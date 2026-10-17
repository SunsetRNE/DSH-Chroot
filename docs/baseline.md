# 基线定义与依赖审计

> 标注：**【已验证】** 本容器实测 / 源码 / npm registry；**【待验证】** 需真机确认。

---

## 1. 基线（Baseline）

| 组件 | 版本 | 为什么是它 | 状态 |
|---|---|---|---|
| 容器发行版 | **Ubuntu 24.04 LTS (noble) arm64** | DSHA 已验证的组合；`node-pty` 只有 glibc 预编译 | 【已验证】DSHA README 明示其离线 rootfs 是 Ubuntu 24.04 arm64 |
| Node.js | **24.x（钉死到具体小版本）** | 官方 `linux-arm64` 二进制即 glibc，可完全 pin，不依赖发行版仓库 | 【已验证】DSHA 容器内 `node -v` = v24.19.0 |
| npm | 11.x（随 Node 自带） | 只需用于一次性安装/升级 | 【已验证】11.17.0 |
| pnpm | **10.x** | DSH **运行时真的在用 pnpm**（插件依赖安装） | 【已验证】10.34.5；`lib/bin.js`、plugin bundle 中均出现 |
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
| `baked` | 烘焙进 payload 的 DSH 版本 | 模块 | 刷模块 / 换 payload |
| `floor` | **硬下限**：低于它就拒绝运行/安装 | 模块 | 刷模块 |
| `recommended` | 软提示，不拦 | 模块 | 刷模块 |
| `node_floor` | Node 最低版本 | 模块 | 刷模块 |
| `layers` | 各层的 sha256，用于启动校验 | 模块 | 刷模块 |
| `state_version` | 状态目录结构版本（**禁止版本层触碰**） | 壳 | 结构变更时 |

**不放进 manifest 的东西**：用户当前选择的版本（在 `active` 指针里）、端口（在 `run/`）、凭据（在 `state/`）。

---

## 5. payload 规范（离线烘焙包）

```
dsh-payload-<baked>-<arch>.tar.zst
└── base/
    ├── node/                 # node 24 + npm + pnpm（官方二进制）
    └── dsh-<baked>/          # npm i -g @deepseek-ai/dsh@<baked> --prefix 后的完整树
└── payload.json              # {baked, node, pnpm, sha256:{...}}
```

**分发三件套**（体积差 3 个数量级，别混在一起）：

| 件 | 大小 | 内容 | 更新频率 |
|---|---|---|---|
| 模块 zip | KB 级 | CLI + 壳 + manifest + wrapper | 逻辑更新 / floor 抬高 |
| payload 包 | ~1 GB 级 | Ubuntu rootfs + Node + pnpm + DSH 基线 | baked 版本变化 |
| state 目录 | 用户自己的 | `~/.dsh` + pnpm store | **永不覆盖** |

模块首启：`base/` 存在且 hash 匹配 → 直接用；否则找 payload（预置 `/sdcard/Download/` 或下载）→ 解包 → 校验 → 落盘。

---

## 6. 复现步骤（大纲，尚未实施）

1. 建 Ubuntu 24.04 chroot（`chroot-distro install ubuntu` 选 noble）
2. 容器内装 Node 24（官方 arm64 二进制，钉小版本）+ **pnpm 11.x**（≥ 上游 pin `11.28.5`，见 ADR-011 决定 A.4；本容器当前是 10.34.5，**不要照抄**）
3. `npm i -g @deepseek-ai/dsh@0.2.0-rc.2 --prefix /opt/dsh/base/dsh-0.2.0-rc.2`
4. **验证三件事**（任何一条不过就不要继续）：
   - [x] `node-pty` 能起 PTY（**✅ 2026-10 于 proot 容器实测通过**；chroot 里用 `tools/verify-pty.sh` 复验）
   - [ ] `dsh --version` / `dsh web --port 0` 能跑起来
   - [ ] 容器内 DNS 与 TLS 正常（`/etc/resolv.conf`、CA bundle）
5. 打 payload：`tar -czf`（gzip；⛔ 不用 zstd —— 设备侧与容器侧都没有，见 ADR-013 决定 C）+ 生成 `payload.json`（每层 sha256）
6. 写壳（manifest + wrapper + dsh-update + service.sh + broker.py）
7. 端到端：解包 → 校验 → 起 DSH → 壳发布端口 → 平板访问（记得 `--trusted-host`）

---

## 7. 基线变更纪律

- **升级 baked**：换 payload + 抬 versionCode；**floor 是否跟着抬由你决定**（抬 floor 会自动停用低于它的用户层）
- **升级 Node**：必须重跑 `node-pty` 验证（原生模块 ABI 敏感）
- **升级 pnpm**：低风险，但记得 pnpm store 版本兼容性
- **任何时候不要**把 `state/` 内容打进 payload
