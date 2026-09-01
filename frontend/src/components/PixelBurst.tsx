import { forwardRef, useImperativeHandle, useRef, useState, type CSSProperties } from 'react'

// ─────────────────────────────────────────────────────────────────────────────
// PixelBurst — 4–6 pixel particles off the BUY button on success
// (REDESIGN-B2 §4, spec §4 micro). 400ms, once per fire; reduced-motion
// fires nothing (gated here AND killed in CSS). Imperative handle so the
// swap card can trigger it from its submit flow without state plumbing.
// ─────────────────────────────────────────────────────────────────────────────

export interface BurstHandle {
  fire: () => void
}

// six fixed pixel trajectories — up-and-out fan, deterministic per index
const PARTICLES: { dx: number; dy: number }[] = [
  { dx: -26, dy: -30 },
  { dx: -10, dy: -40 },
  { dx: 8, dy: -36 },
  { dx: 22, dy: -26 },
  { dx: -2, dy: -44 },
  { dx: 16, dy: -18 },
]

export const PixelBurst = forwardRef<BurstHandle, { className?: string }>(
  function PixelBurst({ className = '' }, ref) {
    const [seq, setSeq] = useState(0)
    const [on, setOn] = useState(false)
    const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)

    useImperativeHandle(
      ref,
      () => ({
        fire: () => {
          // no particles under reduced motion (spec §4) — CSS is the backstop
          if (
            typeof window !== 'undefined' &&
            window.matchMedia('(prefers-reduced-motion: reduce)').matches
          )
            return
          setSeq((s) => s + 1)
          setOn(true)
          if (timer.current) clearTimeout(timer.current)
          timer.current = setTimeout(() => setOn(false), 420)
        },
      }),
      [],
    )

    if (!on) return null

    return (
      <span key={seq} className={`pl-burst ${className}`} aria-hidden="true">
        {PARTICLES.map((p, i) => (
          <span
            key={i}
            className="pl-burst-px"
            style={
              {
                '--dx': `${p.dx}px`,
                '--dy': `${p.dy}px`,
                animationDelay: `${(i % 3) * 30}ms`,
              } as CSSProperties
            }
          />
        ))}
      </span>
    )
  },
)

export default PixelBurst
