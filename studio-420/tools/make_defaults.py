#!/usr/bin/env python3
"""make_defaults.py — embed the 420-edition art into the 420 Trait Studio.

Reads (read-only):
  studio-420/art/{head,expressions,eyes,hats,eyewear,items}.txt
  studio-420/art/palettes.json           (skins / fixed / irises / backgrounds)
  studio/expanded/*.txt + studio/src/defaults.js palettes
                                         (the ORIGINAL release-2 collection,
                                          only for the collection inspector's
                                          original-vs-420 comparison)

Uses studio-420/compiler.js (byte-identical copy of studio/compiler.js) to
parse the trait files and expand every trait to a full 69x69 slot grid — the
same code path the app uses.

Writes:
  studio-420/src/defaults.js    window.PSP_DEFAULTS  = { baseGrid, palettes, axes }
  studio-420/src/original.js    window.PSP_ORIGINAL  = same shape, original art
  studio-420/art/PepeArtData.sol  compiled 420 export
  studio-420/art/GOLDEN_SHA256    sha256 of that export
  studio-420/src/app-core.js    PSP.GOLDEN_SHA pinned to the 420 sha

The 420 golden is its OWN sha (never the original studio's). After pinning,
the script re-compiles the written defaults.js and asserts the sha equals
the pin, so the in-browser self-test can only pass on this exact art.

Run from anywhere:   python3 studio-420/tools/make_defaults.py
"""
import json
import os
import re
import subprocess
import sys
import tempfile

# In-place renames (same DNA slot, new art). Everything else new is appended.
RENAMES = {"items": {"CIGARETTE": "JOINT", "CIGAR": "BLUNT"}}
# Fixed palette slots recolored for 420. Slot 22 (cream) is used by no
# release-2 trait, so recoloring it to leaf green changes no existing pixel.
RECOLORED_FIXED = {22}
HERE = os.path.dirname(os.path.abspath(__file__))          # studio-420/tools
STUDIO = os.path.dirname(HERE)                              # studio-420
REPO = os.path.dirname(STUDIO)                              # repo root
ORIGINAL_GOLDEN = "73fff0a5d6c0b59cd29cd396eedc6ac09ba679858a844049bfa2a30facc8d364"

AXES = ["head", "expressions", "eyes", "hats", "eyewear", "items"]
MAX_PER_AXIS = 16  # 4-bit DNA fields; stamp axes count the implicit NONE

# node stage, cwd = repo root. argv: <outState420> <outOriginal>
NODE_SCRIPT = r"""
import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

await import('./studio-420/compiler.js');
const PSP = globalThis.PSPCompiler;
if (!PSP) { console.error('PSPCompiler did not load'); process.exit(1); }
const AXES = ['head', 'expressions', 'eyes', 'hats', 'eyewear', 'items'];

function load(dir, palettes) {
  const axes = {};
  for (const axis of AXES) {
    const file = dir + '/' + axis + '.txt';
    const parsed = PSP.parseTraitText(readFileSync(file, 'utf8'), file);
    if (parsed.axis !== axis) { console.error('axis mismatch ' + file + ': ' + parsed.axis); process.exit(1); }
    axes[axis] = parsed.traits.map((t) => ({ name: t.name, grid: PSP.traitToGrid(t) }));
  }
  if (axes.head.length !== 1) { console.error(dir + '/head.txt must hold exactly one block'); process.exit(1); }
  return { baseGrid: axes.head[0].grid, axes, palettes };
}
const sha = (s) => createHash('sha256').update(s, 'utf8').digest('hex');

const s420 = load('studio-420/art', JSON.parse(readFileSync('studio-420/art/palettes.json', 'utf8')));
const origPal = JSON.parse(readFileSync('studio/src/defaults.js', 'utf8').match(/window.PSP_DEFAULTS = (.*);/s)[1]).palettes;
const orig = load('studio/expanded', origPal);

const sol = PSP.compileSolidity(s420);
const origSol = PSP.compileSolidity(orig);
writeFileSync(process.argv[1], JSON.stringify(s420));
writeFileSync(process.argv[2], JSON.stringify(orig));
writeFileSync('studio-420/art/PepeArtData.sol', sol);
const counts = {};
for (const a of AXES) counts[a] = s420.axes[a].length;
const names = {};
for (const a of AXES) names[a] = s420.axes[a].map((t) => t.name);
const origNames = {};
for (const a of AXES) origNames[a] = orig.axes[a].map((t) => t.name);
const pal = {};
for (const k of ['skins', 'irises', 'backgrounds']) pal[k] = s420.palettes[k].length;
console.log(JSON.stringify({ sha: sha(sol), bytes: sol.length, counts, names, origNames, pal,
  origSha: sha(origSol), origExportMatches: origSol === readFileSync('studio/expanded/PepeArtData.sol', 'utf8') }));
"""

# re-verification stage: compile exactly what defaults.js holds (what the browser self-test does)
VERIFY_SCRIPT = r"""
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
await import('./studio-420/compiler.js');
const d = JSON.parse(readFileSync('studio-420/src/defaults.js', 'utf8').match(/window.PSP_DEFAULTS = (.*);/s)[1]);
const pin = readFileSync('studio-420/src/app-core.js', 'utf8').match(/PSP\.GOLDEN_SHA =\s*'([0-9a-f]{64})'/)[1];
const sha = createHash('sha256').update(globalThis.PSPCompiler.compileSolidity(d), 'utf8').digest('hex');
console.log(JSON.stringify({ sha, pin }));
"""


def node(script, *args):
    proc = subprocess.run(["node", "--input-type=module", "-e", script, *args],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout + proc.stderr)
        raise SystemExit("FAIL  node stage failed")
    return json.loads(proc.stdout.strip().splitlines()[-1])


def main() -> int:
    os.chdir(REPO)  # node imports + paths are repo-root relative

    tmps = []
    for _ in range(2):
        fd, p = tempfile.mkstemp(prefix="psp420_", suffix=".json")
        os.close(fd)
        tmps.append(p)
    try:
        summary = node(NODE_SCRIPT, *tmps)
        with open(tmps[0], encoding="utf-8") as fh:
            state = json.load(fh)
        with open(tmps[1], encoding="utf-8") as fh:
            original = json.load(fh)
    finally:
        for p in tmps:
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass

    sha = summary["sha"]
    ok = True

    def check(label, cond):
        nonlocal ok
        print(("PASS  " if cond else "FAIL  ") + label)
        if not cond:
            ok = False

    check("original release-2 art recompiles to studio/expanded/PepeArtData.sol",
          summary["origExportMatches"])
    check("420 sha differs from the original goldens (release 1 + release 2 expanded)",
          sha not in (ORIGINAL_GOLDEN, summary["origSha"]))
    for axis in AXES:
        n = summary["counts"][axis]
        dna = n + 1 if axis in ("hats", "eyewear", "items") else n
        grids_ok = all(len(t["grid"]) == 69 and all(len(r) == 69 for r in t["grid"])
                       for t in state["axes"][axis])
        if axis == "head":
            check("head: exactly one BASE block, 69x69", n == 1 and grids_ok)
            continue
        check("%s: %d DNA ids (<= %d), grids 69x69" % (axis, dna, MAX_PER_AXIS),
              dna <= MAX_PER_AXIS and grids_ok)
        orig = summary["origNames"][axis]
        cur = summary["names"][axis]
        ren = RENAMES.get(axis, {})
        expect = [ren.get(n, n) for n in orig]
        check("%s: DNA order stable (%d original slots in place%s, %d appended)" % (
                  axis, len(orig), (", renamed " + ", ".join("%s->%s" % kv for kv in ren.items())) if ren else "",
                  len(cur) - len(orig)),
              cur[:len(orig)] == expect)
    for k, n in summary["pal"].items():
        check("palette %s: %d entries (<= %d)" % (k, n, MAX_PER_AXIS), n <= MAX_PER_AXIS)
        old = original["palettes"][k]
        check("palette %s: original %d entries unchanged (append-only)" % (k, len(old)),
              state["palettes"][k][:len(old)] == old)
    fixed_changed = sorted(int(s) for s, c in state["palettes"]["fixed"].items()
                           if original["palettes"]["fixed"].get(s) != c)
    check("fixed slots: only %s recolored (got %s)" % (sorted(RECOLORED_FIXED), fixed_changed),
          fixed_changed == sorted(RECOLORED_FIXED))
    for slot in sorted(RECOLORED_FIXED):
        users = ["%s/%s" % (a, t["name"]) for a in AXES for t in original["axes"][a]
                 if any(slot in row for row in t["grid"])]
        check("recolored slot %d is unused by every original trait (users: %s)" % (slot, users or "none"),
              not users)
    if not ok:
        return 1

    header = ("// GENERATED by studio-420/tools/make_defaults.py — DO NOT EDIT BY HAND.\n"
              "// Snapshot of studio-420/art/*.txt + studio-420/art/palettes.json.\n"
              "// 420 golden: compileSolidity(this) sha256 %s\n"
              "// Regenerate: python3 studio-420/tools/make_defaults.py\n" % sha)
    with open(os.path.join(STUDIO, "src", "defaults.js"), "w", encoding="utf-8") as fh:
        fh.write(header)
        fh.write("window.PSP_DEFAULTS = %s;\n" % json.dumps(state, separators=(",", ":")))
    with open(os.path.join(STUDIO, "src", "original.js"), "w", encoding="utf-8") as fh:
        fh.write("// GENERATED by studio-420/tools/make_defaults.py — DO NOT EDIT BY HAND.\n"
                 "// The ORIGINAL release-2 collection (studio/expanded/*.txt, read-only),\n"
                 "// used only by collection.html for original-vs-420 comparisons.\n")
        fh.write("window.PSP_ORIGINAL = %s;\n" % json.dumps(original, separators=(",", ":")))
    with open(os.path.join(STUDIO, "art", "GOLDEN_SHA256"), "w", encoding="utf-8") as fh:
        fh.write(sha + "\n")

    core = os.path.join(STUDIO, "src", "app-core.js")
    with open(core, encoding="utf-8") as fh:
        text = fh.read()
    text, n = re.subn(r"(PSP\.GOLDEN_SHA =\s*')[0-9a-f]{64}(')", r"\g<1>%s\g<2>" % sha, text)
    if n != 1:
        print("FAIL  could not find the PSP.GOLDEN_SHA pin in src/app-core.js")
        return 1
    with open(core, "w", encoding="utf-8") as fh:
        fh.write(text)

    v = node(VERIFY_SCRIPT)
    check("written defaults.js compiles to the pinned 420 golden (sha256 %s)" % sha,
          v["sha"] == sha == v["pin"])
    if not ok:
        return 1
    for axis in AXES[1:]:
        print("      %-11s %s" % (axis, " ".join(summary["names"][axis])))
    print("OK    420 golden %s (%d B export)" % (sha, summary["bytes"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
