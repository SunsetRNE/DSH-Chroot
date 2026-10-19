# 变更记录

版本号与 `module.prop` 的 `version` 一致（[规范](docs/versioning.md)）。`update.json` 的 `changelog` 指向本文件。

## v1.0.0.1（未发布）

- 模块身份定稿：`id=Zodiac-Quill-Saga` · `name=DSH Chroot` · 仓库 `DSH-Chroot`
- 版本真源与生成器落地：`tools/version.env` → `build/module.prop` / `build/manifest.json` / `build/apk-version.properties`
- 生成器改为 fail-closed：占位全文扫描、`floor ≤ baked`、`recommended > baked`、模板注释不进产物、`--draft` 逃生口
- 新增 `tools/semver.py`：semver 2.0.0 比较的参考实现
- **版本闸门落地**：`spec/gate-vectors.json`（76 条向量：41 compare + 35 check，含 15 版本升序链）
  + 三份实现（`tools/semver.py` / `lib/semver-gate.sh` POSIX / `lib/semver-gate.mjs` Node）
  + `tools/check-gate.py` 三实现对照。三个变异测试（写反 sh 的数字段规则、写反 node 的 final 规则、放行前导零）均被抓到
- `tools/verify-gate-device.sh`：单文件、自包含的真机自检（由 `tools/build-device-selftest.py` 生成，
  内联实现正文 + 76 条向量，可容忍 CRLF）
- **真机闭环（2026-10-17，mksh R59 / PJD110 / Android 16 → `RESULT ok 76/76`）**：
  首轮曝出方言坑 —— mksh 里 `${s%%|*}` 返回空串（dash/bash 正常），向量行全部解析失败；
  改成 `IFS='|'; set -- $x` 后三端 76/76。坑记为 [pitfalls A20](docs/pitfalls.md)，
  `tools/check-gate.py` 自动纳入 mksh，CI 也装 mksh 跑一遍
- **命门在真 chroot 上闭环（2026-10-18）**：chroot-distro 2.1.0 + ubuntu noble 24.04（arm64）里 `pty.spawn` 拿到 `/dev/pts/0`，
  `/dev/ptmx` 为独立字符设备（5,2 · 666）→ `node-pty` 的直接前提成立。记于 [research §9.1.1](docs/research.md)
- **壳的第一块（service.sh）**：唯一执行者骨架 —— 动词 `boot/start/stop/restart/status/bootstrap/install/logs`，
  退出码 `0/10/20/30/40`；六条契约各自可测：非交互（stdin 钉 `/dev/null`）· 环境钉死 · 幂等 ·
  先停后换（切层前停实例）· 默认离线（`--offline`）· 机器可读标记 `DSH_SERVICE_*`。
  `tools/test-service.sh` 25 条断言在 dash 与 mksh 双端全绿；bootstrap 状态机按 ADR-024 实现（staging + 原子切指针）
- **壳的第二块（dsh-ctl）**：唯一公开入口 —— 环境归一化 · 动词白名单（未知/未实现都明确报 2）·
  cgroup 搬家（best-effort，四类 v1 控制器 + v2，**搬不动如实报**）· 审计日志 `log/ctl.log` · 原样 `exec` service.sh。
  `tools/test-dsh-ctl.sh` 11 条断言全绿；在真机上跑可顺带验证 cgroup 搬家（ADR-019 的验收点）
- **payload 规范与打包器**：[docs/payload.md](docs/payload.md) 定两件套（`payload-<baked>.tar.gz` + `payload.json`）、
  归档布局（`rootfs/` 可选 · `node/` · `dsh/` · `bin/`）、schema-1 字段、四道校验链；
  `tools/build-payload.py` 做**确定性**构建（排序 / uid=0 / 固定 mtime / gzip mtime=0）+ `--verify` + `--selftest`（确定性 + 篡改检测）
- **裁决落地：payload 两层 + curl 修正（2026-10-18 审计）**
  - `service.sh` 改为两层：`base/node/`（换 DSH 时**复用**）+ `base/dsh-<baked>/`（切换）；`active` 只指向 DSH 层；
    inbox 只保留下一份同类产物；契约测试 32 条（含"换版本时 Node 层复用"与退出码 0/10/20/30/40）
  - `tools/build-payload.py` 改为 `--kind node|dsh` 分两层构建（各自确定性 + 校验 + 自测）
  - **ADR-013 / ADR-024 修正**：设备有 `curl 8.21.0`（HTTP2/HTTP3、OpenSSL），`/system/bin/wget` 反而不存在 → 下载器首选 curl
  - ADR-019 补实测限定：KSU 的 `su -c` 起手就在 `/apps`，搬家只对 App 内启动有意义
  - threat-model §6.2 修正：chroot-distro 的 `android-bind` 默认 enable，`/sdcard` 暴露面会自己回来（不是"默认没有"）
  - research §9.1 devpts 措辞修正（宿主 vs 容器是两回事）；设备模块数 9 → 10
- 设计文档：ADR-001 ~ ADR-025 全部拍板；威胁模型含「不设防声明」
- **ADR-024（payload 交付形态与首启自举）**：模块 zip 永不装 payload（只装 < 1 MB 的引导器）；
  首启由壳触发/执行/监督：离线 inbox 优先 → 否则 busybox wget 下载 → 校验 → staging 解压 → 原子切指针；
  修订 ADR-013 的"离线"条款；三条硬约束（无 curl / 解压前查空间 / 纯 POSIX sh）
- **版本号分层（ADR-025，2026-10-18）**：第 4 位改成**烘焙台账序号**，对着 `baked` 而不是 `floor`
  - 新增 [baseline/bake-ledger.json](baseline/bake-ledger.json)（只追加：`seq` ↔ `baked`，第 4 位与 `manifest.baked` 的唯一来源）
    与 [baseline/dsh.env](baseline/dsh.env)（`floor` / `recommended` / `node_floor`）
  - `tools/version.env` 删除 `V_DSH` / `DSH_BAKED`；残留会被生成器 exit 2 拒绝（迁移不许静默忽略）
  - 生成器从台账派生第 4 位与 `baked`，新增校验：`seq` 连续、semver 合法；回滚 / 重复只告警
  - 新增 [tools/test-versioning.py](tools/test-versioning.py)（20 条断言，含"故意写坏必须拒绝"）并接进 CI
  - 明文规则：`version` **永不参与比较**；模块更新只认整数 `versionCode`
  - 文档同步：versioning §2/§5/§10-§12、ADR-010 修订注记、baseline §4/§7、payload §3/§6、pitfalls A21
- **版本闸门接线（ADR-026，2026-10-18）**：`service.sh start` 之前先跑 `decide`，闸门从"库"变成"门"
  - `spec/gate-vectors.json` 新增第三类 **19 条 decide 向量**；py / sh / node 各加 `decide`，5 个运行体 **95/95 一致**
  - `decide` 是纯函数：只回 `verdict reason safe_mode`；回落 / 退出码 / 日志留在壳
  - `service.sh`：低于 `floor` 先**原子回落 baked**；回不来才 **exit 50**（与 30 区分）；alpha 只标记安全模式
  - `status` 新增 `manifest` / `version` 两行（只读，不改退出码）
  - 壳契约测试 32 → **43 条**（dash / mksh 双端）：回落、50、invalid-installed、alpha、缺 manifest、无测试缝变量
  - **顺带修掉一个真机必炸的旧 bug**：入口脚本把 `${DSH_PATH_OVERRIDE:-}` 写成了字面量 `@@{DSH_PATH_OVERRIDE:-}`，
    在设备上（没有该测试变量）`set -u` 直接报 `parameter not set`；测试因为总是导出它而全绿。记入 [pitfalls A22](docs/pitfalls.md)
  - 变异证据：把 alpha 的 `safe_mode` 改成 0 → `FAIL 94/95`；真机自检脚本扩到 95 条（**真机 95/95 待重跑**）

> 尚无模块包。此版本将随首个 Release 发布。

