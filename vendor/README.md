# vendor —— 外部依赖的仓库内基准线

上游（chroot-distro / DSH）变化很快，而 payload 又必须可复现。这里放**打包真正需要的
最小资料**，以及校验它们用的哈希与清单。原则：

> 能在仓库里钉死的，就不依赖“构建时上游刚好是什么”。

## 布局

| 路径 | 内容 | 许可证 |
|---|---|---|
| `chroot-distro/chroot-distro` | 上游脚本，**未修改**（90 KB） | GPL-3.0-or-later |
| `chroot-distro/module.prop` | 上游模块身份（版本 2.1.0+main.20251218） | 同上 |
| `chroot-distro/LICENSE` | GPLv3 全文 | 同上 |
| `chroot-distro/SOURCE.json` | 来源、版本、脚本 sha256、zip sha256 | — |
| `dsh/dsh-0.2.0-rc.2.tgz` | npm 包原始 tarball（24 KB） | MIT |
| `dsh/package/` | 解包后的 `@deepseek-ai/dsh` 本体（20 个文件） | MIT |
| `dsh/npm-shrinkwrap.json` | 已验证安装树的依赖记录：538 个包的精确版本 + integrity（**不是** drop-in `npm ci`） | — |
| `dsh/tree.sha256` | 组装后的 DSH 层逐文件清单（29,280 项：路径 / 权限 / sha256） | — |
| `dsh/SOURCE.json` | registry / upstream tag / commit / 各文件哈希 | — |

## 为什么没有把 `node_modules`（513 MB）提交进来

GitHub 单文件上限 100 MB，513 MB 的树既不该进 git，也不该每次构建重新赌一遍上游。
真正的基准线由三件东西组成：

1. `dsh-0.2.0-rc.2.tgz` —— 根包的字节（24 KB）；
2. `npm-shrinkwrap.json` —— 538 个依赖的**精确版本 + integrity**（从已验证的安装树
   `npm shrinkwrap` 生成；它是记录，不是 drop-in `npm ci`）；
3. `tree.sha256` —— 组装后的层逐文件哈希（29,280 项），任何“装出来不一样”都会被抓到。

重建方式是用**本仓库 node 层的 npm** 做一次全局安装（`npm install -g --prefix <stage>
--prefer-offline @deepseek-ai/dsh@0.2.0-rc.2`），然后跑 `vendor-check --stage`。两次独立
安装的树哈希相同，才把该树当成基线。

大件（`dsh-<baked>.tar.gz` / `node-<ver>.tar.gz` / 将来的 rootfs 层）仍然走
`build/` 与 Release，不进仓库；它们的 sha256 写在 `baseline/manifest.example.json`
的 `layers` 里。

## 许可证

- 仓库本体：**MIT**（根目录 `LICENSE`）。
- `vendor/chroot-distro`：**GPL-3.0-or-later**，原样内置，许可证全文在
  `vendor/chroot-distro/LICENSE`。
- `vendor/dsh`：**MIT**，全文在 `vendor/dsh/package/LICENSE`。

根目录 `NOTICE` 说明了“哪部分归哪个许可证”；分发含 chroot-distro 的整包时，
该组件需按 GPLv3 履行源码/许可证义务，我们自己的文件仍是 MIT。

## 更新流程（换基线时）

1. 改 `SOURCE.json` 的版本 / tag / commit；
2. 重新拉取 tarball、脚本、许可证，**先核对 sha256**；
3. 在一个干净目录里用**本仓库 node 层的 npm** 全局安装，再 `npm shrinkwrap` 生成锁文件
   （不要用 `npm install --package-lock-only` 重新 resolve，那会漂）；
4. 生成 `tree.sha256`，并**再做一次独立安装**核对树哈希相同；
5. 若 `baked` 变了：在 `baseline/bake-ledger.json` 追加一行；
6. 重打 payload，把新 sha256 填回 `baseline/manifest.example.json`；
7. 跑 `python3 tools/vendor-check.py` 与全套测试。

## 校验

```bash
python3 tools/vendor-check.py                       # 仓库内文件哈希
python3 tools/vendor-check.py --stage build/stage-dsh-clean/dsh   # 已组装树 vs tree.sha256
```

`tree.sha256` 的行格式：

```
D 755 <path>              # 目录权限由 payload 构建器统一写成 755
F 644|755 <sha256> <path> # 只保留「不可执行 / 可执行」两档
L <target> <path>
```

按路径排序后逐行哈希，得到文件末尾的 `# aggregate <sha256>`。
