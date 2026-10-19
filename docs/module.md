# 模块包规范（引导器包）

> 模块 zip **只装引导器**（[ADR-024](./decisions.md)）：壳 + manifest + 安装钩子，**< 1 MB**。
> payload（Node 层 + DSH 层，~1 GB）永远不进 zip，首启由 `service.sh bootstrap` 负责（[payload.md](./payload.md)）。

---

## 1. 包内布局

| 包内路径 | 作用 | 权限 |
|---|---|---|
| `module.prop` | 模块身份（生成物） | 644 |
| `manifest.json` | 版本闸门数据（生成物） | 644 |
| `service.sh` | **开机钩子**（3 行）：转交 `/data/local/dsh/service.sh boot` | 755 |
| `customize.sh` | 管理器安装钩子（被安装器 source） | 755 |
| `install.sh` | 真正的安装逻辑（由 `customize.sh` 转交） | 755 |
| `uninstall.sh` | 卸载钩子（ADR-017） | 755 |
| `META-INF/com/google/android/update-binary` | 恢复模式安装入口（管理器不走这里） | 755 |
| `META-INF/com/google/android/updater-script` | 标准占位 | 644 |
| `bin/service.sh` | 壳的唯一执行者（ADR-013），安装时落到 `DSH_ROOT` | 755 |
| `bin/dsh-ctl` | 唯一公开入口（ADR-019） | 755 |
| `lib/semver-gate.sh` | 版本闸门的 POSIX sh 实现 | 644 |

**为什么壳放在 `bin/` 而不是包根**：模块根目录会被管理器整体替换（更新），而 `/data/local/dsh/`
是跨版本的运行域（state 在里面）。包根只留"安装期/开机期"的钩子，运行期文件由 `install.sh` 落盘。

## 2. 安装流程（管理器）

KernelSU / Magisk 的安装器实际做的事：

1. 解包到 `modules_update/<id>/`（**不是** `modules/`）；
2. 校验 `module.prop`（id / version / versionCode）；
3. 如果存在 `customize.sh` → **source** 它（此时 `MODPATH` 已指向解包目录）；
4. 重启后接管：`modules_update/<id>` → `modules/<id>`。

所以我们的分工是：

```
customize.sh（被 source，只转交）
   └─ . install.sh
        ├─ 拒绝降级（ADR-018：versionCode 严格小于已装 → abort）
        ├─ 复制 bin/service.sh · bin/dsh-ctl · lib/semver-gate.sh · manifest.json → DSH_ROOT
        ├─ chmod 0755 / 0644
        └─ 只建空目录 state/ base/ inbox/ run/ log（不碰已有数据，ADR-017 红线）
```

## 3. 开机路径

```
init → KernelSU/Magisk → /data/adb/modules/<id>/service.sh（钩子）
                              └─ exec /data/local/dsh/service.sh boot
                                   ├─ bootstrap（缺 payload → exit 30；有 payload → 解包/校验/切指针）
                                   ├─ version_gate（ADR-026：decide 判定，低于 floor 回落 baked）
                                   └─ runtime_start（真正的容器启动，尚未实现）
```

## 4. 卸载

| | 现在 | 目标（ADR-017） |
|---|---|---|
| 在跑的实例 | 尽力 `stop` | 同 |
| `/data/local/dsh/`（模块域） | **保留**，只打印残留 | 卸载即清空 |
| `/sdcard/Download/dsh/`（用户空间） | 不碰 | 不碰 |

**为什么现在不删**：ADR-017 决定 C 第 4 条自己写着 `uninstall.sh` 的确切执行时机**尚待确认**，
"不确定时只写标记不删数据"。删错是**不可逆**的，所以第一版宁可把残留如实打出来（`DSH_CHROOT_UNINSTALL residual=…`），
等 `dsh-ctl purge` 与时机确认后再接上。

## 5. 构建

```bash
python3 tools/gen-version.py --draft      # 先出 build/module.prop + build/manifest.json
python3 tools/build-module.py             # -> build/DSH-Chroot-<version>.zip
python3 tools/build-module.py --check     # 字节级漂移检查（CI 用）
python3 tools/build-module.py --selftest  # 19 条断言
```

**确定性**：条目按名字排序 · 固定 `mtime`（1980-01-01）· 固定权限 · 不写目录条目 · 不写平台元数据
→ 同样输入永远同一个 sha256。资产名不另立真源，从 `update.json` 的 `zipUrl` 反推。

`--selftest` 覆盖：体积上限 · 文件名 · 必需条目 · 可执行位 · 无 `@@{...}` 残留 · 解包后权限 ·
**安装模拟**（`customize.sh` → `DSH_ROOT`）· 安装后 `status` 能跑 · 闸门识别空层 ·
`help` 不依赖测试缝 · **拒绝降级** · **两次构建字节相同**。

## 6. 包里没有什么（故意的）

- payload（Node 层 / DSH 层）—— ADR-024；
- 用户数据（`state/`）；
- 密钥 / token；
- 第二套安装逻辑（恢复模式与管理器共用 `install.sh`）。

## 7. 已知边界

1. `update-binary`（恢复模式路径）**未在真机验证**；管理器安装不经过它。它是为了让包保持标准模块格式。
2. `manifest.layers` 在 payload 打包前是 `REPLACE_ME` —— 开发包能装、能 `status`，
   但 `start` 会因缺层报 `30`（**这是期望行为**，不是装坏了）。
3. 模块 `id` 发布后不可改（[versioning §8](./versioning.md)）。
