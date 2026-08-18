#!/usr/bin/env bash

set -Eeuo pipefail

# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

require_root
load_env
detect_compose

compose_dual ps

for endpoint in \
  http://127.0.0.1:8080/health \
  http://127.0.0.1:8081/health \
  http://127.0.0.1:8000/health
do
  code=$(curl -sS -o /dev/null --connect-timeout 2 --max-time 5 -w '%{http_code}' "$endpoint" || true)
  echo "$endpoint code=${code:-000}"
done

docker stats --no-stream qwen36-a qwen36-b qwen36-gateway 2>/dev/null || true
free -h
npu-smi info
