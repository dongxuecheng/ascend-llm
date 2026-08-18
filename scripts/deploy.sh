#!/usr/bin/env bash

set -Eeuo pipefail

# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/deploy.sh single [--replace-existing]
  ./scripts/deploy.sh dual   [--replace-existing]

single: qwen36-a on davinci0,1, API at 127.0.0.1:8080
dual:   qwen36-a + qwen36-b and Nginx gateway at 127.0.0.1:8000
EOF
}

mode=${1:-}
replace_existing=false

[ "$mode" = "single" ] || [ "$mode" = "dual" ] || {
  usage
  exit 2
}

if [ "${2:-}" = "--replace-existing" ]; then
  replace_existing=true
elif [ -n "${2:-}" ]; then
  usage
  exit 2
fi

require_root
load_env
detect_compose
resolve_topology

[ -d "$MODEL_DIR" ] || die "模型目录不存在：$MODEL_DIR"
docker image inspect "$VLLM_IMAGE" >/dev/null 2>&1 || die "推理镜像不存在：$VLLM_IMAGE"

mkdir -p \
  "$LOG_ROOT/qwen36-a" "$LOG_ROOT/qwen36-b" \
  "$CACHE_ROOT/qwen36-a" "$CACHE_ROOT/qwen36-b"

if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" = "Enforcing" ]; then
  if command -v semanage >/dev/null 2>&1; then
    semanage fcontext -a -t container_file_t "${CACHE_ROOT}(/.*)?" 2>/dev/null \
      || semanage fcontext -m -t container_file_t "${CACHE_ROOT}(/.*)?"
    semanage fcontext -a -t container_file_t "${LOG_ROOT}(/.*)?" 2>/dev/null \
      || semanage fcontext -m -t container_file_t "${LOG_ROOT}(/.*)?"
  fi
  restorecon -Rv "$CACHE_ROOT" "$LOG_ROOT"
fi

migration_dir="$LOG_ROOT/compose-migration-$(date +%Y%m%d-%H%M%S)"

for name in qwen36-a qwen36-b qwen36-gateway; do
  if ! container_exists "$name"; then
    continue
  fi

  project=$(container_compose_project "$name")
  if [ "$project" = "$COMPOSE_PROJECT_NAME" ]; then
    continue
  fi

  if [ "$replace_existing" != true ]; then
    die "发现非 Compose 容器 $name。确认迁移后追加 --replace-existing"
  fi

  mkdir -p "$migration_dir"
  docker inspect "$name" >"$migration_dir/${name}-inspect.json" || true
  docker logs "$name" >"$migration_dir/${name}.log" 2>&1 || true
  docker stop -t 120 "$name" || true
  docker rm "$name"
done

if [ "$mode" = "dual" ]; then
  compose_dual config >/dev/null
else
  compose config >/dev/null
fi

if [ "$mode" = "dual" ] && ! docker image inspect "$NGINX_IMAGE" >/dev/null 2>&1; then
  docker pull "$NGINX_IMAGE"
fi

echo "===== Start qwen36-a on davinci0,1 ====="
compose up -d qwen36-a
wait_for_health qwen36-a 900

if [ "$mode" = "single" ]; then
  echo "DEPLOYMENT=READY endpoint=http://127.0.0.1:8080/v1"
  exit 0
fi

mem_available_kib=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
min_available_kib=$((MIN_MEM_FOR_SECOND_GIB * 1024 * 1024))
echo "mem_available_kib=$mem_available_kib minimum_for_second_kib=$min_available_kib"

if [ "$mem_available_kib" -lt "$min_available_kib" ]; then
  die "第一实例启动后可用内存不足 ${MIN_MEM_FOR_SECOND_GIB}GiB，不启动第二实例"
fi

echo "===== Start qwen36-b on davinci2,3 ====="
  compose_dual up -d qwen36-b
wait_for_health qwen36-b 900

echo "===== Start local Nginx gateway ====="
compose_dual up -d gateway
wait_for_health qwen36-gateway 120

curl -fsS http://127.0.0.1:8000/health >/dev/null
curl -fsS http://127.0.0.1:8000/v1/models
echo
echo "DEPLOYMENT=READY endpoint=http://127.0.0.1:8000/v1"
