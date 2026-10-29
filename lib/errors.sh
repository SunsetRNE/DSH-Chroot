#!/system/bin/sh
# lib/errors.sh —— 由 tools/gen-errors.py 从 spec/errors.json 生成，**不要手改**。
# 为什么要这个文件：dsh-ctl diag 要在设备上（只有 mksh、没有 python/json）
# 按同一份真源判读证据，所以把表烘成 shell 能读的 '|' 分隔文本。
#
# 字段: code|layer|status|title|expect|fix|probe
# 注意：
#   ① probe 故意排在最后一列 —— 它含 '|'（shell 管道），read 会把余下字段连同分隔符一起给它；
#   ② 表格用**带引号的 heredoc**（<<'EOT'）而不是单引号大字符串 —— 探针里有 '（grep ' /data '），
#      单引号会被提前闭合，后面的 | 和 < 就被当成管道/重定向执行了（首版踩过）。
emit_errors() {
    cat <<'EOT'
E-L0K-MNT-001|L0K|reported|/data 带 nosuid → 容器内 SUID 程序失效|不含 nosuid（或明确知道自己在用 fix-suid）|知情后决定是否 fix-suid；它与『ro bind 保护基线』互相影响|grep ' /data ' /proc/mounts | cut -d' ' -f4
E-L1C-DEV-001|L1C|verified|容器 /dev 不可信（null 是普通文件 / 没有 ptmx）|两个都是 c 开头的字符设备|runtime_start 每次重建：tmpfs /dev + mknod(null zero full random urandom tty ptmx) + devpts|ls -l <rootfs>/dev/null <rootfs>/dev/ptmx
E-L1C-MNT-001|L1C|verified|只读 bind 其实是 rw（toybox 静默失败）|以 ro, 开头|service.sh 的 rt_make_ro：toybox 两种写法 → busybox → 仍失败则写 run/layers-rw 并在 status 显式报|grep ' /opt/dsh/current ' /proc/mounts | cut -d' ' -f4
E-L1C-PTY-001|L1C|verified|PTY 不可用（out of pty devices / pts 目录空）|RESULT=OK 且出现 /dev/pts/N|先按 E-L1C-DEV-001 建 /dev，再 mount -t devpts devpts <rootfs>/dev/pts|sh tools/verify-pty.sh <node-pty目录>
E-L2D-AUTH-001|L2D|verified|带 token 也打不开（401）|200|从 run/dsh.json 重新取；curl 必须带 cookie jar（-c/-b），否则 303 之后的请求会掉成 401|curl -sL -c ck -b ck -o /dev/null -w '%{http_code}' 'http://127.0.0.1:<port>/?token=<token>'
E-L2D-PKG-001|L2D|verified|npm 11 拦装脚本 → node-pty/koffi 二进制缺失（树哈希仍自洽）|无异常；失败会打印 MODULE_NOT_FOUND / 找不到 .node|npm i -g --allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs @deepseek-ai/dsh@<ver>|node -e "require('<层>/dsh/node_modules/node-pty')"
E-L2D-PORT-001|L2D|verified|dsh 起来了但没在超时内报出端口|看到 dsh 自己打印的启动行 `dsh web: http://127.0.0.1:<port>/?token=…`|看 dsh.log；确认 /root/.dsh 可写（0700）与 PATH 里有 node；必要时 RT_READY_TIMEOUT 调大|tail -20 <DSH_ROOT>/log/dsh.log
E-L3S-PAY-001|L3S|verified|payload 缺失或哈希不符（退出码 30）|node : ok / layer : <ver> (ok)；inbox 里有 node-*.tar.gz 与 dsh-*.tar.gz|dsh-ctl install <tar.gz> + 对应 .json；bootstrap --offline；哈希必须是 payload 的 sha256|sh <DSH_ROOT>/service.sh status; ls <DSH_ROOT>/inbox
E-L3S-UPD-001|L3S|verified|update.json 与真源不同步（gen-version 以 exit 2 拒绝）|退出码 0|把 update.json 的 version/versionCode/zipUrl 三处一起改，再 gen-version|python3 tools/gen-version.py --check
E-L3S-VER-001|L3S|verified|版本闸门拒绝启动（退出码 50）|ok (baked) · installed=… floor=… baked=…|按 reason 处理：投递对应层 / 修 manifest / 重新 bootstrap|sh <DSH_ROOT>/service.sh status | grep version
E-L4U-HOST-001|L4U|reported|局域网打不开（进程在、端口通 127.0.0.1）|401（说明通了但需 token）或 200|本版设计如此；要 lan 需另开决定（ADR-006 重审）|curl -s -o /dev/null -w '%{http_code}' http://<手机IP>:<port>/
EOT
}

# 字段: id|when(空格分隔的 code)|verdict|next
emit_signatures() {
    cat <<'EOT'
SIG-MISSING|E-L3S-PAY-001|缺件：还没投递 payload|dsh-ctl install → bootstrap --offline
SIG-NOT-ROOTFS|E-L2D-PORT-001 E-L1C-DEV-001|容器根文件系统不完整（/dev 没建）——不是 dsh 的问题|按 E-L1C-DEV-001 处理，再 start
SIG-NO-PTY|E-L2D-PKG-001 E-L1C-PTY-001|装包时漏了 install-scripts，且容器缺 devpts（两件事同源：都没有『功能探针』）|重装带 --allow-scripts；再建 /dev 与 devpts
SIG-RW-LAYERS|E-L1C-MNT-001|完整性保护缺失（层可写）——功能不受影响，但 AI 能改自己的运行时|确认 busybox 可用，或接受并在 run/layers-rw 里记账
EOT
}
