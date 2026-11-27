# ComfyUI-Docker-Auto

> **ComfyUI** 的 Docker 自动化构建 / 一键体验 / 测试 · 基于较新的 **ComfyUI 0.46.2** 源码
> 支持 **NVIDIA GPU(cu130)** 与 **CPU** 双平台 · **国内网络友好**(base 镜像 + torch 源自动嗅探选国内)
> 附带 **Windows 可视化体验包**(WiFi 一键装 Docker + 启动 ComfyUI CPU 无认证)

如果你在找 **ComfyUI 的 Docker 镜像 / Dockerfile / 一键部署**，这个仓库是较新的版本，且已针对国内网络做了开箱即用的适配。

---

## 这是什么

一个包含三个子项目的仓库，覆盖 ComfyUI 从"容器化构建"到"新手一键使用"再到"自动化测试"：

| 子项目 | 定位 |
|---|---|
| **`ComfyUI-docker`** | Docker 部署包：多阶段镜像(Dockerfile) + 预设启动 + nginx BasicAuth 认证 + 可选 HTTPS + 每用户并发 + HEALTHCHECK。给服务器/正常部署用。 |
| **`ComfyUI-experience`** | **Docker 体验包**(Windows)：可视化窗口一键装好 WSL2/Docker Desktop、一键启动 ComfyUI(默认 CPU 无认证)。给第一次接触 Docker 的人用。自带 0.34 源码，开箱即构建。 |
| **`ComfyUI-testkit`** | 测试包：在装有 Docker 的机器上自动化跑完 build/启动/HTTP/认证/preset 全流程(7 阶段)，含不依赖 Docker 的纯逻辑测试。 |

三者共用同一套 `app/docker/*` 镜像逻辑(Dockerfile / entrypoint.sh / gen_auth.py / net_lib.sh / resolve_preset.py)，**配置与行为一致**。

## 亮点 / 特性

- **较新的版本**：基于 `ComfyUI 0.46.2` 源码；GPU 用 `PyTorch 2.13.0 + cu130`，CPU 可一键切换(`COMFYUI_CPU_ONLY=1`)。
- **多阶段镜像**：`local-stage`(用本地源码) / `remote-stage`(在线拉取)，任选。
- **国内网络友好**：
  - base 镜像可切国内源(如 `docker.m.daocloud.io/library/python:3.13-slim`)；
  - torch / cu130 下载由 `net_lib.sh` **自动判断源类型**(simple 索引 vs flat 目录) 并**按真实下载反馈速度择优**：flat 用精确 wheel 直链、simple 用 `--index-url`，国内优先、官方兜底；带超时容错(`NET_LIB_TOTAL_TIMEOUT`)。
- **认证与安全**：预设级 nginx BasicAuth(bcrypt)、每用户并发 `concurrency`（仅限制任务/写类请求，查询轮询、WebSocket 与静态资源均不受限，避免卡浏览器页面加载）、可选 HTTPS、内置 `HEALTHCHECK`。
- **Windows 可视化体验包**：免 Docker 知识，一键修复环境 + 启动 CPU 无认证 ComfyUI，自带黑色命令行面板、CPU/GPU 状态。
- **构建下载不重复 + 记录默认持久**：wheel 哈希缓存（`wheel_cache.py`）让同版本二次构建纯离线；`--enable-assets` 默认开启（预设 args 自带 + entrypoint 强制兜底），任务/图片历史重启不丢。

## 快速开始

### 靠 Docker 部署(server)
```bash
cd ComfyUI-docker
docker compose up -d --build      # 或按 README 用 remote/local 构建
# 访问 http://<服务器IP>:8189
```
> 见 `ComfyUI-docker/README.md`(端口/认证/HTTPS/并发)。

### 新手一键体验(Windows)
```bash
# 解压 ComfyUI-experience, 右键 experience.bat -> 以管理员身份运行
# 点「修复环境」→ 选预设 → 点「启动」, 浏览器开 http://127.0.0.1:<预设端口>
```
> 见 `ComfyUI-experience/README.md`。

### 自动化测试
```bash
cd ComfyUI-testkit
run_test.bat        # 管理员运行, 7 阶段自动化测试
```
> 也有 `app/tests/test_logic.py`(不依赖 Docker, 开发机可跑)。

## 关于 ComfyUI 源码

- `ComfyUI-experience` **自带** `versions/0.34.0` 源码，保证开箱即构建。
- `ComfyUI-docker` / `ComfyUI-testkit` **不内置源码**：构建时用 `--target remote-stage` 在线拉取，或(用 `local-stage` 时)把对应版本源码放到各自的 `versions/<版本>/`。详见各自 README。

## 增量构建：网络源缓存优先(net_lib.sh, 可选)

`app/docker/net_lib.sh` 负责构建时下载的**源选择**（pick_first_200 选 PyPI index、pick_torch_source 选 cu130 torch 源）。默认它每次真实嗅探(HTTP 200 / 测速)挑当次最快源——这正是"这次命中上交大、下次又因网络改挑阿里"的来源。

新增可选机制：**把"上次命中且产物已在缓存"的源 pin 住**。启用后若目标版本一致且在本地缓存中，探测会**直接沿用上次命中的源、跳过网络探测**，不再因源漂移而重复下载。默认关闭，行为与旧版完全一致。

启用(构建级, 例如 Dockerfile 对应下载 RUN 前加两个 ENV)：
```
ENV NETLIB_TRUST_PIN=1  NETLIB_PIN_FILE=/usr/local/etc/netlib_source_pin
```
当次首跑会真实探测并把这个源写入 `NETLIB_PIN_FILE`；此后该层若是祖先层并在本地缓存命中，后续重建直接复用该源。前提是产物确实由那份缓存供应；不确定时请保持关闭(默认 0)。这一机制在三包 Dockerfile 注释各有示例；改动同样同步到 `ComfyUI-docker / ComfyUI-testkit / ComfyUI-experience` 三份 `app/docker/*`。

## 构建下载缓存：哈希权威（wheel_cache.py，默认开启）

`app/docker/wheel_cache.py` 把 torch / requirements 的**下载产物**按哈希缓存：同版本二次构建**只离线安装、绝不重新下载**——判定只看哈希，不看网络通不通、也不依赖 Docker 层缓存是否失效：
- 下载完成 → 立刻 `ingest` **同步**计算 sha256 写清单（`.manifests/<KEY>.sha256`）；
- 之后每次构建先 `ensure` 对本地缓存文件**实算哈希**与清单逐行对照：全部一致 → `pip install --no-index --find-links=缓存` 纯离线；哈希不同（损坏/不完整）或缓存不可用 → 才联网**回填一次**，回填完立刻 ingest，此后永远命中。
- KEY 含版本号（如 `torch-cu130-2.13.0-0.28.0-2.11.0`、`req-comfyui-0.46.2`），升级版本自动成新条目。
- 缓存落在**构建机的 Docker 引擎（BuildKit cache）**，不在项目目录、也不进镜像/容器；`docker builder prune -a` / `docker system prune -a` 会清掉它。
- 前提：构建需 BuildKit（现代 docker/compose 默认；老引擎 `DOCKER_BUILDKIT=1`）。详见 `ComfyUI-docker/README.md`「下载产物哈希缓存」。

用户资产/任务记录（`--enable-assets`）同为**默认开启**（内置预设 args 自带 + entrypoint 最终参数强制兜底），重启/重建不再丢任务与图片历史；区别开 `--enable-asset-hashing`（blake3 去重，默认关）。

## 自动打包(重新产出分发包)

三个子项目分别各有一套 `.zip` 分发包（`ComfyUI-docker.zip / ComfyUI-experience.zip / ComfyUI-testkit.zip`），
放在**仓库根目录**，内容 = 对应源目录的完整快照（`make_release.py` 会包含源里当前最新的改动，如本次的 nginx 请求体上限修复）。

手动改动源目录后，需要同步 zip 时直接执行：

```
python make_release.py            # 三套都重打并自验
python make_release.py ComfyUI-docker   # 只打 docker(参数用完整子目录名)
build_release.bat [ComfyUI-...]   # Windows 便捷入口(仓库根目录)
```

行为说明(README 承诺，都在 make_release.py 内)：
- **自动排除**：不打包 `.pyc`/`__pycache__`、日志 `.log`、模型权重(`.safetensors/.ckpt/.pt/.pth/.onnx`)等易错/体积项（与仓库根 `.gitignore` 排除口径一致；`versions/` 下的源码与 README/.gitignore 均会打入）。
- **自动产出 + 安全覆盖**：先写 `<name>.zip` 的临时文件 →做**全量自验**(zip 可读、逐条 `testzip()` CRC 无坏、文件集合与源目录逐字全同) → 全通过才原子替换正式包；自验失败则返回非 0 且**不覆盖**旧正式包，避免留下中断/半写残缺档（那种档会出现体积异常、甚至非 zip）。
- **包形态**：每层 = 源子目录内容、不含父目录前缀；显式保存目录占位条目(与历史发布 entries 数一致)。输出 zip 为源的最新快照。

## 目录结构

```
ComfyUI-Docker-Auto/
├── version info: 基于 ComfyUI 0.46.2 / Python 3.13 / PyTorch+cu130, CPU 可切
├── ComfyUI-docker/        Docker 部署包
├── ComfyUI-experience/    Windows 可视化 Docker 体验包(自带源码)
├── ComfyUI-testkit/       自动化测试包
├── make_release.py        自动产出 .zip 分发包(用法见上「自动打包」)
├── build_release.bat      Windows 便捷入口(等价 make_release.py)
├── ComfyUI-docker.zip     由 make_release.py 产生(若不在则由上再生成)
├── ComfyUI-experience.zip ...
└── ComfyUI-testkit.zip ...
```
> 注：`.zip` 为派生产物, 由 `make_release.py` 生成; 直接在某个子目录改完源码后运行一次即可得到同步压缩包。

## License / 说明

- 本仓库包含自写的构建/启动/测试脚本与配置(示例哈希等), 部署前请务必阅读各 README 的「注意事项/安全」节(如替换默认 admin 密码哈希)。
- ComfyUI 本体为开源软件, 详见其上游 LICENSE。
