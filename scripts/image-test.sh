#!/usr/bin/env bash

set -Eeuo pipefail

image_path=${1:-}
endpoint=${QWEN_ENDPOINT:-http://127.0.0.1:8000}
model_name=${MODEL_NAME:-qwen3.6}

if [ -z "$image_path" ] || [ ! -s "$image_path" ]; then
  echo "Usage: ./scripts/image-test.sh /path/to/image.jpg" >&2
  exit 2
fi

case "$image_path" in
  *.jpg|*.jpeg|*.JPG|*.JPEG) mime=image/jpeg ;;
  *.png|*.PNG) mime=image/png ;;
  *.webp|*.WEBP) mime=image/webp ;;
  *)
    echo "ERROR: 仅支持 JPEG、PNG 或 WebP：$image_path" >&2
    exit 2
    ;;
esac

request_file=$(mktemp /tmp/qwen36-image-request.XXXXXX.json)
response_file=$(mktemp /tmp/qwen36-image-response.XXXXXX.json)
trap 'rm -f "$request_file" "$response_file"' EXIT

python3 - "$image_path" "$mime" "$model_name" >"$request_file" <<'PY'
import base64
import json
import sys

image_path, mime, model = sys.argv[1:]
with open(image_path, "rb") as image_file:
    encoded = base64.b64encode(image_file.read()).decode("ascii")

payload = {
    "model": model,
    "messages": [
        {
            "role": "system",
            "content": (
                "你是严谨的图片识别助手。只能根据图片中实际可见的内容回答，"
                "不要猜测；无法确认的内容必须明确说明。"
            ),
        },
        {
            "role": "user",
            "content": [
                {
                    "type": "image_url",
                    "image_url": {"url": f"data:{mime};base64,{encoded}"},
                },
                {
                    "type": "text",
                    "text": (
                        "请识别并检查这张图片，说明：1.主要物体；2.可见文字；"
                        "3.所在场景；4.能确认的事实；5.无法确认的内容。"
                    ),
                },
            ],
        },
    ],
    "max_tokens": 512,
    "temperature": 0,
    "chat_template_kwargs": {"enable_thinking": False},
}
json.dump(payload, sys.stdout, ensure_ascii=False)
PY

curl --fail-with-body --max-time 600 -sS \
  -o "$response_file" \
  -w 'http_code=%{http_code} total=%{time_total}s\n' \
  "$endpoint/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  --data-binary "@$request_file"

python3 - "$response_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as response_file:
    response = json.load(response_file)
print(response["choices"][0]["message"]["content"])
print("usage=", response.get("usage"))
PY
