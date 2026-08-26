#!/usr/bin/env python3
"""make_defaults.py — embed the CURRENT repo art state into the Trait Studio.

Reads (read-only):
  script/traits/{expressions,eyes,hats,eyewear,items}.txt
  studio/spec/psp_state.json            (base_grid, palettes, letters)

Uses studio/compiler.js (Agent A's UMD port, executed in node) to parse the
trait files and expand every trait to a full 69x69 slot grid — the exact same
code path the app and the .sol compiler use, so the embedded defaults can
never drift from the compiler's data model.

Writes:
  studio/src/defaults.js   ->  window.PSP_DEFAULTS = { baseGrid, palettes,
                               axes: { <axis>: [{name, grid}...] in DNA order } }

Also PROVES itself: it compiles the embedded state with compiler.js and
asserts the sha256 equals the repo's golden PepeArtData.sol (the same
constant the app's on-load self-test checks in the browser).

Run from the repo root:   python3 studio/tools/make_defaults.py
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))          # studio/tools
STUDIO = os.path.dirname(HERE)                              # studio
REPO = os.path.dirname(STUDIO)                              # repo root

GOLDEN_SHA = "73fff0a5d6c0b59cd29cd396eedc6ac09ba679858a844049bfa2a30facc8d364"

TRAIT_FILES = [
    ("head", "head.txt"),
    ("expressions", "expressions.txt"),
    ("eyes", "eyes.txt"),
    ("hats", "hats.txt"),
    ("eyewear", "eyewear.txt"),
    ("items", "items.txt"),
]

# Executed by node with cwd = repo root (ESM so the dynamic import of the
# UMD compiler.js resolves the same way studio/test_compiler.mjs loads it).
NODE_SCRIPT = r"""
import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

await import('./studio/compiler.js');
const PSP = globalThis.PSPCompiler;
if (!PSP) { console.error('node stage failed: PSPCompiler did not load'); process.exit(1); }

const stateJson = JSON.parse(readFileSync('studio/spec/psp_state.json', 'utf8'));
const files = JSON.parse(process.argv[1]);
const axes = {};
for (const [axis, file] of files) {
  const text = readFileSync('script/traits/' + file, 'utf8');
  const parsed = PSP.parseTraitText(text, 'script/traits/' + file);
  if (parsed.axis !== axis) {
    console.error('axis mismatch for ' + file + ': ' + parsed.axis);
    process.exit(1);
  }
  axes[axis] = parsed.traits.map((t) => ({ name: t.name, grid: PSP.traitToGrid(t) }));
}
// the head IS the base sprite — head.txt's BASE block feeds SPRITE_BASE
if (!axes.head || axes.head.length !== 1) {
  console.error('head.txt must contain exactly one block (BASE)');
  process.exit(1);
}
const state = { baseGrid: axes.head[0].grid, axes, palettes: stateJson.palettes };
const sol = PSP.compileSolidity(state);
const sha = createHash('sha256').update(sol, 'utf8').digest('hex');
writeFileSync(process.argv[2], JSON.stringify(state));
const counts = {};
for (const [axis] of files) counts[axis] = axes[axis].length;
console.log(JSON.stringify({ sha, counts, bytes: sol.length }));
"""


def main() -> int:
    os.chdir(REPO)  # all paths + node imports are repo-root relative

    fd, tmp = tempfile.mkstemp(prefix="psp_defaults_", suffix=".json")
    os.close(fd)
    try:
        proc = subprocess.run(
            ["node", "--input-type=module", "-e", NODE_SCRIPT,
             json.dumps(TRAIT_FILES), tmp],
            capture_output=True, text=True,
        )
        if proc.returncode != 0:
            sys.stderr.write(proc.stdout + proc.stderr)
            print("FAIL  node stage failed")
            return 1
        summary = json.loads(proc.stdout.strip().splitlines()[-1])
        with open(tmp, "r", encoding="utf-8") as fh:
            state = json.load(fh)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass

    if summary["sha"] != GOLDEN_SHA:
        print("FAIL  embedded state does not compile to the golden .sol")
        print("      sha256 " + summary["sha"])
        print("      want   " + GOLDEN_SHA)
        return 1

    ok = True
    def check(label, cond):
        nonlocal ok
        print(("PASS  " if cond else "FAIL  ") + label)
        if not cond:
            ok = False

    check("compiled embedded defaults === golden PepeArtData.sol "
          "(sha256 " + summary["sha"][:16] + "…, " + str(summary["bytes"]) + " B)",
          True)
    for axis, _ in TRAIT_FILES:
        n = summary["counts"][axis]
        expect = 1 if axis == "head" else None
        if expect is not None:
            check("axis head: exactly one BASE block", n == 1)
        check("axis %s: %d traits -> grids are 69x69" % (axis, n),
              n > 0 and all(
                  len(t["grid"]) == 69 and all(len(r) == 69 for r in t["grid"])
                  for t in state["axes"][axis]))
    rows = len(state["baseGrid"])
    check("baseGrid is 69x69", rows == 69 and all(len(r) == 69 for r in state["baseGrid"]))
    check("palettes carried over (skins/fixed/irises/backgrounds)",
          all(k in state["palettes"] for k in ("skins", "fixed", "irises", "backgrounds")))

    if not ok:
        return 1

    out = os.path.join(STUDIO, "src", "defaults.js")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    body = json.dumps(state, separators=(",", ":"))
    with open(out, "w", encoding="utf-8") as fh:
        fh.write("// GENERATED by studio/tools/make_defaults.py — DO NOT EDIT BY HAND.\n")
        fh.write("// Snapshot of script/traits/*.txt + studio/spec/psp_state.json.\n")
        fh.write("// Proven at generation time: compileSolidity(this) === golden\n")
        fh.write("// PepeArtData.sol (sha256 %s).\n" % GOLDEN_SHA)
        fh.write("// Regenerate: python3 studio/tools/make_defaults.py (repo root)\n")
        fh.write("window.PSP_DEFAULTS = %s;\n" % body)
    size = os.path.getsize(out)
    print("WROTE %s (%d bytes)" % (os.path.relpath(out, REPO), size))
    print("OK    make_defaults complete")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
