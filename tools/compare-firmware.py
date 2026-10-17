#!/usr/bin/env python3
"""比对两份一加/欧加固件包：只看"内核侧四件套"，判断是否同一分支/同一镜像。

用法:
    python3 compare-firmware.py <包A> <包B>

<包> 可以是：
  1) 解包目录（含 boot.img / init_boot.img / vbmeta.img / dtbo.img）
  2) 全量 OTA zip（含 payload.bin，可选带 META-INF/com/android/metadata）

只做只读分析，不修改任何文件。
"""
import hashlib
import io
import os
import sys
import zipfile

KERNEL_SIDE = ["boot.img", "init_boot.img", "vbmeta.img", "dtbo.img", "vendor_boot.img", "recovery.img"]


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def inspect(target):
    """返回 {name: sha256} 与 metadata 文本。"""
    images, meta = {}, ""
    if os.path.isdir(target):
        for name in KERNEL_SIDE:
            p = os.path.join(target, name)
            if os.path.isfile(p):
                images[name] = sha256_file(p)
        mpath = os.path.join(target, "META-INF", "com", "android", "metadata")
        if os.path.isfile(mpath):
            meta = open(mpath, encoding="utf-8", errors="replace").read()
        return images, meta, os.path.getsize(target) if False else None
    if zipfile.is_zipfile(target):
        with zipfile.ZipFile(target) as z:
            names = set(z.namelist())
            for name in KERNEL_SIDE:
                if name in names:
                    images[name] = sha256_bytes(z.read(name))
            for cand in ("META-INF/com/android/metadata", "metadata"):
                if cand in names:
                    meta = z.read(cand).decode("utf-8", errors="replace")
                    break
            has_payload = "payload.bin" in names
        return images, meta, has_payload
    raise SystemExit("无法识别: " + target)


def meta_field(meta, key):
    for line in meta.splitlines():
        if line.startswith(key + "="):
            return line.split("=", 1)[1].strip()
    return ""


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    a, b = sys.argv[1], sys.argv[2]
    ia, ma, pa = inspect(a)
    ib, mb, pb = inspect(b)

    print("=== 包 A:", a)
    print("    payload.bin:", "有" if pa else ("无" if pa is False else "未知"))
    for k in ("pre-build", "post-build", "post-build-incremental", "post-timestamp", "post-security-patch-level"):
        v = meta_field(ma, k)
        if v:
            print("    " + k + " = " + v)
    if meta_field(ma, "pre-build"):
        print("    [增量包] 含 pre-build：镜像以差分包形式存放，需配合精确的源版本镜像才能还原，不能直接当回滚套件")
    for name in KERNEL_SIDE:
        if name in ia:
            print("    " + name.ljust(16) + ia[name])

    print()
    print("=== 包 B:", b)
    print("    payload.bin:", "有" if pb else ("无" if pb is False else "未知"))
    for k in ("pre-build", "post-build", "post-build-incremental", "post-timestamp", "post-security-patch-level"):
        v = meta_field(mb, k)
        if v:
            print("    " + k + " = " + v)
    if meta_field(mb, "pre-build"):
        print("    [增量包] 含 pre-build：镜像以差分包形式存放，需配合精确的源版本镜像才能还原，不能直接当回滚套件")
    for name in KERNEL_SIDE:
        if name in ib:
            print("    " + name.ljust(16) + ib[name])

    print()
    print("=== 结论")
    common = [n for n in KERNEL_SIDE if n in ia and n in ib]
    if not common:
        print("两个包里没有可比对的同名镜像。可能原因：")
        print("  1) 至少一方是 OTA zip —— 需先用 payload-dumper 抽出分区；")
        print("  2) 其中一方是【增量包】—— 镜像以差分形式存放，必须配合精确的源版本镜像才能还原。")
        return
    same = [n for n in common if ia[n] == ib[n]]
    diff = [n for n in common if ia[n] != ib[n]]
    print("相同镜像:", ", ".join(same) if same else "无")
    print("不同镜像:", ", ".join(diff) if diff else "无")
    if not diff:
        print("→ 内核侧四件套完全一致：两个包在这部分是同一份镜像，**技术上可互换**（但仍建议各用各的）。")
    else:
        print("→ 存在不一致：**不要混用**。boot/init_boot 必须与设备其余分区（尤其 vendor_dlkm/system_dlkm 的内核模块）匹配，")
        print("  混用可能导致内核模块加载失败、相机/网络异常，甚至无法开机。")


if __name__ == "__main__":
    main()
