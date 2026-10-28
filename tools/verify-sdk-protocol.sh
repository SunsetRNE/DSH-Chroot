#!/bin/sh
# tools/verify-sdk-protocol.sh —— 在容器内验证 DSH 的 sdk profile 能跑通 stdio JSON-RPC 握手
#
# 干什么：spawn `dsh --profile sdk`（NDJSON over stdin/stdout），发 initialize 收 serverInfo，
#         再发 shutdown，期望干净退出。这是 **P1（垫片走 sdk 载体）的唯一硬证据**（ADR-028）。
#
# 与 verify-pty.sh 的分工：
#   verify-pty.sh          → 证明「容器里能起 PTY」（node-pty 通道）
#   verify-sdk-protocol.sh → 证明「DSH 能被当库用」（协议通道）
#   两条都过，才谈得上写 Kotlin 侧的 ProcessHost + JsonRpcPipe。
#
# 用法:
#   sh tools/verify-sdk-protocol.sh
#   DSH_BIN=/usr/local/bin/dsh sh tools/verify-sdk-protocol.sh
#   DSH_SDK_TIMEOUT_MS=60000 sh tools/verify-sdk-protocol.sh
#
# 退出码（tools/test-sdk-protocol.sh 逐条对账）:
#   0 = 握手通过（initialize 带回 serverInfo 且 shutdown 干净退出）
#   1 = 握手失败（缺 serverInfo / 错误响应 / 超时 / 非零退出 / 提前断流）
#   2 = 环境缺失（找不到 node 或 dsh）
#
# 设计要点：
#   - 只用 stdin/stdout；不碰端口、不碰 socket、不碰 DSH_HOME 之外的状态（ADR-009 的窄接口）。
#   - provider / model 由 initialize 的 params 带入；缺了上游会回 -32603
#     `no adapter registered for provider "undefined"`（真机踩过，见 ADR-028 证据段）。
#   - JS 用**引号 heredoc**（'JSEOF'），参数一律走环境变量，避免被 shell 吃掉 $ / 反引号。

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
TIMEOUT_MS="${DSH_SDK_TIMEOUT_MS:-45000}"

# ---- 1) node ----
NODE_BIN="${DSH_NODE:-}"
if [ -z "$NODE_BIN" ]; then
    NODE_BIN=$(command -v node 2>/dev/null || true)
fi
if [ -z "$NODE_BIN" ] && [ -x /opt/node24/bin/node ]; then
    NODE_BIN=/opt/node24/bin/node
fi
if [ -z "$NODE_BIN" ] || [ ! -x "$NODE_BIN" ]; then
    echo "ENV=missing reason=node"
    echo "(找不到 node；可用 DSH_NODE=<path> 指定)"
    exit 2
fi

# ---- 2) dsh ----
DSH_BIN="${DSH_BIN:-}"
if [ -z "$DSH_BIN" ]; then
    DSH_BIN=$(command -v dsh 2>/dev/null || true)
fi
if [ -z "$DSH_BIN" ]; then
    for cand in /usr/local/bin/dsh /usr/bin/dsh /opt/dsh/base/*/bin/dsh; do
        [ -x "$cand" ] && DSH_BIN="$cand" && break
    done
fi
if [ -z "$DSH_BIN" ] || [ ! -x "$DSH_BIN" ]; then
    echo "ENV=missing reason=dsh"
    echo "(找不到 dsh；可用 DSH_BIN=<path> 指定)"
    exit 2
fi

# cwd：容器里 DSH 的家在 /root（真机以 root 身份跑，这就是对的）。
# 但换个身份跑（例如 CI 的 uid 1001）就进不去 /root —— spawn 会因为 chdir 失败报
# EACCES，看起来像"假 dsh 没有执行位"，实际是 cwd 不可进入（2026-10-28 CI 实锤）。
# 所以：显式给了就用；没给且 /root 可进入就用它；否则回落到可用目录，并**如实打印**。
if [ -n "${DSH_SDK_CWD:-}" ]; then
    CWD_NOTE=""
elif [ -d /root ] && [ -x /root ]; then
    DSH_SDK_CWD=/root
    CWD_NOTE=""
else
    DSH_SDK_CWD="${TMPDIR:-/tmp}"
    CWD_NOTE="  (fallback：当前身份进不去 /root)"
fi
export DSH_SDK_CWD

echo "=== 环境 ==="
echo "node : $NODE_BIN ($("$NODE_BIN" -v 2>/dev/null))"
echo "dsh  : $DSH_BIN"
echo "args : ${DSH_ARGS:---profile sdk}"
echo "cwd  : $DSH_SDK_CWD$CWD_NOTE"
echo "超时 : ${TIMEOUT_MS}ms"

# ---- 3) 协议探针 ----
export DSH_BIN NODE_BIN TIMEOUT_MS
DSH_SDK_TIMEOUT_MS="$TIMEOUT_MS" "$NODE_BIN" - <<'JSEOF'
const { spawn } = require('node:child_process');

const bin = process.env.DSH_BIN;
const args = (process.env.DSH_ARGS || '--profile sdk').split(' ').filter(Boolean);
const timeoutMs = Number(process.env.DSH_SDK_TIMEOUT_MS || 45000);
const provider = process.env.DSH_SDK_PROVIDER || 'deepseek-official';
const model = process.env.DSH_SDK_MODEL || 'deepseek-flash';
const cwd = process.env.DSH_SDK_CWD || process.cwd();

const t0 = Date.now();
let out = '';
let err = '';
let stage = 'spawn';
let done = false;

const child = spawn(bin, args, { cwd, env: process.env, stdio: ['pipe', 'pipe', 'pipe'] });
child.stdout.setEncoding('utf8');
child.stderr.setEncoding('utf8');

function finish(ok, detail) {
    if (done) return;
    done = true;
    const ms = Date.now() - t0;
    if (ok) {
        console.log('RESULT=OK ' + (detail || ''));
    } else {
        console.log('RESULT=FAIL stage=' + stage + ' ' + (detail || ''));
        if (err.trim()) {
            console.log('STDERR=' + JSON.stringify(err.trim().slice(0, 800)));
        }
    }
    console.log('ELAPSED_MS=' + ms);
    try { child.stdin.end(); } catch (e) {}
    try { child.kill('SIGKILL'); } catch (e) {}
    setTimeout(() => process.exit(ok ? 0 : 1), 30);
}

const timer = setTimeout(() => {
    finish(false, 'timeout=' + timeoutMs + 'ms（未在期限内完成 ' + stage + '）');
}, timeoutMs);

let seq = 0;
const pending = new Map();
function call(method, params) {
    const id = ++seq;
    const msg = { jsonrpc: '2.0', id, method };
    if (params !== undefined) msg.params = params;
    pending.set(id, method);
    child.stdin.write(JSON.stringify(msg) + '\n');
    return id;
}

child.on('error', (e) => { stage = 'spawn'; finish(false, 'spawn 失败: ' + e.message); });

child.stdin.on('error', (e) => {
    if (e && e.code === 'EPIPE') finish(false, 'stdin 被提前关闭（进程已退出）');
});

child.on('exit', (code, signal) => {
    if (done) return;
    finish(false, '提前退出 code=' + code + ' signal=' + signal);
});

let buf = '';
child.stdout.on('data', (chunk) => {
    buf += chunk;
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i).trim();
        buf = buf.slice(i + 1);
        if (!line) continue;
        let msg;
        try { msg = JSON.parse(line); } catch (e) { continue; } // 允许日志行混在 stdout
        if (msg.id === undefined || msg.id === null) continue; // 通知，忽略
        const method = pending.get(msg.id);
        pending.delete(msg.id);

        if (method === 'initialize') {
            if (msg.error) {
                finish(false, 'initialize 返回错误 ' + (msg.error.code || '') + ' ' + (msg.error.message || ''));
                return;
            }
            const info = msg.result && msg.result.serverInfo;
            stage = 'serverInfo';
            if (!info || typeof info !== 'object') {
                finish(false, 'initialize 的 result 里没有 serverInfo');
                return;
            }
            if (typeof info.name !== 'string' || !info.name) {
                finish(false, 'serverInfo.name 缺失');
                return;
            }
            if (typeof info.version !== 'string' || !info.version) {
                finish(false, 'serverInfo.version 缺失');
                return;
            }
            console.log('SERVER_NAME=' + info.name);
            console.log('SERVER_VERSION=' + info.version);
            if (info.name.indexOf('harness') < 0) {
                console.log('WARN=serverInfo.name 不含 harness（可能不是 dsh 的 sdk runtime）');
            }
            stage = 'shutdown';
            call('shutdown', {});
            return;
        }

        if (method === 'shutdown') {
            if (msg.error) {
                finish(false, 'shutdown 返回错误 ' + (msg.error.code || '') + ' ' + (msg.error.message || ''));
                return;
            }
            stage = 'exit';
            const code2 = child.exitCode;
            finish(true, 'serverInfo + shutdown 均正常（握手完成，exit=' + code2 + '）');
            return;
        }
    }
});

child.stderr.on('data', (chunk) => { err += chunk; });

stage = 'initialize';
call('initialize', {
    cwd,
    provider,
    model,
    approvalRequests: true,
    capabilities: { userQuestions: true },
});
JSEOF

rc=$?
echo "=== 结论 ==="
case "$rc" in
    0) echo "sdk profile 可用：这个容器里能把 DSH 当库用（P1 载体成立）。" ;;
    2) echo "环境缺失：先补 node / dsh。" ;;
    *) echo "sdk profile 不可用：P1 需要换载体（先看上面的 RESULT=FAIL 行）。" ;;
esac
exit "$rc"
