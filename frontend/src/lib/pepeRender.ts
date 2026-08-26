import art from './pepeArt.json'

/// Client-side pepe renderer — a faithful mirror of PepeDescriptor.renderSVG.
/// Same RLE stamps, same palette assembly, same layer order (base → expr →
/// eyes → eyewear → hat → item), same 4-bit DNA codec. Used when the on-chain
/// descriptor is unreachable (no wallet / dev chain down) and for decorative
/// pepes (header logo). On-chain output stays the canonical source whenever
/// it answers.

const hexToBytes = (h: string): Uint8Array =>
  Uint8Array.from(h.match(/.{2}/g)!, (b) => parseInt(b, 16))

const BASE = hexToBytes(art.base)
const EXPR = art.expr.map(hexToBytes)
const EYE = art.eye.map(hexToBytes)
const HAT = art.hat.map((s) => (s ? hexToBytes(s) : null))
const WEAR = art.wear.map((s) => (s ? hexToBytes(s) : null))
const ITEM = art.item.map((s) => (s ? hexToBytes(s) : null))
const SKINS = hexToBytes(art.skins)
const FIXED = hexToBytes(art.fixed)
const IRISES = hexToBytes(art.irises)
const BGS = hexToBytes(art.bgs)

export interface Traits {
  expr: number
  eye: number
  hat: number
  wear: number
  item: number
  skin: number
  iris: number
  bg: number
}

/// codec v2 — 4 bits per axis, modulo the axis count (any uint256 is valid)
export function decodeDna(dna: bigint): Traits {
  const f = (shift: number) => Number((dna >> BigInt(shift)) & 15n)
  const c = art.counts
  return {
    expr: f(0) % c.expr,
    eye: f(4) % c.eye,
    hat: f(8) % c.hat,
    wear: f(12) % c.wear,
    item: f(16) % c.item,
    skin: f(20) % c.skin,
    iris: f(24) % c.iris,
    bg: f(28) % c.bg,
  }
}

const rgb = (b: Uint8Array, o: number): string =>
  '#' + [0, 1, 2].map((i) => b[o + i].toString(16).padStart(2, '0')).join('').toUpperCase()

/// mirrors PepeArtData.palette — 24 slots assembled from skin ramp + fixed
/// shading slots + iris + bg overrides
function palette(skin: number, iris: number, bg: number): string[] {
  const m: string[] = new Array(24).fill('#000000')
  art.skinSlots.forEach((slot, i) => {
    m[slot] = rgb(SKINS, skin * 24 + i * 3)
  })
  art.fixedSlots.forEach((slot, i) => {
    m[slot] = rgb(FIXED, i * 3)
  })
  m[6] = rgb(IRISES, iris * 3)
  m[15] = rgb(BGS, bg * 3)
  return m
}

/// RLE layer -> one <rect> per horizontal run. Byte-pair runs [len-1][slot],
/// never crossing row boundaries; slot 0 is transparent. `off` skips the
/// 4-byte dx/dy/w header (the base sprite has none).
function runs(data: Uint8Array, ox: number, oy: number, w: number, pal: string[], off = 0): string {
  let s = ''
  let x = 0
  let y = 0
  for (let i = off; i + 1 < data.length; i += 2) {
    const len = data[i] + 1
    const idx = data[i + 1]
    if (idx !== 0) {
      s += `<rect x="${ox + x}" y="${oy + y}" width="${len}" height="1" fill="${pal[idx]}"/>`
    }
    x += len
    if (x === w) {
      x = 0
      ++y
    }
  }
  return s
}

const stamp = (data: Uint8Array, pal: string[]): string =>
  data.length === 0 ? '' : runs(data, data[0], data[1], data[2], pal, 4)

/// dna -> complete SVG, layer order identical to the contract
export function renderPepeSvg(dna: bigint): string {
  const t = decodeDna(dna)
  const pal = palette(t.skin, t.iris, t.bg)
  const layers = [
    runs(BASE, 0, 0, 69, pal),
    stamp(EXPR[t.expr], pal),
    stamp(EYE[t.eye], pal),
    WEAR[t.wear] ? stamp(WEAR[t.wear]!, pal) : '',
    HAT[t.hat] ? stamp(HAT[t.hat]!, pal) : '',
    ITEM[t.item] ? stamp(ITEM[t.item]!, pal) : '',
  ].join('')
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" shapeRendering="crispEdges" viewBox="0 0 69 69">` +
    `<rect x="0" y="0" width="69" height="69" fill="${pal[15]}"/>` +
    layers +
    `</svg>`
  )
}

/// a random dna — 8 axes x 4 bits = exactly 32 bits of entropy
export function randomDna(): bigint {
  const u = new Uint32Array(1)
  crypto.getRandomValues(u)
  return BigInt(u[0]) & 0xffffffffn
}
