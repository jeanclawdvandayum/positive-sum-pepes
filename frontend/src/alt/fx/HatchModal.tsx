// HatchModal — the predeposit claim reveal (alt UI, kind 'claimPredeposit').
// A centered modal with a pixel egg on a spotlit pedestal. Tapping the egg
// (click / Enter / Space) plays: shake → cracks → shell burst → a tadpole
// wriggles out → legs → froglet → the ACTUAL claimed pepe (real art via
// renderPepeSvg, the claim's id + the staker's DNA version) with a light
// burst, sparkles and a bounce. Unknown id → a decorative pepe.
//
// Rendered by ActionFxLayer in its own portal (outside the aria-hidden FX
// layer). It is one of two FX overlays that catch input and never traps the
// user: Esc, a click outside the card, or the close control dismisses it at
// any beat. Motion is CSS keyframes keyed off data-phase; timers only flip the
// phase. Reduced motion: the tap cross-fades egg → pepe (opacity-only WAAPI).

import { useEffect, useRef, useState, type CSSProperties } from 'react'
import { createPortal } from 'react-dom'
import type { FxEvent } from '../../lib/actionFx'
import { renderPepeSvg } from '../../lib/pepeRender'
import { rpcCall } from '../../lib/rpc'
import { stakerAbi } from '../../lib/abi'
import { reducedMotion } from './parts'

type Phase = 'idle' | 'shake' | 'crack' | 'burst' | 'tadpole' | 'legs' | 'froglet' | 'pepe' | 'settled'

/** ms after the tap at which each beat starts. */
const BEATS: [Phase, number][] = [
  ['shake', 0], ['crack', 650], ['burst', 1150], ['tadpole', 1450],
  ['legs', 2300], ['froglet', 2850], ['pepe', 3400], ['settled', 4500],
]

const svgUri = (svg: string) => `data:image/svg+xml,${encodeURIComponent(svg)}`

/** Rows of palette keys → a crisp pixel SVG ('.' is transparent). */
function pixelSvg(rows: string[], palette: Record<string, string>): string {
  const width = Math.max(...rows.map(row => row.length))
  let rects = ''
  rows.forEach((row, y) => {
    for (let x = 0; x < row.length;) {
      let run = 1
      while (row[x + run] === row[x]) run++
      if (row[x] !== '.') rects += `<rect x="${x}" y="${y}" width="${run}" height="1" fill="${palette[row[x]]}"/>`
      x += run
    }
  })
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${width} ${rows.length}" shape-rendering="crispEdges">${rects}</svg>`
}

const FROG = { o: '#16241c', b: '#58a43e', B: '#8fd06a', e: '#ffffff', p: '#16241c', r: '#8a2f3b' }

/** Shown when the minted NFT can't be resolved: a "?" card, never another pepe. */
const MYSTERY = pixelSvg([
  'kkkkkkkkkkkkkkk',
  'kkkkkkkkkkkkkkk',
  'kkkkkkkkkkkkkkk',
  'kkkkkkkkkkkkkkk',
  'kkkkkwwwwwkkkkk',
  'kkkkwwkkkwwkkkk',
  'kkkkkkkkkwwkkkk',
  'kkkkkkkkwwkkkkk',
  'kkkkkkkwwkkkkkk',
  'kkkkkkkwwkkkkkk',
  'kkkkkkkkkkkkkkk',
  'kkkkkkkwwkkkkkk',
  'kkkkkkkkkkkkkkk',
  'kkkkkkkkkkkkkkk',
  'kkkkkkkkkkkkkkk',
], { k: '#1d333e', w: '#b9eb8e' })

const TADPOLE = pixelSvg([
  '....oooo.........',
  '..oobbbboo.......',
  '.obBBbbbbbo......',
  'obeeBbbbbbboo....',
  'obepbbbbbbbbbboo.',
  'obbbbbbbbbboo..oo',
  '.obbbbbbbbo......',
  '..oobbbboo.......',
  '....oooo.........',
], FROG)

const LEGS = pixelSvg([
  '....oooo.......',
  '..oobbbboo.....',
  '.obBBbbbbbo....',
  'obeeBbbbbbboo..',
  'obepbbbbbbbbbo.',
  'obbbbbbbbbboo..',
  '.obbbbbbbbo....',
  '..obbbbbbo.....',
  '..obooooboo....',
  '.obo....obo....',
  '.oo.....oo.....',
], FROG)

const FROGLET = pixelSvg([
  '..oooo....oooo..',
  '.oeeeeo..oeeeeo.',
  '.oeppeooooeppeo.',
  '.obbbbbbbbbbbbo.',
  'obBBbbbbbbbbbbbo',
  'obbbbbbbbbbbbbbo',
  'obbrrrrrrrrrrbbo',
  '.obbbbbbbbbbbbo.',
  '..obbooooooobbo.',
  '.obbo......obbo.',
  '.oooo......oooo.',
], FROG)

// The egg is drawn procedurally so its two shell halves split exactly along
// the zigzag the cracks trace.
const EGG_W = 20
const EGG_H = 24
const EGG_PALETTE = { o: '#1d2b24', w: '#f6f0dc', h: '#ffffff', d: '#d6c9a2', g: '#79c257', G: '#3f8a2d', c: '#1d2b24' }
const SPECKLES: [number, number, 'g' | 'G'][] = [[12, 5, 'g'], [13, 6, 'G'], [6, 9, 'g'], [5, 10, 'G'], [14, 13, 'g'], [9, 16, 'G'], [10, 16, 'g'], [4, 17, 'g'], [13, 19, 'G']]
/** Row where the shell splits at column x: a 2-step zigzag around the waist. */
const splitRow = (x: number) => (x % 4 < 2 ? 10 : 12)

const EGG = (() => {
  const inside = (x: number, y: number) => {
    if (x < 0 || y < 0 || x >= EGG_W || y >= EGG_H) return false
    const top = y < 14
    const t = (y + 0.5 - 14) / (top ? 14 : 10)
    const rx = 9.6 * Math.sqrt(Math.max(0, 1 - t * t)) * (top ? 0.86 + 0.14 * (y / 14) : 1)
    return Math.abs(x + 0.5 - EGG_W / 2) <= rx
  }
  const grid: string[][] = []
  for (let y = 0; y < EGG_H; y++) {
    const row: string[] = []
    for (let x = 0; x < EGG_W; x++) {
      if (!inside(x, y)) { row.push('.'); continue }
      const edge = !inside(x - 1, y) || !inside(x + 1, y) || !inside(x, y - 1) || !inside(x, y + 1)
      const dx = x + 0.5 - EGG_W / 2
      row.push(edge ? 'o' : dx < -3 && y >= 3 && y <= 9 && dx > -7 ? 'h' : dx > 4 && y >= 13 ? 'd' : 'w')
    }
    grid.push(row)
  }
  for (const [x, y, tone] of SPECKLES) if (grid[y][x] === 'w' || grid[y][x] === 'd') grid[y][x] = tone
  const half = (keep: (x: number, y: number) => boolean) =>
    pixelSvg(grid.map((row, y) => row.map((c, x) => (keep(x, y) ? c : '.')).join('')), EGG_PALETTE)
  // Crack pixels trace the split line; each level reveals more of it.
  const crack = (from: number, to: number, branches: [number, number][]) => {
    const rows = Array.from({ length: EGG_H }, () => Array<string>(EGG_W).fill('.'))
    for (let x = from; x <= to; x++) {
      const y = splitRow(x)
      if (grid[y]?.[x] && grid[y][x] !== '.') rows[y][x] = 'c'
      if (x % 4 === 2 && grid[11]?.[x] !== '.') rows[11][x] = 'c' // the zigzag's riser
    }
    for (const [x, y] of branches) if (grid[y]?.[x] !== '.') rows[y][x] = 'c'
    return pixelSvg(rows.map(row => row.join('')), EGG_PALETTE)
  }
  return {
    top: half((x, y) => y < splitRow(x)),
    bottom: half((x, y) => y >= splitRow(x)),
    cracks: [
      crack(12, 15, [[13, 9]]),
      crack(6, 17, [[13, 9], [7, 13], [16, 9]]),
      crack(0, EGG_W - 1, [[13, 9], [7, 13], [16, 9], [3, 13], [10, 9], [11, 8]]),
    ],
  }
})()

const SPARKS = 10
const SHARDS = 8

export default function HatchModal({ event, onDone }: { event: FxEvent; onDone: () => void }) {
  const [phase, setPhase] = useState<Phase>('idle')
  // The reveal is the minted NFT's canonical art: staker.dnaOf(id), read once.
  // Unknown or unreadable → a mystery card, never substitute art.
  const [art, setArt] = useState(() => svgUri(event.pepe?.dna !== undefined
    ? renderPepeSvg(event.pepe.dna, event.pepe.dnaVersion) : MYSTERY))
  useEffect(() => {
    const pepe = event.pepe
    if (!pepe?.staker || pepe.dna !== undefined) return
    let live = true
    ;(rpcCall(pepe.staker, stakerAbi, 'dnaOf', [pepe.id]) as Promise<bigint>)
      .then(dna => { if (live) setArt(svgUri(renderPepeSvg(dna, pepe.dnaVersion))) })
      .catch(() => {})
    return () => { live = false }
  }, [event.pepe])
  const eggRef = useRef<HTMLButtonElement>(null)
  const closeRef = useRef<HTMLButtonElement>(null)
  const pepeRef = useRef<HTMLImageElement>(null)
  const raysRef = useRef<HTMLSpanElement>(null)
  const timers = useRef<number[]>([])
  const onDoneRef = useRef(onDone)
  onDoneRef.current = onDone

  // Focus the egg on open; hand focus back to whatever held it on close.
  useEffect(() => {
    const previous = document.activeElement instanceof HTMLElement ? document.activeElement : undefined
    eggRef.current?.focus({ preventScroll: true })
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onDoneRef.current() }
    window.addEventListener('keydown', onKey)
    const pending = timers.current
    return () => {
      window.removeEventListener('keydown', onKey)
      pending.forEach(clearTimeout)
      if (previous?.isConnected) previous.focus({ preventScroll: true })
    }
  }, [])

  useEffect(() => {
    if (phase === 'settled') closeRef.current?.focus({ preventScroll: true })
  }, [phase])

  const hatch = () => {
    if (phase !== 'idle') return
    if (reducedMotion()) {
      // style.css zeroes CSS transitions under reduced motion; an opacity-only
      // WAAPI cross-fade still reads as the reveal.
      setPhase('settled')
      eggRef.current?.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 300, fill: 'forwards' })
      for (const el of [pepeRef.current, raysRef.current]) el?.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 400, delay: 150, fill: 'backwards' })
      return
    }
    for (const [beat, at] of BEATS) timers.current.push(window.setTimeout(() => setPhase(beat), at))
  }

  const hatched = phase !== 'idle' && phase !== 'shake' && phase !== 'crack'
  const revealed = phase === 'pepe' || phase === 'settled'
  return createPortal(
    <div className="hx-backdrop" onClick={e => { if (e.target === e.currentTarget) onDone() }}>
      <div className="hx-card" role="dialog" aria-modal="true" aria-label="hatch">
        <button ref={closeRef} type="button" className="hx-close" aria-label="close" onClick={onDone}>×</button>
        <div className="hx-stage" data-phase={phase} data-hatched={hatched || undefined} data-revealed={revealed || undefined}>
          <span className="hx-beam" aria-hidden="true" />
          <span ref={raysRef} className="hx-rays" aria-hidden="true" />
          <span className="hx-pedestal" aria-hidden="true" />
          <button ref={eggRef} type="button" className="hx-egg" aria-label="tap the egg" onClick={hatch} disabled={hatched}>
            <img className="hx-shell hx-shell-bottom" src={svgUri(EGG.bottom)} alt="" draggable={false} />
            <img className="hx-shell hx-shell-top" src={svgUri(EGG.top)} alt="" draggable={false} />
            {EGG.cracks.map((crack, i) => (
              <img key={i} className={`hx-crack hx-crack-${i + 1}`} src={svgUri(crack)} alt="" draggable={false} />
            ))}
          </button>
          <span className="hx-flash" aria-hidden="true" />
          {Array.from({ length: SHARDS }, (_, i) => {
            const angle = -Math.PI * (0.1 + (0.8 * i) / (SHARDS - 1))
            return <span key={i} className="hx-shard" aria-hidden="true"
              style={{ '--tx': `${Math.round(Math.cos(angle) * (70 + (i % 3) * 22))}px`, '--ty': `${Math.round(Math.sin(angle) * (60 + (i % 2) * 30))}px`, '--rot': `${(i % 2 ? 1 : -1) * (140 + i * 30)}deg` } as CSSProperties} />
          })}
          <img className="hx-creature hx-tadpole" src={svgUri(TADPOLE)} alt="" aria-hidden="true" draggable={false} />
          <img className="hx-creature hx-legs" src={svgUri(LEGS)} alt="" aria-hidden="true" draggable={false} />
          <img className="hx-creature hx-froglet" src={svgUri(FROGLET)} alt="" aria-hidden="true" draggable={false} />
          <span className="hx-puff" aria-hidden="true" />
          <img ref={pepeRef} className="hx-pepe" src={art} alt="" draggable={false} />
          {Array.from({ length: SPARKS }, (_, i) => {
            const angle = (i / SPARKS) * Math.PI * 2 - Math.PI / 2
            const reach = 110 + (i % 2) * 34
            return <span key={i} className="hx-spark" aria-hidden="true"
              style={{ '--tx': `${Math.round(Math.cos(angle) * reach)}px`, '--ty': `${Math.round(Math.sin(angle) * reach)}px`, animationDelay: `${60 + (i % 5) * 70}ms` } as CSSProperties} />
          })}
        </div>
        <p className="hx-hint" aria-hidden={phase !== 'idle'}>tap the egg</p>
      </div>
    </div>,
    document.body,
  )
}
