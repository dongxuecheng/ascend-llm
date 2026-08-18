#!/usr/bin/env bash

set -Eeuo pipefail

# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

require_root
load_env
detect_compose

echo "===== Docker ====="
docker version --format 'client={{.Client.Version}} server={{.Server.Version}}'
docker info --format 'root={{.DockerRootDir}} driver={{.Driver}}'
"${COMPOSE[@]}" version

echo "===== Host ====="
uname -m
free -h
df -hT / /data

echo "===== Model ====="
[ -d "$MODEL_DIR" ] || die "模型目录不存在：$MODEL_DIR"
[ -s "$MODEL_DIR/config.json" ] || die "模型 config.json 缺失或为空"
[ -s "$MODEL_DIR/quant_model_weights.safetensors.index.json" ] || die "量化权重索引缺失或为空"
du -sh "$MODEL_DIR"

python3 - "$MODEL_DIR" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
cfg = json.loads((root / "config.json").read_text(encoding="utf-8"))
idx = json.loads((root / "quant_model_weights.safetensors.index.json").read_text(encoding="utf-8"))
shards = sorted(set(idx.get("weight_map", {}).values()))
missing = [name for name in shards if not (root / name).is_file()]
empty = [name for name in shards if (root / name).is_file() and (root / name).stat().st_size == 0]
print("architecture=", cfg.get("architectures"))
print("model_type=", cfg.get("model_type"))
print("vision_config=", "present" if cfg.get("vision_config") else "missing")
print("referenced_shards=", len(shards))
print("missing_shards=", missing)
print("empty_shards=", empty)
if not cfg.get("vision_config") or missing or empty:
    raise SystemExit(1)
PY

echo "===== Devices ====="
for dev in \
  /dev/davinci0 /dev/davinci1 /dev/davinci2 /dev/davinci3 \
  /dev/davinci_manager /dev/devmm_svm /dev/hisi_hdc
do
  [ -e "$dev" ] || die "设备节点缺失：$dev"
  echo "OK: $dev"
done

for path in \
  /usr/local/dcmi \
  /usr/local/sbin/npu-smi \
  /usr/local/Ascend/driver/lib64 \
  /usr/local/Ascend/driver/version.info \
  /etc/ascend_install.info
do
  [ -e "$path" ] || die "驱动挂载源缺失：$path"
  echo "OK: $path"
done

npu-smi info

echo "===== NUMA topology ====="
resolve_topology

echo "===== Images ====="
docker image inspect "$VLLM_IMAGE" \
  --format 'vllm id={{.Id}} arch={{.Architecture}} size={{.Size}}' \
  || die "推理镜像不存在：$VLLM_IMAGE"

if docker image inspect "$NGINX_IMAGE" >/dev/null 2>&1; then
  docker image inspect "$NGINX_IMAGE" \
    --format 'nginx id={{.Id}} arch={{.Architecture}} size={{.Size}}'
else
  echo "INFO: 网关镜像尚未下载，deploy.sh 将拉取：$NGINX_IMAGE"
fi

echo "===== Compose config ====="
compose config >/dev/null
compose_dual config >/dev/null
echo "compose_single_config=OK"
echo "compose_dual_config=OK"

echo "===== Existing containers and ports ====="
docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
ss -lntp | grep -E ':(8000|8080|8081)[[:space:]]' || true

echo "PRECHECK=PASS"
