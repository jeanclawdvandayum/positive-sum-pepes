// ─────────────────────────────────────────────────────────────────────────────
// Clock — THE instrument (REDESIGN-B0 item 3, spec §1/§2/§4/§8)
//
// DSEG7 numerals over a radial phosphor glow (the only sanctioned gradient),
// breathing at a phase-scaled rate, sub-10 breathing scale 1.00→1.015,
// +5:00 injection flash with floating chip, phase WORD alongside (WCAG).
// The panel stays dark in both themes — it's the machine's screen.
// Updates ride PhaseEngine's single rAF loop via imperative textContent
// writes: no per-second React re-renders, no per-component intervals.
// prefers-reduced-motion: CSS kills breathing/roll/float; digits update
// instantly and flashes degrade to color-only (see tokens.css).
// ─────────────────────────────────────────────────────────────────────────────

import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import {
  getRemainingMs,
  subscribeFrames,
  subscribeInjections,
  usePhase,
  type Phase,
} from '../phase/PhaseEngine'

const PHASE_WORD: Record<Phase, string> = { calm: 'calm', heat: 'heating', critical: 'critical' }

const LAYOUT_LEN = 8 // "HH:MM:SS"
const IDLE = '72:00:00' // pre-launch, dimmed (spec §8)
const GHOST = '88:88:88' // unlit seven-segment segments

function fmtClock(ms: number): string {
  const t = Math.min(99 * 3600 + 59 * 60 + 59, Math.floor(Math.max(0, ms) / 1000))
  const h = Math.floor(t / 3600)
  const m = Math.floor((t % 3600) / 60)
  const s = t % 60
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`
}

function fmtDelta(ms: number): string {
  const t = Math.floor(ms / 1000)
  const m = Math.floor(t / 60)
  const s = t % 60
  return `+${m}:${String(s).padStart(2, '0')}`
}

export default function Clock({
  variant = 'full',
  className = '',
}: {
  variant?: 'full' | 'mini'
  className?: string
}) {
  const { phase, hasDeadline } = usePhase()
  const digitRefs = useRef<(HTMLSpanElement | null)[]>([])
  const prevStr = useRef<string>(hasDeadline ? fmtClock(getRemainingMs()) : IDLE)
  const flashPending = useRef(false)
  const chipSeq = useRef(0)
  const chipTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)
  const [chip, setChip] = useState<{ ms: number; seq: number } | null>(null)

  // live value: subscribe to the engine's ONE rAF loop, write digits in place
  useLayoutEffect(() => {
    const write = () => {
      const str = hasDeadline ? fmtClock(getRemainingMs()) : IDLE
      const prev = prevStr.current
      for (let i = 0; i < LAYOUT_LEN; i++) {
        const el = digitRefs.current[i]
        if (!el) continue
        if (str[i] !== prev[i]) el.textContent = str[i]
        if (flashPending.current && str[i] !== prev[i] && str[i] !== ':') {
          // time injection: the freshly added minutes flash in accent (§4.3)
          el.classList.remove('clock-flash')
          void el.offsetWidth // restart the keyframe
          el.classList.add('clock-flash')
        }
      }
      prevStr.current = str
      flashPending.current = false
    }
    write()
    return subscribeFrames(write)
  }, [hasDeadline])

  // +5:00 injection → flash changed digits on the next frame + float a chip
  useEffect(() => {
    const onInject = (addedMs: number) => {
      flashPending.current = true
      chipSeq.current += 1
      setChip({ ms: addedMs, seq: chipSeq.current })
      if (chipTimer.current) clearTimeout(chipTimer.current)
      chipTimer.current = setTimeout(() => setChip(null), 2200) // PRM fallback clear
    }
    const unsub = subscribeInjections(onInject)
    return () => {
      unsub()
      if (chipTimer.current) clearTimeout(chipTimer.current)
    }
  }, [])

  return (
    <div
      className={`clock clock--${variant} ${hasDeadline ? '' : 'clock--idle'} ${className}`}
      role="timer"
      aria-label={hasDeadline ? 'time until detonation' : 'clock armed at round launch'}
    >
      <div className="clock-glow" aria-hidden="true" />
      <span className="clock-numerals-wrap">
        <span className="clock-numerals">
          <span className="clock-ghost" aria-hidden="true">
            {GHOST}
          </span>
          {Array.from({ length: LAYOUT_LEN }, (_, i) => {
            const ch = prevStr.current[i] ?? '0'
            return ch === ':' ? (
              <span
                key={i}
                className="clock-colon"
                ref={(el) => {
                  digitRefs.current[i] = el
                }}
              >
                :
              </span>
            ) : (
              <span
                key={i}
                className="clock-digit"
                ref={(el) => {
                  digitRefs.current[i] = el
                }}
              >
                {ch}
              </span>
            )
          })}
        </span>
        {chip && (
          <span key={chip.seq} className="clock-chip" onAnimationEnd={() => setChip(null)}>
            {fmtDelta(chip.ms)}
          </span>
        )}
      </span>
      <span className={hasDeadline ? 'clock-word' : 'clock-word clock-word--armed'}>{hasDeadline ? PHASE_WORD[phase] : 'armed'}</span>
    </div>
  )
}
