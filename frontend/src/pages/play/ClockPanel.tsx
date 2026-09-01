import Clock from '../../components/Clock'
import PotOdometer from '../../components/PotOdometer'
import Skeleton from '../../components/Skeleton'
import { renderPepeSvg } from '../../lib/pepeRender'
import { dnaOfId } from '../../components/PepePicker'
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
// existing getLogs lane; no new reads). Avatars are LOCAL derivations,
// same as the tape: keccak(address) → dna → renderPepeSvg. No timestamp in
// the log payload's reach → the "ago" half simply stays off the line.
//
// Below that, the detonator (§6.3): hidden while the clock lives, appears
// at zero — DetonateButton owns its own states.
// ─────────────────────────────────────────────────────────────────────────────

function short(addr: string): string {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`
}

const avatars = new Map<string, string>()
function avatarFor(addr: string): string {
  let svg = avatars.get(addr)
  if (svg === undefined) {
    svg = renderPepeSvg(dnaOfId(BigInt(addr)))
    if (avatars.size > 32) avatars.clear()
    avatars.set(addr, svg)
  }
  return svg
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
        <div className="mt-5 text-2xl sm:text-3xl" title="the pot — mixETH waiting in this round">
          {round.reserve === undefined ? (
            <Skeleton className="h-8 w-44" aria-label="loading the pot" />
          ) : (
            <PotOdometer value={round.reserve} unit="mixETH" />
          )}
        </div>
        {lastTime === undefined ? (
          <p className="pl-context mt-3 font-data text-xs">
            no time added yet — every whole psp bought feeds the clock +5:00
          </p>
        ) : (
          <p className="pl-context mt-3 flex items-center gap-1.5 font-data text-xs">
            <span
              className="inline-block h-[18px] w-[18px] overflow-hidden rounded border border-[#22344f]"
              style={{ imageRendering: 'pixelated' }}
              aria-hidden="true"
              dangerouslySetInnerHTML={{ __html: avatarFor(lastTime.addr) }}
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
