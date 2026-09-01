// ─────────────────────────────────────────────────────────────────────────────
// TickerBar — one continuous stat strip (REDESIGN-B0 item 5, spec §6:
// "stat strip (volume/fees/reserves/price) = one continuous ticker bar")
//
// AUDIT r1 FIX 5 (render-list dedupe, NOT a data change): with few short
// items the marquee's content period (one copy of the items) was narrower
// than the bar, so the same stat ("price 1.05e-5 mix / psp") was on screen
// twice at once. Rule now: if ONE copy of the items fits the bar, render a
// single static row — every stat appears exactly once. If it overflows,
// run the two-group marquee (-50% forever, second group aria-hidden) — and
// in that regime the content period exceeds the bar, so copies can never
// co-appear either. The `items` prop (labels, values, cadence) is untouched.
// prefers-reduced-motion: the marquee stops (tokens.css); static is already
// still.
// ─────────────────────────────────────────────────────────────────────────────

import { useLayoutEffect, useRef, useState, type CSSProperties, type ReactNode } from 'react'

export interface TickerItem {
  label: string
  value: ReactNode
}

export default function TickerBar({
  items,
  durationMs = 36_000,
  className = '',
}: {
  items: TickerItem[]
  /** one full circuit of the scrolling track; tune to content length */
  durationMs?: number
  className?: string
}) {
  const barRef = useRef<HTMLDivElement>(null)
  const groupRef = useRef<HTMLDivElement>(null)
  // 'scroll' until measured; measurement runs before paint (layout effect)
  const [fits, setFits] = useState<boolean | null>(null)

  useLayoutEffect(() => {
    const bar = barRef.current
    const group = groupRef.current
    if (!bar || !group) return
    const measure = () => {
      const content = group.offsetWidth // exactly one copy of `items`
      const width = bar.clientWidth
      if (content > 0 && width > 0) setFits(content + 8 <= width)
    }
    measure()
    const ro = new ResizeObserver(measure)
    ro.observe(bar)
    ro.observe(group) // font swap / value width changes self-correct
    const onWinResize = () => measure() // belt-and-braces beside the RO
    window.addEventListener('resize', onWinResize)
    return () => {
      ro.disconnect()
      window.removeEventListener('resize', onWinResize)
    }
    // items identity changes every poll in callers — re-measure is cheap and
    // setFits is a no-op render when the layout verdict hasn't flipped
  }, [items])

  if (items.length === 0) return null

  const group = (hidden: boolean) => (
    <div className="ticker-group" aria-hidden={hidden || undefined} ref={hidden ? undefined : groupRef}>
      {items.map((it, i) => (
        <span className="ticker-item" key={i}>
          <span className="ticker-label">{it.label}</span>
          <span className="ticker-value tabular">{it.value}</span>
        </span>
      ))}
    </div>
  )

  const staticRow = fits === true

  return (
    <div
      className={`ticker-bar ${staticRow ? 'ticker-bar--static ' : ''}${className}`}
      role="region"
      aria-label="live round stats"
      ref={barRef}
    >
      <div
        className="ticker-track"
        style={staticRow ? undefined : ({ '--ticker-duration': `${durationMs}ms` } as CSSProperties)}
      >
        {group(false)}
        {!staticRow && group(true)}
      </div>
    </div>
  )
}
