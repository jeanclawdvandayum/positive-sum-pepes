import { useId, useMemo, useState } from 'react'
import { renderDecorativePepeSvg } from '../../lib/pepeRender'
import { fmtAmount } from '../../lib/format'
import type { GraveyardRound } from '../play/useGraveyard'
import RoundWinners from './RoundWinners'
import './hall.css'

function RoundHistoryEntry({ round, connected }: { round: GraveyardRound; connected: boolean }) {
  const [expanded, setExpanded] = useState(false)
  const panelId = useId()
  const buttonId = useId()
  return (
    <li className="border-t border-line">
      <button
        id={buttonId} type="button" aria-expanded={expanded} aria-controls={panelId}
        onClick={() => setExpanded(value => !value)}
        className="flex w-full items-center gap-3 rounded-lg py-4 text-left transition hover:bg-bg-2 focus-visible:outline-2 focus-visible:outline-accent focus-visible:outline-offset-2"
      >
        <span className="flex min-w-0 flex-1 flex-wrap items-baseline gap-x-3 gap-y-1">
          <span className="font-data text-sm text-text-hi">round {round.roundId.toString()}</span>
          <span className="tabular font-data text-xs text-text-lo">
            {round.pot !== undefined ? `pot ${fmtAmount(round.pot)} mixETH` : 'pot unavailable'}
          </span>
          {connected && round.claimablePot > 0n && (
            <span className="tabular font-data text-xs text-pepe">
              {fmtAmount(round.claimablePot)} mixETH winnings to claim below
            </span>
          )}
        </span>
        <span className="shrink-0 text-xs text-text-lo">{expanded ? 'hide winners' : 'view winners'}</span>
        <svg className={`mr-1 h-4 w-4 shrink-0 text-accent transition-transform motion-reduce:transition-none ${expanded ? 'rotate-180' : ''}`} viewBox="0 0 16 16" fill="none" aria-hidden="true">
          <path d="m4 6 4 4 4-4" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </button>
      <div id={panelId} role="region" aria-labelledby={buttonId} hidden={!expanded} className="pb-4">
        {expanded && <RoundWinners hook={round.hook} staker={round.staker} />}
      </div>
    </li>
  )
}

// Share the graveyard's verified dead-round reads. Local round-id observations
// produced fictitious round 0 entries and confused reserves with the fee pot.
export default function HallOfDetonations({ rounds, checked, connected }: {
  rounds: GraveyardRound[]
  checked: boolean
  connected: boolean
}) {
  const sleeper = useMemo(() => renderDecorativePepeSvg(), [])

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
            <RoundHistoryEntry key={`${round.hook}:${round.roundId}`} round={round} connected={connected} />
          ))}
        </ol>
      )}
    </section>
  )
}
