import { useState } from 'react'
import { useAccount } from 'wagmi'
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
import PostRound from './play/PostRound'
import { useTradeTape } from './play/useTradeTape'
import { useLadderBoard } from './play/useLadderBoard'
import { useDeadRound } from './play/useDeadRound'

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
// dead-round lane finds the corpse on its own.
// ─────────────────────────────────────────────────────────────────────────────

export default function Trade() {
  const round = useRound()
  const tape = useTradeTape()
  const dead = useDeadRound()
  /// set by DetonateButton on tx success — flips the page instantly; the
  /// dead-round lane confirms the settled state within one 6s tick
  const [detonated, setDetonated] = useState(false)

  // the ladder reads the LIVE hook's rolling board while the round trades…
  const liveBoard = useLadderBoard(round.mode === 1 ? round.hook : undefined)
  // …and the dead hook's frozen board once a round has settled
  const settledBoard = useLadderBoard(dead.dead ? dead.hook : undefined)

  const postRound = detonated || dead.dead
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
      <ClockPanel round={round} lastTime={tape.lastTime} onDetonated={() => setDetonated(true)} />
      <div className="mt-4">
        <RefBanner />
      </div>
      <div className="mt-4">
        <Tape entries={tape.entries} />
      </div>
      {postRound && <PostRound dead={dead} justDetonated={detonated} />}
      <div className="mt-4 grid grid-cols-1 gap-4 lg:grid-cols-5">
        {/* audit r2 fix 2: swap column hugs its content (lg:self-start) — the
            ladder owns the tall right column; asymmetric bottoms are
            intentional. Kills the ~237px dead zone above the CTA. */}
        <div className="lg:col-span-2 lg:self-start">
          <SwapCard />
        </div>
        <div className="lg:col-span-3">
          <PotBoard
            pot={postRound && dead.dead ? settledBoard.pot : liveBoard.pot}
            tickets={postRound && dead.dead ? settledBoard.seats : liveBoard.seats}
            settled={postRound && dead.dead}
            roundLabel={dead.roundId !== undefined ? `round ${dead.roundId}` : undefined}
            claimable={dead.claimable}
            claimHook={dead.hook}
          />
        </div>
      </div>
      <div className="mt-4">
        <CurveChart hasTrades={tape.count > 0} entryPrice={entryPrice} />
      </div>
      <div className="mt-4">
        <TickerBar items={tickerItems} />
      </div>
    </div>
  )
}
