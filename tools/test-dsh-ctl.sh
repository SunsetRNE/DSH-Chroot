#!/bin/sh
# tools/test-dsh-ctl.sh —— dsh-ctl（公开入口）的契约测试
#
# 断言的是**入口层**的行为：参数校验、审计、透传、环境归一化。
# cgroup 搬家只断言"不崩且如实报告"，因为它在不同环境里结果本来就不一样
# （CI 的 cgroup v2 路径是 /，容器里可能落在 App 组且搬不动 —— 那正是 ADR-019 要求报出来的情况）。

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SH_BIN=$(command -v sh)
ROOT=$(dirname "$HERE")
CTL="$ROOT/dsh-ctl"

PASS=0
FAIL=0
_ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
_no() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

T=$(mktemp -d /tmp/dsh-ctl-test.XXXXXX)
export DSH_ROOT="$T"
export DSH_RUNTIME=fake
export DSH_PATH_OVERRIDE=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

run() {
    _desc=$1; _want=$2; shift 2
    _out=$("$@" 2>&1); _rc=$?
    if [ "$_rc" -eq "$_want" ]; then _ok "$_desc (rc=$_rc)"
    else _no "$_desc" "期望 rc=$_want 实得 rc=$_rc；输出: $_out"; fi
}

run_has() {
    _desc=$1; _want=$2; _needle=$3; shift 3
    _out=$("$@" 2>&1); _rc=$?
    if [ "$_rc" -eq "$_want" ] && printf '%s' "$_out" | grep -q -- "$_needle"; then
        _ok "$_desc (rc=$_rc)"
    else
        _no "$_desc" "期望 rc=$_want 且含 '$_needle'；实得 rc=$_rc；输出: $_out"
    fi
}

echo "== 1) 透传（入口不改语义）"
run_has "status 透传到 service.sh" 0 "DSH_SERVICE_STATUS" sh "$CTL" status
run_has "start 无 payload -> 30（退出码原样透传）" 30 "payload" sh "$CTL" start

echo
echo "== 2) 参数校验（不猜）"
run_has "未知动词 -> 2" 2 "未知动词" sh "$CTL" 乱来
run_has "未实现动词 -> 2，且明确报出来" 2 "尚未实现" sh "$CTL" repair
run_has "rebuild 也未实现" 2 "尚未实现" sh "$CTL" rebuild

echo
echo "== 3) 审计（exec 之前落盘，失败也有记录）"
if [ -f "$T/log/ctl.log" ]; then
    _n=$(wc -l <"$T/log/ctl.log" | tr -d ' ')
    if [ "$_n" -ge 4 ]; then _ok "审计日志有 $_n 条"; else _no "审计日志" "只有 $_n 条"; fi
    if grep -q 'verb="status' "$T/log/ctl.log" && grep -q 'ERROR:乱来' "$T/log/ctl.log"; then
        _ok "审计内容含成功与非法动词"
    else
        _no "审计内容" "$(cat "$T/log/ctl.log")"
    fi
else
    _no "审计日志" "文件不存在"
fi

echo
echo "== 4) 环境归一化"
_out=$(HOME=/bogus PATH=/nonexistent "$SH_BIN" "$CTL" status 2>&1); _rc=$?
if [ "$_rc" -eq 0 ] && ! printf '%s' "$_out" | grep -q '/nonexistent'; then
    _ok "PATH 不继承调用者"
else
    _no "PATH 归一化" "rc=$_rc；$_out"
fi
if printf '%s' "$_out" | grep -q "home      : $T/run"; then
    _ok "HOME 指向模块域"
else
    _no "HOME 归一化" "$_out"
fi

echo
echo "== 5) cgroup 搬家：只要求"不崩 + 如实报告""
_out=$(sh "$CTL" status 2>&1)
if printf '%s' "$_out" | grep -q '^cgroup:'; then
    _ok "有 cgroup 结论行：$(printf '%s' "$_out" | grep '^cgroup:' | head -n1)"
else
    _no "cgroup 报告" "$_out"
fi
if printf '%s' "$_out" | grep -q 'cgroup:' && printf '%s' "$_out" | grep -q 'DSH_SERVICE_STATUS'; then
    _ok "搬家失败也不影响主流程"
else
    _no "cgroup 与主流程" "$_out"
fi

echo
printf '结果: %d 通过 / %d 失败\n' "$PASS" "$FAIL"
rm -rf "$T" 2>/dev/null || true
[ "$FAIL" -eq 0 ]
