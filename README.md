# openEuler 22.03 LTS SP4 + Atlas 300I Duo 部署 Qwen3.6-35B-A3B-W8A8

> 文档基线：2026-08-12
>
> 目标硬件：鲲鹏 920、Atlas 300I Duo 96GB × 2、主机内存 128GB
>
> 目标服务：OpenAI 兼容 API，模型 <code>Eco-Tech/Qwen3.6-35B-A3B-w8a8</code>

本文从一台刚安装完 openEuler 22.03 LTS SP4 的服务器开始，完成系统检查、Atlas 驱动与固件、Docker、模型权重以及 vLLM Ascend 服务部署。

## 1. 最终方案

采用以下版本固定组合：

| 层级 | 选型 |
|---|---|
| 主机系统 | openEuler 22.03 LTS SP4，aarch64 |
| 主机侧昇腾软件 | 与该 310P 镜像所带 CANN 平台版本配套的 Ascend HDK 驱动和固件 |
| 容器 | Docker |
| 推理镜像 | <code>quay.io/ascend/vllm-ascend:v0.23.0rc1-310p-openeuler</code> |
| 容器内软件 | 由镜像整体锁定；vLLM 0.23.0、vLLM Ascend 0.23.0rc1，CANN/TorchNPU 以镜像实测输出为准 |
| 模型 | <code>Eco-Tech/Qwen3.6-35B-A3B-w8a8</code> |
| 首实例 | 一张物理 Atlas 300I Duo 的两个 310P 芯片，TP=2 |
| API | 仅监听 <code>127.0.0.1:8080</code>，外部访问交给反向代理或 API 网关 |

Atlas 300I Duo 每张物理卡包含两个 Ascend 310P 芯片，96GB 是整张卡的总显存。两张物理卡通常会形成四个逻辑 NPU 设备。首次部署只使用同一张物理卡上的两个芯片；第一实例连续稳定运行后，再考虑用另一张卡启动第二副本。

128GB 主机内存可以部署首实例，但余量不宽裕。因此本教程：

- 不使用 CPU offload；
- 不同时加载两个实例；
- 使用 W8A8 权重；
- 初始上下文固定为 20,480 token；
- 初始最大活跃序列数为 16，若出现主机或 NPU 内存压力则先降到 8；
- 默认关闭前缀缓存和 MTP 推测解码。

注意：<code>v0.23.0rc1</code> 是 release candidate，且是该系列首次明确加入 310P 上 Qwen3.5/Qwen3.6 支持的版本。当前方案是这套硬件运行目标模型的最佳官方路径，但仍应按生产前候选版本进行至少 24 小时稳定性、精度和压力验收，不能把“成功启动”视为生产验收完成。

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

## 3. 安装前准备

所有命令均在服务器上执行。先切换到 root：

~~~bash
sudo -i
~~~

### 3.1 核对系统、CPU、内存和磁盘

~~~bash
uname -m
uname -r
cat /etc/os-release
lscpu
free -h
swapon --show
df -hT
~~~

必须确认：

- <code>uname -m</code> 输出 <code>aarch64</code>；
- 系统是 openEuler 22.03 LTS SP4；
- 物理内存约 128GB；
- 用于 Docker 和模型的本地磁盘至少空闲 150GB，推荐 500GB 以上；
- 模型目录最好位于本地 NVMe，不要使用低速网络盘。

后文使用 <code>/data</code> 保存权重和日志。如果实际数据盘挂载点不同，请统一替换路径。

### 3.2 核对两张加速卡

~~~bash
lspci -nn | grep -i -E 'Huawei|19e5|Ascend'
lspci -tv
~~~

这里不以 <code>lspci</code> 行数判断 NPU 数量，因为一张卡可能暴露多个 PCIe 功能。只要两张物理卡都能在 PCIe 拓扑中识别即可；逻辑 NPU 数量在驱动安装后用 <code>npu-smi</code> 确认。

### 3.3 记录当前状态

~~~bash
mkdir -p /var/log/ascend-install
uname -a > /var/log/ascend-install/uname-before.txt
lspci -nn > /var/log/ascend-install/lspci-before.txt
free -h > /var/log/ascend-install/memory-before.txt
~~~

## 4. 获取正确的驱动与固件

打开以下两个官方页面：

- [CANN 9.1.0 版本说明与 HDK 配套关系](https://www.hiascend.com/document/detail/zh/CANNCommunityEdition/910/softwareinst/releasenote/9.1.0/release-notes.md)
- [昇腾商用驱动和固件下载](https://www.hiascend.com/HARDWARE/firmware-drivers/commercial)

还应使用服务器整机厂商提供的兼容性清单，或华为计算产品兼容性查询，核对 openEuler 22.03 LTS SP4 与当前内核。

下载以下 aarch64 安装包及其签名/校验文件：

~~~text
Ascend-hdk-310p-npu-driver_<配套版本>_linux-aarch64.run
Ascend-hdk-310p-npu-firmware_<配套版本>.run
~~~

将文件上传到 <code>/opt/ascend-hdk</code>。为了让后续命令可复制，可以在确认目录中只有一份驱动和一份固件后，将它们分别命名为：

~~~text
/opt/ascend-hdk/driver.run
/opt/ascend-hdk/firmware.run
~~~

不要用通配符自动重命名。如果目录中存在多个版本，先移走旧包。

## 5. 安装主机依赖

### 5.1 检查软件源

~~~bash
dnf makecache
~~~

如果失败，先修复 openEuler 22.03 LTS SP4 软件源和 DNS，不要继续。

### 5.2 安装驱动编译依赖和运维工具

~~~bash
dnf install -y \
  make \
  dkms \
  gcc \
  gcc-c++ \
  kernel-headers-$(uname -r) \
  kernel-devel-$(uname -r) \
  pciutils \
  numactl \
  curl \
  wget \
  jq \
  tar \
  gzip \
  lsof
~~~

验证运行内核与开发包完全匹配：

~~~bash
rpm -q kernel-headers-$(uname -r)
rpm -q kernel-devel-$(uname -r)
test -e /lib/modules/$(uname -r)/build
gcc --version
dkms --version
~~~

三个检查都必须成功。若仓库没有当前内核的 <code>kernel-devel</code>：

1. 不要安装一个不同版本的开发包；
2. 启用与当前 SP4 内核对应的软件仓库，或从 openEuler 官方仓库取得完全相同版本 RPM；
3. 如果决定升级内核，应把 kernel、kernel-devel、kernel-headers 一起升级并重启；
4. 重启后重新执行本节检查，再安装 NPU 驱动。

## 6. 安装 Atlas 驱动与固件

以下是“系统中尚未安装驱动”的首次安装流程。若 <code>npu-smi info</code> 已经能返回信息，这属于覆盖安装或升级，安装顺序和参数不同，应改用对应 HDK 版本的升级文档，不要直接套用本节。

### 6.1 检查安装包

~~~bash
cd /opt/ascend-hdk
ls -lh driver.run firmware.run
chmod 500 driver.run firmware.run
./driver.run --check
./firmware.run --check
sha256sum driver.run firmware.run
~~~

<code>--check</code> 必须显示归档完整性和 SHA256 校验通过。还要把 <code>sha256sum</code> 输出与下载页提供的值对比并保存：

~~~bash
sha256sum driver.run firmware.run > /var/log/ascend-install/hdk-sha256.txt
~~~

### 6.2 首次安装

首次安装顺序是“驱动 → 固件”：

~~~bash
cd /opt/ascend-hdk
./driver.run --full --install-for-all
./firmware.run --full
~~~

两条命令都必须明确显示安装成功。随后重启：

~~~bash
reboot
~~~

不要在安装完成但尚未重启时安装 Docker 推理服务。

### 6.3 驱动验收

重连服务器后：

~~~bash
sudo -i
npu-smi info
cat /usr/local/Ascend/driver/version.info
cat /etc/ascend_install.info
ls -l /dev/davinci* /dev/davinci_manager /dev/devmm_svm /dev/hisi_hdc
dmesg -T | grep -i -E 'ascend|davinci|hisi_hdc|devmm' | tail -n 100
~~~

在当前硬件上，通常应看到四个逻辑 NPU，例如 <code>/dev/davinci0</code> 至 <code>/dev/davinci3</code>，且所有设备健康。以下任一情况都应先停止部署并修复：

- 只能看到两个而不是四个逻辑 NPU；
- <code>npu-smi</code> 报错或设备 Health 不正常；
- 缺少管理设备节点；
- 内核日志存在反复 reset、PCIe AER、SMMU 或固件错误；
- 驱动版本不在所用镜像实际 CANN 版本的 HDK 配套表中。

保存验收信息：

~~~bash
npu-smi info > /var/log/ascend-install/npu-smi-after.txt
lspci -nn > /var/log/ascend-install/lspci-after.txt
~~~

## 7. 安装 Docker

openEuler 22.03 LTS SP4 可直接安装发行版 Docker 包：

~~~bash
dnf install -y docker
systemctl enable --now docker
docker version
docker info
~~~

创建目录：

~~~bash
install -d -m 750 /data/models
install -d -m 750 /data/logs/qwen36-a
df -h /data /var/lib/docker
~~~

如果 <code>/var/lib/docker</code> 所在分区空间不足，应在拉取镜像前，把 Docker data-root 迁移到容量充足的本地磁盘。不要等磁盘写满后再迁移。

## 8. 拉取并固定推理镜像

本教程固定使用 openEuler + 310P 专用镜像：

~~~bash
export VLLM_IMAGE=quay.io/ascend/vllm-ascend:v0.23.0rc1-310p-openeuler
docker pull "$VLLM_IMAGE"
docker image inspect "$VLLM_IMAGE" \
  --format '{{index .RepoDigests 0}}' \
  | tee /var/log/ascend-install/vllm-image-digest.txt
~~~

不要使用 <code>latest</code>，也不要使用 A2/A3 或 Ubuntu 镜像。Atlas 300I Duo 不支持 Triton；310P 专用镜像已经按该平台处理依赖。

若中国大陆网络无法直接访问 Quay，可按 vLLM Ascend FAQ 使用镜像代理，例如：

~~~bash
export VLLM_IMAGE=m.daocloud.io/quay.io/ascend/vllm-ascend:v0.23.0rc1-310p-openeuler
docker pull "$VLLM_IMAGE"
~~~

使用镜像代理时同样记录 RepoDigest。正式环境应将通过测试的镜像同步到内部镜像仓库，并按 digest 固定。

## 9. 容器内 NPU 预检

先只映射计划用于首实例的两个 NPU。以下命令暂定 <code>davinci0</code> 和 <code>davinci1</code> 属于同一张物理 Duo 卡；第 11 节启动前必须确认这一点。

~~~bash
export VLLM_IMAGE=quay.io/ascend/vllm-ascend:v0.23.0rc1-310p-openeuler

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
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi:ro \
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
export VLLM_IMAGE=quay.io/ascend/vllm-ascend:v0.23.0rc1-310p-openeuler

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

## 11. 确认物理卡与逻辑设备对应关系

每个服务实例必须使用同一张物理 Atlas 300I Duo 上的两个 310P 芯片。通常第一张卡对应逻辑设备 0、1，第二张卡对应 2、3，但不能只凭编号假设。

结合以下信息确认设备的 PCIe Bus-Id 和槽位归属：

~~~bash
npu-smi info
lspci -tv
lspci -nn
~~~

必要时通过服务器 BMC、整机厂商 PCIe 槽位映射表或华为运维工具确认。后文假定：

~~~text
物理卡 A：/dev/davinci0、/dev/davinci1
物理卡 B：/dev/davinci2、/dev/davinci3
~~~

如果实际映射不同，必须同步修改 <code>--device</code> 和 <code>ASCEND_RT_VISIBLE_DEVICES</code>。

## 12. 启动 Qwen3.6 首实例

以下参数是 Atlas 300I Duo 的稳健起点，并与 vLLM Ascend v0.23.0 官方模型教程保持一致。

~~~bash
export VLLM_IMAGE=quay.io/ascend/vllm-ascend:v0.23.0rc1-310p-openeuler

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
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi:ro \
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
export VLLM_IMAGE=quay.io/ascend/vllm-ascend:v0.23.0rc1-310p-openeuler

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
  -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi:ro \
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

- [ ] 系统为 openEuler 22.03 LTS SP4 aarch64
- [ ] 当前内核与 kernel-devel/kernel-headers 完全匹配
- [ ] HDK 驱动与固件来自 CANN 9.1.0 配套表
- [ ] 首次安装按“驱动 → 固件”完成并重启
- [ ] <code>npu-smi info</code> 显示四个健康逻辑 NPU
- [ ] Docker 开机自启
- [ ] 镜像为固定的 <code>v0.23.0rc1-310p-openeuler</code>，已记录 digest
- [ ] 模型为 <code>Eco-Tech/Qwen3.6-35B-A3B-w8a8</code>，已记录文件清单/revision
- [ ] 首实例只占用同一张物理 Duo 卡的两个芯片
- [ ] <code>/health</code>、<code>/v1/models</code>、Completions、Chat Completions 均通过
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

此文档的版本链按 2026-08-12 可查询到的官方资料固定。后续升级时，不应只替换容器 tag，而应重新核对“模型 → vLLM Ascend → vLLM/PyTorch/TorchNPU → CANN → HDK 驱动/固件 → OS/内核”的整条兼容关系。
