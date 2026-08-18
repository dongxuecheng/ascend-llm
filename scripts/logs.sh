#!/usr/bin/env bash

set -Eeuo pipefail

name=${1:-qwen36-a}
case "$name" in
  qwen36-a|qwen36-b|qwen36-gateway)
    ;;
  *)
    echo "Usage: $0 [qwen36-a|qwen36-b|qwen36-gateway]" >&2
    exit 2
    ;;
esac

docker logs -f --tail 200 "$name"
