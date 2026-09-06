import Clock from '../../components/Clock'
import PotOdometer from '../../components/PotOdometer'
import Skeleton from '../../components/Skeleton'
import WalletPepeArt from '../../components/WalletPepeArt'
import { useNow } from '../../phase/PhaseEngine'
import type { RoundInfo } from '../../lib/useRound'
import { useDisplayName } from '../../lib/useDisplayName'
import { fmtAmount } from '../../lib/format'
import { groupRoundWinners } from '../../lib/roundWinners'
import type { BoardState } from './useLadderBoard'
import type { LastTimeAdded } from './useTradeTape'
import DetonateButton from './DetonateButton'

// ─────────────────────────────────────────────────────────────────────────────
// ClockPanel — the play page's command strip (REDESIGN-B2 §1, spec §6 play).
//
// Full-bleed band at the very top, dark in BOTH themes (the machine's
// screen, spec §1): the Clock dominant, the POT as a gold odometer directly
// beneath the numerals — ONE instrument, "time left / money waiting". No
// floating pot box, no dead space around it.
//
// Under the pot, one thin live-context line: "last added by [pepe] · Xm
// ago" — CLOCK-REDESIGN §6.6 wired it to TimeAdded (which rides the tape's
// existing getLogs lane). Avatars share the header's NFT identity. No timestamp in
// the log payload's reach → the "ago" half simply stays off the line.
//
// Below that, the detonator (§6.3): hidden while the clock lives, appears
// at zero — DetonateButton owns its own states.
// ─────────────────────────────────────────────────────────────────────────────

function short(addr: string): string {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`
}

function BombingBuyer({ address }: { address: `0x${string}` }) {
  const name = useDisplayName(address, 'anon pepe')
  return <span className="pl-bombing-buyer" title={address}>{name}</span>
}

/// recency for the "last added" line — seconds → dry human time
function ago(sec: number | undefined, now: number): string | undefined {
  if (sec === undefined) return undefined
  const d = Math.max(0, now - sec)
  if (d < 90) return 'just now'
  const m = Math.floor(d / 60)
  if (m < 60) return `${m}m ago`
  return `${Math.floor(m / 60)}h ago`
}

export default function ClockPanel({
  round,
  board,
  lastTime,
  onDetonated,
}: {
  round: RoundInfo
  board: BoardState
  lastTime: LastTimeAdded | undefined
  onDetonated: () => void
}) {
  const now = useNow()
  const when = lastTime ? ago(lastTime.atSec, now) : undefined
  const leadingBuyer = board.seats[0]?.addr
  const pot = board.pot ?? round.potBalance
  const seatCount = board.ticketCount === undefined ? undefined : Number(board.ticketCount > 10n ? 10n : board.ticketCount)
  const buyers = board.seats.slice(0, seatCount).map(seat => seat?.addr)
  // Use the same per-seat floor and small-ladder normalization as claims. A
  // missing occupied seat must leave the estimate pending, not inflate the rest.
  const leadingPrize = board.pot !== undefined && seatCount !== undefined &&
    buyers.length === seatCount && buyers.every((buyer): buyer is `0x${string}` => buyer !== undefined)
      ? groupRoundWinners(board.pot, buyers)[0]?.payout ?? 0n
      : undefined

  return (
    <section
      aria-label="round clock"
      className="pl-clockband relative left-1/2 w-screen -translate-x-1/2"
    >
      <div className="mx-auto flex w-full max-w-6xl flex-col items-center px-4 pb-7 pt-6 sm:pb-9 sm:pt-8">
        <h1 className="mb-5 w-full max-w-4xl text-center font-display text-2xl leading-tight text-[#e8f0f7] [overflow-wrap:anywhere] sm:mb-6 sm:text-3xl">
          {round.mode === 1 ? (
            <>
              {leadingBuyer ? <BombingBuyer address={leadingBuyer} /> : <span className="pl-bombing-buyer">anon pepe</span>}
              {' '}is <em>carpet bombing</em> for{' '}
              <span className="pl-bombing-prize" title="estimated payout across all their current ladder spots if the round detonated with this pot and ladder">
                {fmtAmount(leadingPrize, 4)} mixETH
              </span>{' '}in:
            </>
          ) : 'awaiting arming of carpet bomb'}
        </h1>
        <Clock />
        <div className="mt-5 flex max-w-full flex-wrap items-baseline justify-center gap-x-3 gap-y-1 text-2xl sm:text-3xl" title="the pot gets the launch fee and at least 35% of each trading fee. the last ten tickets split it at detonation; an empty ladder sends it to redemption backing.">
          <span className="font-display text-xl text-[#c9d7e4] sm:text-2xl">total pot:</span>
          {pot === undefined ? (
            <Skeleton className="h-8 w-44" aria-label="loading the pot" />
          ) : (
            <PotOdometer value={pot} unit="mixETH" />
          )}
        </div>
        <div
          className="mt-2 font-data text-xs text-[#8fa3b8]"
          title="the mixETH held by the curve to back PSP."
        >
          curve reserves:{' '}
          {round.reserve === undefined ? (
            <Skeleton className="inline-block h-3 w-24 align-middle" aria-label="loading reserves" />
          ) : (
            <span className="text-[#c9d7e4]">
              {(Number(round.reserve) / 1e18).toLocaleString('en-US', { maximumFractionDigits: 4 })} mixETH
            </span>
          )}
        </div>
        {lastTime === undefined ? (
          <p className="pl-context mt-3 font-data text-xs">
            feed the clock. each full 0.005 mixETH in a buy adds up to +4:20.
          </p>
        ) : (
          <p className="pl-context mt-3 flex items-center gap-1.5 font-data text-xs">
            <WalletPepeArt address={lastTime.addr} staker={round.staker}
              className="inline-block h-[18px] w-[18px] overflow-hidden rounded border border-[#22344f]"
            />
            <span>
              last added by <span className="text-[#e8f0f7]">{short(lastTime.addr)}</span>
              {when !== undefined && <span> · {when}</span>}
            </span>
          </p>
        )}
        <DetonateButton key={round.controller} round={round} onDetonated={onDetonated} />
      </div>
    </section>
  )
}
