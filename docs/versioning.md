# 版本号与 module.prop 规范

> 本文记录项目采用的版本规范（[ADR-010](./decisions.md)）。**所有版本字面量只有一个真源**，见 §5。

---

## 1. module.prop 字段标准

```
id=<模块唯一化 ID>
name=<模块名称>
version=<大版本>.<功能变更新增版本>.<补丁版本号>.<DSH内置版本号>
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
| `version` | **四位**：大版本 / 功能变更新增 / 补丁 / **DSH 内置版本号** |
| `versionCode` | 整数、**单调递增**；= 变更了多少次（见 §3），**与 `version` 无推导关系** |
| `author` | 固定 `SunsetRNE` |
| `description` | 一句话说清"这是什么" |
| `updateJson` | 指向仓库里的 `update.json`（Root 管理器据此检查更新） |
| `managedFeatures` | 逗号分隔的特性名；**有真实实现才写**（见 §4） |

---

## 2. `version` 四位结构

```
 1 . 0 . 0 . 1
 │   │   │   └── 内置 DSH 版本号（随"模块最低支持 DSH 版本"对齐）
 │   │   └────── 补丁版本号
 │   └────────── 功能变更新增版本
 └────────────── 大版本
```

**第四位的定义（已定）**：它是**内置到容器里的那个 DSH 版本号**。

必须满足的约束：

1. **单调**：内置的 DSH 版本越高，这一位越大（只增不减）〔本条为我补充的通用约束〕；
2. **稳定**：同一个 DSH 版本永远对应同一个写法（否则历史版本会"变意思"）〔本条为我补充的通用约束〕；
3. **与 `manifest.json` 的 `floor` 对齐** —— 抬高 floor 必须同时抬这一位，否则用户看到的"内置 DSH 版本"与实际闸门不一致；
4. **与 payload 里的 baked 版本一致** —— 三者（`version` 第 4 位 / `manifest.baked` / payload 内的 DSH 版本）说的是同一件事。

**第 4 位的来源通道（已定 → ADR-022）**：只认 **RC 通道**（`-rc.N`）—— 内置基线**不追 alpha**，所以这一位不会有 alpha 版本。
（⚠️ 通道与写法是**两件事**：通道已定（只追 RC）；写法也已定（见下一条）。）

**第 4 位写什么形式（已定 → 2026-10-17）**：**映射序号** —— 第几次烘焙内置基线，就从 `1` 起递增（`1` = DSH `0.2.0-rc.2`）。
理由：这一位只给人看，没有消费方拿它做运算；权威 semver 在 `manifest.baked`。而"从 semver 自动编码"有**单调性陷阱**——
`0.2.0-rc.2` 若编成 `20002`，那正式版 `0.2.0` 无论怎么编都比它小（semver 里 final > 所有 rc），除非编成 `20099` 这种怪值。
序号法把"只增不减"变成**人工可核对的一条规则**，生成器负责在 `module.prop` 顶部注释里写明 `第 4 位为 N` 对应的 DSH 版本。
（生成器另有一道闸：`floor ≤ baked`、`recommended > baked`，都用真正的 prerelease 感知比较，见 §9。）

**三处分工（避免混淆）**：

| 位置 | 放什么 | 例 |
|---|---|---|
| `version` 第 4 位 | 内置基线的烘焙序号（`1` = DSH `0.2.0-rc.2`） | `1`（→ `1.0.0.1`） |
| `manifest.json` 的 `baked` / `floor` | **完整 semver**（含 `-rc.N`），权威值 | `0.2.0-rc.2` |
| `versionCode` | 变更次数（第几次发布），单调 +1；与上面两行**无推导关系** | `1` |

---

## 3. `versionCode` 是什么

**`versionCode` = 这个模块"变更了多少次"的计数**，只面向 Root 管理器；每对外发一次新包就 +1。

- 它**不从 `version` 推导**，也**不与 `version` 的各位联动** —— 两者是两个独立维度：
  - `version` → **给人看**，表达结构上的变化（大版本 / 功能变更新增 / 补丁 / 内置 DSH 版本号）；
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

**规定**：只维护一个真源文件 `tools/version.env`，其余全部由脚本生成。**已实现**：

| 文件 | 角色 |
|---|---|
| [tools/version.env](../tools/version.env) | **唯一手改的版本文件**（模块身份 + 四位 version + versionCode + DSH 基线） |
| [tools/gen-version.py](../tools/gen-version.py) | 生成器（纯标准库） |
| `build/module.prop` | 生成物 |
| `build/manifest.json` | 生成物（从 [baseline/manifest.example.json](../baseline/manifest.example.json) 模板合并） |
| `build/apk-version.properties` | 生成物（给 APK 构建读 `VERSION_CODE` / `VERSION_NAME`） |

```bash
python3 tools/gen-version.py --draft    # 生成到 build/（草稿：payload 的层 sha256 还没真值时必须带）
python3 tools/gen-version.py            # release 模式：任何占位都报错退出（发布前必须能过）
python3 tools/gen-version.py --check    # 只校验生成物是否与真源同步（CI / 提交前用；可带 --draft）
```

**五条硬性行为**（已实测）：

1. **占位就报错退出**（exit 2），**绝不替你编造**版本号或名字；
2. **占位检查是全文的**，不只看字段开头 —— `<账号>` 这种藏在 URL 中间的值、模板里的 `sha256:REPLACE_ME`、`待定` / `TBD` 都算（上一版只看 `startswith("<")`，会漏放 `UPDATE_JSON`）；
3. `floor ≤ baked`、`recommended > baked` 由**真的 prerelease 感知比较**校验（§9），不是字符串比大小；
4. `DSH_RECOMMENDED` 为空时**删除** `recommended` 键，不继承模板里遗留的旧值（上一版会让模板的幽灵版本 `0.2.1-rc.3` 原样进产物）；
5. `--check` 在生成物与真源不一致时报**漂移**并 exit 1（例如有人手改了 `build/module.prop`）。

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

> 这样做的收益：**管理器里看到的模块版本、APK 的版本、以及闸门里的 floor，永远同步**，不会出现"APK 更新了但模块没更新"这类错位。

---

## 7. 一份可直接复制的初值

见 [tools/version.env](../tools/version.env)（真源）与 [baseline/module.prop.example](../baseline/module.prop.example)（生成后的样子）。

~~当前仍是占位的三项~~ → **三项已于 2026-10-17 定稿**：`MODULE_ID=Zodiac-Quill-Saga` · `MODULE_NAME=DSH Chroot` · `V_DSH=1`。
现在唯一还空着的是 payload 层的 `sha256`（必须真打过包才有），所以生成走 `--draft`；其余任何占位都会被生成器拒绝。

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

生成器用它做的两道闸：`floor ≤ baked`、`recommended > baked`。将来容器里（`sh`）与壳里（`node`）各会有一份实现，
**它们必须与同一张测试向量表对齐**（`spec/gate-vectors.json`，待做）—— 三份实现、一张表，这是防漂移的唯一办法。
