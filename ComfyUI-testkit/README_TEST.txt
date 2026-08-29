========================================
 ComfyUI TestKit — 笔记本预发布测试包
========================================

一、这是什么
    在 你的笔记本(Windows 11) 上，自动完成：
      1. 检测 / 安装 Docker Desktop(含 WSL2 启用)
      2. 用本地源码(versions/0.34.0) 构建 ComfyUI 镜像(纯 CPU 版，不依赖独立显卡)
      3. 以 CPU 模式启动 ComfyUI
      4. 验证：
         - HTTP 页面可访问
         - Nginx BasicAuth(用户名密码认证，401/放行)
         - 预设切换(gpu/cpu/lowvram/gpu-public)
    每项结果都会写入同目录的 log.txt。

二、怎么用
    1. 把本压缩包解压到一个方便的位置(路径可含中文，但建议短一些)。
    2. 进入解压后的 ComfyUI-testkit 文件夹。
    3. 右键 “run_test.bat” → “以管理员身份运行”。
    4. 若弹出 UAC 授权，点“是”。
    5. 首次运行时若检测到没有 Docker：
         - 脚本会用 winget 自动安装 Docker Desktop
         - 并启用 WSL2 / 虚拟机平台
         - 屏幕会提示你需要【重启电脑】
       【重启后，再次双击 run_test.bat】继续完成构建和测试。
    6. 测试结束后，把同目录的 “log.txt” 发给开发者。

三、进度反馈(新增)
    脚本每一步都会显示状态和时间，方便你知道它卡在哪：
      [STEP:xxx] [NOT_STARTED]   尚未开始
      [STEP:xxx] [RUNNING]       正在下载/执行中
      [STEP:xxx] [SUCCESS]       成功
      [STEP:xxx] [FAILED]        失败(失败时会附带输出尾部，便于排障)
      [STEP:docker-install] [REBOOT]   已装好 Docker，需要重启后重跑
    首次安装 Docker / 首次构建镜像(拉取基础镜像+torch)会较长，
    请观察控制台的 [RUNNING] 与下载进度确认它在动，不要中途关闭窗口。

四、注意事项
    - 本测试【不做】“从 GitHub 在线拉取 ComfyUI 源码”的测试(网慢)，
      一律使用本地自带的源代码(versions/0.34.0)。
    - GPU 推理不会在笔记本上测(笔记本无 NVIDIA 独立显卡)，
      这部分留到服务器(A5000 24GB)上验证。
    - 测试端口用 8189，避免和你其它服务冲突。
    - 默认账号/密码在 app/comfyui.json 的 auth.users 里：admin / CHANGE_ME_admin
      (这仅用于测试端口锁定；部署到服务器时请务必改成强密码)

五、目录结构
    ComfyUI-testkit/
    ├── run_test.bat             ← 双击运行(管理员)
    ├── app/
    │   ├── run_test.ps1         ← 主测试脚本(由 bat 调用)
    │   ├── docker/Dockerfile、entrypoint.sh、resolve_preset.py、gen_auth.py
    │   ├── comfyui.json         ← 启动预设表(access/resources/auth)
    │   ├── docker-compose.yml
    │   └── tests/test_logic.py  ← 不依赖 Docker 的纯逻辑测试(已通过)
    └── versions/0.34.0/         ← 预置的 ComfyUI 源码(供 local 构建)
