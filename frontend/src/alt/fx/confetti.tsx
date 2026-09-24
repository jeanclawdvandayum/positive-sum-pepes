// Pepe-face confetti (sell, buy, detonation). Pieces are background-position
// windows into the pre-built sprite sheets in public/alt/confetti/ (generated
// by scripts/gen-confetti-sprites.mjs with the real art — nothing is rendered
// at runtime). Each burst samples random sprites, mixes in a few plain pixel
// squares, and flies them on gravity arcs: the `translate` property carries
// the vertical arc (ease-out rise, ease-in fall) while `transform` carries the
// horizontal drift and tumble, so both compose on one node. CSS: fx.css.

import { useState, type CSSProperties } from 'react'
import sheets from './confettiSheets.json'

export type ConfettiMood = keyof typeof sheets.sheets

type Piece = { style: CSSProperties; className: string }

export interface ConfettiOptions {
  /** Burst origin in viewport px. */
  at: { x: number; y: number }
  /** Pepe faces (sprites) in the burst. */
  faces?: number
  /** Plain pixel squares mixed in. */
  bits?: number
  /** First launch, ms after mount. */
  delay?: number
  /** Launch window the pieces stagger across, ms. */
  stagger?: number
  /** Scales the rise and spread (the detonation launches harder). */
  power?: number
  /** Deterministic sampling for repeatable QA frames. */
  seed?: number
}

function lcg(seed: number): () => number {
  let s = seed >>> 0
  return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296)
}

function burst(mood: ConfettiMood, o: ConfettiOptions): Piece[] {
  const rand = o.seed === undefined ? Math.random : lcg(o.seed)
  const sheet = sheets.sheets[mood]
  const vw = window.innerWidth
  const vh = window.innerHeight
  const narrow = vw < 600
  const power = o.power ?? 1
  const x = Math.min(Math.max(o.at.x, 16), vw - 16)
  const y = Math.min(Math.max(o.at.y, 16), vh - 16)
  // Horizontal reach stays inside the viewport so a 390px screen keeps its pieces.
  const reachLeft = Math.min(x - 14, (narrow ? 170 : 380) * power)
  const reachRight = Math.min(vw - 14 - x, (narrow ? 170 : 380) * power)
  // Rise stays under the top edge: an anchor near the header arcs lower.
  const rise = Math.min(vh * 0.42, (narrow ? 210 : 300) * power, Math.max(90, y - 50))
  const fall = vh - y + 70
  const faces = o.faces ?? 34
  const bits = o.bits ?? 10
  // Sample sprites without replacement: every face in one burst is distinct.
  const pool = Array.from({ length: sheet.count }, (_, i) => i)
  const pieces: Piece[] = []
  for (let i = 0; i < faces + bits; i++) {
    const face = i < faces
    const side = rand() < 0.5 ? -1 : 1
    const dx = side * (0.12 + 0.88 * rand()) * (side < 0 ? reachLeft : reachRight)
    const peak = -rise * (0.45 + 0.55 * rand())
    // Faces drift slowly enough to read: long airtime, a gentle sway, no edge-on flip.
    const duration = face ? 3400 + rand() * 1100 : 2000 + rand() * 700
    const delay = (o.delay ?? 0) + rand() * (o.stagger ?? 220)
    const spin = (rand() < 0.5 ? -1 : 1) * (face ? 12 + rand() * 38 : 300 + rand() * 500)
    const vars: Record<string, string> = {
      '--dx': `${Math.round(dx)}px`,
      '--peak': `${Math.round(peak)}px`,
      '--fall': `${Math.round(fall)}px`,
      '--spin': `${Math.round(spin)}deg`,
      '--flip': face ? '0deg' : `${Math.round(360 + rand() * 360)}deg`,
    }
    let className = 'fx-pc'
    if (face) {
      const pick = pool.splice(Math.floor(rand() * pool.length), 1)[0] ?? 0
      const size = Math.round((narrow ? 32 : 40) + rand() * (narrow ? 6 : 10))
      vars['--s'] = `${size}px`
      vars['--c'] = String(pick % sheets.cols)
      vars['--r'] = String(Math.floor(pick / sheets.cols))
      vars.backgroundImage = `url(${sheet.src})`
    } else {
      className += ` fx-pc-bit fx-pc-${mood} fx-pc-tone${i % 3}`
      vars['--s'] = `${narrow ? 7 : 9}px`
    }
    pieces.push({
      className,
      style: { left: x, top: y, animationDuration: `${Math.round(duration)}ms`, animationDelay: `${Math.round(delay)}ms`, ...vars } as CSSProperties,
    })
  }
  return pieces
}

/** One burst, sampled once on mount (re-renders never reshuffle the flight). */
export function PepeConfetti({ mood, ...options }: ConfettiOptions & { mood: ConfettiMood }) {
  const [pieces] = useState(() => burst(mood, options))
  return <>{pieces.map((piece, i) => <span key={i} className={piece.className} style={piece.style} />)}</>
}
