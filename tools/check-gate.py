#!/usr/bin/env python3
"""三份实现对照同一张表 —— 版本闸门的防漂移检查。

spec/gate-vectors.json 是唯一规格；本脚本把表摊平成 TSV，喂给每个实现，
逐行比对输出。任何一个实现与规格不一致就退出 1。

用法:
    python3 tools/check-gate.py               # 全部实现（python / dash / bash --posix / node）
    python3 tools/check-gate.py --only node   # 只跑名字含 node 的实现
    python3 tools/check-gate.py -v            # 打印每条向量

退出码: 0 全部一致；1 有分歧或某实现跑不起来。
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import semver  # noqa: E402


def impls(tsv_path):
    """四个运行体；有 mksh 就再加一个（Android 的 /system/bin/sh 就是 mksh R59）。

    mksh 值得单独列：它在 ${s%%|*} 这类参数模式上的行为与 dash/bash 不同，
    本机全绿不代表设备全绿（2026-10-17 真机实测踩过）。
    """
    sh_lib = os.path.join("lib", "semver-gate.sh")
    out = [
        ("python", [sys.executable, os.path.join("tools", "semver.py"), "--batch", tsv_path]),
        ("sh/dash", ["dash", sh_lib, "batch", tsv_path]),
        ("sh/bash", ["bash", "--posix", sh_lib, "batch", tsv_path]),
        ("node", ["node", os.path.join("lib", "semver-gate.mjs"), "batch", tsv_path]),
    ]
    if shutil.which("mksh"):
        out.insert(3, ("sh/mksh", ["mksh", sh_lib, "batch", tsv_path]))
    return out


def main(argv):
    only = None
    verbose = False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--only" and i + 1 < len(argv):
            only = argv[i + 1]
            i += 1
        elif a in ("-v", "--verbose"):
            verbose = True
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            print("未知参数: " + a, file=sys.stderr)
            return 2
        i += 1

    spec = semver.load_spec()
    rows = semver.build_rows(spec)
    expect = [r[2] for r in rows]
    tsv = "".join(r[0] + "\t" + "\t".join(r[1]) + "\n" for r in rows)

    fd, tsv_path = tempfile.mkstemp(prefix="gate-vectors-", suffix=".tsv")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(tsv)

    print("向量 %d 条（compare %d / check %d / decide %d）· 规格 spec/gate-vectors.json" % (
        len(rows),
        sum(1 for r in rows if r[0] == "compare"),
        sum(1 for r in rows if r[0] == "check"),
        sum(1 for r in rows if r[0] == "decide")))
    print()

    failures = 0
    ran = 0
    for name, cmd in impls(tsv_path):
        if only and only not in name:
            continue
        ran += 1
        try:
            proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=120)
        except FileNotFoundError:
            print("%-10s 跳过：找不到可执行文件 %s" % (name, cmd[0]))
            failures += 1
            continue
        got = [ln for ln in proc.stdout.split("\n") if ln != ""]
        bad = []
        if len(got) != len(expect):
            bad.append(("<无>", (), "<%d 行>" % len(expect), "<%d 行>" % len(got), "输出行数不符"))
            if proc.stderr.strip():
                bad.append(("<stderr>", (), "", "", proc.stderr.strip().splitlines()[-1]))
        else:
            for row, e, g in zip(rows, expect, got):
                if e != g:
                    bad.append((row[0], row[1], e, g, row[3]))
        status = "OK" if not bad else "FAIL"
        print("%-10s %-4s %d/%d 条一致" % (name, status, len(rows) - len(bad), len(rows)))
        if bad:
            failures += 1
            for kind, args, e, g, why in bad[:10]:
                print("    %s %s 期望 %s 实得 %s  [%s]" % (kind, list(args), e, g, why))
            if len(bad) > 10:
                print("    …… 还有 %d 条不一致" % (len(bad) - 10))
        elif verbose:
            for row, g in zip(rows, got):
                print("    %s %s -> %s" % (row[0], list(row[1]), g))

    os.unlink(tsv_path)
    print()
    if failures:
        print("结果：%d 个实现与规格不一致" % failures)
        return 1
    print("结果：%d 个实现全部与规格一致（%d 条向量）" % (ran, len(rows)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
