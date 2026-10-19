#!/usr/bin/env python3
"""semver 2.0.0 —— 本项目版本闸门的权威参考实现（Python 版）。

为什么单独写一个文件：版本比较是整套方案里**唯一一处写错会静默出错**的地方。
字符串比较在 "0.2.1-rc.1" vs "0.2.0-rc.2" 上给出相反答案，
而这类错误不会抛异常、不会进日志，只会让闸门放行错版本或错误地回滚。

三份实现（Python / POSIX sh / Node）必须与同一张表 spec/gate-vectors.json 逐条一致：
    python3 tools/check-gate.py

严格性（三份实现统一，不做 trim）:
  - 核心三段数字不允许前导零；必须恰好三段
  - prerelease 标识符只允许 [0-9A-Za-z-]，纯数字的标识符不允许前导零
  - build 元数据只允许 [0-9A-Za-z-]，可带前导零，且**不参与比较**

用法:
    python3 tools/semver.py                        # 跑 spec 里全部向量
    python3 tools/semver.py --batch vectors.tsv    # 每行「命令<TAB>参数…」→ 一行结果
    python3 tools/semver.py --decide A FLOOR BAKED # 策略层：-> "verdict reason safe_mode"
    from semver import compare, is_valid, decide
"""

import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SPEC_PATH = os.path.join(ROOT, "spec", "gate-vectors.json")

_SEMVER_RE = re.compile(
    r"^(0|[1-9][0-9]*)"
    r"\.(0|[1-9][0-9]*)"
    r"\.(0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)


def parse(version):
    """返回 (major, minor, patch, pre_tuple)；非法返回 None。

    pre_tuple 里：纯数字段是 int（数值比较），其余是 str（ASCII 字典序）。
    build 元数据解析后丢弃（不参与比较）。
    """
    if not isinstance(version, str):
        return None
    m = _SEMVER_RE.match(version)          # 严格：不做 strip
    if not m:
        return None
    pre = m.group(4)
    ids = []
    if pre:
        for part in pre.split("."):
            if part.isdigit():
                if len(part) > 1 and part[0] == "0":
                    return None            # 数字段前导零 → 非法
                ids.append(int(part))
            else:
                ids.append(part)
    return (int(m.group(1)), int(m.group(2)), int(m.group(3)), tuple(ids))


def is_valid(version):
    return parse(version) is not None


def _compare_pre(a, b):
    # 有 prerelease 的版本 < 无 prerelease 的版本
    if not a and not b:
        return 0
    if not a:
        return 1
    if not b:
        return -1
    for x, y in zip(a, b):
        x_num, y_num = isinstance(x, int), isinstance(y, int)
        if x_num and y_num:
            if x != y:
                return -1 if x < y else 1
            continue
        if x_num != y_num:
            return -1 if x_num else 1        # 数字段 < 字母段
        if x != y:
            return -1 if x < y else 1
    if len(a) == len(b):
        return 0
    return -1 if len(a) < len(b) else 1      # 前缀相同：段数多者更大


def _compare_parsed(pa, pb):
    for i in range(3):
        if pa[i] != pb[i]:
            return -1 if pa[i] < pb[i] else 1
    return _compare_pre(pa[3], pb[3])


def compare(a, b):
    """-1 / 0 / 1。任一侧非法就抛 ValueError —— 宁可炸，也不要静默放行。"""
    pa, pb = parse(a), parse(b)
    if pa is None:
        raise ValueError("非法 semver: %r" % (a,))
    if pb is None:
        raise ValueError("非法 semver: %r" % (b,))
    return _compare_parsed(pa, pb)


def gte(a, b):
    return compare(a, b) >= 0


def gt(a, b):
    return compare(a, b) > 0


def decide(installed, floor, baked):
    """版本闸门的策略层：这一层允不允许跑、要不要安全模式（ADR-026）。

    返回 (verdict, reason, safe_mode)，verdict 是 ok / deny。
    纯函数：不读盘、不改指针 —— 处置（回落 baked / 退出码 / 日志）由壳负责。
    """
    pi = parse(installed)
    if pi is None:
        return ("deny", "invalid-installed", 0)
    pf, pb = parse(floor), parse(baked)
    if pf is None or pb is None:
        return ("deny", "invalid-manifest", 0)
    if _compare_parsed(pf, pb) > 0:          # floor > baked：清单自相矛盾
        return ("deny", "invalid-manifest", 0)
    if _compare_parsed(pi, pf) < 0:
        return ("deny", "below-floor", 0)
    c = _compare_parsed(pi, pb)
    if c < 0:
        return ("ok", "older-than-baked", 0)
    if c == 0:
        return ("ok", "baked", 0)
    first = pi[3][0] if pi[3] else None
    if first == "alpha":
        return ("ok", "user-upgraded-alpha", 1)
    if first is None or first == "rc":
        return ("ok", "user-upgraded", 0)
    return ("ok", "user-upgraded-prerelease", 1)


# ---------- 一张表 → 若干条待验证的用例（自检与三实现对照共用） ----------

def build_rows(spec):
    """把 spec 摊平成 [(kind, args, expect, why)]；chain 展开成相邻对。"""
    rows = []
    for c in spec.get("compare", []):
        rows.append(("compare", (c["a"], c["b"]), str(c["expect"]), c.get("why", "")))
    chain = spec.get("chain", {}).get("versions", [])
    for x, y in zip(chain, chain[1:]):
        rows.append(("compare", (x, y), "-1", "chain: %s < %s" % (x, y)))
    for c in spec.get("check", []):
        rows.append(("check", (c["v"],), c["expect"], c.get("why", "")))
    for c in spec.get("decision", []):
        rows.append(("decide", (c["installed"], c["floor"], c["baked"]), c["expect"], c.get("why", "")))
    return rows


def evaluate(kind, args):
    """单条用例的本实现结果；畸形输入返回 error。"""
    try:
        if kind == "compare":
            if len(args) != 2:
                return "error"
            try:
                return str(compare(args[0], args[1]))
            except ValueError:
                return "invalid"
        if kind == "check":
            if len(args) != 1:
                return "error"
            return "ok" if is_valid(args[0]) else "invalid"
        if kind == "decide":
            if len(args) != 3:
                return "error"
            verdict, reason, safe = decide(args[0], args[1], args[2])
            return "%s %s %d" % (verdict, reason, safe)
        return "error"
    except Exception:
        return "error"


def load_spec(path=SPEC_PATH):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def batch(path):
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            print(evaluate(parts[0], parts[1:]))
    return 0


def self_test(path=SPEC_PATH):
    spec = load_spec(path)
    rows = build_rows(spec)
    fails = []
    for kind, args, expect, why in rows:
        got = evaluate(kind, args)
        if got != expect:
            fails.append((kind, args, expect, got, why))
    print("向量 %d 条（compare %d / check %d / decide %d）" % (
        len(rows),
        sum(1 for r in rows if r[0] == "compare"),
        sum(1 for r in rows if r[0] == "check"),
        sum(1 for r in rows if r[0] == "decide")))
    if fails:
        for kind, args, expect, got, why in fails:
            print("FAIL %s %s 期望 %s 实得 %s  [%s]" % (kind, list(args), expect, got, why))
        print("失败 %d 条" % len(fails))
        return 1
    print("全部通过")
    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--batch":
        raise SystemExit(batch(sys.argv[2]))
    if len(sys.argv) >= 5 and sys.argv[1] == "--decide":
        print("%s %s %d" % decide(sys.argv[2], sys.argv[3], sys.argv[4]))
        raise SystemExit(0)
    if len(sys.argv) >= 2 and sys.argv[1] == "--spec":
        raise SystemExit(self_test(sys.argv[2]))
    raise SystemExit(self_test())
