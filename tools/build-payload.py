#!/usr/bin/env python3
"""tools/build-payload.py —— payload 的**规范实现**（两层版）：打包、校验、自测（ADR-024）。

两层（2026-10-18 裁决）:
    node 层：node + npm + pnpm          → base/node/          （不随 DSH 版本变）
    dsh  层：dsh 树 + bin wrapper       → base/dsh-<baked>/   （每个 baked 一份）

产物（每个层两件套，成对投递）:
    node-<ver>.tar.gz    + node.json
    dsh-<baked>.tar.gz   + dsh.json

为什么清单与归档分开：sha256 不能写进被它哈希的归档里（自指）。
    归档内：<kind>.meta.json（自描述，无 sha256）
    归档外：<kind>.json（meta + sha256 + size，壳的校验依据）

确定性（可复现构建）:
    条目排序 · uid/gid=0 · uname/gname 空 · mtime 固定（SOURCE_DATE_EPOCH，默认 1704067200）
    · gzip mtime=0 → 同样输入永远同一个 sha256，sha256 才有资格当版本锚点。

用法:
    python3 tools/build-payload.py --kind node --version 24.21.0 --pnpm 11.28.5 --stage DIR
    python3 tools/build-payload.py --kind dsh  --baked 0.2.0-rc.2 --stage DIR
    python3 tools/build-payload.py --verify FILE --manifest node.json
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

KINDS = {
    "node": {"meta": "node.meta.json", "required": ("bin/node",)},
    "dsh": {"meta": "dsh.meta.json", "required": ("dsh/package.json",)},
}


def die(msg):
    print("错误: " + msg, file=sys.stderr)
    sys.exit(2)


def ledger_baked(path=None):
    """dsh 层的默认 baked：烘焙台账（baseline/bake-ledger.json）的最后一条。

    与 tools/gen-version.py 同一个来源 —— 构建器与生成器不许各自有一份 baked（ADR-025）。
    """
    path = path or os.path.join(ROOT, "baseline", "bake-ledger.json")
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    bakes = data.get("bakes") or []
    if not bakes:
        return None
    return bakes[-1].get("baked")


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def collect(stage):
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


def build(kind, stage, out_dir, version, epoch=DEFAULT_EPOCH, pnpm=None):
    spec = KINDS[kind]
    for req in spec["required"]:
        if not os.path.exists(os.path.join(stage, req)):
            die(kind + " 层缺少必需项: " + req)

    meta = {"schema": 1, "layer": kind, "created_at": epoch}
    if kind == "node":
        # 清单不许替使用者猜 pnpm 版本：写错了就是「层与清单说的不是一回事」
        if not pnpm:
            die("node 层必须给 --pnpm（钉死的 pnpm 版本）")
        meta["version"] = version
        meta["pnpm"] = pnpm
    else:
        meta["baked"] = version
        meta["distro"] = {"name": "ubuntu", "release": "noble", "version": "24.04", "libc": "glibc"}
    with open(os.path.join(stage, spec["meta"]), "w", encoding="utf-8") as fh:
        fh.write(json.dumps(meta, ensure_ascii=False, indent=2) + "\n")

    os.makedirs(out_dir, exist_ok=True)
    tar_path = os.path.join(out_dir, "%s-%s.tar.gz" % (kind, version))
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as tar:
        for k, rel, extra in collect(stage):
            info = tarfile.TarInfo(rel)
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mtime = epoch
            if k == "dir":
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                tar.addfile(info)
            elif k == "link":
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
    manifest_path = os.path.join(out_dir, kind + ".json")
    with open(manifest_path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    return tar_path, manifest_path, digest, size


def verify(tar_path, manifest_path, quiet=False):
    with open(manifest_path, encoding="utf-8") as fh:
        manifest = json.load(fh)
    kind = manifest.get("layer")
    if kind not in KINDS:
        if not quiet:
            print("FAIL 清单里的 layer 不认识: %r" % (kind,), file=sys.stderr)
        return 1
    digest = sha256_of(tar_path)
    problems = []
    if manifest.get("sha256") != digest:
        problems.append("sha256 不匹配：清单 %s / 实际 %s" % (manifest.get("sha256"), digest))
    if manifest.get("size") != os.path.getsize(tar_path):
        problems.append("size 不匹配")
    with tarfile.open(tar_path, "r:gz") as tar:
        names = tar.getnames()
        if KINDS[kind]["meta"] not in names:
            problems.append("归档里没有 " + KINDS[kind]["meta"])
        else:
            inner = json.load(tar.extractfile(KINDS[kind]["meta"]))
            for key in ("version", "baked", "pnpm"):
                if key in manifest and inner.get(key) != manifest.get(key):
                    problems.append("meta 与清单不一致: %s（%s vs %s）"
                                    % (key, inner.get(key), manifest.get(key)))
    if problems:
        if not quiet:
            for p in problems:
                print("FAIL " + p, file=sys.stderr)
        return 1
    if not quiet:
        print("一致: %s（%s=%s sha256=%s… size=%d）"
              % (os.path.basename(tar_path), "baked" if kind == "dsh" else "version",
                 manifest.get("baked") or manifest.get("version"), digest[:12],
                 os.path.getsize(tar_path)))
    return 0


def _make_stage(root, kind):
    stage = os.path.join(root, "stage-" + kind)
    if kind == "node":
        os.makedirs(os.path.join(stage, "bin"))
        with open(os.path.join(stage, "bin", "node"), "w") as fh:
            fh.write("#!/bin/sh\necho v24.19.0\n")
        os.chmod(os.path.join(stage, "bin", "node"), 0o755)
        os.symlink("bin/node", os.path.join(stage, "node"))
    else:
        os.makedirs(os.path.join(stage, "dsh"))
        with open(os.path.join(stage, "dsh", "package.json"), "w") as fh:
            fh.write('{"name":"@deepseek-ai/dsh","version":"0.2.0-rc.2"}\n')
    return stage


def selftest():
    import shutil
    tmp = tempfile.mkdtemp(prefix="payload-selftest.")
    ok = True
    try:
        for kind, version in (("node", "24.21.0"), ("dsh", "0.2.0-rc.2")):
            stage = _make_stage(tmp, kind)
            o1, o2 = os.path.join(tmp, "o1-" + kind), os.path.join(tmp, "o2-" + kind)
            t1, m1, d1, _ = build(kind, stage, o1, version, pnpm="11.28.5")
            t2, m2, d2, _ = build(kind, stage, o2, version, pnpm="11.28.5")
            if d1 != d2:
                print("FAIL 非确定性（%s）：两次构建 sha256 不同" % kind)
                ok = False
            if verify(t1, m1) != 0:
                ok = False
            with open(t1, "ab") as fh:
                fh.write(b"tamper")
            if verify(t1, m1, quiet=True) == 0:
                print("FAIL 篡改后的包竟然通过了校验（%s）" % kind)
                ok = False
        if ok:
            print("自测通过：两层各自确定性构建 + 校验 + 篡改检测")
        return 0 if ok else 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main(argv):
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--kind", choices=sorted(KINDS))
    ap.add_argument("--stage")
    ap.add_argument("--out", default=os.path.join(ROOT, "build"))
    ap.add_argument("--version")
    ap.add_argument("--baked")
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
    if not args.kind or not args.stage:
        die("需要 --kind 与 --stage（或 --selftest / --verify）")

    if args.kind == "node":
        # 不替使用者猜版本：写错一个数字，manifest 就会指向一份不存在的层
        if not args.version:
            die("node 层必须给 --version（钉死的 Node 版本）")
        if not args.pnpm:
            die("node 层必须给 --pnpm（钉死的 pnpm 版本）")
        version = args.version
    else:
        baked = ledger_baked()
        version = args.baked or baked
        if not version:
            die("dsh 层需要 --baked，或 baseline/bake-ledger.json 的最后一条")
        if baked and args.baked and args.baked != baked:
            die("--baked(%s) 与烘焙台账最后一条的 baked(%s) 不一致" % (args.baked, baked))

    tar_path, manifest_path, digest, size = build(args.kind, args.stage, args.out,
                                                  version, args.epoch, args.pnpm)
    print("写入 %s（%d 字节，sha256 %s…）" % (os.path.relpath(tar_path, ROOT), size, digest[:12]))
    print("写入 %s" % os.path.relpath(manifest_path, ROOT))
    print("layer=%s version=%s" % (args.kind, version))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
