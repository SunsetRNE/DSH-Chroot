#!/usr/bin/env python3
"""版本真源契约测试：台账 -> 第 4 位 / baked 的派生规则。

每条断言都必须能红（变异测试思维）：故意写坏台账、写回已迁走的字段、或让 floor 高于 baked，
生成器必须拒绝；故意让历史回滚或重复，生成器必须告警但放行。
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
GEN = os.path.join(HERE, "gen-version.py")
TEMPLATE = os.path.join(ROOT, "baseline", "manifest.example.json")

MODULE_ENV = """MODULE_ID=Test-Mod
MODULE_NAME=Test Module
AUTHOR=Tester
DESCRIPTION=contract test
UPDATE_JSON=https://example.invalid/update.json
V_MAJOR=1
V_FEATURE=2
V_PATCH=3
VERSION_CODE=9
MANAGED_FEATURES=
"""

DSH_ENV = """DSH_FLOOR=0.2.0-rc.1
DSH_RECOMMENDED=
NODE_FLOOR=24.0.0
"""

FAILS = []
TOTAL = 0


def check(name, cond, detail=""):
    global TOTAL
    TOTAL += 1
    if cond:
        print("ok   " + name)
    else:
        FAILS.append(name)
        print("FAIL " + name + ((" -- " + detail) if detail else ""))


def ledger(*entries):
    return json.dumps({"schema": 1, "bakes": list(entries)}, ensure_ascii=False)


def bake(seq, baked, date="2026-10-17", note="t"):
    return {"seq": seq, "baked": baked, "date": date, "note": note}


class Case:
    def __init__(self, module_env=MODULE_ENV, dsh_env=DSH_ENV, ledger_text=None):
        self.dir = tempfile.mkdtemp(prefix="dsh-versioning-")
        self.env = os.path.join(self.dir, "version.env")
        self.dsh = os.path.join(self.dir, "dsh.env")
        self.led = os.path.join(self.dir, "bake-ledger.json")
        self.out = os.path.join(self.dir, "build")
        self._write(self.env, module_env)
        self._write(self.dsh, dsh_env)
        self._write(self.led, ledger_text or ledger(bake(1, "0.2.0-rc.1")))

    def _write(self, path, text):
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)

    def run(self, check_mode=False):
        cmd = [sys.executable, GEN, "--draft",
               "--env", self.env, "--dsh-env", self.dsh, "--ledger", self.led,
               "--template", TEMPLATE, "--out", self.out,
               "--update-json", os.path.join(self.dir, "no-update.json")]
        if check_mode:
            cmd.append("--check")
        p = subprocess.run(cmd, capture_output=True, text=True)
        return p.returncode, p.stdout, p.stderr

    def read(self, name):
        with open(os.path.join(self.out, name), encoding="utf-8") as fh:
            return fh.read()

    def cleanup(self):
        shutil.rmtree(self.dir, ignore_errors=True)


def main():
    # 1) 基线：第 4 位与 baked 都从台账派生
    c = Case()
    rc, out, err = c.run()
    check("基线：exit 0", rc == 0, "rc=%d err=%s" % (rc, err.strip()[:160]))
    if rc == 0:
        prop = c.read("module.prop")
        manifest = c.read("manifest.json")
        check("基线：第 4 位 = seq", "version=1.2.3.1" in prop, prop)
        check("基线：注释写明台账对应", "烘焙台账 seq 1 = DSH 0.2.0-rc.1" in prop, prop)
        check("基线：manifest.baked 来自台账", '"baked": "0.2.0-rc.1"' in manifest, manifest[:300])
        check("基线：manifest.baked_seq = 1", '"baked_seq": 1' in manifest, manifest[:300])
    c.cleanup()

    # 2) seq 不是硬编码：第 7 次烘焙 -> 1.2.3.7
    versions = ["0.2.0-rc.1", "0.2.0-rc.2", "0.2.1-rc.1", "0.2.1-rc.2",
                "0.2.2-rc.1", "0.3.0-rc.1", "0.3.0-rc.2"]
    c = Case(ledger_text=ledger(*[bake(i, v) for i, v in enumerate(versions, 1)]))
    rc, out, err = c.run()
    prop = c.read("module.prop") if rc == 0 else ""
    manifest = c.read("manifest.json") if rc == 0 else ""
    check("派生：第 7 次烘焙 -> 1.2.3.7", rc == 0 and "version=1.2.3.7" in prop, "rc=%d" % rc)
    check("派生：baked_seq = 7", '"baked_seq": 7' in manifest, manifest[:300])
    check("派生：baked 取最后一条", '"baked": "0.3.0-rc.2"' in manifest, manifest[:300])
    c.cleanup()

    # 3) seq 跳号 -> 拒绝
    c = Case(ledger_text=ledger(bake(1, "0.2.0-rc.1"), bake(3, "0.2.0-rc.2")))
    rc, out, err = c.run()
    check("拒绝：seq 跳号", rc == 2 and "连续" in err, "rc=%d err=%s" % (rc, err.strip()[:120]))
    c.cleanup()

    # 4) seq 从 0 开始 -> 拒绝
    c = Case(ledger_text=ledger(bake(0, "0.2.0-rc.1")))
    rc, out, err = c.run()
    check("拒绝：seq 从 0 开始", rc == 2 and "连续" in err, "rc=%d err=%s" % (rc, err.strip()[:120]))
    c.cleanup()

    # 5) baked 不是合法 semver -> 拒绝
    c = Case(ledger_text=ledger(bake(1, "0.2")))
    rc, out, err = c.run()
    check("拒绝：baked 非法 semver", rc == 2 and "semver" in err, "rc=%d err=%s" % (rc, err.strip()[:120]))
    c.cleanup()

    # 6) floor 高于 baked -> 拒绝
    c = Case(dsh_env="DSH_FLOOR=0.2.0-rc.2\nDSH_RECOMMENDED=\nNODE_FLOOR=24.0.0\n")
    rc, out, err = c.run()
    check("拒绝：floor 高于 baked", rc == 2 and "高于" in err, "rc=%d err=%s" % (rc, err.strip()[:120]))
    c.cleanup()

    # 7) recommended 不严格高于 baked -> 拒绝
    c = Case(dsh_env="DSH_FLOOR=0.2.0-rc.1\nDSH_RECOMMENDED=0.2.0-rc.1\nNODE_FLOOR=24.0.0\n")
    rc, out, err = c.run()
    check("拒绝：recommended 不高于 baked", rc == 2 and "严格高于" in err,
          "rc=%d err=%s" % (rc, err.strip()[:120]))
    c.cleanup()

    # 8) version.env 里残留 V_DSH -> 拒绝（迁移必须彻底，不许静默忽略）
    c = Case(module_env=MODULE_ENV + "V_DSH=1\n")
    rc, out, err = c.run()
    check("拒绝：残留 V_DSH", rc == 2 and "V_DSH" in err, "rc=%d err=%s" % (rc, err.strip()[:120]))
    c.cleanup()

    # 9) version.env 里残留 DSH_BAKED -> 拒绝
    c = Case(module_env=MODULE_ENV + "DSH_BAKED=0.2.0-rc.1\n")
    rc, out, err = c.run()
    check("拒绝：残留 DSH_BAKED", rc == 2 and "DSH_BAKED" in err, "rc=%d err=%s" % (rc, err.strip()[:120]))
    c.cleanup()

    # 10) 回滚：baked 不升序是合法的，但必须告警
    c = Case(ledger_text=ledger(bake(1, "0.2.1-rc.2"), bake(2, "0.2.0-rc.2")))
    rc, out, err = c.run()
    check("回滚：放行 + 告警", rc == 0 and "回滚" in err, "rc=%d err=%s" % (rc, err.strip()[:120]))
    c.cleanup()

    # 11) 重复 baked：放行 + 告警
    c = Case(ledger_text=ledger(bake(1, "0.2.0-rc.1"), bake(2, "0.2.0-rc.1")))
    rc, out, err = c.run()
    check("重复：放行 + 告警", rc == 0 and "重复" in err, "rc=%d err=%s" % (rc, err.strip()[:120]))
    c.cleanup()

    # 12) 台账缺失 -> 拒绝
    c = Case()
    os.remove(c.led)
    rc, out, err = c.run()
    check("拒绝：台账缺失", rc == 2 and "找不到烘焙台账" in err, "rc=%d err=%s" % (rc, err.strip()[:120]))
    c.cleanup()

    # 13) --check：一致 -> 0；手改生成物 -> 1
    c = Case()
    c.run()
    rc, out, err = c.run(check_mode=True)
    check("--check：一致返回 0", rc == 0, "rc=%d err=%s" % (rc, err.strip()[:120]))
    with open(os.path.join(c.out, "module.prop"), "a", encoding="utf-8") as fh:
        fh.write("# tampered\n")
    rc, out, err = c.run(check_mode=True)
    check("--check：漂移返回 1", rc == 1, "rc=%d" % rc)
    c.cleanup()

    print()
    if FAILS:
        print("%d/%d 失败" % (len(FAILS), TOTAL))
        return 1
    print("OK %d/%d" % (TOTAL, TOTAL))
    return 0


if __name__ == "__main__":
    sys.exit(main())
