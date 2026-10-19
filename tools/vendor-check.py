#!/usr/bin/env python3
"""vendor 基准线校验：仓库内第三方资料的哈希 + DSH 层逐文件清单。

用法:
    python3 tools/vendor-check.py                 # 校验 vendor/ 里的文件哈希
    python3 tools/vendor-check.py --stage DIR     # 校验已组装的 DSH 树
    python3 tools/vendor-check.py --write-tree DIR # 重新生成 vendor/dsh/tree.sha256

清单格式（按路径排序后逐行哈希，最后一行是聚合值）:
    D <mode> <path>
    F <mode> <sha256> <path>
    L <target> <path>
    # aggregate <sha256>

退出码: 0 一致 / 1 不一致
"""
import argparse
import hashlib
import json
import os
import stat
import sys
import tarfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
VENDOR = os.path.join(ROOT, "vendor")
DSH_SOURCE = os.path.join(VENDOR, "dsh", "SOURCE.json")
TREE_MANIFEST = os.path.join(VENDOR, "dsh", "tree.sha256")

# 构建输入，不是运行时内容；不应进入层清单
EXCLUDE = {
    "npm-shrinkwrap.json",
    "node_modules/.package-lock.json",
}


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def tree_entries(root):
    lines = []
    for base, dirs, files in os.walk(root):
        dirs.sort()
        files.sort()
        rel_base = os.path.relpath(base, root)
        if rel_base == ".":
            rel_base = ""
        for name in dirs:
            rel = os.path.join(rel_base, name) if rel_base else name
            if rel in EXCLUDE:
                continue
            # 目录权限由 payload 构建器统一写成 755；清单也按 755 记录，
            # 这样「安装树（npm 创建时 700）」与「解包后的层」都对得上。
            lines.append("D 755 %s" % rel)
        for name in files:
            rel = os.path.join(rel_base, name) if rel_base else name
            if rel in EXCLUDE:
                continue
            full = os.path.join(base, name)
            st = os.lstat(full)
            if stat.S_ISLNK(st.st_mode):
                lines.append("L %s %s" % (os.readlink(full), rel))
            elif stat.S_ISREG(st.st_mode):
                # payload 构建器只保留「可执行 / 不可执行」两档：755 / 644。
                # 清单按同一规则记录，安装树（npm 常写成 600）与解包后的层才对得上。
                mode = 0o755 if (st.st_mode & 0o111) else 0o644
                lines.append("F %o %s %s" % (mode, sha256_file(full), rel))
            else:
                lines.append("O %o %s" % (st.st_mode, rel))
    lines.sort()
    return lines


def aggregate(lines):
    h = hashlib.sha256()
    for line in lines:
        h.update(line.encode("utf-8") + b"\n")
    return h.hexdigest()


def write_tree(root):
    lines = tree_entries(root)
    os.makedirs(os.path.dirname(TREE_MANIFEST), exist_ok=True)
    with open(TREE_MANIFEST, "w", encoding="utf-8") as fh:
        for line in lines:
            fh.write(line + "\n")
        fh.write("# aggregate " + aggregate(lines) + "\n")
    print("写入 vendor/dsh/tree.sha256（%d 行，aggregate %s…）"
          % (len(lines), aggregate(lines)[:12]))
    return 0


def check_tree(root, manifest=TREE_MANIFEST):
    if not os.path.exists(manifest):
        print("FAIL 找不到 " + os.path.relpath(manifest, ROOT), file=sys.stderr)
        return 1
    want = []
    want_agg = None
    with open(manifest, encoding="utf-8") as fh:
        for line in fh.read().splitlines():
            if line.startswith("# aggregate "):
                want_agg = line.split()[-1]
            elif line:
                want.append(line)
    got = tree_entries(root)
    got_agg = aggregate(got)
    if got == want and got_agg == want_agg:
        print("一致: 树清单 %d 项（aggregate %s…）" % (len(got), got_agg[:12]))
        return 0
    print("FAIL 树与 vendor/dsh/tree.sha256 不一致", file=sys.stderr)
    if got_agg != want_agg:
        print("  聚合值：期望 %s / 实得 %s" % (want_agg, got_agg), file=sys.stderr)
    want_set, got_set = set(want), set(got)
    only_want = sorted(want_set - got_set)[:10]
    only_got = sorted(got_set - want_set)[:10]
    for line in only_want:
        print("  缺少: " + line, file=sys.stderr)
    for line in only_got:
        print("  多出: " + line, file=sys.stderr)
    return 1


def check_source(source_path):
    with open(source_path, encoding="utf-8") as fh:
        src = json.load(fh)
    base = os.path.dirname(source_path)
    problems = []

    for name, want in src.get("files", {}).items():
        path = os.path.join(base, name)
        if not os.path.exists(path):
            problems.append("缺少 " + os.path.relpath(path, ROOT))
            continue
        got = sha256_file(path)
        if got != want:
            problems.append("%s sha256 期望 %s 实得 %s" % (name, want[:12], got[:12]))

    if src.get("package") == "@deepseek-ai/dsh":
        version = src["version"]
        tarball = os.path.join(base, "dsh-%s.tgz" % version)
        lock = os.path.join(base, src["lockfile"])
        for path, want in ((tarball, src["tarball_sha256"]), (lock, src["lockfile_sha256"])):
            if not os.path.exists(path):
                problems.append("缺少 " + os.path.relpath(path, ROOT))
            elif sha256_file(path) != want:
                problems.append(os.path.basename(path) + " sha256 不一致")
        # 解包后的 package/ 必须与 tarball 内的一致
        pkg = os.path.join(base, "package")
        if os.path.exists(tarball) and os.path.isdir(pkg):
            with tarfile.open(tarball, "r:gz") as tar:
                members = [m for m in tar.getmembers() if m.isfile() and m.name.startswith("package/")]
                for m in members:
                    rel = m.name[len("package/"):]
                    path = os.path.join(pkg, rel)
                    if not os.path.exists(path):
                        problems.append("解包缺少 " + rel)
                        continue
                    if sha256_file(path) != hashlib.sha256(tar.extractfile(m).read()).hexdigest():
                        problems.append("解包内容与 tarball 不一致: " + rel)
        if not os.path.exists(TREE_MANIFEST):
            problems.append("缺少 vendor/dsh/tree.sha256")
        elif src.get("tree_manifest_sha256") and sha256_file(TREE_MANIFEST) != src["tree_manifest_sha256"]:
            problems.append("tree.sha256 自身的 sha256 与 SOURCE.json 不一致")

    if problems:
        for p in problems:
            print("FAIL " + p, file=sys.stderr)
        return 1
    print("一致: " + os.path.relpath(source_path, ROOT))
    return 0


def main(argv):
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--stage")
    ap.add_argument("--write-tree")
    args = ap.parse_args(argv)

    if args.write_tree:
        return write_tree(args.write_tree)
    if args.stage:
        return check_tree(args.stage)

    rc = 0
    rc |= check_source(os.path.join(VENDOR, "chroot-distro", "SOURCE.json"))
    rc |= check_source(DSH_SOURCE)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
