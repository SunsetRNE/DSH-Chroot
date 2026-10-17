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
- 设计文档：ADR-001 ~ ADR-024 全部拍板；威胁模型含「不设防声明」
- **ADR-024（payload 交付形态与首启自举）**：模块 zip 永不装 payload（只装 < 1 MB 的引导器）；
  首启由壳触发/执行/监督：离线 inbox 优先 → 否则 busybox wget 下载 → 校验 → staging 解压 → 原子切指针；
  修订 ADR-013 的"离线"条款；三条硬约束（无 curl / 解压前查空间 / 纯 POSIX sh）

> 尚无模块包。此版本将随首个 Release 发布。

