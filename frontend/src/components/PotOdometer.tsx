// ─────────────────────────────────────────────────────────────────────────────
// PotOdometer — the pot must visibly grow (REDESIGN-B0 item 4, spec §4.2)
//
// Mechanical digit roll (each digit rides a 0–9 track that translates into
// place) + a brief gold flash on changed digits. Tabular mono so numbers
// never reflow. Accepts a value (bigint wad / number / preformatted string)
// and a unit. React state is fine here: pot updates are data-driven events,
// not per-frame. prefers-reduced-motion: rolls become instant swaps; the
// gold flash (color-only) survives (tokens.css).
// ─────────────────────────────────────────────────────────────────────────────

import { useEffect, useRef, useState, type CSSProperties } from 'react'
import { fmtAmount } from '../lib/format'

function OdoDigit({ d }: { d: string }) {
  const [flash, setFlash] = useState(false)
  const prev = useRef(d)

  useEffect(() => {
    if (prev.current === d) return
    prev.current = d
    setFlash(true)
    const t = setTimeout(() => setFlash(false), 750)
    return () => clearTimeout(t)
  }, [d])

  return (
    <span className={`odo-digit ${flash ? 'odo-flash' : ''}`}>
      <span className="odo-track" style={{ transform: `translateY(-${d}em)` } as CSSProperties}>
        {'0123456789'.split('').map((n) => (
          <span key={n}>{n}</span>
        ))}
      </span>
    </span>
  )
}

function toText(value: string | number | bigint | undefined): string {
  if (value === undefined) return ''
  if (typeof value === 'bigint') return fmtAmount(value)
  if (typeof value === 'number') return value.toLocaleString('en-US')
  return value
}

export default function PotOdometer({
  value,
  unit,
  className = '',
  title,
}: {
  /** pot size — bigint wads run through fmtAmount; strings pass through as-is */
  value: string | number | bigint | undefined
  /** e.g. "mix" — rendered small in text-lo beside the number */
  unit?: string
  className?: string
  title?: string
}) {
  const text = toText(value)
  const cells = Array.from(text)

  return (
    <span className={`odo ${className}`} title={title} aria-label={text || 'loading'}>
      {cells.map((ch, i) =>
        ch >= '0' && ch <= '9' ? (
          <OdoDigit key={i} d={ch} />
        ) : (
          <span key={i} className="odo-sep">
            {ch}
          </span>
        ),
      )}
      {unit && <span className="odo-unit">{unit}</span>}
    </span>
  )
}
