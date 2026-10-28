# 报错与定位（自动生成，不要手改）

> 真源：[`spec/errors.json`](../spec/errors.json)；生成：`python3 tools/gen-errors.py`。
> 每条报错都绑定一条**能证明它**的探针命令 —— 先跑探针，再下结论。

## 怎么用

1. 拿到现象（或退出码），在下表里找相同 `code`；
2. 跑该条的 `探针`，看是否符合 `期望` —— 不符合就说明不是这条；
3. 若同时命中多条，查下面的[组合签名](#组合签名)，它给的是**一个**结论而不是一堆猜测。

## 退出码 ↔ 错误

| 退出码 | 含义 | 对应 code |
|---|---|---|
| 30 | payload 缺失 / 校验失败 | `E-L3S-PAY-001` |
| 50 | 版本闸门拒绝 | `E-L3S-VER-001` |
| 60 | 运行时未就绪（容器起不来） | `E-L2D-PORT-001` / `E-L1C-DEV-001` |


## 码表

### L0 内核 / 挂载标志

| code | 症状 | 状态 |
|---|---|---|
| `E-L0K-MNT-001` | /data 带 nosuid → 容器内 SUID 程序失效 | reported |

### L1 容器（rootfs / 挂载 / /dev / PTY）

| code | 症状 | 状态 |
|---|---|---|
| `E-L1C-DEV-001` | 容器 /dev 不可信（null 是普通文件 / 没有 ptmx） | verified |
| `E-L1C-MNT-001` | 只读 bind 其实是 rw（toybox 静默失败） | verified |
| `E-L1C-PTY-001` | PTY 不可用（out of pty devices / pts 目录空） | verified |

### L2 DSH 本体（装包 / 启动 / 鉴权）

| code | 症状 | 状态 |
|---|---|---|
| `E-L2D-AUTH-001` | 带 token 也打不开（401） | verified |
| `E-L2D-PKG-001` | npm 11 拦装脚本 → node-pty/koffi 二进制缺失（树哈希仍自洽） | verified |
| `E-L2D-PORT-001` | dsh 起来了但没在超时内报出端口 | verified |

### L3 壳（payload / 版本闸门 / 产物同步）

| code | 症状 | 状态 |
|---|---|---|
| `E-L3S-PAY-001` | payload 缺失或哈希不符（退出码 30） | verified |
| `E-L3S-UPD-001` | update.json 与真源不同步（gen-version 以 exit 2 拒绝） | verified |
| `E-L3S-VER-001` | 版本闸门拒绝启动（退出码 50） | verified |

### L4 前端（浏览器 / 局域网）

| code | 症状 | 状态 |
|---|---|---|
| `E-L4U-HOST-001` | 局域网打不开（进程在、端口通 127.0.0.1） | reported |

## 详情

### `E-L0K-MNT-001` /data 带 nosuid → 容器内 SUID 程序失效

- **症状**：apt 的 gpgv 报错、sudo 类程序不工作
- **探针**：`grep ' /data ' /proc/mounts | cut -d' ' -f4`
- **期望**：不含 nosuid（或明确知道自己在用 fix-suid）
- **根因**：/data 默认可能 nosuid,nodev,noexec；chroot-distro 的 fix-suid 会 remount 宿主
- **处置**：知情后决定是否 fix-suid；它与『ro bind 保护基线』互相影响
- **易误判**：在容器里查不出来，必须看宿主挂载表
- **相关**：pitfalls A18

### `E-L1C-DEV-001` 容器 /dev 不可信（null 是普通文件 / 没有 ptmx）

- **症状**：写入 /dev/null 变成追加文件；PTY 直接不可用
- **探针**：`ls -l <rootfs>/dev/null <rootfs>/dev/ptmx`
- **期望**：两个都是 c 开头的字符设备
- **根因**：rootfs 来自 tarball，/dev 里可能只有普通文件（真机实测 /dev/null 是 23 字节普通文件）
- **处置**：runtime_start 每次重建：tmpfs /dev + mknod(null zero full random urandom tty ptmx) + devpts
- **易误判**：哈希校验、tree.sha256 全都通过，功能却是死的
- **相关**：ADR-029

### `E-L1C-MNT-001` 只读 bind 其实是 rw（toybox 静默失败）

- **症状**：层目录挂上了，但容器里能改 /opt/dsh/current；AI 可以改自己的运行时
- **探针**：`grep ' /opt/dsh/current ' /proc/mounts | cut -d' ' -f4`
- **期望**：以 ro, 开头
- **根因**：toybox 的 `mount -o bind,ro` 与 `-o remount,ro,bind` 返回 0 但不带 MS_RDONLY；只有 busybox 的 remount,ro,bind 生效
- **处置**：service.sh 的 rt_make_ro：toybox 两种写法 → busybox → 仍失败则写 run/layers-rw 并在 status 显式报
- **易误判**：看 mount 的退出码会以为成功了
- **相关**：ADR-009 · ADR-029

### `E-L1C-PTY-001` PTY 不可用（out of pty devices / pts 目录空）

- **症状**：node-pty spawn 报 OSError('out of pty devices')；python pty 也失败
- **探针**：`sh tools/verify-pty.sh <node-pty目录>`
- **期望**：RESULT=OK 且出现 /dev/pts/N
- **根因**：没挂 devpts（容器 /dev 是 tmpfs 时尤其容易漏），或 /dev/ptmx 不存在
- **处置**：先按 E-L1C-DEV-001 建 /dev，再 mount -t devpts devpts <rootfs>/dev/pts
- **易误判**：看到 /proc/mounts 里宿主的 ptmxmode=000 就以为不可用——容器内看的是 /dev/ptmx 本身
- **相关**：ADR-029 · research §9.1.1

### `E-L2D-AUTH-001` 带 token 也打不开（401）

- **症状**：浏览器显示 dsh web authentication required
- **探针**：`curl -sL -c ck -b ck -o /dev/null -w '%{http_code}' 'http://127.0.0.1:<port>/?token=<token>'`
- **期望**：200
- **根因**：token 抄错 / 用了旧的 dsh.json / 没带 cookie 跟第二次跳转
- **处置**：从 run/dsh.json 重新取；curl 必须带 cookie jar（-c/-b），否则 303 之后的请求会掉成 401
- **易误判**：只看 303 就以为失败；只看 401 就以为 token 错
- **相关**：ADR-021 · ADR-029

### `E-L2D-PKG-001` npm 11 拦装脚本 → node-pty/koffi 二进制缺失（树哈希仍自洽）

- **症状**：dsh 能启动但 PTY/沙箱相关全挂；安装树看起来完整
- **探针**：`node -e "require('<层>/dsh/node_modules/node-pty')"`
- **期望**：无异常；失败会打印 MODULE_NOT_FOUND / 找不到 .node
- **根因**：npm 11 默认不跑 postinstall，只给一行 npm warn install-scripts
- **处置**：npm i -g --allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs @deepseek-ai/dsh@<ver>
- **易误判**：vendor-check 全绿、tree.sha256 两次一致 —— 哈希对，功能死
- **相关**：ADR-027

### `E-L2D-PORT-001` dsh 起来了但没在超时内报出端口

- **症状**：start 返回 60；run/dsh.json 不存在；log/dsh.log 里可能有堆栈
- **探针**：`tail -20 <DSH_ROOT>/log/dsh.log`
- **期望**：看到 dsh 自己打印的启动行 `dsh web: http://127.0.0.1:<port>/?token=…`
- **根因**：profile/依赖问题、端口被占、或 DSH_HOME 不可写；也可能是启动行格式变了
- **处置**：看 dsh.log；确认 /root/.dsh 可写（0700）与 PATH 里有 node；必要时 RT_READY_TIMEOUT 调大
- **易误判**：把 60 当成 payload 缺失（那是 30）
- **相关**：ADR-029

### `E-L3S-PAY-001` payload 缺失或哈希不符（退出码 30）

- **症状**：start/bootstrap 返回 30；status 里 node/layer 是 missing
- **探针**：`sh <DSH_ROOT>/service.sh status; ls <DSH_ROOT>/inbox`
- **期望**：node : ok / layer : <ver> (ok)；inbox 里有 node-*.tar.gz 与 dsh-*.tar.gz
- **根因**：还没投递、投递了但清单不是同一份、或传输损坏
- **处置**：dsh-ctl install <tar.gz> + 对应 .json；bootstrap --offline；哈希必须是 payload 的 sha256
- **易误判**：把 30 和 60 混为一谈（60 是起不来，不是缺件）
- **相关**：ADR-013 · ADR-029

### `E-L3S-UPD-001` update.json 与真源不同步（gen-version 以 exit 2 拒绝）

- **症状**：gen-version 报 update.json 的 version 与真源不一致
- **探针**：`python3 tools/gen-version.py --check`
- **期望**：退出码 0
- **根因**：改了 version.env / 台账但没同步 update.json
- **处置**：把 update.json 的 version/versionCode/zipUrl 三处一起改，再 gen-version
- **易误判**：以为 update.json 也是生成物 —— 它是外部文件，需手工同步
- **相关**：ADR-025

### `E-L3S-VER-001` 版本闸门拒绝启动（退出码 50）

- **症状**：start 返回 50；日志里有 reason=below-floor / invalid-installed / manifest-missing
- **探针**：`sh <DSH_ROOT>/service.sh status | grep version`
- **期望**：ok (baked) · installed=… floor=… baked=…
- **根因**：层版本低于 floor 且没有可回落的 baked；或 .layer 里读不出 version；或 manifest 缺失
- **处置**：按 reason 处理：投递对应层 / 修 manifest / 重新 bootstrap
- **易误判**：手改 module.prop 或 manifest 想绕过闸门 —— 真源在 baseline/ 三份文件
- **相关**：ADR-025 · ADR-026

### `E-L4U-HOST-001` 局域网打不开（进程在、端口通 127.0.0.1）

- **症状**：手机自己能访问，另一台机器连不上
- **探针**：`curl -s -o /dev/null -w '%{http_code}' http://<手机IP>:<port>/`
- **期望**：401（说明通了但需 token）或 200
- **根因**：dsh 只 bind 了 127.0.0.1（本版按 ADR-006 只做 local）
- **处置**：本版设计如此；要 lan 需另开决定（ADR-006 重审）
- **易误判**：以为是防火墙/路由器问题
- **相关**：ADR-006

## 组合签名

单条证据往往不足以下结论，所以这里把「同源故障」写成签名：命中的 `code` 组合 → **一个**结论，而不是一串猜测。

> `when` 只有 1 条 = 该条本身即可定论；≥2 条 = 组合定位（几条证据指向同一个根因）。

| 签名 | 同时命中 | 结论 | 下一步 |
|---|---|---|---|
| `SIG-MISSING` | `E-L3S-PAY-001` | 缺件：还没投递 payload | dsh-ctl install → bootstrap --offline |
| `SIG-NOT-ROOTFS` | `E-L2D-PORT-001` + `E-L1C-DEV-001` | 容器根文件系统不完整（/dev 没建）——不是 dsh 的问题 | 按 E-L1C-DEV-001 处理，再 start |
| `SIG-NO-PTY` | `E-L2D-PKG-001` + `E-L1C-PTY-001` | 装包时漏了 install-scripts，且容器缺 devpts（两件事同源：都没有『功能探针』） | 重装带 --allow-scripts；再建 /dev 与 devpts |
| `SIG-RW-LAYERS` | `E-L1C-MNT-001` | 完整性保护缺失（层可写）——功能不受影响，但 AI 能改自己的运行时 | 确认 busybox 可用，或接受并在 run/layers-rw 里记账 |
