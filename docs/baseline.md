# 基线定义与依赖审计

> 标注：**【已验证】** 本容器实测 / 源码 / npm registry；**【待验证】** 需真机确认。

---

## 1. 基线（Baseline）

| 组件 | 版本 | 为什么是它 | 状态 |
|---|---|---|---|
| 容器发行版 | **Ubuntu 24.04 LTS (noble) arm64** | DSHA 已验证的组合；`node-pty` 只有 glibc 预编译 | 【已验证】DSHA README 明示其离线 rootfs 是 Ubuntu 24.04 arm64 |
| Node.js | **24.21.0（烘焙值）** | 官方 `linux-arm64` 二进制即 glibc，可完全 pin；与上游 `primary-runtime` pin 对齐（ADR-011） | 【已验证】官方 tarball sha256；`node -v` = v24.21.0；开发容器 24.19.0 只是验证环境 |
| npm | 11.19.0（随 Node 24.21.0） | 只需用于一次性安装/升级 | 【已验证】`npm -v` = 11.19.0 |
| pnpm | **11.28.5** | DSH **运行时真的在用 pnpm**；与上游 `packageManager` pin 对齐（10→11 横跨 `allowBuilds` / `strictDepBuilds` 语义） | 【已验证】registry sha512；`pnpm -v` = 11.28.5 |
| DSH | **@deepseek-ai/dsh@0.2.0-rc.2** | DSHA 内跑的就是它；本容器安装的也是它 | 【已验证】`package.json` + `APP_VERSION=…-dsh0.2.0-rc.2` |
| 容器运行时 | chroot-distro 模块（release 2.1.0 骨架 + main 分支脚本） | 原厂内核 + LKM 即可运行 | 【已验证】见 research §3.1 |
| 容器路径 | `/data/local/chroot-distro/<distro>/` | chroot-distro 默认 | 【已验证】源码常量 |

**pin 原则**：Node 与 pnpm 都**不要**用发行版仓库的版本（`apt install nodejs`），而是用官方二进制 / 独立包，
理由是"烘焙基线必须可复现"——发行版仓库的版本会随 `apt upgrade` 漂移，而你的 floor 语义建立在一个确定版本上。

> 注：DSH 的 `package.json` **没有 `engines` 字段**，Node 版本要求不会自动拦你**【已验证】**。
> 所以 Node 版本要由**你的 manifest** 兜住（`node_floor`）。

---

## 2. 依赖 libc 审计（这是选 Ubuntu 的决定性证据）

对 DSH 安装树里的原生（.node）依赖逐个核对 `libc` 字段，并去 npm registry 确认对侧包是否存在：

| 包（arm64） | glibc | musl | 证据 |
|---|---|---|---|
| `@deepseek-ai/node-addon-system-linux-arm64` | ✅ `bin/glibc/system.node` | ✅ `bin/musl/system.node` | 本地解包目录结构 |
| `@koromix/koffi-linux-arm64` | ✅ `linux_arm64/` | ✅ `musl_arm64/` | 本地目录结构 |
| `@ubjs/node-linux-arm64-{gnu,musl}` | ✅ | ✅ | npm registry 两包都在 |
| `node-addon-require-builtin-linux-arm64-{gnu,musl}` | ✅ | ✅ | npm registry 两包都在 |
| `@img/sharp-linux{,-musl}-arm64` | ✅ | ✅ | npm registry（0.35.5） |
| `sherpa-onnx-linux-arm64` | 单一包，**无 libc 字段** | ❓ | **【待验证】** |
| **`node-pty` 1.2.0-beta.15** | ✅ `prebuilds/linux-arm64/pty.node` | ❌ **tarball 内只有 `linux-arm64` / `linux-x64`，无 `linuxmusl`** | 下载 npm tarball 列出条目 |
| **`@trycua/cua-driver-linux-arm64-gnu`** | ✅ | ❌ **musl 包 404**；其 `optionalDependencies` 只有 `-gnu` / `-msvc` / `-darwin` | npm registry 查询 |

**结论**

1. `node-pty` 是 agent runtime 的**命脉**（终端 / 子进程），它**只发 glibc 预编译**。
   Alpine 上要么在容器里装 `build-base python3` 现场编译（**打破"离线烘焙、免编译"的前提**），要么终端能力瘸掉。
   > 附注：`node-pty` 的 npm `latest = 1.1.0` **连 Linux 预编译都没有**，DSH 锁的是 `1.2.0-beta.15` 才有带 `linux-arm64` 的 tarball。**升级 node-pty 前必须核对预编译是否还在。**
2. `cua-driver` 在 musl 上**不是崩溃，是静默降级**（optionalDependency 被跳过）——比报错更难查。
3. 因此：**Ubuntu 24.04 (glibc) 是本依赖树里唯一不需要现场编译、也不需要接受静默降级的选择。**

**体积对照（说明"Alpine 更小"在本题里是噪声）**

| 项 | 量级 |
|---|---|
| Alpine rootfs 基座 | ~5–8 MB |
| Ubuntu rootfs 基座 | ~30–80 MB |
| **DSH 本体（含 node_modules）** | **439 MB** 【已验证】 |
| 设备可用空间 | **582.94 GB** 【已验证】 |

→ 基座差 50 MB 相对 439 MB 是 **<12% 的噪声**，何况设备有 582 GB。

---

## 3. 目录与挂载规范

见 [research.md §4.2](./research.md)。要点复述：

```
/data/local/dsh/
├── state/          # ~/.dsh（profiles/sessions/凭据）+ pnpm-store —— 跨版本持久，禁止进版本目录
├── base/           # 烘焙基线（node/ + dsh-<ver>/），启动前校验 hash
├── user/           # 用户升级层 dsh-<ver>/
├── active          # 原子指针（tmp + os.replace）
├── manifest.json   # 版本闸门数据
└── run/            # 端口 JSON / UDS / 日志
```

容器内：

| 容器内路径 | 指向 | 读写 |
|---|---|---|
| `/usr/local/lib/node_modules/@deepseek-ai/dsh` | active 层 | **只读 bind** |
| `/opt/dsh/base` | `base/` | 只读 |
| `/root/.dsh` | `state/dot-dsh/` | 读写 |
| `/usr/local/bin/{dsh,node,npm,pnpm}` | 壳 wrapper | 壳管 |

---

## 4. manifest 规范

字段定义（示例见 [baseline/manifest.example.json](../baseline/manifest.example.json)）：

| 字段 | 含义 | 谁写 | 变化时机 |
|---|---|---|---|
| `baked` | 烘焙进 payload 的 DSH 版本（烘焙台账最后一条） | 生成器 | 台账记一行换基线 |
| `baked_seq` | 第几次烘焙（= `version` 第 4 位） | 生成器 | 台账记一行换基线 |
| `floor` | **硬下限**：低于它就拒绝运行/安装；与 `baked` **不必相等** | 生成器（源：`baseline/dsh.env`） | 抬下限（与第 4 位无关） |
| `recommended` | 软提示，不拦 | 生成器（源：`baseline/dsh.env`） | 想推荐时 |
| `node_floor` | Node 最低版本 | 生成器（源：`baseline/dsh.env`） | 换 Node 时 |
| `layers` | 各层的 sha256，用于启动校验 | 构建器 + 生成器 | 重打 payload |
| `state_version` | 状态目录结构版本（**禁止版本层触碰**） | 壳 | 结构变更时 |

> `baked` / `baked_seq` 与 `floor` 分属两个来源（[bake-ledger](../baseline/bake-ledger.json) / [dsh.env](../baseline/dsh.env)），
> 这是 [ADR-025](./decisions.md) 的核心：**第 4 位只跟 `baked`**，`floor` 不进版本号。

**不放进 manifest 的东西**：用户当前选择的版本（在 `active` 指针里）、端口（在 `run/`）、凭据（在 `state/`）。

---

## 5. payload 规范（离线烘焙包）

两层、四个文件（完整规范见 [payload.md](./payload.md)）：

```
node-<ver>.tar.gz   + node.json     # node + npm + pnpm（官方二进制）
dsh-<baked>.tar.gz  + dsh.json      # @deepseek-ai/dsh 完整树 + bin wrapper
```

`baked` 的默认值取自 [bake-ledger.json](../baseline/bake-ledger.json) 的最后一条（ADR-025）；压缩用 gzip（ADR-013 决定 C，⛔ 不用 zstd）。

**分发三件套**（体积差 3 个数量级，别混在一起）：

| 件 | 大小 | 内容 | 更新频率 |
|---|---|---|---|
| 模块 zip | KB 级 | CLI + 壳 + manifest + wrapper | 逻辑更新 / floor 抬高 |
| payload 包 | 两层合计 ≈180 MiB（压缩后） | Node + pnpm + DSH 基线（**不含 rootfs**） | Node 变 / baked 变 |
| state 目录 | 用户自己的 | `~/.dsh` + pnpm store | **永不覆盖** |

模块首启：`base/` 存在且 hash 匹配 → 直接用；否则找 payload（预置 `/sdcard/Download/` 或下载）→ 解包 → 校验 → 落盘。

---

## 6. 复现步骤（2026-10-19 已按此烘出一版；产物见 payload.md §4）

1. 建 Ubuntu 24.04 chroot（`chroot-distro install ubuntu` 选 noble）
2. 容器内装 **Node 24.21.0**（官方 arm64 二进制）+ **pnpm 11.28.5**（上游 pin，见 ADR-011 决定 A.4；开发容器是 24.19.0 / 10.34.5，**不要照抄**）
3. `npm i -g @deepseek-ai/dsh@0.2.0-rc.2 --prefix <stage>`（或复用已按本基线验证过的安装树）
4. **验证三件事**（任何一条不过就不要继续）：
   - [x] `node-pty` 能起 PTY（**✅ 2026-10 于 proot 容器实测通过**；chroot 里用 `tools/verify-pty.sh` 复验）
   - [x] `dsh --version` = `0.2.0-rc.2`（2026-10-19 在 Node 24.21.0 下实测）；`dsh web --port 0` 待 runtime adapter
   - [ ] 容器内 DNS 与 TLS 正常（`/etc/resolv.conf`、CA bundle）
5. 打 payload：`tools/build-payload.py --kind node|dsh`（确定性 gzip；⛔ 不用 zstd，见 ADR-013 决定 C），每层出 `<kind>.json`（sha256 + size）
6. 写壳（manifest + wrapper + dsh-update + service.sh + broker.py）
7. 端到端：解包 → 校验 → 起 DSH → 壳发布端口 → 平板访问（记得 `--trusted-host`）

---

## 7. 基线变更纪律

- **升级 baked**：在 [baseline/bake-ledger.json](../baseline/bake-ledger.json) 末尾追加一行（`seq` +1）→ `version` 第 4 位与 `manifest.baked` 自动更新；然后再打 payload。**不记账，生成器就拒绝**（ADR-025）
- **floor 与 baked 是两件事**：**floor 是否跟着抬由你决定**（抬 floor 会自动停用低于它的用户层），它**不改变** `version` 第 4 位
- **同一 baked 重打 payload**（只改了 wrapper / 压缩参数）：不记账，抬 `version` 第 3 位
- **升级 Node**：必须重跑 `node-pty` 验证（原生模块 ABI 敏感）
- **升级 pnpm**：低风险，但记得 pnpm store 版本兼容性
- **任何时候不要**把 `state/` 内容打进 payload
