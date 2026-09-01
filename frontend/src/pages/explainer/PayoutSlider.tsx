// ─────────────────────────────────────────────────────────────────────────────
// PayoutSlider — "if the bomb dropped now with a pot of X" (REDESIGN-B1 §3)
//
// Pure client arithmetic: ladder % × pot, nothing touches the chain. The pot
// number rides pot-gold (§1); bars are accent-tinted (ladder shares, not pot);
// numbers are font-data + tabular so they never reflow (§3).
// ─────────────────────────────────────────────────────────────────────────────

import { useId, useState } from 'react'

const LADDER = [25, 18, 14, 10, 8, 7, 6, 5, 4, 3]

export default function PayoutSlider() {
  const [pot, setPot] = useState(100)
  const id = useId()

  return (
    <div className="mt-10">
      <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
        <label htmlFor={id} className="text-text-lo">
          if the bomb dropped now with a pot of
        </label>
        <output htmlFor={id} className="tabular font-data text-lg" style={{ color: 'var(--pot-gold)' }}>
          {pot.toLocaleString('en-US')} mix
        </output>
      </div>

      <input
        id={id}
        type="range"
        min={1}
        max={1000}
        step={1}
        value={pot}
        aria-label="pot size in mixETH"
        onChange={(e) => setPot(Number(e.target.value))}
        className="mt-4 w-full"
        style={{ accentColor: 'var(--accent)' }}
      />

      <div className="mt-6 grid gap-x-10 sm:grid-cols-2">
        {LADDER.map((pct, i) => (
          <div
            key={i}
            className="relative flex items-center gap-3 border-b border-line py-1.5 pl-2"
          >
            <span
              aria-hidden="true"
              className="absolute inset-y-0 left-0"
              style={{
                width: `min(${(pct / 25) * 100}%, 86%)`,
                background: 'color-mix(in srgb, var(--accent) 13%, transparent)',
              }}
            />
            <span className="tabular relative font-data text-sm text-text-lo">#{i + 1}</span>
            <span className="tabular relative font-data text-sm text-text-hi">{pct}%</span>
            <span
              className="tabular relative ml-auto font-data text-sm"
              style={{ color: i === 0 ? 'var(--pot-gold)' : 'var(--text-hi)' }}
            >
              {(pot * pct / 100).toLocaleString('en-US', { maximumFractionDigits: 2 })} mix
            </span>
          </div>
        ))}
      </div>
    </div>
  )
}
