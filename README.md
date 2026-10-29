# DSH Chroot

> 把 **DeepSeek Harness (DSH)** 装进 Android 的 root 模块 —— **真 chroot，不是 proot**。

**状态：真机上跑通了（2026-10-29）** —— 模块包与 payload 都可用，`dsh web` 在 chroot 里起来并返回 200。
**但还没有 Release**：安装要走「自己打包 + 自己投 payload」的路径（见 [安装](#安装)）。

| 已验证 | 值 |
|---|---|
| 容器 | Ubuntu **24.04.3 LTS (noble)**，干净体积 105 MB |
| 运行时 | Node **24.21.0** + pnpm **11.28.5**（payload 两层：60.43 MiB / 153.7 MiB） |
| DSH | **0.2.1-rc.4**（烘焙台账 `seq=2`）；`start` 起在 `pid 22056` / `port 40537`（快照，每次启动端口不同） |
| 端到端 | 无 token **401**；带 token **200 / 37,971 B / `<title>DeepSeek Harness</title>`** |
| 自诊断 | `dsh-ctl diag` 六项证据全 ✓（`rc=0`） |

> 这些数字来自一加 12 / Android 16 的实测，不是设计目标。换机型没有验证过。

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

还没有 Release，所以是**四步**（第 3 步不做，前两步等于白装）：

1. 拿到模块包 `DSH-Chroot-<version>.zip` —— 自己打：`python3 tools/build-module.py`
2. 在 Root 管理器里刷入 → 重启
3. **投递 payload**：把 `node-24.21.0.tar.gz`、`node.json`、`dsh-0.2.1-rc.4.tar.gz`、`dsh.json`
   这四个文件放进 `/data/local/dsh/inbox/`，然后跑 `dsh-ctl bootstrap --offline`
4. `DSH_RUNTIME=real dsh-ctl start` —— 端口与 token 写在 `run/dsh.json`（0600，token 不进日志）

payload 不进 Release（压缩后 214 MiB）。来源只有两个：自己烘（[docs/payload.md](docs/payload.md)）
或从别处拷这四个文件。**哈希要与 `manifest.json` 的 `layers` 对得上**——目前运行时还没强制校验
（`guards.verify_layer_hashes` 未接线），但真值与实物不符就是隐患，别把它当"反正能用"。

卡住了先跑一条命令，别猜是哪一层：

```sh
dsh-ctl diag        # 0=没发现已知问题 / 1=命中（给错误码 + 自证命令 + 一个结论） / 2=缺报错表
```

`dsh-ctl` 的动词：`boot` · `start` · `stop` · `restart` · `status` · `bootstrap [--offline]` ·
`install <file>` · `logs [--tail N]` · `diag` · `help`（`repair` / `rebuild` / `upgrade` / `purge` 尚未实现，会明确报错）。

## 模块身份

| 字段 | 值 |
|---|---|
| `id` | `Zodiac-Quill-Saga` |
| `name` | `DSH Chroot` |
| `version` | `1.0.4.2`（第 4 位 = 烘焙台账序号，`2` = 第 2 次烘焙 = DSH `0.2.1-rc.4`；见 [versioning §2](docs/versioning.md)） |

为什么 id 与仓库名不一样 → [docs/versioning.md §8](docs/versioning.md)（"越少人看见的字段，越可以讲风格"）。

## 文档

| 文档 | 内容 |
|---|---|
| [docs/guide.md](docs/guide.md) | **内部项目指引**：进度 / 决定速查 / 待办（想快速看懂全貌从这里进） |
| [docs/research.md](docs/research.md) | 架构与路线研究：目标、盘点、路线比较、端口与通信 |
| [docs/decisions.md](docs/decisions.md) | **ADR-001 ~ ADR-030**：30 条独立决策 + 代价 + 重审触发 |
| [docs/errors.md](docs/errors.md) | **报错与定位**：错误码分层 + 每条绑一条探针 + 组合签名（脚本生成，不手改） |
| [docs/threat-model.md](docs/threat-model.md) | 威胁模型，含 §5「不设防声明」 |
| [docs/baseline.md](docs/baseline.md) | 基线定义：Ubuntu 24.04 / Node 24 / pnpm 11.x / DSH 基线 |
| [docs/versioning.md](docs/versioning.md) | 版本号、`module.prop`、命名分工、semver 闸门 |
| [docs/module.md](docs/module.md) | 模块包布局（14 条目）、安装流程、为什么壳放在 `bin/` |
| [docs/payload.md](docs/payload.md) | payload 规范：两层 / 四个文件 / 确定性构建 / 五道校验链 |

## 开发

不需要任何依赖（只要 python3 与 node）：

```bash
python3 tools/check-gate.py             # 三份实现 × 一张向量表（版本比较写错是静默错误，这里不靠自觉）
python3 tools/test-versioning.py        # 版本真源契约：台账派生 / 拒绝类断言 / 漂移检测
python3 tools/gen-version.py            # 从三个真源生成 build/（发布模式；占位会直接报错）
python3 tools/build-module.py           # 打模块 zip（< 1 MB、确定性；见 docs/module.md）
python3 tools/gen-errors.py --check     # 报错文档与真源一致（docs/errors.md 由 spec/errors.json 生成）

dash tools/test-service.sh              # 壳的 49 条契约（退出码 / 挂载 / diag / 状态不许说谎）
dash tools/test-diag.sh                 # 报错判读 14 条（证据 → 命中码 → 组合签名）
dash tools/test-dsh-ctl.sh              # 公开入口 11 条（参数校验 / 审计 / 透传）
dash tools/test-sdk-protocol.sh         # sdk profile 的 stdio JSON-RPC 握手（假 dsh 驱动，不联网）
python3 tools/build-module.py --selftest # 打包 24 条（布局 / 权限 / 安装模拟 / 确定性）
```

需要说明的一点：版本比较是本项目**唯一写错会静默出错**的地方 —— `"0.2.1-rc.1" < "0.2.0-rc.2"` 在字典序上成立，
语义上恰好相反。所以它有三份实现（Python / POSIX sh / Node）、一张共同的向量表，改规则必须三处一起过。

## 许可

[MIT](LICENSE) © 2026 SunsetRNE

