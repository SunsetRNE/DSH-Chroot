#!/usr/bin/env python3
"""生成 tools/verify-gate-device.sh —— 单文件、自包含的闸门自检脚本（给真机用）。

为什么是"生成"而不是手写：手机上只需要拷 **一个文件** 过去，既没有 spec/ 也没有 lib/。
所以把 lib/semver-gate.sh 的实现正文 + spec/gate-vectors.json 的向量一起烘进去 ——
这样"在手机上跑过的代码"就是"将来要用的那份实现"，不会出现自检一套、实跑另一套。

用法:
    python3 tools/build-device-selftest.py            # 重新生成
    python3 tools/build-device-selftest.py --check    # 与磁盘上的文件比对（CI 用），漂移 exit 1
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import semver  # noqa: E402

LIB = os.path.join(ROOT, "lib", "semver-gate.sh")
OUT = os.path.join(ROOT, "tools", "verify-gate-device.sh")

MARK_BEGIN = "# ===== 实现正文开始 ====="
MARK_END = "# ===== 实现正文结束 ====="

HEADER = '''#!/bin/sh
# ============================================================
# verify-gate-device.sh —— 版本闸门 · 真机自检（单文件，自包含）
#
# 由 tools/build-device-selftest.py 从下面两处生成，**不要手改**：
#   - lib/semver-gate.sh        （实现正文，逐字复制）
#   - spec/gate-vectors.json    （向量，逐条内联）
#
# 用法（在手机上，root 或普通用户都行）:
#     sh verify-gate-device.sh
#
# 期望最后一行:  RESULT ok 76/76
# 如果出现 FAIL，把那几行连同上面的"环境"一起贴回来即可定位。
#
# 万一报 "then: not found" / "Syntax error" 之类：文件八成被转成了 CRLF
# （Windows 编辑器、某些分享通道会干这事），先转过再跑：
#     tr -d '\\r' < verify-gate-device.sh > /tmp/v.sh && sh /tmp/v.sh
# ============================================================

# 关掉路径名展开：向量里可能有意料之外的字符，不该被当成 glob 展开
set -f

echo "== 环境"
_shell="unknown"
if [ -n "@@{KSH_VERSION-}" ]; then
    _shell=$KSH_VERSION
elif [ -n "@@{BASH_VERSION-}" ]; then
    _shell="bash $BASH_VERSION"
elif [ -n "@@{ZSH_VERSION-}" ]; then
    _shell="zsh $ZSH_VERSION"
fi
echo "shell    : $_shell"
echo "argv0    : $0"
if command -v uname >/dev/null 2>&1; then
    echo "uname    : $(uname -sm)"
fi
if command -v getprop >/dev/null 2>&1; then
    echo "android  : $(getprop ro.build.version.release 2>/dev/null) / $(getprop ro.product.model 2>/dev/null)"
fi
echo "uid      : $(id -u 2>/dev/null)"
if [ -r /system/bin/sh ]; then
    echo "system sh: $(ls -l /system/bin/sh 2>/dev/null | tr -s ' ' | cut -d' ' -f5,9-)"
fi
echo

# ---------- 以下为实现正文（来自 lib/semver-gate.sh） ----------
'''

RUNNER = '''
# ---------- 以下为向量与跑分（来自 spec/gate-vectors.json） ----------
echo "== 逐条比对（共 @@{TOTAL} 条）"
_TOTAL=0
_PASS=0
_FAIL=0
_CR=$(printf '\\r')

# 解析一条向量。为什么不写 @@{_line%%|*}：mksh（Android 的 /system/bin/sh）里
# 未加引号的 | 在 @@{...} 模式里的行为与 dash/bash 不同 —— 实测会整段吞成空串。
# 改用 IFS 拆分，三种 shell 上行为一致（2026-10-17 真机/容器双端验证）。
_gate_one() {
    _raw=$1
    _ol=$IFS
    IFS='|'
    set -- $_raw
    IFS=$_ol
    _kind=@@{1-}
    case $_kind in
        compare)
            _a=@@{2-}
            _b=@@{3-}
            _want=@@{4-}
            _label="compare $_a $_b"
            if semver_cmp "$_a" "$_b"; then
                _got=$SEMVER_CMP
            else
                _got=invalid
            fi
            ;;
        check)
            _a=@@{2-}
            _want=@@{3-}
            _label="check [$_a]"
            if semver_check "$_a"; then _got=ok; else _got=invalid; fi
            ;;
        *)
            _label=unknow
            _got=error
            _want=?
            ;;
    esac
    _TOTAL=$((_TOTAL + 1))
    if [ "$_got" = "$_want" ]; then
        _PASS=$((_PASS + 1))
    else
        _FAIL=$((_FAIL + 1))
        printf 'FAIL %s -> 期望 %s 实得 %s | 原始行: %s\\n' "$_label" "$_want" "$_got" "$_raw"
    fi
}

while IFS= read -r _line; do
    [ -z "$_line" ] && continue
    case $_line in
        *"$_CR") _line=@@{_line%"$_CR"} ;;
    esac
    _gate_one "$_line"
done <<'GATE_VECTORS'
@@{VECTORS}
GATE_VECTORS

echo
echo "== 典型陷阱（人眼复核）"
_probe() {
    if semver_cmp "$1" "$2"; then _g=$SEMVER_CMP; else _g=invalid; fi
    if [ "$_g" = "$3" ]; then _s=ok; else _s=MISMATCH; fi
    printf '  %-16s vs %-12s -> %-4s (期望 %s) %s\\n' "$1" "$2" "$_g" "$3" "$_s"
}
_probe 0.2.1-rc.1 0.2.0-rc.2 1
_probe 0.2.0 0.2.0-rc.2 1
_probe 0.2.0-rc.10 0.2.0-rc.9 1

echo
if [ "$_FAIL" -eq 0 ] && [ "$_TOTAL" -eq @@{TOTAL} ]; then
    echo "RESULT ok $_PASS/$_TOTAL"
    exit 0
fi
echo "RESULT fail $_PASS/$_TOTAL (fail=$_FAIL)"
exit 1
'''


def read_lib_body():
    lines = open(LIB, encoding="utf-8").read().splitlines()
    start = lines.index(MARK_BEGIN) + 1
    if start < len(lines) and lines[start].startswith("# （"):
        start += 1
    end = lines.index(MARK_END)
    return "\n".join(lines[start:end]).strip("\n")


def build_vectors():
    spec = semver.load_spec()
    rows = semver.build_rows(spec)
    out = []
    for kind, args, expect, _why in rows:
        if kind == "compare":
            out.append("compare|" + args[0] + "|" + args[1] + "|" + expect)
        else:
            out.append("check|" + args[0] + "|" + expect)
    return rows, "\n".join(out)


def compose():
    rows, vectors = build_vectors()
    total = str(len(rows))
    dollar_brace = "$" + "{"
    header = HEADER.replace("@@{", dollar_brace).replace("@@{TOTAL}", total)
    body = read_lib_body().replace("@@{", dollar_brace)
    runner = (RUNNER.replace("@@{VECTORS}", vectors)
                    .replace("@@{TOTAL}", total)
                    .replace("@@{", dollar_brace))
    return header + body + "\n" + runner, len(rows)


def main(argv):
    content, n = compose()
    if "--check" in argv:
        old = ""
        if os.path.exists(OUT):
            old = open(OUT, encoding="utf-8").read()
        if old != content:
            print("漂移: " + os.path.relpath(OUT, ROOT)
                  + " 与 lib/semver-gate.sh 或 spec/gate-vectors.json 不一致，请重新生成",
                  file=sys.stderr)
            return 1
        print("一致: " + os.path.relpath(OUT, ROOT) + "（" + str(n) + " 条向量）")
        return 0
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write(content)
    os.chmod(OUT, 0o755)
    print("写入 " + os.path.relpath(OUT, ROOT) + "（" + str(n) + " 条向量，自包含）")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
