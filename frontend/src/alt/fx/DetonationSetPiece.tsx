// ─────────────────────────────────────────────────────────────────────────────
// DetonationSetPiece — the carpet-bomb set piece (PLAN Feature 4).
//
// Rendered by ActionFxLayer for kind 'detonate' (FxLab's mock stage can mount
// it too). One of two FX overlays that catch input: a click or Esc skips it at
// any beat, and it auto-ends at 5.6s. Timeline (ms):
//   0–900      ALARM: dim ramps in, three red vignette pulses, hazard tape
//              slides onto the top and bottom edges, two siren beams sweep
//   350–3250   PIXEL BOMB: the site's bomb icon sits at the blast point with
//              its spark burning down the fuse; at the blast it flashes away
//              and the cloud erupts from it (the 3D canvas only becomes
//              visible once its loop starts, at blast−40ms)
//   900–1000   white flash
//   950–1300   SLAM: 00:00:00 in --time-lit (forced to the critical red)
//              lands from scale 3.4 with a red glow; square shockwave ring
//   1000–1500  shake A: ±12px decaying (page + stage)
//   1600–2450  CARPET pass 1: 12 bombs sweep left→right onto a diagonal
//   2100–2950  CARPET pass 2: 12 bombs sweep right→left, higher line
//   1600–3200  shake B: a ±3px rumble under the bombing
//   3250–3900  BLAST: a screen-filling explosion flash, a full-screen
//              shockwave ring and a ground ring; mushroom cloud rises
//              3300–4200 behind the clock
//   3250–4050  shake C: ±18px decaying
//   3350–5300  DEBRIS: 16 pixel chunks + a burst of rage/angry/sad/meh
//              pepe confetti from the blast
//   4200–4700  LOCK: ladder rows gray out left→right (the real rows) and the
//              stamp hits the clock's corner with a jolt
//   4700–5200  SETTLE: dim relaxes to .45, the cloud and tape leave
//   5200–5600  stage fades out → onDone
//
// prefers-reduced-motion: static dim + clock + stamp, opacity fade ≤1.2s — no
// shake, no particles. PhaseEngine keeps its rAF monopoly: everything here is
// CSS keyframes or element.animate, animating transform/opacity/filter only.
// Particle groups: 24 bombs + 24 impacts, 16 debris, 38 confetti — each burst
// under 50 nodes. Timers and Animation handles are all cleaned up on
// unmount/skip, and the real page (.alt-shell transform, ladder filters) is
// restored.
// ─────────────────────────────────────────────────────────────────────────────

import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import type { CSSProperties } from 'react'
import { PepeConfetti } from './confetti'
import { loadBoom3d } from './boomLoader'
import { PixelIcon } from '../../components/PixelIcon'
import type { Boom } from './boom3d'

const SEQ_MS = 6200 // stage fade completes at 6200 (CSS: 5800 + 400)
const REDUCED_MS = 1150 // static dim+stamp, fade ends 1080; ≤1.2s incl. timer slop
const BLAST_MS = 3250
const LOCK_MS = 4200

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

const FALL_MS = 420
const PER_PASS = 12
/** Two carpet passes: left→right low, then right→left higher, overlapping. */
const BOMBS = [0, 1].flatMap(pass => Array.from({ length: PER_PASS }, (_, i) => {
  const col = pass === 0 ? i : PER_PASS - 1 - i
  const drop = (pass === 0 ? 1600 : 2100) + i * 70
  return {
    left: `${(col + 0.5) * (100 / PER_PASS)}%`,
    // pass 1 carpets the band under the clock, pass 2 the band above it
    top: pass === 0 ? `${62 + col * 1.3}vh` : `${12 + (PER_PASS - 1 - col) * 0.9}vh`,
    jx: pass === 0 ? '-140px' : '140px',
    jr: pass === 0 ? '-50deg' : '50deg',
    drop,
    land: drop + FALL_MS,
  }
}))

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
  // the blast point; the pepe confetti bursts from the cloud's two flanks
  const [blastAt] = useState(() => ({
    x: window.innerWidth / 2,
    y: window.innerHeight * 0.8,
    flank: Math.min(window.innerWidth * 0.2, 300),
  }))
  const stageRef = useRef<HTMLDivElement | null>(null)
  const quakeRef = useRef<HTMLDivElement | null>(null)
  const clockRef = useRef<HTMLSpanElement | null>(null)
  const boomHostRef = useRef<HTMLDivElement | null>(null)

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
      loadBoom3d()
        .then(({ createBoom }) => {
          const host = boomHostRef.current
          if (boomOff || !host || !stage) return
          boom = createBoom({ host, clock, groundFrac: blastAt.y / window.innerHeight })
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
      at(1600, () => quake(rumbleFrames(3, 24), 1600, 'linear'))
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
      window.removeEventListener('keydown', onKey)
      dropBoom()
      anims.forEach(a => a.cancel())
      fades.forEach(a => a.cancel())
    }
  }, [reduced, blastAt])

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
        {/* the bomb the button promised: it sits at the blast point from the
            alarm on, fuse burning, and flashes into the cloud at the blast
            (the 3D canvas stays invisible until its loop starts) */}
        {!reduced && (
          <span className="dtn-pixel-bomb">
            <PixelIcon name="bomb" />
            <span className="dtn-pixel-spark" />
          </span>
        )}
        {BOMBS.map((b, i) => (
          <span
            key={`b${i}`}
            className="dtn-bomb-drop"
            style={{ left: b.left, top: b.top, '--d': `${b.drop}ms`, '--jx': b.jx, '--jr': b.jr } as CSSProperties}
          />
        ))}
        {BOMBS.map((b, i) => (
          <span
            key={`i${i}`}
            className="dtn-impact"
            style={{ left: b.left, top: b.top, '--id': `${b.land}ms` } as CSSProperties}
          />
        ))}
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
