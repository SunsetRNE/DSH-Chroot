#!/system/bin/sh
# 在容器内验证 PTY 是否可用（node-pty 与 python pty 双通道交叉验证）。
# 用法: sh verify-pty.sh [node-pty 所在目录，默认自动探测]
# 退出码: 0=至少一路通过  1=两路都失败

set -u
PTY_DIR="${1:-}"
FAIL=0

echo "=== 环境 ==="
id 2>/dev/null | head -1
uname -r 2>/dev/null
ls -l /dev/ptmx 2>&1 | head -1
grep devpts /proc/mounts 2>/dev/null | head -1 || echo "(读不到 /proc/mounts)"

# ---- 通道 1：node-pty ----
if command -v node >/dev/null 2>&1; then
  if [ -z "$PTY_DIR" ]; then
    for cand in \
      /usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules \
      /usr/lib/node_modules/@deepseek-ai/dsh/node_modules \
      /opt/dsh/base/*/lib/node_modules/@deepseek-ai/dsh/node_modules; do
      [ -d "$cand/node-pty" ] && PTY_DIR="$cand" && break
    done
  fi
  if [ -n "$PTY_DIR" ] && [ -d "$PTY_DIR/node-pty" ]; then
    echo "=== 通道1: node-pty ($PTY_DIR) ==="
    TMP=$(mktemp /tmp/pty.XXXXXX.js)
    cat > "$TMP" <<EOF
const pty = require("$PTY_DIR/node-pty");
let out = "";
const p = pty.spawn("/bin/sh", ["-c", "echo PTY_OK; tty"], { name: "xterm-256color", cols: 100, rows: 30 });
p.onData(d => { out += d; });
p.onExit(({ exitCode }) => {
  const ok = out.indexOf("PTY_OK") >= 0 && out.indexOf("/dev/pts/") >= 0;
  console.log((ok ? "RESULT=OK " : "RESULT=FAIL ") + JSON.stringify(out.replace(/\r/g, "").trim()));
  process.exit(ok ? 0 : 1);
});
setTimeout(() => { console.log("RESULT=FAIL timeout"); process.exit(1); }, 8000);
EOF
    node "$TMP" || FAIL=$((FAIL+1))
    rm -f "$TMP"
  else
    echo "=== 通道1: 跳过（找不到 node-pty；可传入路径作为参数）==="
    FAIL=$((FAIL+1))
  fi
else
  echo "=== 通道1: 跳过（没有 node）==="
  FAIL=$((FAIL+1))
fi

# ---- 通道 2：python pty ----
if command -v python3 >/dev/null 2>&1; then
  echo "=== 通道2: python pty ==="
  python3 - <<PY || FAIL=$((FAIL+1))
import os, pty, sys
pid, fd = pty.fork()
if pid == 0:
    os.execv("/bin/sh", ["/bin/sh", "-c", "echo PYPTY_OK; tty"])
buf = b""
while True:
    try:
        d = os.read(fd, 4096)
    except OSError:
        break
    if not d:
        break
    buf += d
os.waitpid(pid, 0)
txt = buf.decode("utf-8", "replace")
ok = "PYPTY_OK" in txt and "/dev/pts/" in txt
print(("RESULT=OK " if ok else "RESULT=FAIL ") + txt.replace(chr(13), "").strip().replace(chr(10), " | "))
sys.exit(0 if ok else 1)
PY
else
  echo "=== 通道2: 跳过（没有 python3）==="
  FAIL=$((FAIL+1))
fi

echo "=== 结论 ==="
if [ "$FAIL" -ge 2 ]; then
  echo "两路都未通过：这个容器里 PTY 不可用。"
  exit 1
fi
echo "至少一路通过：这个容器里 PTY 可用。"
exit 0
