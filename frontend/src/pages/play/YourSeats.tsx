import { useAccount } from 'wagmi'
import WalletPepeArt from '../../components/WalletPepeArt'
import { refLinkFor, useReferral } from '../../components/ReferralCard'
import { referralXIntent } from '../../lib/referralShare'
import { fmtAmount, wadToExact } from '../../lib/format'
import { LADDER_SHARES } from '../../lib/gameRules'
import { getRemainingMs, useNow } from '../../phase/PhaseEngine'
import type { RoundInfo } from '../../lib/useRound'
import type { BoardState } from './useLadderBoard'

// ─────────────────────────────────────────────────────────────────────────────
// YourSeats — the personal strip on /play (UX assessment #14): what the
// connected wallet holds on the ladder, what it pays if the round ended now,
// and how many more tickets push it off. Pure arithmetic over reads that
// already exist (useLadderBoard + useAccount); no new RPC lane.
// ─────────────────────────────────────────────────────────────────────────────

function fmtLeft(ms: number): string {
  const t = Math.max(0, Math.floor(ms / 1000))
  const h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), s = t % 60
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`
}

export default function YourSeats({ round, board }: { round: RoundInfo; board: BoardState }) {
  const { address } = useAccount()
  const referral = useReferral()
  useNow() // one-second heartbeat so the shared countdown in the share text stays fresh
  if (!address || round.mode !== 1) return null

  const me = address.toLowerCase()
  const seated = board.seats.filter(s => s !== undefined).length
  const mine = board.seats
    .map((s, i) => (s !== undefined && s.addr.toLowerCase() === me ? i : -1))
    .filter(i => i >= 0)

  if (mine.length === 0) {
    return (
      <div className="flex flex-wrap items-center gap-x-3 gap-y-1 rounded-xl border border-line bg-bg-1 px-4 py-3 text-sm">
        <WalletPepeArt address={address} staker={round.staker} className="h-7 w-7 shrink-0 overflow-hidden rounded border border-line" />
        <span className="text-text-lo">
          you’re not on the ladder ·{' '}
          {round.ticketPrice !== undefined
            ? <>1 ticket (<span className="tabular font-data text-text-hi">{wadToExact(round.ticketPrice)} mixETH</span>) takes seat #1</>
            : 'one ticket takes seat #1'}
        </span>
      </div>
    )
  }

  const denom = LADDER_SHARES.slice(0, seated).reduce((a, b) => a + b, 0)
  const share = mine.reduce((a, i) => a + LADDER_SHARES[i], 0)
  const pct = denom > 0 ? (share / denom) * 100 : 0
  const payout = board.pot !== undefined && denom > 0 ? (board.pot * BigInt(share)) / BigInt(denom) : undefined
  const oldest = Math.max(...mine)
  const bump = 10 - oldest // tickets that push the last of your seats past #10
  const seatsLabel = mine.length === 1 ? `seat #${mine[0] + 1}` : `seats ${mine.map(i => `#${i + 1}`).join(', ')}`

  const text = `i’m #${mine[0] + 1} on the ladder for ${fmtAmount(payout, 4)} mixETH · ${fmtLeft(getRemainingMs())} left · positive sum pepes`
  const link = referral.registry && referral.version === 1n && referral.pepeIds.length > 0
    ? refLinkFor(referral.pepeIds[0], referral.registry)
    : `${window.location.origin}${window.location.pathname}#/play`

  return (
    <div className="flex flex-wrap items-center gap-x-3 gap-y-2 rounded-xl border border-accent/50 bg-bg-1 px-4 py-3 text-sm" aria-label="your seats">
      <WalletPepeArt address={address} staker={round.staker} className="h-7 w-7 shrink-0 overflow-hidden rounded border border-line" />
      <span className="min-w-0 text-text-hi">
        you hold <span className="font-data">{seatsLabel}</span> · pays{' '}
        <span className="tabular font-data">{pct % 1 === 0 ? pct : pct.toFixed(1)}%</span>
        {' = '}
        <span className="tabular font-data text-pot-gold">{payout === undefined ? '…' : fmtAmount(payout, 4)} mixETH</span> if it ends now ·{' '}
        <span className="text-text-lo">{bump} more {bump === 1 ? 'ticket bumps' : 'tickets bump'} you off</span>
      </span>
      <a
        href={referralXIntent(text, link)}
        target="_blank"
        rel="noopener noreferrer"
        className="ml-auto shrink-0 rounded-lg border border-line px-3 py-1.5 text-xs text-text-hi transition hover:border-accent focus-visible:outline-2 focus-visible:outline-accent"
      >
        post to X
      </a>
    </div>
  )
}
