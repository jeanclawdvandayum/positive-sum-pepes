import { useMemo } from 'react'
import { renderPepeSvg, randomDna } from '../../lib/pepeRender'
import { fmtAmount } from '../../lib/format'
import type { GraveyardRound } from '../play/useGraveyard'
import './hall.css'

// Share the graveyard's verified dead-round reads. Local round-id observations
// produced fictitious round 0 entries and confused reserves with the fee pot.
export default function HallOfDetonations({ rounds, checked, connected }: {
  rounds: GraveyardRound[]
  checked: boolean
  connected: boolean
}) {
  const sleeper = useMemo(() => renderPepeSvg(randomDna()), [])

  return (
    <section className="rounded-2xl border border-line bg-bg-1 p-5" aria-label="round history">
      <h2 className="font-display text-lg">hall of detonations</h2>
      <p className="mt-1 text-xs text-text-lo">every boom gets a paper trail.</p>

      {!checked ? (
        <p role="status" className="mt-6 text-sm text-text-lo">checking the graveyard…</p>
      ) : rounds.length === 0 ? (
        <div className="mt-6 flex flex-col items-center justify-center gap-4 py-10 text-center">
          <div className="relative">
            <div
              className="h-[138px] w-[138px] overflow-hidden rounded-xl border border-line [&>svg]:h-full [&>svg]:w-full"
              style={{ imageRendering: 'pixelated', filter: 'grayscale(0.5) opacity(0.6)' }}
              aria-hidden="true"
              dangerouslySetInnerHTML={{ __html: sleeper }}
            />
            <span className="hall-zzz text-sm" aria-hidden="true">
              <span>z</span> <span>z</span> <span>z</span>
            </span>
          </div>
          <div>
            <p className="text-sm text-text-hi">the graveyard is waiting for its first customer.</p>
            <p className="mt-1 text-xs leading-relaxed text-text-lo">
              past rounds and their pots appear here. unlock positions, claim winnings, and redeem below.
            </p>
          </div>
        </div>
      ) : (
        <ol className="mt-4">
          {[...rounds].reverse().map((round) => (
            <li key={round.roundId.toString()} className="flex flex-wrap items-baseline gap-x-3 gap-y-1 border-t border-line py-3 text-sm">
              <span className="font-data text-text-hi">round {round.roundId.toString()}</span>
              <span className="tabular font-data text-xs text-text-lo">
                {round.pot !== undefined ? `pot ${fmtAmount(round.pot)} mixETH` : 'pot unavailable'}
              </span>
              {connected && round.claimablePot > 0n && (
                <span className="tabular font-data text-xs text-pepe">
                  {fmtAmount(round.claimablePot)} mixETH winnings to claim below
                </span>
              )}
            </li>
          ))}
        </ol>
      )}
    </section>
  )
}
