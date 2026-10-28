# DSH 容器化替代 DSHA —— 项目指引

> 状态：**设计已定稿，实施已开工**（2026-10-17：模块身份定稿 + 产物生成器收口 + 首次提交；2026-10-18：版本号分层（ADR-025）+ 版本闸门接线（ADR-026）；2026-10-19：**payload 首烘**（Node 24.21.0 + pnpm 11.28.5 + DSH 0.2.0-rc.2）+ **vendor 基准线**（ADR-027）+ 模块 **1.0.2.1**；2026-10-28：**P1 协议闭环**（ADR-028）+ 基线抬到 **0.2.1-rc.4**（台账 `seq=2`，floor 同值）+ 模块 **1.0.2.2**；晚间：**P2 容器启动闭环**（ADR-029）+ 模块 **1.0.3.2**）。
> 阶段二（自定义内核 / Droidspaces）已按你的决定裁掉，仅在 `docs/pitfalls.md` 里留作"进阶与触发条件"。
> 本文档集是给"未来的你"看的：过一段时间回来，只读本文件就能恢复全部上下文。

---

## 0. 下次从这里继续（30 秒恢复上下文）

**现在到哪一步了**：

| 项 | 状态 |
|---|---|
| 设计决策 **ADR-001 ~ ADR-029** | ✅ 全部拍板（[docs/decisions.md](./decisions.md)） |
| **模块身份**（id / name / 仓库 / 版本真源） | ✅ 定稿（2026-10-17）：id `Zodiac-Quill-Saga` · name `DSH Chroot` · 仓库 `DSH-Chroot`；版本真源拆三份（2026-10-18 → ADR-025）：`tools/version.env` / `baseline/dsh.env` / `baseline/bake-ledger.json`（命名分工见 [versioning §8](./versioning.md)） |
| 设备侧证据（root 形态 / 系统版本 / 固件包） | ✅ 齐了（见 §4、[docs/recovery.md](./recovery.md) §9） |
| **设备 shell 通道** | ✅ **已连接**（2026-10-16，经 root：`uid=0` + SELinux `u:r:ksu:s0`）；只读核查已跑完 → §5 |
| **命门：容器内 PTY** | ✅ **完全闭环**（2026-10-18）：proot 实测（§9.1）+ **真 chroot 复验**（§9.1.1，chroot-distro 2.1.0 + ubuntu noble，`/dev/pts/0`） |
| **壳骨架**（service.sh + dsh-ctl） | ✅ 2026-10-18：六条契约 + 退出码 + 两层 bootstrap（Node 层复用）· 契约测试 43 + 11 条，dash/mksh 双端与 CI 全绿 |
| **版本闸门（三实现 + 真机）** | ✅ **真机闭环**（2026-10-17）：mksh R59 · PJD110 / Android 16 · `RESULT ok 76/76`；Python / POSIX sh / Node 三实现同一张表（[versioning §9](./versioning.md)） |
| **版本号分层（ADR-025）** | ✅ 2026-10-18：第 4 位 = 烘焙台账 `seq`（对着 `baked`，不对着 `floor`）· 三份真源各管一件事 · [tools/test-versioning.py](../tools/test-versioning.py) 20 条断言（含拒绝类） |
| **版本闸门接线（ADR-026）** | ✅ 2026-10-18：`decide` 纯函数（19 条向量 · 5 实现 95/95）· `service.sh start` 前判定 · 低于 floor **回落 baked** · 新退出码 **50** · 壳契约 43 条（dash/mksh） |
| **模块打包（引导器包）** | ✅ 2026-10-18：`tools/build-module.py` · 确定性 + 安装模拟 **22/22**（[docs/module.md](./module.md)）· 首装失败已定位并修（A23：包根 `install.sh` 被判 legacy）。2026-10-19：13 条目，内置 `bin/chroot-distro`（GPLv3）+ 随包许可证 |
| **vendor 基准线（ADR-027）** | ✅ 2026-10-19：chroot-distro 脚本原样 + GPLv3；DSH tarball + 616 包 shrinkwrap + **68,198 项** `tree.sha256`（两次独立安装树哈希相同；2026-10-28 随 rc.4 整份重做）；`tools/vendor-check.py` 进 CI；仓库 MIT / 组件 GPLv3 双声明 |
| **payload（两层）** | ✅ 2026-10-19 首烘 / **2026-10-28 换 dsh 层**：`node-24.21.0.tar.gz` 60.4 MiB · `dsh-0.2.1-rc.4.tar.gz` 154.0 MiB（68,202 条目 / 63,045 文件 / sha256 `7c31ca6a…`）；两次独立安装树哈希相同；**真实归档离线自举 89 s → status ok (baked)**（[payload.md](./payload.md) §4） |
| **P1 载体（sdk profile）** | ✅ **协议闭环**（2026-10-28，[ADR-028](./decisions.md)）：`dsh --profile sdk` 走 **stdio JSON-RPC** · `initialize`→`serverInfo` 全往返 **1221 ms** · 设备探针 `verify-sdk-protocol.sh` + CI 契约 `test-sdk-protocol.sh` **20 条**（dash/mksh） |
| **P2 载体（web profile，真容器启动）** | ✅ **闭环**（2026-10-28，[ADR-029](./decisions.md)）：真 chroot + 两层 `bind(ro)` → `dsh web --port 0` → 启动行取端口/token → `run/dsh.json`(0600)；真机 `http=200` / 37,971 B / `<title>DeepSeek Harness</title>`，无 token → 401；停后挂载清零。设备探针 `verify-runtime.sh` **18 条** · 契约测试 **47 条**（dash）· 新退出码 **60** |
| 阻塞项 | **无** |

**下一步该做的**（按顺序）：

0. ~~版本真源 / 生成器 / 占位收口~~ ✅ **已完成（2026-10-17）**：payload 的层 `sha256` 也已是真值（2026-10-19），
   现在生成走 `python3 tools/gen-version.py`（**不带 `--draft`**）；`--draft` 只在真的还有占位时当逃生口。
1. ~~版本闸门：一张向量表 + 三份实现~~ ✅ **已完成（2026-10-17）**：[spec/gate-vectors.json](../spec/gate-vectors.json)（现 95 条向量）·
   Python / POSIX sh / Node 三实现逐条一致，`python3 tools/check-gate.py` 全绿；变异测试证明这道检查**会红**。
   真机自检脚本 [tools/verify-gate-device.sh](../tools/verify-gate-device.sh) 保留（真机 76/95 待按新版重跑）。
2. ~~壳骨架（service.sh + dsh-ctl）~~ ✅ **已完成（2026-10-18）**：六条契约 + 两层 bootstrap + 版本闸门接线；契约 43 + 11 条（dash/mksh）。
3. ~~模块打包（引导器 < 1 MB）~~ ✅ **已完成（2026-10-18）**：13 条目 · 安装模拟 22/22 · 当前 **1.0.2.2 / versionCode 4**（内置 chroot-distro，GPLv3 随包）。
4. ~~payload 首烘~~ ✅ **已完成（2026-10-19）**：Node **24.21.0** + pnpm **11.28.5** + DSH **0.2.0-rc.2**；
   两层 ≈177 MiB（解压 ≈741 MiB）；真实归档离线自举 **89 s**（26k 文件），`status` 报 `ok (baked)`。
5. ~~P1 载体：`dsh --profile sdk` 的 stdio JSON-RPC~~ ✅ **已完成（2026-10-28，ADR-028）**：`initialize`→`serverInfo`
   全往返 **1221 ms**（Ubuntu 24.04.3 chroot / Node 24.22.1 / dsh 0.2.1-rc.4）；设备探针
   [tools/verify-sdk-protocol.sh](../tools/verify-sdk-protocol.sh)（退出码 0/1/2）+ CI 契约
   [tools/test-sdk-protocol.sh](../tools/test-sdk-protocol.sh)（**20 条**，dash/mksh 各一遍，假 dsh 驱动，不联网不装真包）。
   ✅ 2026-10-28 **已进台账**：`seq=2` / `baked=0.2.1-rc.4`（floor 同值），Node 对齐 **24.21.0** 后复测 1252 ms 通过（[baseline §6](./baseline.md)）。
6. ~~`runtime_start` 的 real 分支（= P2，`web` 载体）~~ ✅ **已完成（2026-10-28，ADR-029）**：`base/node` 与 `base/dsh-<ver>`
   以 `bind(ro)` 进 `/opt/dsh/{node,current}` → chroot 起 `dsh web --port 0` → 从 **stdout 启动行**取端口/token →
   原子写 `run/dsh.json`（0600）。真机端到端：`http=200` / 37,971 B / `<title>DeepSeek Harness</title>`，无 token → 401。
   三个坑写进 ADR-029：容器 `/dev` 是空的（`/dev/null` 竟是普通文件）、toybox 的只读 bind **静默失败**、`curl` 必须带超时。
7. 真机复验（需要你操作 Root 管理器 / 终端）：装 **1.0.3.2** → 投递 `payload-1.0.3.2` → `bootstrap --offline` →
   `status` 应显示 node/layer/version 全 ok → `start` 应真的起来（`port` 那一行有值）；
   只想验运行时而不动真数据，跑 `sh tools/verify-runtime.sh <rootfs> <node层> <dsh层>`（18 条断言）。

**一句话记住三条硬约束**：① 只做 `local` + `lan`，公网不碰；② 与 DSHA **并存但绝不共用 `DSH_HOME`**；③ 固件只抽**内核侧四件套**，永不整包刷、永不恢复 `data`。

---

## 1. 一句话目标

**用 root 模块 + chroot 容器，把 DSHA 那套"应用壳里的虚拟电脑"整个搬出来**：
Ubuntu 24.04 容器里烘焙好 Node + pnpm + 一个 DSH 基线版本，外面套一层"壳"负责
**版本闸门 + 生命周期 + 端口发现 + 受控的局域网访问 + 文件通道**。

核心设计原则：**只依赖窄接口，让下面的每一层都可替换。**
DSH 换版本、容器运行时换实现、甚至内核被 OTA 覆盖回退 —— 壳都不用重写。

---

## 2. 阅读顺序

| 顺序 | 文件 | 内容 |
|---|---|---|
| 1 | [README.md](../README.md) | **对外首页**：它是什么 / 不是什么 / 有什么要求 / 怎么装 |
| 2 | [docs/guide.md](./guide.md) | **本文件**：内部项目指引 —— 进度、决定速查、待办（给"未来的你"） |
| 3 | [docs/research.md](./research.md) | **研究文档**：目标、现状盘点、路线比较、架构、版本策略、端口/通信、缺口、未验证项 |
| 4 | [docs/baseline.md](./baseline.md) | **基线**：Ubuntu 24.04 + Node 24 + **pnpm 11.x** + DSH 基线，含 libc 依赖审计与 manifest 规范 |
| 5 | [docs/projects.md](./projects.md) | **涉及项目清单**：用/不用/备选，各自的角色与风险 |
| 6 | [docs/pitfalls.md](./pitfalls.md) | **反例集**：会绕远路的做法（23 条）+ 值得进阶的方向（10 条） |
| 7 | [docs/decisions.md](./decisions.md) | **决策记录（ADR）**：已拍板的事 + 代价 + 重审触发 |
| 8 | [docs/threat-model.md](./threat-model.md) | **威胁模型（归拢）**：资产 / 对手 / 六条边界 / 威胁↔ADR 对账 / **不设防声明** / 开着的口子 |
| 9 | [docs/recovery.md](./recovery.md) | **刷机前的证据与回滚预案**（ARB 警告 / 包形态 / 抽分区 / 决策树） |
| 10 | [docs/versioning.md](./versioning.md) | **版本号与 module.prop 规范**（四位 version / versionCode / managedFeatures 真实语义 / 单一真源 / 命名分工） |
| 11 | [docs/payload.md](./payload.md) | **payload 规范**：两层 / 四个文件 / 字段 / 确定性构建 / 五道校验链 |
| 12 | [docs/module.md](./module.md) | **模块包规范**：包内布局 / 安装与开机路径 / 卸载策略 / 构建与自测 |
| 13 | [baseline/manifest.example.json](../baseline/manifest.example.json) · [baseline/module.prop.example](../baseline/module.prop.example) | 闸门 manifest 模板、module.prop 生成结果、模块包钩子模板 |

---

## 3. 决策地图（**是 26 条独立决策，不是排列组合**）

```
整个方案 = 26 条互不相关的决策，每条单独选（⑧a 是 ⑧ 的附属）

L0 内核     ① 阶段一不碰内核（原厂 6.1.141 + LKM）........ ✅ ADR-001
L1 运行时   ② 容器用 chroot-distro 模块 ................. ✅ ADR-001
            ③ 发行版 Ubuntu 24.04 (glibc) .............. ✅ ADR-002
L2 DSH      ④ 版本策略 floor-only ..................... ✅ ADR-003
            ㉒ 内置基线只追 RC 通道，alpha 不碰 ......... ✅ ADR-022（候选集=rc；floor 只会是 RC；用户自装 alpha 仍允许，只显示偏离）
            ㉓ 用户手动抬升：0 插件更新 · RC 优先 · alpha 强制安全模式 ✅ ADR-023（换 dsh 本体=连带换整棵全局树；提醒三时刻；AI 适配有无插件通道）
            ⑱ 拒绝降级（模块版本单调；降级只能卸载后重装） ✅ ADR-018（install.sh 拒绝；无强制开关；配套 ADR-010/017）
            ⑤ 与 DSHA 并存（严格分离 DSH_HOME）......... ✅ ADR-004
L3 壳       ⑥ 壳不做 Hook；能力做成可插拔插件 ........... ✅ ADR-005
            ⑦ 访问只做 local + lan，不引入 overlay ..... ✅ ADR-006
            ⑧ 文件通道：多提供者，默认 rclone(WebDAV) ✅ ADR-007
                ⑧a 共享目录：先只给沙箱 ................ ✅ ADR-007（要 /sdcard 子目录需显式 bind）
            ⑨ 能力插件：只写"约定"不写管理器 ......... ✅ ADR-008（DSH 侧交给它自带的机制）
            ⑳ 核心插件：独立发布 / 内部钉死（内外分层） ✅ ADR-020（钉四样；origin 标识；收口清单是必需品）
            ⑯ 挂载布局 + MT 管理器接入（fix-owner 随运行时） ✅ ADR-016（root≠root；两段式公开面；inbox 投递）
            ⑲ 公开入口 dsh-ctl + 进程归属（cgroup 搬家在最外层） ✅ ADR-019（三层结构；四条验收判据；入口须避开 bind 子树）
            ⑩ 版本号与 module.prop 规范 .............. ✅ ADR-010（四位 version；单一真源）
            ㉕ 第 4 位 = 烘焙台账序号，对着 baked ...... ✅ ADR-025（台账只追加；floor 不进版本号；version 永不参与比较）
            ㉖ 启动前跑版本闸门：decide + 壳处置 ...... ✅ ADR-026（低于 floor 回落 baked；alpha 只标记安全模式；exit 50）
L4 信任     ⑪ 内置 Node/pnpm；AI 写插件的约束落在 DSH 之外  ✅ ADR-011（四层约束 + 试衣间/人闸门；approval 是"声明式"的）
            ⑫ 保留上游在线面 + 壳自己做带外面（DSH 死了也能关插件） ✅ ADR-012（在线面=ui-plugin-manager；带外=改 patch / dsh plugin / 重建；共用一份真相；L3=换指针+恢复四份文件）
            ⑬ 重建入口 = service.sh（四入口同一份代码）+ dsh-ctl 多动词 ✅ ADR-013（纯 POSIX sh；⛔ 禁 zstd；显式 chown/chcon）
            ㉑ 凭据分层 + AI 降权（token 出容器；出网只保判据） ✅ ADR-021（0600 靠降权才生效；virtual screen 与 device shell 共用 bridge token）
L5 可观测   ⑭ 四类日志分开；壳是唯一落盘点；两条反馈面 ✅ ADR-014（⛔ 凭证不进日志；诊断包白名单打包；遥测默认保持）
            ⑮ 只走模块仓库发布；不推送上游更新 ✅ ADR-015（模块更新发；基线抬升随模块；自动升级不做；status 显示基线偏离；手机端 UI = 内置第三方插件 dsh-web-mobile v3.0.5）
L6 分发     ⑰ 卸载钩子 = uninstall.sh（七处残留面） ✅ ADR-017（卸载即清空模块域、用户空间永久保留；更新走 update 标记不经 uninstall；先停后卸）
            ㉔ payload 交付：zip 永不装 payload，壳负责首启自举 ✅ ADR-024（离线优先 · curl 下载 · staging+原子切指针 · 修订 ADR-013 的"离线"条款）
```

> ⚠️ 常见误解：以为上面的选项会两两组合出"很多套方案"。**不会** —— 每条轴独立选。
> **截至 ADR-026，设计层全部拍板，没有待定项**（ADR-001 ~ ADR-026）。

### 3.1 文件通道这条轴的真实结构（为什么说它不是"二选一"）

| 物种 | 是什么 | 内部可选协议 |
|---|---|---|
| **A. rclone** | 一个二进制提供"文件服务" | `serve webdav` / `sftp` / `ftp` / `http` / `nfs` / `dlna` —— **换协议只是换启动参数**【已验证】 |
| **B. Syncthing** | 不是文件服务，是**双向同步** | 只有它自己（P2P，两端都装，目录自动一致） |

→ 真正的选择只有一个：**按需访问（A）还是自动同步（B）**。
→ 选 A 之后，"WebDAV 还是 SFTP"是**随时可换的参数**，不是要现在拍板的分叉。

---

## 3.2 关键决定速查（为什么是这些）

| 决定 | 结论 | 一句话理由 | 详见 |
|---|---|---|---|
| 容器运行时 | **chroot-distro 模块** | 唯一"现在就能用原厂内核 + LKM 跑起来"的容器模块；不碰内核 | research §3 |
| 发行版 | **Ubuntu 24.04 (glibc)** | `node-pty` **只有 glibc 预编译**，`cua-driver` **没有 musl 包**；且这是 DSHA 已验证的组合 | baseline §2 |
| Node | **24.21.0（烘焙值）** | 官方 linux-arm64 二进制即 glibc，可完全 pin；24.x 同一 major 内 ABI 不变 | baseline §1 |
| 包管理器 | **pnpm 11.28.5，随模块内置**（构建期打包、安装期解压） | DSH 运行时真的在用 pnpm；**不内置就装不了插件**；且单文件 exe 不能当 node 跑 pnpm | baseline §1、ADR-011 |
| AI 写插件 | **四层约束；批准在容器外**（试衣间不落盘 + 人闸门） | 上游的 approval / `node:vm` 沙箱 / 插件管理器**都不构成安全边界**，且审批是"声明式"的 | ADR-011 |
| DSH 基线 | **0.2.0-rc.2** | 当前 DSHA 内跑的就是它（`APP_VERSION=…-dsh0.2.0-rc.2`） | baseline §1 |
| 内置基线的通道 | **只追 RC，alpha 不碰** | rc = 上游宣告的候选发布，alpha = 它的开发线；`floor` 不可降，把 alpha 钉进去就回不了头 | ADR-022 |
| **用户手动抬升 DSH** | **推荐 0 个内置插件更新；只推荐 RC；alpha 允许但强制禁用全部第三方插件（含内置）＝安全模式** | 换 dsh 本体 ＝ 连带换掉整棵全局树（303 包，62 个 `dsh-client-*` 全锚在 `0.2.0-rc.2`），而插件的 peer 包**只来自这棵树** → "插件没更新"**不等于**"仍适配" | ADR-023 |
| 版本策略 | **只设下限（floor-only），不设上限** | 允许自由升级、禁止低于地板；降 floor 只能刷模块 | research §5 |
| 端口 | **让 DSH 自己 `--port 0`** | 原生支持 OS 分配端口，避免"猜端口"的 TOCTOU 竞态 | research §6 |
| 跨设备访问 | **默认只本机；局域网要显式开 + token；公网档已裁**（ADR-006） | 管理面永不暴露；用 LAN IP 访问时 DSH 会**自动**把 LAN 地址加入信任栅栏，只有**用域名**访问才需要 `--trusted-host` | research §6 |
| 阶段二 | **裁掉** | DSH 自身还在 0.2.x，不值得为它动内核 | pitfalls §B1 |

---

## 4. 现状盘点（决定性事实，全部已验证）

| 项 | 值 | 与方案的冲突点 |
|---|---|---|
| 设备 | 一加 12（PJD110）· Android 16 · 内核 `6.1.141-android14-11-o-g659d588fa0da` | 原厂内核 |
| Root | **ReSukiSU（已改名 BakaSU）LKM 模式**，驱动 v4.2.0-rc2 / 管理器 v4.2.0-rc3 | **已经拿到"内核模块加载 root"**，不需要再折腾 |
| SELinux / Seccomp | 强制 / 过滤模式 | 容器里跑东西要过这两关 |
| 元模块实现 | **Magic Mount-rs** | 那是**模块挂载**（/system 域）的实现，**与本项目的容器分层无关**；容器分层走 bind(ro) + 指针，**不依赖内核 overlayfs**（ADR-009） |
| 空间 / 内存 | 可用 582.94 GB / 22.62 GB 总内存 | 体积不是约束（所以"Alpine 更小"的卖点无效） |
| DSHA | `com.dsh.client` / `com.dsh.clienu`，桥协议 3，APP_CODE 170 | **要被替代的对象**；但它的设备桥能力不能白丢（见 research §8） |
| DSH 本体 | `@deepseek-ai/dsh@0.2.0-rc.2`，干净安装树 **513 MB**（DSHA 内那棵 439 MB 被裁剪过） | **绝不能塞进模块 zip** |
| 设备 shell 通道 | ✅ **已连接**（2026-10-16），经 root：`uid=0` + SELinux `u:r:ksu:s0`；`/data/adb` 可读 | 单条命令白名单：禁脚本 / 管道 / 重定向 / 变量 / 嵌套；`sh`、`app_process`（非受管）被拦 |
| 系统版本串（只读） | `PJD110_16.0.10.501(CN01)`；OTA `PJD110_11.F.57_2570_202608111410`（构建 2026-08-11）；`ro.product.device=OP5929L1` | 与手上全量包同版本 → 回滚套件有效，设备一旦 OTA 更高版本即过期 |
| 启动状态（只读） | `ro.boot.flash.locked=1` · `verifiedbootstate=green` · `veritymode=enforcing` | 抽分区 / 刷写前必须结合 ARB 再评估（见 recovery） |
| DSH 沙箱（本机实测） | `DSH_PERMISSION_MODE=danger-full-access`（`dsh-base/cordis.patch.yml:232,248` 用同一个变量同时决定沙箱 mode 与 approval）→ 沙箱短路 + 审批设成 `never`；`landlock-run --probe` **rc=125**、`bwrap` **未安装** → **受限模式是 fail-closed**（bash 直接不可用，不是变受限） | 容器方案若要真沙箱，必须自带 `bwrap` 或换有 Landlock 的内核；且 DSH 的三个 mode **都不管网络与进程可见性**，读取路径也不受其文件边界保护 |
| 已装模块（10 个，实读；2026-10-18 起含 **`chroot-distro`**） | `WorkSettingPro` `chroot-distro` `hma_oss_zygisk` **`magic_mount_rs`**（元模块）`playintegrityfix` `rezygisk` `treat_wheel` `tricky_store` `ufi-manager` `zygisk_lsposed` | 换 / 升级模块时的冲突面已可见 |

---

## 5. 待办 / 开放问题（回来先看这里）

**已定的**（详见 [docs/decisions.md](./decisions.md)）
- [x] ADR-001 阶段一不碰内核 · ADR-002 Ubuntu 24.04 · ADR-003 floor-only · **ADR-004 先并存** · **ADR-005 壳不做 Hook，能力做成插件，虚拟屏初期不实现**

**还必须回答的**
- [x] ~~容器里让 DSH 当**唯一实例**，还是与宿主/DSHA 那套**并存**？~~ → **已定：先并存**（ADR-004）
      （= **要不要保留 DSHA 的设备桥**。多实例并存技术上 DSH 原生支持：`DSH_HOME` + `--profile` + `--port 0` + 会话级锁；
      **红线是不要共用同一个 `DSH_HOME`**。详见 [research §11](./research.md)）
- [x] ~~平板访问：**只局域网**，还是也要外网（决定要不要引入 Tailscale）？~~ → **已定：只做 `lan` 档，不引入任何 overlay**（ADR-006）
      （判断依据：不会在"不在同一 Wi-Fi"的地方用平板连手机。`public` 档位留空并写明触发条件）
- [x] ~~文件通道：**WebDAV（rclone）** 还是 **SFTP / Syncthing**？~~ → **已定：写成"多提供者列表"，默认 rclone + WebDAV；Syncthing 可后加**（ADR-007）

**动手前要留的证据（~~需要先连上设备 shell 通道~~ → 2026-10-16 通道已通，只读核查已跑完）**
- [x] ~~列 `/data/adb/modules` 那 9 个模块是什么~~ → **已列出**：`WorkSettingPro` · `hma_oss_zygisk` · **`magic_mount_rs`**（元模块）· `playintegrityfix` · `rezygisk` · `treat_wheel` · `tricky_store` · `ufi-manager` · `zygisk_lsposed`
- [x] ~~找 LKM 的 `kernelsu.ko` 位置 + `modinfo` 的 vermagic~~ → **该收集项直接作废（2026-10-16）。**
      唯一留下有用的事实是**形态**：`/proc/modules` 里有 `kernelsu 249856 5 - Live`（**LKM 确认生效**）；`/data/adb` 内无任何 `.ko`（`find` 为空，`ksu/lib` 只有 `libadbroot.so`）→ 它**随 boot / init_boot 镜像走**，不在用户数据区。
      为什么作废：① 阶段一不碰内核，chroot + bind 方案对内核 ABI 零依赖，OTA 打掉 LKM 也不影响 → [research §9](./research.md) #6「天然免疫」；
      ② 真失配时的正确动作是等 / 装 ReSukiSU 对新内核的 LKM —— vermagic 只能告诉你"不匹配"，**不能帮你修**；
      ③ 它只存在于 `.ko` 文件里（`modinfo`），**运行中的模块不暴露**（`/proc/modules` 无此字段，连 `/sys/module/kernelsu` 都不存在）；
      ④ 唯一会用到它的**阶段二已裁**（[pitfalls B1](./pitfalls.md) 仅作"进阶与触发条件"留档，其三条触发条件一条都不成立）
      → **结论：没有任何在排期内的阶段需要 vermagic，删掉即可。**
- [x] ~~核对设备当前版本是否 ≥ 手上的全量包~~ → **设备 = PJD110_16.0.10.501(CN01) = 包版本（同版本）→ 内核回滚套件就绪**；注意设备一旦 OTA 更高版本，旧包即过期
- [x] ~~确认有没有 boot 分区备份~~ → **已有官方全量包 PJD110_16.0.10.501(CN01)**（构建 2026-08-11，已提取 raw img）。用法**限定为"只抽内核侧四件套（boot / init_boot / vbmeta / dtbo）"**，且**必须核对设备当前版本 ≥ 它**（ARB 只增不减、熔断是硬件级）→ 见 [docs/recovery.md](./recovery.md) §9-§11
- [ ] （已不需要）确认内核是否支持 overlayfs —— 容器分层已改为 bind(ro) + 指针（ADR-009）

**待验证的设计假设**
- [x] ~~`dsh web --port 0` 选中的端口从哪里读（stdout？）~~ → **✅ 已实测闭环（2026-10-16，本容器）**：端口就打在启动行里、走 **stdout** —— `dsh web: http://127.0.0.1:39895/?token=…`；DSH_HOME 下**不落端口文件**。**与 chroot 无关**（是 DSH 自身行为），详见 [research §6.2](./research.md)。注意该 URL 自带 token，属凭证
- [x] ~~chroot 容器里 `node-pty` 能否正常起 PTY（这是整条路线的命门）~~ → **✅ 已实测通过**（2026-10，本容器；node-pty 与 python pty 双通道均拿到 `/dev/pts/0`）。注意本容器是 proot/bxroot，**到真正的 chroot 里用 [tools/verify-pty.sh](../tools/verify-pty.sh) 复验一次即闭环** → 见 [research §9.1](./research.md)
- [ ] `rclone serve webdav` 在容器里的权限/性能
- [~] root CLI 替代设备桥的覆盖度 —— **已开跑（2026-10-16）**：`pm list packages` · `dumpsys package` · `ls` · `cat` · `grep` · `find` · `cp`（→ `/sdcard`）· `am force-stop`（策略内建）均可用；`sh` / `app_process`（非受管）被策略拦截。**尚未实测**：`uiautomator dump` / `input` / `screencap` / `cmd notification`

---

## 6. 目录说明

```
DSH-Chroot/                         # 仓库名；模块 id 是 Zodiac-Quill-Saga（见 docs/versioning.md §8）
├── README.md                       # 对外首页：它是什么 / 不是什么 / 怎么装
├── service.sh                      # ★ 壳的唯一执行者（ADR-013）：契约 + 退出码 + 自举入口 + 版本闸门接线（ADR-026）
├── dsh-ctl                         # ★ 唯一公开入口（ADR-019）：归一化 + 参数校验 + cgroup 搬家 + 审计
├── LICENSE                         # MIT
├── CHANGELOG.md                    # 发版记录（update.json 的 changelog 指向它）
├── update.json                     # Root 管理器检查更新用（与 version.env 同步，生成器会校验）
├── .gitignore                      # 忽略 build/、__pycache__/
├── docs/
│   ├── guide.md                    # ★ 内部项目指引（本文件）：进度 / 决定速查 / 待办
│   ├── research.md                 # 研究文档（目标 / 盘点 / 架构 / 策略 / 未验证项）
│   ├── baseline.md                 # 基线定义 + libc 依赖审计 + manifest 规范
│   ├── projects.md                 # 涉及项目清单（用 / 不用 / 备选）
│   ├── pitfalls.md                 # 反例集：弯路 23 条 + 进阶 10 条（A20 mksh 方言；A21 semver 编码；A22 占位符；A23 install.sh legacy）
│   ├── decisions.md                # 决策记录 ADR-001 ~ ADR-026
│   ├── threat-model.md             # 威胁模型（资产/对手/边界/对账/不设防声明）
│   ├── recovery.md                 # 刷机前证据与回滚预案（ARB / 增量包 / 抽分区）
│   ├── versioning.md               # 版本号与 module.prop 规范
│   ├── payload.md                  # payload 规范（ADR-024 的实现面）
│   └── module.md                   # 模块包规范（布局 / 安装 / 开机 / 卸载 / 构建）
├── spec/
│   └── gate-vectors.json           # ★ 版本闸门的唯一规格（三份实现都对着它跑）
├── lib/
│   ├── semver-gate.sh              # 闸门的 POSIX sh 实现（设备侧 / 容器内）
│   └── semver-gate.mjs             # 闸门的 Node 实现（容器内 / 壳）
├── baseline/
│   ├── dsh.env                     # ★ DSH 基线参数（floor / recommended / node_floor）
│   ├── bake-ledger.json            # ★ 烘焙台账（只追加）：seq <-> baked；第 4 位与 manifest.baked 的唯一来源
│   ├── manifest.example.json       # 版本闸门 manifest 模板（生成器的输入）
│   ├── module.prop.example         # module.prop 生成后的样子
│   └── module/                     # 模块包内的安装 / 开机 / 卸载钩子（模板）
└── tools/
    ├── version.env                 # ★ 模块身份 + version 前三位 + versionCode（不写 DSH 版本）
    ├── gen-version.py              # 由三个真源生成 module.prop / manifest.json / APK 版本字段（fail-closed）
    ├── test-versioning.py          # 版本真源契约测试（派生 / 拒绝类 / 回滚告警 / 漂移）
    ├── semver.py                   # 权威 semver 比较（Python 参考实现）
    ├── check-gate.py               # 三份实现 × 一张表：防漂移检查（CI 入口）
    ├── test-service.sh             # 壳的契约测试（幂等 / 环境钉死 / 先停后换 / 退出码）
    ├── test-dsh-ctl.sh             # 入口的契约测试（参数校验 / 审计 / 透传 / cgroup 如实报告）
    ├── build-payload.py            # payload 打包器（两层 · 确定性 tar.gz + 每层清单 + 校验 + 自测）
    ├── build-module.py             # 模块 zip 打包器（< 1 MB · 确定性 · 安装模拟自测）
    ├── verify-pty.sh               # 容器内 PTY 可用性验证（双通道）
    └── compare-firmware.py         # 两份固件包内核侧镜像比对
```

---

## 7. 边界声明

- 本环境**不允许**刷机、写 boot 分区、挂载、装模块。
  设备 shell 通道**已于 2026-10-16 打通**（经 root：`uid=0` + `u:r:ksu:s0`），命令形态受白名单限制
  （单条、禁管道 / 重定向 / 变量 / 嵌套），本次只跑了**只读核查**，未做设备侧写操作。
  因此本文档中所有"设备侧"结论来自 **GitHub 仓库代码/历史 + 本容器内的实测 + 只读设备核查**，
  凡未在真机验证的，都标了 **【待验证】** 或 **【推断】**。
- 标注约定：
  - **【已验证】** = 我在本容器里跑过命令 / 读过源码 / 查过 npm registry，有据可查
  - **【推断】** = 由已验证事实推导，逻辑通但没直接测
  - **【待验证】** = 必须真机跑一次才能定论
