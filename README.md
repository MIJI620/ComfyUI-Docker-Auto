# ComfyUI-Docker-Auto

> **ComfyUI** 的 Docker 自动化构建 / 一键体验 / 测试 · 基于较新的 **ComfyUI 0.34.0** 源码
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

- **较新的版本**：基于 `ComfyUI 0.34.0` 源码；GPU 用 `PyTorch 2.13.0 + cu130`，CPU 可一键切换(`COMFYUI_CPU_ONLY=1`)。
- **多阶段镜像**：`local-stage`(用本地源码) / `remote-stage`(在线拉取)，任选。
- **国内网络友好**：
  - base 镜像可切国内源(如 `docker.m.daocloud.io/library/python:3.13-slim`)；
  - PyPI 与 torch 下载源由 `net_lib.sh` 对候选源做**真实 HTTP 200 嗅探自动选取**(官方源仅兜底)，并带超时容错(`NET_LIB_TOTAL_TIMEOUT`)。
- **认证与安全**：预设级 nginx BasicAuth(bcrypt)、每用户并发 `concurrency`、可选 HTTPS、内置 `HEALTHCHECK`。
- **Windows 可视化体验包**：免 Docker 知识，一键修复环境 + 启动 CPU 无认证 ComfyUI，自带黑色命令行面板、CPU/GPU 状态。

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

## 目录结构

```
ComfyUI-Docker-Auto/
├── version info: 基于 ComfyUI 0.34.0 / Python 3.13 / PyTorch+cu130, CPU 可切
├── ComfyUI-docker/        Docker 部署包
├── ComfyUI-experience/    Windows 可视化 Docker 体验包(自带源码)
└── ComfyUI-testkit/       自动化测试包
```

## License / 说明

- 本仓库包含自写的构建/启动/测试脚本与配置(示例哈希等), 部署前请务必阅读各 README 的「注意事项/安全」节(如替换默认 admin 密码哈希)。
- ComfyUI 本体为开源软件, 详见其上游 LICENSE。
