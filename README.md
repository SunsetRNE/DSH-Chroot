# DSH Chroot

> 把 **DeepSeek Harness (DSH)** 装进 Android 的 root 模块 —— **真 chroot，不是 proot**。

**状态：早期开发中。还没有 Release** —— 仓库里目前是设计文档与工具链，模块包尚不可用。

---

## 这是什么

在手机上给 DSH 一套**真的 Linux 用户态**：Ubuntu 24.04 (glibc) + Node 24 + pnpm，跑在 root 模块托管的 chroot 里。
外面套一层"壳"，负责**版本闸门 + 生命周期 + 端口发现 + 受控的局域网访问 + 文件通道**。

设计原则只有一条：**只依赖窄接口，让下面每一层都可替换** —— DSH 换版本、容器运行时换实现、内核被 OTA 覆盖回退，壳都不用重写。

## 这**不是**什么（读之前先对齐预期）

| 看着像 | 实际是 | 原因 |
|---|---|---|
| 又一个 proot / Termux 方案 | **真 chroot，需要 root** | 不用 ptrace 拦系统调用，DSH 直接跑在真实 syscall 上 |
| 一个沙箱 / 安全边界 | ⛔ **不是隔离** | chroot 与宿主共享内核；容器里的服务就是宿主的 `127.0.0.1:PORT`。见 [威胁模型](docs/threat-model.md) §5「不设防声明」 |
| Docker / LXC | 没有命名空间隔离 | 只有 chroot + bind 挂载，没有 PID / net / mount namespace |

## 和同类项目的区别

安卓上的 DSH 方案（DSHA、deepseek-harness-mobile、Luwi、LittleWhale、dsh-pocket ……）**全部免 root**：proot、Termux 快照、或 WebView + 内置运行时。

**本项目是唯一要求 root 的那一类。** 只有 root 才拿得到真 chroot、开机自启、system 级挂载：

- 收益：没有 ptrace 开销、没有 proot 的兼容性坑、可以随开机自启
- 代价：必须刷 root，且**它不是安全边界**

## 要求

| 项 | 值 |
|---|---|
| 设备 | 一加 12（PJD110）/ Android 16（实测环境）；其他 arm64 + Android 14+ **未验证** |
| Root | KernelSU 系（本项目在 ReSukiSU/BakaSU LKM 上验证）或 Magisk |
| 容器运行时 | [chroot-distro](https://github.com/Magisk-Modules-Alt-Repo/chroot-distro) 模块 |
| 空间 | 约 2 GB（Ubuntu rootfs + Node + DSH 基线） |

## 安装

⛔ **还没有 Release，现在装不了。** 首个版本发布后这里会写成三步：

1. 从 Releases 下载 `DSH-Chroot-<version>.zip`
2. 在 Root 管理器里安装 → 重启
3. `dsh-ctl start`，打开它打印的 URL

## 模块身份

| 字段 | 值 |
|---|---|
| `id` | `Zodiac-Quill-Saga` |
| `name` | `DSH Chroot` |
| `version` | `1.0.2.2`（第 4 位 = 烘焙台账序号，`2` = 第 2 次烘焙 = DSH `0.2.1-rc.4`；见 [versioning §2](docs/versioning.md)） |

为什么 id 与仓库名不一样 → [docs/versioning.md §8](docs/versioning.md)（"越少人看见的字段，越可以讲风格"）。

## 文档

| 文档 | 内容 |
|---|---|
| [docs/guide.md](docs/guide.md) | **内部项目指引**：进度 / 决定速查 / 待办（想快速看懂全貌从这里进） |
| [docs/research.md](docs/research.md) | 架构与路线研究：目标、盘点、路线比较、端口与通信 |
| [docs/decisions.md](docs/decisions.md) | **ADR-001 ~ ADR-026**：26 条独立决策 + 代价 + 重审触发 |
| [docs/threat-model.md](docs/threat-model.md) | 威胁模型，含 §5「不设防声明」 |
| [docs/baseline.md](docs/baseline.md) | 基线定义：Ubuntu 24.04 / Node 24 / pnpm 11.x / DSH 基线 |
| [docs/versioning.md](docs/versioning.md) | 版本号、`module.prop`、命名分工、semver 闸门 |

## 开发

不需要任何依赖（只要 python3 与 node）：

```bash
python3 tools/check-gate.py             # 三份实现 × 一张向量表（版本比较写错是静默错误，这里不靠自觉）
python3 tools/test-versioning.py        # 版本真源契约：台账派生 / 拒绝类断言 / 漂移检测
python3 tools/gen-version.py            # 从三个真源生成 build/（发布模式；占位会直接报错）
python3 tools/build-module.py           # 打模块 zip（< 1 MB、确定性；见 docs/module.md）
```

需要说明的一点：版本比较是本项目**唯一写错会静默出错**的地方 —— `"0.2.1-rc.1" < "0.2.0-rc.2"` 在字典序上成立，
语义上恰好相反。所以它有三份实现（Python / POSIX sh / Node）、一张共同的向量表，改规则必须三处一起过。

## 许可

[MIT](LICENSE) © 2026 SunsetRNE

