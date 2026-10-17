#!/usr/bin/env python3
"""tools/build-payload.py —— payload 的**规范实现**：打包、校验、自测（ADR-024）。

payload 是什么：模块 zip 之外那个"真正的大件"（Ubuntu 侧 runtime + Node + DSH 基线）。
它不随模块分发（ADR-024 决定 A），而是作为独立产物落到 inbox 或 Release。

产物（两个文件，放进 inbox 即成对）:
    payload-<baked>.tar.gz     内容: payload.meta.json + node/ + dsh/ + bin/
    payload.json               旁挂清单: 上述 meta + sha256 + size（壳读这个）

为什么 meta 与清单分开：sha256 不能写进被它哈希的归档里（自指）。所以
    - 归档内: payload.meta.json（自描述，无 sha256）
    - 归档外: payload.json（= meta + sha256 + size，壳的校验依据）
解包后壳还会比对两者的 baked，防止"清单说的和包里装的不是一回事"。

确定性（可复现构建）:
    条目排序 · uid/gid=0 · uname/gname 空 · mtime 固定（SOURCE_DATE_EPOCH，默认 1704067200）
    · gzip mtime=0 → 同样的输入永远得到同一个 sha256，sha256 才有资格当版本锚点。

用法:
    python3 tools/build-payload.py --stage DIR [--out DIR] [--baked V] [--node V] [--pnpm V]
    python3 tools/build-payload.py --verify FILE --manifest payload.json
    python3 tools/build-payload.py --selftest
"""

import argparse
import gzip
import hashlib
import io
import json
import os
import sys
import tarfile
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DEFAULT_EPOCH = 1704067200  # 2024-01-01T00:00:00Z
META_NAME = "payload.meta.json"
REQUIRED = ("node/bin/node", "dsh/package.json")


def die(msg):
    print("错误: " + msg, file=sys.stderr)
    sys.exit(2)


def read_env(path=None):
    path = path or os.path.join(ROOT, "tools", "version.env")
    env = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def collect(stage):
    """按相对路径排序收集文件（符号链接单独处理）。"""
    entries = []
    for base, dirs, files in os.walk(stage):
        dirs.sort()
        rel_base = os.path.relpath(base, stage)
        if rel_base == ".":
            rel_base = ""
        for name in sorted(dirs + files):
            full = os.path.join(base, name)
            rel = os.path.join(rel_base, name) if rel_base else name
            if os.path.islink(full):
                entries.append(("link", rel, os.readlink(full)))
            elif os.path.isdir(full):
                entries.append(("dir", rel, None))
            elif os.path.isfile(full):
                entries.append(("file", rel, full))
    entries.sort(key=lambda e: e[1])
    return entries


def build(stage, out_dir, baked, node_ver, pnpm_ver, epoch=DEFAULT_EPOCH):
    for req in REQUIRED:
        if not os.path.exists(os.path.join(stage, req)):
            die("stage 缺少必需项: " + req)

    meta = {
        "schema": 1,
        "baked": baked,
        "node": node_ver,
        "pnpm": pnpm_ver,
        "distro": {"name": "ubuntu", "release": "noble", "version": "24.04", "libc": "glibc"},
        "layer": baked,
        "created_at": epoch,
    }
    with open(os.path.join(stage, META_NAME), "w", encoding="utf-8") as fh:
        fh.write(json.dumps(meta, ensure_ascii=False, indent=2) + "\n")

    os.makedirs(out_dir, exist_ok=True)
    tar_path = os.path.join(out_dir, "payload-%s.tar.gz" % baked)
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as tar:
        for kind, rel, extra in collect(stage):
            info = tarfile.TarInfo(rel)
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mtime = epoch
            if kind == "dir":
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                tar.addfile(info)
            elif kind == "link":
                info.type = tarfile.SYMTYPE
                info.linkname = extra
                info.mode = 0o777
                tar.addfile(info)
            else:
                with open(extra, "rb") as fh:
                    data = fh.read()
                info.size = len(data)
                info.mode = 0o755 if os.access(extra, os.X_OK) else 0o644
                tar.addfile(info, io.BytesIO(data))

    with open(tar_path, "wb") as fh:
        with gzip.GzipFile(fileobj=fh, mode="wb", compresslevel=9, mtime=0) as gz:
            gz.write(raw.getvalue())

    digest = sha256_of(tar_path)
    size = os.path.getsize(tar_path)
    manifest = dict(meta, sha256=digest, size=size)
    manifest_path = os.path.join(out_dir, "payload.json")
    with open(manifest_path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    return tar_path, manifest_path, digest, size


def verify(tar_path, manifest_path):
    with open(manifest_path, encoding="utf-8") as fh:
        manifest = json.load(fh)
    digest = sha256_of(tar_path)
    problems = []
    if manifest.get("sha256") != digest:
        problems.append("sha256 不匹配：清单 %s / 实际 %s" % (manifest.get("sha256"), digest))
    if manifest.get("size") != os.path.getsize(tar_path):
        problems.append("size 不匹配")
    with tarfile.open(tar_path, "r:gz") as tar:
        names = tar.getnames()
        if META_NAME not in names:
            problems.append("归档里没有 " + META_NAME)
        else:
            inner = json.load(tar.extractfile(META_NAME))
            for key in ("baked", "node", "pnpm"):
                if inner.get(key) != manifest.get(key):
                    problems.append("meta 与清单不一致: %s（%s vs %s）"
                                    % (key, inner.get(key), manifest.get(key)))
    if problems:
        for p in problems:
            print("FAIL " + p, file=sys.stderr)
        return 1
    print("一致: %s（baked=%s sha256=%s… size=%d）"
          % (os.path.basename(tar_path), manifest.get("baked"), digest[:12], os.path.getsize(tar_path)))
    return 0


def selftest():
    import shutil
    tmp = tempfile.mkdtemp(prefix="payload-selftest.")
    try:
        stage = os.path.join(tmp, "stage")
        os.makedirs(os.path.join(stage, "node", "bin"))
        os.makedirs(os.path.join(stage, "dsh"))
        with open(os.path.join(stage, "node", "bin", "node"), "w") as fh:
            fh.write("#!/bin/sh\necho v24.19.0\n")
        os.chmod(os.path.join(stage, "node", "bin", "node"), 0o755)
        with open(os.path.join(stage, "dsh", "package.json"), "w") as fh:
            fh.write('{"name":"@deepseek-ai/dsh","version":"0.2.0-rc.2"}\n')
        os.symlink("bin/node", os.path.join(stage, "node", "node"))

        out1 = os.path.join(tmp, "out1")
        out2 = os.path.join(tmp, "out2")
        t1, m1, d1, s1 = build(stage, out1, "0.2.0-rc.2", "24.19.0", "11.0.0")
        t2, m2, d2, s2 = build(stage, out2, "0.2.0-rc.2", "24.19.0", "11.0.0")
        ok = True
        if d1 != d2:
            print("FAIL 非确定性：两次构建 sha256 不同 %s vs %s" % (d1, d2))
            ok = False
        if verify(t1, m1) != 0:
            ok = False
        # 篡改后必须失败
        with open(t1, "ab") as fh:
            fh.write(b"tamper")
        if verify(t1, m1) == 0:
            print("FAIL 篡改后的包竟然通过了校验")
            ok = False
        if ok:
            print("自测通过：确定性构建 + 校验 + 篡改检测")
        return 0 if ok else 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main(argv):
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--stage")
    ap.add_argument("--out", default=os.path.join(ROOT, "build"))
    ap.add_argument("--baked")
    ap.add_argument("--node")
    ap.add_argument("--pnpm")
    ap.add_argument("--epoch", type=int, default=DEFAULT_EPOCH)
    ap.add_argument("--verify")
    ap.add_argument("--manifest")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()
    if args.verify:
        if not args.manifest:
            die("--verify 必须同时给 --manifest")
        return verify(args.verify, args.manifest)
    if not args.stage:
        die("需要 --stage DIR（或 --selftest / --verify）")

    env = read_env()
    baked = args.baked or env.get("DSH_BAKED")
    if not baked:
        die("拿不到 baked 版本：--baked 或 tools/version.env 的 DSH_BAKED")
    if env.get("DSH_BAKED") and args.baked and args.baked != env["DSH_BAKED"]:
        die("--baked(%s) 与 version.env 的 DSH_BAKED(%s) 不一致" % (args.baked, env["DSH_BAKED"]))

    node_ver = args.node or os.environ.get("PAYLOAD_NODE") or "24.19.0"
    pnpm_ver = args.pnpm or os.environ.get("PAYLOAD_PNPM") or "11.0.0"
    tar_path, manifest_path, digest, size = build(args.stage, args.out, baked, node_ver, pnpm_ver, args.epoch)
    print("写入 %s（%d 字节，sha256 %s…）" % (os.path.relpath(tar_path, ROOT), size, digest[:12]))
    print("写入 %s" % os.path.relpath(manifest_path, ROOT))
    print("baked=%s node=%s pnpm=%s" % (baked, node_ver, pnpm_ver))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
