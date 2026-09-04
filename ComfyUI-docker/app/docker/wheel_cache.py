#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ============================================================================
# wheel_cache.py —— ComfyUI 镜像构建期「下载产物哈希缓存」工具(权威=哈希)
#
# 设计契约(与 README「构建下载缓存(哈希权威)」一致):
#   1. 网络下载到本地缓存目录后, 必须立刻 ingest(同步计算 sha256 写清单),
#      绝不"下完就走、哈希以后再说"。
#   2. 之后任何一次构建要同版本前置时, 先 ensure: 对本地缓存文件【实算哈希】
#      与清单逐行对照 —— 全部一致才算 VALID。
#   3. 只有哈希不同(损坏/篡改/下载不完整)或缓存不可用(文件缺失/清单缺失)
#      这两种情况才允许再走网络下载; VALID 时下游必须离线安装、禁止联网。
#
# 目录布局:
#   <CACHE_ROOT>/<KEY>/                该 KEY 的网络下载产物(如 wheel 文件)
#   <CACHE_ROOT>/.manifests/<KEY>.sha256   清单: 每行 "sha256hex  filename"
#
# 用法:
#   wheel_cache.py ensure <CACHE_ROOT> <KEY>   # 0=VALID  1=INVALID  2=NOMANIFEST
#   wheel_cache.py ingest <CACHE_ROOT> <KEY>   # 扫描 <KEY>/ 下文件, 算哈希写清单(同步)
#   wheel_cache.py list   <CACHE_ROOT> <KEY>   # 打印当前清单(供诊断)
#
# ensure 退出码语义: Dockerfile 里 0 => 走"离线安装"分支; 1/2 => 走"联网回填"分支。
# 本工具只依赖标准库(sha256 逐块计算), 镜像内可直接运行。
# ============================================================================

import hashlib
import os
import sys

CHUNK = 1024 * 1024  # 1 MiB


def _sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            block = f.read(CHUNK)
            if not block:
                break
            h.update(block)
    return h.hexdigest()


def _manifest_path(root: str, key: str) -> str:
    return os.path.join(root, ".manifests", key + ".sha256")


def _key_dir(root: str, key: str) -> str:
    return os.path.join(root, key)


def _read_manifest(root: str, key: str):
    """返回 [(expected_sha256, filename), ...]; 无清单返回 None。"""
    mp = _manifest_path(root, key)
    if not os.path.isfile(mp):
        return None
    entries = []
    with open(mp, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            parts = line.split(None, 1)
            if len(parts) != 2:
                continue
            entries.append((parts[0], parts[1]))
    return entries


def _cmd_ensure(root: str, key: str) -> int:
    entries = _read_manifest(root, key)
    if entries is None:
        print("NOMANIFEST: no manifest for key '%s' -> cache unavailable, allow network" % key)
        return 2
    kdir = _key_dir(root, key)
    bad = []
    for expected, name in entries:
        p = os.path.join(kdir, name)
        if not os.path.isfile(p):
            bad.append("missing: %s" % name)
            continue
        actual = _sha256(p)
        if actual != expected:
            bad.append("hash-mismatch: %s (expected %s, got %s)" % (name, expected[:12], actual[:12]))
    if bad:
        print("INVALID: key '%s' has %d problem(s) -> cache NOT usable, allow network" % (key, len(bad)))
        for b in bad[:10]:
            print("  - " + b)
        return 1
    print("VALID: key '%s' (%d file(s)) hash-verified -> MUST use offline, no network" % (key, len(entries)))
    return 0


def _cmd_ingest(root: str, key: str) -> int:
    """下载完成后【同步】扫描 <KEY>/ 下所有文件, 算 sha256 并写回清单(原子)。"""
    kdir = _key_dir(root, key)
    if not os.path.isdir(kdir):
        print("ERROR: key dir not found: %s" % kdir, file=sys.stderr)
        return 3
    names = sorted(n for n in os.listdir(kdir)
                   if os.path.isfile(os.path.join(kdir, n)) and not n.endswith(".sha256"))
    if not names:
        print("ERROR: no files under %s to ingest" % kdir, file=sys.stderr)
        return 3
    lines = []
    total = 0
    for n in names:
        digest = _sha256(os.path.join(kdir, n))
        lines.append("%s  %s" % (digest, n))
        total += os.path.getsize(os.path.join(kdir, n))
    os.makedirs(os.path.dirname(_manifest_path(root, key)), exist_ok=True)
    tmp = _manifest_path(root, key) + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, _manifest_path(root, key))
    print("INGEST: key '%s' -> %d file(s), %d bytes, manifest written %s"
          % (key, len(names), total, _manifest_path(root, key)))
    return 0


def _cmd_list(root: str, key: str) -> int:
    entries = _read_manifest(root, key)
    if entries is None:
        print("NOMANIFEST: %s" % _manifest_path(root, key))
        return 2
    for expected, name in entries:
        print("%s  %s" % (expected, name))
    return 0


def main(argv) -> int:
    if len(argv) < 4:
        print(__doc__)
        return 3
    cmd, root, key = argv[1], argv[2], argv[3]
    if cmd == "ensure":
        return _cmd_ensure(root, key)
    if cmd == "ingest":
        return _cmd_ingest(root, key)
    if cmd == "list":
        return _cmd_list(root, key)
    print("ERROR: unknown command: %s" % cmd, file=sys.stderr)
    return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv))
