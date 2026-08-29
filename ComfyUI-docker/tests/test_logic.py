#!/usr/bin/env python3
"""ComfyUI-docker 逻辑验证(不依赖 Docker, 可在 Git Bash/Linux/WSL2/容器内运行)。

验证对象:
  1. resolve_preset.py --json  对每个预设输出正确的 access/port/auth_enabled/auth_users/resources
  2. entrypoint.sh            生成正确的 main.py 启动参数(监听地址/端口/资源/预设 args)
  3. gen_auth.py              生成包含 BasicAuth + limit_conn + 自定义端口的 nginx.conf

用法:
  python tests/test_logic.py
退出码 0 = 全部通过; 非 0 = 有失败(打印明细)。
"""
import json
import os
import subprocess
import sys
import tempfile

# 统一 stdout 编码,避免 Windows GBK 控制台在打印非 ASCII 时报 UnicodeEncodeError
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CFG_PATH = os.path.join(ROOT, "comfyui.json")
RESOLVE = os.path.join(ROOT, "docker", "resolve_preset.py")
ENTRYPOINT = os.path.join(ROOT, "docker", "entrypoint.sh")
GEN_AUTH = os.path.join(ROOT, "docker", "gen_auth.py")

FAILURES = []


def check(name, ok, detail=""):
    tag = "PASS" if ok else "FAIL"
    print(f"  [{tag}] {name}" + (f" | {detail}" if detail else ""))
    if not ok:
        FAILURES.append(name)


def load_cfg():
    with open(CFG_PATH, encoding="utf-8") as f:
        return json.load(f)


def resolve(preset):
    r = subprocess.run(
        [sys.executable, RESOLVE, preset, CFG_PATH, "--json"],
        capture_output=True, text=True,
    )
    return r.returncode, r.stdout.strip()


def run_entrypoint(stub_dir, comyui_config, extra_args=None, env=None):
    """在 stub 目录里跑 entrypoint(用假 main.py 打印 argv),返回 main.py 收到的 argv。"""
    env2 = dict(os.environ)
    env2["COMYUI_CONFIG"] = comyui_config
    env2["RESOLVE_PRESET_PY"] = RESOLVE
    if env:
        env2.update(env)
    cmd = ["bash", ENTRYPOINT]
    if extra_args:
        cmd += extra_args
    r = subprocess.run(cmd, cwd=stub_dir, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", env=env2)
    # main.py 输出 "RECV: [..]" 的行
    recv = []
    for line in r.stdout.splitlines():
        if line.startswith("RECV:"):
            recv = eval(line[len("RECV:"):].strip())
    return r.returncode, recv, r.stdout, r.stderr


def main() -> int:
    data = load_cfg()
    presets = data["presets"]

    print("== 1) resolve_preset.py --json 逐预设 ==")
    name2expect = {
        "gpu":        dict(access="inner", auth=True,  vram=8, port=8189),
        "gpu-public": dict(access="public", auth=True,  vram=8, port=8190),
        "cpu":        dict(access="inner", auth=True,  vram=None, port=8191),
        "cpu-public": dict(access="public", auth=True, vram=None, port=8192),
        "cpu-noauth": dict(access="inner", auth=False, vram=None, port=8198),
        "lowvram":    dict(access="inner", auth=True,  vram=2, port=8194),
    }
    for p in presets:
        rc, out = resolve(p["name"])
        ok = rc == 0 and out
        if ok:
            d = json.loads(out)
            exp = name2expect.get(p["name"])
            if exp:
                ok = (d["access"] == exp["access"]
                      and d["auth_enabled"] == exp["auth"]
                      and d.get("port") == exp["port"]
                      and (d.get("resources", {}).get("reserve_vram_gb")
                           is not None) == (exp["vram"] is not None))
                if exp["vram"] is not None:
                    ok = ok and d["resources"]["reserve_vram_gb"] == exp["vram"]
        check(f"resolve preset '{p['name']}'", ok, out[:90])

    # 默认 preset 应与 JSON default_preset 一致
    rc, out = resolve(data.get("default_preset", "gpu"))
    check("default_preset 可 resolve", rc == 0 and bool(out), out[:60])

    # auth_users 白名单: gpu 允许 admin; 校验非白名单被排除
    rc, out = resolve("gpu")
    d = json.loads(out)
    check("auth_users 白名单含 admin", "admin" in d.get("auth_users", []),
          str(d.get("auth_users")))
    rc, out = resolve("cpu-noauth")
    d = json.loads(out)
    check("cpu-noauth auth_enabled=False & 空白名单",
          d.get("auth_enabled") is False and d.get("auth_users") == [],
          str(d.get("auth_enabled")) + str(d.get("auth_users")))

    print("== 2) entrypoint.sh 生成启动参数 ==")
    with tempfile.TemporaryDirectory() as td:
        stub = os.path.join(td, "comfyui")
        os.makedirs(stub, exist_ok=True)
        main_py = os.path.join(stub, "main.py")
        with open(main_py, "w", encoding="utf-8") as f:
            f.write("import sys\nprint('RECV:', sys.argv[1:])\n")
        cfg_path = os.path.join(td, "comfyui.json")
        with open(cfg_path, "w", encoding="utf-8") as f:
            f.write(json.dumps(data))

        def assert_args(kind, want_subset, cmd=None, env=None):
            rc, argv, so, se = run_entrypoint(
                stub, cfg_path, extra_args=cmd, env=env)
            ok = rc == 0 and all(w in argv for w in want_subset)
            check(kind, ok, f"argv={argv} rc={rc}")
            return argv, se

        # 容器内一律 --listen 0.0.0.0; 端口用 preset.port(未设 EXPOSE_PORT 时)
        argv, _ = assert_args("gpu 默认(0.0.0.0 + preset port + vram8)",
                              ["--listen", "0.0.0.0", "--port", "8189", "--reserve-vram", "8"])
        # EXPOSE_PORT 环境变量覆盖端口
        argv, _ = assert_args("gpu 显式 EXPOSE_PORT=9090",
                              ["--port", "9090"],
                              env={"EXPOSE_PORT": "9090"})
        # cpu: 无 vram保留,有 --cpu, port=8191
        assert_args("cpu(无 vram保留,有 --cpu, port=8191)",
                    ["--cpu", "--port", "8191"], env={"PRESET": "cpu"})
        # lowvram + 透传额外参数
        argv, _ = assert_args("lowvram + 透传 --listen",
                              ["--reserve-vram", "2", "--lowvram", "--listen", "0.0.0.0"],
                              cmd=["--preset=lowvram", "--listen", "0.0.0.0"])
        # EXTRA_ARGS 追加
        assert_args("EXTRA_ARGS 追加",
                    ["--fast", "--quiet", "--cpu"],
                    env={"EXTRA_ARGS": "--fast --quiet", "PRESET": "cpu"})

    print("== 3) gen_auth.py 生成 nginx.conf ==")
    # 认证开启预设(取 preset.port)
    r = subprocess.run(
        [sys.executable, GEN_AUTH, CFG_PATH, "--preset", "gpu"],
        capture_output=True, text=True,
        encoding="utf-8", errors="replace")
    conf = r.stdout
    ok = r.returncode == 0
    lpp = json.loads(subprocess.run(
        [sys.executable, RESOLVE, "gpu", CFG_PATH, "--json"],
        capture_output=True, text=True).stdout)["port"]
    ok = ok and f"listen {lpp};" in conf
    ok = ok and "auth_basic " in conf
    ok = ok and "auth_basic_user_file" in conf
    ok = ok and "limit_conn conn0 " in conf   # 每用户独立 zone+常量 limit_conn(admin concurrency=2)
    ok = ok and "proxy_pass http://comfyui" in conf
    check(f"nginx.conf(auth preset gpu, port {lpp}, auth+limit_conn+proxy)", ok)
    # 认证关闭预设(cpu-noauth): 不应含 auth_basic
    r = subprocess.run(
        [sys.executable, GEN_AUTH, CFG_PATH, "--preset", "cpu-noauth"],
        capture_output=True, text=True,
        encoding="utf-8", errors="replace")
    conf = r.stdout
    ok = r.returncode == 0 and "auth_basic" not in conf
    check("nginx.conf(no-auth preset cpu-noauth): 无 auth_basic", ok)

    print("== 3b) gen_auth.py 用户并发(concurrency) + 可选 HTTPS ==")
    # 用临时 comfyui.json 验证: 每用户 concurrency(-1/3/0/缺省)映射 + 0用户不进map
    tmp_cfg = {
        "default_preset": "gpu",
        "auth": {
            "realm": "ComfyUI",
            "users": [
                {"username": "admin", "hash": "$2b$10$x", "concurrency": -1},
                {"username": "bob", "hash": "$2b$10$y", "concurrency": 3},
                {"username": "banned", "hash": "$2b$10$z", "concurrency": 0},
                {"username": "plain", "hash": "$2b$10$w"},
            ],
        },
        "presets": [{
            "name": "gpu", "access": "inner", "port": 8189,
            "auth": {"enabled": True, "auth_users": ["admin", "bob", "banned", "plain"]},
            "args": [], "resources": {"reserve_vram_gb": 8},
        }],
    }
    with tempfile.TemporaryDirectory() as td:
        cfg2 = os.path.join(td, "comfyui2.json")
        with open(cfg2, "w", encoding="utf-8") as f:
            json.dump(tmp_cfg, f)
        r = subprocess.run(
            [sys.executable, GEN_AUTH, cfg2, "--preset", "gpu"],
            capture_output=True, text=True, encoding="utf-8", errors="replace")
        conf = r.stdout
        ok = r.returncode == 0
        # 每用户独立 zone + 常量 limit_conn(admin -1 无限、banned 0 禁用 -> 不生成)
        ok = ok and "map $remote_user $lim0 { bob bob; }" in conf    # bob(3) 第一个有限额用户
        ok = ok and "limit_conn_zone $lim0 zone=conn0:10m;" in conf
        ok = ok and "limit_conn conn0 3;" in conf                    # bob 额度 3
        ok = ok and "map $remote_user $lim1 { plain plain; }" in conf  # plain(缺省1)
        ok = ok and "limit_conn_zone $lim1 zone=conn1:10m;" in conf
        ok = ok and "limit_conn conn1 1;" in conf                    # plain 缺省 => 1
        # admin(-1 无限) 与 banned(0 禁用) 都不应出现在 nginx.conf(不生成 zone/map/limit)
        ok = ok and "admin" not in conf
        ok = ok and "banned" not in conf
        # 恰好 2 个有限额用户 zone(conn0=bob, conn1=plain), 不再有其它用户 zone
        ok = ok and conf.count("zone=conn") == 2
        # 绝不允许 limit_conn 用变量作额度(会致 nginx "invalid number of connections" 启动失败)
        ok = ok and "limit_conn " + "$" not in conf
        check("用户并发(每用户独立 zone+常量; -1无限/3/0禁用/缺省1)", ok)

        # HTTPS: 证书存在 => 443 ssl + 80 重定向
        certs = os.path.join(td, "certs")
        os.makedirs(certs, exist_ok=True)
        with open(os.path.join(certs, "fullchain.pem"), "w") as f:
            f.write("FAKE_CERT")
        with open(os.path.join(certs, "privkey.pem"), "w") as f:
            f.write("FAKE_KEY")
        r = subprocess.run(
            [sys.executable, GEN_AUTH, cfg2, "--preset", "gpu", "--certs-dir", certs],
            capture_output=True, text=True, encoding="utf-8", errors="replace")
        conf = r.stdout
        ok = r.returncode == 0
        ok = ok and "listen 443 ssl;" in conf
        ok = ok and "listen 80;" in conf
        ok = ok and "return 301 https://$host$request_uri;" in conf
        ok = ok and "ssl_certificate" in conf
        check("可选 HTTPS(有证书 -> 443 ssl + 80 重定向)", ok)

        # 无证书 => 仍纯 HTTP
        r = subprocess.run(
            [sys.executable, GEN_AUTH, cfg2, "--preset", "gpu", "--certs-dir", os.path.join(td, "nocerts")],
            capture_output=True, text=True, encoding="utf-8", errors="replace")
        conf = r.stdout
        ok = r.returncode == 0
        ok = ok and "listen 8189;" in conf
        ok = ok and "listen 443 ssl;" not in conf
        check("默认无证书 - HTTP 保持", ok)

    if FAILURES:
        print(f"\n{'='*50}\nFAILED: {len(FAILURES)} 项:")
        for f in FAILURES:
            print("  - " + f)
        return 1
    print("\nALL_LOGIC_OK: 全部逻辑验证通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
