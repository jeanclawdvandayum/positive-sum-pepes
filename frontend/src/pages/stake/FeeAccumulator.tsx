// ─────────────────────────────────────────────────────────────────────────────
// FeeAccumulator — FEES EARNED THIS ROUND, live-ticking (REDESIGN-B3 item 1:
// "this counter is the page's emotional core and the strongest revisit reason").
//
// NO new chain reads: it consumes the existing pendingFeesOf lane (6s batched
// updates) and smooth-interpolates between readings — DECIDED (2026-08-31):
//   · each fresh reading re-anchors the counter and re-derives the accrual
//     rate from a ~12-reading window (~72s), so trade-fee lumps become a
//     steady drip
//   · extrapolation is capped just past one poll interval — if the RPC stalls
//     or backs off, the counter HOLDS instead of faking growth (no fake
//     liveness, red-line)
//   · a drop between readings = a claim landed → history resets, counter
//     restarts from truth (claims reset the counter; nothing is lost)
//   · disconnected → the designed empty state, never a frozen number
// Display rides PhaseEngine's shared whole-second heartbeat (useNow) — no
// private interval, no per-frame work. Tabular mono: numbers never reflow.
// ─────────────────────────────────────────────────────────────────────────────

import { useEffect, useRef } from 'react'
import Skeleton from '../../components/Skeleton'

interface Reading {
  v: bigint
  t: number
}

const WINDOW = 12 // readings kept (~72s at the 6s cadence)

function fmtAccum(n: number): string {
  if (!Number.isFinite(n) || n <= 0) return '0.00000000'
  if (n < 0.001) return n.toFixed(8) // sub-milli drips stay visible while tiny
  return n.toLocaleString('en-US', { minimumFractionDigits: 6, maximumFractionDigits: 6 })
}

export default function FeeAccumulator({
  value,
  connected,
  hasStake,
}: {
  /** Σ pendingFeesOf across the wallet's pepes (existing 6s lane) */
  value: bigint | undefined
  connected: boolean
  hasStake: boolean
}) {
  const hist = useRef<Reading[]>([])

  useEffect(() => {
    if (value === undefined) return // rpc hiccup → keep the last anchor
    const t = Date.now()
    const h = hist.current
    if (h.length > 0 && value < h[h.length - 1].v) h.length = 0 // claim landed
    h.push({ v: value, t })
    if (h.length > WINDOW) h.splice(0, h.length - WINDOW)
  }, [value])

  // designed empty states (spec §8 voice)
  if (!connected) {
    return (
      <div>
        <div className="text-xs text-text-lo">fees earned this round</div>
        <p className="mt-2 max-w-[26rem] text-sm leading-relaxed text-text-lo">
          connect a wallet and this counter ticks your cut of every trade.
        </p>
      </div>
    )
  }
  if (!hasStake) {
    return (
      <div>
        <div className="text-xs text-text-lo">fees earned this round</div>
        <p className="mt-2 max-w-[26rem] text-sm leading-relaxed text-text-lo">
          stake a pepe — the counter starts with the first lock.
        </p>
      </div>
    )
  }

  const h = hist.current
  const anchor = h.length > 0 ? h[h.length - 1] : undefined

  // HONEST COUNTER (2026-09-03 playtest fix): the old extrapolated drip
  // (windowed rate × capped elapsed) ticked ABOVE the chain's real pending —
  // a claim then paid less than the number on screen. The counter now shows
  // the LAST REAL READING and moves only when the chain moves (6s lane);
  // claims reset it. No invented liveness.
  const display = anchor !== undefined ? Number(anchor.v) / 1e18 : 0
  const idle = anchor === undefined ? false : anchor.v === 0n
  const formatted = fmtAccum(display)

  return (
    <div className="min-w-0" style={{ containerType: 'inline-size' }}>
      <div className="text-xs text-text-lo">fees earned this round</div>
      {anchor === undefined ? (
        <Skeleton className="mt-2 h-10 w-60 max-w-full" />
      ) : (
        <>
          <div
            className="st-accum mt-2 pr-2"
            // Size against this column, keeping every digit plus right padding.
            style={{ fontSize: `min(2.25rem, calc((100cqi - 0.5rem) / ${formatted.length * 0.62}))` }}
            role="timer"
            aria-label="fees earned this round, ticking"
          >
            {formatted}
          </div>
          <div className="mt-1.5 text-xs text-text-lo">
            {idle ? 'mixETH · waiting for the next trade' : 'mixETH · ticking between updates — claims reset the counter'}
          </div>
        </>
      )}
    </div>
  )
}
