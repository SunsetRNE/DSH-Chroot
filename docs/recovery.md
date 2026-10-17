# 刷机前的证据与回滚预案

> **什么时候需要读这份**：① 阶段二（自定义内核 / Droidspaces）发车前；② 任何要动 boot 分区的操作前。
> 按 [ADR-001](./decisions.md)，**阶段一只用原厂内核 + LKM，不碰 boot**，所以这份现在不是急事——但**版本号现在就该核一遍**，因为第 2 条是单向的。

---

## 1. 结论：完整系统镜像包 > boot 单分区备份，但有一个致命前提

| 你的资产 | 覆盖 | 前提 |
|---|---|---|
| 完整系统镜像包 | ✅ 能恢复 boot / init_boot / vbmeta / dtbo，甚至全机 | ⚠️ **它必须不早于你当前版本**（见 §2 ARB） |
| 单纯 boot 备份 | 只能救内核刷坏 | 需要与当前版本完全对应 |

**"有完整包" ≠ "能安全回滚"。** 在欧加真（OnePlus / OPPO / realme）上这条尤其致命。

---

## 2. ⚠️ 反回滚（ARB）—— 本项目最贵的坑

- **事实**：OnePlus 已引入 anti-rollback。公开报道（9to5google，**2026-01-20**）：*OnePlus update starts bricking phones when you try to install older software* —— 刷入旧固件会**变砖**。
- **机制**：设备里有一套**只增不减**的熔断等级；固件的回滚等级低于设备当前等级 → 拒绝启动，且**不是软砖**。
- **后果**：
  - 手上的完整包如果比当前版本旧 → **它救不了你，反而会杀死设备**；
  - 该等级随每次 OTA **单向抬高**，无法回落。
- **行动**：
  1. **现在就记录**设备当前版本号（能拿到回滚等级更好）；
  2. 每次 OTA 后**重新核对**手上的包还够不够新；
  3. 任何降级念头，先去查该版本对应的 ARB 等级，**不要试**。

> 延伸阅读：[AdaUnlocked/Oplus-OTA-ARB-Fuse-Analysis](https://github.com/AdaUnlocked/Oplus-OTA-ARB-Fuse-Analysis)

---

## 3. 包的三种形态，风险完全不同

| 形态 | 长什么样 | 能做什么 | 风险 |
|---|---|---|---|
| **OTA 全量包** | zip，内含 payload.bin | 可抽单分区（boot / init_boot / vbmeta / dtbo），也能整包侧载 | 低（只要版本 ≥ 当前）；旧版本 = ARB 熔断 |
| **EDL / MSM 包** | .ofp + MSM Download Tool（9008 模式） | 覆盖最全，能救硬砖 | 中：新机型工具常需登录/授权；来源不明的免登录工具有后门与签名风险 |
| **增量包（delta OTA）** | zip，`metadata` 里带 **pre-build=**，`payload.bin` 是差分 | 只给"当前恰好在 pre-build 版本"的设备做升级 | ⚠️ **不能当回滚套件**：镜像以差分存在，必须配合精确源镜像才能还原（见 §12.5） |
| **降级包 / 工程包** | 各种 | 把系统降到旧版本 | **最高**：ARB 熔断的典型触发源，**不要用** |

---

## 4. 该留的证据（清单）

| 证据 | 怎么拿 | 为什么 |
|---|---|---|
| 设备当前构建指纹 | 设置→关于手机→版本号；或 root 下 getprop ro.build.display.id / ro.build.fingerprint | 判断包够不够新（ARB 前提） |
| 包的构建指纹 | OTA zip 内 META-INF/com/android/metadata 的 post-build= | 与上一行对比，**必须 ≥** |
| boot.img | 从 OTA zip 抽（见 §5） | 内核所在分区；AnyKernel3 内核包多写这里 |
| init_boot.img | 同上 | 通用 ramdisk；Magisk / KernelSU 打补丁多写这里 |
| vbmeta.img | 同上 | 校验 / 验证启动；改过 verity 就必须留 |
| dtbo.img | 同上 | 设备树 overlay；部分内核包会写它 |
| 包的机型代号 | 包名 / 元数据 | 你是 **PJD110（国行）**；**CPH2573 是全球版，不能混刷** |

保存原则：**至少两份**（手机内 + 电脑 / 云），并记下 sha256。

---

## 5. 抽取方法（只抽要的几个分区，不用解整个包）

[real-LiHua/payload-dumper](https://github.com/real-LiHua/payload-dumper)（5ec1cff 版的加强分支）**能直接从 OTA zip 里抽指定分区**，甚至**能从 URL 抽**（不必先下几 GB）：

```bash
pip install git+https://github.com/5ec1cff/payload-dumper
payload_dumper --partitions boot,init_boot,vbmeta,dtbo <OTA.zip 或 URL>
```

---

## 6. 分区角色表（标【待核对】的必须在你机器上确认）

| 分区 | 通常装什么 | 谁写它 |
|---|---|---|
| boot | 内核（Image），部分设备仍含 ramdisk | AnyKernel3 内核包【待核对】 |
| init_boot | 通用 ramdisk（Android 13+ GKI 起从 boot 移出） | Magisk / KernelSU 补丁【待核对】 |
| vendor_boot | vendor ramdisk + vendor 内核模块 | 部分内核 / 模块包 |
| dtbo | 设备树 overlay | 部分内核包 |
| vbmeta / vbmeta_system | 验证启动元数据 | 关 verity 时 |

你这台是**原厂 6.1.141 + ReSukiSU（BakaSU）LKM**，所以回原厂要覆盖的是 **LKM 加载链**碰过的那个分区 —— **先确认它到底是 boot 还是 init_boot**，再谈抢救。

---

## 7. 回滚决策树

```
出问题了
├─ 能进系统，只是内核异常
│    └─ 管理器里重刷原厂 boot（AnyKernel3 形式），或 fastboot flash boot boot.img
├─ 起不来，但能进 fastboot / recovery
│    ├─ fastboot flash boot boot.img
│    ├─ fastboot flash init_boot init_boot.img   （如果 LKM / 补丁改的是它）
│    └─ fastboot flash vbmeta vbmeta.img         （如果动过 verity）
└─ 完全黑砖（连 fastboot 都进不去）
     └─ EDL / MSM 工具（需对应机型的 .ofp；注意免登录工具的来源风险）
```

**每一步之前都先确认：手上的镜像版本 ≥ 当前设备版本**（§2）。

---

## 8. 待核对项（设备 shell 通道 2026-10-16 已通，已做只读核查）

- [x] 设备 ro.build.display.id / ro.build.fingerprint / 内核版本串 → **已读（2026-10-16）**：
      `ro.build.display.id = PJD110_16.0.10.501(CN01)`
      `ro.build.fingerprint = OnePlus/PJD110/OP5929L1:16/BP2A.250605.015/U.fb5f63_156f6fc_156f378:user/release-keys`
      `ro.build.version.ota = PJD110_11.F.57_2570_202608111410`（`ro.build.date.utc=1786421955` → 2026-08-11 04:19 UTC）
      内核 `6.1.141-android14-11-o-g659d588fa0da`
- [x] LKM 的 kernelsu.ko 落在哪个分区链上（boot 还是 init_boot）→ **形态已确认**：
      `/proc/modules` 含 `kernelsu 249856 5 - Live`（**模块已加载**）；`/data/adb` 内无任何 `.ko`
      （`find` 为空，`/data/adb/ksu/lib` 只有 `libadbroot.so`）→ 它**随 boot / init_boot 镜像走，不在用户数据区**。
      要精确到 boot 还是 init_boot，需在**全量包的镜像侧**查（这条只对"回滚时刷哪块分区"有意义）。`vermagic` **不属于本项目的核对项**：阶段二已裁，见 [README §5](../README.md)
- [ ] 手上那个完整系统镜像包的**形态**（OTA zip / .ofp / 其它）与**构建指纹**
- [x] 包的**机型代号**是不是 PJD110 → **包名是 PJD110**；设备侧 `ro.product.device=OP5929L1`
      （PJD110 为对外机型 / 包命名，OP5929L1 为平台代号；`ro.product.model=PJD110`）
- [ ] 是否存在 / 可获取回滚等级信息 → 只读到 `ro.boot.flash.locked=1`、`ro.boot.verifiedbootstate=green`、
      `ro.boot.veritymode=enforcing`，**这些不等于 ARB 等级**，仍需从包侧 / 官方渠道判断

> 我不会执行任何刷写 / 读写分区的动作（设备策略禁止），只做**只读核查与核对**。
---

## 9. 本机实际情况（2026-10 记录）

| 项 | 值 |
|---|---|
| 包文件 | PJD110 16.0.10.501.zip |
| 形态 | **官方全量包（CN01 国行）**，用户已在电脑上提取出分区镜像 |
| 含分区 | init_boot、boot、system、vendor、data 等 |
| 软件版本 | **PJD110_16.0.10.501(CN01)** |
| OTA 串 | PJD110_11.F.57_2570_202608111410 → 构建时间 2026-08-11 |
| 系统 / 补丁 | Android 16 · V16.1.0 · 补丁 2026-08-01 |
| 机型 | 一加 12（PJD110，国行）✅ 与设备一致，不是 CPH2573 |
| **设备当前版本** | **PJD110_16.0.10.501(CN01)** ← 与包**同版本** |
| 朋友那份 | PJD110 16.0.10.501(CNO1B110P02) —— **增量更新包**（非全量） |

> ✅ **结论：包与设备同版本 → 这份全量包可以当"内核回滚套件"使用**（同版本不构成降级，无 ARB 风险）。
> ⚠️ 但维护规则依旧：**一旦设备 OTA 到更高版本，这份包就过期了**（见 §11.1）。

**评价**：形态是**最理想的那种**（有 raw img，不必依赖整包）。但下面第 10、11 节决定了它能不能用。
---

## 10. ⚠️ 关键区分：只回刷内核侧 vs 整机降级

ARB 与 9008 熔断是**硬件级（芯片内 fuse）**，OTA 包里只有字段；而且绿厂屏蔽了 fastboot 对 ARB 等级的查询接口。
（来源：[AdaUnlocked/Oplus-OTA-ARB-Fuse-Analysis](https://github.com/AdaUnlocked/Oplus-OTA-ARB-Fuse-Analysis)，原作者酷安 @小黄泊）

所以分区要分成三类，**只有第一类是你能碰的**：

| 类别 | 分区 | 能不能用旧包回刷 |
|---|---|---|
| **内核侧（安全）** | boot、init_boot、vendor_boot、dtbo、vbmeta、recovery | ✅ 本项目唯一会碰的部分；建议只留这几张 |
| **引导 / 固件侧（危险）** | xbl、xbl_config、abl、tz、hyp、uefi、devcfg、qupfw、modem、engineering_cdt、oplus_sec、aop、dsp、spuservice 等 | ⛔ 旧包一律不能刷 —— 这正是 ARB 与熔断的载体，刷错 = 黑砖 |
| **用户数据** | data | ⛔ 永远不要恢复 —— 会覆盖你自己的数据 |

也就是说：**这个包的正确用法 = 从里面抽 boot / init_boot / vbmeta / dtbo 当"内核回滚套件"，而不是当"整机恢复包"。**
### 10.1 更严峻的一条（来自同一份分析）

- **升级系统会永久熔断 9008 免授权，不可逆、降级无效**；
- 一旦熔断，**售后也救不了**（OCDT 损坏只能拆字库）；
- 一加官方从 2026-01 起开始推送"熔断版本"，并**屏蔽了 fastboot 的 ARB 查询**；
- **你的包是 2026-08 构建**，远晚于该警告的版本线 → 【推断】**你的设备很可能已经在熔断版本线上**，即免授权 EDL 的退路可能已不存在。

**对项目的影响**：

1. 这更加支持 **ADR-001：阶段一不碰内核**；
2. 阶段二真要刷内核时，**只能依赖"内核侧分区回刷"这条路**，不要指望 EDL 兜底；
3. 每一分"少动引导链"的克制，都是实际的保险。

---

## 11. 版本核对流程（现在就做）

**包 = 16.0.10.501（构建 2026-08-11）。设备当前版本必须 ≥ 它，才谈得上"用"。**

> ✅ **已核对（2026-10）：设备 = PJD110_16.0.10.501(CN01) = 包版本** → 满足"≥"条件，**套件就绪**。

查设备当前版本（任选其一）：

1. 设置 → 关于手机 → 版本号；
2. root 下：getprop ro.build.display.id 或 getprop ro.build.fingerprint；
3. 设置 → 系统更新页看当前版本。

| 设备当前 vs 16.0.10.501 | 结论 |
|---|---|
| 相同 | 最佳：boot / init_boot 可随取随用（但没必要整包刷） |
| 设备更旧 | 包更新 → 安全，可用于升级或修复 |
| **设备更新** | ⚠️ **包已过期**：只能当同版本内核回刷的参考；**绝不能整包刷**（ARB 黑砖），且应**重新下载当前版本的全量包** |

### 11.1 维护规则（重要）

**ARB 与熔断只增不减 → 包会"过期成危险品"。** 所以：

- 每次 OTA 之后，**重新下载对应版本的全量包**，抽出 boot / init_boot / vbmeta / dtbo 归档；
- 旧包不要扔，但**标注清楚它的版本**，永不用于整机操作；
- 归档时记 sha256，并至少存两份（手机内 + 电脑 / 云）。
---

## 12. 两份"同版本"包怎么比对（例如你和朋友的）

### 12.1 版本串里的"括号"是什么

- 共同前缀 `PJD110_16.0.10.501` = 机型 + ColorOS 基线 + 构建号 → **同一个基线版本**
- 已知：朋友那份是 **增量更新包**（`metadata` 带 `pre-build=`）→ **跨包比对这条路直接作废**（增量包抽不出可用的 boot.img，见 §12.5）
- 括号里 `(CN01)` 与 `(CN01B110P02)` = OPPO / 一加用来标**渠道或批次变体**的编码
- ⚠️ **`B110P02` 具体代表哪条渠道，我没有权威来源可证实【未证实】**。能确定的是：
  - 它**不改变**"基线版本是否更旧"的判断（ARB 看的是版本号与构建时间）；
  - 它**改变**的是"**是不是同一分支**"——这恰恰是混用镜像时最要紧的一条。

### 12.2 判定可否互换：只看硬证据（从软到硬）

1. 两台机器的**内核版本串**（设置 → 关于手机 → 内核版本）必须完全一致，包括 `-o-gXXXXXXXX` 那一段；
2. 两个包里 `META-INF/com/android/metadata` 的 `post-build=` 与 `post-timestamp=` 是否一致；
3. **最硬的一条**：`boot.img` 与 `init_boot.img` 的 **sha256** 是否一致。

### 12.3 工具（只读）

```bash
python3 tools/compare-firmware.py <包A> <包B>
```

- 支持**解包目录**或**全量 OTA zip**；
- 输出 metadata 字段 + 六个内核侧分区（boot / init_boot / vendor_boot / dtbo / vbmeta / recovery）的 sha256；
- 末尾直接给结论：**可互换** 还是 **不要混用**。

### 12.4 结论规则

| 比对结果 | 结论 |
|---|---|
| 内核侧镜像 sha256 全一致 | 同一份镜像，**技术上可互换**（但仍建议各用各的） |
| 有不一致 | ⛔ **不要混用** —— boot / init_boot 必须与设备其余分区（尤其 vendor_dlkm / system_dlkm 里的内核模块）匹配；混用可能导致内核模块加载失败、相机 / 网络异常，甚至无法开机 |

### 12.5 增量包（delta OTA）—— 为什么它不能当回滚套件

**判别方法**：`META-INF/com/android/metadata` 里**同时有 `pre-build=` 与 `post-build=`** → 增量包；只有 `post-build=` → 全量包。

| | 全量包 | 增量包 |
|---|---|---|
| payload 内容 | 各分区的**完整镜像**（REPLACE） | 相对 **pre-build 版本**的**差分** |
| 能否直接抽出 boot.img | ✅ 能 | ❌ **不能**（拿到的只是补丁） |
| 安装前提 | 基本无（版本可高于设备） | **设备必须恰好是 pre-build 版本** |
| 当"内核回滚套件" | ✅ 可以 | ⛔ **不可以** |
| 收藏价值 | 高（按版本归档） | 低（只在升级那一刻有用） |

**真要还原**：得先有它要求的**精确源版本镜像**，再用支持"把 OTA 补丁打到旧镜像上"的工具还原（payload-dumper 有这一用法，需提供 `old/` 目录）。成本高、条件苛刻，**不如直接拿全量包**。

**因此**：你朋友那份增量包**对你没有当回滚套件的价值**；这类包的正确用途只是"给恰好在源版本的设备升一次级"。





