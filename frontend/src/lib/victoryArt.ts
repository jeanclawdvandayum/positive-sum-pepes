// The victory modal's pepe hand (Round 5): the pure art selection (which
// pepes the cards and the brag PNG draw, derived from the same victory data),
// the fan geometry shared by the CSS hand and the canvas composite, and the
// fan's PNG. Pepe art is a 69×69 pixel SVG; every raster here draws it at an
// integer multiple of 69 with smoothing off, so the PNG keeps the art's hard
// pixel edges. A single pepe uses the shared referralPepePng raster (828px).
/** The hand shows at most six cards; the rest collapse into a '+N more' chip. */
export const FAN_CAP = 6
/** Cards rotate about a pivot this many card heights below the card tops. */
export const FAN_PIVOT = 4

/** How many of a wallet's `total` pepes the hand shows, and how many collapse
 *  into the chip — so the modal only reads the art it will draw. */
export function fanHand(total: number, cap = FAN_CAP): { shown: number; more: number } {
  const shown = Math.max(0, Math.min(Math.floor(total), cap))
  return { shown, more: Math.max(0, Math.floor(total) - shown) }
}

/** Card i of n, in degrees: an even arc, at most 12° apart and 56° across. */
export function fanAngle(i: number, n: number): number {
  if (n < 2) return 0
  return (i - (n - 1) / 2) * Math.min(12, 56 / (n - 1))
}

/** The pepes the victory modal renders — and, because the brag PNG is drawn
 *  from this very hand, exactly the pepes the copied image shows. */
export type VictoryHand = { svgs: readonly string[]; more: number; identity: boolean }

/** Picks a victory's hand from the same data the modal renders. The dev lab's
 *  ready-made art wins; else the winner's position NFTs in the round's staker
 *  (already capped by fanHand when the query built them); else the wallet's
 *  auto-assigned pepe stands in. `undefined` while the NFTs are first loading
 *  — no card and no PNG ever shows stale art. The selection never branches on
 *  the victory source: claim and settle feed it the same fields, and only the
 *  copy around the hand differs. */
export function victoryHand(input: {
  mockPepes?: readonly string[]
  nfts?: { svgs: readonly string[]; more: number }
  nftsLoading?: boolean
  identity: string
}): VictoryHand | undefined {
  if (input.mockPepes) {
    const { shown, more } = fanHand(input.mockPepes.length)
    return { svgs: input.mockPepes.slice(0, shown), more, identity: false }
  }
  if (input.nfts && input.nfts.svgs.length > 0) return { svgs: input.nfts.svgs, more: input.nfts.more, identity: false }
  if (input.nftsLoading && input.nfts === undefined) return undefined
  return { svgs: [input.identity], more: 0, identity: true }
}

/** The art-selection predicate for the brag PNG: one pepe shares the single
 *  card's own raster, several share the whole fan as one composite, and a
 *  hand with nothing to show shares nothing — the brag button waits. */
export type VictoryShare =
  | { kind: 'single'; svg: string }
  | { kind: 'fan'; svgs: readonly string[]; more: number }

export function shareArt(hand: VictoryHand | undefined): VictoryShare | undefined {
  if (!hand || hand.svgs.length === 0) return undefined
  return hand.svgs.length === 1
    ? { kind: 'single', svg: hand.svgs[0] }
    : { kind: 'fan', svgs: hand.svgs, more: hand.more }
}

/** The art at its native 69×69: every SVG rect lands on whole pixels, so the
 *  scaled, rotated draw below samples true art pixels (no rasterizer seams). */
async function artPixels(svg: string): Promise<HTMLCanvasElement> {
  const source = URL.createObjectURL(new Blob([svg], { type: 'image/svg+xml' }))
  try {
    const image = new Image()
    image.src = source
    await image.decode()
    const canvas = document.createElement('canvas')
    canvas.width = canvas.height = 69
    const context = canvas.getContext('2d')
    if (!context) throw new Error('Image export unavailable')
    context.drawImage(image, 0, 0, 69, 69)
    return canvas
  } finally {
    URL.revokeObjectURL(source)
  }
}

// Composite palette: the dark instrument material in both themes, gold trim.
const STAGE = '#0e1e29'
const CARD = '#152833'
const GOLD = '#ffbe55'
const SHADOW = '#02090e'
/** Four PNG pixels per art pixel: each card's art is 276px. */
const ART = 69 * 4
const INSET = 14
const TRIM = 6
const MARGIN = 44

/** The hand as one PNG, drawn with the same fan geometry as the modal: each
 *  card is the pepe on a gold-trimmed card with a hard shadow, rotated about a
 *  pivot below the hand; a '+N more' tag sits in the corner when capped. */
export async function fanPng(svgs: readonly string[], more = 0): Promise<Blob> {
  const images = await Promise.all(svgs.map(artPixels))
  const card = ART + 2 * INSET
  const pivot = FAN_PIVOT * card
  const n = images.length
  // Bounding box of every rotated card (corners about the pivot at 0,0).
  let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity
  for (let i = 0; i < n; i++) {
    const a = (fanAngle(i, n) * Math.PI) / 180
    for (const [x, y] of [[-card / 2, -pivot], [card / 2, -pivot], [-card / 2, card - pivot], [card / 2, card - pivot]]) {
      const rx = x * Math.cos(a) - y * Math.sin(a)
      const ry = x * Math.sin(a) + y * Math.cos(a)
      minX = Math.min(minX, rx); maxX = Math.max(maxX, rx)
      minY = Math.min(minY, ry); maxY = Math.max(maxY, ry)
    }
  }
  const canvas = document.createElement('canvas')
  canvas.width = Math.ceil(maxX - minX + 2 * MARGIN)
  canvas.height = Math.ceil(maxY - minY + 2 * MARGIN + (more > 0 ? 40 : 0))
  const context = canvas.getContext('2d')
  if (!context) throw new Error('Image export unavailable')
  context.imageSmoothingEnabled = false
  context.fillStyle = STAGE
  context.fillRect(0, 0, canvas.width, canvas.height)
  context.strokeStyle = GOLD
  context.lineWidth = TRIM
  context.strokeRect(TRIM / 2 + 8, TRIM / 2 + 8, canvas.width - TRIM - 16, canvas.height - TRIM - 16)
  const originX = MARGIN - minX
  const originY = MARGIN - minY
  images.forEach((image, i) => {
    context.save()
    context.translate(originX, originY)
    context.rotate((fanAngle(i, n) * Math.PI) / 180)
    context.translate(-card / 2, -pivot)
    context.fillStyle = SHADOW
    context.fillRect(10, 10, card, card)
    context.fillStyle = GOLD
    context.fillRect(0, 0, card, card)
    context.fillStyle = CARD
    context.fillRect(TRIM, TRIM, card - 2 * TRIM, card - 2 * TRIM)
    context.drawImage(image, INSET, INSET, ART, ART)
    context.restore()
  })
  if (more > 0) {
    context.font = '700 30px monospace'
    context.fillStyle = GOLD
    context.textAlign = 'right'
    context.textBaseline = 'bottom'
    context.fillText(`+${more} more`, canvas.width - 30, canvas.height - 26)
  }
  return new Promise<Blob>((resolve, reject) => canvas.toBlob(
    blob => blob ? resolve(blob) : reject(new Error('Image export unavailable')),
    'image/png',
  ))
}
