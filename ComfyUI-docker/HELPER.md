# ComfyUI-Docker —— 命令速查（复制粘贴即可）

> 完整说明见 `README.md`。
> **当前目录约定**：`docker build` 用 `docker run` 在“包含 ComfyUI-docker/ 的上级根目录”；`docker compose` 在 `ComfyUI-docker/` 目录内。

## 一、构建镜像

在触发命令前，先统一：
```bash
cd "你的根目录"        # 含 ComfyUI-docker/ 的上级根
```

### GPU / 默认，本地源码（local-stage，服务器推荐）
```bash
docker build --target local-stage \
  --build-arg COMFYUI_VERSION=0.34.0 \
  --build-arg BASE_IMAGE=docker.m.daocloud.io/library/python:3.13-slim \
  -f ComfyUI-docker/app/docker/Dockerfile -t comfyui-docker:latest .
```
> 构建日志应出现 `torch CUDA index: https://mirrors.aliyun.com/pytorch-wheels/cu130`（torch 走阿里云国内源，不可达才回退官方；PyPI 与 torch 源都由 `net_lib.sh` 的 `pick_first_200` 真实嗅探自动选取）。
> 超时可调：构建前 `export NET_LIB_TOTAL_TIMEOUT=10`（默认 20s）或 `NET_LIB_CONNECT_TIMEOUT`。

### CPU（无独显 / 测试）
```bash
docker build --target local-stage \
  --build-arg COMFYUI_VERSION=0.34.0 --build-arg COMFYUI_CPU_ONLY=1 \
  --build-arg BASE_IMAGE=docker.m.daocloud.io/library/python:3.13-slim \
  -f ComfyUI-docker/app/docker/Dockerfile -t comfyui-test:cpu .
```

### 在线拉取源码（remote-stage，需访问 GitHub）
```bash
docker build --target remote-stage --build-arg COMFYUI_VERSION=0.34.0 \
  -f ComfyUI-docker/app/docker/Dockerfile -t comfyui-docker:latest .
```

## 二、生成用户的 bcrypt 密码哈希（认证用）
```bash
docker run --rm comfyui-docker:latest htpasswd -nbB admin '<你的密码>'
# 输出: admin:$2y$05$... → 把 $2y$... 那段贴进 comfyui.json 该用户的 "hash"
```
> ⚠️ 部署前必须替换 comfyui.json 里默认的 `admin` hash。

## 三、启动容器

> 端口 = `EXPOSE_PORT` 或选中预设的 `port`（不是 8188）。`-p/-ports` 必须与之一致。

### GPU + 认证 + 共享模型库（默认 preset=gpu，对外 8189）
```bash
cd "你的根目录"
docker run -d --name comfyui \
  --gpus all -m 16g \
  -e PRESET=gpu \
  -e EXPOSE_PORT=8189 \
  -v /path/to/models:/workspace/comfyui/models \
  -v $PWD/ComfyUI-docker/comfyui.json:/config/comfyui.json:ro \
  -p 8189:8189 \
  comfyui-docker:latest
```
访问 `http://<服务器IP>:8189`，用 preset `auth_users` 允许的用户登录。

### 仅内网
把 `-p 8189:8189` 换成 `-p 127.0.0.1:8189:8189`。

### 无认证预设 / 切换 preset / 附加参数
```bash
docker run -d --name comfyui -e PRESET=cpu-noauth ... comfyui-docker:latest   # 直连不认证
docker run -d --name comfyui ... comfyui-docker:latest --preset=lowvram
docker run -d --name comfyui -e EXTRA_ARGS="--fast" ... comfyui-docker:latest
```

## 四、docker-compose（默认 remote + gpu + nvidia）
```bash
cd ComfyUI-docker
docker compose up -d --build            # 访问 http://<服务器IP>:8189
docker compose run --rm comfyui --preset=lowvram
docker compose logs -f
docker compose down
```
- compose 已设 `PRESET=gpu`、`EXPOSE_PORT=8189`、映射 `8189:8189`，可直接访问。
- 换本地源码：把 compose 的 `target` 改为 `local-stage`。
- 改预设/端口/认证后，同步改 `EXPOSE_PORT` 与 `ports` 再重建生效。

## 五、运维
```bash
docker logs -f comfyui
docker ps -a
docker restart comfyui
docker rm -f comfyui
docker exec -it comfyui bash
```
