#!/bin/sh
# tools/test-service.sh —— service.sh 的**契约测试**（dash 与 mksh 两端都该过）
#
# 覆盖：六条契约（非交互 / 环境钉死 / 幂等 / 先停后换 / 默认离线 / 状态+退出码）
#       + 两层布局（node 层复用、dsh 层切换、指针原子性）+ 退出码 0/10/20/30/40
#
# 用法: sh tools/test-service.sh

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SH_BIN=$(command -v sh)
ROOT=$(dirname "$HERE")
SVC="$ROOT/service.sh"

PASS=0
FAIL=0
_ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
_no() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

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

T=$(mktemp -d /tmp/dsh-svc-test.XXXXXX)
export DSH_ROOT="$T"
export DSH_RUNTIME=fake
# 本容器同时能看见 /system/bin，不覆盖则每条命令都走 Android toybox（慢且带 linker 噪声）
export DSH_PATH_OVERRIDE=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
SVC_RUN() { sh "$SVC" "$@"; }

# 造一个最小层：目录树 -> tar.gz -> 旁挂 json（含 sha256）
make_layer() { # $1=kind(node|dsh) $2=version $3=outdir
    _k=$1; _v=$2; _o=$3
    _tmp=$(mktemp -d)
    mkdir -p "$_tmp/bin"
    printf '#!/bin/sh\necho stub-%s\n' "$_k" >"$_tmp/bin/stub"
    chmod +x "$_tmp/bin/stub"
    (cd "$_tmp" && tar -czf "$_o/$_k-$_v.tar.gz" .)
    _sum=$(sha256sum "$_o/$_k-$_v.tar.gz" | cut -d' ' -f1)
    if [ "$_k" = "node" ]; then
        printf '{"schema":1,"layer":"node","version":"%s","sha256":"%s"}\n' "$_v" "$_sum" >"$_o/node.json"
    else
        printf '{"schema":1,"layer":"dsh","baked":"%s","sha256":"%s"}\n' "$_v" "$_sum" >"$_o/dsh.json"
    fi
    rm -rf "$_tmp"
}

echo "== 0) 准备"
PKG=$(mktemp -d /tmp/dsh-pkg.XXXXXX)
make_layer node 24.19.0 "$PKG"
make_layer dsh 0.2.0-rc.2 "$PKG"
ls "$PKG" | sed 's/^/   /'

echo
echo "== 1) 空环境：status 正常、start 因层缺失被拒"
run_has "status 报 bootstrap: idle" 0 "bootstrap : idle" SVC_RUN status
run_has "status 报 node: missing" 0 "node      : missing" SVC_RUN status
run_has "无层时 start -> 30" 30 "未就绪" SVC_RUN start
run "install 无参数 -> 30" 30 SVC_RUN install
run "未知动词 -> 2" 2 SVC_RUN 不存在

echo
echo "== 2) 投递两层（离线路径）"
run "install node 层 -> 0" 0 SVC_RUN install "$PKG/node-24.19.0.tar.gz"
run "install node 清单 -> 0" 0 SVC_RUN install "$PKG/node.json"
run "install dsh 层 -> 0" 0 SVC_RUN install "$PKG/dsh-0.2.0-rc.2.tar.gz"
run "install dsh 清单 -> 0" 0 SVC_RUN install "$PKG/dsh.json"
run "bootstrap --offline -> 0" 0 SVC_RUN bootstrap --offline
if [ -f "$T/base/node/.layer" ] && [ -f "$T/base/dsh-0.2.0-rc.2/.layer" ]; then
    _ok "两层目录都就位（base/node · base/dsh-0.2.0-rc.2）"
else
    _no "两层目录" "$(ls "$T/base" 2>/dev/null)"
fi
if [ "$(cat "$T/active" 2>/dev/null)" = "0.2.0-rc.2" ]; then
    _ok "active 指针 = 0.2.0-rc.2"
else
    _no "active 指针" "实得: $(cat "$T/active" 2>/dev/null || echo 无)"
fi
run_has "bootstrap 第二次 -> 10" 10 "already ready" SVC_RUN bootstrap --offline

echo
echo "== 3) 幂等矩阵（契约③）"
run "start -> 0" 0 SVC_RUN start
run_has "start 第二次 -> 10" 10 "already running" SVC_RUN start
run_has "status 报 running + node ok" 0 "node      : ok" SVC_RUN status
run "stop -> 0" 0 SVC_RUN stop
run_has "stop 第二次 -> 10" 10 "already stopped" SVC_RUN stop
run "restart -> 0" 0 SVC_RUN restart
run "restart 第二次 -> 0（幂等）" 0 SVC_RUN restart
SVC_RUN stop >/dev/null 2>&1

echo
echo "== 4) 环境钉死（契约②）"
_out=$(HOME=/bogus PATH=/nonexistent "$SH_BIN" "$SVC" status 2>&1)
if printf '%s' "$_out" | grep -q 'path      : /usr/local/sbin\|path      : /system/bin' \
   && ! printf '%s' "$_out" | grep -q '/nonexistent'; then
    _ok "PATH 不继承调用者"
else
    _no "PATH 钉死" "$_out"
fi
if printf '%s' "$_out" | grep -q "home      : $T/run"; then
    _ok "HOME 指向模块域"
else
    _no "HOME 钉死" "$_out"
fi

echo
echo "== 5) 非交互（契约①）：stdin 挂着不动的管道也不该阻塞"
( sleep 30 | timeout 5 sh "$SVC" status >/dev/null 2>&1 )
if [ $? -eq 0 ]; then _ok "stdin 被钉住时不阻塞"; else _no "非交互" "超时或被读走"; fi

echo
echo "== 6) 两层复用：换 DSH 版本时 Node 层不该重装"
_node_stamp=$(cat "$T/base/node/.layer" 2>/dev/null)
make_layer dsh 0.2.1-rc.2 "$PKG"
SVC_RUN install "$PKG/dsh-0.2.1-rc.2.tar.gz" >/dev/null 2>&1
SVC_RUN install "$PKG/dsh.json" >/dev/null 2>&1
rm -f "$T/run/bootstrap.json"    # 模拟"有新版本待自举"
_out=$(sh "$SVC" bootstrap --offline 2>&1); _rc=$?
if [ "$_rc" -eq 0 ] && printf '%s' "$_out" | grep -q '复用'; then
    _ok "Node 层被复用（两层的收益）"
else
    _no "Node 层复用" "rc=$_rc；$_out"
fi
if [ "$(cat "$T/base/node/.layer" 2>/dev/null)" = "$_node_stamp" ]; then
    _ok "Node 层标记未被重写"
else
    _no "Node 层标记" "被意外重写"
fi
if [ "$(cat "$T/active" 2>/dev/null)" = "0.2.1-rc.2" ]; then
    _ok "active 切到 0.2.1-rc.2"
else
    _no "active 切换" "实得 $(cat "$T/active" 2>/dev/null)"
fi

echo
echo "== 7) 退出码 20 / 40（故障注入）"
SVC_RUN start >/dev/null 2>&1
_out=$(DSH_FAULT=stop sh "$SVC" stop 2>&1); _rc=$?
if [ "$_rc" -eq 20 ]; then _ok "stop 失败 -> 20"; else _no "退出码 20" "实得 $_rc: $_out"; fi
SVC_RUN stop >/dev/null 2>&1

make_layer dsh 0.3.0-rc.1 "$PKG"
SVC_RUN install "$PKG/dsh-0.3.0-rc.1.tar.gz" >/dev/null 2>&1
SVC_RUN install "$PKG/dsh.json" >/dev/null 2>&1
rm -f "$T/run/bootstrap.json"
_out=$(DSH_FAULT=switch sh "$SVC" bootstrap --offline 2>&1); _rc=$?
if [ "$_rc" -eq 40 ]; then _ok "切换失败 -> 40"; else _no "退出码 40" "实得 $_rc: $_out"; fi
if [ "$(cat "$T/active" 2>/dev/null)" = "0.2.1-rc.2" ]; then
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
echo "== 8) 离线约束（契约⑤）"
rm -f "$T/inbox"/dsh-*.tar.gz
_out=$(sh "$SVC" bootstrap --offline 2>&1); _rc=$?
if [ "$_rc" -eq 30 ] && printf '%s' "$_out" | grep -q 'offline'; then
    _ok "离线且缺层 -> 30"
else
    _no "离线约束" "实得 $_rc: $_out"
fi

echo
echo "== 9) 日志（契约⑥）"
run_has "logs 能读到记录" 0 "DSH_SERVICE_LOGS" SVC_RUN logs --tail 5

echo
printf '结果: %d 通过 / %d 失败\n' "$PASS" "$FAIL"
rm -rf "$T" "$PKG" 2>/dev/null || true
[ "$FAIL" -eq 0 ]
