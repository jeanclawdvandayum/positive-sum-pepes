import { useMemo } from 'react'
import WalletPepeArt from '../../components/WalletPepeArt'
import { useRound } from '../../lib/useRound'
import { fmtAmount } from '../../lib/format'
import type { TapeEntry } from './useTradeTape'
import WalletName from '../../components/WalletName'

// ─────────────────────────────────────────────────────────────────────────────
// Tape — the slim live activity feed under the clock (REDESIGN-B2 §2).
//
// One-line entries with pepe avatars for buys and sells, newest on top,
// fed by useTradeTape (the StatsPanel getLogs lane). Time injections and
// stake events join when their lanes exist — until then the tape shows
// exactly what the logs say. Loading and failed reads stay distinct from a
// confirmed empty round.
//
// Avatars share the header's round-aware NFT/available-wallet identity.
// ─────────────────────────────────────────────────────────────────────────────

const MAX_ROWS = 3

/// +5:00 per whole psp — same shape the clock's chip floats
function fmtAdded(ms: number): string {
  const m = Math.floor(ms / 60_000)
  const s = Math.floor((ms % 60_000) / 1000)
  return `+${m}:${String(s).padStart(2, '0')}`
}

export default function Tape({ entries, loading, error }: { entries: TapeEntry[]; loading: boolean; error: boolean }) {
  const round = useRound()
  const shown = useMemo(() => entries.slice(0, MAX_ROWS), [entries])

  return (
    <div className="overflow-hidden rounded-xl border border-line bg-bg-1" aria-label="live activity">
      {shown.length === 0 ? (
        <p className="px-4 py-2.5 text-sm text-text-lo" role="status">
          {error ? 'trade history is reconnecting. retrying automatically.'
            : loading ? 'loading round trades…' : 'waiting for trades. the tape keeps receipts.'}
        </p>
      ) : (
        shown.map((e) => (
          <div
            key={e.id}
            className="pl-tape-row flex items-center gap-2.5 border-t border-line px-4 py-2 text-sm first:border-t-0"
          >
            <span className={`pl-dot ${e.kind === 'buy' ? 'pl-dot--buy' : ''}`} aria-hidden="true" />
            <WalletPepeArt address={e.addr} staker={round.staker}
              className="h-[22px] w-[22px] shrink-0 overflow-hidden rounded border border-line"
            />
            <WalletName address={e.addr} className="max-w-[34%] shrink-0 truncate font-data text-xs text-text-lo" />
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
      {shown.length > 0 && (loading || error) && (
        <p className="border-t border-line px-4 py-2 text-xs text-text-lo" role="status">
          {error ? 'showing the latest loaded trades. reconnecting…' : 'loading earlier trades and round totals…'}
        </p>
      )}
    </div>
  )
}
