#!/bin/sh
# tools/test-diag.sh —— `diag` 的契约测试（证据 → 命中码 → 组合签名结论）
#
# 为什么要有它：diag 的价值全在"结论正确"，而结论是**推断**——
# 推断错比不做更糟（会把人引到错误的层）。所以每种典型现场都要有一条断言。
#
# 用法: sh tools/test-diag.sh
# 依赖: 无（不需要 root、不联网、不启动容器；假 DSH_ROOT + symlink 造现场）

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
SVC="$ROOT/service.sh"
CTL="$ROOT/dsh-ctl"

PASS=0
FAIL=0
_ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
_no() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

has() { printf '%s' "$1" | grep -q -- "$2"; }

run_has() { # 描述 期望rc 期望出现的串 参数...
    _desc=$1; _want=$2; _needle=$3; shift 3
    _out=$("$@" 2>&1); _rc=$?
    if [ "$_rc" -eq "$_want" ] && has "$_out" "$_needle"; then
        _ok "$_desc (rc=$_rc)"
    else
        _no "$_desc" "期望 rc=$_want 且含 '$_needle'；实得 rc=$_rc；输出: $_out"
    fi
}

run_not() { # 描述 期望rc 不该出现的串 参数...
    _desc=$1; _want=$2; _needle=$3; shift 3
    _out=$("$@" 2>&1); _rc=$?
    if [ "$_rc" -eq "$_want" ] && ! has "$_out" "$_needle"; then
        _ok "$_desc (rc=$_rc)"
    else
        _no "$_desc" "期望 rc=$_want 且不含 '$_needle'；实得 rc=$_rc；输出: $_out"
    fi
}

T=$(mktemp -d /tmp/dsh-diag-test.XXXXXX)
trap 'rm -rf "$T"' EXIT INT TERM

export DSH_RUNTIME=fake
export DSH_PATH_OVERRIDE=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

D() { DSH_ROOT="$1" sh "$SVC" diag; }

# 造一个"看起来都正常"的现场：两层齐 + manifest 对齐 + rootfs 的 /dev/null 借 symlink
# 指向真字符设备（CI 里没 root，不能 mknod——但 [ -c ] 会跟随符号链接，够用）
mk_good() {
    _r=$1
    mkdir -p "$_r/base/node" "$_r/base/dsh-0.2.1-rc.4" "$_r/run" "$_r/log" "$_r/rootfs/dev/pts"
    printf '{"name":"node"}\n' >"$_r/base/node/.layer"
    printf '{"version":"0.2.1-rc.4"}\n' >"$_r/base/dsh-0.2.1-rc.4/.layer"
    printf '0.2.1-rc.4\n' >"$_r/active"
    printf '{"baked":"0.2.1-rc.4","floor":"0.2.1-rc.4","container_rootfs":"%s/rootfs"}\n' \
        "$_r" >"$_r/manifest.json"
    ln -sf /dev/null "$_r/rootfs/dev/null"
    ln -sf /dev/null "$_r/rootfs/dev/ptmx"
    printf '{"port":12345,"token":"x"}\n' >"$_r/run/dsh.json"
}

echo
echo "== 1) 空目录：该报「缺件」而不是一屏现象 =="
mkdir -p "$T/A"
run_has "命中 SIG-MISSING（不是乱猜层）" 1 "SIG-MISSING" D "$T/A"
run_has "同时给出下一步" 1 "dsh-ctl install" D "$T/A"
run_has "命中码里带着自证命令" 1 "自证 :" D "$T/A"

echo
echo "== 2) 一切正常：不许报故障（否则 diag 就是狼来了） =="
mk_good "$T/B"
run_has "没发现已知故障" 0 "没发现已知故障" D "$T/B"

echo
echo "== 3) /dev 不可信 + 端口没报出 = 组合签名 SIG-NOT-ROOTFS =="
mk_good "$T/C"
rm -f "$T/C/rootfs/dev/null"
printf 'not a device\n' >"$T/C/rootfs/dev/null"
printf '{"token":"x"}\n' >"$T/C/run/dsh.json"     # 有 dsh.json 但没有 port
run_has "命中 SIG-NOT-ROOTFS" 1 "SIG-NOT-ROOTFS" D "$T/C"
run_has "结论指向容器而不是 dsh" 1 "不是 dsh 的问题" D "$T/C"

echo
echo '== 4) 只命中一条、没有签名：必须说「没登记」，不许硬凑结论 =='
mk_good "$T/E"
# 把 floor 抬到 installed 之上 → 版本闸门 deny below-floor → 只命中 E-L3S-VER-001。
# 特意不用「删层」造单条：删层正好命中 SIG-MISSING，那是**登记过**的签名，
# 测不出「没登记就别硬凑」这条底线。
printf '{"baked":"0.2.1-rc.4","floor":"0.9.9","container_rootfs":"%s/rootfs"}\n' \
    "$T/E" >"$T/E/manifest.json"
run_has "单条命中仍 exit 1" 1 "E-L3S-VER-001" D "$T/E"
run_has "没有签名就说没登记" 1 "还没登记" D "$T/E"
run_not "不许凭空给签名" 1 "SIG-" D "$T/E"

echo
echo "== 5) diag 必须只读（跑两遍不能改坏现场） =="
mk_good "$T/F"
D "$T/F" >/dev/null 2>&1
_before=$(cd "$T/F" && find . | sort)
D "$T/F" >/dev/null 2>&1
_after=$(cd "$T/F" && find . | sort)
if [ "$_before" = "$_after" ]; then
    _ok "两遍 diag 后目录结构不变"
else
    _no "diag 改动了现场" "before/after 不一致"
fi

echo
echo "== 6) 公开入口：dsh-ctl diag 应该透传，且不掺 cgroup 搬家噪声 =="
run_has "dsh-ctl diag 透传（SIG-MISSING）" 1 "SIG-MISSING" env DSH_ROOT="$T/A" sh "$CTL" diag
run_not "诊断不该打印 cgroup 搬家" 1 "cgroup" env DSH_ROOT="$T/A" sh "$CTL" diag

echo
echo '== 7) 表缺失：必须明确说「判不了」（rc=2），而不是静默放过 =='
mkdir -p "$T/G/bin" "$T/G/root"
cp "$SVC" "$T/G/bin/service.sh"
run_has "缺 lib/errors.sh -> rc=2" 2 "no-table" env DSH_ROOT="$T/G/root" sh "$T/G/bin/service.sh" diag

echo
echo "== 结论 =="
printf '  通过 %s 条，失败 %s 条\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
    echo "  diag 的判读不可信：先修表或修证据采集，别拿它当结论。"
    exit 1
fi
echo "  diag 按 spec 判读：缺件/组合/无签名/只读/透传/缺表 六种情形都对上了。"
exit 0