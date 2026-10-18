# payload 规范（两层版）

> 模块 zip 装壳（< 1 MB），payload 装"真正的大件"。**payload 分两层**（2026-10-18 裁决）：
> Node 层不随 DSH 版本变，DSH 层每个 `baked` 一份 —— 换 DSH 时 Node 层**复用、不重装**。

---

## 1. 两层与落点

| 层 | 内容 | 落点 | 何时变 |
|---|---|---|---|
| **node** | node + npm + pnpm | `base/node/` | 换 Node 版本时 |
| **dsh** | `@deepseek-ai/dsh` 完整树 + `bin/` wrapper | `base/dsh-<baked>/` | 每次换 DSH 基线 |

`active` 只指向 **DSH 层名**（= `baked`）；Node 版本记录在 `base/node/.layer` 里，由 bootstrap 判定是否复用。

## 2. 产物：每层两件套（共 4 个文件）

```
node-<ver>.tar.gz      + node.json
dsh-<baked>.tar.gz     + dsh.json
```

| 文件 | 内容 | 谁读 |
|---|---|---|
| 归档内 `node.meta.json` / `dsh.meta.json` | 自描述元数据（**无 sha256**） | 解包后与旁挂清单对账 |
| 归档外 `node.json` / `dsh.json` | meta + `sha256` + `size` | `service.sh bootstrap` 先校验再解包 |

为什么分开：**sha256 不能写进被它哈希的归档里**（自指）。

## 3. 清单字段（schema 1）

**node.json**

| 字段 | 例 | 说明 |
|---|---|---|
| `schema` | `1` | 不认识就拒绝 |
| `layer` | `node` | 层种类 |
| `version` | `24.19.0` | 精确版本（不写范围） |
| `pnpm` | `11.0.0` | 同上 |
| `sha256` / `size` | … | 仅旁挂清单有 |

**dsh.json**

| 字段 | 例 | 说明 |
|---|---|---|
| `schema` | `1` | |
| `layer` | `dsh` | |
| `baked` | `0.2.0-rc.2` | 必须与 `manifest.baked` 一致（两者都取自烘焙台账最后一条） |
| `distro` | `{ubuntu,noble,24.04,glibc}` | 层是按哪个发行版烘焙的 |
| `sha256` / `size` | … | 仅旁挂清单有 |

> `manifest.layers` 的**两行**正好对应这两个 tarball 的 sha256：
> `"base/node"` → `node-<ver>.tar.gz`，`"base/dsh-<baked>"` → `dsh-<baked>.tar.gz`。

## 4. 确定性构建

条目排序 · `uid/gid=0` · `uname/gname` 空 · `mtime` 固定（`SOURCE_DATE_EPOCH`，默认 `1704067200`）· gzip `mtime=0`。
同样输入 → 同一个 sha256。

```bash
python3 tools/build-payload.py --kind node --version 24.19.0 --stage /path/to/node-stage
python3 tools/build-payload.py --kind dsh  --baked 0.2.0-rc.2 --stage /path/to/dsh-stage
python3 tools/build-payload.py --verify build/dsh-0.2.0-rc.2.tar.gz --manifest build/dsh.json
python3 tools/build-payload.py --selftest        # 两层各自：确定性 + 校验 + 篡改检测
```

层内必需项：node 层要有 `bin/node`；dsh 层要有 `dsh/package.json`。缺了构建器直接拒绝。

## 5. 校验链（五道）

```
① 旁挂清单 sha256            下载/投递后立刻算（每个层各自校验）
② 归档内 meta 与清单对账      layer / version|baked / pnpm 必须一致
③ Node 层版本比对            已装版本与清单相同 -> 复用，不重装（两层的收益）
④ 解包后层名与 active 指针    切换是 staging + 原子 rename
⑤ 容器内实际 dsh --version 与 baked 对账   ← 防"层与 manifest 说的不是一回事"
```

⑤ 是最容易跳过、也最重要的一道：它验证的不是"文件对不对"，而是"**跑起来的那个东西是不是它**"。

## 6. 与现有文件的对应关系

| 位置 | 谁写 | 谁读 |
|---|---|---|
| `baseline/bake-ledger.json` 的最后一条 `baked` | 人（只追加） | 构建器（dsh 层 `baked` 的默认值）、生成器（`manifest.baked` / `baked_seq` / `version` 第 4 位） |
| `build/{node,dsh}-*.tar.gz` + `{node,dsh}.json` | `tools/build-payload.py` | 发布 / 投递 |
| `/data/local/dsh/inbox/` | `dsh-ctl install` 或用户投递 | `service.sh bootstrap` |
| `/data/local/dsh/base/node/` · `base/dsh-<baked>/` | `service.sh bootstrap` | runtime adapter（bind 进容器） |
| `/data/local/dsh/active` | `service.sh bootstrap` | `service.sh start` / `status` |

## 7. 空间与失败语义

- 峰值 ≈ **压缩包 + 解压副本**（每层各自算，两层同时存在时 ≈ 2×）；空间不足要**提前**失败。
- 退出码沿用 ADR-013：`30` = 层缺失 / 校验失败 / 空间不足 / 解包失败；`40` = 切换失败。
- 失败时 **`active` 指针保持不动**；Node 层已成功切换而 DSH 层失败时，Node 层保留（下次复用）。

## 8. 仍未定的两处

1. **`rootfs/` 进不进 payload**：当前规范不含 rootfs —— 容器根文件系统由 `chroot-distro` 负责。
   若不接受"首次还要跑一次 `chroot-distro download ubuntu`"，就得把 `ubuntu-base-24.04.5-arm64` 的 URL + sha256 钉进 bootstrap。
2. **Node / pnpm 精确版本**：`24.19.0` / `11.0.0` 仍是占位口径，打包前按 [baseline.md](./baseline.md) 复核 libc 依赖后钉死。
