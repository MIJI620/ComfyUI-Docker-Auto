# ComfyUI-Docker —— 自选版本 + 自选启动方式 + 独立认证 + 共享模型库

构建 **NVIDIA GPU Docker 镜像**：`ComfyUI v0.34.0` 源码 + `Python 3.13` + `PyTorch 2.13.0`（GPU=cu130，CPU 可切）。
`.app/docker/` 与测试包 `ComfyUI-testkit/app/docker/` **逐字（byte-for-byte）一致**，测试通过即代表本镜像同套逻辑通过。

- **CPU 与 GPU 可切换**：笔记本/无独显用 CPU（`--build-arg COMFYUI_CPU_ONLY=1`），服务器 RTX 用 cu130。
- **支持自选版本来源**：在线拉取（`remote-stage`，GitHub）/ 本地目录（`local-stage`，`versions/<版本>/`）。
- **国内网络友好**：base 镜像 `BASE_IMAGE` 可换国内源；**torch 下载源用 `net_lib.sh` 真实嗅探自动选取**（GPU 优先阿里云 `pytorch-wheels/cu130`，全部不可达才回退官方）。
- **支持自选启动方式**：预设表（gpu/cpu/lowvram/fp16…），端口与性能参数各自独立。
- **认证与性能解耦**：每个预设可独立开/关 Nginx BasicAuth，并限定允许的用户白名单。
- **密码存 bcrypt 哈希**：不存明文，nginx `auth_basic_user_file` 用 `$2y$/$2b$` 校验。

---

## 目录结构（当前真实布局）

```
ComfyUI-docker/
├── README.md                        # 本教程
├── HELPER.md                        # 命令速查
├── .dockerignore                    # 构建上下文排除项
├── docker-compose.yml               # 一键构建+运行（GPU, 默认 remote-stage + gpu 预设）
├── comfyui.json                     # ★ 运行配置：预设表(含 port/auth) + 全局认证密码库
├── versions/                        # ★ 本地版本目录（local 模式用）
│   └── 0.34.0/                      #   ComfyUI 源码
└── app/docker/                      # ★ 与 ComfyUI-testkit/app/docker 逐字一致
    ├── Dockerfile                   # 多阶段镜像（base → local/remote stage; 国内镜像 pick_first_200）
    ├── net_lib.sh                   # 统一网络源选择库（PyPI/torch 同一套真实嗅探）
    ├── entrypoint.sh                # 读 preset → 拼 main.py 参数 + 按需起 nginx 反代
    ├── gen_auth.py                  # 生成 nginx BasicAuth 配置(按选中预设)
    └── resolve_preset.py            # 解析 comfyui.json 选中的预设
```

---

## 一、comfyui.json —— 核心运行配置

### 全局认证密码库（`auth`）
```jsonc
"auth": {
  "realm": "ComfyUI",
  "max_connections": 50,                     // (历史字段) 原按来源IP的并发上限, 现已由各用户 concurrency 取代
  "users": [
    { "username": "admin", "hash": "$2b$10$..." }   // ★ 只存 bcrypt 哈希, 不存明文
  ]
}
```
> ⚠️ **部署前必须做**：`comfyui.json` 里默认 `admin` 的 `hash` 是一个**示例哈希**（对应一个默认测试密码）。生成你自己的：
> ```bash
> docker run --rm <已 build 的镜像> htpasswd -nbB admin '<你的密码>'
> # 输出形如: admin:$2y$05$xxxxxxxxxxxxxxxxxxxxx
> # 把冒号后那一段(hash)替换 comfyui.json 里该用户的 "hash", 再重建容器。
> ```

### 预设表（`presets[]`）——每条自包含
```jsonc
{
  "name": "gpu",
  "access": "inner",        // inner=仅内网; public=允许公网(安全由 -p 绑定控制)
  "port": 8189,             // ★ 本预设对应的对外端口(nginx 监听 / ComfyUI 直连端口)
  "auth": {                 // ★ 认证独立于性能: 这里单独开关 + 白名单
    "enabled": true,        //   true=走 nginx BasicAuth; false=直连不认证
    "auth_users": ["admin"] //   ★ 只允许这些顶层 auth.users 用户
  },
  "args": ["--lowvram"],    // 追加到 main.py 的任意参数
  "resources": { "reserve_vram_gb": 2 }   // 或 reserve_memory_mb
}
```

**内置预设**：

| preset | access | port | auth | auth_users | args | 特点 |
|---|---|---|---|---|---|---|
| `gpu` | inner | 8189 | ✅ | admin | – | 默认 GPU |
| `gpu-public` | public | 8190 | ✅ | admin | – | GPU 对外 |
| `cpu` | inner | 8191 | ✅ | admin | `--cpu` | 纯 CPU，带认证 |
| `cpu-public` | public | 8192 | ✅ | admin | `--cpu` | 纯 CPU，对外带认证 |
| `cpu-noauth` | inner | 8198 | ❌ | – | `--cpu` | 认证关闭（无认证直连） |
| `fp16` | inner | 8193 | ✅ | admin | `--fp16` | 半精度 |
| `lowvram` | inner | 8194 | ✅ | admin | `--lowvram` | 低显存 |
| `novram` | inner | 8195 | ✅ | admin | `--novram` | 极端低显存 |
| `fast` | inner | 8196 | ✅ | admin | `--fast` | 快速启动 |
| `quiet` | inner | 8197 | ✅ | admin | `--quiet` | 减少日志 |

> **端口铁律**：ComfyUI 对外端口 = `EXPOSE_PORT` 环境变量，未设则用选中 preset 的 `port`。
> 注意 ≠ Dockerfile 里的 `EXPOSE 8188`（那是声明性端口，不是对外映射）。`docker run -p HOST:CTYPE` 与 compose `ports` 必须与对外端口一致。

### 选预设（优先级从高到低）
1. 命令行：`docker compose run --rm comfyui --preset=lowvram`
2. 环境变量：`-e PRESET=lowvram`
3. 配置兜底：`default_preset`

---

## 二、构建镜像

### 位置约定（重要）
- **`docker build`**：请在**包含 `ComfyUI-docker/` 的上级根目录**执行（构建上下文 = 上级根，用 `-f ComfyUI-docker/app/docker/Dockerfile`）。
- **`docker compose`**：请在 `ComfyUI-docker/` **目录内**执行（compose 的 `context: ..` 自动指向上级根）。

#### 构建前自检（建议，可选）
在 `ComfyUI-docker/` 里先跑一次，确认构建材料齐全、缺了就给出明确报错：
```bash
cd ComfyUI-docker
bash ./check_build.sh          # 可带版本号: bash ./check_build.sh 0.34.0
```
> 它会检查 `app/docker/*`、`comfyui.json`、`docker-compose.yml`，以及（local-stage 需要的）`versions/<版本>/`。若你确定走 remote-stage 且无需本地源码，缺失的项目可忽略。

### 方式一：GPU / 默认，本地源码（local-stage）
```bash
cd "你的根目录"          # 上级根（含 ComfyUI-docker/）
docker build --target local-stage \
  --build-arg COMFYUI_VERSION=0.34.0 \
  --build-arg BASE_IMAGE=docker.m.daocloud.io/library/python:3.13-slim \
  -f ComfyUI-docker/app/docker/Dockerfile -t comfyui-docker:latest .
```
- `versions/0.34.0/` 里的本地源码会被 `COPY` 进镜像（离线/可控，推荐服务器用）。
- GPU 分支的 torch 走国内镜像：构建日志里应出现 `torch CUDA index: https://mirrors.aliyun.com/pytorch-wheels/cu130`（不可达才回退官方）。

### 方式二：CPU（无独显/测试）
```bash
cd "你的根目录"
docker build --target local-stage \
  --build-arg COMFYUI_VERSION=0.34.0 --build-arg COMFYUI_CPU_ONLY=1 \
  --build-arg BASE_IMAGE=docker.m.daocloud.io/library/python:3.13-slim \
  -f ComfyUI-docker/app/docker/Dockerfile -t comfyui-test:cpu .
```

### 方式三：在线拉取源码（remote-stage）
```bash
cd "你的根目录"
docker build --target remote-stage --build-arg COMFYUI_VERSION=0.34.0 \
  -f ComfyUI-docker/app/docker/Dockerfile -t comfyui-docker:latest .
```
- 需要能访问 `github.com/Comfy-Org/ComfyUI`（国内可改镜像站）。

### 网络源自动选择与超时容错（net_lib.sh）

构建时所有 **PyPI / torch 下载源**都由统一的 `net_lib.sh` 决定，不搞特例：
- 判定一个"源"是否可用，只看它能否对需要下载的文件返回 **HTTP 200**（`pick_first_200` 逐源真实嗅探）；HTTP 3xx(重定向/302)、4xx/5xx、超时、不可达 → 视为该源未持文件，继续下一个。候选按"国内优先"排序，官方源只在列表最后兜底。
- **超时容错**：探测整体超时默认 `NET_LIB_TOTAL_TIMEOUT=20`（秒）、建连超时 `NET_LIB_CONNECT_TIMEOUT`（默认=整体）。网络卡顿时构建可能在某个源上等待较久——构建前可调小以加速失败切换：
  ```bash
  export NET_LIB_TOTAL_TIMEOUT=10        # 每次 URL 探测整体超时 10s
  export NET_LIB_CONNECT_TIMEOUT=8       # TCP 建连超时 8s(可选,默认=整体)
  docker build ...
  ```
- 构建日志会打印 `Using PyPI index: ...` / `torch CUDA index: ...`，据此确认真实命中的源。

### 一键构建+运行（docker-compose，默认 remote + gpu）
```bash
cd ComfyUI-docker
docker compose up -d --build
# 访问 http://<服务器IP>:8189  (端口 = EXPOSE_PORT / preset.port, 已与 ports 映射对齐)
```
- compose 默认 `runtime: nvidia`、`target: remote-stage`、`PRESET=gpu`、`EXPOSE_PORT=8189`、映射 `8189:8189`。
- 换本地源码：改 compose 的 `target` 为 `local-stage`（并确保 `versions/<版本>/` 在）。

---

## 三、启动容器

### GPU 服务器带认证（默认 preset=gpu，对外端口 8189）
```bash
docker run -d --name comfyui \
  --gpus all -m 16g \
  -e PRESET=gpu \
  -e EXPOSE_PORT=8189 \
  -v /path/to/models:/workspace/comfyui/models \
  -v /path/to/comfyui.json:/config/comfyui.json:ro \
  -p 8189:8189 \
  comfyui-docker:latest
```
- 用户由 `comfyui.json` 的 `auth.users`(bcrypt hash) 与预设 `auth_users` 白名单共同决定。
- 仅内网：把 `-p 8189:8189` 换成 `-p 127.0.0.1:8189:8189`。
- 无认证预设（`cpu-noauth`）：ComfyUI 直连，不弹认证。
- 换预设：`-e PRESET=cpu` / `comfyui-docker:latest --preset=lowvram` / `-e EXTRA_ARGS="--fast"`。

> **端口与安全**：ComfyUI 对外监听 = `EXPOSE_PORT` 或 preset.port（非 8188）。auth 预设走 nginx 反代，ComfyUI 只绑 `127.0.0.1:8188` 防止绕过认证；无 auth 预设才直连对外。

---

## 四、认证是如何工作的（重要）

- **`auth.enabled=true` 的预设**：nginx 绑该预设的 `port`，`auth_basic_user_file` 用 comfyui.json 里
  白名单用户的 bcrypt hash。未认证返回 **401**，白名单内用户返回 **2xx**，白名单外用户 **401**。
- **`auth.enabled=false` 的预设**：nginx 无 `auth_basic`，请求直通后端返回 200（不弹认证）。
- 修改用户/密码后：重新生成 bcrypt hash 写入 comfyui.json，**重建容器** 即生效。

### 四·补充：用户并发限制（按登录用户，非按 IP）

每个用户在自己的全局定义里配 **并发上限**（`auth.users[].concurrency`），全站生效（只要某预设允许该用户，就用它自己的额度）：

```jsonc
"auth": { "users": [
    { "username": "admin", "hash": "$2b$10$...", "concurrency": -1 },  // -1 = 无限(不限制)
    { "username": "bob",   "hash": "$2b$10$...", "concurrency": 3 },   // 3 = 同时最多 3 个连接
    { "username": "tom",   "hash": "$2b$10$..." }                       // 未写 = 严格保守默认 1
]}
```
- `-1` = 无限；`0` = 禁用（该用户即使被某预设列入 `auth_users` 也无法登录，直接 401）；`1..N` = 同时最多 N 个连接。
- **未配置 `concurrency` 时默认 = `1`**（保守：漏写不放开，最多同时 1 个连接）。
- 实现：nginx 的 `limit_conn zone number` 的 number 必须是**常量**（不接受变量），因此为每个**有限额**用户（`concurrency>0`）各生成一条 `map $remote_user → 该用户` + 独立 `limit_conn_zone` + `limit_conn <常量 N>`；该用户请求时 key 非空计入对应 zone、受 N 限制，其他用户 key 为空 → nginx 空 key 不参与限流，从而每个用户独立、额度可不同。`concurrency=-1`(无限)/`0`(禁用) 不生成限制（`0` 的用户已被剥出 htpasswd 走 401）。限流只对开启了认证的预设生效。（原全局 `max_connections` 按 IP 的方式已由此取代。）

### 四·补充：可选 HTTPS（默认 HTTP；给证书即自动切 HTTPS）

默认监听 **HTTP**；若你在挂载的 certs 目录（容器内 `/config/certs`，compose 已挂 `./certs:/config/certs:ro`）提供 **`fullchain.pem` + `privkey.pem`** 两个文件，则自动切换为 **HTTPS（443）** 并把 HTTP 80 重定向到 HTTPS：

```bash
cd ComfyUI-docker
mkdir -p ./certs
cp /path/to/fullchain.pem ./certs/
cp /path/to/privkey.pem   ./certs/
docker compose up -d --build    # nginx 自动监听 443 + 80→443
```
- 不提供证书 = 完全维持原来的 HTTP 行为，无需任何改动。
- 证书续期后重启容器生效。

### 四·补充：健康检查（HEALTHCHECK）

镜像内置 `HEALTHCHECK`（探 `127.0.0.1:8188` 或对外 `EXPOSE_PORT`/preset 端口，`start-period=300s` 覆盖 CPU 慢速首载）。Compose 默认继承，`docker ps` / 编排器可据此发现假活（进程在但端口不通）。

---

## 五、共享模型库

镜像不含模型/输入/输出/用户数据，均经 volume 挂载：
```bash
docker run ... \
  -v /path/to/models:/workspace/comfyui/models \
  -v /path/to/input:/workspace/comfyui/input \
  -v /path/to/output:/workspace/comfyui/output \
  -v /path/to/user:/workspace/comfyui/user \
  -v /path/to/comfyui.json:/config/comfyui.json:ro ...
```
compose 已内置 `./models ./input ./output ./user` 的相对挂载（在 `ComfyUI-docker/` 下建目录或改指真实目录）。

> **多实例提示（可选）**：镜像不限制你起几个容器（一个容器 = 一个 preset）。默认多个容器会**共用**同一个 `./models ./input ./output ./user`——其中 `models` 是只读的模型"储备"，本来就该共用；但若希望不同实例的**输出/用户配置**互不混叠，可为各实例分别指到独立子目录，例如 `models` 继续共用同一套，仅把第二个实例的 `input/output/user` 指向 `./i2/…`：
> ```
> -v ./models:/workspace/comfyui/models     # 共用同一套模型(推荐)
> -v ./i2/input:/workspace/comfyui/input   # 各实例独立
> -v ./i2/output:/workspace/comfyui/output
> -v ./i2/user:/workspace/comfyui/user
> ```
> 纯可选，单实例无需任何改动。

---

## 六、测试验证（7 阶段，已在笔记本 CPU 全绿）

配套测试入口为 `ComfyUI-testkit/`（`run_test.bat` 管理员运行），跑通 7 阶段：

```
[1/7] Docker env → [2/7] Network/mirrors → [3/7] build → [4/7] start+http
→ [5/7] no-auth direct(认证关, 200 非 401)
→ [6/7] auth(basicAuth+bcrypt: 401 / 白名单内200 / 白名单外401)
→ [7/7] preset switch
```
- 认证开/关是两个独立测试；`[6/7]` 是 bcrypt 全量自测。
- 逻辑层有 `tests/test_logic.py`（不依赖 Docker，开发机可跑）。
- **本包 `.app/docker/` 与 testkit 逐字一致**：上述测试通过 = 本镜像同套逻辑通过。
- ⚠️ 本已通过的是 **CPU（COMFYUI_CPU_ONLY=1）** 路径；**GPU(cu130) 建议在真机再 `docker build` 复验一次**（确认构建日志出现 `torch CUDA index: mirrors.aliyun.com/pytorch-wheels/cu130`，且在 `--gpus all` 下服务正常）。

---

## 注意事项 / 服务器部署前必看

- **必配 `BASE_IMAGE` 镜像源**：docker.io 国内常不可达 → `docker.m.daocloud.io/library/python:3.13-slim`。
- **CPU 版** `COMFYUI_CPU_ONLY=1`（锁 torch/torchvision/torchaudio）；**GPU 版**默认 cu130，torch 优先阿里云国内源。
- 容器内非 root `comfyui` 运行；nginx PID/运行时目录已修正到可写路径，BasicAuth 依赖此。
- **宿主机 UID/GID 权限映射**：容器内 `comfyui` 固定 `uid=1000`。若宿主机上 `models/input/output/user` 目录的属主不是 uid=1000（例如 root 或其它账号），容器内以 1000 去读写会 `Permission denied`。解决（无需改镜像）：启动时把当前宿主用户的 uid/gid 传进容器——
  ```bash
  # docker run 方式
  docker run -d --name comfyui -u $(id -u):$(id -g) -e PRESET=gpu \
    -v /path/to/models:/workspace/comfyui/models ... comfyui-docker:latest
  # docker compose 方式
  UID=$(id -u) GID=$(id -g) docker compose up -d --build
  ```
  这样容器进程以你本人的 uid 运行，读写本机目录即可。<code>gpu</code> 预设 + `--gpus all` 时若遇 GPU 权限问题再检查是否需补所在组。
- **上线前必须把默认 `admin` 的 bcrypt hash 换成你自己的真实密码生成值**（见上文）。
- 不要用 Windows 便携版的 `--windows-standalone-build` 参数。
- remote 模式 clone 需访问 GitHub（可改镜像站）。
- 端口映射务必与对外端口（`EXPOSE_PORT` / preset.port）一致，否则访问不到。
