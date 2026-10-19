# 反例集：会绕远路的做法 + 值得进阶的方向

> 上半部分（A）是**我已经在你我的对话里实际踩过/差点踩**的弯路，每条都写了"为什么错"和"正确做法"。
> 下半部分（B）是**进阶方向**，每条都写了"触发条件"——**没到条件就别做**。

---

# A. 弯路（Avoid）

### A1. 一上来就冲着"内核模块加载 root"去
- **症状**：把"找到能加载内核模块的 root 方案"当成项目第一步。
- **为什么错**：你的设备**已经是 LKM 模式**（`kernelsu.ko` 开机载入，内核没改）——你要的东西已经在跑了。
- **正确做法**：**先盘点现状**（root 形态 / 内核版本 / 已装模块），再决定要动什么。第一步永远是"我现在有什么"。

### A2. 把 `sabamdarif/chroot-distro` 当成"模块"
- **症状**：拿它的仓库去研究怎么刷入。
- **为什么错**：它是 **pip 安装的 Python CLI**（`requires-python>=3.10`）；仓库里**没有 `module.prop`/`META-INF`**。模块在**同名的另一个仓库** `Magisk-Modules-Alt-Repo/chroot-distro`（你贴的链接和它是两回事）。
- **正确做法**：认仓库不看名字——**看有没有 `module.prop`**。附：`sabamdarif` 那条线在 2026-02 亲手删掉了 Magisk 外壳。

### A3. 为一个 0.2.x 的上层（DSH）去动内核
- **症状**：先想"要不要刷内核"，再想壳。
- **为什么错**：**顺序反了**。DSH 自己还在 0.2.0-rc，插件/格式会漂移；内核是最贵、最难回滚、最容易被 OTA 抹掉的一层。把稳定性押在它身上是本末倒置。
- **正确做法**：**先把壳做出来，让它对下层不敏感**；阶段一用 stock + LKM 就能跑。内核只在"壳已经稳定、且确实需要 systemd/NAT/GPU"时才动。

### A4. 有 root 还套 proot / DSHA 当基线
- **症状**：因为 DSHA 现成，就把它当运行基础。
- **为什么错**：proot 是用户态 syscall 翻译，**你的 root 本来可以不要这层开销**；而且它把环境绑进 App 沙箱。
- **正确做法**：`chroot` + bind mount。proot 只在**没有 root** 时才是正确工具。

### A5. 自己造"动态端口"（猜端口 / 扫 netstat）
- **症状**：写壳时"先探测一个空闲端口，再传给服务"。
- **为什么错**：探测→真正 bind 之间必然有 **TOCTOU 竞态**；扫 `netstat` 又要处理 busybox/toybox 输出差异。
- **正确做法**：**让服务自己 `bind(0)`**。DSH 原生支持：`dsh web --port 0`（`--help` 明写 "pass 0 to let the OS pick a free one"），端口再回传发布。

### A6. 把 439 MB 的 DSH 塞进模块 zip 或 `/system`
- **症状**：想让"刷一次什么都有"。
- **为什么错**：DSH 安装后 **439 MB**（+Ubuntu rootfs 后 ~1 GB）。Magisk 模块目录是**挂载源**，塞大件会让安装慢/失败率上升，也让模块升级变笨重。
- **正确做法**：**分包**。模块 zip 只放 CLI+壳+manifest（KB 级）；payload（~1 GB）放 `/data/local`，按需解包；state 永不覆盖。

### A7. 把 `~/.dsh` 放进版本目录
- **症状**：为了"干净"，把 profiles/sessions/凭据跟版本放一起。
- **为什么错**：**升级 = 丢 session 和凭据**。
- **正确做法**：`state/` 与版本层彻底分离，容器里只把 `state/dot-dsh` bind 到 `/root/.dsh`。

### A8. 以为 root 容器里的"只读/不可变"是安全边界
- **症状**：靠 `chmod 444` / `chattr +i` 保护基线。
- **为什么错**：容器里的"用户"也是 **root**；你的 floor 不是安全机制。
- **正确做法**：用 **`mount -o remount,ro,bind`**（真正改不动）；并且**接受**floor 只是"防手滑 + 防自动降级 + 可自动回滚"的护栏。

### A9. 直接 `--host 0.0.0.0` 就以为平板能用
- **症状**：监听全网卡，结果平板打开是 403/白屏。
- **为什么错**：两个独立问题。① DSH 的 `/api` 有**浏览器信任栅栏**，非本机 authority 需要 `--trusted-host`；② 你把**整个 agent 控制面裸奔在局域网**上了。
- **正确做法**：DSH 保持监听 `127.0.0.1`，由**壳反代**；壳只暴露三个端点 + token；需要 LAN 时按 Wi-Fi 条件开。

### A10. 相信"下载即安全"
- **症状**：直接用 chroot-distro 的 `install ubuntu` 拉 rootfs。
- **为什么错**：脚本**完全不校验哈希**（源码里只有算自己 md5 的显示用途），而且 `kali`/`alpine`/`archlinuxarm` 是 **`http://` 明文源**。
- **正确做法**：自备 rootfs tarball（官方 https 下载），**自己算 sha256 后**再喂给 `下载 <name> <直链>`/`add`。别让明文 http 进你的运行基线。

### A11. 依赖 chroot-distro 的"在线更新"
- **症状**：等 Magisk 里点更新。
- **为什么错**：`update.json` 停在 **v2.1.0 / versionCode 17**（2025-06），而 main 分支到 2025-12-18 还有 8 个提交未发版 → **点更新永远拿不到东西**。
- **正确做法**：手动替换 `/data/adb/modules/chroot-distro/system/bin/chroot-distro` + `chmod 755` + 重启，并核对 sha256（`39459c59…`）。

### A12. 在 Alpine 上"反正 Node 能装"
- **症状**：为了小体积选 Alpine。
- **为什么错**：`node-pty`（**agent runtime 的命脉**）在 npm 上**只有 glibc 预编译**（tarball 里只有 `linux-arm64`/`linux-x64`）；`@trycua/cua-driver` **musl 包 404**，且它是 optionalDep → **静默降级**（不报错，能力悄悄消失）。
- **正确做法**：Ubuntu 24.04 (glibc)。省下的几十 MB 抵不上"现场编译 + 静默功能缺失 + agent 天天踩 busybox"。

### A13. 把"换内核"当成低风险的一步
- **症状**："管理器重刷一下就好"。
- **为什么错**：至少四个真实坑：① `ssg_enable` 默认 `true`，而作者 README **明写 SSG 仅在一加12 上会导致无法正常启动**；② OKI 内核要与固件小版本对版（构建脚本的 `KERNEL_NAME=android14-11-o-gca13bffobf09` 与你机器的 `…g659d588fa0da` 不同）；③ **别默认 AnyKernel3 会帮你处理所有分区**——写哪些分区由包内配置决定，OKI 场景常见的配套分区（dtbo/vendor_boot）不一定包含【待核对】；④ **OTA 会覆盖 boot**，你就退回 LKM。
- **正确做法**：先备份 boot（能救砖）；确认 `ssg_enable=false`；确认产物与固件版本匹配；并接受"OTA 后要重刷"。

### A14. 拿 DSH 的版本号当"稳定标志"
- **症状**："还没到 1.0，所以不能上。"
- **为什么错**：0.2.0-**rc** 的语义由上游自己定义，而且 `package.json` **连 `engines` 都没有**；它不会替你兜版本兼容。
- **正确做法**：**自己定 floor**，并用 prerelease-aware 比较（`0.2.1-rc.1 > 0.2.0-rc.2 > 0.2.0` 的序必须对，别用字符串比较）。

### A15. 期望纯容器完全替代 DSHA 的设备控制
- **症状**：以为进了容器就"什么都能干"。
- **为什么错**：读屏/点按/剪贴板/通知这些是 **App 层能力**（无障碍服务、Shizuku、MCP 桥）；本会话的 `mcp__dsha-android__*` 工具就来自 DSHA App。**精确控件语义与虚拟屏，root CLI 替代不了。**
- **正确做法**：容器为主 + 保留**极薄设备桥**（`uiautomator dump` + `input` + `screencap` + `am/pm`，必要时保留一个 App 做无障碍增强）。

### A16. 把"1 GB payload 打包"排在"命门验证"之前
- **症状**：先做打包脚本，最后才试跑 DSH。
- **为什么错**：整条路线的命门是 **`node-pty` 在 chroot 里能否起 PTY**，以及 `dsh web --port 0` 能否跑起来。这两条不过，1 GB 白打。
- **正确做法**：**最小验证优先**：容器里 `node -e "…node-pty…"` → 再 `dsh --version` → 再打包。

### A17. 把 `/app/*` 桥当成壳的核心链路
- **症状**：壳的启动/控制依赖 DSHA 的 HTTP 桥。
- **为什么错**：那是 **App 层接口**，App 升级/权限变化/被卸载就断；你替代 DSHA 的初衷恰恰是摆脱它。
- **正确做法**：壳的核心链路是 **root + UDS**；`/app/*` 只能作为**可选增强**。

### A19. 再写一个插件管理器
- **症状**：觉得"插件侧得有个管理器"，准备自己造。
- **为什么错**：**它已经有了**。DSH_HOME 里躺着 `plugin-manager.py` / `plugin-lifecycle.py` / `plugin-transactions.py` / `plugin-dependencies.py` + `plugin-dependency-locks/` / `plugin-sources.json` / `plugin-updates.json` / `plugin-activations.json`（含指纹与版本）/ `plugin-history/` / `plugin-previews/` / `plugin-semver.cjs` —— 源、下载校验、依赖锁、事务、激活指纹、更新检查、历史全都有。再写一个只会和它对账本、抢 `profiles/<name>/node_modules`，而且注定落后上游。
- **正确做法**：DSH 侧**用它的既有机制**（`--profile`、`cordis.patch.yml`、它自己的安装/更新命令）；壳侧只写**目录约定**（`caps/<name>/cap.json` + 起停脚本 + 健康探测），把"管理器"留到确实有第三方生态时再做（触发条件见 [ADR-008](./decisions.md)）。

### A18. 忽略容器与原厂 `/data` 的挂载标志
- **症状**：容器里 SUID 程序不工作 / apt 的 gpgv 报错。
- **为什么错**：`/data` 默认可能带 `nosuid,nodev,noexec`；chroot-distro 有 `fix-suid` 开关去 remount，**这会动宿主的挂载标志**。
- **正确做法**：知情后再用；并且记住它和"用 ro bind 保护基线"是**互相影响**的两件事。

### A20. 在 Android 的 sh（mksh）上用 `${s%%|*}` 切字段
- **症状**：自检脚本在 dash / bash 上 76/76 全绿，拷到手机上却**每一条都落进 `*)` 分支**（`FAIL unknow`），而真正的比较逻辑明明对（人眼复核那三条都 ok）。
- **为什么错**：**mksh 对参数展开里未加引号的 `|` 的处理与 dash/bash 不同** —— 实测（mksh R59，2026-10-17 真机 + 容器双端）：`${line%%|*}` 在 mksh 里返回**空串**，在 dash 里返回第一个字段。加引号的 `${line%%"|"*}` 在两边**都不匹配**（另一头坑）。这不是笔误，是方言：Android 的 `/system/bin/sh` 就是 mksh，**容器里那套 dash/bash 绿了不代表设备绿**。
- **正确做法**：切字段用 `IFS='|'; set -- $x`（三端一致），或 `while IFS= read`；**带引号的变量**模式是安全的（`${line%%"$_tab"*}` 三端都正常，`lib/semver-gate.sh` 的 `batch` 就是这么写的）。凡是要在设备上跑的 sh 代码，**先在本机装个 mksh 跑一遍**（`apt-get install mksh`）。
- **配套**：`tools/check-gate.py` 现在会**自动把 mksh 纳入**（装了就跑），CI 也装 mksh 跑一遍；真机自检脚本 `tools/verify-gate-device.sh` 就是这次踩坑的产物。

### A21. 把 DSH 版本号"编"进 module.prop 的第 4 位（或让一位同时对齐 floor 和 baked）
- **症状**：想让四位 `version` 直接表达"内置的是哪个 DSH 版本"，于是设计一套 `主×10000+次×100+修订` 的编码，或者干脆让第 4 位"既跟 floor 又跟 baked"。
- **为什么错**：三条，都是硬错。
  1. **不存在保序的整数编码**：semver 的序是**稠密**的（`1.0.0 < 1.0.1-0 < 1.0.1-0.0 < … < 1.0.1`，任意两个版本间都能再插一个），而整数之间只能放有限个。`0.2.0-rc.2 → 20002` 这类方案必然在 `0.2.0` 正式版上翻车（final 必须大于所有 rc，却没有可用的整数）。
  2. **一位不能同时等于两个值**：`floor`（允许的最低）与 `baked`（内置的那份）**本来就允许不同**（[baseline §7](./baseline.md)：floor 是否跟着抬由你决定）。今天同值只是巧合，第一次"只抬 floor"或"只换 baked"就必须二选一。
  3. **人肉同步不会报错**：`V_DSH` 当年只被校验"是不是整数"，与 `DSH_BAKED` 的对应关系没有任何机器检查 —— 写错会静默进产物。
- **正确做法**（[ADR-025](./decisions.md)）：第 4 位 = **只追加台账**（[baseline/bake-ledger.json](../baseline/bake-ledger.json)）的 `seq`，**对着 `baked`**；`baked` / `floor` 各自以完整 semver 放在 manifest；`version` **永不参与任何比较**（模块更新只认整数 `versionCode`）。注意 `1.0.0.10` 在字典序上小于 `1.0.0.9` —— 第 10 次发版就会翻车。

### A22. 模板占位符 `@@{...}` 漏展开 —— 本机全绿，真机第一步就炸
- **症状**：`service.sh help` / `dsh-ctl status` 在设备上（没有 `DSH_PATH_OVERRIDE`）报 `parameter not set` 并以非零退出；本机测试却全绿，因为测试脚本**总是**导出那个变量。
- **为什么错**：生成设备自检脚本时用 `@@{` 作为占位符（避免 Python 模板冲突），这个约定被顺手写进了两个入口脚本；`set -u` 下 `"@@{VAR:-}"` 是一个**普通字面量**（非空）→ 进入 then 分支 → 展开 `$VAR` 时变量未定义 → 直接退出。测试缝变量恰好把它遮住了，属于"**测试替身把生产故障挡住**"。
- **正确做法**：入口脚本里只写真正的 `${VAR:-}`；`@@{` 只允许出现在生成器里。并加一条**不设测试缝变量也能跑**的契约断言（本仓已在 `tools/test-service.sh` 里加：`unset DSH_PATH_OVERRIDE; sh service.sh help` 必须 rc=0）。
- **判据**：任何"只在测试里设置"的变量，都要有一条"不设置时也能工作"的用例。

### A23. 在模块包根放 `install.sh` —— 管理器"装不上"，staging 目录却是空的
- **症状**：模块 zip 在 ReSukiSU / KernelSU 里点安装，管理器只报一句失败；`/data/adb/modules_update/<id>/` **存在但是空目录**，`/data/local/dsh` 里什么也没更新。
  **管理器安装日志的原文**（2026-10-19 实测）：legacy 分支只 `inflating: module.prop / install.sh / uninstall.sh`，
  然后 `! install.sh: 找不到 module.prop` → `Error: Failed to install module script`。
- **为什么错**：Magisk / KernelSU 的安装器用「zip 里有没有 `install.sh`」判断 **legacy 模块** —— KernelSU `installer.sh` 里就一句 `is_legacy_script() { unzip -l "$ZIPFILE" install.sh | grep -q install.sh; }`。命中后它只解压 `module.prop` / `install.sh` / `uninstall.sh` / `common/*` 到临时目录并 **source `install.sh`**，**不会解 `bin/` 与 `lib/`**。于是现代布局的安装钩子在空 `MODPATH` 里 `cp bin/service.sh` 失败 → abort；而 `MODPATH` 是在这个分支之前就建好的，所以留下一个空目录。
- **正确做法**：安装逻辑全部放在 `customize.sh`，**包根不要出现 `install.sh`**。判据：`unzip -l 包 | grep -x 'install.sh'` 必须为空；本仓 `tools/build-module.py` 与 `--selftest` 都会拦。
- **附带坑**：安装器解包后会 `set_perm_recursive $MODPATH 0 0 0755 0644` —— **文件一律 0644**。所以模块根 `service.sh`（开机钩子）的可执行位必须在 `customize.sh` 里补（`set_perm … 0755` 或 `chmod`），否则重启后钩子不会执行，而且**不报错**。

---

# B. 进阶（Advance）——每一条都写了"触发条件"

### B1. 阶段二：自定义内核 + Droidspaces
- **触发条件**（**三条同时满足才做**）：① 壳已经稳定运行 ≥ 一段时间；② 你**确实**需要容器内 systemd / NAT / macvlan / GPU 直通；③ 你接受"OTA 后要重刷"。
- **怎么发车**：`cctv18/oppo_oplus_realme_sm8650` 的 6.1.141 流水线，输入：
  `ksu_type=bakasu`（**与你现在管理器同源**，仓库整体改名自 ReSukiSU，脚本原话"BakaSU 兼容 sukisu 管理器"）、
  `droidspaces_enable=standard`、**`ssg_enable=false`**、其余按需；N 选 `l`（无内置 KSU）**走不通**——脚本只"跳过配置"，**不产出 `.ko`**。
- **收益**：真容器。**成本**：刷机风险 + OTA 反复。

### B2. KPM（KpatchNext 内核补丁模块）
- **触发条件**：你想要的只是**隐藏/改写行为**（对已有函数打补丁），而不是"补上没有的内核子系统"。
- **能做**：在任意 KSU/Magisk 环境加载内核模块级补丁。**不能做**：把没编译进去的 `PID_NS`/`NET_NS`/`VETH` 变出来——那必须换内核。

### B3. ~~overlayfs 分层~~ → **已否决**（ADR-009）
- **原本想法**：用 overlayfs 把 `base(ro)` + `user(rw)` 合成容器里的 DSH 目录。
- **否决理由**：
  1. **不需要** —— `mount --bind` + `remount,ro` + 一个 active 指针就能达到同样效果，且完全可控；
  2. **多一层内核依赖** —— stock 内核未必可用（原本标的就是【待验证】）；
  3. **概念混淆** —— 有人会把它和 **KernelSU 的模块挂载**混为一谈，那是**完全不同的场景**（见下）。
- **规范做法**：容器分层 = **bind(ro) + active 指针**；模块挂载 = 交给你的元模块（**Magic Mount-rs**），两者井水不犯河水。
- ⚠️ **唯一的交叉点**：不要给容器 bind **模块目录**（`/data/adb/modules/...`）——那会穿过 KernelSU 的挂载视图。容器只 bind `/data/local/dsh/` 与显式白名单。

> 📌 **两个 "overlay" 别混**：① **文件系统 overlay**（overlayfs，模块挂载/容器分层用它）；② **网络 overlay**（Tailscale/WireGuard 那类组网，见 §B10 与 research §6.4.1）。本项目里：文件系统 overlay **不用**；网络 overlay **已裁**（ADR-006）。

### B4. SCM_RIGHTS 传文件描述符
- **触发条件**：你想让"对外端口"完全由宿主决定，甚至不占 TCP 端口。
- **做法**：容器内服务 `bind(0)` 后，把 listening socket **fd** 通过 UDS 交给宿主壳，宿主壳决定怎么暴露。
- **收益**：暴露面最小。**成本**：实现复杂度上升，仍建议**数据面 UDS 为默认**。

### B5. 用 ext4 镜像承载 rootfs/版本层
- **触发条件**：你开始做"备份/迁移/差分"。
- **收益**：一个文件 = 易备份、易算哈希、易做增量；挂载后就是目录。
- **成本**：需要 loop 支持【待验证】；对 Android 的 `nosuid` 等标志要额外处理。

### B6. 把上游 Python 版塞进容器内当"镜像管理器"
- **触发条件**：你开始需要**任意 Docker 镜像 / OCI / Dockerfile 构建**。
- **做法**：容器里装 Python 3.10+，跑 `sabamdarif/chroot-distro` v3。
- **收益**：一次拿到 build/OCI/sync/diff/isolation。**成本**：容器内多一套 Python 运行时；两套容器布局不通用（要迁移，见前文配方）。

### B7. 设备桥重建（把 DSHA 的能力拿回来）
- **触发条件**：你发现"agent 看不见手机屏幕"影响使用。
- **做法**：容器里挂一个薄 HTTP 桥，包装 `uiautomator dump` / `input` / `screencap` / `am` / `pm` / `cmd notification`；不够的部分再考虑保留一个极薄 App 做无障碍增强。
- **收益**：不依赖 DSHA。**成本**：需要逐项实测覆盖度（**【待验证】**）。

### B8. A/B 多版本共存与灰度
- **触发条件**：你开始"不敢升级 DSH"。
- **做法**：state 与版本层分离后，`base/` 与 `user/` 天然支持两版并存，`active` 原子切换 = **秒级回滚**。
- **收益**：升级心理成本归零。**成本**：几乎为零（本设计已具备）。

### B9. payload 增量更新
- **触发条件**：payload 每次全量下载让你烦。
- **做法**：分层打包（rootfs / node / dsh 三层各自独立哈希），只换变的那层；pnpm store 复用。
- **收益**：升级从 ~1 GB 降到几十~几百 MB。

### B10. 同一套壳跑别的东西
- **触发条件**：你想跑的不止 DSH。
- **做法**：因为壳只依赖"**起/停 + 一个已知端口**"，把 DSH 换成别的 agent/服务（甚至多个）几乎零改造。
- **收益**：这套投资的复用率最高。**成本**：零。

---

## 一句话总结

**弯路几乎都来自"先动最贵的一层"和"没验证就放大"**；
**进阶几乎都来自"把边界留在壳里，让下面可替换"**。
