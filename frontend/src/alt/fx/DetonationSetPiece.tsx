// ─────────────────────────────────────────────────────────────────────────────
// DetonationSetPiece — the detonation set piece (PLAN Feature 4).
//
// Rendered by ActionFxLayer for kind 'detonate' (FxLab's mock stage can mount
// it too). One of two FX overlays that catch input: a click or Esc skips it at
// any beat, and it auto-ends at 6.2s. The story: the alarm goes off, the clock
// slams to zero, the ladder's winners rocket away to safety, and the one big
// bomb goes off. Timeline (ms):
//   0–900      ALARM: dim ramps in, three red vignette pulses, hazard tape
//              slides onto the top and bottom edges, two siren beams sweep
//   350–690    PIXEL BOMB drops onto the blast point (a bespoke 48×60 sprite,
//              PixelBomb below), rocks from 700, twitches from 2600 while its
//              spark burns the fuse down pixel by pixel; white at 3190
//   900–1000   white flash
//   950–1300   SLAM: 00:00:00 in --time-lit (forced to the critical red)
//              lands from scale 3.4 with a red glow; square shockwave ring
//   1000–1500  shake A: ±12px decaying (page + stage)
//   1450–3160  ESCAPE: each ladder winner (the real seat art) climbs into a
//              chunky pixel rocket — stepped nose cone, banded steel hull, a
//              porthole window with the face in it — and arcs up and away to
//              safety, newest seat first, 90ms apart, trailing the blast's
//              own pixel smoke puffs; the seat empties as it leaves
//   1600–3200  shake B: a ±3px launch rumble
//   3250–3900  BLAST: the bomb bursts into the 3D cloud (its fireball ignites
//              at the bomb body's exact center and radius), a hard white-out,
//              shockwave and ground rings; the cloud rises behind the clock
//   3250–4050  shake C: ±18px decaying
//   3350–5300  DEBRIS: 16 pixel chunks + a burst of rage/angry/sad/meh
//              pepe confetti from the blast
//   4200–4700  LOCK: ladder rows gray out left→right (the real rows) and the
//              stamp hits the clock's corner with a jolt
//   4700–5200  SETTLE: dim relaxes to .45, the cloud and tape leave
//   5800–6200  stage fades out → onDone
//
// prefers-reduced-motion: static dim + clock + stamp + the landed pixel bomb
// (no wobble, no burn), opacity fade ≤1.2s — no shake, no rockets, no
// particles, no 3D. PhaseEngine keeps its rAF monopoly: everything here is
// CSS keyframes or element.animate, animating transform/opacity/filter only.
// Particle groups: ≤10 rockets, the shared smoke (≤48 live exhaust puffs
// spawned by timer + 12 static blast puffs, every puff self-removing),
// 16 debris, 38 confetti — each burst under 50 nodes. Timers and Animation
// handles are all cleaned up on unmount/skip, and the real page (.alt-shell
// transform, ladder filters, emptied seat art) is restored.
// ─────────────────────────────────────────────────────────────────────────────

import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import type { CSSProperties, Ref } from 'react'
import { PepeConfetti } from './confetti'
import { DECORATIVE_ART_VERSION, renderPepeSvg } from '../../lib/pepeRender'
import { loadBoom3d } from './boomLoader'
import type { Boom } from './boom3d'

// ── The pixel bomb ──────────────────────────────────────────────────────────
// A bespoke sprite for this scene, drawn on a 48×60 art grid and shown at a
// whole number of screen pixels per art pixel (--bpx: 4 on desktop, 3 under
// 700px), so every art pixel stays crisp. The body is a posterized sphere
// (four bands, Bayer-dithered only at the band edges, lit from the upper
// left) with an outline, a glint, and a red rim light on the lower right
// from the alarm; a riveted collar; a 2px twisted rope fuse; a two-frame
// spark; and a flat ground shadow. Colors are theme vars (--bomb-* on
// .dtn-stage). The ground point — the shadow's center, which the stage
// pins to the blast point — is art (BOMB_CX, BOMB_GROUND).
const BOMB_W = 48
const BOMB_H = 60
const BOMB_CX = 22 // body center x (a pixel boundary: the body is 34px wide)
const BOMB_CY = 39 // body center y
const BOMB_R = 17 // body radius
const BOMB_GROUND = 58

type BombTone = 'ink' | 'b0' | 'b1' | 'b2' | 'b3' | 'spec' | 'rim' | 'shade' | 'r0' | 'r1' | 'r2'
const BAYER4 = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
/** Lambert thresholds into the lit bands (brightest first); below the last: b0. */
const BODY_BANDS: [number, BombTone][] = [[0.86, 'b3'], [0.58, 'b2'], [0.14, 'b1']]

/** One `M x y h1 v1 h-1 z` run per same-tone horizontal pixel run. */
function runsPath(px: Map<number, BombTone>, tone: BombTone): string {
  let d = ''
  for (let y = 0; y < BOMB_H; y++) {
    for (let x = 0; x < BOMB_W; x++) {
      if (px.get(y * BOMB_W + x) !== tone) continue
      let e = x
      while (e + 1 < BOMB_W && px.get(y * BOMB_W + e + 1) === tone) e++
      d += `M${x} ${y}h${e - x + 1}v1h${x - e - 1}z`
      x = e
    }
  }
  return d
}

const PIXEL_BOMB = (() => {
  const body = new Map<number, BombTone>()
  const put = (x: number, y: number, t: BombTone) => body.set(y * BOMB_W + x, t)
  const inside = (x: number, y: number) =>
    (x + 0.5 - BOMB_CX) ** 2 + (y + 0.5 - BOMB_CY) ** 2 <= BOMB_R * BOMB_R
  const L = Math.hypot(0.5, 0.62, 0.6)
  for (let y = BOMB_CY - BOMB_R; y < BOMB_CY + BOMB_R; y++) {
    for (let x = BOMB_CX - BOMB_R; x < BOMB_CX + BOMB_R; x++) {
      if (!inside(x, y)) continue
      if (!inside(x - 1, y) || !inside(x + 1, y) || !inside(x, y - 1) || !inside(x, y + 1)) {
        put(x, y, 'ink')
        continue
      }
      const dx = (x + 0.5 - BOMB_CX) / BOMB_R
      const dy = (y + 0.5 - BOMB_CY) / BOMB_R
      const r = Math.hypot(dx, dy)
      const nz = Math.sqrt(Math.max(1 - r * r, 0))
      const b = BAYER4[(y % 4) * 4 + (x % 4)] / 16
      // bands: clean fills, with a one-to-two pixel checker seam at each edge
      const lam0 = (-0.5 * dx - 0.62 * dy + 0.6 * nz) / L
      const seam = BODY_BANDS.find(([edge]) => Math.abs(lam0 - edge) < 0.035)
      const lam = seam ? seam[0] + ((x + y) % 2 ? 0.01 : -0.01) : lam0
      // the rim light from the alarm: a lower-right crescent, dithered inward
      const toward = (dx * 0.6 + dy * 0.8) / Math.max(r, 1e-3)
      if (toward > 0.3 && (r > 1 - 2.1 / BOMB_R || (r > 1 - 3.2 / BOMB_R && toward > 0.55 && b < 0.5))) {
        put(x, y, 'rim')
        continue
      }
      // the glint: a tilted window reflection upper left, ringed in the top band
      const ex = dx * BOMB_R + 7
      const ey = dy * BOMB_R + 8.5
      const gu = ex * 0.82 + ey * 0.57
      const gw = -ex * 0.57 + ey * 0.82
      const g = (gu / 3.8) ** 2 + (gw / 1.9) ** 2
      put(x, y, g <= 1 ? 'spec' : g <= 2.1 ? 'b3' : BODY_BANDS.find(([edge]) => lam > edge)?.[1] ?? 'b0')
    }
  }
  // second glint: a two-pixel catch light further round the curve
  put(BOMB_CX - 13, BOMB_CY - 2, 'spec')
  put(BOMB_CX - 13, BOMB_CY - 1, 'spec')
  put(BOMB_CX - 12, BOMB_CY - 2, 'b3')

  // the collar: a 10px riveted cylinder with a lip and a flange, its dark
  // opening where the fuse goes in; the body darkens under the flange
  const cyl: BombTone[] = ['ink', 'b3', 'spec', 'b3', 'b2', 'b2', 'b1', 'b1', 'b0', 'ink']
  const c0 = BOMB_CX - 5
  const top = BOMB_CY - BOMB_R - 5 // 17
  for (let c = 1; c < 9; c++) put(c0 + c, top, 'ink')
  for (let c = 0; c < 10; c++) {
    put(c0 + c, top + 1, c === 0 || c === 9 || (c >= 3 && c <= 6) ? 'ink' : c < 3 ? 'b3' : 'b2')
    for (let y = top + 2; y < top + 5; y++) put(c0 + c, y, cyl[c])
  }
  put(c0 + 2, top + 3, 'b1') // rivets
  put(c0 + 7, top + 3, 'b3')
  for (let c = -1; c < 11; c++) {
    put(c0 + c, top + 5, c === -1 || c === 10 ? 'ink' : c < 3 ? 'b3' : c < 6 ? 'b2' : c < 9 ? 'b1' : 'b0')
    put(c0 + c, top + 6, c === -1 || c === 10 ? 'ink' : 'b0')
  }
  for (let c = 0; c < 10; c++) put(c0 + c, top + 7, c < 2 || c > 7 ? 'b0' : 'ink')

  // ground shadow: a flat ellipse, solid in the middle, checkered at the rim
  const shadow = new Map<number, BombTone>()
  for (let y = BOMB_GROUND - 3; y < BOMB_GROUND + 2; y++) {
    for (let x = 0; x < BOMB_W; x++) {
      const e = ((x + 0.5 - BOMB_CX - 1) / 18) ** 2 + ((y + 0.5 - BOMB_GROUND) / 2.4) ** 2
      if (e <= 0.62 || (e <= 1 && (x + y) % 2 === 0)) shadow.set(y * BOMB_W + x, 'shade')
    }
  }

  // the fuse: a curve out of the collar, up and over to the right, rasterized
  // to a 1px centerline then doubled into a 2px rope with a diagonal twist.
  // Each centerline pixel is one burn step; a pixel shared by two steps
  // belongs to the one nearer the collar (it burns last).
  const line: [number, number][] = []
  const P = [[BOMB_CX - 0.5, top + 1.5], [BOMB_CX - 1.5, top - 9], [BOMB_CX + 9, top - 5], [BOMB_CX + 15, top - 13]]
  for (let s = 0; s <= 400; s++) {
    const t = s / 400
    const u = 1 - t
    const x = u ** 3 * P[0][0] + 3 * u * u * t * P[1][0] + 3 * u * t * t * P[2][0] + t ** 3 * P[3][0]
    const y = u ** 3 * P[0][1] + 3 * u * u * t * P[1][1] + 3 * u * t * t * P[2][1] + t ** 3 * P[3][1]
    const p: [number, number] = [Math.floor(x), Math.floor(y)]
    const last = line[line.length - 1]
    if (!last || last[0] !== p[0] || last[1] !== p[1]) line.push(p)
  }
  const owner = new Map<number, number>()
  const rope = new Map<number, BombTone>()
  line.forEach(([x, y], i) => {
    const a = line[Math.max(i - 1, 0)]
    const b = line[Math.min(i + 1, line.length - 1)]
    const steep = Math.abs(b[1] - a[1]) >= Math.abs(b[0] - a[0])
    const cells: [number, number, BombTone][] = [
      [x, y, i % 3 === 0 ? 'r0' : 'r2'],
      steep ? [x + 1, y, i % 3 === 1 ? 'r0' : 'r1'] : [x, y - 1, i % 3 === 1 ? 'r0' : 'r2'],
    ]
    for (const [cx, cy, tone] of cells) {
      const k = cy * BOMB_W + cx
      if (owner.has(k)) continue
      owner.set(k, i)
      rope.set(k, tone)
    }
  })
  // a frayed tip: two loose strands past the end
  const [tx, ty] = line[line.length - 1]
  owner.set((ty - 1) * BOMB_W + tx + 2, line.length - 1)
  rope.set((ty - 1) * BOMB_W + tx + 2, 'r1')
  owner.set(ty * BOMB_W + tx + 2, line.length - 1)
  rope.set(ty * BOMB_W + tx + 2, 'r2')
  const segments = line.map((_, i) => {
    const seg = new Map<number, BombTone>()
    owner.forEach((o, k) => { if (o === i) seg.set(k, rope.get(k)!) })
    return (['r0', 'r1', 'r2'] as const).map(tone => ({ tone, d: runsPath(seg, tone) })).filter(p => p.d)
  })

  const bodyTones: BombTone[] = ['b0', 'b1', 'b2', 'b3', 'spec', 'rim', 'ink']
  return {
    shadow: runsPath(shadow, 'shade'),
    body: bodyTones.map(tone => ({ tone, d: runsPath(body, tone) })),
    segments,
    fuse: line,
  }
})()

/** The spark's two flicker frames, in art pixels around the burning point. */
const SPARK_FRAMES: Record<'w' | 'y' | 'o', [number, number][]>[] = [
  {
    w: [[0, 0]],
    y: [[-1, 0], [1, 0], [0, -1], [0, 1]],
    o: [[-2, -2], [2, -2], [-3, 0], [3, 0], [0, -3], [2, 2], [-2, 2]],
  },
  {
    w: [[0, 0], [0, -1]],
    y: [[-1, -1], [1, -1], [-1, 0], [1, 0], [0, -2], [0, 1]],
    o: [[-3, -2], [3, -2], [-2, 1], [2, 1], [0, -4], [-1, -3], [1, -3]],
  },
]
const sparkPath = (pts: [number, number][]) => pts.map(([x, y]) => `M${x} ${y}h1v1h-1z`).join('')
/** Loose embers thrown off the spark: end offset in art px, loop delay. */
const EMBERS = [
  { ex: '-4px', ey: '-5px', delay: '0ms' },
  { ex: '5px', ey: '-4px', delay: '-130ms' },
  { ex: '2px', ey: '-7px', delay: '-250ms' },
]

// Fuse timeline (ms): the spark sits at the fuse tip from the drop, burns
// one art pixel at a time down to the collar, and the bomb goes white.
const FUSE_LIT = 650
const FUSE_OUT = 5240
const FUSE_STEP = (FUSE_OUT - FUSE_LIT) / (PIXEL_BOMB.fuse.length - 1)

function PixelBomb({ sparkRef }: { sparkRef: Ref<SVGGElement> }) {
  const [tipX, tipY] = PIXEL_BOMB.fuse[PIXEL_BOMB.fuse.length - 1]
  return (
    <svg
      className="dtn-pixel-bomb-art"
      viewBox={`0 0 ${BOMB_W} ${BOMB_H}`}
      shapeRendering="crispEdges"
      aria-hidden="true"
    >
      <path className="dtn-pb-shadow" d={PIXEL_BOMB.shadow} />
      <g className="dtn-pb-rock">
        <g className="dtn-pb-twitch">
          {PIXEL_BOMB.body.map(p => <path key={p.tone} d={p.d} fill={`var(--bomb-${p.tone})`} />)}
          {/* fuse pixel i (0 at the collar) burns away as the spark leaves it */}
          {PIXEL_BOMB.segments.map((seg, i) => (
            <g
              key={i}
              className="dtn-pb-seg"
              style={{ '--burn': `${Math.round(FUSE_LIT + (PIXEL_BOMB.fuse.length - i) * FUSE_STEP)}ms` } as CSSProperties}
            >
              {seg.map(p => <path key={p.tone} d={p.d} fill={`var(--bomb-${p.tone})`} />)}
            </g>
          ))}
          <g ref={sparkRef} className="dtn-pb-spark" transform={`translate(${tipX} ${tipY})`}>
            {SPARK_FRAMES.map((f, i) => (
              <g key={i} className={`dtn-pb-spark-f${i}`}>
                <path d={sparkPath(f.o)} fill="var(--fire-orange)" />
                <path d={sparkPath(f.y)} fill="var(--fire-yellow)" />
                <path d={sparkPath(f.w)} fill="var(--fire-white)" />
              </g>
            ))}
            {EMBERS.map((e, i) => (
              <path
                key={i}
                className="dtn-pb-ember"
                d="M0 0h1v1h-1z"
                fill={i === 1 ? 'var(--fire-orange)' : 'var(--fire-yellow)'}
                style={{ '--ex': e.ex, '--ey': e.ey, animationDelay: e.delay } as CSSProperties}
              />
            ))}
          </g>
        </g>
      </g>
    </svg>
  )
}

const SEQ_MS = 8300 // stage fade completes at 8300 (CSS: 7900 + 400)
const REDUCED_MS = 1150 // static dim+stamp, fade ends 1080; ≤1.2s incl. timer slop
const BLAST_MS = 5300
const LOCK_MS = 6250

// Deterministic LCG so QA screenshots repeat exactly.
function lcg(seed: number) {
  let s = seed >>> 0
  return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296)
}

const DEBRIS = (() => {
  const r = lcg(7)
  return Array.from({ length: 16 }, (_, i) => {
    const a = -Math.PI * (0.05 + 0.9 * r())
    const d = 140 + r() * 320
    return {
      dx: Math.round(Math.cos(a) * d),
      dy: Math.round(Math.sin(a) * d),
      size: 5 + Math.round(r() * 7),
      tone: i % 3,
      delay: Math.round(r() * 120),
    }
  })
})()

// ESCAPE: the ladder's winners rocket away to safety before the blast.
// Newest seat first (the ladder lists the newest ticket at the top); the last
// one clears the top of the screen before BLAST_MS. The rocket itself is a
// chunky pixel capsule drawn in detonation.css at ROCKET_ART grid pixels
// scaled by --rpx screen px each, with the seat's pepe in the porthole; its
// exhaust is the blast's own pixel smoke puff (dtn-puff — one smoke system,
// two emitters), spawned at the nozzle on a timer while it flies.
const ESCAPE_MS = 1650
const ESCAPE_STAGGER = 170
const ESCAPE_MS_EACH = 1900 // 520ms on the pad (flame lit, shivering), 1380ms of flight — slow enough to read the faces
// exhaust schedule (ms after a rocket's launch): two ignition puffs on the
// pad, then a trail puff every PUFF_EVERY from liftoff (29% of the flight)
// until just before the top of the screen
const PUFF_PAD_AT = [60, 170]
const PUFF_FLY_FROM = 520
const PUFF_EVERY = 80
const PUFF_DUR = 640 // one exhaust puff's lifetime
const PUFF_CAP = 48 // live dynamic puffs; + 12 static blast puffs ≤ 60 nodes

interface Escapee {
  x: number
  y: number
  /** the seat's own pepe (the ladder row's WalletPepeArt svg), else a
      deterministic decorative pepe so the lab and empty boards still flee
      as recognizable pepes */
  svg: string
  /** the real ladder art, hidden once its rocket leaves */
  art?: HTMLElement
  launch: number
  dx: number
  rise: number
  tilt: number
}

/**
 * The seats that flee: the real ladder art when the ladder shows pepes, else
 * (FX lab, an empty board) generated pepe art on the ladder rows or, with no
 * ladder at all, along the lower third. Seats below the fold launch from the
 * bottom edge so every escape crosses the screen.
 */
function escapees(): Escapee[] {
  const vw = window.innerWidth
  const vh = window.innerHeight
  const visible = (el: Element) => el.getBoundingClientRect().width > 0
  const arts = [...document.querySelectorAll<HTMLElement>('.alt-shell .ladder-panel .ladder-row .ladder-art')].filter(visible)
  const rows = [...document.querySelectorAll<HTMLElement>('.alt-shell .ladder-panel .ladder-row')].filter(visible)
  const rand = lcg(19)
  // a decorative face for boards without seat art (fx lab, empty ladder):
  // the same release-2 art lane the site renders when no NFT backs a pepe.
  // renderPepeSvg decodes any dna (PepePicker feeds it keccak-sized ids), so
  // any value in the 2**48 draw space yields a valid, distinct face.
  const pepe = () => {
    const dna = BigInt(Math.floor(rand() * 2 ** 48))
    return renderPepeSvg(dna, DECORATIVE_ART_VERSION)
  }
  const seats: { x: number; y: number; svg: string; art?: HTMLElement }[] = arts.length
    ? arts.map(art => {
      const r = art.getBoundingClientRect()
      return { x: r.left + r.width / 2, y: r.top + r.height / 2, svg: art.innerHTML, art }
    })
    : rows.length
      ? rows.map(row => {
        const r = row.getBoundingClientRect()
        return { x: r.left + 58, y: r.top + r.height / 2, svg: pepe() }
      })
      : Array.from({ length: 8 }, (_, i) => ({ x: vw * (0.1 + 0.8 * (i / 7)), y: vh * 0.7, svg: pepe() }))
  // One launch plane level with the bomb, evenly spaced across it: the
  // escape reads as a squadron line-up, not a scatter of ladder rows.
  const planeY = Math.round(vh * 0.8)
  const n = Math.min(seats.length, 10)
  const inset = vw * (n > 6 ? 0.07 : 0.14)
  return seats.slice(0, 10).map((seat, i) => {
    const x = n === 1 ? vw / 2 : inset + (i * (vw - 2 * inset)) / (n - 1)
    const away = x < vw / 2 ? -1 : 1
    return {
      x: Math.round(x),
      y: planeY,
      svg: seat.svg,
      art: seat.art,
      launch: ESCAPE_MS + i * ESCAPE_STAGGER,
      dx: Math.round(away * vw * (0.06 + 0.16 * rand())),
      // off the top with the whole exhaust trail (the rocket is 80px tall)
      // behind it
      rise: Math.round(planeY + vh * 0.65 + 120),
      tilt: Math.round(away * (6 + 10 * rand())),
    }
  })
}

/** A decaying translate shake: `peak` px, `steps` alternating jolts. */
function shakeFrames(peak: number, steps: number): Keyframe[] {
  const frames: Keyframe[] = [{ transform: 'translate(0px, 0px)' }]
  for (let i = 0; i < steps; i++) {
    const amp = peak * (1 - i / steps)
    const sx = i % 2 ? -1 : 1
    const sy = i % 3 ? 1 : -1
    frames.push({ transform: `translate(${(sx * amp).toFixed(1)}px, ${(sy * amp * 0.7).toFixed(1)}px)` })
  }
  frames.push({ transform: 'translate(0px, 0px)' })
  return frames
}

/** A steady rumble (no decay) for under the bombing. */
function rumbleFrames(amp: number, steps: number): Keyframe[] {
  const r = lcg(3)
  return Array.from({ length: steps }, (_, i) => i === 0 || i === steps - 1
    ? { transform: 'translate(0px, 0px)' }
    : { transform: `translate(${((r() * 2 - 1) * amp).toFixed(1)}px, ${((r() * 2 - 1) * amp).toFixed(1)}px)` })
}

/** Impact origin of the slam ring: the live detonate button, else viewport center. */
function impactOrigin(): { ox: string; oy: string } {
  const el = document.querySelector('.alt-detonate')
  if (el) {
    const r = el.getBoundingClientRect()
    return { ox: `${Math.round(r.left + r.width / 2)}px`, oy: `${Math.round(r.top + r.height / 2)}px` }
  }
  return { ox: '50%', oy: '50%' }
}

export default function DetonationSetPiece({ onDone }: { onDone: () => void }) {
  const [reduced] = useState(() => window.matchMedia('(prefers-reduced-motion: reduce)').matches)
  const [origin] = useState(impactOrigin)
  // the blast point (whole pixels, so the pixel bomb sitting on it stays
  // crisp); the pepe confetti bursts from the cloud's two flanks
  const [blastAt] = useState(() => ({
    x: Math.round(window.innerWidth / 2),
    y: Math.round(window.innerHeight * 0.8),
    flank: Math.min(window.innerWidth * 0.2, 300),
    // screen pixels per bomb art pixel
    bpx: window.innerWidth < 700 ? 3 : 4,
  }))
  // the winners who flee (read off the live ladder at mount); none under
  // reduced motion
  const [rockets] = useState(() => (reduced ? [] : escapees()))
  // the blast's own smoke emitter: a deterministic base-surge ring of the
  // SAME pixel puff the rockets trail (dtn-puff), bursting outward around
  // the bomb as the cloud erupts
  const [blastPuffs] = useState(() => {
    const r = lcg(23)
    return Array.from({ length: 12 }, (_, i) => ({
      dx: Math.round((r() * 2 - 1) * Math.max(blastAt.flank, 60)),
      dy: Math.round(-(14 + r() * 60)),
      size: 26 + Math.round(r() * 20),
      delay: Math.round(i * 32 + r() * 40),
      dur: 1100 + Math.round(r() * 300),
      dark: r() < 0.4,
    }))
  })
  const stageRef = useRef<HTMLDivElement | null>(null)
  const quakeRef = useRef<HTMLDivElement | null>(null)
  const clockRef = useRef<HTMLSpanElement | null>(null)
  const boomHostRef = useRef<HTMLDivElement | null>(null)
  const trailHostRef = useRef<HTMLSpanElement | null>(null)
  const sparkRef = useRef<SVGGElement | null>(null)

  // Anchor the stamp to the clock's LAYOUT box (offset* — immune to the slam
  // animation's scale, which getBoundingClientRect would report). The glyph
  // grazes the lower-right corner so the digits stay legible.
  useLayoutEffect(() => {
    const clock = clockRef.current
    const stage = stageRef.current
    if (!clock || !stage) return
    // keep the rotated seal's bounding box (~±95px) inside the viewport; when
    // the viewport forces the anchor inward (narrow screens), hang the seal
    // below the clock's corner instead of over the seconds digits
    const wantSx = clock.offsetLeft + clock.offsetWidth + 18
    const sx = Math.min(wantSx, window.innerWidth - 95)
    const clamped = sx < wantSx - 1
    stage.style.setProperty('--sx', `${sx}px`)
    stage.style.setProperty(
      '--sy',
      `${clock.offsetTop + clock.offsetHeight - 40 + (clamped ? 86 : 0)}px`,
    )
  }, [])
  const onDoneRef = useRef(onDone)
  onDoneRef.current = onDone
  const skipRef = useRef<() => void>(() => {})

  useEffect(() => {
    const timers: number[] = []
    const anims: Animation[] = [] // page mutations — cancelled at finish
    const fades: Animation[] = [] // the stage's own exit — kept until unmount
    const puffRemovals: number[] = [] // exhaust backstops — only unmount cancels
    let finished = false
    // The 3D cloud: created as soon as its chunk lands (shaders compile during
    // the alarm), started just before the blast, disposed on finish/unmount.
    // Not ready by the blast → this run keeps the CSS cloud.
    let boom: Boom | null = null
    let boomOff = reduced
    const dropBoom = () => {
      boomOff = true
      boom?.dispose()
      boom = null
    }

    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') finish()
    }
    const finish = () => {
      if (finished) return
      finished = true
      timers.forEach(clearTimeout)
      window.removeEventListener('keydown', onKey)
      dropBoom()
      // Restore the real page immediately: at natural finish the stage is
      // already invisible, and a slow parent must never leave the shell
      // shaken or the ladder gray.
      anims.forEach(a => a.cancel())
      if (stageRef.current) stageRef.current.style.pointerEvents = 'none'
      onDoneRef.current()
    }
    window.addEventListener('keydown', onKey)
    skipRef.current = finish

    const at = (ms: number, run: () => void) => timers.push(window.setTimeout(run, ms))
    if (!reduced) {
      // The scene's clock is the stage's own CSS exit animation, so the 3D
      // stays frame-locked to the CSS beats (and to paused/seeked QA frames).
      const stage = stageRef.current
      const t0 = performance.now()
      let stageAnim: Animation | undefined
      const clock = () => {
        stageAnim ??= stage
          ?.getAnimations()
          .find(a => a instanceof CSSAnimation && a.animationName === 'dtn-stage-out')
        return (stageAnim ? Number(stageAnim.currentTime) : performance.now() - t0) - BLAST_MS
      }
      // The spark burns down the fuse one art pixel at a time (tip → collar),
      // in step with the rope pixels' CSS burn delays. Kept to unmount like
      // the fades: the stage is still on screen between a skip and unmount.
      const spark = sparkRef.current?.animate(
        [...PIXEL_BOMB.fuse].reverse().map(([x, y]) => ({ transform: `translate(${x}px, ${y}px)`, easing: 'steps(1, end)' })),
        { duration: FUSE_OUT - FUSE_LIT, delay: FUSE_LIT, fill: 'both' },
      )
      if (spark) fades.push(spark)
      loadBoom3d()
        .then(({ createBoom }) => {
          const host = boomHostRef.current
          if (boomOff || !host || !stage) return
          boom = createBoom({
            host,
            clock,
            groundFrac: blastAt.y / window.innerHeight,
            // the fireball ignites exactly where the pixel bomb's body sits
            ignite: { up: (BOMB_GROUND - BOMB_CY) * blastAt.bpx, radius: BOMB_R * blastAt.bpx },
          })
          stage.dataset.boom = '3d'
        })
        .catch(() => {
          // no WebGL2, or the chunk failed to load: the CSS cloud plays
        })
      at(BLAST_MS - 40, () => {
        if (boom) boom.start()
        else boomOff = true
      })
      // Page + stage shake together. No fill, so the transform is restored
      // exactly at the end of each stage.
      const quake = (frames: Keyframe[], duration: number, easing: string) => {
        for (const el of [document.querySelector('.alt-shell'), quakeRef.current]) {
          if (el) anims.push(el.animate(frames, { duration, easing }))
        }
      }
      at(1000, () => quake(shakeFrames(12, 9), 500, 'linear'))
      // the launch rumble under the escape
      at(1800, () => quake(rumbleFrames(3, 24), 2600, 'linear'))
      // each escaping seat's real ladder art empties as its rocket leaves the
      // pad (restored with the rest of the page on finish)
      for (const r of rockets) {
        if (r.art) anims.push(r.art.animate([{ opacity: 0 }, { opacity: 0 }], { duration: 1, delay: r.launch, fill: 'forwards' }))
      }
      // Rocket exhaust: the SAME pixel puff the blast emits (dtn-puff — one
      // smoke system, two emitters), spawned at each nozzle on a timer while
      // its rocket sits on the pad and climbs. Live nodes are capped; each
      // puff removes itself on animationend, with a timeout backstop, so a
      // skip can never strand smoke.
      const prand = lcg(31)
      const puffHost = trailHostRef.current
      const rocketEls = [...(stageRef.current?.querySelectorAll<HTMLElement>('.dtn-rocket') ?? [])]
      let livePuffs = 0
      const spawnPuff = (x: number, y: number) => {
        if (!puffHost || livePuffs >= PUFF_CAP) return
        livePuffs++
        const el = document.createElement('span')
        el.className = 'dtn-puff'
        el.style.left = `${Math.round(x)}px`
        el.style.top = `${Math.round(y)}px`
        const dur = PUFF_DUR + Math.round(prand() * 160)
        el.style.setProperty('--pz', `${9 + Math.round(prand() * 8)}px`)
        el.style.setProperty('--pdx', `${Math.round(prand() * 26 - 13)}px`)
        el.style.setProperty('--pdy', `${Math.round(6 + prand() * 26)}px`)
        el.style.animationDuration = `${dur}ms`
        if (prand() < 0.35) {
          el.style.setProperty('--pt', 'var(--boom-smoke-1)')
          el.style.setProperty('--pt-hi', 'var(--boom-smoke-2)')
        }
        let gone = false
        const retire = () => {
          if (gone) return
          gone = true
          livePuffs--
          el.remove()
        }
        el.addEventListener('animationend', retire, { once: true })
        puffRemovals.push(window.setTimeout(retire, dur + 560))
        puffHost.appendChild(el)
      }
      rockets.forEach((r, i) => {
        const el = rocketEls[i]
        if (!el) return
        for (const pad of PUFF_PAD_AT) {
          at(r.launch + pad, () => {
            const b = el.getBoundingClientRect()
            spawnPuff(b.left + b.width / 2 + (prand() * 8 - 4), b.bottom - 12)
          })
        }
        for (let t = PUFF_FLY_FROM; t <= ESCAPE_MS_EACH - 60; t += PUFF_EVERY) {
          at(r.launch + t, () => {
            const b = el.getBoundingClientRect()
            spawnPuff(b.left + b.width / 2 + (prand() * 10 - 5), b.bottom - 10)
          })
        }
      })
      at(BLAST_MS, () => quake(shakeFrames(18, 12), 800, 'linear'))
      // Ladder lock: grayscale sweep across the real rows, left→right (row
      // order). cancel() on finish restores them.
      at(LOCK_MS, () => {
        document
          .querySelectorAll<HTMLElement>('.alt-shell .ladder-panel .ladder-row')
          .forEach((row, i) => {
            anims.push(
              row.animate(
                [{ filter: 'grayscale(0)' }, { filter: 'grayscale(1) brightness(0.85)' }],
                { duration: 240, delay: i * 40, easing: 'ease-out', fill: 'forwards' },
              ),
            )
          })
      })
    } else {
      // Reduced motion: the stage already renders as a static dim + stamp;
      // exit with a short opacity fade only.
      at(950, () => {
        const fade = stageRef.current?.animate([{ opacity: 1 }, { opacity: 0 }], {
          duration: 200,
          fill: 'forwards',
        })
        if (fade) fades.push(fade)
      })
    }

    at(reduced ? REDUCED_MS : SEQ_MS, finish)
    return () => {
      timers.forEach(clearTimeout)
      puffRemovals.forEach(clearTimeout)
      window.removeEventListener('keydown', onKey)
      dropBoom()
      anims.forEach(a => a.cancel())
      fades.forEach(a => a.cancel())
    }
  }, [reduced, blastAt, rockets])

  return (
    <div
      ref={stageRef}
      className="dtn-stage"
      role="presentation"
      aria-hidden="true"
      data-reduced={reduced || undefined}
      style={{ '--ox': origin.ox, '--oy': origin.oy, '--bx': `${blastAt.x}px`, '--by': `${blastAt.y}px` } as CSSProperties}
      onClick={() => skipRef.current()}
    >
      <div ref={quakeRef} className="dtn-quake">
        <span className="dtn-dim" />
        <span className="dtn-alarm" />
        <span className="dtn-siren dtn-siren-l" />
        <span className="dtn-siren dtn-siren-r" />
        {/* CSS fallback cloud; stands down once the 3D scene is ready (data-boom) */}
        <div className="dtn-mush">
          <div className="dtn-mush-skirt" />
          <div className="dtn-mush-stem" />
          <div className="dtn-mush-head">
            <div className="dtn-mush-glow" />
            <div className="dtn-mush-cap" />
          </div>
        </div>
        {!reduced && <div ref={boomHostRef} className="dtn-boom" />}
        {/* the blast's smoke emitter: a base-surge ring of the same pixel
            puff the rockets trail (dtn-puff), bursting outward around the
            bomb as the cloud erupts */}
        {!reduced && (
          <span className="dtn-puffs dtn-puffs-blast">
            {blastPuffs.map((p, i) => (
              <span
                key={`bp${i}`}
                className="dtn-puff"
                style={{
                  left: blastAt.x,
                  top: blastAt.y,
                  '--pz': `${p.size}px`,
                  '--pdx': `${p.dx}px`,
                  '--pdy': `${p.dy}px`,
                  ...(p.dark ? { '--pt': 'var(--boom-smoke-1)', '--pt-hi': 'var(--boom-smoke-2)' } : {}),
                  animationDelay: `${BLAST_MS + 40 + p.delay}ms`,
                  animationDuration: `${p.dur}ms`,
                } as CSSProperties}
              />
            ))}
          </span>
        )}
        {/* the bomb the button promised: it drops onto the blast point after
            the alarm, fuse burning, rocks while the winners flee, goes white
            and bursts into the cloud — whose fireball ignites at its exact
            center and size. The 3D canvas stays invisible until its loop
            starts. Static under reduced motion. */}
        <span
          className="dtn-pixel-bomb"
          style={{ '--bpx': `${blastAt.bpx}px`, '--bax': BOMB_CX, '--bay': BOMB_GROUND, '--bcy': BOMB_CY, '--baw': BOMB_W, '--bah': BOMB_H } as CSSProperties}
        >
          <PixelBomb sparkRef={sparkRef} />
        </span>
        {/* the ladder's winners rocket away to safety, newest seat first:
            a chunky pixel capsule (stepped nose, banded hull, fins) with the
            seat's own pepe in the porthole */}
        {rockets.map((r, i) => (
          <span
            key={`r${i}`}
            className="dtn-rocket"
            style={{
              left: r.x,
              top: r.y,
              '--rx': `${r.dx}px`,
              '--ry': `${-r.rise}px`,
              '--rt': `${r.tilt}deg`,
              animationDuration: `${ESCAPE_MS_EACH}ms`,
              animationDelay: `${r.launch}ms`,
            } as CSSProperties}
          >
            <span className="dtn-rocket-body">
              <span className="dtn-rocket-window" dangerouslySetInnerHTML={{ __html: r.svg }} />
            </span>
            <span className="dtn-rocket-flame" />
          </span>
        ))}
        {/* the rockets' exhaust emitter: the TSX spawns dtn-puff nodes here
            at each nozzle while the rockets fly (capped, self-removing) */}
        <span ref={trailHostRef} className="dtn-puffs dtn-puffs-trail" />
        <span className="dtn-ring" />
        {/* the stamp rides the slam card, so the blast's knock-back carries both */}
        <div className="dtn-slam">
          <span ref={clockRef} className="dtn-clock">00:00:00</span>
          <span className="dtn-stamp">✓</span>
        </div>
        <span className="dtn-ground-ring" />
        <span className="dtn-shock" />
        {DEBRIS.map((p, i) => (
          <span
            key={`d${i}`}
            className="dtn-debris"
            data-tone={p.tone}
            style={{ '--dx': `${p.dx}px`, '--dy': `${p.dy}px`, '--dd': `${BLAST_MS + 100 + p.delay}ms`, width: p.size, height: p.size } as CSSProperties}
          />
        ))}
        {!reduced && (
          <div className="dtn-confetti">
            <PepeConfetti mood="sad" at={{ x: blastAt.x - blastAt.flank, y: blastAt.y }} faces={11} bits={4} delay={BLAST_MS + 220} stagger={420} power={1.5} seed={11} />
            <PepeConfetti mood="sad" at={{ x: blastAt.x + blastAt.flank, y: blastAt.y }} faces={11} bits={4} delay={BLAST_MS + 300} stagger={420} power={1.5} seed={29} />
          </div>
        )}
        <span className="dtn-tape dtn-tape-top" />
        <span className="dtn-tape dtn-tape-bottom" />
        <span className="dtn-blast" />
        <span className="dtn-flash" />
      </div>
    </div>
  )
}
