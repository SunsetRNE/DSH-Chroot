#!/usr/bin/env python3
"""打模块 zip：确定性、可自测（ADR-024：模块包 < 1 MB，只装"引导器"）。

模块包不是 payload 包：zip 里只有壳（service.sh / dsh-ctl / lib）+ manifest + 安装钩子。
payload（Node 层 + DSH 层）永远不进 zip，首启由 service.sh bootstrap 负责（ADR-024）。

用法:
    python3 tools/build-module.py            # 生成 build/<asset>-<version>.zip
    python3 tools/build-module.py --check    # 与磁盘上的包逐字节比对（CI 用），漂移 exit 1
    python3 tools/build-module.py --selftest # 布局 / 权限 / 占位符 / 安装模拟 / 降级拒绝 / 确定性

前置：先跑 python3 tools/gen-version.py（发布模式；需要 build/module.prop 与 build/manifest.json）。

退出码: 0 成功；1 漂移（--check）；2 输入不合规
"""

import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BUILD = os.path.join(ROOT, "build")
TPL = os.path.join(ROOT, "baseline", "module")
PROP = os.path.join(BUILD, "module.prop")
MANIFEST = os.path.join(BUILD, "manifest.json")
LEDGER = os.path.join(ROOT, "baseline", "bake-ledger.json")
UPDATE_JSON = os.path.join(ROOT, "update.json")

FIXED_DT = (1980, 1, 1, 0, 0, 0)      # 固定时间戳 -> 同样输入永远同一个 sha256
MAX_BYTES = 1024 * 1024               # ADR-024：模块包 < 1 MB

# (包内路径, 源文件, 权限)
ENTRIES = [
    ("module.prop", PROP, 0o644),
    ("manifest.json", MANIFEST, 0o644),
    ("service.sh", os.path.join(TPL, "service.sh"), 0o755),
    ("uninstall.sh", os.path.join(TPL, "uninstall.sh"), 0o755),
    ("customize.sh", os.path.join(TPL, "customize.sh"), 0o755),
    ("META-INF/com/google/android/update-binary", os.path.join(TPL, "update-binary"), 0o755),
    ("META-INF/com/google/android/updater-script", os.path.join(TPL, "updater-script"), 0o644),
    ("bin/service.sh", os.path.join(ROOT, "service.sh"), 0o755),
    ("bin/dsh-ctl", os.path.join(ROOT, "dsh-ctl"), 0o755),
    ("lib/semver-gate.sh", os.path.join(ROOT, "lib", "semver-gate.sh"), 0o644),
]

EXECUTABLES = [arc for arc, _, mode in ENTRIES if mode == 0o755]


def die(msg):
    print("错误: " + msg, file=sys.stderr)
    sys.exit(2)


def read_text(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def read_json(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def read_prop(path):
    data = {}
    for line in read_text(path).splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = value.strip()
    return data


def ledger_baked():
    data = read_json(LEDGER)
    bakes = data.get("bakes") or []
    if not bakes:
        die("烘焙台账 bakes 为空")
    return bakes[-1].get("baked")


def target_name(version):
    """资产名不另立真源：从 update.json 的 zipUrl 反推，既省一个字段也防止两处漂移。"""
    if not os.path.exists(UPDATE_JSON):
        die("找不到 update.json")
    data = read_json(UPDATE_JSON)
    base = str(data.get("zipUrl", "")).rsplit("/", 1)[-1]
    if not base.endswith("-" + version + ".zip"):
        die("update.json 的 zipUrl 文件名（" + base + "）与 version（" + version + "）对不上")
    if str(data.get("version")) != version:
        die("update.json 的 version(" + str(data.get("version")) + ") 与 module.prop（" + version + "）不一致")
    return base


def build():
    for path in [src for _, src, _ in ENTRIES]:
        if not os.path.exists(path):
            die("缺少文件: " + os.path.relpath(path, ROOT) + "（先跑 tools/gen-version.py）")

    prop = read_prop(PROP)
    for key in ("id", "name", "version", "versionCode"):
        if not prop.get(key):
            die("module.prop 缺字段: " + key)
    version = prop["version"]

    manifest = read_json(MANIFEST)
    if str(manifest.get("module", {}).get("version")) != version:
        die("manifest.module.version 与 module.prop 的 version 不一致")
    baked = ledger_baked()
    if manifest.get("baked") != baked:
        die("manifest.baked(" + str(manifest.get("baked")) + ") 与烘焙台账最后一条（" + str(baked) + "）不一致")

    # pitfalls A23：包根一旦出现 install.sh，Magisk/KernelSU 会判成 legacy 模块，只解压几个文件
    if any(arc == "install.sh" for arc, _, _ in ENTRIES):
        die("包根不能有 install.sh：安装器会把它判成 legacy 模块（docs/pitfalls.md A23）")

    files = []
    total = 0
    for arc, src, mode in ENTRIES:
        raw = open(src, "rb").read()
        if b"@@{" in raw:
            die(arc + " 里还有未展开的 @@{...} 占位符（入口脚本曾因此真机报 parameter not set）")
        total += len(raw)
        files.append((arc, raw, mode))
    if total > MAX_BYTES:
        die("模块包解压后 " + str(total) + " 字节，超过 1 MB（ADR-024 只装引导器）")

    files.sort(key=lambda item: item[0])
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        for arc, raw, mode in files:
            info = zipfile.ZipInfo(arc, FIXED_DT)
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (0o100000 | mode) << 16
            zf.writestr(info, raw)
    return target_name(version), buf.getvalue(), total


def main(argv):
    if "--selftest" in argv:
        return selftest()

    name, data, raw_total = build()
    out = os.path.join(BUILD, name)
    digest = hashlib.sha256(data).hexdigest()

    if "--check" in argv:
        old = b""
        if os.path.exists(out):
            old = open(out, "rb").read()
        if old != data:
            print("漂移: " + os.path.relpath(out, ROOT) + " 与当前源码不一致，请重新打包", file=sys.stderr)
            return 1
        print("一致: " + os.path.relpath(out, ROOT) + "（" + str(len(data)) + " 字节，sha256 " + digest[:12] + "…）")
        return 0

    with open(out, "wb") as fh:
        fh.write(data)
    print("写入 " + os.path.relpath(out, ROOT) + "（" + str(len(data)) + " 字节）")
    print("sha256 " + digest)
    print("条目 " + str(len(ENTRIES)) + " 个 · 解压后 " + str(raw_total) + " 字节（上限 " + str(MAX_BYTES) + "）")
    if "REPLACE_ME" in read_text(MANIFEST):
        print("注意: manifest.layers 还是 REPLACE_ME —— 这是开发包；payload 打好后要用真实哈希重打。", file=sys.stderr)
    return 0


def extract_with_modes(zpath, dest):
    """按真实安装器的方式解包：有 unzip 就用它（会恢复 Unix 权限），否则手动补。"""
    unzip = shutil.which("unzip")
    if unzip:
        subprocess.run([unzip, "-q", "-o", zpath, "-d", dest], check=True)
        return
    with zipfile.ZipFile(zpath) as zf:
        for info in zf.infolist():
            target = os.path.join(dest, info.filename)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "wb") as fh:
                fh.write(zf.read(info))
            mode = (info.external_attr >> 16) & 0o777
            if mode:
                os.chmod(target, mode)


def selftest():
    name, data, _ = build()
    fails = []
    stats = {"ok": 0, "fail": 0}

    def chk(desc, cond, extra=""):
        print(("ok   " if cond else "FAIL ") + desc + ((" -- " + extra) if (extra and not cond) else ""))
        if cond:
            stats["ok"] += 1
        else:
            stats["fail"] += 1
            fails.append(desc)

    chk("模块包 < 1 MB", len(data) < MAX_BYTES, str(len(data)))
    chk("文件名来自 update.json", name.endswith(".zip") and "DSH-Chroot" in name, name)

    required = {arc for arc, _, _ in ENTRIES}
    with zipfile.ZipFile(io.BytesIO(data)) as zf:
        names = set(zf.namelist())
        missing = sorted(required - names)
        chk("必需条目齐全", not missing, ", ".join(missing))
        chk("包根没有 install.sh（legacy 陷阱 A23）", "install.sh" not in names)
        bad_modes = []
        for arc in EXECUTABLES:
            info = zf.getinfo(arc)
            if ((info.external_attr >> 16) & 0o777) != 0o755:
                bad_modes.append(arc)
        chk("可执行位 = 755", not bad_modes, ", ".join(bad_modes))
        leftovers = [n for n in sorted(names) if b"@@{" in zf.read(n)]
        chk("没有未展开的 @@{...}", not leftovers, ", ".join(leftovers))
        prop_line = zf.read("module.prop").decode("utf-8")
        chk("module.prop 带 updateJson", "updateJson=https://" in prop_line)

    tmp = tempfile.mkdtemp(prefix="dsh-module-")
    try:
        zpath = os.path.join(tmp, name)
        with open(zpath, "wb") as fh:
            fh.write(data)
        mod = os.path.join(tmp, "mod")
        extract_with_modes(zpath, mod)
        chk("解包后 bin/service.sh 可执行",
            (os.stat(os.path.join(mod, "bin", "service.sh")).st_mode & 0o777) == 0o755)

        droot = os.path.join(tmp, "dsh")
        mdir = os.path.join(tmp, "modules")
        os.makedirs(mdir)
        env = dict(os.environ)
        env.update({
            "MODPATH": mod,
            "DSH_ROOT": droot,
            "DSH_MODULES_DIR": mdir,
            "DSH_PATH_OVERRIDE": os.environ.get("PATH", "/usr/bin:/bin"),
        })
        sh = shutil.which("sh") or "/bin/sh"
        r = subprocess.run([sh, os.path.join(mod, "customize.sh")], env=env,
                           capture_output=True, text=True)
        chk("安装模拟：customize.sh rc=0", r.returncode == 0,
            (r.stdout + r.stderr).strip()[:200])
        for rel in ("service.sh", "dsh-ctl", "manifest.json", "lib/semver-gate.sh"):
            chk("安装后存在 " + rel, os.path.exists(os.path.join(droot, rel)))

        r = subprocess.run([sh, os.path.join(droot, "service.sh"), "status"], env=env,
                           capture_output=True, text=True)
        chk("安装后 status rc=0", r.returncode == 0, (r.stdout + r.stderr).strip()[:200])
        chk("status 报 node missing", "node      : missing" in r.stdout)
        chk("闸门识别空层（deny invalid-installed）",
            "deny (invalid-installed)" in r.stdout, r.stdout.strip()[:300])

        env_no_seam = dict(env)
        env_no_seam.pop("DSH_PATH_OVERRIDE", None)
        r = subprocess.run([sh, os.path.join(droot, "service.sh"), "help"], env=env_no_seam,
                           capture_output=True, text=True)
        chk("help 不依赖 DSH_PATH_OVERRIDE",
            r.returncode == 0 and "DSH_SERVICE_HELP" in r.stdout, (r.stdout + r.stderr)[:200])

        prop = read_prop(PROP)
        fake = os.path.join(mdir, prop["id"])
        os.makedirs(fake)
        with open(os.path.join(fake, "module.prop"), "w", encoding="utf-8") as fh:
            fh.write("id=" + prop["id"] + "\nversionCode=999999\n")
        r = subprocess.run([sh, os.path.join(mod, "customize.sh")], env=env,
                           capture_output=True, text=True)
        chk("拒绝降级：旧 versionCode 更高时必须失败",
            r.returncode != 0 and "拒绝降级" in (r.stdout + r.stderr),
            (r.stdout + r.stderr).strip()[:200])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    _, data2, _ = build()
    chk("确定性：两次构建字节相同", data == data2)
    chk("sha256 可复现", hashlib.sha256(data).hexdigest() == hashlib.sha256(data2).hexdigest())

    print()
    if fails:
        print("%d/%d 失败" % (stats["fail"], stats["ok"] + stats["fail"]), file=sys.stderr)
        return 1
    print("OK %d/%d 自测通过：布局 / 权限 / 占位符 / 安装模拟 / 降级拒绝 / 确定性"
          % (stats["ok"], stats["ok"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
