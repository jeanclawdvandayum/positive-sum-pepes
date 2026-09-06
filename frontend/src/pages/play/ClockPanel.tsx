import Clock from '../../components/Clock'
import PotOdometer from '../../components/PotOdometer'
import Skeleton from '../../components/Skeleton'
import WalletPepeArt from '../../components/WalletPepeArt'
import { useNow } from '../../phase/PhaseEngine'
import type { RoundInfo } from '../../lib/useRound'
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
  lastTime,
  onDetonated,
}: {
  round: RoundInfo
  lastTime: LastTimeAdded | undefined
  onDetonated: () => void
}) {
  const now = useNow()
  const when = lastTime ? ago(lastTime.atSec, now) : undefined

  return (
    <section
      aria-label="round clock"
      className="pl-clockband relative left-1/2 w-screen -translate-x-1/2"
    >
      <div className="mx-auto flex w-full max-w-6xl flex-col items-center px-4 pb-7 pt-6 sm:pb-9 sm:pt-8">
        <Clock />
        <div className="mt-5 text-2xl sm:text-3xl" title="the pot gets the launch fee and at least 35% of each trading fee. the last ten tickets split it at detonation; an empty ladder sends it to redemption backing.">
          {round.potBalance === undefined ? (
            <Skeleton className="h-8 w-44" aria-label="loading the pot" />
          ) : (
            <PotOdometer value={round.potBalance} unit="mixETH" />
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
        <DetonateButton round={round} onDetonated={onDetonated} />
      </div>
    </section>
  )
}
