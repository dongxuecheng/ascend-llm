#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

die() {
  echo "ERROR: $*" >&2
  exit 1
}
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "请使用 root 执行：sudo -i"
  fi
}

load_env() {
  if [ ! -f "$PROJECT_DIR/.env" ]; then
    die "缺少 $PROJECT_DIR/.env，请先执行：cp .env.example .env"
  fi

  set -a
  # shellcheck disable=SC1091
  . "$PROJECT_DIR/.env"
  set +a

  : "${COMPOSE_PROJECT_NAME:=ascend-llm}"
  : "${VLLM_IMAGE:=quay.io/ascend/vllm-ascend:v0.23.0-310p-openeuler}"
  : "${NGINX_IMAGE:=nginx:1.28-alpine}"
  : "${MODEL_DIR:=/data/models/Qwen3.6-35B-A3B-w8a8}"
  : "${LOG_ROOT:=/data/logs}"
  : "${CACHE_ROOT:=/data/cache}"
  : "${BDF_A:=0000:01:00.0}"
  : "${BDF_B:=0000:03:00.0}"
  : "${MIN_MEM_FOR_SECOND_GIB:=48}"

  export COMPOSE_PROJECT_NAME VLLM_IMAGE NGINX_IMAGE MODEL_DIR LOG_ROOT CACHE_ROOT
  export BDF_A BDF_B MIN_MEM_FOR_SECOND_GIB
}

detect_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose -f "$PROJECT_DIR/docker-compose.yml")
    COMPOSE_DUAL=(docker compose -f "$PROJECT_DIR/docker-compose.yml" -f "$PROJECT_DIR/docker-compose.dual.yml")
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE=(docker-compose -f "$PROJECT_DIR/docker-compose.yml")
    COMPOSE_DUAL=(docker-compose -f "$PROJECT_DIR/docker-compose.yml" -f "$PROJECT_DIR/docker-compose.dual.yml")
  else
    die "未找到 docker compose 或 docker-compose"
  fi
}

compose() {
  (cd "$PROJECT_DIR" && "${COMPOSE[@]}" "$@")
}

compose_dual() {
  (cd "$PROJECT_DIR" && "${COMPOSE_DUAL[@]}" "$@")
}

numa_node_for_bdf() {
  local bdf=$1
  local node_file="/sys/bus/pci/devices/$bdf/numa_node"
  [ -r "$node_file" ] || return 1
  cat "$node_file"
}

cpus_for_node() {
  local node=$1
  local cpulist="/sys/devices/system/node/node${node}/cpulist"
  [ -r "$cpulist" ] || return 1
  cat "$cpulist"
}

resolve_topology() {
  local node_a node_b

  node_a=$(numa_node_for_bdf "$BDF_A") || die "无法读取 $BDF_A 的 NUMA 节点"
  node_b=$(numa_node_for_bdf "$BDF_B") || die "无法读取 $BDF_B 的 NUMA 节点"

  [ "$node_a" -ge 0 ] || die "$BDF_A 返回 NUMA node=$node_a，请在 .env 手工设置 CPUSET_A"
  [ "$node_b" -ge 0 ] || die "$BDF_B 返回 NUMA node=$node_b，请在 .env 手工设置 CPUSET_B"

  if [ -z "${CPUSET_A:-}" ]; then
    CPUSET_A=$(cpus_for_node "$node_a") || die "无法读取 NUMA node $node_a 的 CPU 列表"
  fi
  if [ -z "${CPUSET_B:-}" ]; then
    CPUSET_B=$(cpus_for_node "$node_b") || die "无法读取 NUMA node $node_b 的 CPU 列表"
  fi

  export NUMA_NODE_A=$node_a NUMA_NODE_B=$node_b CPUSET_A CPUSET_B

  echo "card_a_bdf=$BDF_A numa=$NUMA_NODE_A cpus=$CPUSET_A"
  echo "card_b_bdf=$BDF_B numa=$NUMA_NODE_B cpus=$CPUSET_B"

  if [ "$node_a" = "$node_b" ]; then
    echo "WARNING: 两张卡位于同一 NUMA 节点，双实例可能竞争同一组 CPU/内存带宽。" >&2
  fi
}

container_exists() {
  docker container inspect "$1" >/dev/null 2>&1
}

container_compose_project() {
  docker container inspect "$1" \
    --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || true
}

wait_for_health() {
  local container=$1
  local timeout_seconds=${2:-900}
  local elapsed=0
  local state health

  echo "等待 $container 健康，最长 ${timeout_seconds}s..."
  while [ "$elapsed" -lt "$timeout_seconds" ]; do
    state=$(docker inspect "$container" --format '{{.State.Status}}' 2>/dev/null || true)
    health=$(docker inspect "$container" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null || true)

    if [ "$state" = "running" ] && [ "$health" = "healthy" ]; then
      echo "$container is healthy"
      return 0
    fi

    if [ "$state" = "exited" ] || [ "$state" = "dead" ]; then
      docker logs --tail 200 "$container" || true
      die "$container 已退出"
    fi

    if [ "$health" = "unhealthy" ]; then
      docker logs --tail 200 "$container" || true
      die "$container 健康检查失败"
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  docker logs --tail 200 "$container" || true
  die "等待 $container 健康超时"
}
