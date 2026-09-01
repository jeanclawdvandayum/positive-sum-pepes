import { useMemo } from 'react'
import { Link } from 'react-router-dom'
import Clock from '../components/Clock'
import { randomDna, renderPepeSvg } from '../lib/pepeRender'
import { BeatDiagram, DiagramStyles } from './explainer/diagrams'
import PayoutSlider from './explainer/PayoutSlider'

// ─────────────────────────────────────────────────────────────────────────────
// / — the explainer (REDESIGN-B1 §1–§4). Narrative, not a card wall:
// hero → one round, five beats → the math, straight → no rug, ever.
//
// Copy policy: every sentence below is existing lineage copy kept verbatim
// (sigmabf Explainer + inventory §5 claims) — the numbers mirror the
// contracts; do not paraphrase them. Voice stays lowercase, wry.
//
// The hero Clock is the REAL instrument. No deadline is wired yet (the
// contract exposes no round timer), so PhaseEngine idles and the Clock runs
// its spec §8 pre-launch state: dimmed 72:00:00, "armed the moment the round
// launches." setDeadline() stays ready for contract wiring — no invented
// chain reads, no fake liveness (B0 conflict #1, DECIDED).
// ─────────────────────────────────────────────────────────────────────────────

const SUBHEAD =
  'positive sum pepes is FOMO3D with the rug surgically removed. buy PSP → buy time → hold a ladder spot → split the pot. staking pays you to stay. redemption means you can always walk away whole'

const BEATS: { n: string; name: string; copy: string; kind: 'arm' | 'buy' | 'climb' | 'detonate' | 'claim' }[] = [
  {
    n: '01',
    name: 'arm',
    copy: 'the clock arms at launch with 72:00:00 on it. hit zero and trading halts.',
    kind: 'arm',
  },
  {
    n: '02',
    name: 'buy',
    copy: 'every WHOLE PSP bought adds +5:00 — but never more than a full clock.',
    kind: 'buy',
  },
  {
    n: '03',
    name: 'climb',
    copy: 'fees stream to the stakers and pile into the pot — plus a fixed 0.5% of every trade to whoever\'s link brought you.',
    kind: 'climb',
  },
  {
    n: '04',
    name: 'detonate',
    copy: 'clock at zero? anyone — yes, you — can push the button and carpetBomb().',
    kind: 'detonate',
  },
  {
    n: '05',
    name: 'claim or redeem',
    copy: 'winners claim their share via claimPot() whenever they want — pull-based, no deadline, no sweep.',
    kind: 'claim',
  },
]

const MATH: [string, string][] = [
  ['ladder', 'at detonation the pot splits 25/18/14/10/8/7/6/5/4/3% from newest ticket to oldest.'],
  ['renormalization', 'fewer than 10 entries? shares renormalize, nobody gets dusted.'],
  ['bonding curve', 'PSP price rides a bonding curve: buys push it up, sells glide it down.'],
  ['fee routing', 'fees stream to the stakers and pile into the pot — plus a fixed 0.5% of every trade to whoever\'s link brought you.'],
]

// stepped timeline: each beat steps further right (staircase, not a card wall)
const STEP_PAD = ['', 'lg:pl-6', 'lg:pl-12', 'lg:pl-18', 'lg:pl-24']

export default function Landing() {
  // one greeter pepe per load — the same "the header IS the art" lane
  const greeter = useMemo(() => renderPepeSvg(randomDna()), [])

  return (
    <div className="xd-page font-body text-text-hi">
      <DiagramStyles />

      {/* ── 1. hero ── */}
      <section className="pt-10 pb-4 sm:pt-14">
        <div className="flex flex-wrap items-end gap-x-10 gap-y-6">
          <div>
            {/* the REAL clock, embedded live — prelaunch idle state per §8 */}
            <Clock variant="mini" />
            <p className="mt-2 text-xs text-text-lo">armed the moment the round launches.</p>
          </div>
          <span
            className="block h-[138px] w-[138px] shrink-0 overflow-hidden rounded-lg border border-line sm:h-[207px] sm:w-[207px] [&>svg]:h-full [&>svg]:w-full"
            style={{ imageRendering: 'pixelated' }}
            aria-label="a greeter pepe"
            dangerouslySetInnerHTML={{ __html: greeter }}
          />
        </div>

        <h1 className="mt-10 font-display text-[clamp(4rem,8vw,6rem)] leading-[1.05] tracking-tight">
          a bomb, a clock, and a pot that only grows
        </h1>

        <p className="mt-6 max-w-2xl text-base leading-relaxed text-text-lo">{SUBHEAD}</p>

        <div className="mt-8">
          <Link
            to="/play"
            className="inline-flex items-center justify-center rounded-xl bg-accent px-7 py-3 text-base font-semibold text-bg-0 transition hover:brightness-110 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent active:translate-y-[1px]"
          >
            buy psp
          </Link>
        </div>
      </section>

      {/* ── 2. one round, five beats ── */}
      <section className="mt-20">
        <h2 className="font-display text-2xl sm:text-3xl">one round, five beats</h2>
        <ol className="mt-8">
          {BEATS.map((b, i) => (
            <li
              key={b.n}
              className={`flex flex-col items-start gap-6 border-t border-line py-8 sm:flex-row sm:items-center ${STEP_PAD[i]}`}
            >
              <BeatDiagram kind={b.kind} />
              <div className="max-w-md">
                <div className="tabular font-data text-sm text-text-lo">
                  {b.n} · {b.name}
                </div>
                <p className="mt-2 leading-relaxed">{b.copy}</p>
              </div>
            </li>
          ))}
        </ol>
      </section>

      {/* ── 3. the math, straight ── */}
      <section className="mt-20 rounded-2xl border border-line bg-bg-1 p-6 sm:p-10">
        <h2 className="font-display text-2xl sm:text-3xl">the math, straight</h2>
        <dl className="mt-8">
          {MATH.map(([term, def]) => (
            <div key={term} className="grid gap-1 border-t border-line py-4 sm:grid-cols-[12rem_1fr] sm:gap-6">
              <dt className="font-data text-sm text-text-lo">{term}</dt>
              <dd className="leading-relaxed">{def}</dd>
            </div>
          ))}
        </dl>
        <PayoutSlider />
      </section>

      {/* ── 4. no rug, ever ── */}
      <section className="mt-24 pb-20 text-center">
        <p className="text-sm text-text-lo">no rug, ever</p>
        <p className="mx-auto mt-4 max-w-4xl font-display text-[clamp(2.25rem,5vw,4rem)] leading-[1.1]">
          worst case you redeem, best case you win the pot.
        </p>
        <p className="mx-auto mt-6 max-w-xl leading-relaxed text-text-lo">
          redemption and flat settlement are always available — PSP can always be exited for its
          backing.
        </p>
      </section>
    </div>
  )
}
