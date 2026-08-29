# ComfyUI-experience —— Docker 体验包

面向**第一次接触 Docker** 的用户：不用懂 Docker，双击即可在这台 Windows 上**自动把 Docker 环境装好**、**一键启动一套 ComfyUI**。

> - 仅支持 **Windows**（依赖 WSL2 + Docker Desktop）。
> - 界面默认预设为 **`cpu-noauth`（CPU、无认证直连）**，即“开箱即用、不弹密码”的最省事模式。
> - 本包带可视化窗口，所有 build/run/修复的日志进入窗口内黑色控制台，**不会**到处弹黑色窗口、也不会乱码。
> - 高端玩法 / 认证 / HTTPS / 并发 / 多实例等，请看 `ComfyUI-docker`（Docker 部署包）的 README，本体验包只保持简单。

---

## 一、怎么开始（三步）

1. **解压本包**到一个路径（路径不要含中文，例如 `D:\ComfyUI-experience`）。
2. **右键 `experience.bat` → 以管理员身份运行**。
3. 在弹出的窗口中：
   - 若顶部显示“环境状态: 就绪(Docker)”，可直接选预设并点 **启动**；
   - 若显示缺失 Docker / WSL，先点 **修复环境**（会自动下载/安装 WSL2 + Docker Desktop 并启动引擎，可能要求重启一次，重启后再运行即可续上）。

启动后，浏览器访问：

```
http://127.0.0.1:<预设端口>
```

默认 `cpu-noauth` 的端口是 **8198**（实际以窗口里该预设的端口为准，见 `app/comfyui.json`）。

想停掉：窗口点 **停止**。

## 二、窗口里都有什么

| 部件 | 作用 |
|---|---|
| 环境状态 | 就绪 / 缺 Docker / 缺 WSL / 缺虚拟化 的提示 |
| 修复环境 | 自动安装/启动 WSL2 + Docker Desktop（幂等，可反复点） |
| 预设下拉 | 切换 gpu / cpu / cpu-noauth / lowvram …（均来自 `app/comfyui.json`） |
| 启动 / 停止 | 构建并启动容器 / 停止并移除容器 |
| 黑色日志面板 | 所有命令输出实时滚动显示（默认黑底绿字，等宽字体） |
| 底部状态栏 | 启动时间 / 累计运行 / CPU 占用 / GPU 占用(%) / 当前状态 |

> 说明：本机没有 NVIDIA 显卡或未装驱动时，GPU 占用会显示 `N/A`（正常现象）。

## 三、它做了什么（底层）

- **环境自举**：`app/setup_docker.ps1` 复用了 TestKit 的 Docker 自举链——检测并安装 WSL2 内核/发行版、安装并启动 Docker Desktop、等待 Docker 引擎就绪。到“环境状态: 就绪”后即可启动容器。
- **构建镜像**：首次启动若镜像缺失，自动 `docker build --target local-stage --build-arg COMFYUI_CPU_ONLY=1`（CPU 镜像），context 使用本包自带 `versions/0.34.0` 源码 + `app/docker`。
- **启动容器**：`docker run --name comfyui-exp -e PRESET=<预设> -p <端口>:<端口> ...`。认证行为由 `entrypoint.sh` 按所选取预设自动决定（`cpu-noauth` 无认证直连，其它预设可能开启 nginx BasicAuth）。

## 四、遇到问题

- **提示需要重启**：这是启用 WSL2/虚拟化后必须做的；重启后再次双击 `experience.bat` 即可（幂等续上）。
- **虚拟化没开（BIOS）**：Docker 必须依赖虚拟化。若提示“缺失虚拟化”，请进 BIOS 开启 VT-x/AMD-V 后再试；实在不行，这台机器跑不了 Docker，请改用 `ComfyUI_windows_portable_nvidia` 便携包（免 Docker 直跑）。
- **下载很慢/失败**：Docker Desktop(~500MB)、WSL MSI、Ubuntu 发行版都会联网下载；若失败，按窗口提示手动下载后用 **修复环境** 重试。
- **默认 admin 密码**：`comfyui.json` 里的 `admin` 是一个**示例哈希**。用于生产/公网前务必替换成你自己的密码哈希（方法见 `ComfyUI-docker` 的 README）。

## 五、高级配置去哪了

本体验包刻意保持“选项最少”。要配置预设、端口、认证、HTTPS、用户并发等，请改用 **`ComfyUI-docker`（Docker 部署包）** 并阅读其 `README.md` / `HELPER.md`。两者共用同一套 `app/docker` 镜像逻辑，配置方式一致。

## 六、目录结构

```
ComfyUI-experience/
├── experience.bat            # 入口(管理员运行)
├── README.md                 # 本说明
├── app/
│   ├── experience.ps1        # 可视化窗口(主程序)
│   ├── setup_docker.ps1      # 环境自举(装/启 Docker)
│   ├── start_comfyui.ps1     # 构建并启动预设容器
│   ├── stop_comfyui.ps1      # 停止容器
│   ├── comfyui.json          # 预设/认证配置
│   ├── docker-compose.yml
│   └── docker/               # 镜像构建(Dockerfile / entrypoint / net_lib …)
└── versions/
    └── 0.34.0/               # ComfyUI 源码(镜像构建用)
```
