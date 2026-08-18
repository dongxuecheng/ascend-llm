# Ascend LLM

在 openEuler 22.03 LTS SP4、鲲鹏 920 和 Atlas 300I Duo 上，使用 Docker Compose 运行 <code>Qwen3.6-35B-A3B-W8A8</code>。

项目提供 OpenAI 兼容 API，默认只启动一个模型实例：

~~~text
qwen36-a
├── NPU：/dev/davinci0、/dev/davinci1
├── 并行：TP=2
├── 模型：/data/models/Qwen3.6-35B-A3B-w8a8
└── API：http://127.0.0.1:8080/v1
~~~

第二张 Atlas 300I Duo 默认不使用。

## 前置条件

启动前应已满足：

- Ascend 驱动工作正常，<code>npu-smi info</code> 能看到健康设备；
- Docker 服务正在运行；
- <code>docker compose version</code> 可以正常执行；
- 推理镜像已经拉取：<code>quay.io/ascend/vllm-ascend:v0.23.0-310p-openeuler</code>；
- 模型位于：<code>/data/models/Qwen3.6-35B-A3B-w8a8</code>；
- 当前没有其他容器占用名称 <code>qwen36-a</code> 或端口 <code>8080</code>。

## 配置

进入项目目录并创建本地配置：

~~~bash
cd /data/packages/ascend-llm
cp -n .env.example .env
~~~

根据第一张卡的 NUMA 节点设置 CPU 亲和：

~~~bash
CARD_A_NODE=$(cat /sys/bus/pci/devices/0000:01:00.0/numa_node)
CARD_A_CPUS=$(cat "/sys/devices/system/node/node$CARD_A_NODE/cpulist")

sed -i "s/^CPUSET_A=.*/CPUSET_A=$CARD_A_CPUS/" .env
echo "card_a_numa=$CARD_A_NODE cpus=$CARD_A_CPUS"
~~~

常用参数位于 <code>.env</code>：

| 参数 | 默认值 | 说明 |
|---|---:|---|
| <code>VLLM_IMAGE</code> | <code>v0.23.0-310p-openeuler</code> | vLLM Ascend 310P 镜像 |
| <code>MODEL_DIR</code> | <code>/data/models/Qwen3.6-35B-A3B-w8a8</code> | 主机模型目录 |
| <code>MODEL_NAME</code> | <code>qwen3.6</code> | API 模型名称 |
| <code>CPUSET_A</code> | 自动填写 | 第一张卡对应的 NUMA CPU |
| <code>MAX_MODEL_LEN</code> | <code>20480</code> | 最大上下文长度 |
| <code>MAX_NUM_SEQS</code> | <code>8</code> | 最大活跃请求数 |
| <code>MAX_NUM_BATCHED_TOKENS</code> | <code>4096</code> | 单次调度的 token 上限 |
| <code>GPU_MEMORY_UTILIZATION</code> | <code>0.90</code> | NPU 显存使用比例 |

## 启动

确认默认 Compose 文件只包含一个服务：

~~~bash
docker compose config --services
~~~

预期输出：

~~~text
qwen36-a
~~~

启动模型：

~~~bash
docker compose up -d
~~~

查看状态和加载日志：

~~~bash
docker compose ps
docker compose logs -f --tail 200 qwen36-a
~~~

首次加载需要数分钟。容器健康后执行：

~~~bash
curl -i http://127.0.0.1:8080/health
curl -sS http://127.0.0.1:8080/v1/models
~~~

如果提示容器名 <code>qwen36-a</code> 已被占用，说明存在之前通过 <code>docker run</code> 创建的同名容器。先确认并删除旧容器，再重新执行 <code>docker compose up -d</code>：

~~~bash
docker ps -a --filter 'name=^/qwen36-a$'
docker stop -t 120 qwen36-a
docker rm qwen36-a
docker compose up -d
~~~

删除旧容器不会删除推理镜像和 <code>/data/models</code> 中的模型。

## API 使用

### 文本请求

~~~bash
curl --max-time 600 -sS \
  http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  --data-binary '{
    "model": "qwen3.6",
    "messages": [
      {
        "role": "user",
        "content": "请简要介绍这台昇腾推理服务器。"
      }
    ],
    "max_tokens": 256,
    "temperature": 0,
    "chat_template_kwargs": {
      "enable_thinking": false
    }
  }'
~~~

是否启用 Thinking 由每次请求的 <code>chat_template_kwargs.enable_thinking</code> 决定。

### 图片识别

仓库提供图片请求测试工具，支持 JPEG、PNG 和 WebP：

~~~bash
QWEN_ENDPOINT=http://127.0.0.1:8080 \
  ./scripts/image-test.sh /data/test.jpg
~~~

### OpenAI 客户端参数

接入兼容 OpenAI API 的应用时使用：

~~~text
base_url = http://127.0.0.1:8080/v1
model    = qwen3.6
~~~

服务默认只监听本机回环地址。需要远程访问时，应在前面增加带鉴权和 TLS 的反向代理，不建议直接让 vLLM 监听公网地址。

## 日常管理

~~~bash
# 查看容器
docker compose ps

# 查看日志
docker compose logs -f --tail 200 qwen36-a

# 查看 NPU
npu-smi info

# 查看资源占用
docker stats --no-stream qwen36-a

# 重启
docker compose restart qwen36-a

# 停止但保留容器
docker compose stop

# 启动已停止的容器
docker compose start

# 停止并删除项目容器
docker compose down
~~~

<code>docker compose down</code> 不会删除模型目录和推理镜像。

## 可选双实例

默认不要使用第二实例。需要提高并发吞吐时，可叠加 <code>docker-compose.dual.yml</code>：

~~~bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.dual.yml \
  up -d
~~~

双实例模式增加：

- <code>qwen36-b</code>：使用 <code>davinci2,3</code>，监听 <code>127.0.0.1:8081</code>；
- <code>qwen36-gateway</code>：Nginx 负载均衡，监听 <code>127.0.0.1:8000</code>。

当前 128GB 主机优先使用默认单实例。启用双实例前应单独完成内存、并发和稳定性测试。

## 当前推理配置

默认 Compose 配置采用：

- Atlas 300I Duo 同一张物理卡内 TP=2；
- Ascend W8A8 量化；
- <code>float16</code> 执行路径；
- <code>gpu-memory-utilization=0.90</code>；
- 最大上下文 20,480 token；
- Full Decode ACLGraph，捕获大小 <code>[1,8]</code>；
- 关闭 310P 不支持的 NPUGraph Ex；
- 默认关闭前缀缓存；
- 按 NPU 所在 NUMA 节点限制容器 CPU；
- API 只监听 <code>127.0.0.1</code>。

该配置以稳定、低并发图片识别和通用问答为目标。实际最优参数取决于图片分辨率、输入输出长度、并发量和延迟目标，应使用真实业务数据测试后再调整。

参考：

- [vLLM Ascend：Qwen3.6-35B-A3B](https://docs.vllm.ai/projects/ascend/en/main/tutorials/models/Qwen3.6-35B-A3B.html)
- [vLLM Ascend：Supported Models](https://docs.vllm.ai/projects/ascend/en/latest/user_guide/support_matrix/supported_models.html)

## 项目文件

~~~text
docker-compose.yml          默认单实例
docker-compose.dual.yml     可选双实例和 Nginx
.env.example                运行参数
nginx/                      双实例负载均衡配置
scripts/image-test.sh       图片识别测试
scripts/smoke-test.sh       文本测试
~~~
