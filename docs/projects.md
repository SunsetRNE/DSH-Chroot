# 涉及项目清单

> 星数为查询时快照，仅作"活跃度参考"，不是质量背书。
> 结论列：✅ 采用 / ⏸ 备选（触发条件见"触发"列）/ ⛔ 不用（附原因）

---

## 1. 容器运行时（L1）

| 项目 | 形式 | 星 | 在本方案里的角色 | 结论 / 触发 |
|---|---|---|---|---|
| [Magisk-Modules-Alt-Repo/chroot-distro](https://github.com/Magisk-Modules-Alt-Repo/chroot-distro) | **Magisk/KSU 模块**（一个 sh CLI，18 KB zip） | 502 | **阶段一的容器运行时** | ✅ 采用 |
| [sabamdarif/chroot-distro](https://github.com/sabamdarif/chroot-distro) | pip CLI（Python 3.10+，Docker Hub 拉镜像） | 161 | 功能强得多（build/OCI/isolation），但不再是模块 | ⏸ 备选：需要"任意 Docker 镜像"时，塞进容器内运行（见 pitfalls §B6） |
| [LightNabz/chroot-distro](https://github.com/LightNabz/chroot-distro) · [YasserNull/chroot-distro](https://github.com/YasserNull/chroot-distro) | 模块 fork | 0 / 3 | 参考实现 | ⛔ 除非上游挂掉 |
| [ravindu644/Droidspaces-OSS](https://github.com/ravindu644/Droidspaces-OSS) | 二进制（<400 KB）+ Android App | 2321 | 真容器：容器内 PID 1、NAT/gateway/macvlan、GPU/USB 直通、`/data/local/Droidspaces` | ⏸ **阶段二已裁**；触发：确实需要 systemd / NAT / GPU 直通 |
| [Goldzxcbug/Droidspaces_Kernel_patch](https://github.com/Goldzxcbug/Droidspaces_Kernel_patch) · [Droidspaces/Droidspaces-rootfs-builder](https://github.com/Droidspaces/Droidspaces-rootfs-builder) · [Goldzxcbug/Droidspaces-rootfs-Desktop-builder](https://github.com/Goldzxcbug/Droidspaces-rootfs-Desktop-builder) | 内核补丁 / rootfs 构建 | 83 / 83 / 232 | 阶段二配套 | ⏸ 同上 |
| [lfdevs/mesa-for-android-container](https://github.com/lfdevs/mesa-for-android-container) | 容器内 Mesa（Adreno 硬件加速） | 362 | 阶段二想做桌面时的图形栈 | ⏸ 同阶段二 |

---

## 2. 同类容器模块（横向参考，大多可直接借用思路）

| 项目 | 特点 | 星 | 结论 |
|---|---|---|---|
| [FerryAr/lhroot](https://github.com/FerryAr/lhroot) · [Magisk-Modules-Alt-Repo/lhroot](https://github.com/Magisk-Modules-Alt-Repo/lhroot) | Linux Chroot Installer & **Bootscript** 模块 | 226 / 56 | ⏸ 参考它的"开机自动起服务"写法 |
| [shakir2117/Nethunter_4_KSU](https://github.com/shakir2117/Nethunter_4_KSU) | Kali NetHunter 模块，**自动识别 Magisk / KernelSU Next**，`post-fs-data` 挂 BusyBox | 12 | ⏸ 参考它的"多 root 管理器自适应" |
| [S1LENCE-D/astrbot-mubuntu](https://github.com/S1LENCE-D/astrbot-mubuntu) | **KSU/Magisk/APatch 模块，在 Ubuntu 24.04 chroot 里部署一个应用** | 1 | 👀 **最贴近我们要做的事的现成范例**，动手前值得读一遍 |
| [FLYCOM-E/Ubuntu-For-Android](https://github.com/FLYCOM-E/Ubuntu-For-Android) | arm64 Ubuntu chroot 模块 | 8 | ⏸ 参考 |
| [Geofferey/com.geofferey.bootdebi](https://github.com/Geofferey/com.geofferey.bootdebi) | Debian chroot + **开机起服务** | 2 | ⏸ 参考 |
| [lishxlin/Alpine_as_Magisk_module](https://github.com/lishxlin/Alpine_as_Magisk_module) · [chuanglizhe/alpine-linux-magisk](https://github.com/chuanglizhe/alpine-linux-magisk) | Alpine 最小 chroot 模块 | 10 / 1 | ⛔ 本方案不选 musl（见 baseline §2） |

---

## 3. Root 层（L0 之上）

| 项目 | 角色 | 星 | 结论 |
|---|---|---|---|
| [Baka-SU/BakaSU](https://github.com/Baka-SU/BakaSU)（**原 ReSukiSU**，仓库整体改名，release 资产名仍叫 `ReSukiSU_*`） | **你正在用的 root（LKM 模式）** | 1876 | ✅ 现状，不动 |
| [tiann/KernelSU](https://github.com/tiann/KernelSU) · [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) · [SukiSU-Ultra](https://github.com/SukiSU-Ultra/SukiSU-Ultra) | 其他 KSU 分支 | 19257 / 4476 / — | ⛔ 除非换内核，否则没必要换 |
| [bmax121/KernelPatch](https://github.com/bmax121/KernelPatch)（APatch 内核侧） | KPM（内核补丁模块）机制来源 | — | ⏸ 进阶：KPM 只能改已有函数，**不能补内核子系统**（见 pitfalls §B2） |
| [HSR-Firefly/kernelsu-module-dev-skill](https://github.com/HSR-Firefly/kernelsu-module-dev-skill) | 一个 **DSH Skill**，教 AI 打包 KernelSU 模块 | 0 | 👀 写模块时可以让 agent 用它 |

---

## 4. 内核（阶段二，已裁，存档）

| 项目 | 角色 | 星 | 结论 |
|---|---|---|---|
| [cctv18/oppo_oplus_realme_sm8650](https://github.com/cctv18/oppo_oplus_realme_sm8650) | SM8650/MT6989/MT6897 通用内核**自动编译流水线**（OKI 模式，Clang 20，ccache ~6 min） | 500 / **1489 forks** | ⏸ 阶段二备用。6.1.141 分支 = `oneplus/sm8650_b_16.0.0_oneplus12_6.1.141`（**与你的机器同源**） |
| 同上 workflow 的关键输入 | `ksu_type=bakasu`（兼容 sukisu 管理器）/ `droidspaces_enable=standard` / **`ssg_enable=false`（一加12 有已知启动失败）** | — | 见 pitfalls §B1 的"发车条件" |
| [WildKernels/OnePlus_KernelSU_SUSFS](https://github.com/WildKernels/OnePlus_KernelSU_SUSFS) | Droidspaces 社区设备列表里 OnePlus 系列的内核下载源 | — | ⏸ 同上 |
| [osm0sis/android-busybox-ndk](https://github.com/osm0sis/android-busybox-ndk) | chroot-distro **硬依赖** BusyBox ≥ 1.36.1 | — | ✅ **阶段一必须装** |

---

## 5. 壳要用到的工具（自选件）

| 能力 | 首选 | 备选 | 备注 |
|---|---|---|---|
| 文件通道 | **rclone**（`serve webdav/sftp/ftp/http`，单二进制） | Syncthing（双向同步） | 平板侧 WebDAV/SFTP 客户端遍地都是 |
| 公网访问 | **Tailscale / WireGuard（overlay）** | Cloudflare Tunnel / FRP→VPS | ⛔ 不做路由器端口映射 |
| 局域网发现 | 固定端口 + 手输；或读 `run/*.json`（**该文件由壳写，DSH 自己不落端口文件** —— 2026-10-16 实测） | mDNS（Android 上受限） | 【待验证】 |
| 设备桥替代 | `uiautomator` / `input` / `screencap` / `am` / `pm` | 复用 DSHA 的 `/app/*` | 能力对比见 research §8 |
| 打包 | `tar -czf`（**gzip**）或 `-cjf`（bzip2）；如需镜像化 → ext4 + loop | — | ⛔ **不用 zstd**：设备侧与容器侧都没有它（ADR-013 决定 C）；镜像化是进阶项 |

---

## 6. DSH 本体的依赖清单（基线的一部分，便于日后比对升级风险）

**【已验证】** `@deepseek-ai/dsh@0.2.0-rc.2` 直接依赖（节选，共上百个 `@deepseek-ai/*` 子包）：

- CLI/运行时：`commander`、`js-yaml`、`@deepseek-ai/cordis`、`cordis-plugin-{include,loader,timer}`、`dsh-hmr`
- 核心：`dsh-base`、`dsh-app-boot`、`dsh-cmdline`、`dsh-headless`、`dsh-fs-local`、`dsh-jobs-local`、`dsh-mcp-client`、`dsh-home-paths`、`dsh-compaction-*`、`dsh-goal*`、`dsh-schedule`、`dsh-subprocess-local`（← **node-pty 在这里**）
- 界面：一堆 `dsh-client-ui-*`
- **原生模块（升级时要重点复验）**：`node-pty`、`sharp`、`koffi`、`sherpa-onnx`、`@trycua/cua-driver`、`@ubjs/node`、`node-addon-require-builtin`、`@deepseek-ai/node-addon-system`

> 安装后总体积 **439 MB**；`package.json` **无 `engines` 字段** → Node 版本必须由你的 manifest 兜住。

---

## 7. 参考：DSHA 本身

| 项目 | 说明 |
|---|---|
| [DSH-APP/DSHA](https://github.com/DSH-APP/DSHA) | 免 root・免 Termux 的 APK；bxroot/proot + 完整 Ubuntu rootfs；**root/Shizuku/ADB 三通道共用一套命令白名单**；README 自述已知弱点含"**无内核级沙箱**" |
| 你机器上的形态 | `com.dsh.client` / `com.dsh.clienu`，APP_CODE 170，桥协议 3 |

我们不是"打败它"，而是**把它的环境层搬进 root 容器**；它的**设备桥能力要单独想办法保留**（research §8）。
