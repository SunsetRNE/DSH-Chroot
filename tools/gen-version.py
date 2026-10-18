#!/usr/bin/env python3
"""从三个真源生成 module.prop / manifest.json / APK 版本字段。

三个输入各管一件事（互不重复）:
    tools/version.env           模块身份 + version 前三段 + versionCode
    baseline/dsh.env            DSH 基线参数：DSH_FLOOR / DSH_RECOMMENDED / NODE_FLOOR
    baseline/bake-ledger.json   烘焙台账：seq <-> baked（第 4 位与 manifest.baked 的唯一来源）

用法:
    python3 tools/gen-version.py --draft       # 草稿模式：允许未填项（会大声列出），生成到 build/
    python3 tools/gen-version.py               # 发布模式：任何占位都报错退出
    python3 tools/gen-version.py --check       # 只校验生成物与真源是否同步（漂移 → exit 1）
    python3 tools/gen-version.py --env X --dsh-env Y --ledger Z --out D --template T --update-json U

设计原则:
  1. 缺值 / 占位一律报错，绝不替使用者编造版本号或名字；
  2. 第 4 位与 baked 都由台账派生 —— 这两个值手写不了，所以也漂不了；
  3. baked / floor / recommended 的关系用 semver 真比较，不用字符串比大小；
  4. update.json（Root 管理器的检查更新入口）必须与 version / versionCode 同步。

退出码: 0 成功 / 1 漂移（--check）/ 2 输入或产物不合规
"""

import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import semver  # 同目录的权威比较实现，见 docs/versioning.md §9

# 模块版本真源（tools/version.env）
REQUIRED = (
    "MODULE_ID", "MODULE_NAME", "AUTHOR", "DESCRIPTION", "UPDATE_JSON",
    "V_MAJOR", "V_FEATURE", "V_PATCH", "VERSION_CODE",
)

# DSH 基线参数（baseline/dsh.env）—— baked 不在这里，它来自台账
REQUIRED_DSH = ("DSH_FLOOR", "NODE_FLOOR")

# 这些字段已经迁走；留在 version.env 里会被静默忽略，所以直接拒绝
DEPRECATED = {
    "V_DSH": "第 4 位现在由 baseline/bake-ledger.json 的 seq 派生",
    "DSH_BAKED": "baked 现在是烘焙台账的最后一条",
    "DSH_FLOOR": "已移到 baseline/dsh.env",
    "DSH_RECOMMENDED": "已移到 baseline/dsh.env",
    "NODE_FLOOR": "已移到 baseline/dsh.env",
}

# 占位形状：<任意标签> / REPLACE_ME / 待定 / TBD
PLACEHOLDER_RE = re.compile(r"<[^<>\n]{1,40}>|REPLACE_ME|待定|\bTBD\b")


def die(msg):
    print("错误: " + msg, file=sys.stderr)
    sys.exit(2)


def find_placeholders(text):
    return sorted(set(PLACEHOLDER_RE.findall(text)))


def load_env(path):
    if not os.path.exists(path):
        die("找不到真源文件: " + path)
    env = {}
    with open(path, encoding="utf-8") as fh:
        raw = fh.read()
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key.strip()] = value.strip()
    return env, raw


def load_ledger(path):
    if not os.path.exists(path):
        die("找不到烘焙台账: " + path)
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except ValueError as exc:
        die("烘焙台账不是合法 JSON: " + str(exc))
    if not isinstance(data, dict):
        die('烘焙台账顶层必须是对象：{"schema": 1, "bakes": [...]}')
    if data.get("schema") != 1:
        die("烘焙台账 schema 必须是 1，当前为: " + repr(data.get("schema")))
    bakes = data.get("bakes")
    if not isinstance(bakes, list) or not bakes:
        die("烘焙台账的 bakes 必须是非空数组")
    return bakes


def validate_ledger(bakes):
    """台账是第 4 位与 baked 的唯一来源，所以它的形状必须能被机器核对。"""
    warnings = []
    seen = {}
    prev = None
    for idx, entry in enumerate(bakes, 1):
        if not isinstance(entry, dict):
            die("烘焙台账第 %d 条不是对象" % idx)
        seq = entry.get("seq")
        baked = entry.get("baked")
        if not isinstance(seq, int) or isinstance(seq, bool):
            die("烘焙台账第 %d 条的 seq 必须是整数，当前为: %r" % (idx, seq))
        if seq != idx:
            die("烘焙台账 seq 必须从 1 连续递增：第 %d 条的 seq 是 %d，期望 %d"
                "（不许跳号、不许删旧条目）" % (idx, seq, idx))
        if not isinstance(baked, str) or not semver.is_valid(baked):
            die("烘焙台账第 %d 条的 baked 不是合法 semver: %r" % (idx, baked))
        date = entry.get("date")
        if date is not None and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", str(date)):
            die("烘焙台账第 %d 条的 date 必须是 YYYY-MM-DD，当前为: %r" % (idx, date))
        if baked in seen:
            warnings.append("台账第 %d 条与第 %d 条 baked 重复（%s）：确认这是有意的回滚 / 重烘"
                            % (idx, seen[baked], baked))
        else:
            seen[baked] = idx
        if prev is not None and not semver.gt(baked, prev):
            warnings.append("台账第 %d 条（%s）不高于上一条（%s）：回滚是合法的，确认是有意为之"
                            % (idx, baked, prev))
        prev = baked
    return bakes[-1]["seq"], bakes[-1]["baked"], warnings


def parse_args(argv):
    opts = {"env": os.path.join(HERE, "version.env"),
            "dsh-env": os.path.join(ROOT, "baseline", "dsh.env"),
            "ledger": os.path.join(ROOT, "baseline", "bake-ledger.json"),
            "template": os.path.join(ROOT, "baseline", "manifest.example.json"),
            "update-json": os.path.join(ROOT, "update.json"),
            "out": os.path.join(ROOT, "build"),
            "check": False,
            "draft": False}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--check":
            opts["check"] = True
        elif a == "--draft":
            opts["draft"] = True
        elif a in ("--env", "--dsh-env", "--ledger", "--template", "--update-json", "--out") and i + 1 < len(argv):
            opts[a[2:]] = argv[i + 1]
            i += 1
        else:
            die("未知参数: " + a)
        i += 1
    return opts


def validate(env, dsh, baked, env_raw, dsh_raw, draft):
    missing = [k for k in REQUIRED if not env.get(k)]
    if missing:
        die("version.env 缺少字段: " + ", ".join(missing))

    stale = [k for k in DEPRECATED if k in env]
    if stale:
        die("version.env 里不该再有 " + "、".join(stale) + " —— "
            + "；".join(DEPRECATED[k] for k in stale))

    missing_dsh = [k for k in REQUIRED_DSH if not dsh.get(k)]
    if missing_dsh:
        die("baseline/dsh.env 缺少字段: " + ", ".join(missing_dsh))

    for key in ("V_MAJOR", "V_FEATURE", "V_PATCH", "VERSION_CODE"):
        if not re.fullmatch(r"[0-9]+", env[key]):
            die(key + " 必须是整数，当前为: " + env[key])
    if int(env["VERSION_CODE"]) < 1:
        die("VERSION_CODE 必须 >= 1")

    floor = dsh["DSH_FLOOR"]
    recommended = dsh.get("DSH_RECOMMENDED", "")
    if not semver.is_valid(floor):
        die("DSH_FLOOR 不是合法 semver: " + floor)
    if recommended and not semver.is_valid(recommended):
        die("DSH_RECOMMENDED 不是合法 semver: " + recommended)

    if not semver.gte(baked, floor):
        die("DSH_FLOOR(" + floor + ") 高于 baked(" + baked + ")：地板比内置基线还新，闸门会永久拒绝启动")
    if recommended and not semver.gt(recommended, baked):
        die("DSH_RECOMMENDED(" + recommended + ") 必须严格高于 baked(" + baked + ")；不想推荐就留空")

    warnings = []
    for name, text in (("version.env", env_raw), ("baseline/dsh.env", dsh_raw)):
        hits = find_placeholders(text)
        if hits:
            msg = name + " 仍有未填项: " + " / ".join(hits)
            if not draft:
                die(msg + "（临时预览可加 --draft）")
            warnings.append(msg)
    return warnings


def compose(env, seq, baked):
    version = ".".join((env["V_MAJOR"], env["V_FEATURE"], env["V_PATCH"], str(seq)))

    prop_lines = [
        "# 由 tools/gen-version.py 从 version.env + dsh.env + bake-ledger.json 生成 —— 不要手改",
        "# version 第 4 位为 " + str(seq) + "（烘焙台账 seq " + str(seq) + " = DSH " + baked + "），只增不减",
        "id=" + env["MODULE_ID"],
        "name=" + env["MODULE_NAME"],
        "version=" + version,
        "versionCode=" + env["VERSION_CODE"],
        "author=" + env["AUTHOR"],
        "description=" + env["DESCRIPTION"],
        "updateJson=" + env["UPDATE_JSON"],
    ]
    if env.get("MANAGED_FEATURES"):
        prop_lines.append("managedFeatures=" + env["MANAGED_FEATURES"])
    else:
        prop_lines.append("# managedFeatures: 空（不接管任何内核特性）")
    module_prop = "\n".join(prop_lines) + "\n"

    apk = "\n".join([
        "# 由 tools/gen-version.py 生成 —— APK 构建读取本文件",
        "# 对齐规则: 内部版本码 = 模块 versionCode；外部版本号 = 模块 version 结构",
        "VERSION_CODE=" + env["VERSION_CODE"],
        "VERSION_NAME=" + version,
        "",
    ])
    return version, module_prop, apk


def strip_notes(obj):
    """下划线开头的键是写给维护者的模板注释（里面有 <port> 这类散文占位），不进产物。"""
    if isinstance(obj, dict):
        return {k: strip_notes(v) for k, v in obj.items() if not k.startswith("_")}
    if isinstance(obj, list):
        return [strip_notes(v) for v in obj]
    return obj


def compose_manifest(env, dsh, version, seq, baked, template_path):
    if not os.path.exists(template_path):
        die("找不到 manifest 模板: " + template_path)
    with open(template_path, encoding="utf-8") as fh:
        data = json.load(fh)

    module = data.setdefault("module", {})
    module["id"] = env["MODULE_ID"]
    module["author"] = env["AUTHOR"]
    module["version"] = version
    module["versionCode"] = int(env["VERSION_CODE"])
    module["managed_features"] = [f for f in env.get("MANAGED_FEATURES", "").split(",") if f]

    data["baked"] = baked
    data["baked_seq"] = seq
    data["floor"] = dsh["DSH_FLOOR"]
    if dsh.get("DSH_RECOMMENDED"):
        data["recommended"] = dsh["DSH_RECOMMENDED"]
    else:
        # 关键：留空就是「不推荐」，不能继承模板里遗留的旧值（曾经让幽灵版本 0.2.1-rc.3 进了产物）
        data.pop("recommended", None)
    data["node_floor"] = dsh["NODE_FLOOR"]
    return json.dumps(strip_notes(data), ensure_ascii=False, indent=2) + "\n"


def check_update_json(path, version, version_code, draft):
    """update.json 是给 Root 管理器检查更新的文件，必须与版本身份同步（否则更新按钮指向错的包）。"""
    if not os.path.exists(path):
        msg = "缺少 update.json：模块的检查更新会 404"
        if not draft:
            die(msg + "（发布前必须补上；临时预览可加 --draft）")
        return [msg]
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except ValueError as exc:
        die("update.json 不是合法 JSON: " + str(exc))

    for key in ("version", "versionCode", "zipUrl"):
        if not data.get(key) and data.get(key) != 0:
            die("update.json 缺少字段: " + key)

    if str(data["version"]) != version:
        die("update.json 的 version(" + str(data["version"]) + ") 与真源生成的 version("
            + version + ") 不一致：改版本时两处必须同步")
    if int(data["versionCode"]) != int(version_code):
        die("update.json 的 versionCode(" + str(data["versionCode"]) + ") 与 version.env 的 VERSION_CODE("
            + version_code + ") 不一致")

    warnings = []
    zip_url = str(data["zipUrl"])
    if ("/download/v" + version + "/") not in zip_url:
        warnings.append("update.json 的 zipUrl 里没有 /download/v" + version
                        + "/ 这一段：按约定 tag 是 v<version>，请核对")
    return warnings


def scan_outputs(targets, draft):
    warnings = []
    for name, text in targets:
        hits = find_placeholders(text)
        if not hits:
            continue
        msg = "生成物 " + name + " 里仍有未填项: " + " / ".join(hits)
        if not draft:
            die(msg + "（补齐模板里的值；临时预览可加 --draft）")
        warnings.append(msg)
    return warnings


def main():
    opts = parse_args(sys.argv[1:])

    env, env_raw = load_env(opts["env"])
    dsh, dsh_raw = load_env(opts["dsh-env"])
    bakes = load_ledger(opts["ledger"])

    seq, baked, warnings = validate_ledger(bakes)
    warnings += validate(env, dsh, baked, env_raw, dsh_raw, opts["draft"])

    version, module_prop, apk = compose(env, seq, baked)
    manifest = compose_manifest(env, dsh, version, seq, baked, opts["template"])

    targets = (
        (os.path.join(opts["out"], "module.prop"), module_prop),
        (os.path.join(opts["out"], "manifest.json"), manifest),
        (os.path.join(opts["out"], "apk-version.properties"), apk),
    )
    warnings += check_update_json(opts["update-json"], version, env["VERSION_CODE"], opts["draft"])
    warnings += scan_outputs(targets, opts["draft"])

    if opts["check"]:
        drift = []
        for path, want in targets:
            got = ""
            if os.path.exists(path):
                with open(path, encoding="utf-8") as fh:
                    got = fh.read()
            if got != want:
                drift.append(os.path.relpath(path, ROOT))
        if drift:
            print("漂移: 以下生成物与真源不一致 -> " + ", ".join(drift), file=sys.stderr)
            return 1
        print("一致: 生成物与真源同步 (version=" + version + ", bake seq=" + str(seq) + ")")
        for w in warnings:
            print("注意: " + w, file=sys.stderr)
        return 0

    os.makedirs(opts["out"], exist_ok=True)
    for path, text in targets:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        print("写入 " + os.path.relpath(path, ROOT))
    print("version=" + version + "  versionCode=" + env["VERSION_CODE"]
          + "  baked=" + baked + "  seq=" + str(seq))
    for w in warnings:
        print("注意（草稿）: " + w, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
