#!/usr/bin/env node
/**
 * test_compiler.mjs — proves studio/compiler.js is a byte-identical port of
 * script/gen_pepe_art.py's emit path, plus grid/text round-trip invariants.
 *
 *  1. compileSolidity(repo traits + psp_state.json) === golden .sol (===),
 *     printing both sha256 sums.
 *  2. For every repo trait: traitToGrid -> gridToTrait -> traitToGrid
 *     deep-equals the original grid.
 *  3. For all 5 trait files: traitText(parse(file)) re-parses to the same
 *     traits (names, order, y/dx/dy, rows) — and re-serializes the file
 *     byte-for-byte.
 *
 * Exit code 0 iff every check passes.
 */
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';

process.chdir(resolve(dirname(fileURLToPath(import.meta.url)), '..'));

// compiler.js is a UMD; this repo's package.json is type:module, so under
// node here it attaches globalThis.PSPCompiler (in a CJS scope it would be
// module.exports instead — both paths live in the UMD wrapper).
await import('./compiler.js');
const PSP = globalThis.PSPCompiler;
if (!PSP) {
  console.error('FAIL  PSPCompiler failed to load');
  process.exit(1);
}

const EXPECTED_GOLD_SHA =
  '73fff0a5d6c0b59cd29cd396eedc6ac09ba679858a844049bfa2a30facc8d364';

const TRAIT_FILES = [
  ['head', 'head.txt'],
  ['expressions', 'expressions.txt'],
  ['eyes', 'eyes.txt'],
  ['hats', 'hats.txt'],
  ['eyewear', 'eyewear.txt'],
  ['items', 'items.txt'],
];

let failures = 0;
function check(label, ok, detail) {
  console.log((ok ? 'PASS' : 'FAIL') + '  ' + label + (!ok && detail ? '  [' + detail + ']' : ''));
  if (!ok) failures++;
}

function eq(a, b) {
  if (a === b) return true;
  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) if (!eq(a[i], b[i])) return false;
    return true;
  }
  return false;
}

function sha256(s) {
  return createHash('sha256').update(s, 'utf8').digest('hex');
}

function firstDiff(a, b) {
  if (a === b) return '';
  const n = Math.min(a.length, b.length);
  let i = 0;
  while (i < n && a.charCodeAt(i) === b.charCodeAt(i)) i++;
  const line = a.slice(0, i).split('\n').length;
  return 'first divergence at offset ' + i + ' (line ' + line +
    '): got ' + JSON.stringify(a.slice(i, i + 40)) +
    ', want ' + JSON.stringify(b.slice(i, i + 40)) +
    (a.length === b.length ? '' : ' (length ' + a.length + ' vs ' + b.length + ')');
}

// ── parse the 5 repo trait files ──────────────────────────────────────
const texts = {};
const parsed = {};
for (const [axis, file] of TRAIT_FILES) {
  const text = readFileSync(join('script', 'traits', file), 'utf8');
  const p = PSP.parseTraitText(text, 'script/traits/' + file);
  check('parse ' + file + ' -> axis=' + axis + ' (' + p.traits.length + ' traits)',
    p.axis === axis && p.traits.length > 0, 'got axis ' + p.axis);
  texts[axis] = text;
  parsed[axis] = p;
}

// ── check 1: compile vs golden (byte-identical) ───────────────────────
const stateJson = JSON.parse(readFileSync(join('studio', 'spec', 'psp_state.json'), 'utf8'));
const state = {
  // the head IS the base sprite: head.txt's BASE block feeds SPRITE_BASE
  baseGrid: (parsed.head && parsed.head.traits[0])
    ? PSP.traitToGrid(parsed.head.traits[0])
    : stateJson.base_grid,
  axes: Object.fromEntries(TRAIT_FILES.map(([axis]) => [
    axis,
    parsed[axis].traits.map((t) => ({ name: t.name, grid: PSP.traitToGrid(t) })),
  ])),
  palettes: stateJson.palettes,
};
check('head.txt parses to exactly one BASE block',
  parsed.head && parsed.head.traits.length === 1 &&
  parsed.head.traits[0].name === 'BASE',
  parsed.head ? parsed.head.traits.map((t) => t.name).join(',') : 'none');

const golden = readFileSync(join('studio', 'spec', 'golden', 'PepeArtData.sol'), 'utf8');
const goldSha = sha256(golden);
const out = PSP.compileSolidity(state);
const outSha = sha256(out);

console.log('compile sha256: ' + outSha);
console.log('golden sha256: ' + goldSha + '  (spec pins ' + EXPECTED_GOLD_SHA + ')');
check('golden file matches spec-pinned sha256', goldSha === EXPECTED_GOLD_SHA, goldSha);
check('1. compileSolidity(repo state) === golden PepeArtData.sol', out === golden,
  out === golden ? '' : firstDiff(out, golden));
check('1b. compile sha256 === golden sha256', outSha === goldSha, outSha + ' != ' + goldSha);

if (out !== golden) {
  // keep the divergent output for offline diffing (temp artifact, not a deliverable)
  const { writeFileSync } = await import('node:fs');
  writeFileSync('/tmp/PSPCompiler_out.sol', out);
  console.log('      (divergent output saved to /tmp/PSPCompiler_out.sol — diff it:)');
}

// ── check 2: grid round-trip for every repo trait ─────────────────────
{
  let n = 0, bad = 0;
  for (const [axis] of TRAIT_FILES) {
    for (const t of parsed[axis].traits) {
      n++;
      const g1 = PSP.traitToGrid(t);
      const t2 = PSP.gridToTrait(axis, t.name, g1);
      const g2 = PSP.traitToGrid(t2);
      if (!eq(g2, g1)) {
        bad++;
        console.log('      grid round-trip FAILED for ' + axis + '/' + t.name);
      }
    }
  }
  check('2. gridToTrait ∘ traitToGrid round-trips all ' + n + ' repo trait grids', bad === 0,
    bad + ' failures');
}

// ── check 3: traitText re-parse round-trip for all 5 files ────────────
{
  let nameOk = 0, byteOk = 0;
  for (const [axis, file] of TRAIT_FILES) {
    const t1 = parsed[axis].traits;
    const text2 = PSP.traitText(axis, t1);
    const p2 = PSP.parseTraitText(text2, '<traitText(' + axis + ')>');

    let ok = p2.axis === axis && p2.traits.length === t1.length;
    if (ok) {
      for (let i = 0; i < t1.length; i++) {
        const a = t1[i], b = p2.traits[i];
        if (a.name !== b.name || a.y !== b.y || a.dx !== b.dx || a.dy !== b.dy ||
            !eq(a.rows, b.rows)) {
          ok = false;
          console.log('      re-parse mismatch ' + axis + '/' + a.name +
            ': y ' + a.y + '/' + b.y + ' dx ' + a.dx + '/' + b.dx +
            ' dy ' + a.dy + '/' + b.dy);
          break;
        }
      }
    }
    if (ok) nameOk++;
    if (text2 === texts[axis]) byteOk++;
    else console.log('      traitText(' + axis + ') not byte-identical to ' + file +
      ': ' + firstDiff(text2, texts[axis]));
  }
  check('3. traitText re-parse round-trip (names, order, y/dx/dy, rows)',
    nameOk === TRAIT_FILES.length, nameOk + '/' + TRAIT_FILES.length);
  check('3b. traitText(parse(file)) === file bytes', byteOk === TRAIT_FILES.length, byteOk + '/' + TRAIT_FILES.length);
}

// ── summary ───────────────────────────────────────────────────────────
console.log('');
if (failures) {
  console.error(failures + ' check(s) FAILED');
  process.exit(1);
}
console.log('ALL CHECKS PASSED');
process.exit(0);
