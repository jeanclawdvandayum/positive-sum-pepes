import Clock from '../../components/Clock'
import ClockBand from '../../components/ClockBand'
import PotOdometer from '../../components/PotOdometer'
import Skeleton from '../../components/Skeleton'
import WalletPepeArt from '../../components/WalletPepeArt'
import { useNow, usePhase } from '../../phase/PhaseEngine'
import { useEthUsd } from '../../lib/useEthUsd'
import { wadToExact } from '../../lib/format'
import type { RoundInfo } from '../../lib/useRound'
import { useDisplayName } from '../../lib/useDisplayName'
import { fmtAmount } from '../../lib/format'
import { groupRoundWinners } from '../../lib/roundWinners'
import type { BoardState } from './useLadderBoard'
import type { LastTimeAdded } from './useTradeTape'
import DetonateButton from './DetonateButton'
import NotifyToggle from './NotifyToggle'

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
  return <span className="pl-bombing-buyer" title={`${name} · ${address}`}>{name.split('.')[0]}</span>
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
  const { phase, hasDeadline } = usePhase()
  const ethUsd = useEthUsd()
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
    <ClockBand label="round clock" className="pl-clockband">
        <h1 className="mb-5 w-full max-w-4xl text-center font-display text-2xl leading-tight text-[#e8f0f7] [overflow-wrap:anywhere] sm:mb-6 sm:text-3xl">
          {round.mode === 1 ? (
            <>
              {leadingBuyer ? <BombingBuyer address={leadingBuyer} /> : <span className="pl-bombing-buyer">anon pepe</span>}
              {' '}is <em>carpet bombing</em> for{' '}
              <span className="pl-bombing-prize" title="carpet bombing = holding the top seats. estimated payout across all their current seats if the round detonated with this pot and ladder">
                {fmtAmount(leadingPrize, 4)} mixETH
              </span>{' '}in:
            </>
          ) : 'awaiting arming of carpet bomb'}
        </h1>
        <Clock />
        {round.mode === 1 && hasDeadline && (
          <p className="clock-word mt-3 font-data text-xs" aria-live="polite">
            {phase === 'calm' ? 'calm' : phase === 'heat' ? 'heating up' : 'critical'}
          </p>
        )}
        <div className="mt-5 flex max-w-full flex-wrap items-baseline justify-center gap-x-3 gap-y-1 text-2xl sm:text-3xl" title="the prize. seeded by the opening buy's 10% fee, fed by at least 35% of every trading fee. the last ten tickets split it at detonation; an empty ladder sends it to the backing.">
          <span className="font-display text-xl text-[#c9d7e4] sm:text-2xl">prize pot:</span>
          {pot === undefined ? (
            <Skeleton className="h-8 w-44" aria-label="loading the pot" />
          ) : (
            <PotOdometer value={pot} unit="mixETH" />
          )}
          {pot !== undefined && ethUsd !== null && (
            <span className="tabular font-data text-sm text-[#8fa3b8]" title="display estimate at the current ETH price">
              ≈ ${(Number(pot) / 1e18 * ethUsd).toLocaleString('en-US', { maximumFractionDigits: 0 })}
            </span>
          )}
        </div>
        <div
          className="mt-2 font-data text-xs text-[#8fa3b8]"
          title="the mixETH backing PSP — what every PSP redeems for once the round is over."
        >
          backing:{' '}
          {round.reserve === undefined ? (
            <Skeleton className="inline-block h-3 w-24 align-middle" aria-label="loading reserves" />
          ) : (
            <span className="text-[#c9d7e4]">
              {(Number(round.reserve) / 1e18).toLocaleString('en-US', { maximumFractionDigits: 4 })} mixETH
            </span>
          )}
        </div>
        {round.mode === 1 && (
          <p className="pl-context mt-3 max-w-2xl font-data text-xs leading-relaxed">
            at zero: trading stops · the carpet bombers on the ladder split the pot · every PSP redeems for its backing.
          </p>
        )}
        {round.readError ? (
          <p className="pl-context mt-3 font-data text-xs text-phase-heat" role="status">reconnecting to the chain…</p>
        ) : lastTime === undefined ? (
          <p className="pl-context mt-3 font-data text-xs">
            feed the clock. every ticket adds up to 69 seconds{round.ticketPrice !== undefined && ` · a ticket costs ${wadToExact(round.ticketPrice)} mixETH right now (prize pot ÷ 10,000)`}.
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
        <NotifyToggle round={round} />
        <DetonateButton key={round.controller} round={round} onDetonated={onDetonated} />
    </ClockBand>
  )
}
