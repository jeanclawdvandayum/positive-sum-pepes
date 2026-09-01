// ─────────────────────────────────────────────────────────────────────────────
// HallOfDetonations — ROUND HISTORY, the right column's mythology (REDESIGN-B3
// items 4+6). Lists past detonations: pot size, your result (winner-pepe lanes
// arrive with the archive data — never invented here).
//
// Record source is the LOCAL record (decided 2026-08-31): the app watches the
// existing currentRoundId lane and archives a round when it observes the id
// advance — pot = the reserve it last polled for that round, your result =
// what you had staked at the boom. Rounds that fired before this browser ever
// looked are not fetchable without new chain reads, so until records exist the
// designed empty state renders: sleeping pepe + zzz, §8 voice, verbatim.
// ─────────────────────────────────────────────────────────────────────────────

import { useEffect, useMemo, useRef, useState } from 'react'
import { renderPepeSvg, randomDna } from '../../lib/pepeRender'
import { fmtAmount } from '../../lib/format'

interface HallRecord {
  round: string
  pot: string | null
  yourStaked: string | null
  ts: number
}

const KEY = 'psp-hall-v1'

function readHall(): HallRecord[] {
  try {
    const raw = localStorage.getItem(KEY)
    if (!raw) return []
    const parsed = JSON.parse(raw)
    return Array.isArray(parsed) ? (parsed as HallRecord[]) : []
  } catch {
    return []
  }
}

function writeHall(records: HallRecord[]) {
  try {
    localStorage.setItem(KEY, JSON.stringify(records))
  } catch {
    /* private mode — the hall just won't persist */
  }
}

export default function HallOfDetonations({
  roundId,
  pot,
  yourStaked,
}: {
  roundId: bigint
  /** reserve of the round being watched (existing lane) */
  pot: bigint | undefined
  yourStaked: bigint
}) {
  const [records, setRecords] = useState<HallRecord[]>(readHall)
  const prev = useRef<{ id: bigint; pot: bigint | undefined } | null>(null)
  // sleeping pepe — cast per mount, like every teaser lane in the app
  const sleeper = useMemo(() => renderPepeSvg(randomDna()), [])

  // the archiver: fires only when the observed round id ADVANCES
  useEffect(() => {
    const p = prev.current
    prev.current = { id: roundId, pot }
    if (!p || roundId <= p.id) return // first observation / same round
    const rec: HallRecord = {
      round: p.id.toString(),
      pot: p.pot !== undefined ? p.pot.toString() : null,
      yourStaked: yourStaked > 0n ? yourStaked.toString() : null,
      ts: Date.now(),
    }
    setRecords((rs) => {
      const next = [...rs, rec]
      writeHall(next)
      return next
    })
  }, [roundId, pot, yourStaked])

  return (
    <section
      className="flex flex-1 flex-col rounded-2xl border border-line bg-bg-1 p-5"
      aria-label="round history"
    >
      <h2 className="font-display text-lg">hall of detonations</h2>
      <p className="mt-1 text-xs text-text-lo">round history — every boom, archived.</p>

      {records.length === 0 ? (
        <div className="relative mt-6 flex flex-1 flex-col items-center justify-center gap-4 py-10 text-center">
          <div className="relative">
            <div
              className="h-[138px] w-[138px] overflow-hidden rounded-xl border border-line [&>svg]:h-full [&>svg]:w-full"
              style={{ imageRendering: 'pixelated', filter: 'grayscale(0.5) opacity(0.6)' }}
              aria-hidden="true"
              dangerouslySetInnerHTML={{ __html: sleeper }}
            />
            <span className="st-zzz text-sm" aria-hidden="true">
              <span>z</span> <span>z</span> <span>z</span>
            </span>
          </div>
          <div>
            <p className="text-sm text-text-hi">no detonations yet — the first archive seat is open.</p>
            <p className="mt-1 text-xs leading-relaxed text-text-lo">
              when a round goes up, its record lands here: pot size, winners, your seat in it.
            </p>
          </div>
        </div>
      ) : (
        <ol className="mt-4">
          {records.map((r) => (
            <li key={r.round} className="flex flex-wrap items-baseline gap-x-3 gap-y-1 border-t border-line py-3 text-sm">
              <span className="font-data text-text-hi">round {r.round}</span>
              <span className="tabular font-data text-xs text-text-lo">
                {r.pot !== null ? `pot ${fmtAmount(BigInt(r.pot))} mix` : 'pot …'}
              </span>
              <span className="tabular font-data text-xs text-text-lo">
                {r.yourStaked !== null ? `you had ${fmtAmount(BigInt(r.yourStaked))} psp staking` : 'you weren\u2019t staked'}
              </span>
            </li>
          ))}
        </ol>
      )}
    </section>
  )
}
