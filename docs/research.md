# 研究文档：用 root 容器替代 DSHA

> 标注约定：**【已验证】** 有据可查（本容器实测 / 源码 / registry）；**【推断】** 由事实推导；**【待验证】** 必须真机测。

---

## 1. 目标与动机

### 1.1 目标

在**不改内核**的前提下（原厂 6.1.141 + ReSukiSU/BakaSU LKM），用 **root 模块 + chroot 容器** 搭出一套可替代 DSHA 的 DSH 运行环境：

1. 容器里烘焙好 **Ubuntu 24.04 + Node 24 + pnpm 11.x + DSH 基线**
2. 一层"壳"负责：**版本闸门**、容器/服务生命周期、**动态端口发现**、**受控的跨设备访问**、**文件通道**
3. 上层（DSH）可自由升级，下层（内核/容器运行时）可替换，**壳保持不变**

### 1.2 动机（为什么要替代 DSHA）

| 维度 | DSHA（应用壳） | 本方案（root 容器） |
|---|---|---|
| 运行层 | bxroot / proot（用户态 syscall 翻译） | 真 `chroot` + bind mount，**无 proot 开销** |
| 与 App 的关系 | 绑在 App 生命周期与沙箱里 | 与 App 无关，**卸载 App 也能跑** |
| 文件可见性 | 受 App 权限约束 | 宿主 root 视角，**可 bind 真系统路径** |
| 环境搬运 | 绑在 APK 的 rootfs 里 | 容器目录 + payload 包，**可备份/可迁移** |
| 版本控制 | 跟着 APK 走 | **自己定基线 + 自己设版本地板** |

### 1.3 非目标（明确不做）

- ❌ 不追求"阶段二"（自定义内核 / Droidspaces）——**你已裁掉**，理由见 §9 与 pitfalls §B1
- ❌ 不做公网端口映射（走 overlay，见 §6.4）
- ❌ 不在本环境刷机、写 boot、装模块

---

## 2. 现状盘点（决定性事实）

| 项 | 值 | 来源 |
|---|---|---|
| 设备 | 一加 12（PJD110）· Android 16 (SDK 36) | `/app/device` **【已验证】** |
| 内核 | `6.1.141-android14-11-o-g659d588fa0da` | ReSukiSU 管理器截图 **【已验证】** |
| Root | **ReSukiSU · LKM 模式**，驱动 v4.2.0-rc2(35160/4)，管理器 v4.2.0-rc3(35171/4) | 截图 **【已验证】** |
| SELinux / Seccomp | 强制 / 过滤模式 | 截图 **【已验证】** |
| Hook / Zygisk / 元模块 | Tracepoint Syscall Redirect / ReZygisk / **Magic Mount-rs** | 截图 **【已验证】** |
| 授权与模块 | 19 个超级用户 / 9 个模块（清单：`WorkSettingPro` · `hma_oss_zygisk` · **`magic_mount_rs`** · `playintegrityfix` · `rezygisk` · `treat_wheel` · `tricky_store` · `ufi-manager` · `zygisk_lsposed`） | 截图 + 设备侧实读 **【已验证】** |
| 空间 / 内存 | 582.94 GB 可用 / 22.62 GB 总内存 | `/app/device` **【已验证】** |
| DSHA | `com.dsh.client` `com.dsh.clienu`；桥协议 3；APP_CODE 170；`APP_VERSION=0.2.21-…-dsh0.2.0-rc.2` | `/app/apps`、`/app/version` **【已验证】** |
| DSH 本体 | `@deepseek-ai/dsh@0.2.0-rc.2`，安装后 **439 MB** | 本容器 `du -sh` **【已验证】** |
| 容器内工具链 | node v24.19.0 / npm 11.17.0 / pnpm 10.34.5 | 本容器 **【已验证】** |
| 设备 shell 通道 | ✅ **已连接**（2026-10-16，经 root） | `adb-shell id` → `uid=0 … context=u:r:ksu:s0`；`ls /data/adb` 可读；命令形态受单条白名单限制 **【已验证】** |
| 设备版本串 | `PJD110_16.0.10.501(CN01)` · OTA `PJD110_11.F.57_2570_202608111410`（构建 2026-08-11） · `ro.product.device=OP5929L1` | `getprop`（只读）**【已验证】** |
| 启动状态 | `flash.locked=1` · `verifiedbootstate=green` · `veritymode=enforcing` | `getprop`（只读）**【已验证】** |

> ⚠️ **重要推论（【已验证】的事实 + 【推断】的结论）**
> 你已经拥有"**内核模块加载 root**"——LKM 模式就是 `kernelsu.ko` 在开机时载入、内核本体未改。
> 项目起点那一问的答案，就是你手机本身。**不需要为此做任何事。**

---

## 3. 技术路线比较

### 3.1 容器运行时

| 方案 | 形式 | 需要内核改动？ | 网络 | 隔离 | 结论 |
|---|---|---|---|---|---|
| **chroot-distro 模块** | Magisk/KSU 模块（1 个 sh CLI） | ❌ 不需要 | 共享宿主 netns | 无 | ✅ **选它** |
| sabamdarif/chroot-distro（上游 Python） | pip CLI | ❌ | 共享宿主 | 可选 netns（需内核） | ⛔ 不再提供模块形态（2026-02 已删 Magisk 外壳）**【已验证】** |
| Droidspaces | 二进制 + App | ✅ 需要（PID_NS/IPC_NS/NET_NS/veth/bridge/devtmpfs…） | NAT / gateway / macvlan | 真容器（容器内 PID 1） | ⏸ 阶段二（已裁） |
| proot / DSHA | 用户态 syscall 翻译 | ❌ | 共享宿主 | 无 | ⛔ 有 root 还套 proot 是双重开销 |

**chroot-distro 的关键事实（【已验证】）**
- 数据全在 `/data/local/chroot-distro/`：`<distro>/`（容器）、`.rootfs/`（下载缓存）、`.backup/`（备份）、`.config/`（开关 + 自定义发行版标记）
- 模块 zip 只有 **18 KB**，`system/bin/chroot-distro` 是一个 **88.5 KB / 2384 行的 sh 脚本**
- `config.sh`：`AUTOMOUNT=true`、`POSTFSDATA=false`、`LATESTARTSERVICE=false` → **不常驻、不开机跑**
- 依赖 **BusyBox ≥ 1.36.1**
- rootfs 归档**顶层最多一层子目录**，否则 `install` 直接拒绝
- **不校验下载哈希**；kali/alpine/archlinuxarm 甚至是 `http://` 明文 **【已验证】**
- 官方在线更新**已死**：`update.json` 停在 v2.1.0/versionCode 17，而 main 分支到 2025-12-18 还有 8 个提交未发版 **【已验证】**
- 手动更新方式：替换 `/data/adb/modules/chroot-distro/system/bin/chroot-distro` + `chmod 755` + 重启
  - main 分支脚本 sha256 = `39459c596d5f83a093139988c9ef7d78304daef3cf4412c09cee050a05840d98`
  - 我重打包的 zip sha256 = `5c2ab56ce15e530ae57321c6d04ac3f1f309781ac26423a4a7eede5d600609ce`

### 3.2 上游 Python 版为什么"看着更好"却不用

**【已验证】** 上游 `sabamdarif/chroot-distro` 是 **2026-05-29 起的 Python 重写**（`requires-python>=3.10`，唯一依赖 `backports-zstd`），从 **Docker Hub** 拉镜像，功能强得多（build/OCI/isolation/sync/diff）。

但对我们：
- **它不再产出模块**（2026-02-15 亲手删掉 `META-INF`/`customize.sh`/`module.prop`/`system/bin`）**【已验证】**
- 要跑它就得在设备上先有 **Python ≥3.10** → 实际等于绑 Termux 或自带解释器（我们 §3.3 的方案里都不便宜）
- 它的 **Android 适配全部挂在 `IS_TERMUX` 开关下**（`helpers/android.py` 每个入口 `if not IS_TERMUX: return`）**【已验证】**，非 Termux 环境下会丢：guest `/etc/group` 补 `aid_inet(3003)`、`_apt` 主组、`ensure_data_suid`（清 `/data` 的 nosuid/nodev/noexec）——**没有这些，容器里没网、apt 直接废**

→ 结论：**阶段一不碰它**。将来若需要"任意 Docker 镜像"，再考虑把它塞进容器内运行（见 pitfalls §B6）。

### 3.3 如果将来非要在设备上跑 Python 版

三条路（**都没选**，仅存档）：
1. 依赖 Termux（违背"不装 App"的初衷）
2. 静态 musl CPython（`astral-sh/python-build-standalone` 有 `aarch64-unknown-linux-musl` 的 3.14.8 **【已验证】**）——但要处理 DNS（无 `/etc/resolv.conf`）、CA（`SSL_CERT_DIR=/system/etc/security/cacerts`）、zstd（3.14 有 stdlib `compression.zstd`）
3. 自己编（成本最高）

---

## 4. 架构

### 4.1 四层 + 适配器（核心设计原则）

```
L3  壳（控制面）      ← 唯一需要你自己写、长期不变的东西
      ├─ 版本闸门 / 生命周期 / 端口发现 / 访问控制 / 文件通道
L2  DSH（可换版本）    ← 只依赖"起/停 + 一个已知端口"
L1  容器运行时（可换）  ← chroot-distro 现在；Droidspaces 将来
      └─ adapter 接口：list / start / stop / exec
L0  内核（可被 OTA 覆盖）← 原厂 + LKM 就能跑阶段一
```

**为什么这样切**：OTA 会覆盖 boot → 你退回 LKM + 原厂内核。此时 **chroot-distro 照样能用，Droidspaces 会失效**。
所以"阶段一在 stock+LKM 上工作"是硬要求，阶段二只能是升级。

### 4.2 目录布局

```
/data/local/dsh/
├── state/                     # 持久层（跨版本，绝不能进版本目录）
│   ├── dot-dsh/               # ~/.dsh：profiles / sessions / 凭据 / 配置
│   └── pnpm-store/            # pnpm 全局 store（省几百 MB 重复下载）
├── base/                      # 烘焙基线层（模块带来，启动前校验 hash）
│   ├── node/                  # node 24 + npm + pnpm
│   └── dsh-0.2.0-rc.2/        # 439 MB 的 @deepseek-ai/dsh 完整树
├── user/                      # 用户升级层
│   └── dsh-<ver>/
├── active                     # 壳维护的原子指针（一行路径：写 tmp + os.replace）
├── manifest.json              # baked / baked_seq / floor / recommended / node_floor / sha256
└── run/                       # 端口 JSON、UDS、日志
```

容器内挂载（启动时由壳建立）：

| 容器内 | 指向 | 读写 |
|---|---|---|
| `/usr/local/lib/node_modules/@deepseek-ai/dsh` | `active` 解出的层 | **只读 bind**（`mount -o remount,ro,bind`） |
| `/opt/dsh/base` | `base/` | 只读 |
| `/root/.dsh` | `state/dot-dsh/` | 读写（持久） |
| `/usr/local/bin/{dsh,node,npm,pnpm}` | 壳装的 wrapper | 壳管 |

> **铁律**：版本层与状态层彻底分离。一旦 `~/.dsh` 混进版本目录，**升级 = 丢 session 和凭据**。

### 4.3 挂载机制：两套，别混

| | 谁在做 | 作用域 | 用什么 |
|---|---|---|---|
| **模块挂载** | KernelSU 元模块（你的是 **Magic Mount-rs**） | `/system` 域 | Magic Mount 自定义挂载（**不是** overlayfs 路线） |
| **容器分层** | 我们的壳 | `/data/local/dsh/` 内部 | **`mount --bind` + `remount,ro` + active 指针**——**不用 overlayfs**（ADR-009） |

⚠️ **唯一边界**：**不要给容器 bind 模块目录**（`/data/adb/modules/...`），那会穿过 KernelSU 的挂载视图。容器只 bind `/data/local/dsh/` 与显式白名单路径。

> 📌 **两个 "overlay" 不是一回事**：**文件系统 overlay**（overlayfs）本项目**不用**；**网络 overlay**（Tailscale 类）已裁（ADR-006）。

---

## 5. 版本策略：只设下限（floor-only）

### 5.1 语义

| 概念 | 含义 |
|---|---|
| **floor（硬下限）** | 任何被激活的 DSH 版本必须 `≥ floor`；低于 floor **不允许运行，也不允许安装** |
| **ceiling（上限）** | **没有**。用户想升多新都行 |
| **baked（烘焙基线）** | 随模块版本走；它是"网"，不是"天花板" |
| **降级** | 只允许降到 `≥ floor`；**低于 floor 只能改 manifest = 刷模块**，容器内做不到 |
| **recommended** | 软提示，不拦人（否则闸门会把人烦死） |

### 5.2 三道闸（defense in depth）

1. **`dsh` wrapper（PATH 最前）**：启动前解析 active 层 → 读其 `package.json.version` → 与 `floor` 做 **prerelease-aware semver 比较**（`0.2.1-rc.1 > 0.2.0-rc.2 > 0.2.0` 的顺序必须对，**别用字符串比较**）→ 低于 floor 就拒绝启动并回落基线
2. **`dsh-update <ver>`（唯一升级入口）**：装前校验 `≥ floor` → 装到 `user/` → 装后**再校验一次** → 原子翻转 `active`；**并且它是一次"只动 dsh 本体"的事务** —— 插件一个字节都不动（**0 插件更新**，ADR-023）
3. **supervisor**：启动时 + 周期性校验 hash 与版本；偏离 → 自动切回 `base/` 并记日志

### 5.3 四条流程

| 动作 | 结果 |
|---|---|
| `dsh-update 0.2.1-rc.3` | 新层进 `user/`，指针翻转；失败自动回滚指针 |
| `dsh-update 0.2.1-alpha.5`（**抬到 alpha**） | **允许，但强制进安全模式**：禁用全部第三方插件（含模块内置）→ 只剩**裸上游 DSH**；退出 ＝ 恢复声明（ADR-023） |
| `dsh-update 0.2.0-rc.1`（低于 floor） | **拒绝**，提示只有刷模块才能降 floor |
| 模块更新把 floor 抬到 0.2.1 | 用户层 < 新 floor → **自动停用该层、回落 baked**，并提示 |
| 基线被改坏 | 启动 hash 校验失败 → 从模块/备份恢复，或拒绝启动（不给"带病跑"的机会） |

> ⚠️ **诚实边界**：root 容器里**没有真正的不可变**——你的"用户"也是 root。floor 不是安全边界，而是
> **防手滑 + 防工具链自动降级 + 可自动回滚**的护栏。想更硬，只能靠"每次启动校验 + 偏离即回落"。

---

## 6. 动态端口与通信

### 6.1 一个前提判断（省掉一半复杂度）

**chroot 不隔离网络**：容器里的服务就是宿主的 `127.0.0.1:PORT`。
→ **不需要端口转发**，只需要"发现 + 反代 + 鉴权"。
（将来上 Droidspaces + netns 才需要 NAT/映射，Droidspaces 自带 NAT 模式。）

### 6.2 DSH 原生就支持动态端口（【已验证】，`dsh --profile web --help`）

```
--host <host>                  bind host
--port <port>                  listen port; pass 0 to let the OS pick a free one
--trusted-host <authority...>  extra authority the /api browser-trust fence accepts
```

- `--port 0` → **让 OS 分配空闲端口**，满足"动态端口"，**别自己猜**（猜端口有 TOCTOU 竞态）
- **DSH web 自带鉴权**【已验证】：启动打印的是**带 token 的 URL**（`dsh web: <authenticatedUrl> (LAN: <lanUrl>)`）；浏览器打开该 URL 换取**签名 cookie**；README 原文：「Host 与 Origin 检查控制可达性，**token 交换则认证每个 Host API 方法与 WebSocket 流**」
- **`--trusted-host` 的准确语义**【已验证】：绑定 `0.0.0.0` 时会**自动采样 LAN IPv4 字面量**并加入 `/api` 信任栅栏（`trustedHosts: [...lanAddresses, ...extra]`），所以**用 LAN IP 访问通常不需要手写 `--trusted-host`**；真正需要它的是：**用域名/hostname 访问**，或**启动后才发现/变化的地址**（README 注明 LAN 地址只在启动时采样一次，网络变化要重启 GUI）
  > 📌 **更正**：本节早期版本把 `--trusted-host` 写成"必踩的坑"，说过头了，已按源码事实修正。
- 真正的风险不是"没鉴权"，而是：**带 token 的 URL 本身就是凭证** —— 谁拿到谁就能驱动这个 agent。所以"可控"的意义在于：**端口什么时候开、绑哪个网卡、谁能拿到 URL**。
- **【已验证】端口从哪里读（2026-10-16 本容器实测）**：`--port 0` 时 DSH 把**真实端口**打进启动行，
  且该行走 **stdout**（stderr 为空）：
  ```
  $ DSH_HOME=/tmp/probe dsh web --port 0 --no-open --host 127.0.0.1
  dsh web: http://127.0.0.1:39895/?token=<...>      ← 端口即 OS 分配的那个
  ```
  **DSH_HOME 下不落任何端口文件**（实测只生成 `profiles/`、`storages/`、`.anonymous-user-id`、`.credentials.yaml`）
  → 对 **spawn 子进程**的壳而言，**stdout 首行就是即时真源**；按"首行取 `127.0.0.1:<port>` 与 token"即可，无需扫 netstat、无需猜。
  （若壳改为**进程内托管**，还有更直接的取法，见下一条。）
  > ⚠️ 该 URL **自带 token，本身就是凭证** → 壳读取时必须按敏感数据处理（同 §6.2 末尾的风险说明）。
  > 另有 `DSH_WEB_URL` 环境变量会下发给 **DSH 的子进程**（当前会话可见 `DSH_WEB_URL=http://127.0.0.1:3080`），
  > 但它对**启动器**不可用（启动器必须早于 DSH 就知道端口）。
  > 📌 这条与"容器 / chroot"**无关** —— 它是 DSH 自身的行为，在宿主、容器、chroot 里一致。
- **【已验证】端口发现的第二条路（进程内，不靠 stdout）**：若壳不 spawn 子进程，而是像上游
  `apps/desktop-host/src/index.ts` 那样**直接复用 `@deepseek-ai/dsh/profile-boot` 的 `runProfile()`**
  自己把 profile 起在进程内（该文件第 6 行就是 `import { runProfile }`，第 25-42 行是现成范例），
  就能直接读实际监听地址：`ctx.webServer.getOrigin()`（`packages/host/webserver/src/index.ts:351`）。
  → 两条路都通：**spawn 子进程 ⇒ 读 stdout 那一行；进程内 runProfile ⇒ 读 `ctx.webServer`**。壳按自己的托管方式选一条。
- **【重要】没有产品级 HTTP 健康检查端点**：全仓搜 `/health` / `/healthz` 只命中一个测试 fixture。
  就绪信号是**进程内**的：`AppReady` 只在 fiber ACTIVE 且 loader 存在时提交（`apps/cli/src/profile-boot.ts:44`）、
  Web 那个 `dsh web:` 行本身即就绪信号、desktop 走 Node IPC `{type:'ready', url, injections}`。
  → 壳**不要**去轮询 `/health`（不存在），只能按上面三种信号判断。
- **监听失败即启动失败**：`EADDRINUSE` 之类会让插件初始化直接失败并带 bind 诊断，不会静默退回
  （`packages/host/webserver/README.md:71`）→ 壳必须把"端口被占"当作启动错误处理，而不是无限重试。

### 6.3 控制面分层

| 通道 | 绑定 | 暴露什么 |
|---|---|---|
| **管理面** | UDS `…/run/ctl.sock`（0600）+ 仅 127.0.0.1 | `start/stop/exec/status`、容器与 DSH 生命周期 |
| **数据面** | `0.0.0.0:<动态端口>`，**只三个端点** | `/health` · `/files/*`（WebDAV/SFTP） · `/dsh/*`（反代到 `127.0.0.1:<dsh端口>`） |

**反代 DSH** 的好处：DSH 不用改 `--host`，**永不直接暴露**；统一挂 token 与白名单。

### 6.4 "可控的访问"三档

| 档 | 绑定 | 触发条件 | 备注 |
|---|---|---|---|
| `local`（默认） | 127.0.0.1 + UDS | 永远可用 | 安全基线 |
| `lan` | `0.0.0.0` + token | 仅在指定 Wi-Fi SSID / 网段时 | 平板走这个 |
| ~~`public`~~ | ~~不监听公网~~ | ~~手动开~~ | ⛔ **已裁（ADR-006）**：不引入任何 overlay。若将来重开，只允许 Tailscale / Headscale 这类零端口暴露方案 |

### 6.4.1 什么时候才需要"公网档"——以及有哪些选项

**触发条件**：只有当你需要在**不同网络**（蜂窝 / 异地）访问手机上的 DSH 服务时才需要。若"手机和平板在同一 Wi-Fi"就能覆盖你的需求，**这一档永远不用开**。

| 方案 | 是什么 | 门槛 | 暴露面 | 第三方依赖 |
|---|---|---|---|---|
| **Tailscale** | 基于 WireGuard 的零配置 overlay 组网 | 装客户端 + 登录账号 | **零端口暴露**（设备间 P2P/中继） | 协调服务器（可换 Headscale 自建） |
| Headscale | Tailscale 的自建控制面 | 需要一台有公网 IP 的机器 | 同上 | 自持 |
| ZeroTier / Netbird | 同类 overlay | 同上 | 同上 | 同上 |
| 裸 WireGuard | 自己管密钥与对端 | 需要公网可达的对端 | 需开一个 UDP 端口 | 无 |
| Cloudflare Tunnel | 把 HTTP 服务经 Cloudflare 暴露 | 需要域名 + `cloudflared` | 只暴露 HTTP，经 CF 中转 | Cloudflare |
| FRP / rathole → VPS | 反代到自己的服务器 | 需要 VPS | 只暴露 VPS 端口 | 自持 |
| DDNS + 端口映射 | 传统做法 | **需要公网 IP**（国内家宽常为 CGNAT，多半没有） | **直接把服务暴露在公网** | 无 |
| IPv6 直连 | 运营商给公网 v6 | 需要 v6 + 防火放开 | 直接暴露 | 无 |

**结论（当前）**：按最初需求（同一网络）→ **只做 `lan` 档，公网档留空**。真要开时，优先 **overlay（Tailscale/Headscale）**，**不要** DDNS+端口映射——把一个"能执行 root 命令的 agent"直接放到公网，是最贵的错误。

### 6.5 端口发现

`…/run/dsh.json` = `{"state":"ready","port":41234,"url":"http://127.0.0.1:41234"}`
写 `tmp` + `os.replace` 原子替换；**就绪判定 = 真能 connect**，不是"文件出现了"。

---

## 7. 文件通道（手机 ↔ 平板）

### 7.1 两个物种（不是"二选一"）

| 物种 | 是什么 | 内部可选 | 端口的性质 |
|---|---|---|---|
| **A. rclone** | 一个静态二进制提供**文件服务** | `serve webdav` / `sftp` / `ftp` / `http` / `nfs` / `dlna` —— **换协议只是换参数**【已验证】 | **纯服务端**：一个监听点（可 `--addr unix://` 或 127.0.0.1:0），**能被壳的反代完整包住** |
| **B. Syncthing** | **双向自动同步**（P2P，两端都装） | 只有它自己 | **P2P 节点**：默认 `22000/TCP+UDP`（同步）、`21027/UDP`（发现）、GUI `127.0.0.1:8384`【已验证】——**不能被反代包住**，需要自己的端口在局域网可达 |

> ⚠️ 这条差异会**反过来影响访问门控的设计**：
> A 可以"壳监听一个端口 → 反代到 UDS"；B 必须"**按 Wi-Fi 条件启停进程**"，让它的端口只在你允许的网络里存在。

### 7.2 默认配置

- **rclone 默认走 WebDAV**：`rclone serve webdav <root> --addr unix:///data/local/dsh/run/files.sock`（**零 TCP 端口**），由壳反代
- 平板用 Solid Explorer / MiXplorer / Windows 资源管理器 / macOS Finder 直接挂
- 认证：`--htpasswd`（或 `--user/--pass`）；TLS 需要时 `--cert/--key`

### 7.3 共享目录（比协议更重要的前置问题）

⚠️ 容器能看到的文件范围由 chroot-distro 的 bind 决定（默认宿主 root + 可选 `android_bind`）。

- **默认只共享沙箱**：`/data/local/dsh/shared`
- **不要**一上来就摊开 `/storage/emulated/0`（那是相册/微信/所有 App 数据）
- 真要访问下载/照片，再单独 bind 一个子目录（如 `/storage/emulated/0/Download/dsh`）

### 7.4 切换难度（按需 ⇄ 自动同步）

**前提**：文件通道在设计上就写成**多提供者列表**（不是单选项）—— 见 [ADR-007](./decisions.md)。做到这一点之后，"切换"就不存在了，只剩"加减一个提供者"。

| 动作 | 难度 | 具体工作 |
|---|---|---|
| **两个并存**（推荐默认） | **极低** | 各跑各的进程、各用各的端口/目录范围；壳的配置里两条条目 |
| 加 Syncthing（rclone 继续留着） | **低** | 手机侧：加二进制 + 配置 + **壳按 Wi-Fi 启停**；平板侧：装 **Syncthing-Fork**（3069★）+ 配对设备 ID |
| 从"纯 rclone"切到"纯 Syncthing" | **低** | 手机侧改配置停一个；**真正的工作在平板侧**（见下） |
| 从 Syncthing 切回 rclone | **低** | 停进程；要清理 Syncthing 残留（`.stversions`、索引、**已经同步到平板的副本**） |
| 改共享目录范围 | **中** | rclone：改参数即可；Syncthing：**文件夹 ID 变了要重新配对/重扫**，且平板上的旧副本要手动决定留不留 |

**真正会让人不舒服的不是协议，是语义差异**：

| | rclone（按需） | Syncthing（同步） |
|---|---|---|
| 平板上有没有副本 | **没有**（现看现拿） | **有**（占平板空间） |
| 删除的行为 | 删远端就没了 | **删除会传播**（要小心误删） |
| 大目录 | 随便浏览 | **不能全同步**（必须先圈定范围） |
| 平板侧存活要求 | 只在用时连 | **App 必须常驻**——Android 有 doze/省电，社区甚至专门写了 [SleepManager](https://github.com/Baggio94/SleepManager) / [SleepSync](https://github.com/Baggio94/SleepSync) 来帮它喘气【已验证：这类工具存在本身即证据】 |

### 7.5 结论

**把文件通道写成"提供者列表"，默认上 rclone(WebDAV)，Syncthing 作为可后加的第二个提供者。**
这样"切换难度"这件事被永久消除——以后想加就加，想停就停，改的是配置不是代码。


---

## 8. 已知缺口：替代 DSHA 会丢掉"安卓桥"

**这是本方案最大的能力回退风险，必须提前认领。**

DSHA 的价值不只是 Linux 环境，还有 Android 侧能力（读屏 / 点按 / 截屏 / 通知 / 剪贴板 / 传感器 / 启动应用 / Shizuku / ADB）。
纯容器**不会自动拥有**这些（本会话的 `mcp__dsha-android__*` 工具来自 DSHA App 的 MCP 桥，不在容器里）。

好消息：**你有 root，大部分能自己重建**【推断 + 部分已实测（2026-10-16 设备通道已通）】：

| 能力 | root CLI 替代 | 状态 |
|---|---|---|
| UI 自动化 | `uiautomator dump` + `input tap/swipe/text` + `screencap`（**不需要无障碍服务**） | 【待验证】 |
| 应用控制 | `am start` / `am force-stop` / `pm list` | `pm list packages` **已实测通过**；`am force-stop` 走 DSHA 策略内建路径，未单独实测 |
| 文件读写 | 直接 `/data`、`/sdcard`（比 App 层强） | **部分实测**：`ls /data/adb`、`cat /proc/*`、`grep`、`find`、`cp → /sdcard` 均可用（root） |
| 通知 / 剪贴板 | `cmd notification` / 剪贴板接口 | 【待验证】 |
| 精确控件语义 / 虚拟屏 | 依赖无障碍服务与 App | ❌ **替代不了** |

→ 建议：**容器为主，保留一个极薄的 Android 桥**（复用 DSHA 的 `/app/*`，或写几十行 root HTTP 桥）。

---

## 9. 风险与未验证项清单

| # | 项 | 类型 | 影响 | 怎么消解 |
|---|---|---|---|---|
| 1 | ~~chroot 容器里 `node-pty` 能否起 PTY~~ | **✅ 已闭环（proot 实测 2026-10 + 真 chroot 复验 2026-10-18）** | 命门已解除 | 见 §9.1 / §9.1.1 |
| 2 | ~~内核是否支持 overlayfs~~ | **已消解** | 容器分层改用 **bind(ro) + active 指针**，不依赖 overlayfs（ADR-009） | 无需验证 |
| 3 | ~~`--port 0` 的端口如何读出~~ | **✅ 已消解（2026-10-16 实测）** | 端口从启动行 stdout 解析（实测 → `39895`）；DSH_HOME 无端口文件 | 已闭环，见 §6.2 |
| 4 | SELinux 强制下 chroot + bind + 网络 | 【待验证】 | 可能被 neverallow 拦 | 先跑最小 chroot |
| 5 | chroot-distro 不校验下载哈希 + 部分源明文 http | **【已验证】** | 供应链风险 | 自备 rootfs tarball 并自校验（见 pitfalls §A10） |
| 6 | OTA 覆盖 boot → 退回 LKM | 【推断】 | 自定义内核失效 | 阶段一不依赖内核，天然免疫 |
| 7 | DSH 0.2.x API/插件格式漂移 | 【已验证的事实：0.2.x 早期】 | 升级可能踩坑 | floor 闸门 + 基线可回滚 + 版本层隔离 |
| 8 | ~~9 个已装模块与新方案冲突~~ → **清单已列**（2026-10-16），元模块确认为 `magic_mount_rs` | **已消解（信息层面）** | 挂载方式是否互相干扰，仍需真 chroot 试跑时观察 | 清单见 §2 表格 |
| 9 | **DSH 沙箱在本机不可用**：`landlock-run --probe` rc=125（内核未启用 Landlock ABI）、`bwrap` 未安装 | **已确认（2026-10-16 实测）** | Linux 沙箱链两档全废 → **受限模式 fail-closed**，开了反而让 bash 完全跑不了；而本机当前是 `danger-full-access`（沙箱短路 + approval=`never`） | 要真沙箱：容器里自带 `bwrap`，或用带 Landlock 的内核；注意 DSH 三个 mode 都不管网络/进程可见性，读取也不受其文件边界保护 |

---

### 9.1 命门实测记录（2026-10，本容器）

**结果：通过。**

```
环境: uid=0(root)  kernel 6.1.141-android14-11-o-g659d588fa0da
      /dev/ptmx 存在(crw-rw-rw-)   devpts /dev/pts devpts rw,seclabel,relatime,mode=600,ptmxmode=000
      容器内: node v24.19.0 + node-pty 1.2.0-beta.15（glibc 预编译）

通道1 node-pty : RESULT=OK  spawn -> "PTY_OK /dev/pts/0"，cols/rows 透传，exitCode 正确传播
通道2 python   : RESULT=OK  pty.fork() -> "PYPTY_OK /dev/pts/0"
```

**⚠️ 环境差异（必须写明）**：这里是 **DSHA 的 bxroot/proot 容器**，不是 chroot-distro 的 chroot。
之所以仍算强证据：**proot 才是有 syscall 拦截的那一层，chroot 比 proot 更贴近宿主**（同一内核、同一 devpts 挂载）；
而且 libc / Node / node-pty 的版本与目标基线一致（Ubuntu + Node 24 + node-pty 1.2.0-beta.15）。
→ 判定：**【高置信推断】chroot 里同样可用**，但仍应在真正的 chroot 容器里复验一次（脚本已备好）。

**附带发现（避免误判）**：**宿主**的 devpts 默认 `mode=600`，所以在**宿主**上看 `ls /dev/pts` 会 Permission denied，
但**分配 PTY 不受影响**（两条通道都拿到了 `/dev/pts/0`）。以后看到这个报错别当成"PTY 不可用"。

⚠️ **2026-10-18 修正**：这条只对**宿主**成立。**容器内**完全不同 —— chroot-distro 会挂一个**自己的 devpts 实例**
（其源码里 `mount -t devpts`），实测容器内 `ls /dev/pts/` 正常返回 `0 ptmx`。两件事别混。

**复验工具**：`tools/verify-pty.sh`（node-pty 与 python pty 双通道，任一路通过即 OK）

### 9.1.1 真 chroot 复验（2026-10-18，设备实测 → **命门完全闭环**）

环境：chroot-distro **2.1.0** + ubuntu **noble 24.04（arm64）**，宿主 mksh R59 / 一加 12 / Android 16。

```
root@localhost:~# python3 -c 'import pty;pty.spawn("/bin/sh")'
# tty
/dev/pts/0                      ← 真 chroot 里分配到了 PTY
# ls -l /dev/ptmx
crw-rw-rw-. 1 root root 5, 2 Oct 18 06:44 /dev/ptmx
# ls /dev/pts/
0  ptmx
```

**结论：PTY 在真 chroot 里可用** —— 这是 `node-pty` 的直接前提（它打开的就是 `/dev/ptmx`）。此前只在 proot/bxroot 容器里验证过，现在目标形态也验过了。

**两条容易误判的事实（记下来）**：

1. **chroot 里的 `/proc/mounts` 是宿主的那张表**（共享 mount namespace），所以会看到宿主的 `devpts … ptmxmode=000`。**它不代表容器内的可用性** —— 要看 `/dev/ptmx` 本身：这里是独立的字符设备 `5,2`、权限 `666`，并不走被 `ptmxmode=000` 卡住的那条符号链接路径。
2. 容器内的 `/dev/pts` 里能看到 `0` 和 `ptmx`，说明 chroot-distro 给它挂了**自己的 devpts 实例**（其源码 1100 行附近 `mount -t devpts`）。

---

## 10. 结论与下一步

**结论**：这条路可行，而且**第一版完全不碰内核**。

1. 阶段一：chroot-distro 模块 + Ubuntu 24.04 + 烘焙 DSH 基线 + 壳（版本闸门 + 控制面 + 文件通道）
2. 阶段二（已裁）：只有当你确实需要 systemd / NAT / GPU 直通时，才去编自定义内核 + Droidspaces；
   届时**只换 adapter，壳不动**

**下一步（按顺序，别跳）**
1. 回答 README §5 的三个问题（唯一实例？局域网还是外网？文件通道选哪个？）
2. ~~连上设备 shell 通道~~ → **2026-10-16 已连上（root）并跑完只读核查**；`kernelsu.ko` 只留下一条事实：**随 boot / init_boot 镜像走**（`/proc/modules` 中 `kernelsu … Live`）。原计划的 "vermagic 核对" **整项作废**——阶段二已裁，没有在排期的阶段需要它（理由见 [README §5](../README.md)）
3. 做**最小可行性验证**：容器里跑通 `node-pty` + `dsh web --port 0`
4. 才写壳的骨架（`manifest.json` / `dsh` wrapper / `dsh-update` / `service.sh` / `broker.py`）
5. 最后才做 payload 打包与离线安装


---

## 11. 多实例并存问题说明（"唯一实例 vs 并存"到底在问什么）

### 11.1 "一个 DSH 实例"是什么

一个 `dsh` 进程 + 它的**状态根（DSH_HOME）** + **profile（插件集）** + **工作区** + **监听端口**。

你现在这台机器上**已经有一个在跑**：本会话的 DSH web 在 `127.0.0.1:3080`、DSHA 桥在 `3090`、状态根是 `/root/.dsh`——**它就是 DSHA 那套**。
你计划在 chroot 容器里再起一个 → 于是变成两个。

### 11.2 能不能并存？**能，DSH 本来就是多实例友好的**

**【已验证】** 证据：

| 机制 | 事实 |
|---|---|
| `DSH_HOME` | `dsh-home-paths` 文档原文：「显式路径优先于 `$DSH_HOME`，后者优先于 `~/.dsh`；空白环境变量会被忽略」 |
| `--profile <name>` | 每个 profile 有自己的 `cordis.yml` / `package.json` / `node_modules`，即**插件集可分离** |
| `--port 0` | 端口可让 OS 分配，多个实例不会抢同一个端口 |
| 会话锁语义 | `session.lock` 上的**非阻塞 flock** 排的是"**同一个会话**的第二个写入方"，**不是**"整个产品只能有一个进程" |

### 11.3 真正会撞的地方（这是这个问题真正的含义）

| # | 撞点 | 现状证据（本机 `/root/.dsh`） | 后果 | 隔离办法 |
|---|---|---|---|---|
| 1 | **状态根** | `profiles/`、`sessions/`、`attachments/`、`cache/`、`storages/`、`credential-paths.json` | 插件、凭据、设置全共享 | **每实例一个 `DSH_HOME`** |
| 2 | **插件安装账本** | `plugin-sources.json`、`plugin-install-operations/`、`plugin-dependency-locks/`（按依赖哈希 + `completed`）、`plugin-transactions.py` | 已有跨进程锁（`plugin-manager.py` 里 `fcntl.flock(LOCK_EX\|LOCK_NB)`），但"一个实例正在用某插件、另一个把它升级掉"仍会发生 | 分离 HOME + 分离 profile |
| 3 | **迁移脚本** | `rc1-migration.py`、`rc1-settings-migration.cjs`、`legacy-preset-convert.cjs` | **不同版本**对同一份共享状态跑迁移 → 互相踩 | 分离 HOME（**版本不同时尤其必须**） |
| 4 | 会话 | `session.lock` 按会话互斥 | 同一会话第二个实例打不开（**这是特性**） | 各用各的会话 |
| 5 | 端口 | DSHA 桥 `3090`、当前 DSH web `3080` | 第二实例抢端口 | `--port 0` |
| 6 | 工作区 | — | 两个 agent 改同一批文件 | 工作区目录分开 |
| 7 | 磁盘/内存 | 每实例 439 MB + profile `node_modules` + pnpm store | 两实例 ~1 GB 起 | 接受；或共享 pnpm store（**先别**，见 11.5） |

### 11.4 这条决策的真正分歧点不是"能不能"，而是**要不要保留 DSHA 的能力面**

| | 唯一实例（容器） | 并存 |
|---|---|---|
| 设备控制（读屏/点按/通知/剪贴板/虚拟屏） | ❌ 默认失去，要靠 root CLI 重建（覆盖不全，见 §8） | ✅ 原样保留（DSHA 的 `/app/*` 桥） |
| 迁移成本 | 要把凭据/设置搬到容器 | 零迁移，两套各自独立 |
| 资源 | 一份 | 两份（~1 GB + 内存） |
| 复杂度 | 低 | 中（必须严格三分离） |
| 长期 | 干净、可掌控 | 两套同时维护，容易分叉 |

### 11.5 结论：**已决定"先并存"**（见 [ADR-004](./decisions.md)）

> 成本修正：DSHA **不是我们在维护**，所以"并存 = 两套都要维护、会分叉"的代价**不成立**。
> 并存的真实代价只剩：资源占用（~1 GB/实例）+ 分离纪律 + 心理负担。

以下为并存期必须遵守的纪律：

1. **红线**：**不要让两个实例共用一个 `DSH_HOME`**——尤其两边版本不同时（迁移脚本 + 插件账本会互相踩）
2. profile 名字分开（`--profile container` vs 现有 `web`）
3. 工作区目录分开
4. 端口一律 `--port 0` + 由壳发布
5. pnpm store：**先分开**（最稳）；等确信两实例不会同时装插件，再考虑共享省盘
6. 明确分工：**DSHA 那套管设备控制，容器那套管计算/文件/长期服务**

切到"唯一实例"的时机：当容器那套能独立完成你日常 90% 的操作，再迁移凭据/设置、冻结 DSHA 的 DSH、并按 pitfalls §B7 补上设备桥。

---

## 12. 能力插件：写"约定"，不写"管理器"

见 [ADR-008](./decisions.md)。要点：

```
/data/local/dsh/caps/<name>/
├── cap.json      # name / version / requires(root,wifi,ports) / health / start / stop
├── start.sh      # 或 start.py
└── stop.sh
```

壳对能力的全部职责：

1. **扫描** `caps/*/cap.json`
2. **按条件启停**（例如 `requires.wifi` 不满足就不启）
3. **健康探测**并把端口并入 `run/caps.json`（与 DSH 的 `run/dsh.json` 同一套原子写）

**明确不做**：依赖解析、版本约束、远程仓库、UI、权限模型、沙箱、回滚。
触发条件满足任一条再谈（能力 ≥5 / 第三方分发 / 版本矩阵 / 沙箱与权限隔离）。

> DSH 侧那一半**不要碰**：它已经有 `plugin-manager.py` / `plugin-transactions.py` / `plugin-dependency-locks/` / `plugin-semver.cjs` 这一整套。

---

## 附：本项目的证据来源

| 证据 | 获取方式 |
|---|---|
| 设备/系统信息 | `/app/device`、`/app/apps`、`/app/version` |
| Root 形态 | ReSukiSU 管理器截图 |
| DSH 安装体积与依赖树 | 本容器 `du -sh`、`node_modules` 遍历 |
| 原生依赖 libc 覆盖 | 本地 `package.json` 的 `libc` 字段 + npm registry 查询（含 404 验证） |
| `dsh web` 参数 | `node lib/bin.js web --help` |
| chroot-distro 模块内部 | 下载 release zip 解包 + 逐行阅读 + git 全历史 clone |
| 上游 Python 版行为 | 本地 clone 源码（`constants.py` / `helpers/android.py` / `elevate.py` / `syscalls/`） |
| 内核/容器方案 | `cctv18/oppo_oplus_realme_sm8650` 的 workflow 与 builder 脚本、`ravindu644/Droidspaces-OSS` 文档 |
