# openEuler 22.03 LTS SP4 + Atlas 300I Duo 部署 Qwen3.6-35B-A3B-W8A8

> 文档基线：2026-08-18
>
> 目标硬件：鲲鹏 920、Atlas 300I Duo 96GB × 2、主机内存 128GB
>
> 目标服务：OpenAI 兼容 API，模型 <code>Eco-Tech/Qwen3.6-35B-A3B-w8a8</code>

本文从一台刚安装完 openEuler 22.03 LTS SP4 的服务器开始，完成系统检查、Atlas 驱动与固件、Docker、模型权重以及 vLLM Ascend 服务部署。

## Docker Compose 双实例快速部署（推荐）

仓库已经包含可直接部署的生产基线：

~~~text
Nginx 127.0.0.1:8000
├── qwen36-a 127.0.0.1:8080 → davinci0,1 → TP=2
└── qwen36-b 127.0.0.1:8081 → davinci2,3 → TP=2
~~~

主要文件：

~~~text
docker-compose.yml          两个 vLLM 实例和本地 Nginx 网关
.env.example                镜像、模型、上下文和内存保护参数
nginx/default.conf.template least_conn 负载均衡和流式代理配置
scripts/preflight.sh        模型、驱动、设备、NUMA 和 Compose 预检
scripts/deploy.sh           自动 NUMA CPU 亲和、顺序冷启动和内存闸门
scripts/status.sh           容器、API、内存和 NPU 状态
scripts/logs.sh             跟踪指定容器日志
scripts/smoke-test.sh        OpenAI Chat Completions 冒烟测试
scripts/image-test.sh        图片识别端到端验收
scripts/down.sh              停止并删除本项目容器
~~~

如果服务器还没有 Compose，openEuler 22.03 可以从已配置的软件仓库安装：

~~~bash
dnf install -y docker-compose
docker-compose version
~~~

脚本同时兼容 `docker compose` 插件和 `docker-compose` 独立命令。进入上传或克隆好的项目目录后执行：

~~~bash
sudo -i
cd /data/packages/ascend-llm
cp .env.example .env
chmod +x scripts/*.sh
./scripts/preflight.sh
~~~

`.env` 默认保持网关只监听本机。`deploy.sh` 会读取两张卡的 PCIe NUMA 节点，并把每个实例限制在对应 NUMA CPU 集合中。不要在没有鉴权和 TLS 的情况下把 `GATEWAY_LISTEN` 改成 `0.0.0.0:8000`。

从此前手工创建的 `qwen36-a` 容器迁移到 Compose，并启动双实例：

~~~bash
./scripts/deploy.sh dual --replace-existing
~~~

`--replace-existing` 只删除同名旧容器，不删除镜像、模型或 `/data` 数据；删除前会把旧容器的 `inspect` 和日志保存到 `/data/logs/compose-migration-<时间>`。两个约 38GB 的实例会顺序启动，第一实例健康且主机可用内存仍不少于 48GiB 时才启动第二实例。每个实例首次冷启动最长允许 15 分钟。

部署完成后：

~~~bash
./scripts/status.sh
./scripts/smoke-test.sh
./scripts/image-test.sh /data/test.jpg
~~~

应用统一访问：

~~~text
http://127.0.0.1:8000/v1
~~~

如果第二张卡或 128GB 主机内存无法通过双实例验收，可回退到单实例：

~~~bash
./scripts/down.sh
./scripts/deploy.sh single
~~~

单实例直接访问 `http://127.0.0.1:8080/v1`。脚本不会把一个请求拆到两张物理卡上；双实例提高的是并发吞吐和可用性，单请求延迟仍由单个 TP=2 实例决定。

## 1. 最终方案

采用以下版本固定组合：

| 层级 | 选型 |
|---|---|
| 主机系统 | openEuler 22.03 LTS SP4，aarch64 |
| 主机侧昇腾软件 | 与该 310P 镜像所带 CANN 平台版本配套的 Ascend HDK 驱动和固件 |
| 容器 | Docker |
| 推理镜像 | <code>quay.io/ascend/vllm-ascend:v0.23.0-310p-openeuler</code> |
| 容器内软件 | 由镜像整体锁定；vLLM 0.23.0、vLLM Ascend 0.23.0，CANN/TorchNPU 以镜像实测输出为准 |
| 模型 | <code>Eco-Tech/Qwen3.6-35B-A3B-w8a8</code> |
| 部署拓扑 | 每张物理 Atlas 300I Duo 启动一个 TP=2 副本，共两个副本 |
| API | 两个后端监听 <code>127.0.0.1:8080/8081</code>，Nginx 统一监听 <code>127.0.0.1:8000</code> |

Atlas 300I Duo 每张物理卡包含两个 Ascend 310P 芯片，96GB 是整张卡的总显存。两张物理卡形成四个逻辑 NPU 设备。每个模型副本只使用同一张物理卡内的两个芯片，避免单个请求跨物理卡执行 TP=4；两个副本由本地 Nginx 按最少连接数分发请求。

128GB 主机内存已经验证首实例运行后仍有约 100GiB 可用。双实例采用顺序冷启动和 48GiB 可用内存闸门；若现场压力测试出现持续 swap、OOM 或可用内存低于 20GiB，应立即回退单实例，生产双实例仍建议升级到 256GB。因此本教程：

- 不使用 CPU offload；
- 不同时冷启动两个实例；
- 使用 W8A8 权重；
- 初始上下文固定为 20,480 token；
- 每实例最大活跃序列数为 8，双实例合计为 16；
- 默认关闭前缀缓存和 MTP 推测解码。

截至文档基线日期，vLLM Ascend 官方安装页已经提供稳定版 <code>v0.23.0-310p-openeuler</code>，因此不再使用早期的 <code>v0.23.0rc1</code>。即便使用稳定版，正式上线前仍应完成至少 24 小时稳定性、精度和压力验收，不能把“成功启动”视为生产验收完成。

## 2. 重要原则

### 2.1 主机不安装 CANN Toolkit

使用官方预构建 vLLM Ascend 镜像时，主机只安装驱动和固件。CANN、NNAL、PyTorch、TorchNPU、vLLM 和 vLLM Ascend 均由容器提供。不要再在主机或容器中混装另一套 CANN/Python 包。

### 2.2 不猜驱动版本

vLLM Ascend 的 310P 安装说明要求使用平台专用 CANN 9.1.0 版本线，并按对应版本说明中的配套表选择 Ascend HDK。发布过程中曾出现 beta 与正式小版本文档更新，因此最终以“所拉取镜像的 digest、镜像内实测 CANN 版本、该版本对应 HDK 配套表”三者为准。华为下载页和配套表可能更新，而且部分下载需要账号，所以本文不硬编码一个可能过期的 HDK 小版本。

下载时必须同时满足：

- 产品为 Atlas 300I Duo / Ascend 310P；
- 架构为 aarch64；
- 操作系统和内核被该 HDK 明确支持；
- 驱动与固件来自同一配套发布；
- 该 HDK 位于镜像实际 CANN 版本对应的兼容表中。

### 2.3 先通过兼容性闸门

如果华为兼容性查询或 HDK 发布说明没有列出当前服务器型号、openEuler 22.03 LTS SP4 和当前内核组合，不要强装。应选择厂商认证内核/OS，或提交华为技术工单确认。

## 3. 当前服务器基线与部署进度

本文现在按已经取得的现场输出维护，不再把服务器当成完全未知的裸机。当前已确认：

| 项目 | 现场结果 | 结论 |
|---|---|---|
| 服务器 | Huawei TaiShan 200（Model 2280） | 正常 |
| CPU | 鲲鹏 920 5220，双路、64 核、2 个 NUMA 节点 | 正常 |
| 操作系统 | openEuler 22.03 LTS SP4，aarch64 | 正常 |
| 内核 | <code>5.10.0-216.0.0.115.oe2203sp4.aarch64</code> | 驱动依赖已与运行内核匹配 |
| 主机内存 | 标称 128GB，系统可见约 124GiB，swap 4GB | 单实例可用，余量有限 |
| NPU | Atlas 300I Duo 96GB × 2，共 4 个逻辑设备 | <code>davinci0..3</code> 均健康 |
| 驱动 | <code>npu-smi 25.5.2</code>，通过官方 <code>.run</code> 包预装 | 不要重复安装或覆盖 |
| 第一张卡 | PCIe <code>0000:01:00.0</code>，Gen4 x16 | 首实例使用 <code>davinci0,1</code> |
| 第二张卡 | PCIe <code>0000:03:00.0</code>，Gen4 x8（降级） | 暂不用于首实例，后续排查槽位/链路 |
| 数据盘 | <code>/dev/sdb1</code>，XFS，7.3TB，挂载到 <code>/data</code> | <code>ftype=1</code>，适合 overlay2 |
| Docker | openEuler <code>docker-engine 18.09.0-350.oe2203sp4</code> | 容器和模型实跑均已通过 |
| SELinux | Enforcing | Docker、模型和日志目录标签均已验收 |

当前目录规划：

~~~text
/data/docker       Docker data-root
/data/models       模型权重
/data/logs         服务日志
/data/packages     离线安装包或临时下载
~~~

所有后续命令均在服务器上以 root 执行：

~~~bash
sudo -i
~~~

建议先设置一个明确的静态主机名，避免后续日志和监控中持续出现 <code>localhost.localdomain</code>：

~~~bash
hostnamectl set-hostname hz-server
~~~

这是管理性变更，不影响已有 IP 和 SSH 连接。

## 4. 处理已预装的 Atlas 驱动

当前服务器已经通过 <code>.run</code> 包完成驱动和固件安装，<code>/etc/ascend_install.info</code> 显示 full 安装成功，四个逻辑 NPU 的 Health 均为 OK。因此本机不执行任何驱动安装、覆盖安装或升级命令。

特别注意：本机宿主侧命令实际位于：

~~~text
/usr/local/sbin/npu-smi
~~~

而官方 vLLM Ascend 容器通常从 <code>/usr/local/bin/npu-smi</code> 调用它，所以容器挂载应把宿主源路径映射到容器目标路径：

~~~bash
-v /usr/local/sbin/npu-smi:/usr/local/bin/npu-smi:ro
~~~

不要照搬官方示例中的宿主源路径，否则 Docker 会在不存在的位置创建目录，随后导致容器内 <code>npu-smi</code> 不可用。

部署前只做只读验收：

~~~bash
npu-smi info
cat /usr/local/Ascend/driver/version.info
cat /etc/ascend_install.info
ls -l /dev/davinci[0-3] /dev/davinci_manager /dev/devmm_svm /dev/hisi_hdc
~~~

以下任一情况都必须停止：设备 Health 不为 OK、设备节点缺失、驱动文件缺失，或者内核日志出现持续的 NPU reset、PCIe AER、SMMU、固件错误。

## 5. 驱动维护边界

当前驱动编译依赖 <code>make</code>、<code>dkms</code>、<code>gcc</code>、精确匹配运行内核的 <code>kernel-headers</code> 与 <code>kernel-devel</code> 均已安装，无需重复执行安装命令。

后续升级驱动或内核前必须重新核对：

- CANN 9.1.0 与 Ascend HDK 的官方配套表；
- Atlas 300I Duo / Ascend 310P、aarch64、openEuler 和目标内核兼容性；
- 驱动与固件是否来自同一配套发布；
- 维护窗口、回退包和 BMC 远程控制是否可用。

驱动/固件升级不是本次容器部署的一部分。不能因为容器预检失败就直接重装驱动；应先核对挂载路径、镜像平台和版本链。

## 6. 数据盘、Docker 与 SELinux 现状

数据盘已经以 XFS 挂载到 <code>/data</code>，<code>/etc/fstab</code> 已通过校验；Docker 的 <code>data-root</code> 已设为 <code>/data/docker</code>，存储驱动为 overlay2，并通过 systemd 的 <code>RequiresMountsFor=/data</code> 保证数据盘先于 Docker 挂载。

Docker 根目录已使用 SELinux 等价映射继承 <code>/var/lib/docker</code> 的标签。模型和日志目录也必须具有容器可访问标签，但不要对 <code>/usr/local/Ascend</code>、<code>/usr/local/dcmi</code> 或设备节点做递归重标记。

~~~bash
semanage fcontext -a -t container_file_t '/data/models(/.*)?'
semanage fcontext -a -t container_file_t '/data/logs(/.*)?'
restorecon -Rv /data/models /data/logs
~~~

如果规则已经存在，<code>-a</code> 会提示已定义；把对应一行改为 <code>semanage fcontext -m ...</code> 后重新执行即可。

## 7. 验证 Docker 真实可运行

当前安装的是 openEuler 仓库维护的 Docker 18.09.0 构建。<code>docker info</code> 中显示 <code>runc version: N/A</code> 并不能单独证明运行时故障，必须以实际创建容器的结果为准。

先运行一个小型多架构测试镜像：

~~~bash
docker run --rm hello-world
~~~

若能看到 <code>Hello from Docker!</code>，说明镜像拉取、aarch64 manifest、overlay2、runc、网络命名空间和容器清理的基本链路均已工作。随后确认根目录和服务日志：

~~~bash
docker info --format 'root={{.DockerRootDir}} driver={{.Driver}}'
systemctl is-active docker
journalctl -u docker --since '-10 minutes' -p warning --no-pager
~~~

一次性的 <code>Failed to cleanup netns</code> 警告在 daemon 仍为 active、测试容器能正常运行且没有持续重复时，可以先记录并继续；如果每次运行都出现、容器无法删除或网络异常，则应先修复 Docker。

## 8. 拉取并固定推理镜像

本教程固定使用 openEuler + 310P 专用镜像：

~~~bash
export VLLM_IMAGE=quay.io/ascend/vllm-ascend:v0.23.0-310p-openeuler
mkdir -p /var/log/ascend-install
docker pull "$VLLM_IMAGE"
docker image inspect "$VLLM_IMAGE" \
  --format '{{index .RepoDigests 0}}' \
  | tee /var/log/ascend-install/vllm-image-digest.txt
~~~

不要使用 <code>latest</code>，也不要使用 A2/A3 或 Ubuntu 镜像。Atlas 300I Duo 不支持 Triton；310P 专用镜像已经按该平台处理依赖。

若中国大陆网络无法直接访问 Quay，可按 vLLM Ascend FAQ 使用镜像代理，例如：

~~~bash
export VLLM_IMAGE=m.daocloud.io/quay.io/ascend/vllm-ascend:v0.23.0-310p-openeuler
docker pull "$VLLM_IMAGE"
~~~

使用镜像代理时同样记录 RepoDigest。正式环境应将通过测试的镜像同步到内部镜像仓库，并按 digest 固定。

## 9. 容器内 NPU 预检

先只映射计划用于首实例的两个 NPU。以下命令暂定 <code>davinci0</code> 和 <code>davinci1</code> 属于同一张物理 Duo 卡；第 11 节启动前必须确认这一点。

~~~bash
export VLLM_IMAGE=quay.io/ascend/vllm-ascend:v0.23.0-310p-openeuler

docker run --rm \
  --name ascend-preflight \
  --network host \
  --shm-size=10g \
  --device /dev/davinci0 \
  --device /dev/davinci1 \
  --device /dev/davinci_manager \
  --device /dev/devmm_svm \
  --device /dev/hisi_hdc \
  -v /usr/local/dcmi:/usr/local/dcmi:ro \
  -v /usr/local/sbin/npu-smi:/usr/local/bin/npu-smi:ro \
  -v /usr/local/Ascend/driver/lib64:/usr/local/Ascend/driver/lib64:ro \
  -v /usr/local/Ascend/driver/version.info:/usr/local/Ascend/driver/version.info:ro \
  -v /etc/ascend_install.info:/etc/ascend_install.info:ro \
  "$VLLM_IMAGE" \
  bash -lc 'npu-smi info && python -c "import torch, torch_npu, vllm, vllm_ascend; print(torch.__version__, torch_npu.__version__, vllm.__version__)"'
~~~

预检必须满足：

- 容器内 <code>npu-smi info</code> 正常；
- 四个 Python 包均能导入；
- vLLM 为 0.23.0；
- 没有 driver/runtime version mismatch、<code>libascendcl.so</code> 或 <code>libdcmi.so</code> 错误。

将容器内实际版本存档，后续所有升级和故障定位都以此为准：

~~~bash
docker run --rm "$VLLM_IMAGE" bash -lc '
python -c "import torch, torch_npu, vllm; print(torch.__version__, torch_npu.__version__, vllm.__version__)"
find /usr/local/Ascend -maxdepth 5 -type f \( -name version.info -o -name version.cfg \) -print -exec head -n 30 {} \;
' | tee /var/log/ascend-install/container-stack-versions.txt
~~~

如果这里显示的 CANN 平台版本与安装 HDK 时采用的配套表不一致，应停止，不要启动模型。重新选择一套完整兼容栈。

若宿主机 <code>npu-smi</code> 正常、容器内失败，优先检查设备节点和五个驱动目录/文件挂载，不要在容器里重新安装驱动。

## 10. 下载模型权重

官方 vLLM Ascend Qwen3.6 教程为 Atlas 300I Duo W8A8 路径指定了：

~~~text
Eco-Tech/Qwen3.6-35B-A3B-w8a8
~~~

模型地址：[ModelScope 模型页](https://www.modelscope.cn/models/Eco-Tech/Qwen3.6-35B-A3B-w8a8)

推荐先下载到主机固定目录，不让生产服务在每次启动时临时下载。使用一次性容器完成下载，避免污染主机 Python：

~~~bash
export VLLM_IMAGE=quay.io/ascend/vllm-ascend:v0.23.0-310p-openeuler

docker run --rm \
  --network host \
  -v /data/models:/models \
  "$VLLM_IMAGE" \
  bash -lc 'python -m pip install --no-cache-dir -U modelscope && modelscope download --model Eco-Tech/Qwen3.6-35B-A3B-w8a8 --local_dir /models/Qwen3.6-35B-A3B-w8a8'
~~~

下载中断后可以重跑同一条命令。完成后验证：

~~~bash
MODEL_DIR=/data/models/Qwen3.6-35B-A3B-w8a8
test -f "$MODEL_DIR/config.json"
find "$MODEL_DIR" -maxdepth 1 -type f -printf '%f %s bytes\n' | sort
du -sh "$MODEL_DIR"
chmod -R a+rX "$MODEL_DIR"
~~~

至少应看到配置、tokenizer 和 safetensors 权重/索引文件。将模型页面的 revision、下载时间和文件列表存档：

~~~bash
date -Is > /var/log/ascend-install/model-download-time.txt
find "$MODEL_DIR" -maxdepth 2 -type f -printf '%P %s bytes\n' \
  | sort > /var/log/ascend-install/model-files.txt
~~~

如果用于生产，建议将模型复制到内部对象存储或制品库，并锁定已经验收的 revision。该 W8A8 权重来自 vLLM Ascend 官方教程指向的 ModelScope 仓库，不应与其他来源的同名量化权重混用。

## 11. 物理卡与逻辑设备对应关系

现场 PCIe 与 <code>npu-smi</code> 输出已经确认当前映射：

~~~text
物理卡 A：0000:01:00.0，PCIe Gen4 x16，/dev/davinci0、/dev/davinci1
物理卡 B：0000:03:00.0，PCIe Gen4 x8（downgraded），/dev/davinci2、/dev/davinci3
~~~

首实例固定使用物理卡 A 的 <code>davinci0,1</code>。这既保证 TP=2 位于同一张 Duo 卡，也避开第二张卡当前的 x8 降级链路。第二张卡在后续使用前，应结合服务器槽位规格、转接板/背板和 BMC 告警确认 x8 是否为该槽位的设计状态；不要为了首实例而移动硬件。

## 12. 启动 Qwen3.6 首实例

以下参数是 Atlas 300I Duo 的稳健起点，并与 vLLM Ascend v0.23.0 官方模型教程保持一致。

~~~bash
export VLLM_IMAGE=quay.io/ascend/vllm-ascend:v0.23.0-310p-openeuler

docker run -d \
  --name qwen36-a \
  --restart unless-stopped \
  --network host \
  --shm-size=10g \
  --log-opt max-size=100m \
  --log-opt max-file=5 \
  --device /dev/davinci0 \
  --device /dev/davinci1 \
  --device /dev/davinci_manager \
  --device /dev/devmm_svm \
  --device /dev/hisi_hdc \
  -v /usr/local/dcmi:/usr/local/dcmi:ro \
  -v /usr/local/sbin/npu-smi:/usr/local/bin/npu-smi:ro \
  -v /usr/local/Ascend/driver/lib64:/usr/local/Ascend/driver/lib64:ro \
  -v /usr/local/Ascend/driver/version.info:/usr/local/Ascend/driver/version.info:ro \
  -v /etc/ascend_install.info:/etc/ascend_install.info:ro \
  -v /data/models/Qwen3.6-35B-A3B-w8a8:/models/Qwen3.6-35B-A3B-w8a8:ro \
  -v /data/logs/qwen36-a:/logs \
  -e ASCEND_RT_VISIBLE_DEVICES=0,1 \
  -e PYTORCH_NPU_ALLOC_CONF=expandable_segments:True \
  -e OMP_NUM_THREADS=1 \
  -e TASK_QUEUE_ENABLE=1 \
  "$VLLM_IMAGE" \
  vllm serve /models/Qwen3.6-35B-A3B-w8a8 \
    --host 127.0.0.1 \
    --port 8080 \
    --tensor-parallel-size 2 \
    --gpu-memory-utilization 0.90 \
    --max-num-seqs 16 \
    --served-model-name qwen3.6 \
    --dtype float16 \
    --additional-config '{"ascend_compilation_config":{"enable_npugraph_ex":false}}' \
    --compilation-config '{"cudagraph_mode":"FULL_DECODE_ONLY","cudagraph_capture_sizes":[1,8]}' \
    --quantization ascend \
    --max-model-len 20480 \
    --no-enable-prefix-caching
~~~

参数说明：

- <code>--tensor-parallel-size 2</code>：模型跨同一张 Duo 卡的两个芯片；
- <code>--dtype float16</code>：Atlas 300I Duo 推理路径要求；
- <code>--quantization ascend</code>：W8A8 权重必需；
- <code>--max-model-len 20480</code>：官方 310P 基线，先保证稳定；
- <code>--max-num-seqs 16</code>：限制并发 KV Cache 和图捕获压力；
- <code>enable_npugraph_ex=false</code>：Atlas 300I Duo 不支持该功能；
- <code>FULL_DECODE_ONLY</code>：仅在 decode 阶段使用图重放；
- <code>--no-enable-prefix-caching</code>：先降低显存压力；
- 监听 <code>127.0.0.1</code>：避免未经鉴权的模型 API 暴露到网络。

官方命令示例的 capture size 使用 <code>[1,8]</code>，说明文字又列出 <code>[1,2,4,8,16]</code>。首轮采用实际示例中的 <code>[1,8]</code>；只有完成稳定性和精度验收后，才测试更大的捕获集合。

不要在首轮加入以下功能：

- MTP/speculative decoding；
- prefix caching；
- CPU/KV offload；
- async scheduling；
- 自行安装 Triton；
- 超过 20,480 的上下文；
- 两个模型实例同时冷启动。

## 13. 观察启动过程

~~~bash
docker ps --filter name=qwen36-a
docker logs -f --tail 200 qwen36-a
~~~

首次启动需要读取数十 GB 权重并完成图捕获，时间可能较长。另开终端观察主机和 NPU：

~~~bash
watch -n 2 npu-smi info
~~~

以及：

~~~bash
free -h
swapon --show
docker stats --no-stream qwen36-a
~~~

判断标准：

- 容器保持 Up 状态；
- 日志最终显示 API 服务开始监听 8080；
- 两个目标 NPU 有显存占用，另外两个 NPU 空闲；
- 主机没有 OOM killer；
- 稳态不持续使用 swap；
- 没有反复 NPU reset、HCCL、ACL、ATB 或 graph capture 错误。

若容器退出：

~~~bash
docker inspect qwen36-a \
  --format 'exit={{.State.ExitCode}} oom={{.State.OOMKilled}} error={{.State.Error}}'
docker logs --tail 300 qwen36-a
~~~

## 14. API 功能验收

### 14.1 健康与模型列表

~~~bash
curl -fsS http://127.0.0.1:8080/health
curl -fsS http://127.0.0.1:8080/v1/models | jq
~~~

### 14.2 Completions 测试

~~~bash
curl -fsS http://127.0.0.1:8080/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "qwen3.6",
    "prompt": "请用三句话说明鲲鹏与昇腾在这台服务器中的分工。",
    "max_tokens": 160,
    "temperature": 0
  }' | jq
~~~

### 14.3 Chat Completions 测试

~~~bash
curl -fsS http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "qwen3.6",
    "messages": [
      {"role": "system", "content": "你是一个简洁、准确的中文助手。"},
      {"role": "user", "content": "列出部署大模型服务时需要监控的五项指标。"}
    ],
    "max_tokens": 256,
    "temperature": 0
  }' | jq
~~~

验收结果应为 HTTP 200，JSON 中有 <code>choices</code>，返回内容可读且无异常重复。

### 14.4 重启恢复测试

~~~bash
docker restart qwen36-a
docker logs -f --tail 100 qwen36-a
curl -fsS http://127.0.0.1:8080/v1/models | jq
~~~

随后安排一次服务器维护重启，验证 Docker 自启动、NPU 驱动加载和容器自动恢复：

~~~bash
reboot
~~~

重连后：

~~~bash
sudo -i
npu-smi info
systemctl is-active docker
docker ps --filter name=qwen36-a
curl -fsS http://127.0.0.1:8080/v1/models | jq
~~~

## 15. 128GB 主机内存下的运行规则

128GB 对单个 TP=2 实例通常可用，但必须保留宿主机、Docker、模型加载和临时缓冲的余量。

### 15.1 内存告警线

建议在服务稳定后记录基线：

~~~bash
free -h
grep -E 'MemAvailable|SwapTotal|SwapFree' /proc/meminfo
docker stats --no-stream qwen36-a
~~~

运维建议：

- <code>MemAvailable</code> 长期低于 20GB：黄色告警；
- <code>MemAvailable</code> 长期低于 10GB：停止扩容并排查；
- 稳态持续使用 swap：视为内存不足，不把 swap 当正常容量；
- 内核出现 <code>Out of memory</code> 或容器 <code>OOMKilled=true</code>：立即降低配置或只保留一个实例。

不要为了隐藏问题而创建超大 swap。少量应急 swap 可以保留，但推理稳态不应依赖它。

### 15.2 内存或显存不足时的调整顺序

每次只改一项：

1. 把 <code>--max-num-seqs 16</code> 降为 8；
2. 把 <code>--gpu-memory-utilization 0.90</code> 降为 0.86；
3. 把 <code>--max-model-len 20480</code> 降为 16384；
4. 确认没有第二实例、下载容器或其他大内存进程；
5. 仍然不稳定时，将主机内存升级到 256GB。

## 16. 可选：使用第二张 Duo 卡启动第二副本

这不是首轮部署的必做项。满足以下条件后再做：

- 首实例连续运行并压测至少 24 小时；
- <code>MemAvailable</code> 稳定高于 35–40GB；
- 无持续 swap；
- 已确认物理卡 B 对应 <code>davinci2</code>、<code>davinci3</code>；
- 第二实例必须在第一实例完全启动后再启动。

第二实例命令如下：

~~~bash
install -d -m 750 /data/logs/qwen36-b
export VLLM_IMAGE=quay.io/ascend/vllm-ascend:v0.23.0-310p-openeuler

docker run -d \
  --name qwen36-b \
  --restart unless-stopped \
  --network host \
  --shm-size=10g \
  --log-opt max-size=100m \
  --log-opt max-file=5 \
  --device /dev/davinci2 \
  --device /dev/davinci3 \
  --device /dev/davinci_manager \
  --device /dev/devmm_svm \
  --device /dev/hisi_hdc \
  -v /usr/local/dcmi:/usr/local/dcmi:ro \
  -v /usr/local/sbin/npu-smi:/usr/local/bin/npu-smi:ro \
  -v /usr/local/Ascend/driver/lib64:/usr/local/Ascend/driver/lib64:ro \
  -v /usr/local/Ascend/driver/version.info:/usr/local/Ascend/driver/version.info:ro \
  -v /etc/ascend_install.info:/etc/ascend_install.info:ro \
  -v /data/models/Qwen3.6-35B-A3B-w8a8:/models/Qwen3.6-35B-A3B-w8a8:ro \
  -v /data/logs/qwen36-b:/logs \
  -e ASCEND_RT_VISIBLE_DEVICES=2,3 \
  -e PYTORCH_NPU_ALLOC_CONF=expandable_segments:True \
  -e OMP_NUM_THREADS=1 \
  -e TASK_QUEUE_ENABLE=1 \
  "$VLLM_IMAGE" \
  vllm serve /models/Qwen3.6-35B-A3B-w8a8 \
    --host 127.0.0.1 \
    --port 8081 \
    --tensor-parallel-size 2 \
    --gpu-memory-utilization 0.90 \
    --max-num-seqs 8 \
    --served-model-name qwen3.6 \
    --dtype float16 \
    --additional-config '{"ascend_compilation_config":{"enable_npugraph_ex":false}}' \
    --compilation-config '{"cudagraph_mode":"FULL_DECODE_ONLY","cudagraph_capture_sizes":[1,8]}' \
    --quantization ascend \
    --max-model-len 20480 \
    --no-enable-prefix-caching
~~~

第二实例先从 <code>max-num-seqs=8</code> 开始。两个实例都通过 API 验收后，再由 Nginx、HAProxy 或现有 API 网关在 8080、8081 之间做健康检查和负载均衡。

如果第二实例导致主机进入 swap、OOM 或启动时间异常，立即停止它：

~~~bash
docker stop qwen36-b
~~~

在 128GB 主机上，“一个稳定实例”优先级高于“两个勉强运行的实例”。生产双副本建议把主机内存升级到至少 256GB。

## 17. 外部访问与安全

本教程让 vLLM 只监听回环地址。推荐由已有 API 网关反向代理，并在网关层完成：

- TLS；
- API Key 或统一身份认证；
- 请求体和最大 token 限制；
- 并发限制与排队；
- 超时、熔断和速率限制；
- 审计日志；
- 仅向受信网段开放。

不要把未鉴权的 vLLM 端口直接暴露到互联网。若只是临时内网测试，可将 <code>--host</code> 改为指定的内网地址，并用 firewalld rich rule 只允许受信 CIDR，而不是开放给 <code>0.0.0.0/0</code>。

## 18. 日常运维

~~~bash
# 状态
docker ps --filter name=qwen36
npu-smi info

# 日志
docker logs --tail 200 qwen36-a

# 停止/启动
docker stop qwen36-a
docker start qwen36-a

# 资源
docker stats --no-stream qwen36-a
free -h
swapon --show
df -h /data /var/lib/docker
~~~

升级原则：

1. 不在运行中的容器内 <code>pip install -U</code>；
2. 新镜像使用新 tag/digest；
3. 先停止第二副本或在测试机验证；
4. 核对新 vLLM Ascend、CANN、HDK、模型的完整兼容链；
5. 保留旧镜像 digest 和旧启动参数，确保可回退；
6. 驱动/固件升级属于维护操作，严格按对应版本文档的“固件 → 驱动”升级顺序执行；不要使用首次安装的顺序。

## 19. 常见问题

### 19.1 主机正常、容器内 npu-smi 失败

检查五类挂载和设备节点是否完整：

~~~bash
docker inspect qwen36-a | jq '.[0].HostConfig.Devices, .[0].Mounts'
~~~

不要通过 <code>--privileged</code> 掩盖缺失挂载。Atlas 300I Duo 标准容器路径不需要特权模式。

### 19.2 报 driver/runtime version mismatch

说明主机 HDK 与容器内 CANN 不兼容。回到镜像实际 CANN 版本的 HDK 配套表核对，不要在容器中覆盖 CANN。

### 19.3 报 libatb.so、libascendcl.so 或 Triton 错误

- 确认镜像 tag 结尾是 <code>-310p-openeuler</code>；
- 确认没有在容器中持久化安装过其他 Python/CANN 包；
- 重新使用干净的固定镜像启动；
- Atlas 300I Duo 不支持 Triton/Triton Ascend。

### 19.4 启动时 NPU OOM

按第 15.2 节顺序降配置。还应确认两个目标设备属于同一物理 Duo 卡，并且没有残留进程占用显存：

~~~bash
npu-smi info
docker ps -a
~~~

### 19.5 容器被主机 OOM Kill

~~~bash
docker inspect qwen36-a --format '{{.State.OOMKilled}}'
journalctl -k -g 'Out of memory|Killed process' --since '-1 hour'
~~~

只保留一个实例，顺序加载，关闭不相关的大内存服务。若首实例仍不稳定，升级至 256GB。

### 19.6 API 返回异常重复或精度明显不正常

- 用 <code>temperature=0</code> 做可重复测试；
- 核对模型目录确实是指定 W8A8 revision；
- 核对包含 <code>--quantization ascend</code> 和 <code>--dtype float16</code>；
- 关闭 MTP、prefix caching 和额外采样优化；
- 使用固定小样本做升级前后对比；
- 不要把“服务能返回 200”当作完整精度验收。

## 20. 最终验收清单

- [x] 系统为 openEuler 22.03 LTS SP4 aarch64
- [x] 当前内核与 kernel-devel/kernel-headers 完全匹配
- [ ] HDK 驱动与固件来自 CANN 9.1.0 配套表
- [x] 预装 HDK 驱动和固件已验收，四个逻辑 NPU 均健康
- [x] <code>npu-smi info</code> 显示四个健康逻辑 NPU
- [x] Docker 开机自启
- [ ] 镜像为固定的 <code>v0.23.0-310p-openeuler</code>，已记录 digest
- [x] 模型为 <code>Eco-Tech/Qwen3.6-35B-A3B-w8a8</code>，10 个权重分片和索引完整
- [x] 首实例只占用同一张物理 Duo 卡的 <code>davinci0,1</code>，TP=2
- [x] <code>/health</code>、<code>/v1/models</code>、Chat Completions 和图片输入均通过
- [ ] Compose 双实例、NUMA CPU 亲和与 Nginx 网关通过压力验收
- [ ] 重启容器后可恢复
- [ ] 重启服务器后驱动、Docker、模型服务可恢复
- [ ] 稳态无 swap、无 OOM、无 NPU reset
- [ ] API 未未经鉴权直接暴露到互联网

## 21. 参考资料

- [vLLM Ascend v0.23.0 安装说明](https://docs.vllm.ai/projects/ascend/en/v0.23.0/installation.html)
- [vLLM Ascend v0.23.0：Qwen3.6-35B-A3B 部署教程](https://docs.vllm.ai/projects/ascend/zh-cn/v0.23.0/tutorials/models/Qwen3.6-35B-A3B.html)
- [vLLM Ascend 版本配套策略](https://docs.vllm.ai/projects/ascend/en/latest/community/versioning_policy.html)
- [vLLM Ascend FAQ](https://docs.vllm.ai/projects/ascend/en/latest/faqs.html)
- [CANN 9.1.0 版本说明](https://www.hiascend.com/document/detail/zh/CANNCommunityEdition/910/softwareinst/releasenote/9.1.0/release-notes.md)
- [华为：NPU 驱动与固件安装说明](https://www.hiascend.com/document/detail/en/canncommercial/800/softwareinst/instg/instg_0005.html)
- [昇腾驱动和固件下载中心](https://www.hiascend.com/HARDWARE/firmware-drivers/commercial)
- [Atlas 300I Duo 产品页](https://e.huawei.com/cn/products/computing/ascend/atlas-300i-duo)
- [ModelScope：Qwen3.6-35B-A3B-w8a8](https://www.modelscope.cn/models/Eco-Tech/Qwen3.6-35B-A3B-w8a8)
- [openEuler 22.03 LTS SP4 文档](https://docs.openeuler.org/zh/docs/22.03_LTS_SP4/)

---

此文档的版本链按 2026-08-18 可查询到的官方资料和当前服务器实测输出固定。后续升级时，不应只替换容器 tag，而应重新核对“模型 → vLLM Ascend → vLLM/PyTorch/TorchNPU → CANN → HDK 驱动/固件 → OS/内核”的整条兼容关系。
