# 变更记录

版本号与 `module.prop` 的 `version` 一致（[规范](docs/versioning.md)）。`update.json` 的 `changelog` 指向本文件。

## v1.0.3.2（未发布）

- **`dsh-ctl diag` 上线：报错表从「人能看懂」变成「设备能判读」（2026-10-28，ADR-030 实现补充）** ——
  6 项只读证据 → 命中码 → 组合签名结论；零命中时明说「还没登记」，**不许硬凑**
  - `spec/errors.json` 多产一个 `lib/errors.sh`（shell 表）：设备上只有 mksh，没有 python / jq，JSON 吃不下
  - `dsh-ctl` 为 `diag` **跳过 cgroup 搬家**——只读契约优先于「入口该统一行为」
  - 新增 `tools/test-diag.sh`（**13 条**断言，dash + mksh 双端）并接进门禁；CI 从 18 步变 20 步
  - **修打包漏装**：`lib/errors.sh` 原先没进 `ENTRIES` / 没被 `customize.sh` 复制 → 真机上 `diag` 只会 `rc=2`；
    包 13 → **14 条目**，并加自测断言「装完 `diag` 能判读」守住这件事

- **P2 闭环：`runtime_start` 的 real 分支（2026-10-28，ADR-029）** —— `start` 不再是 30，而是真的把 DSH 跑起来
  - 真机实测：`dsh web --port 0` 在 chroot 里起来后，stdout **首行**就是 `dsh web: http://127.0.0.1:<port>/?token=…`；
    端口与 token 从这一行取，写进 `run/dsh.json`（**0600**），日志里只有端口
  - **token 全程不落盘**：启动行走「数据 fifo → 结果 fifo」搬运，`run/dsh.json` 是唯一落地处（ADR-022）
  - **退出码新增 60**「运行时未就绪」：与 30（payload 缺失/校验失败）分开，`status` 能直接看出是缺件还是起不来
  - **挂载表（最小集）**：`base/node` → `/opt/dsh/node`（ro）· `base/dsh-<ver>` → `/opt/dsh/current`（ro）· `data/.dsh` → `/root/.dsh`（rw）
    · `proc` · `tmpfs /dev` + `devpts /dev/pts`
  - **容器 `/dev` 必须自己建**：真机实测这个 rootfs 的 `/dev/null` 是 **23 字节的普通文件**、`/dev/ptmx` 不存在
    → 不建 devtmpfs 就是「哈希对、功能死」（PTY 直接不可用，`verify-pty.sh` 双通道都红）
  - ⚠️ **toybox 的只读 bind 是静默失败**：`mount -o bind,ro` 与 `-o remount,ro,bind` 都返回 0 但仍 `rw`；
    只有 **busybox** 的 `remount,ro,bind` 真的生效（写入 `EROFS`）。所以挂完必须**验 `/proc/mounts` 的 flags**，
    验不过就写 `run/layers-rw` 并在 `status` 里显式报「完整性保护缺失」——不假装
  - 停止：按**进程组**杀（`setsid` 起的会话首进程 = pgid），再 `KILL` 兜底；停完整层卸载 + 删 `dsh.json`
- **新增 `tools/verify-runtime.sh`（真机探针，18 条断言）**：起容器 → 查 `dsh.json` → 验两层 `ro` → 带 token 访问（200）
  → 不带 token 被拒（401）→ 验日志无 token → stop 后进程/挂载/`dsh.json` 全清。退出码 **0/1/2**
- **契约测试 43 → 47 条**（`tools/test-service.sh` §11）：rootfs 不存在 → 60、目录不像 rootfs → 60、失败不留 `dsh.json`、`status` 报 runtime
- **报错体系骨架（ADR-030）**：`spec/errors.json` 单一真源 → `docs/errors.md` 由脚本生成，`--check` 接进门禁（**文档不手改**）
  - **11 条错误码**（`E-L<层><类>-<大类>-<序号>`，层 = `L0K` 内核 / `L1C` 容器 / `L2D` 本体 / `L3S` 壳 / `L4U` 前端）
    + **4 个组合签名**；9 条 `verified`（有真机或 CI 证据）、2 条 `reported`（未实测，明确标注，不冒充已验证）
  - **每条必须绑一条能证明它的探针**（`probe` + `expect`）：说不出"跑什么命令能证明它"的，不许进表
  - 组合签名回答"到底是哪一种报错"：`when` 1 条 = 该条即可定论，≥2 条 = 同源组合
    （例：`E-L2D-PORT-001 + E-L1C-DEV-001` → 「容器根文件系统不完整，不是 dsh 的问题」）
  - 生成器会拦：code 格式 / 全局唯一 / **层前缀与 `layer` 一致** / 签名与退出码引用的 code 必须存在；`--check` 逐字节比对文档
  - 退出码 ↔ 错误 的映射也放真源（`exit_codes`），生成器**不硬编码任何领域知识**（否则就是第二份真源）
- 文档：`guide.md` 第 6 步收口、`module.md` 开机路径、`docs/errors.md`（新增）、ADR-029、ADR-030、本文件
- **修：CI 首跑就曝出的探针缺陷（2026-10-28）** —— 这正是「报错大全」要治的那类误判
  - `verify-sdk-protocol.sh` 把默认 cwd 写死 `/root`；CI 以 **uid 1001** 跑，`spawn(..., {cwd:'/root'})`
    的 chdir 直接失败，报出来却是 `EACCES` 且路径指向假 dsh —— **看着像"文件没有执行位"，实际是 cwd 不可进入**
  - 现改为：显式指定 > `/root` 可进入则用它 > 否则回落到 `$TMPDIR`，并**把 fallback 打印在环境行**
  - 测试同步：`P()` 显式传 `DSH_SDK_CWD="$T"`；§4 的 cwd 断言不再依赖"以谁的身份跑"；
    新增 §6「默认 cwd 与身份无关」两条断言（本机 19/19，dash 与 sh 各跑一遍）

## v1.0.2.2（未发布）

- **基线抬升：DSH 0.2.0-rc.2 → 0.2.1-rc.4（台账 `seq=2`，2026-10-28）** —— ADR-022 只追 RC，取 npm `next` 通道
  - `dsh-0.2.1-rc.4.tar.gz` **154.0 MiB**（161,532,738 B）/ 68,202 条目 / sha256 `7c31ca6a…155fc6`；解包 752 MiB，`dsh/node_modules` 194 个顶层包
  - **Node 对齐到 24.21.0**（`node` 层不重烘、sha256 与清单不变，只换 dsh 层）+ `pnpm 11.28.5` + `npm 11.19.0`
  - ⚠️ **npm 11 默认拦装脚本**：不显式 `--allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs`，
    装出来的树**没有 `node-pty` / `koffi` 的二进制**——而树哈希照样自洽。本次先踩后修（第一版树 PTY 是死的），已写进 `vendor/dsh/SOURCE.json` 的 `install` 字段
  - `floor` 同步抬到 `0.2.1-rc.4`（模块未发布过，没有旧用户层被停用；一行改回即可降回 `0.2.0-rc.2`）
  - `version` `1.0.2.1` → **`1.0.2.2`**（第 4 位 = 台账 seq 2）· `versionCode` 3 → **4**
- **vendor 基准线整份重做（ADR-027）**
  - `vendor/dsh/`：rc.4 tarball（25,132 B）+ 解包包体（20 文件）+ `npm-shrinkwrap.json`（237,268 B）+ `tree.sha256`（**68,198 项**，9.1 MiB，aggregate `d9f35ab2…`）
  - **两次独立 `npm i -g` 后树清单逐字节相同**（这次是量出来的，不是声称的）；`tools/vendor-check.py --stage` 对已构建的层树同样通过
  - 旧 rc.2 的 tarball 与 `package/` 已替换（git 历史保留）
- **设备侧复验（Node 24.21.0 对齐后）**：`node-pty` 双通道 PTY OK（`/dev/pts/0`）· P1 握手 **1252 ms**（`initialize`→`serverInfo`→`shutdown`）· 全门禁 18 步绿（含 `vendor-check --stage`）
- 文档：`baseline.md`（基线行 / 复现命令含 `--allow-scripts` / 分叉说明改为已拍板）、`payload.md` §4 产物表、`README` version 行、`guide.md` 进度表

## v1.0.2.1（未发布）

- **P1 载体定案：`dsh --profile sdk` 的 stdio JSON-RPC（2026-10-28，ADR-028）**
  - 真机 chroot 实测：`initialize` → `serverInfo`（`deepseek-harness-sdk-runtime 0.0.1`）**全往返 1221 ms**，`shutdown` 后进程干净退出；
    不需要端口、不需要 token、不落 HTTP 凭据
  - 新增 `tools/verify-sdk-protocol.sh`：设备侧探针，退出码 **0=通过 / 1=握手失败 / 2=环境缺失**，参数一律走 `DSH_*` 环境变量（换基线不改脚本）
  - 新增 `tools/test-sdk-protocol.sh`：CI 契约 **20 条**——用假 dsh 演六种故障态（缺 `serverInfo` / `-32603` / 启动即崩 / 挂住不回 / stdout 污染 / 环境缺失），
    dash 与 mksh 各跑一遍；**不联网、不装 616 个包、不需要 root**
  - `.github/workflows/gate.yml` 新增两步；`docs/decisions.md` 增 ADR-028；`docs/guide.md` 进度表 + 下一步重排（real 分支降为 P2）；`docs/baseline.md` 复现清单加“sdk 握手”一项
  - `web` 载体（`--port 0` + 启动行 token URL）保留为 **P2**，与 P1 共用 `ProcessHost`，就绪判据不同；`start` 仍如实报 **30**
  - 已是历史：基线在 **1.0.2.2** 里抬到了 `0.2.1-rc.4`（见上一条），本节的 1221 ms 是抬升前在 Node 24.22.1 上的首测
- **vendor 基准线（2026-10-19）**：外部依赖拉进仓库，不再“构建时上游刚好是什么”
  - `vendor/chroot-distro/`：2.1.0+main.20251218 脚本（90 KB，**原样**）+ GPLv3 全文 + `SOURCE.json`
  - `vendor/dsh/`：`@deepseek-ai/dsh@0.2.0-rc.2` tarball + 解包包体 + `npm-shrinkwrap.json`（538 包精确版本 + integrity）+ `tree.sha256`（29,280 项逐文件清单；**两次独立安装树哈希相同**）
  - `NOTICE` + `vendor/README.md`：仓库 MIT；chroot-distro GPLv3；DSH MIT；分发边界写清
  - `tools/vendor-check.py`：校验 vendor 文件哈希 + 已组装 DSH 树；CI 新增一步
- **模块内置 chroot-distro**：`bin/chroot-distro`（90 KB）+ `licenses/chroot-distro/{LICENSE,SOURCE.json}` 进 zip；`customize.sh` 落到 `$DSH_ROOT/bin` 与 `$DSH_ROOT/licenses/`。运行时尚待 `runtime_start` 接线
- **DSH 层改用干净安装树重建**：两次独立 `npm i -g`（npm 11.19.0 / Node 24.21.0）树哈希相同；新 `dsh-0.2.0-rc.2.tar.gz` 117.0 MiB / 25,974 文件 / sha256 `4c420513…2b62`；node 层不变
- 旧 1.0.1.1 的 dsh 层（116.9 MiB / 13,382 文件，含 DSHA 带进来的 extraneous 包）作废；**必须用 1.0.2.1 的 payload**
- 版本 `1.0.1.1` → `1.0.2.1`（补丁位 1 → 2）· `versionCode` 2 → 3
- 说明：`npm-shrinkwrap.json` 是从已验证安装树生成的**记录**，不是 drop-in `npm ci`（原树是 global 安装，dev/optional 未齐）；重建以 `tree.sha256` 为准

## v1.0.1.1（未发布）

- **payload 首次烘焙（2026-10-19）**：Node **24.21.0**（npm 11.19.0）+ pnpm **11.28.5** / DSH **0.2.0-rc.2**
  - `node-24.21.0.tar.gz` 60.4 MiB（解压 227 MiB）· sha256 `168d5988…d0d606`
  - `dsh-0.2.0-rc.2.tar.gz` 116.9 MiB（解压 439 MiB / 13,382 文件）· sha256 `72d821ca…5ba503`
  - 两层各自**独立重建一次**，sha256 逐字节相同 —— 确定性是量出来的，不是声称的
  - 解包后实测：`bin/dsh --version` = `0.2.0-rc.2`；`node-pty` 在新 Node 上 `pty.spawn` 返回 `PTY_OK`
- `baseline/manifest.example.json`：`layers` 的 `REPLACE_ME` → 真实 sha256；`pnpm_floor` 10.0.0 → 11.0.0
- 版本 `1.0.0.1` → `1.0.1.1`（同一 baked 重打层 → 补丁位 +1）· `versionCode` 1 → 2（第 2 次对外变更）
- `gen-version.py` 从 `--draft` 转为**发布模式**（CI 同步）：任何 `REPLACE_ME` 再出现都 exit 2
- 文档：payload §3/§4/§8 钉死 Node/pnpm 与实测体积；baseline §1/§5/§6、guide 进度表、versioning/module/README 的 `--draft` 说明同步
- **仍未做**：`runtime_start` 的 real 分支（bind 两层 + 起 `dsh web` + 解析端口）→ payload 就位后 `start` 仍报 30

## v1.0.0.1（未发布）

- 模块身份定稿：`id=Zodiac-Quill-Saga` · `name=DSH Chroot` · 仓库 `DSH-Chroot`
- 版本真源与生成器落地：`tools/version.env` → `build/module.prop` / `build/manifest.json` / `build/apk-version.properties`
- 生成器改为 fail-closed：占位全文扫描、`floor ≤ baked`、`recommended > baked`、模板注释不进产物、`--draft` 逃生口
- 新增 `tools/semver.py`：semver 2.0.0 比较的参考实现
- **版本闸门落地**：`spec/gate-vectors.json`（76 条向量：41 compare + 35 check，含 15 版本升序链）
  + 三份实现（`tools/semver.py` / `lib/semver-gate.sh` POSIX / `lib/semver-gate.mjs` Node）
  + `tools/check-gate.py` 三实现对照。三个变异测试（写反 sh 的数字段规则、写反 node 的 final 规则、放行前导零）均被抓到
- `tools/verify-gate-device.sh`：单文件、自包含的真机自检（由 `tools/build-device-selftest.py` 生成，
  内联实现正文 + 76 条向量，可容忍 CRLF）
- **真机闭环（2026-10-17，mksh R59 / PJD110 / Android 16 → `RESULT ok 76/76`）**：
  首轮曝出方言坑 —— mksh 里 `${s%%|*}` 返回空串（dash/bash 正常），向量行全部解析失败；
  改成 `IFS='|'; set -- $x` 后三端 76/76。坑记为 [pitfalls A20](docs/pitfalls.md)，
  `tools/check-gate.py` 自动纳入 mksh，CI 也装 mksh 跑一遍
- **命门在真 chroot 上闭环（2026-10-18）**：chroot-distro 2.1.0 + ubuntu noble 24.04（arm64）里 `pty.spawn` 拿到 `/dev/pts/0`，
  `/dev/ptmx` 为独立字符设备（5,2 · 666）→ `node-pty` 的直接前提成立。记于 [research §9.1.1](docs/research.md)
- **壳的第一块（service.sh）**：唯一执行者骨架 —— 动词 `boot/start/stop/restart/status/bootstrap/install/logs`，
  退出码 `0/10/20/30/40`；六条契约各自可测：非交互（stdin 钉 `/dev/null`）· 环境钉死 · 幂等 ·
  先停后换（切层前停实例）· 默认离线（`--offline`）· 机器可读标记 `DSH_SERVICE_*`。
  `tools/test-service.sh` 25 条断言在 dash 与 mksh 双端全绿；bootstrap 状态机按 ADR-024 实现（staging + 原子切指针）
- **壳的第二块（dsh-ctl）**：唯一公开入口 —— 环境归一化 · 动词白名单（未知/未实现都明确报 2）·
  cgroup 搬家（best-effort，四类 v1 控制器 + v2，**搬不动如实报**）· 审计日志 `log/ctl.log` · 原样 `exec` service.sh。
  `tools/test-dsh-ctl.sh` 11 条断言全绿；在真机上跑可顺带验证 cgroup 搬家（ADR-019 的验收点）
- **payload 规范与打包器**：[docs/payload.md](docs/payload.md) 定两件套（`payload-<baked>.tar.gz` + `payload.json`）、
  归档布局（`rootfs/` 可选 · `node/` · `dsh/` · `bin/`）、schema-1 字段、四道校验链；
  `tools/build-payload.py` 做**确定性**构建（排序 / uid=0 / 固定 mtime / gzip mtime=0）+ `--verify` + `--selftest`（确定性 + 篡改检测）
- **裁决落地：payload 两层 + curl 修正（2026-10-18 审计）**
  - `service.sh` 改为两层：`base/node/`（换 DSH 时**复用**）+ `base/dsh-<baked>/`（切换）；`active` 只指向 DSH 层；
    inbox 只保留下一份同类产物；契约测试 32 条（含"换版本时 Node 层复用"与退出码 0/10/20/30/40）
  - `tools/build-payload.py` 改为 `--kind node|dsh` 分两层构建（各自确定性 + 校验 + 自测）
  - **ADR-013 / ADR-024 修正**：设备有 `curl 8.21.0`（HTTP2/HTTP3、OpenSSL），`/system/bin/wget` 反而不存在 → 下载器首选 curl
  - ADR-019 补实测限定：KSU 的 `su -c` 起手就在 `/apps`，搬家只对 App 内启动有意义
  - threat-model §6.2 修正：chroot-distro 的 `android-bind` 默认 enable，`/sdcard` 暴露面会自己回来（不是"默认没有"）
  - research §9.1 devpts 措辞修正（宿主 vs 容器是两回事）；设备模块数 9 → 10
- 设计文档：ADR-001 ~ ADR-025 全部拍板；威胁模型含「不设防声明」
- **ADR-024（payload 交付形态与首启自举）**：模块 zip 永不装 payload（只装 < 1 MB 的引导器）；
  首启由壳触发/执行/监督：离线 inbox 优先 → 否则 busybox wget 下载 → 校验 → staging 解压 → 原子切指针；
  修订 ADR-013 的"离线"条款；三条硬约束（无 curl / 解压前查空间 / 纯 POSIX sh）
- **版本号分层（ADR-025，2026-10-18）**：第 4 位改成**烘焙台账序号**，对着 `baked` 而不是 `floor`
  - 新增 [baseline/bake-ledger.json](baseline/bake-ledger.json)（只追加：`seq` ↔ `baked`，第 4 位与 `manifest.baked` 的唯一来源）
    与 [baseline/dsh.env](baseline/dsh.env)（`floor` / `recommended` / `node_floor`）
  - `tools/version.env` 删除 `V_DSH` / `DSH_BAKED`；残留会被生成器 exit 2 拒绝（迁移不许静默忽略）
  - 生成器从台账派生第 4 位与 `baked`，新增校验：`seq` 连续、semver 合法；回滚 / 重复只告警
  - 新增 [tools/test-versioning.py](tools/test-versioning.py)（20 条断言，含"故意写坏必须拒绝"）并接进 CI
  - 明文规则：`version` **永不参与比较**；模块更新只认整数 `versionCode`
  - 文档同步：versioning §2/§5/§10-§12、ADR-010 修订注记、baseline §4/§7、payload §3/§6、pitfalls A21
- **版本闸门接线（ADR-026，2026-10-18）**：`service.sh start` 之前先跑 `decide`，闸门从"库"变成"门"
  - `spec/gate-vectors.json` 新增第三类 **19 条 decide 向量**；py / sh / node 各加 `decide`，5 个运行体 **95/95 一致**
  - `decide` 是纯函数：只回 `verdict reason safe_mode`；回落 / 退出码 / 日志留在壳
  - `service.sh`：低于 `floor` 先**原子回落 baked**；回不来才 **exit 50**（与 30 区分）；alpha 只标记安全模式
  - `status` 新增 `manifest` / `version` 两行（只读，不改退出码）
  - 壳契约测试 32 → **43 条**（dash / mksh 双端）：回落、50、invalid-installed、alpha、缺 manifest、无测试缝变量
  - **顺带修掉一个真机必炸的旧 bug**：入口脚本把 `${DSH_PATH_OVERRIDE:-}` 写成了字面量 `@@{DSH_PATH_OVERRIDE:-}`，
    在设备上（没有该测试变量）`set -u` 直接报 `parameter not set`；测试因为总是导出它而全绿。记入 [pitfalls A22](docs/pitfalls.md)
  - 变异证据：把 alpha 的 `safe_mode` 改成 0 → `FAIL 94/95`；真机自检脚本扩到 95 条（**真机 95/95 待重跑**）
- **模块打包（引导器包，2026-10-18）**：`tools/build-module.py` + [docs/module.md](docs/module.md)
  - 包内 10 条目：`module.prop` / `manifest.json` / 开机钩子 / `customize.sh` / `uninstall.sh` / `META-INF` / `bin/{service.sh,dsh-ctl}` / `lib/semver-gate.sh`
  - **16,801 字节**（解压 40,678），远低于 ADR-024 的 1 MB 上限；payload 仍不进 zip
  - 确定性 zip（排序 / 固定 mtime / 固定权限）→ 同输入同 sha256
  - `--selftest` 20 条断言：布局 / 权限 / 无 `@@{...}` 残留 / **包根无 `install.sh`** / **安装模拟**（customize.sh → DSH_ROOT）/ 安装后 status / **拒绝降级** / 两次构建字节相同
  - 安装期逻辑全在 `customize.sh`：拒绝降级（ADR-018）+ 落壳 + 只建空目录（ADR-017 红线）+ 补开机钩子可执行位
  - **首装失败已定位**：包根放过一个 `install.sh` → ReSukiSU/KernelSU 判成 legacy 模块，只解压 4 个路径，
    staging 目录因此全是空的。已删掉该文件并加两道校验，记入 [pitfalls A23](docs/pitfalls.md)
  - 卸载钩子第一版**只停服务 + 打印残留、不删数据**（ADR-017 决定 C 第 4 条：时机未确认前不删）

> 尚无 Release。开发包可用 `python3 tools/gen-version.py && python3 tools/build-module.py` 生成（发布模式；`build/` 不进仓库）。

