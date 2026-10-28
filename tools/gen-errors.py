#!/usr/bin/env python3
"""从 spec/errors.json 生成 docs/errors.md（单一真源，文档不手改）。

用法:
    python3 tools/gen-errors.py           # 生成 docs/errors.md
    python3 tools/gen-errors.py --check   # 只校验（CI 用）：文档与真源一致、码表无重复

纪律（会拦）:
    - code 必须形如 E-L<层><类>-<大类>-<3 位序号>，例如 E-L1C-MNT-001；全局唯一
      层 = L0K / L1C / L2D / L3S / L4U（见 LAYER_NAME），大类 = MNT/DEV/PTY/…
    - code 里的层前缀必须与 layer 字段一致
    - 每条必须有 symptom / probe / expect / root_cause / fix
    - signatures 里引用的 code 必须存在

退出码: 0 一致 / 1 有问题
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPEC = os.path.join(ROOT, "spec", "errors.json")
OUT = os.path.join(ROOT, "docs", "errors.md")

CODE_RE = re.compile(r"^E-(L[0-4][A-Z])-[A-Z]{2,4}-\d{3}$")
REQUIRED = ("symptom", "probe", "expect", "root_cause", "fix")
LAYER_NAME = {
    "L0K": "L0 内核 / 挂载标志",
    "L1C": "L1 容器（rootfs / 挂载 / /dev / PTY）",
    "L2D": "L2 DSH 本体（装包 / 启动 / 鉴权）",
    "L3S": "L3 壳（payload / 版本闸门 / 产物同步）",
    "L4U": "L4 前端（浏览器 / 局域网）",
}


def load():
    with open(SPEC, encoding="utf-8") as fh:
        return json.load(fh)


def validate(spec):
    problems = []
    seen = set()
    codes = set()
    for e in spec["errors"]:
        code = e.get("code", "")
        m = CODE_RE.match(code)
        if not m:
            problems.append("code 格式不对: %r" % code)
            continue
        if m.group(1) != e.get("layer"):
            problems.append("%s: code 前缀 %s 与 layer 字段 %r 不一致"
                            % (code, m.group(1), e.get("layer")))
        if code in seen:
            problems.append("code 重复: %s" % code)
        seen.add(code)
        codes.add(code)
        if e.get("layer") not in LAYER_NAME:
            problems.append("%s: layer 不认识 (%r)" % (code, e.get("layer")))
        for k in REQUIRED:
            if not e.get(k):
                problems.append("%s: 缺字段 %s" % (code, k))
    for s in spec.get("signatures", []):
        for c in s.get("when", []):
            if c not in codes:
                problems.append("签名 %s 引用了不存在的 code: %s" % (s.get("id", "?"), c))
        if not s.get("verdict"):
            problems.append("签名 %s 没有 verdict" % s.get("id", "?"))
    for ec in spec.get("exit_codes", []):
        for c in ec.get("codes", []):
            if c not in codes:
                problems.append("退出码 %r 引用了不存在的 code: %s" % (ec.get("exit"), c))
        if not ec.get("codes"):
            problems.append("退出码 %r 没有绑定任何 code" % ec.get("exit"))
    return problems


def render(spec):
    lines = []
    lines.append("# 报错与定位（自动生成，不要手改）")
    lines.append("")
    lines.append("> 真源：[`spec/errors.json`](../spec/errors.json)；生成：`python3 tools/gen-errors.py`。")
    lines.append("> 每条报错都绑定一条**能证明它**的探针命令 —— 先跑探针，再下结论。")
    lines.append("")
    lines.append("## 怎么用")
    lines.append("")
    lines.append("1. 拿到现象（或退出码），在下表里找相同 `code`；")
    lines.append("2. 跑该条的 `探针`，看是否符合 `期望` —— 不符合就说明不是这条；")
    lines.append("3. 若同时命中多条，查下面的[组合签名](#组合签名)，它给的是**一个**结论而不是一堆猜测。")
    lines.append("")
    lines.append("## 退出码 ↔ 错误")
    lines.append("")
    lines.append("| 退出码 | 含义 | 对应 code |")
    lines.append("|---|---|---|")
    for ec in sorted(spec.get("exit_codes", []), key=lambda x: x["exit"]):
        codes = " / ".join("`%s`" % c for c in ec["codes"])
        lines.append("| %d | %s | %s |" % (ec["exit"], ec["label"], codes))
    lines.append("")
    lines.append("")

    by_layer = {}
    for e in spec["errors"]:
        by_layer.setdefault(e["layer"], []).append(e)

    lines.append("## 码表")
    lines.append("")
    for layer in sorted(by_layer):
        lines.append("### %s" % LAYER_NAME.get(layer, layer))
        lines.append("")
        lines.append("| code | 症状 | 状态 |")
        lines.append("|---|---|---|")
        for e in sorted(by_layer[layer], key=lambda x: x["code"]):
            lines.append("| `%s` | %s | %s |" % (e["code"], e["title"], e.get("status", "?")))
        lines.append("")

    lines.append("## 详情")
    lines.append("")
    for e in sorted(spec["errors"], key=lambda x: x["code"]):
        lines.append("### `%s` %s" % (e["code"], e["title"]))
        lines.append("")
        lines.append("- **症状**：%s" % e["symptom"])
        lines.append("- **探针**：`%s`" % e["probe"])
        lines.append("- **期望**：%s" % e["expect"])
        lines.append("- **根因**：%s" % e["root_cause"])
        lines.append("- **处置**：%s" % e["fix"])
        if e.get("traps"):
            lines.append("- **易误判**：%s" % e["traps"])
        if e.get("refs"):
            lines.append("- **相关**：%s" % " · ".join(e["refs"]))
        lines.append("")

    lines.append("## 组合签名")
    lines.append("")
    lines.append("单条证据往往不足以下结论，所以这里把「同源故障」写成签名：命中的 `code` 组合 → **一个**结论，而不是一串猜测。")
    lines.append("")
    lines.append("> `when` 只有 1 条 = 该条本身即可定论；≥2 条 = 组合定位（几条证据指向同一个根因）。")
    lines.append("")
    lines.append("| 签名 | 同时命中 | 结论 | 下一步 |")
    lines.append("|---|---|---|---|")
    for s in spec.get("signatures", []):
        when = " + ".join("`%s`" % c for c in s["when"])
        lines.append("| `%s` | %s | %s | %s |" % (s["id"], when, s["verdict"], s.get("next", "—")))
    lines.append("")
    return "\n".join(lines)


def main(argv):
    spec = load()
    problems = validate(spec)
    if problems:
        for p in problems:
            print("FAIL " + p, file=sys.stderr)
        return 1
    text = render(spec)
    if "--check" in argv:
        if not os.path.exists(OUT):
            print("FAIL 缺少 docs/errors.md（先跑一次 gen-errors.py）", file=sys.stderr)
            return 1
        with open(OUT, encoding="utf-8") as fh:
            if fh.read() != text:
                print("FAIL docs/errors.md 与 spec/errors.json 不一致（重新生成）", file=sys.stderr)
                return 1
        print("一致: docs/errors.md（%d 条错误 / %d 个签名）"
              % (len(spec["errors"]), len(spec.get("signatures", []))))
        return 0
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write(text)
    print("写入 docs/errors.md（%d 条错误 / %d 个签名）"
          % (len(spec["errors"]), len(spec.get("signatures", []))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))