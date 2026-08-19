# Ascend LLM

使用 Docker Compose 在 Atlas 300I Duo 上分别测试：

- Qwen3.6-35B-A3B-W8A8；
- Qwen3.6-27B-W8A8-310P；
- Qwen3.8-27B-W8A8。

三个模型使用相同的 NPU、端口和调度参数，以便进行公平测试。

| 模型 | Compose 文件 | NPU | API |
|---|---|---|---|
| Qwen3.6-35B-A3B-W8A8 | <code>docker-compose.qwen35b-a3b.yml</code> | <code>davinci0,1</code> | <code>127.0.0.1:8080</code> |
| Qwen3.6-27B-W8A8-310P | <code>docker-compose.qwen27b.yml</code> | <code>davinci0,1</code> | <code>127.0.0.1:8080</code> |
| Qwen3.8-27B-W8A8 | <code>docker-compose.qwen38-27b.yml</code> | <code>davinci0,1</code> | <code>127.0.0.1:8080</code> |

三个模型不能同时启动。测试另一个模型前，必须先停止当前模型。

## 前置条件

- <code>npu-smi info</code> 显示 NPU 健康；
- <code>docker-compose version</code> 可以正常执行；
- 已有推理镜像：
  <code>quay.io/ascend/vllm-ascend:v0.23.0-310p-openeuler</code>；
- 需要测试的模型已经放入 <code>/data/models</code>；
- 端口 <code>8080</code> 未被其他程序占用。

如果此前的 <code>qwen36-a</code> 仍在运行，先停止并删除旧容器：

~~~bash
docker stop -t 120 qwen36-a
docker rm qwen36-a
~~~

这不会删除模型和推理镜像。

## 配置

~~~bash
cd /data/packages/ascend-llm
cp -n .env.example .env
~~~

确认并根据实际目录修改：

~~~env
QWEN35_MODEL_DIR=/data/models/Qwen3.6-35B-A3B-w8a8
QWEN27_MODEL_DIR=/data/models/Qwen3.6-27B-W8A8-310P
QWEN38_MODEL_DIR=/data/models/Qwen3.8-27B-w8a8
~~~

三份 YAML 已把第一张 Atlas 300I Duo 对应的 CPU 固定为 <code>0-31</code>。模型缓存使用独立的 Docker 命名卷，由 Docker 自动创建、持久化并处理 SELinux，无需手工创建缓存目录。

三份 YAML 使用 <code>version: "2.4"</code>，兼容服务器现有的
<code>docker-compose 1.22</code>。命令不使用 <code>-p</code>；Compose 会默认使用项目目录名
<code>ascend-llm</code> 作为项目名。三个模型轮流运行且服务名、容器名和缓存卷名均不同，
因此不需要额外指定项目名。若以后移动加速卡或改变 PCIe 槽位，应重新确认 NUMA 拓扑并更新
YAML 中的 <code>cpuset</code>。

## 测试 Qwen3.6-35B-A3B-W8A8

启动：

~~~bash
docker-compose -f docker-compose.qwen35b-a3b.yml up -d
~~~

查看状态和日志：

~~~bash
docker-compose -f docker-compose.qwen35b-a3b.yml ps

docker-compose -f docker-compose.qwen35b-a3b.yml logs -f --tail 200
~~~

健康检查：

~~~bash
curl -i http://127.0.0.1:8080/health
curl -sS http://127.0.0.1:8080/v1/models
~~~

停止：

~~~bash
docker-compose -f docker-compose.qwen35b-a3b.yml down
~~~

## 测试 Qwen3.6-27B-W8A8-310P

确认 35B 模型已经停止，然后启动：

~~~bash
docker-compose -f docker-compose.qwen27b.yml up -d
~~~

查看状态和日志：

~~~bash
docker-compose -f docker-compose.qwen27b.yml ps

docker-compose -f docker-compose.qwen27b.yml logs -f --tail 200
~~~

健康检查：

~~~bash
curl -i http://127.0.0.1:8080/health
curl -sS http://127.0.0.1:8080/v1/models
~~~

停止：

~~~bash
docker-compose -f docker-compose.qwen27b.yml down
~~~

## 测试 Qwen3.8-27B-W8A8

确认其他模型已经停止，然后启动：

~~~bash
docker-compose -f docker-compose.qwen38-27b.yml up -d
~~~

查看状态和日志：

~~~bash
docker-compose -f docker-compose.qwen38-27b.yml ps
docker-compose -f docker-compose.qwen38-27b.yml logs -f --tail 200
~~~

健康检查：

~~~bash
curl -i http://127.0.0.1:8080/health
curl -sS http://127.0.0.1:8080/v1/models
~~~

停止：

~~~bash
docker-compose -f docker-compose.qwen38-27b.yml down
~~~

Qwen3.8-27B-W8A8 是刚发布的模型，Eco-Tech 当前验证信息只明确列出 Atlas A2/A3，尚未列出
Atlas 300I Duo。该模型与 Qwen3.6-27B 使用相同的 Qwen3.5 Hybrid 架构，因此这里沿用当前
310P 的已验证配置，但首次启动仍应按实验性兼容进行验证。

## 文本请求

测试 35B 时：

~~~bash
MODEL_NAME=qwen3.6-35b-a3b
~~~

测试 27B 时：

~~~bash
MODEL_NAME=qwen3.6-27b
~~~

测试 Qwen3.8-27B 时：

~~~bash
MODEL_NAME=qwen3.8-27b
~~~

发送请求：

~~~bash
curl --max-time 600 -sS -o /tmp/qwen-response.json -w 'http_code=%{http_code} total=%{time_total}s\n' http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' --data-binary "{
    \"model\": \"$MODEL_NAME\",
    \"messages\": [
      {
        \"role\": \"user\",
        \"content\": \"请用三句话说明图片识别模型应该如何避免产生幻觉。\"
      }
    ],
    \"max_tokens\": 256,
    \"temperature\": 0,
    \"chat_template_kwargs\": {
      \"enable_thinking\": false
    }
  }"

python3 -m json.tool /tmp/qwen-response.json
~~~

## 图片请求

先根据当前模型设置 <code>MODEL_NAME</code>，然后执行：

~~~bash
IMAGE=/data/test.jpg
MIME=$(file -b --mime-type "$IMAGE")

curl --max-time 600 -sS -o /tmp/qwen-image-response.json -w 'http_code=%{http_code} total=%{time_total}s\n' http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' --data-binary @- <<EOF
{
  "model": "$MODEL_NAME",
  "messages": [
    {
      "role": "system",
      "content": "只能根据图片中实际可见的内容回答，无法确认的内容必须明确说明。"
    },
    {
      "role": "user",
      "content": [
        {
          "type": "image_url",
          "image_url": {
            "url": "data:$MIME;base64,$(base64 -w0 "$IMAGE")"
          }
        },
        {
          "type": "text",
          "text": "请识别图片中的主要物体、文字、场景和无法确认的内容。"
        }
      ]
    }
  ],
  "max_tokens": 512,
  "temperature": 0,
  "chat_template_kwargs": {
    "enable_thinking": false
  }
}
EOF

python3 -m json.tool /tmp/qwen-image-response.json
~~~

## 批量测试火焰和烟雾识别

把待测图片放入项目根目录的 <code>test-images</code>。支持
<code>jpg</code>、<code>jpeg</code>、<code>png</code> 和 <code>webp</code>：

~~~bash
cd /data/packages/ascend-llm
mkdir -p test-images
ls -lh test-images
~~~

确认当前模型的健康检查返回 <code>200</code> 后运行。默认关闭思考模式：

~~~bash
python3 test_fire_smoke.py
python3 test_fire_smoke.py --thinking off
~~~

需要开启思考模式时：

~~~bash
python3 test_fire_smoke.py --thinking on
~~~

开启思考模式时脚本会使用 <code>temperature=0.6</code>、<code>top_p=0.95</code>、
<code>top_k=20</code> 和 <code>max_tokens=1024</code>；关闭时使用确定性的非思考配置。
工具会自动读取当前运行的模型名并串行测试所有图片。全部结果统一写入项目根目录的
<code>test-results.json</code>，每张图片只记录图片名、端到端请求耗时和大模型原始回复。
脚本每处理完一张图片就更新结果文件，因此中途停止时已经完成的结果仍会保留；再次执行会覆盖旧结果。

图片和 <code>test-results.json</code> 默认被 Git 忽略。

## 公平测试原则

测试三个模型时应保持以下条件完全一致：

- 使用同一张图片和相同提示词；
- 使用同一组 <code>davinci0,1</code>；
- 保持 <code>MAX_MODEL_LEN=20480</code>；
- 保持 <code>MAX_NUM_SEQS=8</code>；
- 保持 <code>MAX_NUM_BATCHED_TOKENS=4096</code>；
- 保持 <code>GPU_MEMORY_UTILIZATION=0.90</code>；
- 三个模型使用相同的 Thinking 设置；
- 每个模型先预热至少三次，再记录测试结果；
- 不把首次模型加载和首次图编译时间计入稳定性能结果。

建议记录：

- 图片识别结果和幻觉情况；
- 总响应时间；
- 首 token 延迟；
- 输出 token 数和生成速度；
- NPU 显存与利用率；
- 容器主机内存占用；
- 连续请求是否出现错误。

## 三份配置的差异

35B-A3B 是稀疏 MoE 模型，两个 27B 是 Dense Hybrid 模型。三份 YAML 的公共配置保持一致；两个 27B 配置额外包含：

~~~text
--mamba-ssm-cache-dtype float16
--trust-remote-code
~~~

为了建立公平的基础性能结果，27B 默认没有启用 MTP 推测解码。完成基线测试后，再单独测试 MTP：

~~~text
--speculative-config
{"method":"qwen3_5_mtp","num_speculative_tokens":1}
~~~

## 项目文件

~~~text
docker-compose.qwen35b-a3b.yml  Qwen3.6-35B-A3B-W8A8
docker-compose.qwen27b.yml      Qwen3.6-27B-W8A8-310P
docker-compose.qwen38-27b.yml   Qwen3.8-27B-W8A8
.env.example                    公共路径和测试参数
test_fire_smoke.py              火焰/烟雾批量识别与速度统计
test-images/                    待测图片目录（内容不提交 Git）
README.md                       启动、调用和测试说明
~~~
