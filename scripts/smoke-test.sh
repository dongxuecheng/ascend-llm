#!/usr/bin/env bash

set -Eeuo pipefail

endpoint=${QWEN_ENDPOINT:-http://127.0.0.1:8000}
output=/tmp/qwen36-compose-smoke.json

curl --max-time 600 -fsS \
  -o "$output" \
  -w 'http_code=%{http_code} total=%{time_total}s\n' \
  "$endpoint/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  --data-binary '{
    "model": "qwen3.6",
    "messages": [
      {"role": "system", "content": "你是一个简洁、准确的中文助手。"},
      {"role": "user", "content": "请回复：双实例服务正常。"}
    ],
    "max_tokens": 64,
    "temperature": 0,
    "chat_template_kwargs": {"enable_thinking": false}
  }'

python3 - "$output" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
print(data["choices"][0]["message"]["content"])
print("model=", data.get("model"))
print("usage=", data.get("usage"))
PY
