#!/system/bin/sh
# tools/verify-runtime.sh —— **真机**验证 runtime_start 的 real 分支（P2 / ADR-029）
#
# 它做的事就是 service.sh start 在开机时会做的事，只是把 DSH_ROOT 指到临时目录，
# 免得污染真正的 /data/local/dsh：
#   建两层 bind → 起容器（dsh web --port 0）→ 从 stdout 启动行拿端口 → 带 token 访问 → stop → 查清理
#
# 用法:
#   sh tools/verify-runtime.sh <容器rootfs> <node层目录> <dsh层目录>
# 例:
#   sh tools/verify-runtime.sh /data/local/chroot-distro/ubuntu \
#       /data/local/dsh/base/node /data/local/dsh/base/dsh-0.2.1-rc.4
#
# 退出码: 0=全通过  1=有断言失败  2=参数/环境不对
#
# 为什么必须是真机：它要 chroot + mknod + mount，容器里跑不了（也没有意义）。

set -u

if [ "$(id -u 2>/dev/null)" != "0" ]; then
    echo "需要 root（chroot/mount/mknod）" >&2
    exit 2
fi
if [ "$#" -lt 3 ]; then
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
fi

ROOTFS=$1
NODE_DIR=$2
DSH_DIR=$3
HERE=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
REPO=$(dirname "$HERE")
SVC="$REPO/service.sh"
[ -f "$SVC" ] || { echo "找不到 service.sh（$SVC）" >&2; exit 2; }

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

VER=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$DSH_DIR/.layer" 2>/dev/null | head -n1)
[ -n "$VER" ] || { echo "$DSH_DIR/.layer 里读不到 version（先 bootstrap 或手写一份）" >&2; exit 2; }

T=/data/local/tmp/dsh-rt-probe.$$
mkdir -p "$T/base/node" "$T/base/dsh-$VER" "$T/data" "$T/inbox" "$T/run" "$T/log" 2>/dev/null || {
    echo "建临时 DSH_ROOT 失败：$T" >&2; exit 2
}
set --
mount --bind "$NODE_DIR" "$T/base/node" 2>/dev/null || { echo "bind node 层失败" >&2; exit 2; }
mount --bind "$DSH_DIR" "$T/base/dsh-$VER" 2>/dev/null || { echo "bind dsh 层失败" >&2; exit 2; }

cleanup() {
    DSH_ROOT=$T DSH_RUNTIME=real sh "$SVC" stop >/dev/null 2>&1
    umount -l "$T/base/dsh-$VER" 2>/dev/null
    umount -l "$T/base/node" 2>/dev/null
    rm -rf "$T" 2>/dev/null
}
trap 'cleanup' EXIT INT TERM

printf '{"layer":"node","version":"24.21.0"}\n' >"$T/base/node/.layer" 2>/dev/null
printf '{"layer":"dsh","version":"%s"}\n' "$VER" >"$T/base/dsh-$VER/.layer" 2>/dev/null
printf '{"schema":1,"baked":"%s","baked_seq":2,"floor":"%s","paths":{"container_rootfs":"%s"}}\n' \
    "$VER" "$VER" "$ROOTFS" >"$T/manifest.json"
printf '%s\n' "$VER" >"$T/active"

echo "== 环境 =="
printf '  rootfs=%s\n  node=%s\n  dsh=%s (%s)\n' "$ROOTFS" "$NODE_DIR" "$DSH_DIR" "$VER"

echo
echo "== 1) start（real 分支） =="
_out=$(DSH_ROOT=$T DSH_RUNTIME=real sh "$SVC" start 2>&1); _rc=$?
if [ "$_rc" -eq 0 ]; then ok "start -> 0"; else no "start 应为 0" "rc=$_rc: $_out"; fi
printf '%s' "$_out" | grep -q 'runtime: dsh 就绪' && ok "日志报出就绪" || no "日志没报就绪" "$_out"

echo
echo "== 2) run/dsh.json（端口与 token 的唯一真源） =="
J="$T/run/dsh.json"
PORT=$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$J" 2>/dev/null | head -n1)
TOKEN=$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$J" 2>/dev/null | head -n1)
PID=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$J" 2>/dev/null | head -n1)
if [ -n "$PORT" ] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then ok "端口来自启动行：$PORT"
else no "端口不对" "port=${PORT:-空}"; fi
[ -n "$TOKEN" ] && ok "token 已写入（长度 ${#TOKEN}）" || no "token 为空"
[ "$(stat -c %a "$J" 2>/dev/null)" = "600" ] && ok "dsh.json 权限 0600" || no "dsh.json 权限不是 0600" "$(stat -c %a "$J" 2>/dev/null)"
kill -0 "${PID:-0}" 2>/dev/null && ok "进程在跑（pid $PID）" || no "进程不在" "pid=${PID:-空}"

echo
echo "== 3) 版本层必须真只读（ADR-009） =="
for m in "$ROOTFS/opt/dsh/node" "$ROOTFS/opt/dsh/current"; do
    _flags=$(grep " $m " /proc/mounts 2>/dev/null | head -n1 | cut -d' ' -f4)
    case ",$_flags," in
        *,ro,*) ok "ro: $m" ;;
        *) no "不是 ro: $m" "flags=$_flags" ;;
    esac
done

echo
echo "== 4) 带 token 能打开 UI，不带被拒 =="
_ck="$T/ck.txt"
if command -v curl >/dev/null 2>&1; then
    _code=$(curl -sL --connect-timeout 5 --max-time 20 -c "$_ck" -b "$_ck" -o "$T/idx.html" -w '%{http_code}' \
        "http://127.0.0.1:$PORT/?token=$TOKEN" 2>/dev/null)
    _size=$(wc -c <"$T/idx.html" 2>/dev/null || echo 0)
    if [ "$_code" = "200" ] && [ "$_size" -gt 1000 ]; then ok "带 token -> 200（${_size} B）"
    else no "带 token 访问失败" "http=$_code size=$_size"; fi
    _code2=$(curl -s --connect-timeout 5 --max-time 20 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null)
    if [ "$_code2" = "401" ] || [ "$_code2" = "403" ]; then ok "不带 token -> $_code2"
    else no "不带 token 竟能访问" "http=$_code2"; fi
else
    no "没有 curl，无法验证 HTTP" "（设备通常自带 curl）"
fi

echo
echo "== 5) token 不能落进日志（ADR-022） =="
if grep -q -- "$TOKEN" "$T/log/service.log" "$T/log/dsh.log" 2>/dev/null; then
    no "日志里出现了 token"
else
    ok "日志里没有 token"
fi

echo
echo "== 6) stop：进程、挂载、dsh.json 全清 =="
_out=$(DSH_ROOT=$T DSH_RUNTIME=real sh "$SVC" stop 2>&1); _rc=$?
if [ "$_rc" -eq 0 ]; then ok "stop -> 0"; else no "stop 应为 0" "rc=$_rc: $_out"; fi
kill -0 "${PID:-0}" 2>/dev/null && no "进程没死" || ok "进程已退出"
_n=$(mount 2>/dev/null | grep -c " $ROOTFS/")
if [ "$_n" -eq 0 ]; then ok "容器挂载已清空"; else no "仍有 $_n 个挂载"; fi
[ -f "$J" ] && no "dsh.json 没删" || ok "dsh.json 已删"

echo
printf '结果: %d 通过 / %d 失败\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && echo "RESULT=OK" || echo "RESULT=FAIL"
[ "$FAIL" -eq 0 ]
