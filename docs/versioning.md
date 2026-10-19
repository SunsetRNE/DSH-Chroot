# 版本号与 module.prop 规范

> 本文记录项目采用的版本规范（[ADR-010](./decisions.md)；第 4 位已由 [ADR-025](./decisions.md) 修订）。
> **版本字面量分三个真源，各管一件事**，见 §5。

---

## 1. module.prop 字段标准

```
id=<模块唯一化 ID>
name=<模块名称>
version=<大版本>.<功能变更新增版本>.<补丁版本号>.<烘焙序号>
versionCode=<面向 Root 管理器的整数，变更则 +1>
author=SunsetRNE
description=<描述信息>
updateJson=<更新 JSON 地址>
managedFeatures=<管理特性，逗号分隔，Root 管理器标签>   ← 语义见 §4
```

| 字段 | 规则 |
|---|---|
| `id` | 必须匹配 `^[a-zA-Z][a-zA-Z0-9._-]+$`；本项目固定为 **`Zodiac-Quill-Saga`**，**发布后不可改**（§8） |
| `name` | 面向用户显示 |
| `version` | **四位**：大版本 / 功能变更新增 / 补丁 / **烘焙序号（烘焙台账 `seq`）** |
| `versionCode` | 整数、**单调递增**；= 变更了多少次（见 §3），**与 `version` 无推导关系** |
| `author` | 固定 `SunsetRNE` |
| `description` | 一句话说清"这是什么" |
| `updateJson` | 指向仓库里的 `update.json`（Root 管理器据此检查更新） |
| `managedFeatures` | 逗号分隔的特性名；**有真实实现才写**（见 §4） |

---

## 2. `version` 四位结构

```
 1 . 0 . 0 . 1
 │   │   │   └── 第 4 位：烘焙事件序号（由 baseline/bake-ledger.json 生成）
 │   │   └────── 补丁版本号
 │   └────────── 功能变更新增版本
 └────────────── 大版本
```

**第 4 位的定义（2026-10-18 定稿 → [ADR-025](./decisions.md)）**：它是**"第几次把一份 DSH 烘焙进 payload"**的计数，
从 `1` 起递增、只增不减。它**对着 `baked`（容器里装的那一份），不对着 `floor`（允许的最低版本）**。

必须满足的约束，以及它们各自靠什么保证：

| 约束 | 怎么保证 |
|---|---|
| **单调**：只增不减 | 台账只追加；`seq` 必须从 1 连续递增（生成器校验，跳号即 exit 2） |
| **稳定**：同一 baked 永远同一写法 | 台账是历史，不许改旧条目；生成器只读最后一条 |
| **与 `manifest.baked` 一致** | **同一处派生**：`seq` 与 `baked` 都取自台账最后一条，不是人工核对 |
| **与 payload 的 dsh 层一致** | `tools/build-payload.py` 的默认 `--baked` 也取自台账最后一条 |

**为什么不对着 `floor`**：`floor` 是"允许的最低版本"，它变化时**容器里装的东西没变**；把第 4 位绑到 floor，
"内置版本"这个名字就名不副实。`floor ≤ baked` 本来就允许两者不同（见 [baseline §7](./baseline.md)）。所以：

- 换 `baked` → 第 4 位 +1（在台账里记一行）
- 只抬 `floor` → 第 4 位**不变**（只抬补丁位）

> 今天 `floor == baked == 0.2.0-rc.2` 只是巧合，不是约束。

**第 4 位的来源通道（ADR-022）**：只认 **RC 通道**（`-rc.N`）—— 内置基线**不追 alpha**，所以这一位不会有 alpha 版本。

**为什么只能是计数、不能是 semver 编码**：

```
1.0.0  <  1.0.1-0  <  1.0.1-0.0  <  1.0.1-0.0.0  <  …  <  1.0.1
```

semver 的序是**稠密**的 —— 任意两个版本之间都能再插进一个，而整数之间只能放有限个。
所以**不存在保序的整数编码**：`0.2.0-rc.2 → 20002` 这类方案必然在 `0.2.0` 正式版上翻车
（final 必须大于所有 rc，却没有可用的整数）。计数法不承诺顺序，只承诺"变没变" —— 这才是这一位能承担的全部。

**三处分工（避免混淆）**：

| 位置 | 放什么 | 例 |
|---|---|---|
| `version` 第 4 位 | 烘焙台账的 `seq`（`1` = 第 1 次烘焙） | `1`（→ `1.0.0.1`） |
| `manifest.json` 的 `baked` / `floor` | **完整 semver**，权威值；`baked` 与 `floor` 是两件事 | `0.2.0-rc.2` / `0.2.0-rc.2` |
| `versionCode` | 变更次数（第几次发布），单调 +1；与上面两行**无推导关系** | `1` |

---

## 3. `versionCode` 是什么

**`versionCode` = 这个模块"变更了多少次"的计数**，只面向 Root 管理器；每对外发一次新包就 +1。

- 它**不从 `version` 推导**，也**不与 `version` 的各位联动** —— 两者是两个独立维度：
  - `version` → **给人看**，表达结构上的变化（大版本 / 功能变更新增 / 补丁 / 烘焙序号）；
  - `versionCode` → **给 Root 管理器看**，只表达"这是第几次变更"。
- 所以：一次纯修复（`version` 可能只动补丁位）与一次大改（动大版本），在 `versionCode` 上都**只是 +1**。

**永远不要回退 `versionCode`**：管理器按它比对更新，回退会导致更新/降级不生效。

---

## 4. `managedFeatures` 的真实语义（我按你的 Root 管理器源码核实过）

你列的这个字段**确实存在**，但它在 BakaSU / KernelSU-Next 里有**两处**用法，必须成对使用：

### 4.1 写在 `module.prop` 里 —— 给**安装器**做特性自检

`installer.sh` 的 `check_managed_features()` 会：

1. `grep_prop managedFeatures module.prop`；
2. 按逗号拆分；
3. 对每一项执行 `ksud feature check <feature>`，按返回值提示：

| ksud 返回 | 安装器输出 |
|---|---|
| `unsupported` | ⚠️ 内核不支持该特性，**模块可能无法正常工作** |
| `managed` | ⚠️ 该特性**已被别的模块管理**，可能冲突 |
| `supported` | ✅ 支持且可用 |

### 4.2 写在模块 **config** 里 —— 运行时声明（管理器标签由此而来）

`ksud` 在 `list_module` 时会扫描模块 config 的 `manage.<feature>=true`，把 `<feature>` 收集起来拼成 `managedFeatures` 塞进输出的 JSON（供管理器显示标签、供 `ksud feature check` 判定为 `managed`）。

### 4.3 由此得到两条硬规则

1. **两处必须列同一组特性名**（`module.prop` 的 `managedFeatures` 与 config 的 `manage.*=true`），否则"安装器自检"与"运行时声明"会打架；
2. ⛔ **没有真实实现就不要声明** —— 声明了会让 `ksud feature check` 报 `managed`，别的模块会以为该特性已被占用（等于误报冲突）。

> **本项目当前定位**：阶段一只管容器与 DSH，**不接管任何内核特性** → `managedFeatures` 应为**空/不写**。
> 将来若真的接管"挂载"之类，再按 §4.1 + §4.2 成对声明。

---

## 5. 单一真源（本条最关键）

版本号会同时出现在 **三个地方**：`module.prop`、`manifest.json`、APK。三处手改必然漂移。

**规定**：三个真源各管一件事，其余全部由脚本生成。**已实现**（[ADR-025](./decisions.md)）：

| 文件 | 角色 |
|---|---|
| [tools/version.env](../tools/version.env) | **手改**：模块身份 + version 前三段 + `versionCode` |
| [baseline/dsh.env](../baseline/dsh.env) | **手改**：`DSH_FLOOR` / `DSH_RECOMMENDED` / `NODE_FLOOR` |
| [baseline/bake-ledger.json](../baseline/bake-ledger.json) | **手改，只追加**：烘焙台账，`seq` ↔ `baked`；第 4 位与 `manifest.baked` 的唯一来源（§10） |
| [tools/gen-version.py](../tools/gen-version.py) | 生成器（纯标准库） |
| `build/module.prop` | 生成物 |
| `build/manifest.json` | 生成物（从 [baseline/manifest.example.json](../baseline/manifest.example.json) 模板合并） |
| `build/apk-version.properties` | 生成物（给 APK 构建读 `VERSION_CODE` / `VERSION_NAME`） |
| [update.json](../update.json) | **手写但与真源强校验**（提交在仓库根：Root 管理器从这里检查更新；`version` / `versionCode` 必须与生成结果一致） |

```bash
python3 tools/gen-version.py            # 发布模式：生成到 build/；任何占位都报错退出
python3 tools/gen-version.py --check    # 只校验生成物是否与真源同步（CI / 提交前用）
python3 tools/gen-version.py --draft    # 逃生口：真的还有未填项时只看草稿（payload sha256 已是真值，平时不用）
```

**七条硬性行为**（已实测；[tools/test-versioning.py](../tools/test-versioning.py) 用 20 条断言守着）：

1. **占位就报错退出**（exit 2），**绝不替你编造**版本号或名字；
2. **占位检查是全文的**，不只看字段开头 —— `<账号>` 这种藏在 URL 中间的值、模板里的 `sha256:REPLACE_ME`、`待定` / `TBD` 都算（上一版只看 `startswith("<")`，会漏放 `UPDATE_JSON`）；
3. `floor ≤ baked`、`recommended > baked` 由**真的 prerelease 感知比较**校验（§9），不是字符串比大小；
4. `DSH_RECOMMENDED` 为空时**删除** `recommended` 键，不继承模板里遗留的旧值（上一版会让模板的幽灵版本 `0.2.1-rc.3` 原样进产物）；
5. **第 4 位与 `baked` 从台账派生** —— `seq` 必须从 1 连续递增（跳号 / 从 0 开始直接 exit 2），`baked` 必须是合法 semver；`version.env` 里残留 `V_DSH` / `DSH_BAKED` / 基线参数也直接 exit 2（迁移必须彻底，不许静默忽略）；
6. `--check` 在生成物与真源不一致时报**漂移**并 exit 1（例如有人手改了 `build/module.prop`）；
7. **`update.json` 与真源强校验** —— 它的 `version` / `versionCode` 必须等于生成结果，缺文件或不同步直接 exit 2（否则更新按钮会指向错的包）。

APK 侧接入方式（二选一）：

- Gradle 直接读 `build/apk-version.properties`，写入 `versionCode` / `versionName`；
- 或把该文件拷进 APK 工程，用 `gradle.properties` 的方式引用。

（`build/` 是产物目录，已加 `.gitignore`。）

---

## 6. APK 对齐规则

| APK 字段 | 对齐目标 | 注意 |
|---|---|---|
| `versionCode`（内部版本码） | **= 模块 `versionCode`**，同步 +1 | Android 要求单调递增且为 32 位内整数；**不能超过 2100000000** |
| `versionName`（外部版本号） | **= 模块 `version`**，同四位结构 | 纯展示，不参与比较 |

> 这样做的收益：**管理器里看到的模块版本、APK 的版本、以及闸门里的 `baked`，永远指向同一次烘焙**（第 4 位 = 台账 seq），不会出现"APK 更新了但模块没更新"这类错位；`floor` 另有来源，不受第 4 位影响。

---

## 7. 一份可直接复制的初值

三个真源：[tools/version.env](../tools/version.env) · [baseline/dsh.env](../baseline/dsh.env) · [baseline/bake-ledger.json](../baseline/bake-ledger.json)。
生成后的样子见 [baseline/module.prop.example](../baseline/module.prop.example)。

**2026-10-17 定稿的三项**：`MODULE_ID=Zodiac-Quill-Saga` · `MODULE_NAME=DSH Chroot` · 首个烘焙 `seq=1` / `baked=0.2.0-rc.2`（记在台账里，不写在 version.env）。
payload 层的 `sha256` 也已在 2026-10-19 填成真值（`node-24.21.0` / `dsh-0.2.0-rc.2`）；现在生成走**发布模式**，任何占位（包括 `REPLACE_ME`）都会被拒绝。

---

## 8. 命名分工：四个字符串，各管一件事（2026-10-17 定稿）

| 字符串 | 值 | 谁看得见 | 能不能改 |
|---|---|---|---|
| `id`（`MODULE_ID`） | `Zodiac-Quill-Saga` | `/data/adb/modules/<id>`、`ksud` 命令、日志 | ⛔ **发布后不可改** |
| `name`（`MODULE_NAME`） | `DSH Chroot` | Root 管理器卡片（一行） | ✅ 随时可改 |
| 仓库名 | `DSH-Chroot` | GitHub、`updateJson` URL、clone 命令 | ✅ 可改，但会断掉已发出去的 `updateJson` |
| zip 资产名 | `DSH-Chroot-<version>.zip` | 安装时选文件的那一屏 | ✅ 可改 |
| `description` | 一句话 | 管理器卡片第二行、仓库描述 | ✅ 随时可改 |

**为什么这样分**：`id` 是**永久主键**，所以由它承担"独特性"（代号 `Zodiac-Quill-Saga`）；
其余每一个别人会**读**到、**点**到、**搜**到的位置，都承担"可读性"（`DSH Chroot` / `DSH-Chroot`）。

> 判据：**越少人看见的字段，越可以讲风格；越常被看见的字段，越必须讲事实。**
> —— 对应到本项目：`id` 全用代号（没人手打它），`updateJson` 的 URL 与仓库名全用产品名（每个人都会点开）。

**`id` 的硬规则**（Magisk 官方文档 + KernelSU `ksud` 源码是同一个正则）：

```
^[a-zA-Z][a-zA-Z0-9._-]+$     ✓ a_module   ✓ a.module   ✓ module-101
                              ✗ "a module" ✗ 1_module   ✗ -a-module
```

- 首字符必须是字母；只允许字母、数字、`.`、`_`、`-`。**大写合法但反惯例**（本项目故意用大写，作为代号的一部分）。
- 官方原话：**"You should not change it once published."** → 改名不是改名，是**换一个模块**（旧目录残留、`ksud` 认不出、用户要卸载再装）。
- `id` 是**精确匹配**：`Zodiac-Quill-Saga` 与 `zodiac-quill-saga` 是两个不同目录，脚本里手打小写会找不到。

**查重记录（2026-10-17）**：GitHub 搜索 `Zodiac-Quill-Saga in:name` → `total_count = 0`；`dsh-chroot in:name` → `0`。
设备上 9 个已装模块无同名。`dsh-container` 已被 [omdsh-dev/dsh-container](https://github.com/omdsh-dev/dsh-container)（Docker 封装）占用，故弃用。

---

## 9. semver 比较：唯一权威实现与三道闸

`tools/semver.py` 是**权威参考实现**（纯标准库，实现 semver 2.0.0 的优先级规则）：

- 先比较 `major / minor / patch` 三段数值；
- **有 `-pre` 的 < 无 `-pre` 的**（`0.2.0-rc.2 < 0.2.0`）；
- `-pre` 逐段比较：数字段按数值（`rc.9 < rc.10`）、字母段按 ASCII 字典序、数字段 < 字母段、前缀相同则段数多者大（`alpha < alpha.1`）；
- `+build` 元数据**忽略**。

⛔ **禁止字符串比较**：`"0.2.1-rc.1" < "0.2.0-rc.2"` 在字典序上成立，但语义上相反 —— 这是本项目最容易静默出错的点。

生成器用它做的两道闸：`floor ≤ baked`、`recommended > baked`。

### 9.1 三份实现 · 一张表（已落地，2026-10-17）

| 实现 | 文件 | 跑在哪 |
|---|---|---|
| Python（参考实现） | [tools/semver.py](../tools/semver.py) | 构建机 / CI / 生成器 |
| POSIX sh | [lib/semver-gate.sh](../lib/semver-gate.sh) | 设备侧（Android 的 sh，**不是 bash**）与容器内 |
| Node | [lib/semver-gate.mjs](../lib/semver-gate.mjs) | 容器内 / 壳 |

唯一规格：[spec/gate-vectors.json](../spec/gate-vectors.json) —— 41 条 compare + 35 条 check + 19 条 decide，其中含一条 15 个版本的升序链（相邻必须严格递增）。

```bash
python3 tools/check-gate.py       # 5 个运行体 × 95 条向量逐条比对（python / dash / bash --posix / mksh / node）
python3 tools/check-gate.py -v    # 打印每条结果
python3 tools/semver.py           # 只跑 Python 实现
```

**跑过的证据**：五个运行体（python / sh-dash / sh-bash / sh-mksh / node）**95/95 全一致**；
四个变异测试分别被抓到 —— 把 sh 的「数字段 < 字母段」写反、把 node 的「final > prerelease」写反、放行 prerelease 前导零、把 alpha 的 `safe_mode` 改成 0
（最后这条是 2026-10-18 加 decide 时现场跑的：`FAIL 94/95`，抓的正是 `decide ['0.2.2-alpha.5', …]`）。
**一道永远绿的检查等于没有检查**，所以这几条变异测试要跟着一起维护。

✅ **真机已闭环（2026-10-17，实测）**：设备是 **mksh R59**（`@(#)MIRBSD KSH R59 2020/10/31 Android`，
一加 12 / PJD110 / Android 16，`/system/bin/sh` 为普通文件、含 mksh 标记、无 toybox 标记），
当时在该机上跑自检脚本得到 **`RESULT ok 76/76`**。
用 [tools/verify-gate-device.sh](../tools/verify-gate-device.sh)（**单文件、自包含**：由 `tools/build-device-selftest.py` 把实现正文 + 向量烘进去）
在真机上跑，首轮暴露了一个**方言坑**（mksh 里 `${s%%|*}` 返回空串，见 [pitfalls A20](./pitfalls.md)），修掉后设备与本机三端（mksh / dash / bash）
一律 `RESULT ok 76/76`。`tools/check-gate.py` 现已自动纳入 mksh（装了就跑），CI 也会装 mksh 跑一遍。

> ⚠️ 加了 decide 之后，自检脚本已扩到 **95 条**。本机 dash / mksh 均 **95/95**；**真机 95/95 待重跑**（上次真机证据是 76 条版本）。

```bash
python3 tools/build-device-selftest.py           # 改完 lib 或 spec 后重新生成（CI 会校验没漂移）
python3 tools/build-device-selftest.py --check
```

### 9.2 策略层 `decide`（ADR-026）

比较只回答"谁更新"，不回答"能不能用"。`decide` 是那一层：

```
decide(installed, floor, baked) -> verdict · reason · safe_mode
verdict = ok | deny；safe_mode = 0 | 1
```

**纯函数**：不读盘、不改指针、不起进程。判定与处置分开 —— 回落 baked / 退出码 / 日志都在壳里。

| 情况 | verdict | reason | safe_mode |
|---|---|---|---|
| installed 非法 / 读不出 | deny | `invalid-installed` | 0 |
| floor / baked 非法，或 `floor > baked` | deny | `invalid-manifest` | 0 |
| installed < floor | deny | `below-floor` | 0 |
| floor ≤ installed < baked | ok | `older-than-baked` | 0 |
| installed == baked | ok | `baked` | 0 |
| installed > baked，rc / final | ok | `user-upgraded` | 0 |
| installed > baked，alpha | ok | `user-upgraded-alpha` | **1** |
| installed > baked，其他预发布 | ok | `user-upgraded-prerelease` | **1** |

三条说明：

- **`recommended` 不参与 decide** —— 软提示一旦进判定就变成硬拦；它只由 `status` 展示。
- **alpha 的 `safe_mode` 只算不执行**：今天没有"禁用全部插件"的机制（ADR-023 的落地件），壳只把它打出来。
- **exit 50** 是壳的处置结果，不是 decide 的输出（ADR-013 的退出码表由 ADR-026 增补）。


---

## 10. 烘焙台账（`baseline/bake-ledger.json`）

台账是第 4 位与 `baked` 的**唯一来源**。它只增不改：一条记录 = 一次烘焙。

```json
{
  "schema": 1,
  "bakes": [
    { "seq": 1, "baked": "0.2.0-rc.2", "date": "2026-10-17", "note": "首个基线" }
  ]
}
```

| 字段 | 规则 |
|---|---|
| `seq` | 整数，**必须从 1 连续递增**（第 n 条的 `seq` 必须等于 n）；跳号 / 从 0 开始直接 exit 2 |
| `baked` | 合法 semver（§9 的实现校验）；最后一条就是 `manifest.baked` |
| `date` | 可选，`YYYY-MM-DD` |
| `note` | 可选，一句人话：为什么烘这一次 |

**加一条账**（换 DSH 基线时）：

```bash
# 编辑 baseline/bake-ledger.json，在 bakes 末尾追加：
#   { "seq": 2, "baked": "0.2.1-rc.2", "date": "2026-10-20", "note": "上游 rc 修了 X" }
python3 tools/gen-version.py            # version 第 4 位自动变成 2（当前补丁位下 → 1.0.2.2）
```

**回滚也记一条账**：把一份更旧的 DSH 重新烘进 payload 同样是一次烘焙 —— `seq` 继续 +1，`baked` 写回旧版本。
生成器对这种**非升序**或**重复**的 `baked` **只告警、不拒绝** —— 回滚是合法动作，告警只是提醒你别把顺序写错。

**同一 baked 重新打包不记账**：字节变了但 DSH 版本没变（重打层 / 改 wrapper / 换压缩参数）走第 3 位补丁。
这样"第 4 位变了 = DSH 换了"才永远成立（§11）。

---

## 11. 变更决策表（改哪一位）

| 变更 | 1 大 | 2 功能 | 3 补丁 | 4 台账 | versionCode | 台账加行 |
|---|---|---|---|---|---|---|
| 修壳 / 容器 bug，DSH 不变 | | | +1 | 不变 | +1 | — |
| 模块新增功能 | | +1 | 0 | 不变 | +1 | — |
| 换 DSH 基线（如 `0.2.0-rc.2 → 0.2.1-rc.2`） | | | 0 | +1 | +1 | **+1 行** |
| 同一 baked 重打层（哈希变了） | | | +1 | 不变 | +1 | — |
| 只抬 `floor`（不放新 DSH） | | | +1 | 不变 | +1 | — |
| 破坏性变更（安装路径 / 布局） | +1 | 0 | 0 | 不变 | +1 | — |

两条判据：

- **跟不跟新的 RC**：除 ADR-022 的"只追 RC"外，还要满足**安全修复 / 我需要的新 API / 上游 RC 已稳定**三条之一。第 4 位只增不减，跟得越勤越没余量。
- **抬不抬 floor**：只有**需要把用户从旧版本赶走**时（旧版有已知缺陷）才抬；否则保持低 floor，允许用户自行回滚。

---

## 12. 一条禁令：`version` 永不参与比较

- 模块更新的**唯一**排序键是整数 `versionCode`（`update.json` 用它，生成器校验的是**相等**）。
- `version`（四位）只给人看、给 `--check` 做**相等**比对；任何"谁更大"的判断都不许落在它上面。
- 原因很具体：`1.0.0.10` 在字典序上**小于** `1.0.0.9` —— 第 10 次发版就会翻车。
- DSH 版本之间的"谁更新"只走 §9 的 semver 闸门（三份实现 + 76 条向量）。
