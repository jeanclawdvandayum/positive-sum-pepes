#!/usr/bin/env node
/// curveMath.referee.mjs — byte-accuracy referee for curveMath.mjs.
/// Runs the forge dump harness (test/CurveDumpRolling.t.sol), captures the
/// CSV rows CurveMath itself computed, and asserts the JS engine reproduces
/// every (supply → price, reserve) pair EXACTLY, wei-for-wei.
/// Usage: node frontend/src/lib/curveMath.referee.mjs [--csv path/to/dump.log]
///   --csv skips the forge run and reads a captured log instead.

import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "..", "..");
const m = await import(path.join(here, "curveMath.mjs"));
const sidecar = JSON.parse(readFileSync(path.join(here, "curveConfigs.json"), "utf8"));

let log;
const csvArg = process.argv.indexOf("--csv");
if (csvArg > 0) {
  log = readFileSync(process.argv[csvArg + 1], "utf8");
} else {
  log = execSync(
    "forge test --match-path test/CurveDumpRolling.t.sol -vv",
    { cwd: repo, encoding: "utf8", maxBuffer: 64 * 1024 * 1024, stdio: ["pipe", "pipe", "inherit"] },
  );
}

const rows = { CURVE1: [], CURVE2: [], CURVE3: [], PROTOTYPE: [] };
for (const line of log.split("\n")) {
  if (!line.includes("CSV:")) continue;
  const [, rest] = line.split("CSV:");
  const [tag, payload] = rest.split(":");
  if (!rows[tag]) continue;
  const [s, p, r] = payload.split(",").map((x) => BigInt(x.trim()));
  rows[tag].push({ s, p, r });
}

let total = 0, bad = 0;
for (const tag of ["CURVE1", "CURVE2", "CURVE3", "PROTOTYPE"]) {
  const key = tag === "PROTOTYPE" ? "prototype" : tag.toLowerCase();
  const cfg = sidecar.curves[key];
  const cc = m.makeConfig(BigInt(cfg.p0Wad), cfg.bounds.map(BigInt), cfg.rates.map(BigInt), cfg.exps);
  let n = 0, mism = 0, firstBad = null;
  for (const { s, p, r } of rows[tag]) {
    n++;
    const jp = m.marginalPrice(s, cc);
    const jr = m.curveIntegral(0n, s, cc);
    if (jp !== p || jr !== r) {
      mism++;
      if (!firstBad) firstBad = { s, solP: p, jsP: jp, solR: r, jsR: jr };
    }
  }
  total += n; bad += mism;
  const status = n === 0 ? "NO ROWS (run forge dump)" : mism === 0 ? "BYTE-EXACT" : "MISMATCH";
  console.log(`${tag.padEnd(10)} ${String(n).padStart(4)} rows  ${status}`);
  if (firstBad) console.log("  first diff:", JSON.stringify(firstBad, (k, v) => (typeof v === "bigint" ? v.toString() : v)));
}
if (total === 0) { console.error("no CSV rows captured"); process.exit(1); }
console.log(bad === 0 ? `\nREFEREE PASS: ${total} points byte-identical to Solidity.` : `\nREFEREE FAIL: ${bad}/${total} mismatched`);
process.exit(bad === 0 ? 0 : 1);
