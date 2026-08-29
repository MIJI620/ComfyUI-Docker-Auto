#!/usr/bin/env bash
# ============================================================================
# 构建前检查(preflight)
# 在 docker build / docker compose 之前先跑, 确保构建上下文材料齐全。
#   bash ./check_build.sh [VERSION]     # 默认版本 0.34.0
# 缺失项会逐条列明并给出修复提示; 全部就绪则打印 PREFLIGHT PASSED。
# 使用场景:
#   - local-stage(本地源码): 需要 versions/<VERSION>/ 存在;
#   - remote-stage(在线拉取): 不需要本地源码, 但需网络可访问 GitHub。
# ============================================================================
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
VER="${1:-0.34.0}"
fail=0

say(){ if [ -e "$ROOT/$2" ]; then echo "  [ OK  ] $1  $2"; else echo "  [缺失] $1  $2"; fail=1; fi; }

echo "== ComfyUI-Docker build preflight (version=$VER) =="
echo "-- docker 材料(app/docker 与配置) --"
say "Dockerfile    " app/docker/Dockerfile
say "net_lib.sh    " app/docker/net_lib.sh
say "entrypoint.sh " app/docker/entrypoint.sh
say "resolve_preset" app/docker/resolve_preset.py
say "gen_auth      " app/docker/gen_auth.py
say "comfyui.json  " comfyui.json
say "docker-compose" docker-compose.yml

echo "-- 版本源码 (local-stage 需要; remote-stage 不需要) --"
if [ -d "$ROOT/versions/$VER" ]; then
  echo "  [ OK  ] versions/$VER  目录存在"
else
  echo "  [缺失] versions/$VER  目录不存在"
  echo "         若用 target: local-stage, 必须提供本地源码(参考: versions/0.34.0/)。"
  echo "         若用 target: remote-stage, 则从 GitHub 克隆(需网络可访问), 此检查可作为提示。"
  fail=1
fi

echo ""
if [ "$fail" = "0" ]; then
  echo "PREFLIGHT PASSED. 下一步见 README: docker compose up -d --build, 或 docker build 各命令。"
  echo "安全提醒: 上线前请替换 comfyui.json 里默认 admin 的 bcrypt 密码哈希。"
  exit 0
else
  echo "PREFLIGHT FAILED —— 请先补齐上述缺失项; 若确实走 remote-stage 且无需本地源码, 可忽略 versions 一项。"
  exit 1
fi
