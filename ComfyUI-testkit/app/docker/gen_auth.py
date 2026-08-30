#!/usr/bin/env python3
"""从 comfyui.json 生成 Nginx 配置(BasicAuth + 按用户并发限制 + 可选 HTTPS + 自定义端口)。

与旧版差异:
    - 认证按"预设"决定: 传 --preset 后读取该预设的 port 与 auth(auth_users 白名单)
    - htpasswd 文件内容 = 顶层 auth.users 中, 属于该预设白名单的用户, 用其已有 bcrypt hash
    - 并发限制【按登录用户】($remote_user), 而非按来源 IP:
        每个用户在全局 auth.users[].concurrency 配置(缺省保守=1):
          -1 = 无限(不生成 zone, 不受限)
           0 = 禁用(该用户不生成 htpasswd 条目, 即使被白名单也会 401, 故也不生成 zone)
          N>0 = 该用户同时最多 N 个请求/任务(生成独立 zone + 常量 limit_conn N)
        ⚠️ 实现要点: nginx 的 `limit_conn zone number` 的 number 不接受变量, 会报
           "invalid number of connections" 并使 nginx 无法启动。因此不能用一个
           map 变量做额度。改为: 为每个"有限额"用户各生成一条
           map(key=该用户) + limit_conn_zone + limit_conn <常量 N>:
             该用户请求时 $lim<i> = 用户名(非空) -> 计入对应 zone, 受该用户常量 N 限制;
             其他用户 $lim<i> = 空(未命中 map) -> nginx 空 key 不参与 limit_conn, 不受该 zone 影响。
          从而每个用户独立、额度可不同。仅对开启认证的预设生效(无认证时 $remote_user 为空)。
    - 可选 HTTPS: --certs-dir 下存在 fullchain.pem + privkey.pem 时, 监听 443 ssl
        并把 80 重定向到 443; 否则维持 HTTP 监听 preset.port。
    - 不再用 {PLAIN} 明文; 密码哈希由 gen_hash(htpasswd -nbB) 生成后写入 comfyui.json

用法:
    python gen_auth.py <comfyui.json> --preset gpu [--htpasswd /etc/nginx/.htpasswd] [--certs-dir /config/certs]

输出到 stdout 为完整 nginx.conf; 提示信息走 stderr。
"""
import argparse
import json
import os
import sys

# concurrency 的特殊值
CONC_UNLIMITED = -1   # 无限
CONC_DISABLED = 0     # 禁用
DEFAULT_CONC = 1      # 未配置时的保守默认


def _norm_conc(v):
    """把并发配置规整为 int; None/非数字 => 保守默认 1。"""
    if v is None:
        return DEFAULT_CONC
    try:
        return int(v)
    except Exception:
        return DEFAULT_CONC


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("config")
    ap.add_argument("--preset", required=True,
                    help="选中的预设名称(取其 port 与 auth 白名单)")
    ap.add_argument("--htpasswd", default="/etc/nginx/.htpasswd",
                    help="htpasswd 用户文件路径(供 nginx auth_basic_user_file 引用)")
    ap.add_argument("--certs-dir", default=None,
                    help="证书目录(内含 fullchain.pem + privkey.pem); 提供则启用 HTTPS, 否则 HTTP")
    args = ap.parse_args()

    with open(args.config, encoding="utf-8") as f:
        data = json.load(f)

    presets = data.get("presets", [])
    preset = next((p for p in presets if p.get("name") == args.preset), {})
    listen_port = int(preset.get("port", 8188))

    auth_sec = preset.get("auth", {}) or {}
    enabled = bool(auth_sec.get("enabled", False))
    allowed = [u for u in (auth_sec.get("auth_users", []) or [])]

    values_cache = {u.get("username"): u.get("concurrency")
                    for u in (data.get("auth", {}).get("users", []) or [])}
    realm = (data.get("auth", {}) or {}).get("realm", "ComfyUI")

    # 是否启用 HTTPS: 两个证书文件都必须真实存在
    use_https = False
    cert_pem = cert_key = ""
    if args.certs_dir:
        cert_pem = os.path.join(args.certs_dir, "fullchain.pem")
        cert_key = os.path.join(args.certs_dir, "privkey.pem")
        use_https = os.path.isfile(cert_pem) and os.path.isfile(cert_key)

    out = []
    out.append("events { worker_connections 1024; }")
    out.append("http {")
    out.append("    include /etc/nginx/mime.types;")
    out.append("    default_type application/octet-stream;")
    out.append("    sendfile on;")

    # 按用户并发限制(仅认证开启时有意义)。
    # 每个"有限额"用户(concurrency>0)生成独立 zone + map(key=该用户);
    #   -1(无限)/0(禁用) 不生成 zone(-1 不限; 0 已被 htpasswd 剔除走 401)。
    # 不用单 zone + map 变量作额度: nginx `limit_conn` 的 number 必须为常量, 否则启动失败。
    limited = []   # (username, 常量额度)
    if enabled:
        for uname in allowed:
            conc = _norm_conc(values_cache.get(uname, DEFAULT_CONC))
            if conc == CONC_UNLIMITED or conc <= 0:
                continue
            limited.append((uname, conc))
        for i, (uname, conc) in enumerate(limited):
            vname = "lim" + str(i)
            out.append(f"    map $remote_user ${vname} {{ {uname} {uname}; }}")
            out.append(f"    limit_conn_zone ${vname} zone=conn{i}:10m;")

    upstream_block = ("    upstream comfyui {\n"
                      "        server 127.0.0.1:8188;\n"
                      "    }")
    out.append(upstream_block)

    def server_block(ssl_mode):
        # proxy 指令(两个 location 共用: 其它 / 命令类)
        def proxy_lines():
            return ("            proxy_pass http://comfyui;",
                    "            proxy_http_version 1.1;",
                    "            proxy_set_header Host $host;",
                    "            proxy_set_header X-Real-IP $remote_addr;",
                    "            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;",
                    "            proxy_read_timeout 3600s;",
                    "            proxy_buffering off;")
        lines = []
        if ssl_mode:
            lines.append(f"    server {{")
            lines.append("        listen 443 ssl;")
            lines.append(f"        ssl_certificate {cert_pem};")
            lines.append(f"        ssl_certificate_key {cert_key};")
        else:
            lines.append(f"    server {{")
            lines.append(f"        listen {listen_port};")
        lines.append("")
        if enabled:
            lines.append(f"        # 用户名密码认证\n        auth_basic \"{realm}\";")
            lines.append(f"        auth_basic_user_file {args.htpasswd};")
        lines.append("")
        lines.append("        # 静态/其它资源(JS/CSS/页面): 不做并发限制, 否则会卡浏览器并行加载")
        lines.append("        location / {")
        for pl in proxy_lines():
            lines.append(pl)
        lines.append("        }")
        # 命令/API 类路径: 才按用户并发限制(upload/prompt/queue 等动作用户请求)
        if enabled and limited:
            lines.append("")
            lines.append("        # 命令/API 类请求(上传/生图/队列等)才按登录用户并发限制; 静态资源不受限")
            lines.append('        location ~ ^/(prompt|queue|history|interrupt|free|object_info|system_stats|upload/|view|ws|api/|internal/|extensions/) {')
            for i, (uname, conc) in enumerate(limited):
                lines.append(f"            limit_conn conn{i} {conc};")
            for pl in proxy_lines():
                lines.append(pl)
            lines.append("        }")
        lines.append("    }")
        return "\n".join(lines)

    if use_https:
        # HTTP 80 全量重定向到 HTTPS
        out.append("    server {")
        out.append("        listen 80;")
        out.append("        return 301 https://$host$request_uri;")
        out.append("    }")
        out.append(server_block(ssl_mode=True))
    else:
        out.append(server_block(ssl_mode=False))

    out.append("}")
    print("\n".join(out))

    # stderr 提示
    if use_https:
        print(f"# HTTPS: 监听 443 (证书 {cert_pem}), HTTP 80 重定向到 443。", file=sys.stderr)
    else:
        print(f"# HTTP : 监听 {listen_port} (未提供 --certs-dir 或证书缺失)。", file=sys.stderr)

    if enabled:
        all_users = (data.get("auth", {}) or {}).get("users", []) or []
        users = [u for u in all_users if u.get("username") in allowed]
        # 剔除 concurrency==0 的禁用用户(他们不生成 htpasswd 条目)
        active = [u for u in users if int(u.get("concurrency", DEFAULT_CONC)) != CONC_DISABLED]
        if not active:
            print(
                f"# WARN: preset '{args.preset}' 开启认证但无可用的白名单用户("
                f"被 concurrency=0 禁用或未配置), 认证不会拦截任何人。",
                file=sys.stderr,
            )
        for u in active:
            conc = int(u.get("concurrency", DEFAULT_CONC))
            desc = "无限" if conc == CONC_UNLIMITED else str(conc)
            print(
                f"#   {u.get('username','')} -> concurrency={desc}; "
                f"hash 由 htpasswd -nbB {u.get('username','')} '<密码>' 生成后填入",
                file=sys.stderr,
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
