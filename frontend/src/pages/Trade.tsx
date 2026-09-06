import { useState } from 'react'
import { useAccount } from 'wagmi'
import { Link } from 'react-router-dom'
import SwapCard from '../components/SwapCard'
import CurveChart from '../components/CurveChart'
import TickerBar from '../components/TickerBar'
import { RefBanner } from '../components/ReferralCard'
import { useRound } from '../lib/useRound'
import { fmtAmount, fmtPrice } from '../lib/format'
import { PlayStyles } from './play/PlayStyles'
import ClockPanel from './play/ClockPanel'
import Tape from './play/Tape'
import PotBoard from './play/PotBoard'
import { useTradeTape } from './play/useTradeTape'
import { useLadderBoard } from './play/useLadderBoard'
import SpawnRoundPanel from './play/SpawnRoundPanel'
import { ADDRESSES } from '../lib/config'
import { useDeadRound } from './play/useDeadRound'
import { playRoundState } from '../lib/playRoundState'

// ─────────────────────────────────────────────────────────────────────────────
// /play — the command center (REDESIGN-B2, spec §6 play, CLOCK-REDESIGN §6).
//
// Clock panel full-bleed at top (one instrument: time left / money waiting)
// → live tape under the clock → [post-round: redemption portal] → swap left /
// ladder right → curve → the bottom stat cards folded into ONE continuous
// TickerBar. All lanes keep their sanctioned cadences: round state 4s
// (useRound), board + dead-round 6s (useLadderBoard/useDeadRound — the
// useRpcReads speed), tape per-block getLogs. Nothing faster anywhere.
//
// Post-round (CLOCK-REDESIGN §4/§5): detonate() flips the page into the
// redemption-portal state — the portal panel appears, the ladder settles to
// the frozen distribution with claims-forever rows, and the clock retires
// (DeadlineWire disarms it). Same state for anyone arriving later: the
// dead-round lane confirms claims for this round. Historical corpses never
// replace a successor's board or expose an already-completed spawn.
// ─────────────────────────────────────────────────────────────────────────────

export default function Trade() {
  const round = useRound()
  const tape = useTradeTape()
  const dead = useDeadRound()
  /// set by DetonateButton on tx success — flips the page instantly; the
  /// dead-round lane confirms the settled state within one 6s tick
  const [detonatedRoundId, setDetonatedRoundId] = useState<bigint>()
  const { settled, spawnFromRoundId, claimable } = playRoundState(round, dead, detonatedRoundId)
  // The clock, pot, tickets and avatars always belong to the current round,
  // including while it is settled and its successor is still being created.
  const board = useLadderBoard(round.hook)
  const ticketCount = board.ticketCount
  const { address } = useAccount()
  const entryPrice = address !== undefined ? tape.entryPriceOf(address) : undefined

  const tickerItems = [
    { label: 'volume', value: `${fmtAmount(tape.volumeWad)} mixETH` },
    { label: 'fees to stakers', value: `${fmtAmount(tape.feesWad)} mixETH` },
    { label: 'reserves', value: `${fmtAmount(round.reserve)} mixETH` },
    { label: 'price', value: `${fmtPrice(round.marginalPrice)} mix / psp` },
  ]

  return (
    <div className="pl-page font-body text-text-hi">
      <PlayStyles />
      <ClockPanel round={round} leadingBuyer={board.seats[0]?.addr} lastTime={tape.lastTime} onDetonated={() => setDetonatedRoundId(round.id)} />
      <div className="mt-4">
        <RefBanner />
      </div>
      <div className="mt-4">
        <Tape entries={tape.entries} />
      </div>
      {settled && (
        <div className="flex items-center gap-3 rounded-xl border border-line bg-bg-1 p-5 text-sm text-text-lo">
          <span>
            round {round.id.toString()} is flat — redeem your psp from the{' '}
            <Link to="/graveyard" className="text-accent underline">graveyard</Link>.
          </span>
        </div>
      )}
      {spawnFromRoundId !== undefined && (
        <SpawnRoundPanel key={`${ADDRESSES.factory}:${spawnFromRoundId}`} factory={ADDRESSES.factory} destroyedRoundId={spawnFromRoundId} />
      )}
      <div className="mt-4 grid grid-cols-1 gap-4 lg:grid-cols-5">
        {/* Stretch both cards to the shared row height on wide screens. */}
        <div className="min-w-0 lg:col-span-2">
          <SwapCard />
        </div>
        <div className="min-w-0 lg:col-span-3">
          <PotBoard
            key={round.hook}
            pot={board.pot}
            tickets={board.seats}
            ticketCount={ticketCount}
            staker={round.staker}
            settled={settled}
            roundId={round.id}
            roundLabel={`round ${round.id}`}
            claimable={claimable}
            claimHook={settled ? round.hook : undefined}
          />
        </div>
      </div>
      <div className="mt-4">
        <CurveChart hasTrades={tape.count > 0 || (ticketCount ?? 0n) > 0n} entryPrice={entryPrice} />
        {round.mode === 1 && round.swapFeeBps !== undefined && (
          <p className="mt-2 text-xs font-data text-text-lo" title="the sliding sine fee at the current reserve — 10% at launch → 2.5% at the reserve target">
            trade fee: {(Number(round.swapFeeBps) / 100).toFixed(2)}% of every buy and sell — 60% to stakers · the rest to the pot and referral/deployer rewards
          </p>
        )}
      </div>
      <div className="mt-4">
        <TickerBar items={tickerItems} />
      </div>
    </div>
  )
}
