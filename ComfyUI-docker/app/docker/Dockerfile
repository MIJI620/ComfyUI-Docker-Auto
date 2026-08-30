# ============================================================================
# ComfyUI Dockerfile (NVIDIA GPU) —— 支持自选版本 + 自选启动方式
#
# 运行配置与 ComfyUI_windows_portable_nvidia (v0.34) 对齐:
#   - Python 3.13
#   - PyTorch 2.13.0 + CUDA 13.0 (cu130)
#
# 构建上下文 = 本目录的父目录(即 ComfyUI-testkit/ 根):
#   根下需存在  versions/<版本名>/  (ComfyUI 源码) 与  app/docker/  (本文件所在)。
#
# 两个完整且自包含的 stage(用 --target 选一即可得到可用镜像):
#   remote-stage : 在线从 GitHub 拉取指定 tag 源码 (需联网; 网慢请勿用于测试)
#   local-stage  : 用本地 versions/<版本名>/ 源码 (离线/测试用, 推荐)
#
# --build-arg COMFYUI_VERSION=版本名/版本号 , 默认 0.34.0
# --build-arg COMFYUI_CPU_ONLY=1          , 构建纯 CPU 镜像(笔记本等无 GPU 用)
#
# 说明: 编写时本地无 Docker, 本文件需用户在装有 Docker 的机器上跑 docker build
#       验证; 纯逻辑(预设/参数/认证配置生成)已由 tests/test_logic.py 验证。
#
# 示例(在 ComfyUI-testkit/ 根目录):
#   docker build --target local-stage \
#     --build-arg COMFYUI_VERSION=0.34.0 --build-arg COMFYUI_CPU_ONLY=1 \
#     -f app/docker/Dockerfile -t comfyui-test .
# ============================================================================

# ================= 公用运行环境 base =================
# BASE_IMAGE lets you build from a registry mirror (e.g. docker.m.daocloud.io/library/python:3.13-slim)
# when docker.io is unreachable.  Pass with:  --build-arg BASE_IMAGE=docker.m.daocloud.io/library/python:3.13-slim
ARG BASE_IMAGE=python:3.13-slim
FROM ${BASE_IMAGE} AS base
ARG COMFYUI_CPU_ONLY=0
ARG COMFYUI_VERSION=0.34.0
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    COMFYUI_VERSION=${COMFYUI_VERSION}
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl gcc g++ libgl1 libgomp1 libglib2.0-0 nginx apache2-utils \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /workspace
RUN python -m venv /workspace/venv
ENV PATH="/workspace/venv/bin:$PATH"

# 把统一网络源选择库拷进镜像。所有下载(PyPI / torch 等)一律用它, 不搞特例。
COPY app/docker/net_lib.sh /usr/local/bin/net_lib.sh
RUN chmod +x /usr/local/bin/net_lib.sh

# ---- 选择 PyPI 源(同一套 pick_first_200 真实嗅探, 见 net_lib.sh) ----
# 对 pip 依赖(requirements.txt / 非 torch 依赖)选一个国内 index 做全局源。
# 探测物 = 三个必需包(torch/torchvision/torchaudio)的 simple 索引页, 全部 HTTP 200 才算该源合法。
# 官方 pypi.org 只作候选列表最后一项兜底, 绝不在代码里硬编码优先。
RUN . /usr/local/bin/net_lib.sh \
 && PICK="$(pick_first_200 "torch/ torchvision/ torchaudio/" \
        "https://pypi.tuna.tsinghua.edu.cn/simple" \
        "https://mirrors.aliyun.com/pypi/simple" \
        "https://mirrors.cloud.tencent.com/pypi/simple" \
        "https://mirrors.ustc.edu.cn/pypi/simple" \
        "https://mirror.sjtu.edu.cn/pypi/web/simple" \
        "https://pypi.org/simple")" \
 && if [ -n "$PICK" ]; then \
      echo "Using PyPI index: $PICK"; \
      pip config set global.index-url "$PICK" && \
      printf 'PIP_INDEX_URL=%s\n' "$PICK" >> /etc/environment && \
      export PIP_INDEX_URL="$PICK"; \
    else \
      echo "WARN: all PyPI candidates failed; using official default"; \
    fi \
 && cat /root/.config/pip/pip.conf 2>/dev/null || true

# torch: 默认 cu130(与服务器一致); COMFYUI_CPU_ONLY=1 时装纯 CPU 版(测试/无GPU)。
# torch/torchvision/torchaudio 的下载源选择与上面 PyPI 选择用【同一套函数 pick_first_200】
# (见 net_lib.sh), 一切以"真实能拿到目标文件"为准(dist 和文件 HTTP 200 才算)。
#   - GPU(cuXXX): 候选为各国内 pytorch-wheels 的 cu130 索引 + 官方 download.pytorch.org 兜底。
#     探测物 = 具体 wheel 文件 URL; 仅当某源能对该文件返回 HTTP 200 才用作 --index-url。
#   - CPU:        torch 的 Linux CPU wheel 走标准 PyPI simple(全局已有国内 index),
#     同样用 pick_first_200 探测 /simple/torch/ 确认该源能解析到包。两条分支共用同一函数。
RUN . /usr/local/bin/net_lib.sh \
 && pip install --upgrade pip setuptools wheel \
 && if [ "${COMFYUI_CPU_ONLY}" = "1" ]; then \
      echo "torch CPU: picking CN PyPI index (pick_first_200 torch+vision+audio pages)" \
      && CPU_IDX="$(pick_first_200 "torch/ torchvision/ torchaudio/" \
          "https://pypi.tuna.tsinghua.edu.cn/simple" \
          "https://mirrors.aliyun.com/pypi/simple" \
          "https://mirrors.cloud.tencent.com/pypi/simple" \
          "https://mirrors.ustc.edu.cn/pypi/simple" \
          "https://pypi.org/simple")" \
      && echo "torch CPU index: ${CPU_IDX:-none}" \
      && pip install --no-cache-dir \
            torch==2.13.0 \
            torchvision==0.28.0 \
            torchaudio==2.11.0 \
            ${CPU_IDX:+--index-url "$CPU_IDX"}; \
    else \
      echo "torch CUDA: probing cu130 sources by TYPE + SPEED (pick_torch_source)..." \
      && TORCH_SRC="$(pick_torch_source \
            "torch-2.13.0%2Bcu130-cp313-cp313-manylinux_2_28_x86_64.whl torchvision-0.28.0%2Bcu130-cp313-cp313-manylinux_2_28_x86_64.whl torchaudio-2.11.0%2Bcu130-cp313-cp313-manylinux_2_28_x86_64.whl" \
            "torch/" 2097152 \
          "https://mirror.sjtu.edu.cn/pytorch-wheels/cu130" \
          "https://mirrors.aliyun.com/pytorch-wheels/cu130" \
          "https://download.pytorch.org/whl/cu130")" \
      && SRC_TYPE="$(printf '%s\n' "$TORCH_SRC" | sed -n 1p)" \
      && SRC="$(printf '%s\n' "$TORCH_SRC" | sed -n 2p)" \
      && echo "torch CUDA source: type=${SRC_TYPE:-none} base=${SRC:-none}" \
      && DEP_IDX="$(pick_first_200 "torch/ torchvision/ torchaudio/" \
            "https://pypi.tuna.tsinghua.edu.cn/simple" \
            "https://mirrors.aliyun.com/pypi/simple" \
            "https://mirrors.cloud.tencent.com/pypi/simple" \
            "https://mirrors.ustc.edu.cn/pypi/simple" \
            "https://pypi.org/simple")" \
      && DEP_IDX="${DEP_IDX:-https://pypi.org/simple}" \
      && if [ "$SRC_TYPE" = "simple" ]; then \
           echo "torch CUDA: use --index-url (simple)" \
           && pip install --no-cache-dir \
                torch==2.13.0+cu130 torchvision==0.28.0+cu130 torchaudio==2.11.0+cu130 \
                --index-url "$SRC"; \
         elif [ "$SRC_TYPE" = "flat" ]; then \
           echo "torch CUDA: flat source -> direct wheel URLs ($SRC), deps from $DEP_IDX" \
           && pip install --no-cache-dir \
                "$SRC/torch-2.13.0%2Bcu130-cp313-cp313-manylinux_2_28_x86_64.whl" \
                "$SRC/torchvision-0.28.0%2Bcu130-cp313-cp313-manylinux_2_28_x86_64.whl" \
                "$SRC/torchaudio-2.11.0%2Bcu130-cp313-cp313-manylinux_2_28_x86_64.whl" \
                --index-url "$DEP_IDX"; \
         else \
           echo "WARN: no cu130 source reachable; trying official simple" \
           && pip install --no-cache-dir \
                torch==2.13.0+cu130 torchvision==0.28.0+cu130 torchaudio==2.11.0+cu130 \
                --index-url https://download.pytorch.org/whl/cu130; \
         fi; \
    fi

# ================= local-stage : 用本地源码 =================
FROM base AS local-stage
ARG COMFYUI_VERSION=0.34.0
COPY versions/${COMFYUI_VERSION}/ /workspace/comfyui
# 安装 ComfyUI 其余依赖(注意: source 里 requirements.txt 不在 COPY 路径时也兼容)
RUN pip install -r /workspace/comfyui/requirements.txt

# ---- 启动参数 & 安全加固 & 反代认证(内嵌到本 stage) ----
COPY app/docker/resolve_preset.py /usr/local/bin/resolve_preset.py
COPY app/docker/gen_auth.py      /usr/local/bin/gen_auth.py
COPY app/docker/entrypoint.sh    /entrypoint.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/resolve_preset.py /usr/local/bin/gen_auth.py \
 && useradd --create-home --uid 1000 comfyui \
 && mkdir -p /config \
            /workspace/comfyui/models /workspace/comfyui/input \
            /workspace/comfyui/output /workspace/comfyui/user \
            /var/cache/nginx /var/log/nginx /run/nginx /var/lib/nginx \
 && chown -R comfyui:comfyui /workspace/comfyui \
 && chown -R comfyui:comfyui /var/cache/nginx /var/log/nginx /run/nginx /var/lib/nginx 2>/dev/null || true
ENV COMFYUI_SOURCE=local
WORKDIR /workspace/comfyui
# 健康检查: 探 ComfyUI 本体(127.0.0.1:8188)或对外端口(EXPOSE_PORT/preset.port 兜底 8189)。
# start-period=300s 覆盖 CPU 慢速首载; curl 由 base stage apt 装好。
HEALTHCHECK --interval=30s --timeout=10s --start-period=300s --retries=3 \
  CMD bash -c "curl -fs -o /dev/null http://127.0.0.1:8188/ || curl -fs -o /dev/null http://127.0.0.1:\${EXPOSE_PORT:-8189}/ || exit 1"
EXPOSE 8188
USER comfyui
ENTRYPOINT ["/entrypoint.sh"]

# ================= remote-stage : 在线拉取指定 tag (需联网) =================
FROM base AS remote-stage
ARG COMFYUI_VERSION=0.34.0
RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/* \
    && git clone --depth 1 --branch "v${COMFYUI_VERSION}" \
         https://github.com/Comfy-Org/ComfyUI.git /workspace/comfyui
RUN pip install -r /workspace/comfyui/requirements.txt

# ---- 启动参数 & 安全加固 & 反代认证(内嵌到本 stage) ----
COPY app/docker/resolve_preset.py /usr/local/bin/resolve_preset.py
COPY app/docker/gen_auth.py      /usr/local/bin/gen_auth.py
COPY app/docker/entrypoint.sh    /entrypoint.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/resolve_preset.py /usr/local/bin/gen_auth.py \
 && useradd --create-home --uid 1000 comfyui \
 && mkdir -p /config \
            /workspace/comfyui/models /workspace/comfyui/input \
            /workspace/comfyui/output /workspace/comfyui/user \
            /var/cache/nginx /var/log/nginx /run/nginx /var/lib/nginx \
 && chown -R comfyui:comfyui /workspace/comfyui \
 && chown -R comfyui:comfyui /var/cache/nginx /var/log/nginx /run/nginx /var/lib/nginx 2>/dev/null || true
ENV COMFYUI_SOURCE=remote
WORKDIR /workspace/comfyui
# 健康检查: 探 ComfyUI 本体(127.0.0.1:8188)或对外端口(EXPOSE_PORT/preset.port 兜底 8189)。
HEALTHCHECK --interval=30s --timeout=10s --start-period=300s --retries=3 \
  CMD bash -c "curl -fs -o /dev/null http://127.0.0.1:8188/ || curl -fs -o /dev/null http://127.0.0.1:\${EXPOSE_PORT:-8189}/ || exit 1"
EXPOSE 8188
USER comfyui
ENTRYPOINT ["/entrypoint.sh"]
