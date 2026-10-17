#!/usr/bin/env python3
"""semver 2.0.0 —— 本项目版本闸门的权威参考实现（Python 版）。

为什么单独写一个文件：版本比较是整套方案里**唯一一处写错会静默出错**的地方。
字符串比较在 "0.2.1-rc.1" vs "0.2.0-rc.2" 上给出相反答案，
而这类错误不会抛异常、不会进日志，只会让闸门放行错版本或错误地回滚。

其他实现（容器里的 POSIX sh、壳里的 node）必须与同一张向量表对齐 —— 见 docs/versioning.md §9。

用法:
    python3 tools/semver.py            # 跑自检向量表
    from semver import compare, is_valid
"""

import re

# 严格按 semver 2.0.0 的 BNF：不允许前导零、不允许缺段、只允许 ASCII 字母数字与连字符
_SEMVER_RE = re.compile(
    r"^(0|[1-9][0-9]*)"
    r"\.(0|[1-9][0-9]*)"
    r"\.(0|[1-9][0-9]*)"
    r"(?:-((?:[0-9A-Za-z-]+)(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)


def parse(version):
    """返回 (major, minor, patch, pre_tuple)；非法返回 None。

    pre_tuple 里：数字段是 int（用于数值比较），字母段是 str（用于 ASCII 字典序）。
    无 prerelease 时为 ()。
    """
    if not isinstance(version, str):
        return None
    m = _SEMVER_RE.match(version.strip())
    if not m:
        return None
    major, minor, patch = int(m.group(1)), int(m.group(2)), int(m.group(3))
    pre = m.group(4)
    if pre is None:
        return (major, minor, patch, ())
    return (major, minor, patch, tuple(int(p) if p.isdigit() else p for p in pre.split(".")))


def is_valid(version):
    return parse(version) is not None


def _compare_pre(a, b):
    # 规则：有 prerelease 的版本 < 无 prerelease 的版本
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


def compare(a, b):
    """-1 / 0 / 1。任一侧非法就抛 ValueError —— 宁可炸，也不要静默放行。"""
    pa, pb = parse(a), parse(b)
    if pa is None:
        raise ValueError("非法 semver: %r" % (a,))
    if pb is None:
        raise ValueError("非法 semver: %r" % (b,))
    for i in range(3):
        if pa[i] != pb[i]:
            return -1 if pa[i] < pb[i] else 1
    return _compare_pre(pa[3], pb[3])


def gte(a, b):
    return compare(a, b) >= 0


def gt(a, b):
    return compare(a, b) > 0


# (a, b, 期望 compare(a,b))；最后若干条是向量表将来要同步给 sh / node 的那张表
VECTORS = [
    ("0.2.1-rc.1", "0.2.0-rc.2", 1),      # 字典序会给出相反答案：本题的经典陷阱
    ("0.2.0", "0.2.0-rc.2", 1),           # final > 所有 rc
    ("0.2.0-rc.2", "0.2.0-rc.2", 0),
    ("0.2.0-rc.10", "0.2.0-rc.9", 1),     # rc.10 > rc.9（字典序会反）
    ("0.2.0-rc.2", "0.2.0-rc.10", -1),
    ("1.0.0-alpha", "1.0.0-alpha.1", -1),
    ("1.0.0-alpha.1", "1.0.0-alpha.beta", -1),   # 数字段 < 字母段
    ("1.0.0-alpha.beta", "1.0.0-beta", -1),
    ("1.0.0-beta", "1.0.0-beta.2", -1),
    ("1.0.0-beta.2", "1.0.0-beta.11", -1),
    ("1.0.0-beta.11", "1.0.0-rc.1", -1),
    ("1.0.0-rc.1", "1.0.0", -1),
    ("1.0.0+build.1", "1.0.0", 0),        # build 元数据忽略
    ("0.2.1-rc.2", "0.2.0-rc.2", 1),
    ("10.0.0", "9.9.9", 1),
]

INVALID = ["0.2", "v0.2.0", "01.2.3", "1.2.3-", "", "1.2.3.4", "1.2.x"]


def _self_test():
    failures = 0
    for a, b, want in VECTORS:
        got = compare(a, b)
        if got != want:
            failures += 1
            print("FAIL compare(%r, %r) = %d，期望 %d" % (a, b, got, want))
    for v in INVALID:
        if is_valid(v):
            failures += 1
            print("FAIL is_valid(%r) 应为 False" % (v,))
    total = len(VECTORS) + len(INVALID)
    if failures:
        print("向量表 %d 条，失败 %d 条" % (total, failures))
        return 1
    print("向量表 %d 条全部通过（%d 条比较 + %d 条非法）" % (total, len(VECTORS), len(INVALID)))
    return 0


if __name__ == "__main__":
    raise SystemExit(_self_test())
