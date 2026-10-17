#!/usr/bin/env python3
"""从 version.env 生成 module.prop / manifest.json / APK 版本字段 —— 单一真源。

用法:
    python3 tools/gen-version.py --draft       # 草稿模式：允许未填项（会大声列出），生成到 build/
    python3 tools/gen-version.py               # 发布模式：任何占位都报错退出
    python3 tools/gen-version.py --check       # 只校验生成物与真源是否同步（漂移 → exit 1）
    python3 tools/gen-version.py --env X --out Y [--template T]

设计原则:
  1. 缺值 / 占位一律报错，绝不替使用者编造版本号或名字；
  2. 占位检查覆盖全部字段（URL 中间的 <账号> 也算），并且检查生成物本身；
  3. baked / floor / recommended 的关系用 semver 真比较，不用字符串比大小。

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

REQUIRED = (
    "MODULE_ID", "MODULE_NAME", "AUTHOR", "DESCRIPTION", "UPDATE_JSON",
    "V_MAJOR", "V_FEATURE", "V_PATCH", "V_DSH", "VERSION_CODE",
    "DSH_BAKED", "DSH_FLOOR", "NODE_FLOOR",
)

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


def parse_args(argv):
    opts = {"env": os.path.join(HERE, "version.env"),
            "template": os.path.join(ROOT, "baseline", "manifest.example.json"),
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
        elif a in ("--env", "--template", "--out") and i + 1 < len(argv):
            opts[a[2:]] = argv[i + 1]
            i += 1
        else:
            die("未知参数: " + a)
        i += 1
    return opts


def validate(env, raw_text, draft):
    missing = [k for k in REQUIRED if not env.get(k)]
    if missing:
        die("version.env 缺少字段: " + ", ".join(missing))

    for key in ("V_MAJOR", "V_FEATURE", "V_PATCH", "VERSION_CODE"):
        if not re.fullmatch(r"[0-9]+", env[key]):
            die(key + " 必须是整数，当前为: " + env[key])
    if int(env["VERSION_CODE"]) < 1:
        die("VERSION_CODE 必须 >= 1")
    if not re.fullmatch(r"[0-9]+", env.get("V_DSH", "")):
        die("V_DSH 必须是整数（内置基线的烘焙序号，1 = DSH 0.2.0-rc.2），当前为: " + repr(env.get("V_DSH")))

    for key in ("DSH_BAKED", "DSH_FLOOR"):
        if not semver.is_valid(env[key]):
            die(key + " 不是合法 semver: " + env[key])
    if env.get("DSH_RECOMMENDED") and not semver.is_valid(env["DSH_RECOMMENDED"]):
        die("DSH_RECOMMENDED 不是合法 semver: " + env["DSH_RECOMMENDED"])

    if not semver.gte(env["DSH_BAKED"], env["DSH_FLOOR"]):
        die("DSH_FLOOR(" + env["DSH_FLOOR"] + ") 高于 DSH_BAKED(" + env["DSH_BAKED"]
            + ")：地板比内置基线还新，闸门会永久拒绝启动")
    if env.get("DSH_RECOMMENDED") and not semver.gt(env["DSH_RECOMMENDED"], env["DSH_BAKED"]):
        die("DSH_RECOMMENDED(" + env["DSH_RECOMMENDED"] + ") 必须严格高于 DSH_BAKED("
            + env["DSH_BAKED"] + ")；不想推荐就留空")

    warnings = []
    hits = find_placeholders(raw_text)
    if hits:
        msg = "version.env 仍有未填项: " + " / ".join(hits)
        if not draft:
            die(msg + "（临时预览可加 --draft）")
        warnings.append(msg)
    return warnings


def compose(env):
    version = ".".join((env["V_MAJOR"], env["V_FEATURE"], env["V_PATCH"], env["V_DSH"]))

    prop_lines = [
        "# 由 tools/gen-version.py 从 tools/version.env 生成 —— 不要手改",
        "# version 第 4 位为 " + env["V_DSH"] + "（内置基线 DSH " + env["DSH_BAKED"] + "），只增不减",
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


def compose_manifest(env, template_path, version):
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

    data["baked"] = env["DSH_BAKED"]
    data["floor"] = env["DSH_FLOOR"]
    if env.get("DSH_RECOMMENDED"):
        data["recommended"] = env["DSH_RECOMMENDED"]
    else:
        # 关键：留空就是「不推荐」，不能继承模板里遗留的旧值（曾经让幽灵版本 0.2.1-rc.3 进了产物）
        data.pop("recommended", None)
    data["node_floor"] = env["NODE_FLOOR"]
    return json.dumps(strip_notes(data), ensure_ascii=False, indent=2) + "\n"


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
    env, raw_text = load_env(opts["env"])

    warnings = validate(env, raw_text, opts["draft"])
    version, module_prop, apk = compose(env)
    manifest = compose_manifest(env, opts["template"], version)

    targets = (
        (os.path.join(opts["out"], "module.prop"), module_prop),
        (os.path.join(opts["out"], "manifest.json"), manifest),
        (os.path.join(opts["out"], "apk-version.properties"), apk),
    )
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
            print("漂移: 以下生成物与 version.env 不一致 -> " + ", ".join(drift), file=sys.stderr)
            return 1
        print("一致: 生成物与 version.env 同步 (version=" + version + ")")
        for w in warnings:
            print("注意: " + w, file=sys.stderr)
        return 0

    os.makedirs(opts["out"], exist_ok=True)
    for path, text in targets:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        print("写入 " + os.path.relpath(path, ROOT))
    print("version=" + version + "  versionCode=" + env["VERSION_CODE"])
    for w in warnings:
        print("注意（草稿）: " + w, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
