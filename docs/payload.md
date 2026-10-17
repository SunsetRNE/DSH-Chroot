# payload 规范（ADR-024 的实现面）

> 一句话：**模块 zip 装壳（< 1 MB），payload 装"真正的大件"**。两者都上设备之后，壳才能把 DSH 起起来。
> 本文只定"包长什么样、怎么校验"；"怎么交付、怎么自举"在 [decisions.md ADR-024](./decisions.md)。

---

## 1. 产物：两件套（必须成对放进 inbox）

```
payload-<baked>.tar.gz      归档本体
payload.json                旁挂清单（壳校验的依据）
```

为什么分两个：**sha256 不能写进被它哈希的归档里**（自指）。所以

| 文件 | 内容 | 谁读 |
|---|---|---|
| 归档内 `payload.meta.json` | 自描述元数据（**无 sha256**） | 解包后与旁挂清单对账 |
| 归档外 `payload.json` | meta + `sha256` + `size` | `service.sh bootstrap` 先校验再解包 |

解包后壳还会比对两者的 `baked` —— 防止"清单说的和包里装的不是一回事"。

## 2. 归档布局

```
payload.meta.json
rootfs/          ← 可选：容器根文件系统的初始化内容（仅在容器 rootfs 缺失时使用）
node/            ← Node 24（arm64 / glibc）+ npm + pnpm
dsh/             ← @deepseek-ai/dsh 完整树（含 node_modules）
bin/             ← 壳装的 wrapper（dsh / node / npm / pnpm）
```

- `node/bin/node` 与 `dsh/package.json` 是**必需项**，缺了构建器直接拒绝。
- 解包目标：`/data/local/dsh/base/<baked>/`（整层原子切换，见 ADR-009 / ADR-024 决定 D）。
- `rootfs/` 的落点在容器运行时目录（当前 `/data/local/chroot-distro/ubuntu`），**仅首次**使用。

## 3. `payload.json` 字段（schema 1）

| 字段 | 例 | 说明 |
|---|---|---|
| `schema` | `1` | 格式版本；不认识的版本必须拒绝 |
| `baked` | `0.2.0-rc.2` | **内置 DSH 版本**（完整 semver），必须与 `manifest.baked` 一致 |
| `node` | `24.19.0` | 精确到小版本（不写范围） |
| `pnpm` | `11.0.0` | 同上 |
| `distro` | `{name,release,version,libc}` | 目前固定 ubuntu / noble / 24.04 / glibc |
| `layer` | `0.2.0-rc.2` | 解包后的层名（= `baked`） |
| `created_at` | `1704067200` | 固定时间戳（可复现构建） |
| `sha256` | `…` | **仅旁挂清单有** |
| `size` | `…` | **仅旁挂清单有** |

## 4. 确定性构建（sha256 才有资格当锚点）

规则：条目**排序** · `uid/gid=0` · `uname/gname` 空 · `mtime` 固定（`SOURCE_DATE_EPOCH`，默认 `1704067200`）· gzip `mtime=0`。
同样的输入永远得到同一个 sha256 —— 这样"版本"和"字节"才对得上。

```bash
python3 tools/build-payload.py --stage /path/to/stage          # 产出 build/payload-<baked>.tar.gz + payload.json
python3 tools/build-payload.py --verify build/payload-0.2.0-rc.2.tar.gz --manifest build/payload.json
python3 tools/build-payload.py --selftest                      # 确定性 + 校验 + 篡改检测
```

`--baked` 默认取 [tools/version.env](../tools/version.env) 的 `DSH_BAKED`；显式传值但与之不一致会直接报错（防版本漂移）。

## 5. 校验链（四道，缺一不可）

```
① 旁挂清单 sha256  ← 下载/投递后立刻算（service.sh bootstrap）
② 归档内 meta 与清单对账（baked / node / pnpm 必须一致）
③ 解包后比对层名与 active 指针
④ 容器内实际 dsh --version 与 baked 对账   ← 防"层与 manifest 说的不是一回事"
```

④ 是最后一道，也是最容易被跳过的一道：它验证的不是"文件对不对"，而是"**跑起来的那个东西是不是它**"。

## 6. 与现有文件的对应关系

| 位置 | 谁写 | 谁读 |
|---|---|---|
| `tools/version.env` 的 `DSH_BAKED` | 人 | 构建器（决定 `baked`）、生成器（决定 `manifest.baked`） |
| `build/payload-<baked>.tar.gz` + `build/payload.json` | `tools/build-payload.py` | 发布 / 投递 |
| `/data/local/dsh/inbox/payload*` | `dsh-ctl install` 或用户投递 | `service.sh bootstrap` |
| `/data/local/dsh/base/<baked>/` | `service.sh bootstrap` | runtime adapter（bind 进容器） |
| `/data/local/dsh/active` | `service.sh bootstrap` | `service.sh start` / `status` |

## 7. 空间与失败语义

- 峰值 ≈ **压缩包 + 解压副本**（≈ 2×）；空间不足要**提前**失败，不许解一半。
- 失败退出码沿用 ADR-013：`30` = payload 缺失 / 校验失败 / 空间不足；`40` = 切换失败。
- 失败时 **`active` 指针保持不动** —— 用户仍能用上一个版本（ADR-024 决定 D）。

## 8. 仍未定的两处（写下来免得以后翻旧账）

1. **`rootfs/` 到底进不进 payload**：现在的规范是"可选、仅首次使用"。若不进，首次必须由 `chroot-distro download ubuntu <pinned-url>` 拉基础镜像（届时要把 24.04.5 的 URL 与 sha256 钉死）。
2. **Node / pnpm 的精确版本**：`node 24.19.0` / `pnpm 11.x` 目前是占位口径，打包前要按 [baseline.md](./baseline.md) 的结论钉死并复核 libc 依赖。
