import { useMemo } from 'react'
import { renderPepeSvg } from '../../lib/pepeRender'
import { dnaOfId } from '../../components/PepePicker'
import { fmtAmount } from '../../lib/format'
import type { TapeEntry } from './useTradeTape'

// ─────────────────────────────────────────────────────────────────────────────
// Tape — the slim live activity feed under the clock (REDESIGN-B2 §2).
//
// One-line entries with pepe avatars for buys and sells, newest on top,
// fed by useTradeTape (the StatsPanel getLogs lane). Time injections and
// stake events join when their lanes exist — until then the tape shows
// exactly what the logs say, or its designed §8 empty state. Never a
// spinner.
//
// Avatars are LOCAL derivations: keccak(address) → dna → renderPepeSvg —
// same art data the contract renders, deterministic per address, zero
// chain reads. Placeholder identity until the primaryOf lane ships with
// round wiring.
// ─────────────────────────────────────────────────────────────────────────────

const MAX_ROWS = 3

const avatars = new Map<string, string>()
function avatarFor(addr: string): string {
  let svg = avatars.get(addr)
  if (svg === undefined) {
    svg = renderPepeSvg(dnaOfId(BigInt(addr)))
    if (avatars.size > 128) avatars.clear()
    avatars.set(addr, svg)
  }
  return svg
}

function short(addr: string): string {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`
}

/// +5:00 per whole psp — same shape the clock's chip floats
function fmtAdded(ms: number): string {
  const m = Math.floor(ms / 60_000)
  const s = Math.floor((ms % 60_000) / 1000)
  return `+${m}:${String(s).padStart(2, '0')}`
}

export default function Tape({ entries }: { entries: TapeEntry[] }) {
  const shown = useMemo(() => entries.slice(0, MAX_ROWS), [entries])

  return (
    <div className="overflow-hidden rounded-xl border border-line bg-bg-1" aria-label="live activity">
      {shown.length === 0 ? (
        <p className="px-4 py-2.5 text-sm text-text-lo">no trades yet — the first one prints here.</p>
      ) : (
        shown.map((e) => (
          <div
            key={e.id}
            className="pl-tape-row flex items-center gap-2.5 border-t border-line px-4 py-2 text-sm first:border-t-0"
          >
            <span className={`pl-dot ${e.kind === 'buy' ? 'pl-dot--buy' : ''}`} aria-hidden="true" />
            <span
              className="h-[22px] w-[22px] shrink-0 overflow-hidden rounded border border-line"
              style={{ imageRendering: 'pixelated' }}
              aria-hidden="true"
              dangerouslySetInnerHTML={{ __html: avatarFor(e.addr) }}
            />
            <span className="hidden shrink-0 font-data text-xs text-text-lo sm:inline">
              {short(e.addr)}
            </span>
            <span className="min-w-0 truncate text-text-lo">
              {e.kind === 'buy' ? 'bought' : 'sold'}{' '}
              <span className="tabular font-data text-text-hi">{fmtAmount(e.pspWad, 2)} psp</span>
              {e.addedMs !== undefined ? (
                <>
                  {' · '}
                  <span className="tabular font-data text-accent" title="fed the clock">
                    {fmtAdded(e.addedMs)}
                  </span>
                </>
              ) : (
                <>
                  {' for '}
                  <span className="tabular font-data text-text-hi">
                    {fmtAmount(e.mixWad, 2)} mixETH
                  </span>
                </>
              )}
            </span>
          </div>
        ))
      )}
    </div>
  )
}
