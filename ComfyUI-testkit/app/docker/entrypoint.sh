#!/usr/bin/env bash
# ============================================================================
# ComfyUI entrypoint —— 读取 comfyui.json 预设,拼接 main.py 启动命令
#
# preset 来源优先级:
#   1) 命令行参数  --preset=名字  或  --preset 名字
#   2) 环境变量    PRESET
#   3) JSON 文件    default_preset
#
# 额外参数:
#   - 环境变量 EXTRA_ARGS : 追加到 main.py 末尾(空格分隔)
#   - 命令行其余参数      : 透传给 main.py
#
# 依据预设决定:
#   - 容器内一律 --listen 0.0.0.0, 使 docker -p 端口映射能访问; "inner/public"
#     安全由宿主机端口映射控制(如 127.0.0.1:8188:8188=仅内网), 而非容器 loopback。
#   - resources.reserve_* -> --reserve-vram / (内存由容器层控制,这里仅 log)
#   - auth_required -> BasicAuth 由 Nginx 承担(镜像内); 这里 ComfyUI 仍绑 0.0.0.0 由 nginx 反代。
#
# 用法示例(容器内):
#   docker run --gpus all -v $PWD/comfyui.json:/config/comfyui.json comfyui-docker
#   docker run ... comfyui-docker --preset=cpu
#   docker run ... -e EXTRA_ARGS="--listen 0.0.0.0" comfyui-docker
# ============================================================================
set -u

# 配置路径: 默认 /config/comfyui.json, 可用环境变量 COMYUI_CONFIG 覆盖
CFG="${COMYUI_CONFIG:-/config/comfyui.json}"
PY="${RESOLVE_PRESET_PY:-/usr/local/bin/resolve_preset.py}"
# 可选 HTTPS 证书目录: 内含 fullchain.pem + privkey.pem; 存在才启用 HTTPS(否则 HTTP)
CERTS_DIR="${COMYUI_CERTS_DIR:-/config/certs}"
# ComfyUI 解释器: 容器内用 venv(有 torch); 外部/测试可用系统 python 覆盖。
PYTHON_BIN="${PYTHON_BIN:-}"
if [ -z "$PYTHON_BIN" ]; then
  if [ -x /workspace/venv/bin/python ]; then PYTHON_BIN=/workspace/venv/bin/python; fi
fi
if [ -z "$PYTHON_BIN" ]; then PYTHON_BIN="$(command -v python || echo python)"; fi

# ---- 1) 从命令行解析 --preset / 自测钩子 ----
SELFTEST_AUTH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --self-test-auth) SELFTEST_AUTH=1; shift ;;
    --preset=*) PRESET="${1#*=}"; shift ;;
    --preset)   shift; PRESET="${1:-}"; shift ;;
    *) break ;;
  esac
done
PRESET="${PRESET:-}${EXTRA_PRESET:-}"

# 自测钩子: 不启动真实 ComfyUI(免 GPU), 用假后端 + nginx 验证认证行为。
# 认证开/关由"选中的预设"决定:
#   - auth.enabled=false -> nginx 无 auth_basic, 假后端直通返回 200(测无认证)
#   - auth.enabled=true  -> nginx BasicAuth, 用顶层 auth.users 中白名单用户的 bcrypt hash
# 用法: --self-test-auth [--preset=<名字>]  (预设可从命令/PRESET/默认读取)
if [ "$SELFTEST_AUTH" = "1" ]; then
  # 确定被测预设(与正常启动共用同一优先级)
  DEFP="$(python -c \
    "import json,sys;d=json.load(open(sys.argv[1], encoding='utf-8'));print(d.get('default_preset','gpu'))" \
    "$CFG" 2>/dev/null || echo gpu)"
  TESTP="${PRESET:-$DEFP}"
  echo "[ComfyUI] SELFTEST: use preset=${TESTP} (auth behavior via local preset + global auth.users)"
  # 生成 htpasswd: 顶层 auth.users 中选本预设白名单 auth_users; 剔除 concurrency=0 的禁用用户; 用其已存 bcrypt hash
  python -c "
import json,sys,os
data=json.load(open(sys.argv[1], encoding='utf-8'))
pname=sys.argv[2]
preset=next((p for p in data.get('presets',[]) if p.get('name')==pname),{})
auth=preset.get('auth',{}) or {}
allowed=set(auth.get('auth_users',[]) or [])
enabled=bool(auth.get('enabled',False))
allu=data.get('auth',{}).get('users',[]) or []
users=[u for u in allu if u.get('username') in allowed and int(u.get('concurrency',1))!=0]
lines=[]
for u in users:
    h=u.get('hash') or ''
    lines.append(u.get('username','')+':'+h)
open('/tmp/.htpasswd','w').write('\n'.join(lines))
print('enabled=%s allowed=%s htpasswd_lines=%d' % (enabled, sorted(allowed), len(lines)))
" "$CFG" "$TESTP" 2>&1 | sed 's#^#[ComfyUI] htpasswd# '
  # 生成 nginx conf(用预设置的 listen_port 与白名单)
  python /usr/local/bin/gen_auth.py "$CFG" --preset "$TESTP" --certs-dir "$CERTS_DIR" 2>/dev/null \
    | grep -v '^#' > /tmp/nginx.comfyui.conf
  sed -i "s#auth_basic_user_file .*#auth_basic_user_file /tmp/.htpasswd;#" /tmp/nginx.comfyui.conf
  # put pid in a writable path (non-root comfyui cannot write /run/nginx.pid)
  sed -i '1i pid /tmp/nginx.pid;' /tmp/nginx.comfyui.conf
  (python -m http.server 8188 --bind 127.0.0.1 >/dev/null 2>&1 &)
  echo "[ComfyUI] SELFTEST: fake backend up on 127.0.0.1:8188"
  echo "[ComfyUI] SELFTEST: ---- nginx.conf begin ----"
  cat /tmp/nginx.comfyui.conf
  echo "[ComfyUI] SELFTEST: ---- nginx.conf end ----"
  echo "[ComfyUI] SELFTEST: .htpasswd content:"
  sed 's/:[^:]*$/:<hash>/' /tmp/.htpasswd 2>/dev/null || true
  echo "[ComfyUI] SELFTEST: nginx -t output:"
  nginx -t -c /tmp/nginx.comfyui.conf 2>&1
  echo "[ComfyUI] SELFTEST: launch nginx (daemon off)"
  exec nginx -c /tmp/nginx.comfyui.conf -g "daemon off;"
fi

# ---- 2) 确定默认 preset ----
DEFAULT_PRESET=gpu
if [ -f "$CFG" ]; then
  DEFAULT_PRESET="$(python -c \
    "import json,sys;print(json.load(open(sys.argv[1], encoding='utf-8')).get('default_preset','gpu'))" \
    "$CFG" 2>/dev/null || echo gpu)"
fi
PRESET="${PRESET:-$DEFAULT_PRESET}"

# ---- 3) 获取决策 JSON ----
DECISION="$(python "$PY" "$PRESET" "$CFG" --json 2>/dev/null || true)"
if [ -z "$DECISION" ]; then
  echo "[ComfyUI] [WARN] preset '$PRESET' 未找到或配置缺失,回退默认 args"
  DECISION="$(printf '{"preset":"%s","args":[],"access":"inner","port":8188,"auth_enabled":false,"auth_users":[],"resources":{},"global_auth":{}}' "$PRESET")"
fi
export CG_DECISION="$DECISION"

# ---- 4) 用 python 一次性生成最终 argv(避免 bash 数组跨子 shell 丢失问题) ----
# 捕获 stderr,失败时给出兜底参数(和前台直跑一致的 --listen 0.0.0.0 --port EXPOSE_PORT)
EMIT=$(PRESET="$PRESET" EXTRA_ARGS="${EXTRA_ARGS:-}" python -c "
import os, json
d = json.loads(os.environ['CG_DECISION'])
addr = '0.0.0.0'
ext_port = str(os.environ.get('EXPOSE_PORT') or d.get('port') or 8188)
args = list(d.get('args', []))
argv = ['--listen', addr, '--port', ext_port]
res = d.get('resources', {}) or {}
if res.get('reserve_vram_gb') is not None:
    argv += ['--reserve-vram', str(res['reserve_vram_gb'])]
extra = os.environ.get('EXTRA_ARGS', '')
if extra.strip():
    argv += [a for a in extra.split() if a]
argv += args
print(' '.join(argv))
" 2>/tmp/argv_err)
if [ -z "$EMIT" ]; then
  echo "[ComfyUI] [WARN] argv generation failed; using fallback fixed args. stderr:"
  cat /tmp/argv_err 2>/dev/null | head -5
  EMIT="--listen 0.0.0.0 --port ${EXPOSE_PORT:-8188}"
  # also include preset args (e.g. --cpu) from resolve
  PY="$(command -v python)"
  PRES_ARGS=$(python /usr/local/bin/resolve_preset.py "$PRESET" "$CFG" 2>/dev/null || true)
  [ -n "$PRES_ARGS" ] && EMIT="$EMIT $PRES_ARGS"
fi
FINAL_ARGS=()
for tok in $EMIT; do
  FINAL_ARGS+=("$tok")
done

echo "[ComfyUI] preset=${PRESET} source=${COMFYUI_SOURCE:-?} version=${COMFYUI_VERSION:-?}"
python -c "import json,os;d=json.loads(os.environ['CG_DECISION']);print('[ComfyUI] access=%s auth_enabled=%s port=%s vram_gb=%s'%(d.get('access'),d.get('auth_enabled'),d.get('port'),(d.get('resources') or {}).get('reserve_vram_gb')))"
echo "[ComfyUI] main.py args: ${FINAL_ARGS[*]} $*"
echo "[ComfyUI] external port = ${EXPOSE_PORT:-8188}  (host maps this port INTO the container); internal ComfyUI port below"

# ---- 5) 启动 ----
# 若该预设开启认证(auth.enabled)且镜像装了 nginx, 则由 nginx 对外做 BasicAuth,
# ComfyUI 强制只绑定 127.0.0.1(不经 nginx 不暴露), 防绕过认证直接访问 ComfyUI。
# 否则 ComfyUI 使用预设的 port 直接监听并前台运行。
# 需要认证时: ComfyUI 后台运行 + nginx 前台; 否则 ComfyUI 前台(exec 替换 shell)。
CMD_ARGS=("${FINAL_ARGS[@]//$'\r'/}")
CMD_ARGS+=("$@")

AUTH_REQUIRED="$(python -c "
import json,os
print('True' if json.loads(os.environ['CG_DECISION']).get('auth_enabled', False) else 'False')
")"

if [ "${AUTH_REQUIRED}" = "True" ] && command -v nginx >/dev/null 2>&1; then
  echo "[ComfyUI] 启用 Nginx BasicAuth 反代对外端口(ComfyUI 仅监听 127.0.0.1)"
  # a) 生成 nginx 配置(基于选中预设的 port + auth_users 白名单; 顶层 auth.users 存 bcrypt hash)
  python /usr/local/bin/gen_auth.py "$CFG" --preset "$PRESET" --certs-dir "$CERTS_DIR" 2>/dev/null \
    | grep -v '^#' > /tmp/nginx.comfyui.conf
  # 生成 htpasswd: 顶层 auth.users 中选本预设白名单 auth_users; 剔除 concurrency=0 的禁用用户; 用其已存 bcrypt hash
  python -c "
import json,sys
data=json.load(open(sys.argv[1], encoding='utf-8'))
pname=sys.argv[2]
preset=next((p for p in data.get('presets',[]) if p.get('name')==pname),{})
auth=preset.get('auth',{}) or {}
allowed=set(auth.get('auth_users',[]) or [])
allu=data.get('auth',{}).get('users',[]) or []
users=[u for u in allu if u.get('username') in allowed and int(u.get('concurrency',1))!=0]
lines=[u.get('username','')+':'+(u.get('hash') or '') for u in users]
open('/tmp/.htpasswd','w').write('\n'.join(lines))
print('allowed=%s htpasswd_lines=%d' % (sorted(allowed), len(lines)))
" "$CFG" "$PRESET" 2>&1 | sed 's#^#[ComfyUI] htpasswd# ' || true
  sed -i "s#auth_basic_user_file .*#auth_basic_user_file /tmp/.htpasswd;#" /tmp/nginx.comfyui.conf
  # non-root comfyui cannot write /run/nginx.pid -> put pid in a writable path
  sed -i '1i pid /tmp/nginx.pid;' /tmp/nginx.comfyui.conf
  # b) 启动前检查: 若 admin 仍在用默认(未替换)密码哈希, 打印醒目提醒(非阻塞, 上线前应替换)
  # 用环境变量把默认 hash 交给 python, 彻底规避 `$` 在 -c 命令串里的 shell 二次展开歧义
  DHASH='$2b$10$HwAMFQwi2u1srsfba6G8nOzYS37kLbAVc2D2u5hn8uqFKC3IrFp1.'
  export DHASH
  if "$PYTHON_BIN" -c "import os,json,sys;d=json.load(open(sys.argv[1], encoding='utf-8'));u=next((x for x in d.get('auth',{}).get('users',[]) if x.get('username')=='admin'),{});sys.exit(0 if u.get('hash')==os.environ['DHASH'] else 1)" "$CFG"; then
    echo "[ComfyUI] [WARN] admin 仍在使用【默认密码哈希】! 上线前请在 comfyui.json 生成并替换 auth.users[].hash(见 README)。" >&2
  fi
  # 后台启动 ComfyUI(强制绑 127.0.0.1:8188, 其余预设参数保留)
  REST=()
  skip=0
  for i in "${FINAL_ARGS[@]}"; do
    if [ "$skip" = "1" ]; then skip=0; continue; fi
    case "$i" in
      --listen|--port) skip=1 ;;
      *) REST+=("$i") ;;
    esac
  done
  "$PYTHON_BIN" main.py --listen 127.0.0.1 --port 8188 "${REST[@]}" "$@" &
  COMFY_PID=$!
  # c) 前台运行 nginx
  nginx -c /tmp/nginx.comfyui.conf -g "daemon off;"
else
  echo "[ComfyUI] 直接启动 ComfyUI (无 BasicAuth 反代)"
  # use venv python so torch & deps are available (system/python may lack them)
  exec "$PYTHON_BIN" main.py "${CMD_ARGS[@]}"
fi
