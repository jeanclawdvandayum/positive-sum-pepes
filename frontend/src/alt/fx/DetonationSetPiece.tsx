// ─────────────────────────────────────────────────────────────────────────────
// DetonationSetPiece — the carpet-bomb set piece (PLAN Feature 4).
//
// Rendered by ActionFxLayer for kind 'detonate' (FxLab's mock stage can mount
// it too). It is the ONLY overlay allowed to catch input: a click or Esc
// skips it, and it auto-ends in ≤3s. Timeline (ms):
//   0–120     screen dims to 70% black
//   100–190   white flash (peak ~110ms)
//   170–420   clock slams to 00:00:00 (Segment face, scale 2.4→.92→1.04→1,
//             hard glow)
//   300–820   shockwave ring + pixel debris from the button (--ox/--oy);
//             page shake (decaying ±6px translate on .alt-shell via
//             element.animate, restored after) and the same keyframe curve
//             on the slam card so the whole frame jolts together
//   600–1875  carpet bombing: 12 pixel bombs (22px, amber-rimmed, fall
//             streak) drop in parallel diagonally, staggered left→right,
//             landing on one diagonal line, each with a 56px impact burst
//   1800–2280 ladder rows lock (grayscale sweep via element.animate on the
//             real .ladder-panel rows, if present) + stamp glyph hit on the
//             clock's corner; dim relaxes 0.7→0.45 so the handoff reads
//   2700–2900 stage fades out → onDone
//
// prefers-reduced-motion: static dim + stamp, JS opacity fade ≤1.2s — no
// shake, no particles. PhaseEngine keeps its rAF monopoly: everything here is
// CSS keyframes or element.animate, animating transform/opacity/filter only.
// Particle nodes: 12 debris + 12 bombs + 12 impacts = 36 (≤40). Timers and
// Animation handles are all cleaned up on unmount/skip and the real page
// elements (.alt-shell transform, ladder filters) are restored.
// ─────────────────────────────────────────────────────────────────────────────

import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import type { CSSProperties } from 'react'

const SEQ_MS = 2900 // fade completes at 2900 (CSS: 2700+200); ≤3s incl. timer slop
const REDUCED_MS = 1150 // static dim+stamp, fade ends 1080; ≤1.2s incl. timer slop

// Deterministic LCG so QA screenshots repeat exactly.
function lcg(seed: number) {
  let s = seed >>> 0
  return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296)
}

const DEBRIS = (() => {
  const r = lcg(7)
  return Array.from({ length: 12 }, (_, i) => {
    const a = r() * Math.PI * 2
    const d = 80 + r() * 200
    return {
      dx: Math.round(Math.cos(a) * d),
      dy: Math.round(Math.sin(a) * d - 40),
      size: 3 + Math.round(r() * 5),
      tone: i % 3,
    }
  })
})()

const FALL_MS = 450
// One carpet line: bombs fall in parallel (--jx fixed) and land on a single
// diagonal sweeping left→right.
const BOMBS = Array.from({ length: 12 }, (_, i) => ({
  left: `${(i + 0.5) * (100 / 12)}%`,
  top: `${56 + i * 1.4}vh`,
  delay: `${600 + i * 75}ms`,
}))

/** Impact origin: the live detonate button, else viewport center. */
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
  const stageRef = useRef<HTMLDivElement | null>(null)
  const clockRef = useRef<HTMLSpanElement | null>(null)

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
    let finished = false

    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') finish()
    }
    const finish = () => {
      if (finished) return
      finished = true
      timers.forEach(clearTimeout)
      window.removeEventListener('keydown', onKey)
      // Restore the real page immediately: at natural finish the stage is
      // already invisible, and a slow parent must never leave the shell
      // shaken or the ladder gray.
      anims.forEach(a => a.cancel())
      if (stageRef.current) stageRef.current.style.pointerEvents = 'none'
      onDoneRef.current()
    }
    window.addEventListener('keydown', onKey)
    skipRef.current = finish

    if (!reduced) {
      // 300ms — page shake on the impact frame: decaying ±6px translate on
      // the shell. No fill, so the transform is restored exactly at the end.
      timers.push(
        window.setTimeout(() => {
          const shell = document.querySelector('.alt-shell')
          if (!shell) return
          anims.push(
            shell.animate(
              [
                { transform: 'translate(0px, 0px)' },
                { transform: 'translate(6px, -4px)' },
                { transform: 'translate(-6px, 5px)' },
                { transform: 'translate(5px, 3px)' },
                { transform: 'translate(-4px, -3px)' },
                { transform: 'translate(3px, 2px)' },
                { transform: 'translate(-2px, -1px)' },
                { transform: 'translate(1px, 1px)' },
                { transform: 'translate(0px, 0px)' },
              ],
              { duration: 520, easing: 'ease-out' },
            ),
          )
        }, 300),
      )
      // 1800ms — ladder lock: grayscale sweep across the real rows,
      // left→right. cancel() on cleanup restores them.
      timers.push(
        window.setTimeout(() => {
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
        }, 1800),
      )
    } else {
      // Reduced motion: the stage already renders as a static dim + stamp;
      // exit with a short opacity fade only.
      timers.push(
        window.setTimeout(() => {
          const fade = stageRef.current?.animate([{ opacity: 1 }, { opacity: 0 }], {
            duration: 200,
            fill: 'forwards',
          })
          if (fade) fades.push(fade)
        }, 950),
      )
    }

    timers.push(window.setTimeout(finish, reduced ? REDUCED_MS : SEQ_MS))
    return () => {
      timers.forEach(clearTimeout)
      window.removeEventListener('keydown', onKey)
      anims.forEach(a => a.cancel())
      fades.forEach(a => a.cancel())
    }
  }, [reduced])

  return (
    <div
      ref={stageRef}
      className="dtn-stage"
      role="presentation"
      aria-hidden="true"
      data-reduced={reduced || undefined}
      style={{ '--ox': origin.ox, '--oy': origin.oy } as CSSProperties}
      onClick={() => skipRef.current()}
    >
      <span className="dtn-dim" aria-hidden="true" />
      <span className="dtn-flash" aria-hidden="true" />
      <div className="dtn-slam" aria-hidden="true">
        <span ref={clockRef} className="dtn-clock">00:00:00</span>
      </div>
      <span className="dtn-ring" aria-hidden="true" />
      {DEBRIS.map((p, i) => (
        <span
          key={i}
          className="dtn-debris"
          data-tone={p.tone}
          style={{ '--dx': `${p.dx}px`, '--dy': `${p.dy}px`, width: p.size, height: p.size } as CSSProperties}
        />
      ))}
      {BOMBS.map((b, i) => (
        <span
          key={i}
          className="dtn-bomb-drop"
          style={{ left: b.left, top: b.top, '--d': b.delay } as CSSProperties}
        />
      ))}
      {BOMBS.map((b, i) => (
        <span
          key={i}
          className="dtn-impact"
          style={{ left: b.left, top: b.top, '--id': `${600 + i * 75 + FALL_MS}ms` } as CSSProperties}
        />
      ))}
      <span className="dtn-stamp" aria-hidden="true">
        ✓
      </span>
    </div>
  )
}
