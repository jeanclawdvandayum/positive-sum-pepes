// Reproducible pepe-confetti sprite sheets for the alt-UI FX (sell, buy, and
// the detonation set-piece). Renders ~100 distinct pepes per mood with the
// REAL art (src/lib/pepeRender.ts, release 2), rasterises each SVG's 1px runs
// into a 69x69 pixel grid, and packs them into one indexed PNG per mood.
// Deterministic: a fixed seed per mood, so re-running reproduces the bytes.
//
//   node --experimental-strip-types scripts/gen-confetti-sprites.mjs   (from frontend/)
//
// Outputs:
//   public/alt/confetti/<mood>.png       10 columns × N rows of 69px cells
//   src/alt/fx/confettiSheets.json       the index the runtime reads (cell, cols, count, dna list)
//
// No dependencies beyond node: PNG = signature + IHDR/PLTE/IDAT/IEND chunks,
// deflated with node:zlib, CRC from zlib.crc32.

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { registerHooks } from 'node:module'
import { fileURLToPath } from 'node:url'
import { crc32, deflateSync } from 'node:zlib'

process.chdir(fileURLToPath(new URL('..', import.meta.url)))

// pepeRender.ts imports its art tables as bare JSON (Vite-style); serve them to
// node as ES modules so the real renderer runs unmodified.
registerHooks({
  load(url, context, next) {
    if (url.endsWith('.json')) {
      return { format: 'module', source: `export default ${readFileSync(fileURLToPath(url), 'utf8')}`, shortCircuit: true }
    }
    return next(url, context)
  },
})
const { renderPepeSvg, decodeDna } = await import('../src/lib/pepeRender.ts')

const VERSION = 2n // AMAZING and RAGE exist only in the release-2 art
const art = JSON.parse(readFileSync('src/lib/pepeArtExpanded.json', 'utf8'))
const EXPR = { NEUTRAL: 0, SMILE: 1, GRIN: 2, LAUGH: 3, SAD: 4, SCARED: 5, ANGRY: 6, SMIRK: 7, CRINGE: 8, MEH: 9, AMAZING: 10, RAGE: 11 }
const MOODS = {
  // sell + detonation: the round went badly for somebody
  sad: { seed: 0x5e11, expressions: ['RAGE', 'ANGRY', 'SAD', 'MEH'] },
  // buy: a seat on the ladder
  happy: { seed: 0xb0b, expressions: ['SMILE', 'SMIRK', 'AMAZING'] },
}
const COUNT = 100
const CELL = 69
const COLS = 10

function mulberry32(seed) {
  let a = seed >>> 0
  return () => {
    a = (a + 0x6d2b79f5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

/** DNA codec v2: 4 bits per axis in order expr, eye, hat, wear, item, skin, iris, bg. */
function dnaOf(traits) {
  return ['expr', 'eye', 'hat', 'wear', 'item', 'skin', 'iris', 'bg']
    .reduce((dna, axis, i) => dna | (BigInt(traits[axis]) << BigInt(i * 4)), 0n)
}

function pickSprites({ seed, expressions }) {
  const rand = mulberry32(seed)
  const pick = n => Math.floor(rand() * n)
  const c = art.counts
  const seen = new Set()
  const out = []
  for (let i = 0; out.length < COUNT; i++) {
    const traits = {
      expr: EXPR[expressions[out.length % expressions.length]],
      eye: pick(c.eye), hat: pick(c.hat), wear: pick(c.wear), item: pick(c.item),
      skin: pick(c.skin), iris: pick(c.iris), bg: pick(c.bg),
    }
    const dna = dnaOf(traits)
    const key = dna.toString(16)
    if (seen.has(key)) continue
    // round-trip through the real decoder: what we store is what renders
    const decoded = decodeDna(dna, VERSION)
    if (decoded.expr !== traits.expr) throw new Error(`expression ${traits.expr} did not survive the codec`)
    seen.add(key)
    out.push({ dna, expr: expressions.find(name => EXPR[name] === traits.expr) })
  }
  return out
}

/** The renderer emits one <rect> per horizontal run on a 69x69 grid. */
function rasterise(svg) {
  const px = new Array(CELL * CELL).fill(null)
  for (const m of svg.matchAll(/<rect x="(\d+)" y="(\d+)" width="(\d+)" height="(\d+)" fill="#([0-9A-Fa-f]{6})"\/>/g)) {
    const [x, y, w, h] = m.slice(1, 5).map(Number)
    for (let yy = y; yy < y + h; yy++) for (let xx = x; xx < x + w; xx++) px[yy * CELL + xx] = m[5].toUpperCase()
  }
  if (px.some(p => p === null)) throw new Error('sprite has unpainted pixels (background rect missing?)')
  return px
}

function chunk(type, data) {
  const len = Buffer.alloc(4)
  len.writeUInt32BE(data.length)
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data])
  const crc = Buffer.alloc(4)
  crc.writeUInt32BE(crc32(body) >>> 0)
  return Buffer.concat([len, body, crc])
}

/** Indexed (palette) PNG when the sheet fits 256 colours, truecolour otherwise. */
function encodePng(width, height, pixels) {
  const colours = [...new Set(pixels)]
  const indexed = colours.length <= 256
  const bpp = indexed ? 1 : 3
  const index = new Map(colours.map((c, i) => [c, i]))
  const raw = Buffer.alloc((width * bpp + 1) * height)
  for (let y = 0; y < height; y++) {
    const row = y * (width * bpp + 1)
    raw[row] = 0 // filter: none (flat pixel art deflates best unfiltered)
    for (let x = 0; x < width; x++) {
      const hex = pixels[y * width + x]
      const at = row + 1 + x * bpp
      if (indexed) raw[at] = index.get(hex)
      else for (let k = 0; k < 3; k++) raw[at + k] = parseInt(hex.slice(k * 2, k * 2 + 2), 16)
    }
  }
  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(width, 0)
  ihdr.writeUInt32BE(height, 4)
  ihdr[8] = 8 // bit depth
  ihdr[9] = indexed ? 3 : 2 // colour type: palette | RGB
  const parts = [Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', ihdr)]
  if (indexed) parts.push(chunk('PLTE', Buffer.from(colours.flatMap(hex => [0, 2, 4].map(k => parseInt(hex.slice(k, k + 2), 16))))))
  parts.push(chunk('IDAT', deflateSync(raw, { level: 9 })), chunk('IEND', Buffer.alloc(0)))
  return { png: Buffer.concat(parts), colours: colours.length, indexed }
}

mkdirSync('public/alt/confetti', { recursive: true })
const index = { cell: CELL, cols: COLS, version: Number(VERSION), sheets: {} }
for (const [mood, spec] of Object.entries(MOODS)) {
  const sprites = pickSprites(spec)
  const rows = Math.ceil(sprites.length / COLS)
  const width = COLS * CELL
  const height = rows * CELL
  const sheet = new Array(width * height).fill('000000')
  sprites.forEach((sprite, i) => {
    const px = rasterise(renderPepeSvg(sprite.dna, VERSION))
    const ox = (i % COLS) * CELL
    const oy = Math.floor(i / COLS) * CELL
    for (let y = 0; y < CELL; y++) for (let x = 0; x < CELL; x++) sheet[(oy + y) * width + ox + x] = px[y * CELL + x]
  })
  const { png, colours, indexed } = encodePng(width, height, sheet)
  const file = `public/alt/confetti/${mood}.png`
  writeFileSync(file, png)
  index.sheets[mood] = {
    src: `/alt/confetti/${mood}.png`,
    count: sprites.length,
    rows,
    expressions: spec.expressions,
    dna: sprites.map(s => `0x${s.dna.toString(16).padStart(8, '0')}`),
  }
  console.log(`${file}: ${sprites.length} sprites, ${width}x${height}px, ${colours} colours (${indexed ? 'indexed' : 'rgb'}), ${png.length} bytes`)
}
writeFileSync('src/alt/fx/confettiSheets.json', `${JSON.stringify(index, null, 2)}\n`)
console.log('src/alt/fx/confettiSheets.json written')
