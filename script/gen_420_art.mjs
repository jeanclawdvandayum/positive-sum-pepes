// Reproducible 420 art release (release 3). The 420 Studio sources stay frozen
// under studio-420/; this script only reads them, exactly like gen_expanded_art
// reads studio/. The 420 edition keeps the release-2 head and DNA order (two
// in-place item renames: CIGARETTE->JOINT, CIGAR->BLUNT), redraws the eyes,
// appends new traits and grows the palettes (skin Purp, iris Redeye, bgs
// Haze/PurpleHaze/Kush, fixed slot 22 recolored to leaf green).
import { readFileSync, writeFileSync } from 'node:fs'
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { fileURLToPath } from 'node:url'
process.chdir(fileURLToPath(new URL('..', import.meta.url)))
await import('../studio-420/compiler.js')
const compiler = globalThis.PSPCompiler
const read = p => readFileSync(p, 'utf8')
const old = JSON.parse(read('frontend/src/lib/pepeArtExpanded.json'))
const exported = read('studio-420/art/PepeArtData.sol')
assert.equal(createHash('sha256').update(exported).digest('hex'), read('studio-420/art/GOLDEN_SHA256').trim(), 'studio-420 export drifted from its pinned golden')
const axes = ['expressions', 'eyes', 'hats', 'eyewear', 'items']
const parsed = Object.fromEntries(['head', ...axes].map(axis => [axis, compiler.parseTraitText(read(`studio-420/art/${axis}.txt`)).traits]))
assert.equal(parsed.head.length, 1, 'head.txt must hold exactly one block')
const palettes = JSON.parse(read('studio-420/art/palettes.json'))
const state = { baseGrid: compiler.traitToGrid(parsed.head[0]), axes: Object.fromEntries(axes.map(axis => [axis, parsed[axis].map(t => ({ name: t.name, grid: compiler.traitToGrid(t) }))])), palettes }
assert.equal(compiler.compileSolidity(state), exported, '420 Studio export differs from text grids / current palettes')
const constants = Object.fromEntries([...exported.matchAll(/bytes internal constant (\w+) = hex"([\da-fA-F]*)";/g)].map(m => [m[1], m[2]]))
const art = {...old, counts: {...old.counts}, base: constants.SPRITE_BASE }
const parts = [art.base]
const starts = {}
const names = []
const legacyNames = Buffer.from(read('src/PepeDescriptor.sol').match(/NAMES = hex"([\da-fA-F]+)"/)[1], 'hex').toString().split('\0').slice(0,-1)
// Human-readable metadata names for every slot added after release 1 (ids >= 10
// per axis) plus the two in-place 420 renames, which must not keep legacy names.
const newNames = {
  AMAZING: 'Amazing', RAGE: 'Rage', SUS: 'Sus', FUCKMYSHITUP: 'Fuck My Shit Up', READINGGLASSES: 'Reading Glasses', UNIBROW: 'Unibrow', KNIFE: 'Knife',
  MUNCHIES: 'Munchies', COTTONMOUTH: 'Cottonmouth', RASTA: 'Rasta Tam', BUCKET: 'Bucket Hat',
  JOINT: 'Joint', BLUNT: 'Blunt', VAPE: 'Weed Vape', LEAFCHAIN: 'Leaf Chain', SMOKERINGS: 'Smoke Rings',
  Purp: 'Purp', Redeye: 'Redeye', Haze: 'Haze', PurpleHaze: 'Purple Haze', Kush: 'Kush',
}
const renames = { CIGARETTE: 'JOINT', CIGAR: 'BLUNT' }
const prevLabels = axis => [...(axes.indexOf(axis) >= 2 ? ['NONE'] : []), ...compiler.parseTraitText(read(`studio/expanded/${axis}.txt`)).traits.map(t => t.name).filter(n => n !== 'NONE')]
for (const [i, axis] of axes.entries()) {
  const key = ['expr','eye','hat','wear','item'][i]
  const labels = [...(i >= 2 ? ['NONE'] : []), ...parsed[axis].map(t => t.name).filter(n => n !== 'NONE')]
  assert(labels.length <= 16)
  // DNA order: every release-2 slot stays in place (renames keep their slot),
  // 420 traits are appended after them.
  const prev = prevLabels(axis)
  assert.deepEqual(labels.slice(0, prev.length), prev.map(n => renames[n] ?? n), `${axis}: release-2 DNA order changed`)
  const values = labels.map(n => n === 'NONE' ? '' : constants[`${key.toUpperCase()}_${n}`])
  assert(values.every(v => v !== undefined))
  art[key] = values; art.counts[key] = values.length
  starts[key.toUpperCase()] = parts.length
  parts.push(...values)
  starts[`${key.toUpperCase()}_NAME`] = names.length
  // A renamed slot (JOINT, BLUNT) must take its new name, not the legacy one.
  names.push(...labels.map((n, j) => j < 10 && n === prev[j] ? legacyNames[i*10+j] : newNames[n]))
}
for (const [i,key] of ['skin','iris','bg'].entries()) {
  const list = palettes[{skin:'skins',iris:'irises',bg:'backgrounds'}[key]]
  starts[`${key.toUpperCase()}_NAME`] = names.length
  names.push(...list.map((p, j) => j < 10 ? legacyNames[50+i*10+j] : newNames[p.name]))
  art.counts[key] = list.length
  assert(list.length <= 16)
}
for (const [key,c] of Object.entries({skins:'SKIN_RAMPS',fixed:'FIXED_SLOTS',irises:'IRIS_COLORS',bgs:'BG_COLORS'})) {
  art[key] = constants[c]
}
// Palettes only grew (append-only), except fixed slot 22 recolored to leaf
// green — no release-2 trait uses it, so no existing pixel changes color.
assert.equal(constants.SKIN_RAMPS.slice(0, old.skins.length), old.skins, 'release-2 skin ramps changed')
assert.equal(constants.IRIS_COLORS.slice(0, old.irises.length), old.irises, 'release-2 irises changed')
assert.equal(constants.BG_COLORS.slice(0, old.bgs.length), old.bgs, 'release-2 backgrounds changed')
assert.deepEqual(art.skinSlots, old.skinSlots, 'skin slot layout changed')
assert.deepEqual(art.fixedSlots, old.fixedSlots, 'fixed slot layout changed')
assert.deepEqual(art.fixedSlots.filter((slot, i) => constants.FIXED_SLOTS.slice(i*6, i*6+6) !== old.fixed.slice(i*6, i*6+6)), [22], 'only fixed slot 22 may be recolored')
assert.equal(art.base, old.base, 'Existing head pixels changed')
assert(names.every(n => typeof n === 'string' && /^[a-zA-Z0-9 ]+$/.test(n)), 'Metadata names must be JSON safe')
starts.NAME = parts.length
parts.push(...names.map(n => Buffer.from(n).toString('hex')))
const offsets = [0]
for (const p of parts) offsets.push(offsets.at(-1)+p.length/2)
assert(offsets.at(-1)+1 <= 24576, 'Art storage exceeds EIP-170')
const countNames = {expr:'EXPR',eye:'EYE',hat:'HAT',wear:'WEAR',item:'ITEM',skin:'SKIN',iris:'IRIS',bg:'BG'}
const palette = exported.slice(exported.indexOf('    /// @dev skin + iris'))
const sol = `// SPDX-License-Identifier: MIT\npragma solidity 0.8.26;\n\n/// @title PepeArt420\n/// @notice GENERATED by node script/gen_420_art.mjs. Release 3 (420 edition), immutable pixel data.\nlibrary PepeArt420 {\n    uint8 internal constant SIZE = 69;\n${Object.entries(art.counts).map(([k,v])=>`    uint8 internal constant ${countNames[k]}_COUNT = ${v};`).join('\n')}\n${Object.entries(starts).map(([k,v])=>`    uint256 internal constant ${k}_START = ${v};`).join('\n')}\n    bytes internal constant DATA = hex"${parts.join('')}";\n    bytes internal constant OFFSETS = hex"${offsets.map(n=>n.toString(16).padStart(4,'0')).join('')}";\n${['SKIN_RAMPS','FIXED_SLOTS','IRIS_COLORS','BG_COLORS'].map(k=>`    bytes internal constant ${k} = hex"${constants[k]}";`).join('\n')}\n${palette}`
const outputs = {'src/art/PepeArt420.sol':sol, 'frontend/src/lib/pepeArt420.json':JSON.stringify(art)+'\n'}
for (const [p, data] of Object.entries(outputs)) {
  if (process.argv.includes('--check')) assert.equal(read(p),data,`Regenerate ${p}`)
  else writeFileSync(p,data)
}
console.log(`420 art: ${Object.values(art.counts).reduce((a,b)=>a*b,1)} combinations, ${offsets.at(-1)+1} storage bytes; release-2 head and DNA order preserved; export sha256 ${createHash('sha256').update(exported).digest('hex')}`)
