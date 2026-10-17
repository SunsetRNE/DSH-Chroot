#!/bin/sh
# tools/test-service.sh —— service.sh 的**契约测试**（本机可跑；dash 与 mksh 两端都该过）
#
# 为什么先写测试：ADR-013 那六条契约里，四条是"看不见的行为"（幂等 / 先停后换 / 非交互 / 环境钉死），
# 靠人肉点一遍迟早漏。这里把它们变成可重复的断言。
#
# 用法: sh tools/test-service.sh

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SH_BIN=$(command -v sh)
ROOT=$(dirname "$HERE")
SVC="$ROOT/service.sh"

PASS=0
FAIL=0

_ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
_no()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

# run <描述> <期望退出码> <命令...>
run() {
    _desc=$1
    _want=$2
    shift 2
    _out=$("$@" 2>&1)
    _rc=$?
    if [ "$_rc" -eq "$_want" ]; then
        _ok "$_desc (rc=$_rc)"
    else
        _no "$_desc" "期望 rc=$_want 实得 rc=$_rc；输出: $_out"
    fi
}

# 单独断言输出里含某串
run_has() {
    _desc=$1
    _want=$2
    _needle=$3
    shift 3
    _out=$("$@" 2>&1)
    _rc=$?
    if [ "$_rc" -eq "$_want" ] && printf '%s' "$_out" | grep -q -- "$_needle"; then
        _ok "$_desc (rc=$_rc, 含 '$_needle')"
    else
        _no "$_desc" "期望 rc=$_want 且含 '$_needle'；实得 rc=$_rc；输出: $_out"
    fi
}

T=$(mktemp -d /tmp/dsh-svc-test.XXXXXX)
export DSH_ROOT="$T"
export DSH_RUNTIME=fake
SVC_RUN() { sh "$SVC" "$@"; }

echo "== 0) 准备"
mkdir -p "$T"
printf 'root: %s\n' "$T"

echo
echo "== 1) 空环境：status 正常、start 因 payload 缺失被拒"
run_has "status 报 bootstrap: idle" 0 "bootstrap : idle" SVC_RUN status
run_has "无 payload 时 start -> 30" 30 "payload 未就绪" SVC_RUN start
run "install 无参数 -> 30" 30 SVC_RUN install
run "未知动词 -> 2" 2 SVC_RUN 不存在

echo
echo "== 2) 投递 payload（离线路径）"
_fake=$(mktemp -d)
printf 'stub\n' >"$_fake/README"
(cd "$_fake" && tar -czf "$T/payload-1.0.0.1.tar.gz" .) || true
_sum=$(sha256sum "$T/payload-1.0.0.1.tar.gz" | cut -d' ' -f1)
printf '{"baked":"1.0.0.1","node":"24.19.0","pnpm":"11","sha256":"%s","size":1}\n' "$_sum" >"$T/inbox/payload.json"
run "install payload -> 0" 0 SVC_RUN install "$T/payload-1.0.0.1.tar.gz"
run "bootstrap --offline -> 0" 0 SVC_RUN bootstrap --offline
if [ -f "$T/active" ] && [ "$(cat "$T/active")" = "1.0.0.1" ]; then
    _ok "active 指针 = 1.0.0.1"
else
    _no "active 指针" "实得: $(cat "$T/active" 2>/dev/null || echo 无)"
fi
if [ -f "$T/base/1.0.0.1/.layer" ]; then _ok "层目录与 .layer 标记存在"; else _no "层目录" "缺 base/1.0.0.1/.layer"; fi
run_has "bootstrap 第二次 -> 10" 10 "already ready" SVC_RUN bootstrap --offline

echo
echo "== 3) 幂等矩阵（契约③）"
run "start -> 0" 0 SVC_RUN start
run_has "start 第二次 -> 10" 10 "already running" SVC_RUN start
run_has "status 报 running" 0 "dsh       : running" SVC_RUN status
run "stop -> 0" 0 SVC_RUN stop
run_has "stop 第二次 -> 10" 10 "already stopped" SVC_RUN stop
run "restart -> 0" 0 SVC_RUN restart
run "restart 第二次 -> 0（幂等）" 0 SVC_RUN restart
SVC_RUN stop >/dev/null 2>&1

echo
echo "== 4) 环境钉死（契约②）"
# 用绝对路径起 shell，才能真的验证 PATH 不被继承
_out=$(HOME=/bogus PATH=/nonexistent "$SH_BIN" "$SVC" status 2>&1)
if printf '%s' "$_out" | grep -q 'path      : /usr/local/sbin\|path      : /system/bin' \
   && ! printf '%s' "$_out" | grep -q '/nonexistent'; then
    _ok "PATH 不继承调用者（status 里没有 /nonexistent）"
else
    _no "PATH 钉死" "$_out"
fi
if printf '%s' "$_out" | grep -q "home      : $T/run"; then
    _ok "HOME 指向模块域（不是 /bogus）"
else
    _no "HOME 钉死" "$_out"
fi

echo
echo "== 5) 非交互（契约①）：stdin 挂着不动的管道，也不该阻塞"
( sleep 30 | timeout 5 sh "$SVC" status >/dev/null 2>&1 )
if [ $? -eq 0 ]; then _ok "stdin 被钉住时不阻塞"; else _no "非交互" "超时或被读走"; fi

echo
echo "== 6) 退出码 20 / 40（故障注入）"
SVC_RUN start >/dev/null 2>&1
_out=$(DSH_FAULT=stop sh "$SVC" stop 2>&1); _rc=$?
if [ "$_rc" -eq 20 ]; then _ok "stop 失败 -> 20"; else _no "退出码 20" "实得 $_rc: $_out"; fi
SVC_RUN stop >/dev/null 2>&1

# 换层：先让它 ready，再清状态模拟"有新版本"，注入 switch 故障
SVC_RUN start >/dev/null 2>&1
rm -f "$T/run/bootstrap.json"
_out=$(DSH_FAULT=switch sh "$SVC" bootstrap --offline 2>&1); _rc=$?
if [ "$_rc" -eq 40 ]; then _ok "切换失败 -> 40"; else _no "退出码 40" "实得 $_rc: $_out"; fi
if [ "$(cat "$T/active" 2>/dev/null)" = "1.0.0.1" ]; then
    _ok "切换失败后 active 指针保持不动"
else
    _no "active 未被破坏" "实得 $(cat "$T/active" 2>/dev/null)"
fi
if pgrep -f "sleep 600" >/dev/null 2>&1; then
    _no "先停后换（契约④）" "仍有 sleep 600 残留"
else
    _ok "先停后换：换层前实例已停"
fi

echo
echo "== 7) 离线约束（契约⑤）"
rm -f "$T/inbox"/payload*
_out=$(sh "$SVC" bootstrap --offline 2>&1); _rc=$?
if [ "$_rc" -eq 30 ] && printf '%s' "$_out" | grep -q 'offline'; then
    _ok "离线且无 payload -> 30"
else
    _no "离线约束" "实得 $_rc: $_out"
fi

echo
echo "== 8) 日志（契约⑥）"
run_has "logs 能读到记录" 0 "DSH_SERVICE_LOGS" SVC_RUN logs --tail 5

echo
printf '结果: %d 通过 / %d 失败\n' "$PASS" "$FAIL"
rm -rf "$T" "$_fake" 2>/dev/null || true
[ "$FAIL" -eq 0 ]
