#!/usr/bin/env node
// lib/semver-gate.mjs —— 版本闸门的 Node 实现（容器内 / 壳里用）
//
// 三份实现（Python / POSIX sh / Node）必须与 spec/gate-vectors.json 逐条一致：
//     python3 tools/check-gate.py
//
// 用法:
//     node lib/semver-gate.mjs compare 0.2.1-rc.1 0.2.0-rc.2   # -> -1 | 0 | 1（非法 -> invalid，退出 2）
//     node lib/semver-gate.mjs check 0.2.0-rc.2                # -> ok | invalid
//     node lib/semver-gate.mjs decide 0.2.2-alpha.5 0.2.0-rc.2 0.2.1-rc.2
//                                                              # -> ok user-upgraded-alpha 1
//     node lib/semver-gate.mjs batch /tmp/vectors.tsv          # 每行一条，输出同样行数
//
// 严格性（与 Python / sh 实现完全一致）: 不做 trim；核心三段不许前导零；必须恰好三段；
// prerelease 纯数字段不许前导零；build 元数据允许前导零且不参与比较。

import fs from "node:fs";

const RE = new RegExp(
  "^(0|[1-9][0-9]*)" +
  "\\.(0|[1-9][0-9]*)" +
  "\\.(0|[1-9][0-9]*)" +
  "(?:-([0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*))?" +
  "(?:\\+([0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*))?$"
);

function parse(v) {
  if (typeof v !== "string") return null;
  const m = RE.exec(v);
  if (m === null) return null;
  const pre = [];
  if (m[4]) {
    for (const part of m[4].split(".")) {
      if (/^[0-9]+$/.test(part)) {
        if (part.length > 1 && part[0] === "0") return null;
        pre.push(Number(part));
      } else {
        pre.push(part);
      }
    }
  }
  return {
    major: Number(m[1]),
    minor: Number(m[2]),
    patch: Number(m[3]),
    pre: pre
  };
}

export function isValid(v) {
  return parse(v) !== null;
}

function cmpNum(a, b) {
  return a < b ? -1 : a > b ? 1 : 0;
}

function cmpStr(a, b) {
  return a < b ? -1 : a > b ? 1 : 0;
}

function cmpPre(a, b) {
  if (a.length === 0 && b.length === 0) return 0;
  if (a.length === 0) return 1;   // 无 prerelease > 有 prerelease
  if (b.length === 0) return -1;
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) {
    const x = a[i];
    const y = b[i];
    const xn = typeof x === "number";
    const yn = typeof y === "number";
    let c;
    if (xn && yn) c = cmpNum(x, y);
    else if (xn) c = -1;          // 数字段 < 字母段
    else if (yn) c = 1;
    else c = cmpStr(x, y);
    if (c !== 0) return c;
  }
  return cmpNum(a.length, b.length);
}

function cmpParsed(pa, pb) {
  let c = cmpNum(pa.major, pb.major);
  if (c === 0) c = cmpNum(pa.minor, pb.minor);
  if (c === 0) c = cmpNum(pa.patch, pb.patch);
  if (c !== 0) return c;
  return cmpPre(pa.pre, pb.pre);
}

export function compare(a, b) {
  const pa = parse(a);
  const pb = parse(b);
  if (pa === null) throw new Error("非法 semver: " + JSON.stringify(a));
  if (pb === null) throw new Error("非法 semver: " + JSON.stringify(b));
  return cmpParsed(pa, pb);
}

// 策略层（ADR-026）：返回 [verdict, reason, safe_mode]
// 纯判定：不读盘、不改指针 —— 处置由壳负责
export function decide(installed, floor, baked) {
  const pi = parse(installed);
  if (pi === null) return ["deny", "invalid-installed", 0];
  const pf = parse(floor);
  const pb = parse(baked);
  if (pf === null || pb === null) return ["deny", "invalid-manifest", 0];
  if (cmpParsed(pf, pb) > 0) return ["deny", "invalid-manifest", 0];
  if (cmpParsed(pi, pf) < 0) return ["deny", "below-floor", 0];
  const c = cmpParsed(pi, pb);
  if (c < 0) return ["ok", "older-than-baked", 0];
  if (c === 0) return ["ok", "baked", 0];
  const first = pi.pre.length ? pi.pre[0] : null;
  if (first === "alpha") return ["ok", "user-upgraded-alpha", 1];
  if (first === null || first === "rc") return ["ok", "user-upgraded", 0];
  return ["ok", "user-upgraded-prerelease", 1];
}

function evaluate(kind, args) {
  try {
    if (kind === "compare") {
      if (args.length !== 2) return "error";
      try {
        return String(compare(args[0], args[1]));
      } catch (e) {
        return "invalid";
      }
    }
    if (kind === "check") {
      if (args.length !== 1) return "error";
      return isValid(args[0]) ? "ok" : "invalid";
    }
    if (kind === "decide") {
      if (args.length !== 3) return "error";
      return decide(args[0], args[1], args[2]).join(" ");
    }
    return "error";
  } catch (e) {
    return "error";
  }
}

function batch(path) {
  const text = fs.readFileSync(path, "utf8");
  const lines = text.split("\n");
  let out = [];
  for (const line of lines) {
    if (line === "") continue;
    const parts = line.split("\t");
    out.push(evaluate(parts[0], parts.slice(1)));
  }
  if (out.length) process.stdout.write(out.join("\n") + "\n");
}

function main(argv) {
  const verb = argv[0];
  if (verb === "compare") {
    const r = evaluate("compare", [argv[1], argv[2]]);
    if (r === "invalid" || r === "error") {
      console.log("invalid");
      return 2;
    }
    console.log(r);
    return 0;
  }
  if (verb === "check") {
    const r = evaluate("check", [argv[1]]);
    console.log(r === "ok" ? "ok" : "invalid");
    return r === "ok" ? 0 : 1;
  }
  if (verb === "decide") {
    if (argv.length < 4) {
      process.stderr.write("用法: node lib/semver-gate.mjs decide INSTALLED FLOOR BAKED\n");
      return 2;
    }
    console.log(decide(argv[1], argv[2], argv[3]).join(" "));
    return 0;
  }
  if (verb === "batch") {
    batch(argv[1]);
    return 0;
  }
  process.stderr.write("用法: node lib/semver-gate.mjs compare A B | check V | decide I F B | batch FILE\n");
  return 2;
}

const isEntry = process.argv[1] && process.argv[1].endsWith("semver-gate.mjs");
if (isEntry) {
  process.exit(main(process.argv.slice(2)));
}
