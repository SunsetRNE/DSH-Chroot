#!/bin/sh
# tools/test-sdk-protocol.sh —— verify-sdk-protocol.sh 的**契约测试**（dash 与 mksh 两端都该过）
#
# 为什么能在 CI 里跑：探针只依赖 stdin/stdout，所以用一个**假 dsh**（node 脚本）就能把
# 六种真实故障态逐个演一遍，不需要装 616 个包、不需要网络、不需要 root（ADR-028）。
#
# 覆盖：
#   1) 正常握手 → 0，且 SERVER_NAME / SERVER_VERSION 打得出来
#   2) 有 result 但缺 serverInfo → 1
#   3) initialize 回 -32603（provider 缺失的真实报错）→ 1，且错误码要透出
#   4) 进程启动即崩 → 1
#   5) 挂住不回 → 1（超时路径）
#   6) stdout 被日志污染 / 不回包 → 1（不误判成成功）
#   7) 找不到 dsh → 2；找不到 node → 2（环境缺失必须与握手失败分开）
#   8) 参数与 provider/model 真的传下去了（--profile sdk / deepseek-official）
#
# 用法: sh tools/test-sdk-protocol.sh

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
PROBE="$HERE/verify-sdk-protocol.sh"
NODE_BIN=$(command -v node 2>/dev/null || true)
[ -z "$NODE_BIN" ] && [ -x /opt/node24/bin/node ] && NODE_BIN=/opt/node24/bin/node

PASS=0
FAIL=0
_ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
_no() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

run_has() { # desc want_rc needle -- cmd...
    _desc=$1; _want=$2; _needle=$3; shift 3
    _out=$("$@" 2>&1); _rc=$?
    if [ "$_rc" -eq "$_want" ] && printf '%s' "$_out" | grep -q -F -- "$_needle"; then
        _ok "$_desc (rc=$_rc)"
    else
        _no "$_desc" "期望 rc=$_want 且含 '$_needle'；实得 rc=$_rc；输出: $_out"
    fi
}

run_not() { # desc want_rc unwanted_needle -- cmd...
    _desc=$1; _want=$2; _bad=$3; shift 3
    _out=$("$@" 2>&1); _rc=$?
    if [ "$_rc" -ne "$_want" ]; then
        _no "$_desc" "期望 rc=$_want；实得 rc=$_rc；输出: $_out"
    elif printf '%s' "$_out" | grep -q -F -- "$_bad"; then
        _no "$_desc" "不该出现 '$_bad'；输出: $_out"
    else
        _ok "$_desc (rc=$_rc)"
    fi
}

echo "== 0) 准备"
if [ -z "$NODE_BIN" ] || [ ! -x "$NODE_BIN" ]; then
    echo "  FAIL 找不到 node —— 探针无法自测（CI 里有 setup-node 24）"
    exit 1
fi
T=$(mktemp -d /tmp/dsh-sdk-test.XXXXXX) || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

# 假 dsh：按 FAKE_MODE 演不同故障态；顺带把 argv 与收到的 params 落盘供断言
cat >"$T/dsh" <<'FAKEEOF'
#!/usr/bin/env node
const fs = require('node:fs');
const dir = process.env.FAKE_DIR || '.';
const mode = process.env.FAKE_MODE || 'ok';
fs.writeFileSync(dir + '/argv.txt', process.argv.slice(2).join(' '));

const reply = (id, result, error) =>
    process.stdout.write(JSON.stringify(error
        ? { jsonrpc: '2.0', id, error }
        : { jsonrpc: '2.0', id, result }) + '\n');

if (mode === 'crash') { process.stderr.write('boom: cannot boot\n'); process.exit(9); }

// hang / garbage 必须真的**一个包都不回**，否则测的就不是超时路径
if (mode === 'hang' || mode === 'garbage') {
    if (mode === 'garbage') process.stdout.write('not a json line\n');
    setInterval(() => {}, 1000);
} else {
    let buf = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk) => {
        buf += chunk;
        let i;
        while ((i = buf.indexOf('\n')) >= 0) {
            const line = buf.slice(0, i).trim();
            buf = buf.slice(i + 1);
            if (!line) continue;
            let msg;
            try { msg = JSON.parse(line); } catch (e) { continue; }
            if (msg.method === 'initialize') {
                fs.writeFileSync(dir + '/init.json', JSON.stringify(msg.params || {}));
                if (mode === 'error') {
                    reply(msg.id, null, { code: -32603, message: 'no adapter registered for provider "undefined"' });
                } else if (mode === 'noserverinfo') {
                    reply(msg.id, { ok: true });
                } else {
                    reply(msg.id, { serverInfo: { name: 'deepseek-harness-sdk-runtime', version: '0.0.1' }, capabilities: {} });
                }
            } else if (msg.method === 'shutdown') {
                reply(msg.id, {});
                setTimeout(() => process.exit(0), 20);
            }
        }
    });
}
FAKEEOF
chmod +x "$T/dsh"
echo "   fake dsh: $T/dsh"

# 探针调用器（FAKE_MODE / 超时 由外层控制；PROBE_SH 可换 shell 跑探针本体）
P() {
    _m=$1; shift
    FAKE_DIR="$T" FAKE_MODE="$_m" DSH_BIN="$T/dsh" DSH_NODE="$NODE_BIN" \
        DSH_SDK_CWD="$T" DSH_SDK_TIMEOUT_MS="${TMO:-45000}" \
        "${PROBE_SH:-sh}" "$PROBE" "$@"
}

echo
echo "== 1) 正常握手"
run_has "initialize + shutdown -> 0" 0 "RESULT=OK" P ok
run_has "打出 SERVER_NAME" 0 "SERVER_NAME=deepseek-harness-sdk-runtime" P ok
run_has "打出 SERVER_VERSION" 0 "SERVER_VERSION=0.0.1" P ok
run_not "正常路径不报 FAIL" 0 "RESULT=FAIL" P ok

echo
echo "== 2) 故障态必须判红（不能把「有回复」当成功）"
run_has "缺 serverInfo -> 1" 1 "RESULT=FAIL" P noserverinfo
run_has "-32603 错误码透出 -> 1" 1 "no adapter registered" P error
run_has "启动即崩 -> 1" 1 "RESULT=FAIL" P crash
TMO=3000 run_has "挂住不回 -> 1（超时）" 1 "timeout" P hang
run_has "stdout 被日志污染 -> 1" 1 "RESULT=FAIL" P garbage

echo
echo "== 3) 环境缺失必须与握手失败分开（都是 2，不是 1）"
_out=$(DSH_BIN=/nonexistent/dsh DSH_NODE="$NODE_BIN" sh "$PROBE" 2>&1); _rc=$?
if [ "$_rc" -eq 2 ] && printf '%s' "$_out" | grep -q 'reason=dsh'; then
    _ok "dsh 不存在 -> 2"
else
    _no "dsh 不存在 -> 2" "rc=$_rc: $_out"
fi
_out=$(DSH_BIN="$T/dsh" DSH_NODE=/nonexistent/node sh "$PROBE" 2>&1); _rc=$?
if [ "$_rc" -eq 2 ] && printf '%s' "$_out" | grep -q 'reason=node'; then
    _ok "node 不存在 -> 2"
else
    _no "node 不存在 -> 2" "rc=$_rc: $_out"
fi

echo
echo "== 4) 参数真的传下去了（不传 --profile sdk 就是另一个载体，静态类型也不报错）"
run_has "默认带 --profile sdk" 0 "--profile sdk" sh -c "cat '$T/argv.txt' 2>/dev/null; exit 0"
_out=$(cat "$T/argv.txt" 2>/dev/null)
case "$_out" in
    *"--profile sdk"*) _ok "argv = --profile sdk（实得: $_out）" ;;
    *) _no "argv 缺 --profile sdk" "实得: $_out" ;;
esac
run_has "provider 传进 initialize" 0 '"provider":"deepseek-official"' sh -c "cat '$T/init.json' 2>/dev/null; exit 0"
run_has "model 传进 initialize" 0 '"model":"deepseek-flash"' sh -c "cat '$T/init.json' 2>/dev/null; exit 0"
run_has "cwd 传进 initialize" 0 '"cwd":"'"$T"'"' sh -c "cat '$T/init.json' 2>/dev/null; exit 0"

echo
echo "== 5) 可覆盖性（换基线 / 换 provider 不该改脚本）"
FAKE_DIR="$T" FAKE_MODE=ok DSH_BIN="$T/dsh" DSH_NODE="$NODE_BIN" \
    DSH_SDK_PROVIDER=some-other DSH_SDK_MODEL=other-model DSH_SDK_CWD=/tmp \
    sh "$PROBE" >/dev/null 2>&1
run_has "DSH_SDK_PROVIDER 覆盖生效" 0 '"provider":"some-other"' sh -c "cat '$T/init.json' 2>/dev/null; exit 0"

echo
echo "== 6) 默认 cwd 与身份无关（没人指定时，不能因为进不去 /root 就判红）"
_out=$(FAKE_DIR="$T" FAKE_MODE=ok DSH_BIN="$T/dsh" DSH_NODE="$NODE_BIN" sh "$PROBE" 2>&1); _rc=$?
_cwdline=$(printf '%s\n' "$_out" | grep '^cwd  : ')
if [ "$_rc" -eq 0 ] && printf '%s' "$_out" | grep -q 'RESULT=OK'; then
    _ok "未指定 cwd 也能握手（$_cwdline）"
else
    _no "未指定 cwd 就判红（CI 的 uid 1001 进不去 /root，报出来却是 EACCES）" "rc=$_rc: $_cwdline"
fi
if [ -d /root ] && [ -x /root ]; then
    case "$_cwdline" in
        *"/root") _ok "cwd 默认 /root（当前身份可进入）" ;;
        *) _no "cwd 默认值应为 /root" "$_cwdline" ;;
    esac
else
    case "$_cwdline" in
        *fallback*) _ok "cwd 回落到可用目录并如实标注（$_cwdline）" ;;
        *) _no "进不去 /root 却没有标注 fallback" "$_cwdline" ;;
    esac
fi

echo
echo "== 7) 探针本体换 shell 复跑（真机 /system/bin/sh 是 mksh，不是 dash）"
if command -v mksh >/dev/null 2>&1; then
    PROBE_SH=mksh run_has "mksh: 正常握手 -> 0" 0 "RESULT=OK" P ok
    PROBE_SH=mksh run_has "mksh: 缺 serverInfo 仍判红" 1 "RESULT=FAIL" P noserverinfo
    run_has "mksh: 环境缺失仍分离" 2 "reason=dsh" \
        env DSH_BIN=/nonexistent/dsh DSH_NODE="$NODE_BIN" mksh "$PROBE"
else
    echo "  (没有 mksh，跳过；CI 里会装)"
fi

echo
echo "== 结论"
printf '  通过 %s 条，失败 %s 条\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
    echo "  sdk 协议探针没达到契约：先修探针，再谈 P1 接线。"
    exit 1
fi
echo "  sdk 协议探针符合契约：六种故障态全部判红，环境缺失与握手失败已分开。"
exit 0
