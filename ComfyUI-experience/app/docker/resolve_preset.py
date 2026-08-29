#!/usr/bin/env python3
"""解析 comfyui.json, 输出"选用某个预设后应如何启动 ComfyUI"的决策。

用法:
    python resolve_preset.py <preset名称> <comfyui.json路径> [--json]

输出 (一行, 便于 bash 取值):
    --json : 打印一个 JSON 对象, 含所选预设的 args/access/port/auth(auth_users), 以及全局 auth
    (默认) : 只打印该预设的 args, 每行一个参数 (兼容旧用法)

exit code:
    0  正常
    2  预设不存在或配置缺失(此时默认不输出, 由调用方回退缺省)
"""
import json
import sys


def _load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def main() -> int:
    if len(sys.argv) < 3:
        return 0
    name, path = sys.argv[1], sys.argv[2]
    as_json = "--json" in sys.argv

    data = _load(path)
    if data is None:
        return 2

    selected = None
    for p in data.get("presets", []):
        if p.get("name") == name:
            selected = p
            break
    if selected is None:
        return 2

    if as_json:
        # 输出完整决策, 供 entrypoint / 测试 / Nginx 模板复用
        auth_sec = selected.get("auth", {}) or {}
        decision = {
            "preset": name,
            "args": selected.get("args", []),
            "access": selected.get("access", "inner"),
            "port": int(selected.get("port", 8188)),
            "auth_enabled": bool(auth_sec.get("enabled", False)),
            "auth_users": [u for u in (auth_sec.get("auth_users", []) or [])],
            "resources": selected.get("resources", {}),
            "global_auth": data.get("auth", {}),
        }
        sys.stdout.write(json.dumps(decision))
    else:
        # 只输出 args, 每行一个
        for a in selected.get("args", []):
            sys.stdout.write(str(a) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
