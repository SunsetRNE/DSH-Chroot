# 决策记录（ADR）

> 只记"已经拍板"的事，每条写清**背景 / 决定 / 代价 / 何时重审**。
> 未拍板的悬而未决项在 [README §5](../README.md) 的待办里。

---

## ADR-001 阶段一不碰内核

- **背景**：DSH 自身还在 0.2.x-rc；自定义内核是最贵、最难回滚、最容易被 OTA 抹掉的一层。
- **决定**：阶段一在 **原厂 6.1.141 + ReSukiSU/BakaSU LKM** 上工作，容器用 **chroot-distro 模块**（纯用户态 chroot，不需要内核新特性）。
- **代价**：没有 netns / systemd / GPU 直通 —— 容器共享宿主网络与文件系统。
- **重审触发**：壳稳定运行 + 确实需要 systemd/NAT/GPU + 接受 OTA 后重刷（见 [pitfalls §B1](./pitfalls.md)）。

## ADR-002 发行版选 Ubuntu 24.04（glibc）

- **背景**：容器要烘焙 DSH；Alpine 基座小 30–70 MB。
- **决定**：**Ubuntu 24.04 LTS (noble) arm64**。
- **依据**（【已验证】）：`node-pty` 在 npm 上**只有 glibc 预编译**（tarball 内只有 `linux-arm64`/`linux-x64`）；`@trycua/cua-driver` 的 **musl 包 404**，且它是 optionalDependency → musl 上是**静默降级**。另外 DSHA 已验证的组合就是 Ubuntu 24.04。
- **代价**：基座大几十 MB（相对 439 MB 的 DSH 是噪声；设备可用 582 GB）。
- **重审触发**：上游为 musl 补齐全部原生预编译。

## ADR-003 版本策略：只设下限（floor-only）

- **背景**：DSH 0.2.x-rc 会漂移，用户又想自由升级。
- **决定**：`floor`（硬下限，低于它拒绝运行/安装）+ 无上限 + `baked` 基线随模块走；降 floor 只能刷模块。
- **代价**：root 容器里没有真正的不可变，floor 是护栏不是安全边界（要靠启动校验 + 偏离回落）。
- **重审触发**：上游发布稳定的版本兼容承诺（届时可放开降级）。

## ADR-004 先"并存"，不切唯一实例  ← **本次决定**

- **背景**：设备控制（读屏/点按/虚拟屏/通知/剪贴板）目前挂在 DSHA App 上；容器实例只有 root 命令行，替代它的覆盖度不全。
- **决定**：**DSHA 那套继续跑（管设备控制），容器实例管计算/文件/长期服务**；两者**严格分离状态**。
- **并存纪律（红线）**：
  1. **不要共用同一个 `DSH_HOME`**（尤其两边版本不同时：`rc1-migration.py` 之类的迁移脚本 + `plugin-*` 账本会互相踩）
  2. profile 名分开（`--profile container` vs 现有 `web`）
  3. 工作区目录分开
  4. 端口一律 `--port 0` + 由壳发布
  5. pnpm store 先分开
- **成本修正（重要）**：DSHA **不是我们在维护**，所以传统"并存 = 两套都要维护、会分叉"的代价**不成立**。
  并存的真实代价只剩：**资源占用（~1 GB/实例）+ 分离纪律 + 心理负担**。
- **重审触发**：容器那套能独立完成日常 90% 操作时，再迁移凭据/设置、冻结 DSHA 的 DSH、按 [pitfalls §B7](./pitfalls.md) 补设备桥。

## ADR-005 壳不做 Hook；能力做成可插拔插件；虚拟屏初期不实现  ← **本次决定**

- **背景**：想用"壳写成 Hook 模块"的方式解决虚拟屏等设备能力。
- **决定**：
  1. **壳（core）只负责通信与生命周期**：UDS/端口、adapter、版本闸门、supervisor、文件通道。**不写 Hook，不碰 framework。**
  2. 设备能力（虚拟屏 / 输入注入 / 截屏 …）走**能力插件**：DSH 侧的 `dsh-tool-*` 插件 + 宿主的**特权 root helper**，通过端口/HTTP 对接。**初期只留接口，不实现逻辑。**
  3. **Hook（Zygisk / LSPosed / 内核 hook）只在"必须改别的进程内行为"时才考虑**——虚拟屏不属于这一类（见下）。
- **依据**（【已验证】，来自 DSHA 源码）：
  - 虚拟屏的实现链是 **特权 shell 创建 display**（`VirtualScreenPolicy` 注释明确讨论 `VIRTUAL_DISPLAY_FLAG_TRUSTED` / `ADD_TRUSTED_DISPLAY`，且 `uid == 0` 即可请求 TRUSTED）+ **App 侧 Activity/预览** + **输入注入与无障碍**。
  - 同一注释还记录了：Android 12 上 **shell（ADB/Shizuku）未持有 `ADD_TRUSTED_DISPLAY`，请求会抛 SecurityException，导致 ADB 通道恒失败（issue #123）**。
    → 也就是说 **root（uid 0）在这件事上比 ADB/Shizuku 通道更强**，根本不需要 hook。
  - DSH 侧那一半本来就是**插件**：`app/src/main/assets/builtin-plugins/dsh-tool-vscreen/`（`lib/index.js` + `lib/server.cjs`）。
- **代价**：初期没有虚拟屏；能力插件的接口如果设计不当，后期可能要改壳。
- **重审触发**：确实遇到"root CLI 做不到、必须进别的进程改行为"的具体场景，再单独评估 hook 方案。

## ADR-006 访问只做局域网档，不引入 overlay  ← **本次决定**

- **背景**：设计里有 `local` / `lan` / `public` 三档访问。是否需要第三档，取决于"会不会在不同网络下用平板连这台手机"。
- **决定**：**只实现 `local`（默认）与 `lan`（按 Wi-Fi 门控 + token）**；`public` **留空，不引入 Tailscale / ZeroTier / WireGuard / Cloudflare Tunnel 等任何组件**。
- **依据**：使用者明确答复"**不会**在不同网络下访问"。
- **代价**：无（省掉一整套依赖与攻击面）。
- **实现约束**：
  - `lan` 档 = 壳反代监听 `0.0.0.0`，DSH 本体保持 `127.0.0.1`；按 Wi-Fi SSID/网段门控开关
  - **仍然禁止** DDNS + 端口映射那类公网暴露（`public` 档若将来重开，也只允许 overlay 方案）
- **重审触发**：出现"确实要在蜂窝/异地访问"的真实需求时，再按 [research §6.4.1](./research.md) 的对比表选型（优先 Tailscale / Headscale）。

## ADR-007 文件通道写成"多提供者列表"，默认 rclone(WebDAV)  ← **本次决定**

- **背景**：文件通道有"按需访问"（rclone：WebDAV/SFTP/…）与"自动同步"（Syncthing）两个物种。担心将来切换困难。
- **决定**：
  1. 壳把文件通道声明为 **providers 列表**，而不是单选字段；每个提供者有独立的 `kind / root / 监听方式 / 启停条件`。
  2. **默认只启用 rclone + WebDAV**，走 `--addr unix://…/files.sock`（**零 TCP 端口**），由壳反代。
  3. **Syncthing 作为可后加的第二个提供者**，不与 rclone 冲突。
  4. 共享目录**默认只给沙箱** `/data/local/dsh/shared`；要 `/sdcard` 子目录需显式 bind。
- **依据**：把"选哪个"从"现在拍板的二选一"降级为"以后改配置"；两个物种可并存。
- **代价**：壳要多一点配置解析与生命周期管理；Syncthing 不能被反代包住，需要**按 Wi-Fi 条件启停进程**（它的 `22000/TCP+UDP`、`21027/UDP` 要自己在局域网可达）。
- **重审触发**：若 Syncthing 的常驻/耗电在平板上不可接受（社区已有 SleepManager/SleepSync 这类补丁 App），则退回"纯 rclone"。

## ADR-008 不写插件管理器：DSH 侧交给 DSH 自己的机制，壳侧只写"约定"  ← **本次决定**

- **背景**：考虑要不要自己写一个插件管理器。
- **决定**：
  1. **DSH 插件侧：绝对不写。**
     - **【已验证】** DSH_HOME（`/root/.dsh`）里已经有一整套：`plugin-manager.py`（导入/导出/链接安装 + 下载校验）、`plugin-lifecycle.py`（启停）、`plugin-transactions.py`（事务）、`plugin-dependencies.py` + `plugin-dependency-locks/`（依赖与锁）、`plugin-sources.json`（源）、`plugin-updates.json`（更新检查）、`plugin-activations.json`（激活指纹/版本/startup）、`plugin-history/`、`plugin-previews/`、`plugin-semver.cjs`（semver）
     - 再写一个只会和它对账本、抢 `profiles/<name>/node_modules`，且**必然落后于上游**。
  2. **壳的能力插件侧：只写"约定"，不写"管理器"。**
     - 目录约定 `/data/local/dsh/caps/<name>/` + `cap.json`（name/version/requires/health）+ `start.sh`/`stop.sh`
     - 壳只做三件事：**扫描 → 按条件启停 → 健康探测 + 并入统一端口发现**
     - **不做**：依赖解析、版本约束、远程仓库、UI、权限模型、沙箱、回滚
  3. 能力对 DSH 的暴露方式：能力自己起 HTTP/UDS；DSH 侧用**一个** `dsh-tool-*` 插件去调它（那个插件用 DSH 自己的管理器装）。
- **依据**：能力数量预计 <5、无第三方生态；管理器一旦开始写就会背上用不到的一整套。
- **代价**：能力之间不能声明依赖；升级能力要手工。
- **重审触发**（满足任一条再考虑做管理器）：① 能力数 ≥5；② 需要第三方分发能力；③ 需要版本兼容矩阵；④ 需要沙箱/权限隔离。
- **现成参考**：真要写时，本机 `/root/.dsh/plugin-manager.py` 就是一份可读的设计参考（源 / 事务 / 锁 / 指纹）。
- **修订（ADR-012）**：本条排除的是**管理器内核**（依赖解析 / 生命周期 / 版本约束 / 仓库客户端）。
  **操作面与带外恢复是必需的**，且**只有壳能做**（要在 DSH 起不来时仍可用）→ 见 **ADR-012**。
  即：本条管"谁管插件"，ADR-011 管"谁能批准装插件"，ADR-012 管"DSH 死了谁来关插件"。

## ADR-009 容器分层不用 overlayfs：bind(ro) + active 指针  ← **本次决定**

- **背景**：设计里曾把 overlayfs 作为"更优雅的版本分层"列为进阶项；同时使用者指出他的**模块挂载**用的是 **Magic Mount-rs**（自定义挂载），overlayfs 是被绕开的那条路。
- **澄清（重要）**：这是**两个不同场景**：
  - **模块挂载**（KernelSU 元模块，`/system` 域）：你的 Magic Mount-rs 负责，无关于本项目；
  - **容器分层**（`/data/local/dsh/` 内部）：我们的壳负责 —— **这里根本不需要 overlayfs**。
- **决定**：容器分层规范做法 = **`mount --bind` + `remount,ro` + active 指针**（文本指针原子写）。**不采用 overlayfs**，也不再需要验证内核是否支持它。
- **依据**：
  1. 等价效果、实现更简单、行为完全可控；
  2. 少一层内核特性依赖（stock 上本来就要能跑，见 ADR-001）；
  3. 避免与"模块挂载"的概念混淆。
- **代价**：切换 active 指针时若进程仍在运行，需要按顺序处理（先停服务再换指针），overlayfs 的"无缝"优势我们没有 —— 但可接受（我们的 DSH 本来就是可重启的服务）。
- **新增约束**：**不要给容器 bind 模块目录**（`/data/adb/modules/...`），否则会穿过 KernelSU 的挂载视图。容器只 bind `/data/local/dsh/` 与显式白名单。
- **重审触发**：出现"必须在不重启服务的前提下切换版本层"的真实需求。

## ADR-010 采用统一的版本号与 module.prop 规范  ← **本次决定**

- **背景**：使用者给出模块版本规范（四位 `version` + 单调 `versionCode` + APK 对齐）。
- **决定**：采纳，并把细则写进 [docs/versioning.md](./versioning.md)：
  1. `version` = `<大版本>.<功能变更新增>.<补丁>.<DSH内置版本号>`，第 4 位与 manifest 的 `floor` **对齐**；（⛔ 已由 ADR-025 修订）
  2. `versionCode` = **变更了多少次**（面向 Root 管理器的计数），单调 +1；**不从 `version` 推导、不与它联动**（两者是独立维度：`version` 给人看，`versionCode` 给管理器看）；
  3. APK：`versionCode` 对齐模块 `versionCode`，`versionName` 对齐 `version` 结构；
  4. **单一真源** `version.env`，`module.prop` / `manifest.json` / APK 三处全部由它生成，禁止手改；
  5. `managedFeatures`：**有真实实现才声明**，且必须与模块 config 的 `manage.<feature>=true` **成对一致**。

> **修订（ADR-025，2026-10-18）**：第 1 条与下面"已定"里的「与 `floor` 对齐 / 与 `floor` 及 `baked` 三者一致」**作废** ——
> 第 4 位改为**对着 `baked`**，并由 [baseline/bake-ledger.json](../baseline/bake-ledger.json) 的 `seq` 生成。以本文档末尾的 **ADR-025** 为准。

- **依据（源码核实）**：BakaSU 的 `installer.sh::check_managed_features()` 从 **module.prop** 读 `managedFeatures` 并用 `ksud feature check` 逐项判定（unsupported / managed / supported）；而 `ksud` 的 `list_module` 会从模块 config 的 `manage.*` 派生同名标签。两处不一致会自打架。
- **代价**：多一个构建脚本；换来三处版本永不漂移。
- **已定**：`version` 第 4 位 = **内置到容器里的那个 DSH 版本的映射值**（不是随意计数器），并必须与 `manifest.floor` 及 payload 内的 baked 版本三者一致。（⛔ 已由 ADR-025 修订：只对着 `baked`，`floor` 不进版本号）
- **已定**：`version` 第 4 位 = **内置 DSH 版本号**，随"模块最低支持 DSH 版本"对齐。（⛔ 同上，已作废）
- **已定（2026-10-17）→ 修订（ADR-025，2026-10-18）**：第 4 位的书写形式是**映射序号**（第几次烘焙），由烘焙台账生成；
  "从 semver 编码"这条路已被证否 —— semver 的序是稠密的，不存在保序的整数编码（见 [versioning §2](./versioning.md)）。
- **未定**：`id` / `name`（暂时占位，后面再定）。
- **重审触发**：上游 DSH 发布稳定的版本号规则，可用其数字码替换自维护序号。

---

## ADR-011 AI 写插件：内置包管理器，约束只能落在 DSH 够不着的地方  ← **本次决定**

- **背景**：我们要的能力是"**让 AI 写插件、装插件**"，而不只是跑一个裸的 DSH。这条链上有两个独立问题：
  1. **能力**：pnpm 不内置就装不了插件；
  2. **约束**：能装插件就等于给了"**进程内、沙箱外、跨会话存活**"的代码执行 —— 而使用者明确要求"不能让 AI 搞坏设备环境和容器环境"。

- **上游三条原文（说明 DSH 内部没有任何一层能当边界）**：
  1. `SAFETY.md`：沙箱/审批/权限**"可以降低风险，但不保证隔离，也不能保证防止损害"**；**"不要把 DSH 当作不可信工作负载唯一的安全控制措施"**；**"优先在一次性虚拟机、容器或专用环境中运行"**。
  2. `packages/boot/plugin-manager/README.md:31`：装完的 **"installed Host code executes in-process outside the workspace sandbox"**。
  3. `packages/extensions/cordis-host-runner/README.md:62`：那个 `node:vm` 沙箱 **"is not a security boundary"**、**"Treat a dynamic package like bash access"**。

- **上游一个结构性事实：它的"人在环"是声明式的，不是强制的**（同一模式出现两次）：
  - `plugin-manager/README.md:64`：`approvedBuilds` 由调用方声明 —— **"The service validates pending names; it does not verify conversation approval."**
  - `plugin-manager/README.md:71`：版本豁免要 `acceptRisk: true` —— **"The service checks the acknowledgement and versions, not conversation history."**
  → 服务只校验"**你声明了**"，不校验"**用户真的批了**"。所以把审批只放在 DSH 里，等于把闸门交给模型。

### 决定 A：内置包管理器（能力）

1. **把 Node + pnpm 作为内置公共服务随模块分发**：构建期打包、安装期解压落盘。**这是必选项**，不是可选优化 —— DSH 的价值就在插件能力。
   - 先例：上游自己的**开箱即用产品** Desktop 就是内置的（"ships one pnpm distribution at `resources/runtime/primary-runtime/dependencies/pnpm`"，"package operations do not require pnpm on PATH"，"**the application must run without a system Node.js or pnpm installation**"，`apps/desktop/README.md:43,116`）。
   - 代价量级（实测）：`pnpm@11.28.5` unpacked **22.6 MB / 454 文件**；Node 上游已 pin **24.21.0**（含 `linux-arm64.tar.gz` + sha256，见 `scripts/primary-runtime/lock.json`）→ 合计 **≈70 MB**，相对 582 GB 可用空间是噪声。
2. **默认路径与"单文件可执行"冲突，必须二选一**：`@yao-pkg/pkg --sea` 打出的二进制**不能冒充普通 node**（设计笔记原文："a SEA binary cannot impersonate plain Node because it always boots its embedded app"）→ 走单文件就**没有 node 跑 pnpm**，还得另外带一个 Node，不如直接用普通 Node。**结论：容器内用「普通 Node + pnpm + npm 装的 dsh」**。
3. **不发明接口**：上游已为"应用自带包管理器"留好正式缝 —— **launcher facts**：`ProfileContext.packageManager?: ProfilePnpmInvocation`（`packages/boot/app-boot/src/profile-context.ts:18`），**优先于 `pnpmCommand`**，且其 env **只作用于包操作子进程**（`plugin-manager/README.md:10`）。桌面范例 `apps/desktop-host/src/index.ts:25-42`：
   ```ts
   runProfile({ profile: 'web', args: [...],
     packageManager: { command: process.execPath,
       args: ['--expose-internals', '<pnpm.mjs>'],
       env: { PATH: `${pnpmBinDir}${delimiter}${process.env.PATH}` } } })
   ```
   → 壳只需解压一份 Node+pnpm，启动时注入 `packageManager`，**不塞全局 PATH、不改 `pnpmCommand`**。
4. **版本要钉到 ≥ 上游 pin，不是"够用就行"**：上游 `packageManager` 钉的是 **`pnpm@11.28.5`**（engines `node ^22.19 || >=24`），而**本容器当前是 pnpm 10.34.5 + node 24.19.0**（实测）—— 差一个大版本，而 `allowBuilds` / `strictDepBuilds` 的语义正好横在这两个大版本之间。内置时按上游 pin 对齐。

### 决定 B：约束分层（信任只能来自 DSH 之外）

> 📌 本条的边界表已并入 [docs/threat-model.md](./threat-model.md) §3。**新增或改动边界时，两份都要改。**

| 层 | 约束 | 谁执行 | AI 能否看见 / 改动 |
|---|---|---|---|
| **L1 会话能力** | `plugin_manager` 工具**默认关闭**，只在 Creator preset 开启；每次写操作要 `danger-full-access` 或逐次审批 | DSH preset | 可见，但**不能自己切 preset** |
| **L2 人在环** | 插件安装/构建脚本批准走**容器外通道**（壳的 UI / 宿主）；**不把 `approvedBuilds`/`acceptRisk` 交给模型** | 壳 | **不可见** |
| **L3 容器边界** | 只读根 + 独立可写数据卷 + 不挂设备节点 + 网络出口白名单；**"跑 AI 写的插件"的容器 ≠ 承载设备能力的容器** | 容器运行时 | 不可见 |
| **L4 宿主** | 与 DSHA 设备桥**不共用 `DSH_HOME` 与 `~/.agents`**；不向容器暴露 adb key / 设备策略 | 宿主 | 不可见 |

- **原则**：AI 不能把自己提权到"**能改约束本身**"的那一层。上游已有同款范式可抄 —— `plugin-manager/README.md:143`：管理器**不能禁用自己、不能改别的 profile、不能改 preset 组成**。
- **两条路径**：
  1. **试衣间**（不落盘）：用上游的动态定义能力（`dsh-cordis-host-runner`，`vmTimeoutMs` 默认 5s，**定义重启即消失**）给模型"能写、能跑一次、但不留痕"的出口。注意官方对它的定性是"**当作 bash 权限**"，所以这一步同样只能在容器里。
     > 上游**故意不给模型**这条路：`cordis-host-runner/README.md` 写明 "no model tool creates dynamic definitions"，且 "The shipped Creator workflow uses **installed bundles** instead of this definition registry" —— 即上游让模型写插件的唯一出货路径就是**持久安装**。我们反过来用它当试衣间，是**比上游默认更安全**的改法。
  2. **人闸门**（持久安装）：`installBundle`/`enable`/`remove` 是**唯一**会把代码变成"进程内 + 沙箱外 + 跨会话存活"的动作 → 必须在容器外、由人批准。

### 决定 C：红线（违反即视为设计错误）

- **R1**：`plugin_manager` 的**写**操作、`approvedBuilds`、`acceptRisk` 一律**不下沉给模型**。
- **R2**："跑 AI 写的插件"的容器与"承载设备能力"的容器**物理分开**。
- **R3**：容器不挂 `/data/adb`、不持有 adb key、不共用 `DSH_HOME`/`~/.agents`（补 ADR-004）。
- **R4**：批准是**按包名永久存活**的（`plugin-manager/README.md:64`）→ 壳必须提供"**查看/撤销已批准包名**"的入口。
- **R5**：模型不得有能力修改约束本身（切 preset、改 profile、改壳配置）。
- **与 ADR-008 的边界（防打架）**：ADR-008 排除的是"自己写一个插件**管理器**"（依赖解析 / 生命周期 / 版本约束 / 仓库）。
  本条**不违反**它 —— 壳加的是**闸门**（批准 + 账本 + 消费协议），且明确"三面共享同一套实现，**壳不重新实现任何包操作**"。
  两者的分工：**ADR-008 说"谁管插件"，本条说"谁能批准装插件"。**

### 决定 D：离线 registry 从"必选"降为"条件项"

- 判据不是"DSH 要不要联网"，而是"**这台机器的网络出口里有没有 public registry**"。
- DSH 要连模型服务 ⇒ 一般就有公网 ⇒ 预置 store / 本地镜像（原设想 ③）**不是必选**；
- **例外**：AI 服务来自**本地 / 私有局域网 / 本地服务器部署**时，可能出现"有内网、无公网" → 此时 ③ 才重新变成必需。把它写成一句可检查的条件，而不是笼统的"离线/在线"。

### 附：插件管理器的协议面与通用反馈（壳按这里对接）

**三面共享同一套实现**（`packages/boot/plugin-manager/src/operations.ts`）：Web 插件页 · `plugin_manager` 工具 · `dsh plugin` CLI。壳要拦，拦的是这三面，**不重新实现**。

- **操作集**：`listBundles` · `inspect(spec, options)` · `installBundle` · `waitForInstall(requestId)` · `cancelInstall(requestId)` · `registries()` · 行级 enable/disable · remove · `list_version_exemptions` · `set_version_exemption`。
- **通用反馈**（原文："Results contain the last attempted stage, target, saved-state change, application status and error codes"）：

| 字段 | 取值 / 含义 |
|---|---|
| `application` | `applied` · `restart-required` · `failed` · `cancelled` |
| `failedAt` | 区分"**spec 主机不可达**"与"registry 侧不可达"（git/tarball 类才可能是前者） |
| `packageResult.kind` | 由退出码 + 输出分类**最后一次 pnpm run** |
| `pendingBuilds` | 待批准脚本的**包名全集**（含历史遗留与"被忽略"的名字） |
| `approvedBuilds` | **调用方声明**的批准（见 R1） |
| `nextStep` | 由 application 状态 / 拒绝码 / pnpm failure kind / restart 原因派生的**一句话**，说明模型下一步做什么 |
| `inspect().problem` | `invalid-spec` · `already-installed` · `not-found` · `not-a-package` · `not-a-bundle` · `network` · `unknown` |
| `incompatible-version` | 带每个被拒包的 `name` / `version` / `runtimeVersion` / 未满足的 `requirements` |
| 事件流 | `plugin-manager/install-log`（流式 pnpm 输出）· `plugin-manager/install-state`（`installing`/`cancelling`/`applying`，每次试探 registry 带 `attempt` + 位置 + plan 长度） |
| 诊断 | `outputBytes` 默认 16384；完整输出落在 profile 的 `.plugin-manager/logs` |
| 运行记录 / 锁 | `.plugin-manager/run.json`；profile 写锁 `lockWaitMs` 默认 120 s；静默超时 `idleTimeoutMs` 默认 600 s → `timedOut` |
| 回滚语义 | 失败/取消恢复 `package.json` + `pnpm-lock.yaml`，**故意不恢复 `pnpm-workspace.yaml`** |
| 配置面（8 项） | `pnpmCommand` · `inspectTimeoutMs`(20 s) · `githubConnectionTimeoutMs`(5 s) · `registry` · `fallbackRegistries`(默认 `registry.npmmirror.com`) · `outputBytes`(16384) · `lockWaitMs`(120 s) · `idleTimeoutMs`(600 s) |

- **壳该怎么用这套协议**：
  1. 用 **`plugin-manager/install-state` + `install-log`** 当审批上下文 —— **把 pnpm 原始输出直接给人看，不要经模型转述**；
  2. 用 **`pendingBuilds`** 作为"待批准清单"的权威来源，**由壳回填 `approvedBuilds`**；
  3. 把 **`application` / `failedAt` / `problem` / `incompatible-version`** 直接映射进壳的状态机（这四个是稳定的机器可读面）；
  4. 维护"已批准包名"的**可撤销账本**（R4）；
  5. **不碰** `nextStep`（那是给模型看的一句话），壳的文案自己出。

- **代价**：多一层审批 UI / 宿主通道；Creator 要另一个容器实例；换来的"AI 不能自己装插件"会牺牲一点爽感。
- **重审触发**：① 上游把审批从"声明式"改成"可校验"（宿主签名 / 回调）；② 上游提供**真正的**插件沙箱；③ 出现"只跑本地模型、完全离网"的部署，需要重新评估 ③。

---

## ADR-012 壳的插件操作面：保留上游在线面，另做带外面，两套面共用一份真相  ← **本次决定**

- **背景**：ADR-008 说"绝对不写插件管理器"，ADR-011 又让壳加"闸门（批准 + 账本）"—— 边界要再钉一次。而使用者指出了更根本的一点：
  **在 Android 上跑虚拟 Linux 环境本身很脆弱**（容器会被杀、rootfs 会坏、node/pnpm 可能缺失、HMR reload 会失败、profile 可能坏到 DSH 根本起不来）。
  而**上游的管理面全部要求 DSH 活着**：Web 插件页要有 Host 在跑，`plugin_manager` 工具要有会话在跑。
  → 真正的问题不是"要不要写管理器"，而是"**DSH 起不来时，谁还能把插件关掉**"。

### 决定 A：在线面保留上游的 UI 映射，不自研

**UI 映射包存在，且是成品**（实测确认）：

| 包 | 角色 |
|---|---|
| `@deepseek-ai/dsh-client-ui-plugin-manager` | **在线面主入口**（Web 侧边栏 **Plugins**）：bundle 与行开关、装前先由 Host `inspect` spec、看 pnpm 输出、中止运行、启用新装的、卸载需确认、并承载各插件自己的配置页 |
| `@deepseek-ai/dsh-client-ui-settings-plugin-inventory` | **只读清单**（Settings → 内置插件）：内置插件与运行时状态 |
| `@deepseek-ai/dsh-plugin-manager/registry` | 浏览器安全入口，导出 `OFFICIAL_NPM_REGISTRY` / `NPMMIRROR_REGISTRY` |

→ **保留**，不删、不重写：它功能最全且跟上游同步。**壳也不另写第三个浏览器插件页。**

### 决定 B：带外面（out-of-band）必须自己做 —— 这是新增的必需品

它必须在 **DSH 进程不存在**时可用。可用的上游机制（都存在于 CLI / 文件层，不需要 boot profile）：

| 手段 | 用途 |
|---|---|
| `dsh --profile <name> --dump-config` / `--dump-config-schema` | **不 boot** 就能看组装出来的树，定位是谁把它弄坏的 |
| 直接改 `cordis.patch.yml`：`- id: <row>` + `disabled: true` | 最小回退动作；profile patch / home patch / `--patch` 三层都可 |
| `dsh plugin --profile <name> remove <pkg>` | 转发 pnpm，**不 boot profile** |
| `dsh --profile <name> --from-default-profile <template>` | 从出货模板**重建** profile（不读旧 profile 的依赖与 patch） |
| `$DSH_HOME/profiles/.<name>.staging-*/previous` | 替换失败时留下的手动恢复目录 |

> ⚠️ `dsh plugin` **明确要求 pnpm 在 PATH 上**（`apps/cli/reference/README.md:83`）——这又是一条"必须内置 pnpm"的**独立**理由（见 ADR-011 决定 A）。

### 决定 C：红线 —— 两套面共用一份真相，禁止第二本账

- 真相 = profile 目录里的**四份文件**：`package.json`（`dsh.profile.bundles` + dependencies）· `cordis.patch.yml`（`disabled` 行）· `pnpm-workspace.yaml`（`allowBuilds`）· `compatibility.json`（版本豁免）。
- **壳的带外面只读写这四份文件**；ADR-011 的批准账本只是"**谁批的 / 何时 / 哪个包**"的**审计旁证**，**不是状态真源**。
- 一致性要求：壳改完之后，DSH 的在线面必须看到**同样的结果**（这条要写成测试）。

### 决定 D：Android 特有的分级降级（DSH 没有 safe mode）

上游**没有** safe mode / 恢复模式（全仓搜索无命中），所以分级处置由壳提供：

| 级别 | 症状 | 处置 |
|---|---|---|
| **L0** | 只是某个插件坏 | 在线面关掉它；必要时带外面改 `disabled` |
| **L1** | DSH 起不来 | 带外：`--dump-config` 定位 → 改 patch 禁用 → 重启 |
| **L2** | profile 文件坏 | `dsh plugin remove`，或从模板 `--from-default-profile` 重建 |
| **L3** | 容器 / rootfs 坏 | **两步**：① 换 `active` 指针回退**程序层**（ADR-009）；② 用快照恢复 profile 的**四份文件**（见 D.1/D.2）—— **只做第一步等于没修**。入口与脚本契约见 **ADR-013** |

#### D.1 为什么 L3 不能单独用：程序层 vs 数据层

容器里有两块东西，性质不同：

| | 在哪 | 可写 | 谁负责回退 |
|---|---|---|---|
| **程序层** | `bind(ro)` 的版本层：Ubuntu + Node + pnpm + DSH 本体 | 只读 | **L3 换 `active` 指针**（ADR-009） |
| **数据层** | 可写卷里的 `$DSH_HOME/profiles/<name>/` | 可写 | **L2 / 快照恢复** |

**插件住在数据层**：声明在 profile 的 `package.json`（`dsh.profile.bundles` + dependencies），代码在 profile 的 `node_modules/`。
而 DSH **每次启动都按这份声明重新加载** → 只回退程序层，坏插件会被原样加载回来，表现出来就是"回退没用"。

#### D.2 快照点与恢复动作（壳执行）

- **快照点 = 每次批准改动 profile 四份文件之前**（复用 ADR-011 的人闸门，**不额外增加时机**）。
  只存 **profile 目录里的四份小文本文件**就够：`package.json` · `cordis.patch.yml` · `pnpm-workspace.yaml`（`allowBuilds`）· `compatibility.json`（版本豁免）—— **KB 级**，**不备份 `node_modules`**。
- **恢复动作**：把这四份换回上一个快照 → DSH 即可重新启动。
- **`node_modules` 里的残留是惰性的**（上游就是这么设计的）：
  `plugin-manager/README.md:162` —— "Restoration rewrites only the two snapshotted files; … **the next package operation prunes packages no manifest references.**"
  → 恢复那一刻残留文件不影响启动，等下一次包操作自动清掉。
- **所以 L3 是接力而不是单步**：`换 active 指针` → `恢复 profile 四份文件` → 才能启动。

### 与 ADR-008 的关系（最终口径）

- ADR-008 排除的是"**管理器内核**"：依赖解析 / 生命周期 / 版本约束 / 仓库客户端。
- 本条要的是"**操作面 + 带外恢复**"。
- 壳 **不做**：依赖解析、semver、仓库客户端、包操作实现。
- 壳 **要做**：四份文件的读写、审计账本、四级降级入口、（ADR-011 的）审批闸门。
- 一句话：**ADR-008 说"谁管插件"，ADR-011 说"谁能批准装插件"，本条说"DSH 死了谁来关插件"。**

- **代价**：壳多一套"与上游操作同一份文件"的读写逻辑（必须有一致性测试兜底）；带外面能力弱于在线面（装插件仍需 pnpm + 网络）。
- **重审触发**：① 上游提供官方 safe mode / 恢复 CLI；② 上游把管理状态从四份文件收敛到单一 store（届时壳的带外面要跟着改）；③ 容器层能可靠提供快照回滚，L3 可简化。

---

## ADR-013 重建入口与脚本契约  ← **本次决定**

- **背景**：ADR-012 定了"带外面"（DSH 死了也能操作插件），但没说**入口在哪、谁能跑、跑的时候环境长什么样**。
  使用者给出答案：**通过 Root 管理器 / MT 管理器 / 其他终端执行 `service.sh` 即可完成重建**。
  → 这条入口比"壳自己的 web 页"更底层：**DSH 死、壳守护死、浏览器没有、App 不在，它都能用** —— 它是带外面的**最后一层兜底**。

### 决定 A：四个入口，同一份代码

| 入口 | 谁跑 | 何时 |
|---|---|---|
| `service.sh`（开机） | magiskd / ksud（root，模块域） | 开机自启、模块更新后 |
| Root 管理器 | 用户手点（root） | 重建、修复 |
| MT 管理器 / 终端 App | 用户手跑（root / su） | 现场排障 |
| 壳守护进程（未来） | broker | 自动化 |

**规则**：`service.sh` 是**唯一执行者**，其余入口只 `exec` 它并传参 → **保证四条路径跑的是同一份代码**，不会出现逻辑漂移。
> 补充（**ADR-019**）：在这条之上再加一层**公开入口** `dsh-ctl`（环境归一化 / 参数校验 / **cgroup 搬家** / 审计），执行者仍是 `service.sh`。

对外只暴露**一个命令（`dsh-ctl`）与一组动词**（主路径如下；完整集另见 ADR-019 决定 A 与 ADR-023）：

```
dsh-ctl status          # 当前层 / active 指针 / profile 四份文件校验和 / 进程在不在 / 上次失败原因 / mode=（ADR-023）
dsh-ctl repair          # L1–L2：改 patch 禁用 + 恢复四份文件
dsh-ctl rebuild         # L3：换指针 + 恢复四份文件 + 重启
dsh-ctl logs [--tail N] # 运维日志（见 ADR-014）
dsh-ctl diag            # 生成脱敏诊断包 → /sdcard/Download/（见 ADR-014）
dsh-ctl upgrade <ver>   # 手动抬升 DSH：唯一推荐入口（“0 插件更新”事务，见 ADR-023）
```

### 决定 B：脚本契约（六条 —— 因为它跑在别人的进程里）

1. **非交互、无 TTY**：不能 `read`、不能等确认；输入只走参数 / 环境变量。
2. **环境钉死**：自己设 `PATH=/system/bin:/data/adb/ksu/bin` 与 `TMPDIR`；**不继承调用者的 `HOME` / `PATH`**。
3. **幂等**：跑两次结果一致（第二次输出 `already current` 并 exit 0）。
4. **先停后换**：ADR-009 已记账的代价 —— 检测活跃实例 → 优雅停 → 等 → 再切 `active` 指针，**不能热换**。
5. **离线**：payload 从模块自带的副本解压，不联网。
6. **可观测 + 退出码**：给人看的一段状态 + **给机器看的一行标记**。沿用 [recovery.md](./recovery.md) 里记过的 DSHA 先例（`DSHA_VSCREEN_BOOTSTRAP <hex>` / `DSHA_VSCREEN_ERROR=<code>`）：
   - `DSH_REBUILD_OK <层名>` / `DSH_REBUILD_ERROR=<code>`
   - 退出码：`0` 成功 · `10` 已是当前（幂等）· `20` 停止失败（有活跃实例）· `30` payload 缺失或校验失败 · `40` 切换失败 · `50` 版本闸门拒绝启动（ADR-026 增补）。

### 决定 C：环境硬约束（2026-10-16 设备实测）

| | 结果 |
|---|---|
| **可用** | `sh` · `toybox` · `setsid` · `flock` · `tar` · `unzip` · `gzip` · `bzip2` · `cpio` · `mount`/`umount` · `readlink` · `chcon` · `chown` · `stat` · `mktemp` · `find` · `xargs` · `sed` · `awk` · `grep` · `tr` · `cut` · `nohup` · **`curl`** |
| **不可用** | `zstd` · `xz` · `lz4` · `7z` · `zip` · `pigz` · `start-stop-daemon` · **`wget`**（`/system/bin` 层面）。`busybox` **不在** `/system/bin`，但 **`/data/adb/ksu/bin/busybox` 在**（1.7 MB，可作兜底） |

> ⚠️ **2026-10-18 修正**：原始表格把 `curl` 列进了"不可用"，**是错的**。实测这台设备 `/system/bin/curl` 是 **654 KB 的真实二进制**，
> 版本 `curl 8.21.0 (aarch64-unknown-linux-android)`，特性含 **HTTP2 / HTTP3 / HTTPS-proxy / threadsafe**（libcurl 8.21.0 + OpenSSL 3.6.3）；
> 反而 `/system/bin/wget` 不存在。→ 下载器首选 **curl**（`-C -` 断点续传 / `--retry` / `--fail` / 进度），`busybox wget` 只作兜底。

由此得到两条硬规则：

1. ⛔ **payload 不用 zstd**。`tar --zstd` 在**设备侧没有**，**当前这个 Ubuntu 容器里也没有**（实测 `zstd: command not found`）；
   而模块 zip 是在 **Android 侧**被 Root 管理器解压的 → 能用的压缩只有 **`gzip` / `bzip2`**（`tar`、`unzip` 都原生有）。
   → 已同步修正 [projects.md](./projects.md) 与 [baseline.md](./baseline.md) 里的 `tar --zstd`。
2. ⛔ **纯 POSIX `sh`**：Android 的 `sh` 不是 bash；**没有 `start-stop-daemon`** → 停服务自己写 pidfile + `kill`。

### 决定 D：SELinux 域 / uid 不一致的处置

四个入口的 SELinux 域与 uid **可能各不相同**（`u:r:su:s0`、ksu 域、App 域、模块域）。
同一个脚本从四处跑，**写出来的文件属主 / 上下文可能不一致**，长期会出现"DSH 读不了自己数据"这类问题。

- 脚本里**显式 `chown 0:0` + 固定 mode**，必要时 `chcon`（设备上有）；
- **只让 `service.sh` 做写操作**（即决定 A 的那条规则）。

- **代价**：壳要维护一个纯 `sh` 脚本（不能复用容器里的 Python / Node 工具）；payload 压缩率略降（gzip / bzip2 换 zstd）。
- **重审触发**：① Android 侧出现可用的 `zstd`（或 KSU busybox 带回 zstd applet）；② 壳守护进程成熟后 `dsh-ctl` 可不再依赖人工入口，但**契约不变**。

---

## ADR-014 日志与反馈：四类分开、壳是唯一落盘点、两条反馈面  ← **本次决定**

- **背景**：排障需求把"日志"推上台面。但**"日志"是四个没有共同点的东西**，混在一起就无解。
  使用者同时指出一个更根本的分野：**"DSH 运行"与"DSH 移植"是两条路** ——
  一个是让 DSH 在**已有可用的电脑系统**上跑，另一个是把**可用的电脑系统移植到手机上**跑。
  → 故障因此分成两类：**DSH 自己的问题**（上游能诊断）与**移植层的问题**（上游完全不了解）。

### 决定 A：四类日志分开，各有归属

| 类型 | 归属 | 落点 | 谁看 |
|---|---|---|---|
| ① **运维日志**（壳起停、DSH 起不来、修复动作） | **壳** | `/data/local/dsh/log/` | 用户 / 我们 |
| ② **产品数据**（会话事件、工具调用） | DSH | `$DSH_HOME/sessions/`（上游机制） | DSH 自己；**不是运维日志，别拿来排障** |
| ③ **系统日志**（内核 / Android / root 执行） | Android | `/data/adb/ksu/log/`（**KSU 已在抓**，见下） | 我们 |
| ④ **遥测**（外发） | DSH | 上游 collector（默认不上报，见决定 E） | 上游 |

### 决定 B：壳是唯一落盘点

- **【已验证】DSH 自己不落盘**：上游全仓无 `logFile` / `log-file` 机制，它的"日志"就是 stdout / stderr。
- 而 ADR-013 已规定 **`service.sh` 是唯一执行者** → **由它做 stdout / stderr 重定向**，这是最自然、且没有第二处的位置。
- **位置**：`/data/local/dsh/log/` —— 在 ADR-009 已规定的容器白名单路径内，所以**容器内外都能看**。
- **轮转**：每类 `5 MB × 2 代`（对齐 KSU 的两代滚动习惯）。日志**不进 payload、不进版本层**（数据/程序分离）。
- **不自己抓 logcat**：KSU 已经在抓（`logcat.log` 19 MB × 2 代 + `dmesg.log` + `sulog-<日期>.log`），**引用即可，不要重复实现**。
  另实测：`logcat` 命令**在设备策略白名单里**（`adb-shell "logcat -d -t 3"` 返回 0），壳有现成出路。

### 决定 C：⛔ 凭证绝不进日志（本项目特有的红线）

- **实测**：`dsh web` 启动行**自带 token** —— `dsh web: http://127.0.0.1:39895/?token=…`。
- **壳若把 stdout 原样落盘 = 把凭证写进日志。**
- 规则：
  1. **token 行只进 `run/dsh.json`（0600），不进日志**；日志里只留端口；
  2. 日志写入前过一遍**脱敏白名单**（token / API key / `Authorization` / `anonymous-user-id` / cookie）；
  3. **日志目录 0700、文件 0600**（与 `DSH_HOME` 的凭据区同级），**不放 `/sdcard`**。
- 上游先例：本仓库 [recovery.md](./recovery.md) 记过的 DSHA 规则 —— **"不把启动输出和凭据写进日志"**。

### 决定 D：两条反馈面（"运行"与"移植"的分野落地）

| | 反馈对象 | 通道 | 内容 |
|---|---|---|---|
| **面 1** | **上游 DSH 本体** | 上游既有机制（见决定 E，默认 `FEEDBACK_ONLY`） | 会话日志前缀；**仅用户显式反馈时释放** |
| **面 2** | **移植层（本项目）** | **`dsh-ctl diag`** → 生成脱敏诊断包到 `/sdcard/Download/` | 壳日志 + 版本/指纹 + 容器与挂载状态 + `dsh-ctl status` + **相关** logcat/dmesg 片段 |

- **为什么要分**：移植层的故障（chroot / bind / SELinux / ColorOS 后台 / 模块 / root 形态 / 存储）**上游既不了解也无法从会话日志诊断**。
  把这类问题点成"给上游反馈"，上游收到的是一段毫无帮助的会话日志 —— 反过来也一样。
  → 所以 ADR 要写清一句可分诊的话：**"DSH 本体行为异常 → 面 1；装了/起不来/挂不上/被杀 → 面 2"**。
- **⛔ 诊断包必须白名单打包，绝不 `tar` 整个 `DSH_HOME`**。理由：那里躺着 `.credentials.yaml`（模型 API key）、`.anonymous-user-id`（遥测身份）、`.bridge_token`（设备桥凭据）。
  包含：`dsh-ctl status` 输出 · 壳日志尾部 · `module.prop` / `manifest.json` / 版本串 / 内核串 / SELinux 模式 · 挂载表（`/proc/mounts` 相关行）· 容器层与 `active` 指针 · DSH 版本。
  排除：任何凭据文件 · `sessions/`（产品数据，含隐私）· `node_modules` · 全量 logcat（只取相关行）。
- 用户视角只有一条命令：**`dsh-ctl diag`**，产物落在 Download 里，**可以直接分享出去**（手机上没有电脑也能给）。

### 决定 E：遥测保持默认，但写清它是什么

- **【已验证】默认不会偷偷上报**：`mode: DSH_TELEMETRY_MODE || 'FEEDBACK_ONLY'`，上游注释原文 ——
  "OTel releases a Session-log prefix **only after explicit user feedback**, regardless of model provider. **Ordinary activity never triggers capture.**"
- 端点 `https://dsh-otel-collector.deepseeksvc.com/v1/logs`（gzip、1 s 超时、3 s 关闭预算）；
  身份 = `$DSH_HOME/.anonymous-user-id`（随机 UUID，**删文件即重置身份**）。
- **开关语义反直觉（记下来免得踩）**：`DSH_TELEMETRY_DISABLED` —— **任意非空值都算关，包括 `0` 和 `false`**。
- **而且只有启动器能关**：上游注释写明 "the launchers patch the row disabled; **config cannot disable a row**" → **这又是壳作为启动器的一个职责落点**（与 ADR-011/013 同源）。
- **决定**：**阶段一保持默认（`FEEDBACK_ONLY`）**，不替用户做隐私决定；但在本文件与威胁模型里写清"何时会发、发到哪、带什么身份、怎么重置、怎么关"。

### 附带发现（两条，收进威胁模型）

1. **`/data/adb/ksu/log/logcat.log` 权限是 `-rw-rw-rw-`（世界可读）**，而它含**全系统日志** → 容器里**任何进程**（包括 AI 写的插件）都能读。不是我们的 bug，但必须知道它在那儿。
2. `DSH_TELEMETRY_DISABLED` 的反直觉语义（见决定 E），以及 `.anonymous-user-id` 是**可重置**的。

- **代价**：壳多一个日志写入 + 脱敏 + 诊断打包的实现（**脱敏必须是白名单，不能是黑名单**）；诊断包需要人工看一眼再发（我们不替用户自动外发）。
- **重审触发**：① 上游提供"移植层"友好的诊断接口或自带日志落盘；② 上游把反馈面做成可自托管的 collector（则可考虑把面 2 并入）；③ 出现需要长期留存的故障（届时再谈日志归档与体积）。

---

## ADR-015 更新通道：只以模块仓库发布为准，不推送上游更新  ← **本次决定**

- **背景**：DSH 0.2.x 仍在 rc / alpha 之间漂移（实测：本机跑 `0.2.0-rc.2`，上游 HEAD 已是 `0.2.1-alpha.5`，npm 的 `alpha` tag 也在动）。
  把这种上游更新**自动推给用户**，等于把不稳定性转嫁到设备上。

### 决定

1. **唯一发布通道 = 模块仓库**（Root 管理器的模块仓库 + `updateJson`，即 ADR-010 已定的字段）。
   `versionCode` 单调递增（ADR-010 §3），管理器据此提示更新。
2. **不推送上游更新**：不把 DSH 上游的新版本作为模块更新推给用户；**运行中的 DSH 不做自动升级、不做后台更新检查**。
3. **但必须区分三件事**（否则将来会打架）：

   | | 做不做 | 说明 |
   |---|---|---|
   | (a) **模块自身更新**（壳修复 / 容器修复 / 组合变更） | **发** | 走模块仓库，`versionCode` +1 |
   | (b) **模块内置的 DSH 基线抬升** | **随 (a) 一起发**，不单独推 | 换 payload + 台账记一行 → 抬 `version` 第 4 位、刷新 `manifest.baked`；`floor` 是否跟着抬是另一件事（ADR-025） |
   | (c) **运行中的 DSH 自动升级** | ⛔ **不做** | 没有后台更新检查、没有静默替换版本层 |

4. **与 ADR-003（floor-only）不矛盾**：floor 管的是**闸门语义**（允许高于 floor 的版本运行），本条管的是**分发策略**（我们不主动推）—— 两个不同维度。
   用户**可以自己**装更高版本的 DSH，floor 闸门仍然照常生效。
5. **因此壳要显示"偏离"**：用户手动升级后，"模块内置基线"与"实际运行版本"会不一致
   → **`dsh-ctl status` 必须同时显示这两个值及其偏离**（否则排障时说不清用户到底在跑哪个版本）。
6. **升级动作复用现有机制**：模块更新 = 落新版本层 + 切 `active` 指针（ADR-009）+ **profile 数据不动**（ADR-012 D.1 的程序/数据分离）；
   重建入口与脚本契约见 ADR-013。

### 手机端 Web UI：**内置现成的第三方插件**，不自己写（2026-10-16 澄清）

**它不是我们要做的项目**，而是一个**已存在、可维护的第三方 DSH 插件**：

| 项 | 值 |
|---|---|
| 包名 / 版本 | `dsh-web-mobile` **v3.0.5** |
| 说明 | "尽可能的使 dsh 适配竖屏等移动端设备" |
| 作者 / 仓库 | `mexiaosh` · `github.com/mexiaosqwq/dsh-web-mobile`（MIT） |
| 形态 | **bundle + 浏览器半边**：`dsh.bundle.patch = ./cordis.patch.yml`；`dsh.client.platform = web`，`inject` 上游 8 个 `dsh-client-*` 包；产物 `lib/client.js` **707 KB** |
| 现状 | **DSHA 的 8 个内置插件之一**（`builtin-plugins.json`），profile 里以 `link:/root/dsha-web-mobile` 引用 |

**因此"内置"这条这样落**：

1. **照抄 DSHA 的做法**：把插件目录放进 **payload 的只读层**，profile 用 `link:` 指向它 —— 而不是让用户在容器里 `pnpm add`。
   理由：它是第三方 Git 项目（不是我们发的 npm 包）；`link:` 到只读路径既不会被 `dsh plugin` 的包操作动到，也能随模块更新一起走。
2. **更新通道 = 随模块发布**（与上面 (b) 同类），用户**不在容器里单独更新它**；且必须 **pin 版本 + 校验哈希**
   （DSHA 已有先例：`/root/.dsh/plugin-updates.json` 里第三方插件的下载请求带 `sha256`）。
3. **抬 DSH 基线时核对它的 peer 范围**（**例行检查项，不是风险项**）：它对 8 个 `@deepseek-ai/dsh-client-*` 声明了**窄区间**，例如
   `>=0.2.0-rc.1 <0.3.0-0`（本机 `0.2.0-rc.2` 落在范围内）→ 上游进 0.3 时会失配。
   **但这只是适配问题，不成问题**（2026-10-16 澄清）：
   - 它是**纯 client 侧的渲染优化**，只 inject 那 8 个 `dsh-client-*` 包，**不碰 host 侧、不碰 session 格式、不碰持久化**
     → 上游真正的破坏性变更**根本不经过它**；
   - peer 区间就是**它自己写的 8 行字符串**，放宽即可；
   - 三档解法，代价递增：① **放宽 `package.json` 的 peer 区间**（改 8 行，最干净）→ ② **不改包，写 `version-exemptions`**
     （`compatibility.json` + `acceptRisk`，一行配置）→ ③ 真出现 API 差异才动源码（而 client UI 的差异通常是**增量**：新增 slot / 改名，不是推倒重来）。
4. **它在 ADR-012 里的归属是明确的**：它是**在线面（DSH web UI）的增强** —— DSH 死了它也没用 → **属于在线面，不是带外面**。
   所以先前列的"ADR-012 边界复审"到此有答案，不需要再悬着。
5. **访问面与体积**：走 **ADR-006** 的既有档位（`local` / `lan`），不新增面；payload 多出的是一份前端产物
   （`client.js` 707 KB 量级，相对 439 MB 是噪声），但要**纳入 payload 的哈希校验**。

- **代价**：用户拿不到上游的新能力与新修复，直到我们发新模块；"什么时候把上游基线抬上来"变成我们自己的判断责任；
  另加一条：**我们多了一个要跟的上游第三方项目**（它一旦停更，就得自己 fork 维护 —— 但**适配成本低**，不是主要负担）。
- **重审触发**：① 上游发布稳定版本或兼容承诺（与 ADR-003 的重审触发同源）；② 上游提供可自托管的更新通道；
  ③ `dsh-web-mobile` **停更或改协议**（届时自维护 fork）—— **peer 区间不覆盖不是触发条件，那只是适配**。

---

## ADR-016 挂载布局与外部编辑器接入（MT 管理器）  ← **本次决定**

- **背景**：想让 MT 管理器"**添加本地存储**"直接管理容器里的文件（它是现成的人在环载体：root + 终端扩展包都在）。
  但实测发现一个根本前提：**root 和 root 不是一回事** —— 属主与权限在两个视角下**不一致**，而且**看不出来**。

### 实测证据（当前 DSHA proot 容器）

| 视角 | 路径 | 属主 |
|---|---|---|
| **容器内** | `/root/.probe_owner_test` | `root:root` (0) |
| **宿主侧** | `/data/data/com.dsh.client/files/linux/ubuntu/root/.probe_owner_test` | **`u0_a543` (10543)** |

- 整个 rootfs 在宿主侧**全部属于 `u0_a543`**；进程树里可见 `libproot.so … -0 --rootfs=…` —— **那个 `-0` 是 proot 伪造的 uid 0**。
- ⚠️ **proot 连 `stat` 一起伪造**：容器内 `ls -l` 永远显示 `root root`，而**访问检查按真实 uid 10543 判** → 出现"**看着是 root，做起来被拒**"（读一个宿主机 root 创建的 0600 文件即 EACCES，且从容器内查不出原因）。
- **两个命名空间互走不出去**（实测）：容器内 `/data/data`、`/data/user/0` 都是**空占位目录**，`ls /data/data/com.dsh.client/...` 直接 No such file or directory → **跨边界只能靠 bind**。
- **bind 目标必须预置**（实测）：rootfs 里 `apex` `dev` `proc` `sys` `system` `sdcard` 在宿主侧是 **mode 0000 的空目录** —— 它们就是 bind 挂载点本体。

**三个目录的实测结论**（路径更正：实际是 `/files/**linux**/ubuntu/…`，中间多一层 `linux`）：

| 目录 | 容器内 | 宿主侧 | 日常用不用 |
|---|---|---|---|
| `/root` → `<rootfs>/root` | `0700`（`.dsh` 也 0700） | u0_a543 | **主战场** —— DSH_HOME 在此 |
| `/tmp` → `<rootfs>/tmp` | **`0777`；注意没有 sticky 位** | u0_a543 | 用（临时交换） |
| `/var/tmp` | `0700`（≠ Ubuntu 默认的 1777） | u0_a543 | 基本不用 |
| `/home` | `0700`，**完全空的** | u0_a543 | **不用** —— 一切以 root 跑，`HOME=/root` |

### 决定 A：挂载布局（唯一形态）

```
宿主                                        容器内           用途
/data/local/dsh/data/.dsh      bind rw →   /root/.dsh       DSH_HOME（手改后须 fix-owner）
/data/local/dsh/shared         bind rw →   /mnt/shared      人与容器共享（MT 常来）
/data/local/dsh/inbox          bind rw →   /mnt/inbox       投递（dsh-ctl install 消费）
/data/local/dsh/log            bind rw →   /var/log/dsh     运维日志（ADR-014；MT 只读看）
/data/local/dsh/agents         bind rw →   /mnt/agents      DSH_AGENTS_HOME：壳写的状态托管块（ADR-023；归模块域）
/data/local/dsh/versions/<v>   bind ro →   /               版本层（MT 不该改）
/sdcard/Download/dsh           bind rw →   /mnt/public      公开导出面（无 root 也能看）
```

- **`/home` 保持空置**，不拿来放东西：容器内 `HOME=/root`，放 `/home` 只会让路径变长还得多一次 bind。
- **`agents/`（ADR-023 追加）**：承载 `DSH_AGENTS_HOME`（不显式设置时会被解析成 `~/.agents`）→ **必须显式指向它**。它归**模块域**（随 `/data/local/dsh/` 整体，卸载即清空），**不是** DSH_HOME 数据卷 → 壳写它**不触** ADR-017 决定 C 的红线；**用户自己的全局指令仍写在 `$DSH_HOME/AGENTS.md`**，壳不碰。
- **两段式公开面**：主目录 `/data/local/dsh/`（root-only —— `/data/local` 的 `--x` 权限天然挡住非 root 的 App）；
  公开面 `/sdcard/Download/dsh/`（无 root 可见）。
- ⛔ **红线**：`DSH_HOME` 与任何凭据**绝不进公开面**（ADR-011/014 同源）。

### 决定 B：外部编辑器（MT 管理器）的接入边界

- **它只需要添加一个根**：`/data/local/dsh/`（MT 以 root 模式运行即可进入）。
- **可写区仅三处**：`shared/` · `inbox/` · profile 的**四份文件**（`package.json` / `cordis.patch.yml` / `pnpm-workspace.yaml` / `compatibility.json`）。
- ⛔ **不该改**：`versions/`（只读版本层）· `active` 指针（只由 `dsh-ctl` 写）。
- ⛔ **不要直接编辑 rootfs 里的 `/root`** —— MT 是以**真 root** 写的，写进去就是 `0:0`，与 rootfs 其余文件（proot 下为 10543）不一致 → 触发决定 C。

### 决定 C：`fix-owner` 的目标值取决于运行时（硬规则）

| 形态 | rootfs 内文件在宿主侧应有的属主 |
|---|---|
| **proot**（现状 / DSHA 那套） | **`10543:10543`**（= 容器内 uid 0 映射到的宿主 uid） |
| **chroot**（本项目目标） | **`0:0`** |

- **不硬编码**：`dsh-ctl fix-owner` 按当前运行时解析目标值（可用 `<rootfs>` 的属主/安装方式判定）。
- **调用时机**：① `service.sh` 开机路径；② `dsh-ctl repair`；③ **外部编辑器手改之后**（文档要写明）。
- **同时校验挂载表**：期望为 `ro` 的挂载点必须确实以 `ro` 挂着 —— 防"后加的 `rw` bind 静默覆盖只读保护"。

### 决定 D：`inbox/` 投递约定（MT 管理器 = L2 人在环的现成载体）

- 约定：**用户用 MT 管理器把文件丢进 `inbox/`** → `dsh-ctl install` 消费（校验哈希 → 安装 → 记审计）。
- 这把 ADR-011 决定 B 的 **L2 人在环**落到了一个**具体载体**上：MT 管理器（root + 终端扩展包 `bin.mt.termex`，**还能直接跑 `service.sh`**，正是 ADR-013 的"终端 App"入口）。
- 于是"没有电脑也能操作"有了三个入口：**Root 管理器**（跑 `service.sh`）· **MT 管理器**（丢文件 + 终端）· **浏览器**（在线面）。

- **代价**：壳要维护"运行时 → 目标属主"的映射 + 挂载表校验；外部编辑器的自由度被**限制在三个可写区**（但这是必要的，否则"我是 root 却读不了"会反复出现）。
- **重审触发**：① 容器运行时从 proot 换成 chroot（目标属主随之变，映射表要更新）；② 出现比 MT 管理器更合适的带外编辑面；③ `/data/local` 的权限模型在别的 ROM 上不同（`--x` 的保护假设要复验）。

---

## ADR-017 模块卸载：唯一的钩子是 `uninstall.sh`；**模块域清空、用户空间保留**  ← **本次决定**

- **背景**：**卸载模块 ≠ 干净**。我们的东西大部分写在**模块目录之外**，而模块目录一删，就再没有执行时机了。
  生态惯例是模块自带 `uninstall.sh`，管理器在**删除模块目录之前**执行它 —— **这是唯一的清理时机**。

### 实测参考（本机，2026-10-16）

| 观察 | 说明 |
|---|---|
| 10 个模块里 **8 个带 `uninstall.sh`** | 惯例成立（`WorkSettingPro`、`ufi-manager` 没有；2026-10-18 新增的 `chroot-distro` 也没有） |
| `tricky_store/uninstall.sh`（9 行） | **先杀进程**（`pidof` + `kill -9`）**再删数据**；还顺手删了 `/data/media/0/TEESimulator`（**外置存储**上的诊断目录）→ 一次印证三件事：进程不会自动停、外置存储也要清、这活必须自己干 |
| `magic_mount_rs/metauninstall.sh` | 空实现（`exit 0`），而 `/data/adb/magic_mount/` 里留着 `config.toml` / `scan.ret` → **残留的活样本** |
| `/data/adb/ksu/module_configs/` | 有模块级配置（如 `magic_mount_rs`）→ 管理器**不一定清** |

### 决定 A：残留面清单（七处，逐条定归属）

| # | 位置 | 内容 | 谁清 |
|---|---|---|---|
| 1 | `/data/adb/modules/<id>/` | 模块本体 | 管理器 |
| 2 | **`/data/local/dsh/`** | **数据卷**：`data/.dsh`（DSH_HOME）· `versions/` · `log/` · `shared/` · `inbox/` · `active` | `uninstall.sh`（见决定 C） |
| 3 | `/sdcard/Download/dsh/` | 公开导出面（ADR-016） | `uninstall.sh`（**要问**，见决定 C） |
| 4 | `/data/adb/ksu/module_configs/<id>` | 模块配置（`manage.*`） | 管理器可能不清 → **要主动删** |
| 5 | ⚠️ **运行中的进程** | 壳守护 · DSH · chroot | **没人清，除非 `uninstall.sh` 做** |
| 6 | ⚠️ **bind 挂载** | 容器内的 bind（ADR-016 那六条） | 同上 |
| 7 | pnpm store | 若不在 DSH_HOME 内 | 同 2 |
| 8 | `/data/adb/service.d/<hook>.sh` | 开机钩子（**若采用**，见 ADR-019 决定 E） | `uninstall.sh` —— 否则留下**悬空钩子** |

> **第 5、6 条最容易被忽略**：模块目录被删了，但 `setsid` 起的守护进程**还活着**、bind 还挂着。
> 后果是"**幽灵服务**"——占着端口、挂载表里有条目、可执行文件却已被删（Linux 上 inode 尚存所以进程不死，但任何新 `exec` / `dlopen` 都会失败）。

### 决定 B：`uninstall.sh` 的五步顺序

```
1. 优雅停        dsh-ctl stop      ← 先给服务机会落盘收尾
2. 兜底杀        pidfile → kill -TERM → 等待 → kill -KILL
3. 卸 bind       逆序 umount（先内层，再外层）
4. 打印"还剩什么"  数据卷在哪、公开面在哪、怎么彻底清
5. 退出码        0 = 清理完成；非 0 = 有残留（管理器仍会删目录，所以必须靠这行字留证）
```

- ⛔ **不学 `kill -9`**：DSH 有会话持久化（`turn/end` 封口 + JSONL 原子世代发布），`-9` 会留下**未封口的 turn**。
  上游有崩溃修复（`interruptedTurnClosers`）能兜，但没有理由主动制造它。
- **必须先卸 bind 再删目录**：挂载活在命名空间里，删文件不会让已挂载点消失 → 否则留下"路径不存在但挂载表里有"的幽灵条目，还可能影响下次安装。

### 决定 C：**卸载即清空模块域，用户空间永久保留**（2026-10-16 使用者拍板）

**证据先行** —— 从设备上的 `ksud` 二进制里提取到的字符串表明，**"更新"与"卸载"在管理器层面是两条互不相干的路径**：

| 动作 | 管理器实际做什么 |
|---|---|
| **更新** | `mktouch …/modules/<id>/update` + **`rm -rf …/remove`**（主动清掉卸载标记）→ **不会执行 `uninstall.sh`** |
| **卸载** | 创建 `remove` 标记（`Failed to mark module` / `Failed to create remove file`）→ 执行 `uninstall.sh` |
| **安装（开机模式）** | `$BOOTMODE && MODDIRNAME=modules_update` —— 先暂存在 `modules_update/`，重启才接管 |

→ **原先"怕更新误触发清空"的顾虑被证据解除**，所以"卸载即清空"是安全的默认。

**决定**：

1. **模块域 = 卸载即清空**：`uninstall.sh` 删除 `/data/local/dsh/` 的全部内容（DSH_HOME · versions · log · shared · inbox · active · pnpm store）。
2. **用户空间 = 永久保留**：`/sdcard/Download/dsh/`（公开导出面）**不删**，只打印"它还在，要清自己清"。
   理由：那是**用户可见、用户自己管理**的目录，可能已被当成自己的文件夹用过。
3. ⛔ **反向红线**：`install.sh` / `service.sh` / 壳守护进程**一个字节都不许碰数据卷**（除版本驱动的幂等迁移外）。
   **只有 `uninstall.sh` 与显式的 `dsh-ctl purge` 能删数据。**
4. ⚠️ **删除必须发生在"真的删目录"那一步，不能发生在"打标记"那一步** ——
   管理器的卸载是**可撤销**的（`Undo module uninstall mark <id>`）；若在标记阶段就清空，用户一撤销就"模块回来了、数据没了"。
   **待确认**：`uninstall.sh` 的确切执行时机（打标记时 vs 下次开机处理标记时）。
   **防御性写法**：不确定时**只写标记不删数据**，把删除交给下次启动的壳 —— 那时 `remove` 标记若已消失，就说明用户撤销了，不清。
5. **跨版本提示仍要打印**：session 格式是**相邻链迁移**（缺一级即抛）→ 若将来改回"保留"策略，保留的数据**与版本绑定**，装更旧的版本**不保证能读**。

> **实施注记（2026-10-18）**：首个模块包的 `uninstall.sh` **只停服务 + 打印残留，不删数据** ——
> 依据就是上面第 4 条"不确定时只写标记不删数据"。删除动作等 `dsh-ctl purge` 与执行时机的确认；
> 现状与目标见 [module.md §4](./module.md)。

### 决定 D：复用 `dsh-ctl`，不写第二套逻辑

- `uninstall.sh` 同样受 **ADR-013 的脚本契约**约束（纯 POSIX `sh` · 非交互无 TTY · 环境钉死 · 离线）。
- 它 **`exec` `dsh-ctl`**（同一份代码），自己不重复实现停服务 / 卸挂载 / 清配置。
- **best-effort**：**绝不因为清理失败而阻止卸载** —— 失败要打印清楚并给非零退出码，让"还剩什么"可被人工接手。

- **代价**：壳多一个 `uninstall.sh` + `dsh-ctl stop/purge` 的实现，且要维护"**残留面清单**"（今后任何新增写盘位置都必须登记，否则就会漏）。
- **重审触发**：① 管理器提供更完整的卸载钩子（如卸载前后两阶段）；② 数据卷改成可整体删除的镜像文件（届时第 2 项的"保留还是删"变成"删一个文件"）；③ 出现会话数据必须跨大版本保留的真实需求（届时要做降级读取或导出格式）。

---

## ADR-018 拒绝降级：模块版本单调，降级只能"卸载后重装"  ← **本次决定**

- **背景**：使用者拍板 —— **不支持降级、拒绝降级**；要降级**只能先卸载模块，再安装旧版模块**。

### 依据（与已有 ADR 一致，不是新增特权）

| 已有条款 | 关系 |
|---|---|
| **ADR-010** | 已规定 `versionCode` **单调递增、永不回退**（"管理器按它比对更新，回退会导致更新 / 降级不生效"）；`version` 第 4 位（烘焙序号，ADR-025）同样**只增不减** |
| **ADR-003** | floor 闸门管的是"**DSH 版本**不得低于地板"；本条把同一条原则**推广到模块版本这一层** |
| **ADR-017 决定 C** | **卸载即清空模块域** → 于是"卸载后装旧版"天然就是**干净重装**。**两条政策是配套的** |

### 决定

1. **拒绝降级在安装期钩子里执行**（**不依赖管理器**，因为管理器通常不拦降级安装）。
   ⚠️ 实现放在 `customize.sh`，**不能叫 `install.sh`** —— 包根出现 `install.sh` 会被 Magisk/KernelSU 判成 legacy 模块（[pitfalls A23](./pitfalls.md)）。逻辑如下：

   ```
   旧 = /data/adb/modules/<id>/module.prop 的 versionCode   （模块未装则跳过）
   新 = 本 zip 里 module.prop 的 versionCode
   新 < 旧  → 拒绝安装（非零退出）
   新 = 旧  → 允许（幂等重装 / 修复安装）
   新 > 旧  → 允许
   ```

   → **拒绝条件只有"严格小于"** —— 这样"同版本重装"仍然可用（修一个装坏了的版本）。

2. **拒绝时必须打印可执行指引**（不能只报错）：
   - 说明原因（当前 `vN` → 目标 `vM`，**降级不受支持**）；
   - 给出**唯一路径**：先在 Root 管理器里**卸载模块** → 再安装这个旧版包；
   - ⚠️ 同时警告后果：**卸载会清空模块域数据**（会话 / 凭据 / 插件），
     但**用户空间 `/sdcard/Download/dsh/` 不受影响**（ADR-017 决定 C）。

3. **不提供任何"强制降级"开关**（环境变量、标记文件都算）—— 否则这条政策形同虚设。
   唯一的逃生舱就是"卸载 → 重装"，而那条路的**数据后果必须显式知情**。

4. **与 ADR-015 联动**：`dsh-ctl status` 显示"内置基线 vs 实际运行版本"的偏离；
   **偏离为负（实际更低）时标红** —— 那是"用户自己手装低版本 DSH"的路径
   （ADR-003 允许在 floor 以上自由升级，但**模块基线本身不允许回退**）。

5. **"卸载后装旧版"是唯一受支持的降级路径，且天然干净**（数据已清）
   → 因此**不需要实现任何向下迁移链**。

- **代价**：坏版本上线后，用户回退要付"**丢数据**"的代价。这是**明确接受的代价**，换来的是"**永远不用维护向下迁移**"。
- **重审触发**：① 出现"**必须保数据回退**"的真实场景（届时做 `dsh-ctl export/import` 作为**卸载前的出口**，
  但仍**不放宽 `install.sh` 的拒绝**）；② 上游开始对降级提供官方支持。

---

## ADR-019 公开入口与进程归属：三层结构，搬家必须发生在最外层  ← **本次决定**

- **背景**：ADR-013 定了"四入口 → `service.sh` 是唯一执行者"，但没回答"**起在哪**"。
  实测发现后者不是经验之谈，而是 **cgroup 决定的**：跑在 App 的私有 cgroup 里，App 一死就被连带清理。
  使用者提出出路：**加一层内置约定的公开入口脚本**，带参启动 `service.sh` —— 它同时也正好是"搬家"该待的位置。

### 实测证据（本机，2026-10-16）

**进程树（当前 DSHA 形态）**：

```
PID    PPID   USER       NAME
23268  1709   u0_a543    com.dsh.client      ← App 主体（zygote fork）
20792  23268  u0_a543    libproot.so
20795  20792  u0_a543    node (dsh web)      ← DSH 本体
21575  20795  u0_a543    node
```

**cgroup 对照（`/proc/<pid>/cgroup` + `oom_score_adj`）**：

| pid | 是什么 | `memory` cgroup | `oom_score_adj` |
|---|---|---|---|
| 23268 | com.dsh.client | **`/apps/com.dsh.client`** | 0 |
| 20792 | libproot.so | **`/apps/com.dsh.client`** | 0 |
| 20795 | node (dsh web) | **`/apps/com.dsh.client`** | 0 |
| 17059 | **com.dsh.client:shizuku** | **`/apps`** ← 不在 App 里 | 0 |
| 9430 | adbd（init 起的） | **`/`**（根） | **-1000** |

→ **`/apps/com.dsh.client` 是 App 私有 cgroup：App 死 → 组销毁 → 里面的进程被内核连带清掉。**
→ **A/B 对照**：`com.dsh.client:shizuku` 是**同一个 App 的另一个进程**，但经 root 起来（`PPid=1`、`uid=root`）、落在 `/apps` —— **同一个身份，结果完全不同，差别只在"谁 fork 的"**。

**cgroup 布局（搬家要写哪儿）**：

```
cgroup v1：/dev/memcg/apps/            ← 各 App 的父组
             ├── cgroup.procs          ← ★ 搬到这儿 = 脱离 App 专属组
             ├── com.dsh.client/cgroup.procs   ← 我们被困在这里
             └── bin.mt.plus.canary/   ← MT 管理器自己也有一个
cgroup v2：/sys/fs/cgroup/apps/cgroup.procs
```

⚠️ 但 `/proc/<pid>/cgroup` 显示同时受**四个 v1 控制器**管辖 —— **四个都要搬才算干净**：
```
5:freezer:/          4:memory:/apps/com.dsh.client      ← 最要命
3:cpuset:/top-app    2:cpu:/top-app
```

### 决定 A：三层结构（公开入口 = 内置约定层）

```
[调用者]   Root 管理器 / MT 管理器 / 壳
      │  带参数
      ▼
[公开入口] /data/local/dsh/bin/dsh-ctl      ← 内置约定层
      │     · 环境归一化（PATH / TMPDIR / HOME）
      │     · 参数校验
      │     · cgroup 搬家（best-effort，搬不动必须报）
      │     · 审计日志（谁 / 何时 / 什么动词）
      │  exec，原样传参
      ▼
[执行者]   service.sh                        ← 唯一执行者（ADR-013）
```

- **为什么多这一层**：**cgroup 是继承的** → 搬家必须发生在**任何长期进程被 fork 之前**。
  直接调 `service.sh` 就得把搬家塞进它开头（而开机正路根本不需要搬）；多一层入口，正好把"归一化 + 搬家"收在一处、**只在手动路径生效**。
- 动词与 ADR-013 对齐：`boot`（无参默认）· `start` · `stop` · `restart` · `repair` · `rebuild` · `status` · `logs` · `diag` · `install <file>` · `purge · upgrade <ver>`。

### 决定 B：搬家是 **best-effort + 必须报实情**

- 依次尝试四个 v1 控制器（`memory` / `cpuset` / `cpu` / `freezer`），能搬几个搬几个。
- ⛔ **搬不动必须显式报出来**（SELinux 可能拦其中某些）—— **绝不能假装成功**：
  `status` 显示"已脱离"而实际还在 App 树里，比不搬更糟。
- **正路不需要搬家**：开机由模块 `service.sh` 启动时，祖先链是 `init → magiskd/ksud → service.sh`，继承下来就是对的。
- **2026-10-18 补充实测（限定场景）**：从 Termux 走 `su -c` 起步时，cgroup 已在 `/apps`（`dsh-ctl` 报"无需搬"）。
  也就是说**搬家只对"App 内启动"有意义**（例：DSHA 容器落在 `/apps/com.dsh.client`）；本项目主路径它不是刚需，
  保留为 best-effort（搬不动就如实报）即可，**不要当它是必需步骤**。

### 决定 C：四条可测的验收判据（进 `dsh-ctl status`）

| 判据 | 期望值 |
|---|---|
| `PPid` | **1** |
| `uid` | **0** |
| `memory` cgroup | **不含 `/apps/<我们的包名>`**（显示实际值） |
| 终极验收 | **`am force-stop <app>` 之后端口仍可用** |

> ⚠️ **终极验收只能在模块形态下做** —— 并存期做会连同 DSHA 那套一起杀掉。

### 决定 D：入口路径的硬约束 —— **必须避开所有 bind 到容器内的子树**

- ⛔ 入口脚本**不能落在** ADR-016 那六条 bind 覆盖的子树里（`data/.dsh` · `shared` · `inbox` · `log` · `versions`），
  否则**容器内 AI 写的插件能改入口** → 改一次入口 = 下次重建时以 root 执行任意代码，**这是一条现成的提权路径**。
- → 入口放 **`/data/local/dsh/bin/dsh-ctl`**：在 MT 管理器已添加的那个根下面（用户省事），**但不在任何 bind 子树里**（容器内看不到）。

### 决定 E：`/data/adb/service.d/` 钩子 = **第八处残留面**（补 ADR-017）

- 若采用 `/data/adb/service.d/<hook>.sh` 做开机钩子（该目录是本机已有的**独立钩子机制**，`post-fs-data.d/` 里就有 `rezygisk.sh` 这个实例），
  它**独立于模块目录** → 卸载模块时**不会自动消失** → 留一个**悬空钩子**。
- → 要么不用它（让模块自己的 `service.sh` 做开机启动，这是更标准的做法），**要么必须由 `uninstall.sh` 清理**，
  并登记为 ADR-017 残留面清单的**第 8 项**。

### 决定 F：`origin` 标记（区分"手动救回来的实例"）

- pidfile 里带 `origin=boot` 或 `origin=manual`；
- `dsh-ctl status` **把 origin 与 cgroup 归属一起显示**（决定 C 那些判据的落地位置）；
- **下次开机由正路接管时，自动清掉 manual 标记**。

- **代价**：壳多一层入口脚本；搬家是 best-effort（**手动路径可能仍然不干净**，只能靠 `status` 显示实话）；入口位置被一条硬约束绑定（不得进入 bind 子树）。
- **重审触发**：① 本机 cgroup 从 v1 混合切到纯 v2（搬家目标路径要重取）；② 管理器提供"以非 App cgroup 启动脚本"的官方入口（届时可省掉搬家）；③ `/data/local/dsh` 的 bind 子树发生变化（决定 D 的边界要重算）。

---

## ADR-020 核心插件的形态：**独立发布 / 内部钉死**（解耦对外，紧耦合对内）  ← **本次决定**

- **背景**：我们要给容器加一个**核心插件**——收口 AI 的执行出口 + 提供"知识协议面"。
  参照物是 [dsh-ops](https://github.com/T-Auto/dsh-ops)（本机已装 v0.3.0，但它是 `os: win32` / `cpu: x64`，**在 Android arm64 上是"挂着但跑不起来"** → 它是**模式参照，不是可复用件**）。
- **使用者定调**：**独立发布维护（解耦）→ 其他环境皆可复用；但在本产品里它是核心产品之一 → 打包初期就内置指定版本，随模块与内置容器变更（紧耦合）**。

### 先例：上游自己就是这么干的

`vendor/` 里是 Cordis 全家（9 个包）：**上游 SHA 清单**（`vendor/README.md` 的 Manifest 表）+ **本地改动日志 24 条** + **同步流程** + 工具 `scripts/rescope-vendor.ts`；
`AGENTS.md` 的 vendoring policy 一句话 —— **"`vendor/` packages are pinned source copies"**。**这就是"独立发布 + 内部钉死"的现成范式。**

### 决定 A：一个真源

- **源码仓库是唯一真源**；内置的那一份是**产物快照**，**不是再抄一份代码**。
- 否则两条线各自漂移，最后没人知道内置的到底是哪一版（同 ADR-010 的单一真源原则）。

### 决定 B：钉死四样（缺一不可）

| 钉什么 | 内容 |
|---|---|
| **版本** | 精确 semver，**不用 range** |
| **来源** | commit SHA 或 release tag + tarball URL |
| **哈希** | tree sha256（照 dsh-ops 的 `.dsha-dependencies.json`：`manifestSha256` / `treeSha256` / `lockSha256`） |
| **peer 覆盖** | 它声明的 DSH peer 范围 **vs 本次 payload 的 DSH 基线版本** —— 必须落在范围内（ADR-015 里 `dsh-web-mobile` 的窄区间教训） |

### 决定 C：可对账 + 可自检

- **一份内置清单**随 payload 发布（上述四样 + 装载位置）。
- `dsh-ctl status` 必须显示**三者一致**：内置声明的版本/哈希 ↔ **实际加载的那一份** ↔ profile 里引用它的形式。
  不一致 = "payload 被动过" **或** "用户换成了外部版" —— **两种都要能看出来**。

### 决定 D：内外分层（解耦与紧耦合能同时成立的**唯一**办法）

```
┌─ 通用层（跨环境可复用）
│    工具 · 协议面（x-prompt-sections）· 权限声明（permissions[]）· 策略对齐
│    └ 只依赖 DSH 公开契约：peer 包 + dsh-plugin.json + sandbox policy
└─ 绑定层（只在我们的产品里启用）
     与壳 / cgroup / 挂载白名单 / dsh-ctl 的对接
     └ 做成组件开关，默认关；我们打包时打开
```

- 平台判定照 dsh-ops 的 `x-components`（每组件带 `platforms` / `architectures`，不匹配就不加载）。
- **我们要加的第二个维度**：不只"平台匹配"，还要"**宿主具备不具备绑定层**"——没有壳环境时绑定层自动缺席，通用层照常工作。
- **关键**：解耦与紧耦合的差别**只发生在开关上，不发生在代码里**。

### 决定 E：`origin` 标识（两个形态必须可区分）

- 版本标识区分 `origin=bundled | external`；`dsh-ctl status` 显示它。
- **与 ADR-019 决定 F 的 `origin=boot | manual` 用同一套措辞**（那个管"服务怎么起来的"，这个管"插件从哪来的"）。

### 决定 F：**收口清单是配套必需品**——新插件是第 8 个出口，不是取代前 7 个

**实测（本机 live 树 157 个条目）**，与"执行出口"相关的至少有：

```
tool-bash   tool-bash-persistent   tool-fs   tool-fs-search   terminal-bash
dsh-ops-bash & powershell 7        dsh-ops-file
间接：tool-web（能下载）· tool-subagent（子代理自己会干活）· tool-workflow（能跑代码）· skill-filesystem（能读文件）
```

→ **要真收口，必须同时把旧 row 禁掉** —— 那是 **profile 层的组合动作**（ADR-012 决定 C：profile 是唯一真相），插件自己做不到。

**收口清单（草案，逐项可验证）**：

| row | 处置 | 说明 |
|---|---|---|
| `tool-bash` · `tool-bash-persistent` | **禁** | 核心出口，由新插件取代 |
| `tool-fs` · `tool-fs-search` | **禁** | 由插件的文件工具取代 |
| `terminal-bash` | **禁** | 持久终端同样是出口 |
| `dsh-ops-*` | **按平台** | 本机 win32 不可用（ADR-015 同类处理） |
| `tool-web` | ⚠️ **待定** | 下载会写盘 → 需与"可见世界"白名单一起评估 |
| `tool-subagent` · `tool-workflow` · `skill-filesystem` | ⚠️ **待定** | **间接出口**：子代理/工作流会自己跑工具、技能能读文件 → 收口不完整就等于没收 |

**验证方式**：`dsh --profile <name> --dump-config` 直接看每个 row 的 `disabled`。

- **代价**：多了一个要跟的上游项目 + 一套"内置清单/对账"的维护；收口清单里那几项"待定"不解决，收口就是**名义上的**。
- **重审触发**：① 该插件上游停止维护（届时自维护 fork）；② 它声明的 DSH peer 区间不再覆盖我们的基线；③ `tool-subagent` / `tool-workflow` 的间接出口被证明无法收口（届时要么接受，要么禁用它们并承担能力损失）。

---

## ADR-021 凭据分层与降权：token 出容器 + AI 非 root + 出网判据  ← **本次决定**

- **背景**：威胁模型 §6.1（凭据暴露面）与 §6.3（出网策略是空词）是当时唯二"真的空着"的口子。
  下决定前先扒清了**虚拟屏的实现**——因为使用者指出"虚拟屏靠着和 DSH 同一个凭证才能运行"。

### 扒出来的事实（`/root/dsha-tool-vscreen/lib/server.cjs`，84 行）

虚拟屏插件是一个 **MCP server over stdio**，暴露 14 个 `android_vscreen_*` 工具。关键两行：

```js
// :59
const url = 'http://127.0.0.1:3090/app/vscreen/' + route;      // 打到 DSHA 桥
// :75
const token = (await readFile('/root/.dsh/.bridge_token','utf8')).trim();
const response = await fetch(request.url, {...headers: {..., 'X-Token': token}});
```

→ **它读的就是 `/root/.dsh/.bridge_token`**，与 `adb-shell.py` 用的是**同一个文件、同一个 token**。
**所以"虚拟屏与设备 shell 共用同一个桥凭证"不是猜测，是硬需求** —— 把它抽走，两个能力直接死。

### 决定 A：凭据分两类，分别处置（先前被混为一谈）

| 凭证 | 位置 | 泄露后果 | 处置 |
|---|---|---|---|
| **模型 API key** | `~/.dsh/.credentials.yaml`（223 B） | 花钱 + 可读他人对话 | 降权后由 0600 保护（决定 C） |
| **设备桥 token** | `~/.dsh/.bridge_token`（**32 B 明文**） | ⚠️ **拿到设备操作权**（读屏 / 点按 / 截屏 / 启停应用 / **虚拟屏**） | **移出容器**（决定 B） |

> 之前之所以看着像一条问题，是因为把两者当成了一种东西。**第二个危险得多**：它不是"花钱"，是"对这台手机的操作权"。

### 决定 B：token 出容器

- `.bridge_token` **不再落在容器 rootfs 里**；改为**宿主在启动特权子进程时注入**（env 或私有 fd）。
- 虚拟屏与设备 shell **照常工作** —— 因为按 **ADR-005**，它们的执行侧本来就在**宿主的特权 helper** 里（"DSH 侧 `dsh-tool-*` 插件 + 宿主特权 root helper，通过端口/HTTP 对接"）。
  → **设计意图早就在，缺的只是这一句"token 文件不进容器"。**

### 决定 C：AI 降权（本 ADR 里**收益最大、成本最低**的一条）

- **实测**：`.bridge_token` 与 `.credentials.yaml` **都是 `0600` 属主 root**。
- **但**：容器内的 AI **现在就是以 root 跑** → **0600 形同虚设，全员可读**。
- **决定**：容器内的 AI 以**专门的非 root uid** 运行；特权消费方（需要 token 的桥调用）仍在特权侧。
- **这一条是前提**：没有它，决定 A/B 的"0600 保护"和"token 出容器"都只是心理安慰 —— 因为 root 能读任何文件、也能读别的进程的 `/proc/<pid>/environ`。

### 决定 D：出网策略 —— 把空词换成"**可检查的判据 + 诚实的不设防**"

- **事实**：chroot **不隔离网络**（容器与宿主共享 netns）→ **在 chroot 形态下，出网目的地无法强制**（root + 共享 netns）。
- **所以不写假策略**，写成两条：

| | 内容 |
|---|---|
| **可检查的** | 容器内**不得有绑 `0.0.0.0` / `::` 的监听**（ADR-006 `local` 档）。`dsh-ctl status` 应报告；有则告警（当前 DSH 3080 与 DSHA 桥 3090 **都只在回环** ✅） |
| **不设防的** | **出网目的地**（技术上强制不了）→ 明确列入威胁模型 §5「不设防声明」，**不当它是保护** |
| **升级触发** | 真需要强制出网白名单 → 那是 **netns** 的事 → 归**阶段二**（ADR-001 已裁，触发条件见 pitfalls §B1） |

> 顺带记录一个**审计面缺口**：容器内读 `/proc/net/tcp` 是 **Permission denied**（Android 限制 + proot 下真实 uid 非 0）
> → **代理人无法自证监听面**，只能从宿主侧查。

### 决定 E：与已有 ADR 的关系

| ADR | 关系 |
|---|---|
| **ADR-004** | 只分离了 `DSH_HOME`；本条补**第二层：分离"设备凭据"** |
| **ADR-005** | 本条是它的**必要条件**——能力在宿主侧，凭据自然也留宿主侧 |
| **ADR-011** | 那条管"**能不能装插件**"；本条管"**装进来之后能读到什么**" |
| **ADR-016 / ADR-019** | 降权是"进程归属"的**第三个维度**（前两个是 `PPid` 与 cgroup） |

- **代价**：容器内的 AI 不再以 root 跑 → **某些需要 root 的操作要显式走特权通道**（正是 ADR-005 说的"能力插件 + 特权 helper"），短期会多一层调用；出网"不设防"是**诚实的退让**而不是保护。
- **重审触发**：① 上游把桥凭证改成"宿主注入 + 可校验"（届时 ADR-011 的 L2 可以少一条假设）；② 阶段二上 netns → 出网白名单从"不设防"升级为"可强制"；③ 出现"AI 必须以 root 跑"的真实需求（届时降权要重新评估）。

---

## ADR-022 内置 DSH 基线只追 RC 通道：alpha 一律不碰  ← **本次决定**

- **背景**：ADR-015 定了"**基线抬升随模块一起发**"（决定 3 的 (b)），但**没定"抬哪一份"** —— 上游现在同时挂着两条预发布通道。
  **实测（2026-10-16）**：本机跑的是 `0.2.0-rc.2`（DSHA 内跑的也是它），而上游 HEAD 已经是 `0.2.1-alpha.5`，npm 的 `alpha` dist-tag 也在动。
  → 照"取最新"的直觉走，**第一次抬基线就会把 alpha 烘进只读层**、并把它钉成 `floor`。
  **使用者拍板：只追 RC，alpha 不碰。**

### 决定 A：候选集 = RC 通道（写成白名单，不写黑名单）

| | 规则 |
|---|---|
| ✅ **进候选集** | `-rc.N` 通道的发布（例：`0.2.0-rc.2`） |
| ⛔ **不进候选集** | 一切 `-alpha.*` |
| ⛔ **同样不进** | 其它非 rc 的预发布通道（`-beta` / `-dev` / canary 之类，上游将来若出现）—— 按**通道白名单**写，否则这条规则一秒就漏（同 ADR-014 决定 C 的"脱敏只许白名单"） |

**可机器判定的判据**（进选取 / 发版流程，别靠人记）：

```
预发布候选必须匹配 ^\d+\.\d+\.\d+-rc\.\d+$      ← 只认 rc
命中 -alpha / -beta / -dev …                        → 直接拒绝
```

→ 这条同时是 [baseline/bake-ledger.json](../baseline/bake-ledger.json) 的 `baked` 与 `manifest` 的 `baked` / `floor` 的**准入闸门**（ADR-025 起第 4 位由台账派生，这里仍是上游）。

### 决定 B：与 floor 闸门的分工（防打架）

| 条款 | 管的是 |
|---|---|
| **ADR-003（floor-only）** | "**用户能跑哪一份**" —— 只设下限、无上限，floor 以上自由升级 |
| **本条** | "**我们内置哪一份**" —— 候选只来自 RC 通道 |

- 二者**不矛盾**：**用户自己手装 alpha 仍然允许**（ADR-003 未变），壳只按 ADR-015 决定 5 / ADR-018 决定 4 在 `dsh-ctl status` 里把偏离**显示出来**（写明"用户自装：alpha 通道"）。
- 反向也成立：因为 `version` 第 4 位 / `manifest.baked` / payload 三者**同源**（ADR-025：都由台账派生），**只追 RC 自动约束了 floor** —— 不会出现"floor 钉在 alpha 上"。

### 决定 C：正式版（无预发布后缀）不在本条约束内

- 本条筛的是**预发布通道**。上游若发正式版（`0.3.0` 这种），**不按本条处理** —— 走 ADR-003 / ADR-015 既有的"上游发布稳定版本"重审触发**单独评估**。
- 本条不替那两条 ADR 决定任何事，只保证一条：**在预发布里，我们只认 rc。**

### 依据：为什么"不碰 alpha"是划算的

1. **`floor` 不可降**（ADR-018；降 floor 只能刷模块）→ 把 alpha 抬成 floor 等于给设备钉一个"**上游施工中**"的下限，**而且回不了头** —— 一笔**不对称**的赌注。
2. **alpha 与 rc 的语义不同（上游自己定义的）**：rc = 上游宣告的**候选发布**；alpha = 上游的**当前开发线**（HEAD 就在那儿）。
   ADR-001 / ADR-015 已经因为"DSH 自身还在 0.2.x-rc"而**选择不跟着上游跑** —— 这条理由对 alpha **只会更强**。
3. **抬一次 = 发一次版**：payload 里的 DSH 是 **439 MB** 量级，还要打哈希 + 三处版本对齐（ADR-010 / ADR-020 决定 B·C）→ 成本决定了我们**不适合追开发线**。
4. **一个必须写下来的 semver 陷阱**：`0.2.1-alpha.5` 在 semver 里**大于** `0.2.0-rc.2`（先比主次修订位）。
   ADR-003 已记过"**别用字符串比较**"，这里补一条：**也别只看数值大小** —— 本条判的是**通道**，不是**谁的数字大**。

### 抬 RC 时的例行检查（沿用，不新增）

- `dsh-web-mobile` 的 peer 区间（ADR-015 已列为**例行检查项**，不是风险项）；
- 核心插件声明的 DSH peer 覆盖必须落在新基线范围内（ADR-020 决定 B"钉四样"之一）。

- **代价**：拿不到 alpha 里的新修复与新特性，直到它们进 RC（可能落后数天到数周）；上游若长期只发 alpha，我们会**停在旧 RC**（见重审触发）。
  **明确接受：宁可慢，也不把一个施工中的基线钉进设备。**
- **重审触发**：① 上游停发 RC 通道（只发 alpha / 只发正式版）；
  ② 出现"**只有 alpha 里修了的安全洞**"且 RC 迟迟不来 —— 届时走**临时层**（[research §5.3](./research.md)：用 `dsh-update` 装进 `user/` 层、用完可弃），**⛔ 不动 `floor`、不动 payload**；
  ③ 上游把 rc / alpha 改成**并行两条不同的版本线**（则"挑最新 RC"这条规则要重写）。

---

## ADR-023 用户手动抬升 DSH：推荐 0 插件更新、RC 优先、alpha 强制安全模式  ← **本次决定**

- **背景**：ADR-003 允许自由升级（**无上限**），ADR-022 决定 B 也明确写了"**用户自装 alpha 仍然允许**，壳只把偏离**显示出来**"。
  但**"显示偏离"只是报信，没有定处置** —— 用户自己把 DSH 抬上去之后：**插件怎么办、数据怎么办、谁告诉用户、AI 怎么知道？** 本条补齐这整条路径。
- **使用者拍板**：① 手动抬升时**优先推荐 0 个内置插件更新**（保数据安全）；② **只推荐 RC**；③ **alpha 允许，但强制禁用所有第三方插件（包括模块内置的）** ＝ 安全更新。

### 实测依据（2026-10-16，本容器；两条都改变了设计）

**① 换 dsh 本体 = 连带换掉整棵全局树**（这条推翻了"插件没更新就没事"的直觉）

| 查什么 | 结果 |
|---|---|
| `@deepseek-ai/dsh` 直接依赖 | **82** 条（79 自研 + 3 外部：`commander` / `js-yaml` / `node-addon-require-builtin`）；其中 `dsh-client-*` **只有 2 个** |
| 那批 client 包从哪来 | `@deepseek-ai/dsh-web-app` 直接依赖 127 条，其中 **58 个**是 `dsh-client-*`（传递依赖带进来） |
| 全局树实际内容 | **303 个 `@deepseek-ai/*` 包，其中 292 个版本精确等于 `0.2.0-rc.2`**；`dsh-client-*` **62 个，全部 = `0.2.0-rc.2`** |
| profile 的 `node_modules/` | **完全没有 `@deepseek-ai/`**（只有第三方插件的 `link:` 符号链接）→ 插件的 peer 包**只能来自这棵树** |

→ **结论**：插件代码不动（"0 个更新"），**它脚下的 API 照样被整体搬走**。
所以**"适配判定"必须按运行时实际解析到的版本做，不能按"插件有没有被更新"推断**。
（ADR-015 那句"peer 区间不覆盖只是适配问题"针对的是**我们自己抬基线**；对**用户手动抬升**，改那 8 行 peer 不是正确动作 —— 壳要给的是**三档处置**。）

**② 版本层是只读的 → 手动抬升只能落在可写 `user/` 层**（ADR-009 + research §5.2/§5.3）

→ 免费得到一件事：**抬升天然是一个可拦截的事务**（壳是唯一执行者），不是"用户手一抖就乱"。
⛔ 但**不假装能拦住绕过**（root 容器里没有不可变，research §5 已诚实声明）→ **事后对账是必需品，不是可选项**。

### 决定 A：状态机（一个判据、一个实现、一处显示）

判据**只认预发布通道，不比大小** —— `0.2.1-alpha.5` 在 semver 里**大于** `0.2.0-rc.2`（先比数值位），字符串比较更不行（ADR-003 / ADR-022 都记过这个坑）。

| 状态 | 判据（机器可执行） | 插件处置 |
|---|---|---|
| `bundled` | `running == baked` | 全部启用 |
| `manual-rc` | 预发布首段 = `rc`，且 `running ≠ baked` | **0 更新**；逐个做 peer 判定：范围内 → 启用；**范围外 → 默认禁用**（fail-closed），豁免**必须人在环**（ADR-011 L2） |
| `manual-alpha` | 预发布首段为 `alpha`（或**任何非 rc 的预发布**） | ⛔ **强制禁用全部第三方插件**（含模块内置的 ＝ 我们的核心插件）→ 只剩**上游裸 DSH** ＝ **安全模式** |
| `below-floor` | `running < floor`（prerelease-aware 比较） | 沿用 ADR-003 / ADR-018：**拒绝启动** |
| `unknown` | 通道解析不出 | **按 alpha 处理**（fail-safe 到最保守） |

- **执行者**：`dsh-update`（装的时候）→ `service.sh`（每次启动对账）→ `dsh-ctl status`（显示）。**同一个判定函数，只有一个实现** —— 正是 DSHA 那套"策略双实现、两条通道两种结果"（`AUTH-03`）要避免的形状。
- **安全模式怎么执行**：走 **ADR-012 决定 B 的带外面**（清 `bundles` / 写 `disabled: true` 行）—— 因为 alpha **可能根本起不来**，那时候**在线面是不存在的**。

### 决定 B："0 个内置插件更新"的准确定义与证明方式

**定义**：抬升事务里**只允许出现 dsh 本体（全局树）的差分**。以下**一个字节都不动**：
`/root/dsha-*`（内置第三方插件）· `plugin-src/*` · profile 的 `package.json` 依赖行 · 我们的核心插件。

**为什么（数据安全）**：**插件是"写数据的那一层"**（profile 四份文件 + 会话投影，ADR-012 决定 C / D.2）。
把"换运行时"和"换插件"捆在一次动作里 → 出事**无法归因**、回退**要多退一步**。**一次只动一个变量。**

**怎么证明**（沿用 ADR-020 决定 C 的"可对账"形态）：抬升前后各取一次快照（插件目录的 `package.json` 版本 + 内容哈希）→
**差分里出现插件条目 ＝ 本次抬升违反了本策略** → 记日志 ＋ **强制进安全模式**。

**与 ADR-020 的关系**：不冲突，是同一条。内置插件本来就**钉死**（版本 / 来源 / 哈希 / peer 四样）→ "推荐 0 更新"其实等于"**保持钉死**"；本条补的是"**用户升级路径上也不许动它们**"。

### 决定 C：提醒用户 —— 三个时刻、四条通道，**都不依赖 DSH 活着**

| 时刻 | 通道 | 形态 |
|---|---|---|
| **抬升前** | `dsh-update` / `dsh-ctl upgrade` 的**策略卡** | 三行：本次**会**做什么（换哪个版本）· **不会**做什么（0 个插件更新、不碰 profile）· 失败怎么退（指针回滚）；**需确认** |
| **抬升后首次启动** | `service.sh` 的对账 ＋ **一行机器可读标记** | `DSH_MODE=alpha-safe` · `DSH_BASELINE_DRIFT=<running>|<baked>`（沿用 ADR-013 决定 B 的 `DSH_*` 标记风格）；同时写 `run/state.json` |
| **日常可见** | ① `dsh-ctl status`（新增 `mode=` 一行）② `dsh-ctl logs` | 人主动看；手机上用 Root 管理器 / MT 管理器就能跑 |
| **可选增强** | ① root 侧 Android 通知（`cmd notification`）**【待验证】** ② 壳反代层的横幅（需 HTML 注入，**脆弱**，只作可选项） | ⛔ 不新增"必须开着 App"的通道（ADR-012 的 **App 可缺席**原则） |

**每条提醒都必须带"怎么回去"**：归位 ＝ **停用 `user/` 层、回落 `baked`**（数据不动；research §5.3 已有此流程）→
提醒里**直接给那一条命令**，别让用户自己拼。

### 决定 D：让 AI 适配 —— **两条通道，其中一条不依赖任何插件**（本 ADR 的关键判断）

**D.1 无插件通道（alpha 安全模式下的唯一通道）**：`<agentsHome>/AGENTS.md`

- **上游机制【已验证】**（`packages/context/agent-instructions/README.md`）：首个请求会带一条 **durable baseline** 消息，
  内容链 ＝ `$DSH_HOME/AGENTS.md` → `<agentsHome>/AGENTS.md`；`dsh-base` 默认启用（`maxBytes: 65536`）。
- **做法**：壳把一段**托管块**写进 `<agentsHome>/AGENTS.md`；**`DSH_AGENTS_HOME` 必须显式指向壳拥有的路径**
  （顺带落实 ADR-004 那条"两个实例不得共享 `~/.agents`" —— 以前只写了红线，没写落地）。
- ⛔ **体积纪律**：总预算 65536 B，而规则是"**更宽的文件先被整份省略**，最具体的文件才被截断" →
  托管块**必须小（目标 ≤ 600 B）**，否则会把**用户自己的指令**挤掉。
- **生效时机要写清楚**：**下一个会话 / 会话恢复时**对账 → **不会立即改写正在跑的会话**（免得出现"为什么 AI 还不理我"）。

```text
<!-- Zodiac-Quill-Saga:managed:begin 由壳生成，勿手改 -->
本机 DSH 运行状态（自动生成）：
- 运行 0.2.1-alpha.5（手动抬升）· 内置基线 0.2.0-rc.2 · 通道 alpha ⇒ 安全模式
- 第三方插件（含内置）已禁用：dsh-web-mobile · dsh-tool-vscreen · …（其工具不存在）
- 纪律：① 工具集以运行时实际注册为准，不按记忆调用；不确定先只读探测
        ② 不要自行改 profile、放宽版本约束或安装插件
        ③ 版本相关故障：报状态（dsh-ctl status），不要改配置
<!-- Zodiac-Quill-Saga:managed:end -->
```

**D.2 有插件时的通道**：核心插件（ADR-020）贡献一段 prompt section（形制照 `dsh-ops` 的 `x-prompt-sections`）。
⚠️ **但它在 alpha 安全模式下被禁用** → 所以 **D.1 必须独立存在**，不能只做 D.2。

**D.3 一句主张**：**适配 ≠ 给 AI 一份版本差异表**。表会过期，纪律不会。
正解是告诉它"**别信记忆、以运行时探测为准、别自己改约束**" —— 这也是本条能长期成立的原因。

### 决定 E：与已有 ADR 的分工 ＋ 连带改动

| ADR | 关系 |
|---|---|
| ADR-003 / 018 | 不变：floor 只设下限；本条**不设新上限**，只定"抬上去之后怎么处置" |
| ADR-022 | **共用同一个通道判据**（`^\d+\.\d+\.\d+-rc\.\d+$`）：ADR-022 管"**我们内置哪一份**"，本条管"**用户抬上来之后怎么办**" |
| ADR-015 决定 5 | 从"status **显示**偏离"升级为"显示 **＋ 处置**" |
| ADR-012 | 安全模式**只能**用带外面执行（alpha 可能起不来） |
| ADR-011 L2 | 豁免 / 放行**必须人在环**；AI 不许自己放宽 peer（ADR-021 降权后它本来也改不了 profile） |
| ADR-016 | **挂载表 ＋1 行**：`/data/local/dsh/agents` → `/mnt/agents`（承载 `DSH_AGENTS_HOME`）；它归**模块域**，**不是** DSH_HOME 数据卷 |
| ADR-013 | `dsh-ctl` **动词 ＋1**：`upgrade <ver>`（唯一推荐入口）；托管块与 peer 判定由**同一个生成器**刷新 |

**两条边界**（写清楚，避免越界）：
- 壳写托管块**只动标记区间内**；`$DSH_HOME/AGENTS.md` 是**用户自己的全局指令**（数据卷），壳**不碰**。
- 安全模式**不删任何插件包**（只禁用声明）→ 退出安全模式 ＝ 恢复声明，**`node_modules` 不用重装**（同 ADR-012 D.2 的"残留是惰性的"）。

- **代价**：① alpha 下用户拿到的是**裸 DSH**（没有手机端 UI、没有设备能力插件、没有虚拟屏）—— 功能明显缩水，**这是故意的**（安全更新优先）；
  ② "0 插件更新"会让插件**落后于它自己的上游**，想更新插件必须**另开一次事务**；
  ③ fail-closed 的 peer 判定会**误伤**（某些纯 UI 插件区间写得窄、实际能跑）—— 代价是"用户要申请一次豁免"，换来的是"**不静默跑未适配组合**"；
  ④ 托管块是壳写进模型上下文的**唯一一处**，必须守体积与"只写事实"的纪律。
- **重审触发**：① 上游把 client 包改成 **seam / provider 形态**（插件不再逐包 pin）→ peer 判定可放宽；
  ② "用户手动抬升"变成**常见路径**（说明我们的模块节奏太慢）→ 该反思 **ADR-015** 的节奏，而不是继续加护栏；
  ③ `dsh-agent-instructions` 的加载语义变了（路径链 / 预算 / 生效时机）→ D.1 要换通道；
  ④ 用户要求"alpha 下也要能用插件" → **拒绝**，除非上游给出 rc。

---

## ADR-024 payload 交付形态与首启自举：模块 zip 永远不装 payload  ← **本次决定**

- **背景**：目标形态是"**刷模块 → 重启 → 能用**"。而现在这条 demo 路径要求人手装 chroot-distro、手选发行版、手装 python —— 这不能当交付形态。问题归纳成一句：**1 GB 级的 payload 怎么到设备上**。
- **结论先说**：⛔ **payload 永远不进模块 zip**；改成**首启自举（bootstrap）**，由壳**触发 / 执行 / 监督 / 观测**。

### 为什么不能塞进 zip（三条，任一条都足以否决）

1. **体积翻倍**：根管理器先把 zip 解到 `/data/adb/modules_update/<id>/` 再改名 → 安装期同时存在 zip 与解压副本，1 GB 变 2 GB；且每次模块更新都要重下。
2. **安装器环境不可靠**：`install.sh` 跑在 root 管理器的受限环境里，没有断点续传、没有进度、超时无人管 —— 1 GB 在 Installer 里解压是"必须一次成功"的赌局。
3. **与已有决定冲突**：[guide §4](./guide.md) 已写"DSH 本体 439 MB **绝不能塞进模块 zip**"，[pitfalls A6](./pitfalls.md) 也记了同一条；payload 只会更大。

### 决定 A：模块 zip 只装"引导器"

内容固定为：`module.prop` · `service.sh` · `dsh-ctl` · `dsh-update` · `lib/`（含 `semver-gate.sh`）· `update.json` · 少量配置。**体积目标 < 1 MB**。
payload 是**独立产物**，有两种形态：Release 资产 / 本地文件。

### 决定 B：来源优先级（离线优先）

```
① 本地 inbox：/data/local/dsh/inbox/payload-<ver>.tar.gz（ADR-016 的投递面）
② inbox 没有 → 联网下载：GitHub Releases（ADR-015 的发布通道）
③ 都不行 → exit 30，不启动 DSH，也绝不假装成功
```

- `dsh-ctl bootstrap --offline`：**禁止 ②**，只认本地。
- payload 必须自带 `payload.json`：`{baked, node, pnpm, sha256, size}`；解压后还要拿容器内实际 `dsh --version` 与 `baked` 对账（对不上就拒绝 —— 防"层与 manifest 说的不是一回事"）。
- **不做增量**（见 [pitfalls B9](./pitfalls.md)）：整包替换更简单、更好回滚。

### 决定 C：四层分工

| 层 | 谁 | 职责 | 不许做 |
|---|---|---|---|
| 触发 | `service.sh boot`（开机）/ `dsh-ctl bootstrap`（手动）/ 模块更新标记 | 只判断"要不要自举" | 不下载、不解压 |
| 执行 | `service.sh bootstrap` → `dsh-update` | 下载 → 校验 → 解压 → 切指针 | 不动 `active` 之外的东西 |
| 监督 | `run/bootstrap.json` | 记录阶段 / 进度 / 错误，供崩溃恢复 | 不做决策 |
| 观测 | `dsh-ctl status` | 显示 `bootstrap: downloading 42%` 之类 | 不写状态 |

> 为什么必须由壳来做：bootstrap 期间 **DSH 还没起来** —— 任何依赖 DSH 的路径（插件、Web UI、AI）都不成立。这也是 ADR-005 "壳不做 Hook"的另一面。

### 决定 D：状态机与幂等（崩溃可恢复）

```
idle ──► downloading ──► verifying ──► unpacking ──► ready
            │               │              │
            └───────────────┴──────────────┴──► failed(code, retryable?)
                                                       │
                        下次 boot 从"最后一个完成的阶段"继续 ┘
```

- 每个阶段结束后**先落盘状态再进下一阶段**（写失败就停，不硬闯）。
- 解压走 **staging + 原子切换**：解到 `base/.staging-*/` → sha256 对账 → 改名 → 原子切 `active` 指针（ADR-009 的"先停后换"同样适用）。
- **两层（2026-10-18 裁决）**：`base/node/`（Node 层，不随 DSH 版本变）+ `base/dsh-<baked>/`（DSH 层）；`active` 只指向 DSH 层。
  Node 层已装且版本相同则**复用不重装** —— 这是两层相对单层的唯一实质收益（省流量 / 省解压时间），代价是 `manifest.layers` 有两行哈希、bootstrap 要多一步判定。
- 任何一步失败：`active` **保持不动**，用户仍能用上一个版本。

### 决定 E：三条设备侧硬约束

1. **下载器用 `curl`**（2026-10-18 修正）：设备 `/system/bin/curl` = 8.21.0（HTTP2/HTTP3、OpenSSL），
   断点续传 `-C -`、重试 `--retry 3`、失败判定 `--fail`。`busybox wget` 只在没有 curl 的 ROM 上作兜底（`/system/bin/wget` 不存在）。
2. **解压前查空间**：压缩包与解压副本会同时在，峰值 ≈ 2×；空间不足要**提前** exit 30，不许解到一半才炸。
3. **纯 POSIX sh**：判定与切指针都在 `service.sh` 里，不能借用容器里的 Python/Node（那时容器还没起来）。

### 决定 F：修订 ADR-013 的"离线"条款

ADR-013 决定 B 第 5 条原文是"**离线**：payload 从模块自带的副本解压，不联网"。**改为**：

> 默认离线可用；允许**一次显式或自动的网络自举**，且必须可禁用（`--offline`）。

其余五条契约（非交互 / 环境钉死 / 幂等 / 先停后换 / 可观测+退出码）**不变**。

### 决定 G：出网要记账

首启下载是**壳主动出网**，目的地是 GitHub Releases。ADR-021 已承认"出网目的地技术上强制不了" → 本条要在 [threat-model §6.3](./threat-model.md) 补一行：谁发起、何时、连哪里、能否禁用。**不假装它不存在。**

### 决定 H：用户动作与可见预期

| 步骤 | 用户做 | 系统做 | 耗时（估） |
|---|---|---|---|
| 1 | 刷模块 zip | 解包、落引导器 | 秒级 |
| 2 | 重启 | `service.sh boot` → 判断 payload 缺失 | 秒级 |
| 3 | 等 | 下载 / 校验 / 解压（或直接读 inbox） | 取决于来源 |
| 4 | 打开 `dsh-ctl status` 给出的 URL | 起 DSH、发布端口 | — |

`status` 必须能回答三个问题：**现在在哪个阶段 / 卡住的原因 / 还差多少**。

- **代价**：① 首次使用不是"刷完立刻可用"，要等自举；② 自举期间占 2× 空间；③ 多了一条出网面（要记账）；④ 多一个状态文件要维护一致性。
- **重审触发**：① payload 体积降到可接受（< 200 MB）→ 重评"塞进 zip"；② 上游给出稳定的 arm64 rootfs 直链 → 可简化成纯下载；③ GitHub Releases 在国内不可达成为常态 → 换源（并因此改 ADR-015）；④ 出现可靠的内置增量格式 → 再翻 [pitfalls B9](./pitfalls.md)。

---

## ADR-025 第 4 位改成「烘焙台账序号」，对着 baked 而不是 floor  ← **本次决定**

- **背景**：ADR-010 对第 4 位给过三个互相冲突的说法 —— 与 `manifest.floor` 对齐、与 `floor` 及 payload 的 `baked` 三者一致、与 `baked` 一致；
  而 [baseline §7](./baseline.md) 又明确"floor 是否跟着抬由你决定"，即 **`floor ≠ baked` 是合法状态**。
  今天三者同值（`0.2.0-rc.2`）只是巧合，第一次"只抬 floor"或"只换 baked"就必须三选一。
  同时 `V_DSH` 是**人肉同步**的：`tools/gen-version.py` 只校验它是整数，从不校验它与 `DSH_BAKED` 的对应关系 —— 写错不报错，静默进产物。

### 决定 A：第 4 位 = 烘焙事件序号，对着 `baked`

- 用户看管理器卡片想知道的是"**我容器里装的是哪份 DSH**"，那是 `baked`；`floor` 是"允许的最低"，它变了你装的东西没变。
- ADR-022 已把「第 4 位 / `manifest.baked` / payload」绑成一组，跟 floor 绑是孤例。
- `floor` 在 manifest 里已有自己的表达（完整 semver），不需要在版本号里再出现一次。

### 决定 B：baked 的唯一来源 = 只追加的烘焙台账

新增 [baseline/bake-ledger.json](../baseline/bake-ledger.json)：

```json
{ "schema": 1, "bakes": [ { "seq": 1, "baked": "0.2.0-rc.2", "date": "2026-10-17", "note": "首个基线" } ] }
```

- `seq` 就是 `version` 第 4 位；最后一条的 `baked` 就是 `manifest.baked`（生成器另写一个 `baked_seq` 供展示与排障）。
- **`tools/version.env` 删除 `V_DSH` / `DSH_BAKED`**；基线参数（`DSH_FLOOR` / `DSH_RECOMMENDED` / `NODE_FLOOR`）移到 [baseline/dsh.env](../baseline/dsh.env)。
- 换基线 = 在台账末尾追加一行。**不记账就发不出去**（生成器 exit 2）。

### 决定 C：四条机器校验（fail-closed）

1. `seq` 必须从 1 连续递增（跳号 / 从 0 开始 / 非整数 → exit 2）；
2. 每条的 `baked` 必须是合法 semver（复用 versioning §9 的实现）；
3. `floor ≤ baked`、`recommended > baked`（原有，不变）；
4. 台账里出现**非升序**或**重复** `baked` → **只告警、不拒绝** —— 回滚是合法的（它是"又烘焙了一次"，不是"版本变低了"）。

### 决定 D：同一 baked 重新打包 → 不记账，抬补丁位

"第 4 位变 = DSH 换了"必须永远成立。字节变了但版本没变（重打层 / 换压缩参数 / 改 wrapper）走第 3 位。

### 决定 E：`version` 永不参与任何比较

- 模块更新的**唯一**排序键是整数 `versionCode`（[update.json](../update.json) 与生成器校验的都是它）。
- 第 4 位是计数，第 1~3 位是人读的结构 —— 两者都不参与"谁更新"的判断。
- 理由：`1.0.0.10` 在字典序上**小于** `1.0.0.9`，第 10 次发版就会翻车。

### 决定 F：修订 ADR-010

ADR-010 中"第 4 位与 `floor` 对齐 / 与 `floor` 及 `baked` 三者一致"**作废**，以本条为准：

> 第 4 位 = 烘焙台账 `seq`，对着 `baked`；`floor` 不进版本号。

ADR-010 的其余条款（四位结构 / `versionCode` 独立计数 / 单一真源 / `managedFeatures`）**不变**。

### 决定 G：验证不是靠记性

新增 [tools/test-versioning.py](../tools/test-versioning.py)：20 条断言覆盖"派生 / 跳号 / 从 0 开始 / 非法 semver / floor 高于 baked / recommended 不高于 baked / 残留旧字段 / 回滚告警 / 重复告警 / 台账缺失 / 漂移检测"。
其中**拒绝类**断言全部是"故意写坏 → 必须 exit 2"，防止这道检查变成永远绿的装饰。

- **代价**：① 多一个只追加的文件；② 每次换基线要记得记账（忘了会被生成器拦住，不是静默漂移）；③ 回滚时第 4 位仍会 +1，"第 4 位更大 = DSH 更新"只在**正常前进**时成立。
- **重审触发**：① 上游给出稳定且可解析的数字版本码 → 重新评估"编码 vs 计数"；② 出现"必须在不升第 4 位的前提下换 baked"的硬需求 → 说明计数语义不够用；③ 管理器开始直接展示 manifest → 第 4 位的展示价值下降，可评估去掉。

---

## ADR-026 启动前跑版本闸门：`decide` 判定，壳处置  ← **本次决定**

- **背景**：闸门（向量表 + 三份实现 + 真机闭环）此前**只有库，没有消费者** —— `service.sh` 里 `manifest` 出现 0 次，
  所以 `floor` 一直只是"文档里的规则"：低于 floor 的层照样启动，alpha 层照样进，谁也不知道。
  而比较只能回答"谁更新"，回答不了"能不能用"（还要叠加 floor / baked / 通道三层判断）。

### 决定 A：`decide` 是纯函数，只判定不处置

```
decide(installed, floor, baked) -> verdict · reason · safe_mode
```

- 纯函数：不读盘、不改指针、不起进程；三份实现（py / sh / node）与 compare / check 共用同一张向量表。
- **判定与处置分开**：回落 baked、退出码、日志全部留在 `service.sh` —— 这样"规则写错"和"流程写错"能分开定位。

判定表见 [versioning §9.2](./versioning.md)。

### 决定 B：低于 floor 的正确处置是"回落 baked"，不是"一律拒绝"

- `floor ≤ baked` 由生成器保证，所以 baked 一定 ≥ floor。
- 因此当 active 层 `< floor` 而 baked 层存在时：**原子切回 baked 再启动**（tmp + `mv`，ADR-009），不是拒绝。
- 只有 baked 层也不可用 / 指针写不进去时，才拒绝并返回 `50`。
- "先停后换"不适用于此：走到 `do_start` 这一步时本来就没有活跃实例（`pid_alive` 已在最前面判过）。

### 决定 C：新增退出码 `50` = 版本闸门拒绝启动

| 码 | 含义 | 处置建议 |
|---|---|---|
| `30` | payload 缺失 / 校验失败 | 去投递或下载 payload，再来 |
| `40` | 切换失败 | 查磁盘 / 权限 / active 指针 |
| **`50`** | 版本闸门拒绝 | **换层或刷模块**，重试没有用 |

30 与 50 必须分开：前者重试有意义，后者重试只会死循环。

### 决定 D：`safe_mode` 只算不执行

alpha / 非 rc 预发布 → `safe_mode=1`，但今天**没有"禁用全部插件"的实现**（ADR-023 的落地件）。
壳只把这一位打出来（日志 + `status`），**不假装执行**。等 ADR-023 的插件禁用机制做出来，再消费这一位。

### 决定 E：`status` 只读，不改退出码

`status` 也调 decide，但**只用于展示**（`version : ok (baked) · installed=… floor=… baked=… safemode=…`）；
即使判定是 deny，`status` 仍返回 0 —— 它是报告，不是闸门。缺 manifest / 缺库时，`status` 必须能把原因说出来，而不是自己失败。

- **代价**：① 启动路径多读两个文件（manifest + `.layer`），每次 start 一次，可忽略；② 多一个退出码，所有消费方要知道；③ 多 19 条向量与壳上 11 条契约断言要维护。
- **重审触发**：① ADR-023 的插件禁用机制落地 → 接上 `safe_mode` 的执行；② 出现"低于 floor 也要强行启动"的真实需求（例如排障模式）→ 加显式 `--force`，不要放宽默认；③ manifest 读取成为启动瓶颈（不现实）→ 缓存进 `run/`。

### 修订记录

- 增补 ADR-013 决定 B 的退出码表（`50`）。
- 本条输入（`baked` / floor）的来源见 ADR-025，因此不再有"第 4 位对着谁"的歧义。

---

## 附：一条来自源码的实现细节（将来做能力插件时会用到）

DSHA 的虚拟屏用手握手的**令牌**：

- 特权侧启动时输出 `DSHA_VSCREEN_BOOTSTRAP <48 位 hex>`，宿主只信任这一行标记（`VirtualScreenBootstrap.java`）
- 失败时输出固定错误码 `DSHA_VSCREEN_ERROR=<code>`，宿主按码分类，**不把启动输出和凭据写进日志**
- 输入侧有"**帧门**"：`frameSeq` 必须是你刚看过的那一帧，否则 `FRAME_EXPIRED` / `FRAME_NOT_OBSERVED`（`VirtualScreenPolicy`）

这套"**特权 helper 回报令牌 + 宿主按帧门校验**"的模式值得直接借用——它同时解决了**鉴权**和**乱序输入**两个问题。
