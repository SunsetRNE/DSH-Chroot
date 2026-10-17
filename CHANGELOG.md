# 变更记录

版本号与 `module.prop` 的 `version` 一致（[规范](docs/versioning.md)）。`update.json` 的 `changelog` 指向本文件。

## v1.0.0.1（未发布）

- 模块身份定稿：`id=Zodiac-Quill-Saga` · `name=DSH Chroot` · 仓库 `DSH-Chroot`
- 版本真源与生成器落地：`tools/version.env` → `build/module.prop` / `build/manifest.json` / `build/apk-version.properties`
- 生成器改为 fail-closed：占位全文扫描、`floor ≤ baked`、`recommended > baked`、模板注释不进产物、`--draft` 逃生口
- 新增 `tools/semver.py`：semver 2.0.0 比较的权威实现 + 22 条自检向量
- 设计文档：ADR-001 ~ ADR-023 全部拍板；威胁模型含「不设防声明」

> 尚无模块包。此版本将随首个 Release 发布。

