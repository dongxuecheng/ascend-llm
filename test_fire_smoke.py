#!/usr/bin/env python3
"""逐张测试图片中的火焰/烟雾，并把结果写入一个 JSON 文件。"""

import base64
import json
import sys
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


PROJECT_DIR = Path(__file__).resolve().parent
IMAGE_DIR = PROJECT_DIR / "test-images"
RESULT_FILE = PROJECT_DIR / "test-results.json"
API_BASE = "http://127.0.0.1:8080/v1"
TIMEOUT_SECONDS = 600

IMAGE_TYPES = {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".webp": "image/webp",
}

PROMPT = """请判断这张图片中是否存在可见火焰或可见烟雾。只能依据图片中实际可见的内容，不要猜测；注意区分烟雾与云、雾、蒸汽和扬尘。请简洁回答：
火焰：是、否或不确定
烟雾：是、否或不确定
依据：简要说明可见证据和无法确认的地方"""


def request_json(url, payload=None):
    headers = {"Accept": "application/json"}
    data = None
    method = "GET"
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
        method = "POST"

    request = Request(url, data=data, headers=headers, method=method)
    try:
        with urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            body = response.read().decode("utf-8", errors="replace")
    except HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError("HTTP {}: {}".format(exc.code, body[:1000])) from exc
    except (URLError, TimeoutError, OSError) as exc:
        raise RuntimeError(str(exc)) from exc

    try:
        result = json.loads(body)
    except json.JSONDecodeError as exc:
        raise RuntimeError("接口返回的不是合法 JSON：{}".format(body[:1000])) from exc
    if not isinstance(result, dict):
        raise RuntimeError("接口返回的 JSON 顶层不是对象")
    return result


def get_model_name():
    response = request_json(API_BASE + "/models")
    models = response.get("data")
    if not isinstance(models, list) or not models:
        raise RuntimeError("/v1/models 没有返回可用模型")
    model_name = models[0].get("id") if isinstance(models[0], dict) else None
    if not model_name:
        raise RuntimeError("无法读取当前模型名称")
    return model_name


def find_images():
    if not IMAGE_DIR.is_dir():
        raise RuntimeError("图片目录不存在：{}".format(IMAGE_DIR))
    return sorted(
        path
        for path in IMAGE_DIR.rglob("*")
        if path.is_file() and path.suffix.lower() in IMAGE_TYPES
    )


def build_payload(image_path, model_name):
    mime_type = IMAGE_TYPES[image_path.suffix.lower()]
    encoded_image = base64.b64encode(image_path.read_bytes()).decode("ascii")
    return {
        "model": model_name,
        "messages": [
            {
                "role": "system",
                "content": "你是严谨的火焰与烟雾图片识别助手。",
            },
            {
                "role": "user",
                "content": [
                    {
                        "type": "image_url",
                        "image_url": {
                            "url": "data:{};base64,{}".format(
                                mime_type, encoded_image
                            )
                        },
                    },
                    {"type": "text", "text": PROMPT},
                ],
            },
        ],
        "max_tokens": 256,
        "temperature": 0,
        "chat_template_kwargs": {"enable_thinking": False},
    }


def get_reply(response):
    try:
        content = response["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError) as exc:
        raise RuntimeError("接口响应中缺少大模型回复") from exc
    if not isinstance(content, str):
        raise RuntimeError("大模型回复不是文本")
    return content.strip()


def save_results(results):
    RESULT_FILE.write_text(
        json.dumps(results, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def main():
    try:
        images = find_images()
        if not images:
            raise RuntimeError("{} 中没有 jpg、png 或 webp 图片".format(IMAGE_DIR))
        model_name = get_model_name()
    except RuntimeError as exc:
        print("ERROR: {}".format(exc), file=sys.stderr)
        return 1

    results = []
    save_results(results)

    print("model={}".format(model_name))
    print("images={}".format(len(images)))

    for index, image_path in enumerate(images, start=1):
        relative_name = image_path.relative_to(IMAGE_DIR).as_posix()
        elapsed = None
        started = None
        try:
            payload = build_payload(image_path, model_name)
            started = time.perf_counter()
            response = request_json(API_BASE + "/chat/completions", payload)
            elapsed = round(time.perf_counter() - started, 3)
            reply = get_reply(response)
        except (OSError, RuntimeError) as exc:
            if started is not None:
                elapsed = round(time.perf_counter() - started, 3)
            reply = "ERROR: {}".format(exc)

        results.append(
            {
                "image": relative_name,
                "elapsed_seconds": elapsed,
                "reply": reply,
            }
        )
        save_results(results)
        print(
            "[{}/{}] {} | {}s".format(
                index,
                len(images),
                relative_name,
                elapsed if elapsed is not None else "n/a",
            ),
            flush=True,
        )

    print("results={}".format(RESULT_FILE))
    return 0


if __name__ == "__main__":
    sys.exit(main())
