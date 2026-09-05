import { useMemo } from 'react'
import { Link } from 'react-router-dom'
import Clock from '../components/Clock'
import { useCaptureReferral } from '../components/ReferralCard'
import { randomDna, renderPepeSvg } from '../lib/pepeRender'
import { BeatDiagram, DiagramStyles, type BeatKind } from './explainer/diagrams'
import { targetChain } from '../lib/config'
import PayoutSlider from './explainer/PayoutSlider'
import CurveExplainer from './explainer/CurveExplainer'

// ─────────────────────────────────────────────────────────────────────────────
// / — the explainer (REDESIGN-B1 §1–§4). Narrative, not a card wall:
// hero → six beats → repeating curve → the math → settlement.
// Game rules follow READINESS.md; the hero clock uses the shared live deadline.
// ─────────────────────────────────────────────────────────────────────────────

const SUBHEAD =
  'positive sum pepes is a countdown-driven bonding-curve game. buy PSP → buy time → hold a ladder spot → split the pot. staking pays you to stay. after detonation, redeem PSP for its share of remaining backing. this can be less than your purchase cost.'

const BEATS: { n: string; name: string; copy: string; kind: BeatKind }[] = [
  {
    n: '01',
    name: 'backed by mixETH',
    copy: 'the game’s reserve asset is Alchemix’s mixETH, a yield-earning ETH vault token built on ERC-4626. as its external strategies earn yield, each mixETH share can represent more ETH — bringing value into the game’s reserves even between trades. the game keeps its accounts in mixETH.',
    kind: 'reserve',
  },
  {
    n: '02',
    name: 'arm',
    copy: 'the clock arms at launch with the round’s configured window. hit zero and trading halts.',
    kind: 'arm',
  },
  {
    n: '03',
    name: 'buy',
    copy: 'every 0.005 mixETH purchased adds +4:20 — but never more than a full clock.',
    kind: 'buy',
  },
  {
    n: '04',
    name: 'climb',
    copy: '60% of each trading fee goes to stakers, 35% to the pot, and 5% to the referral leg. without attribution, that leg splits 4% to the pot and 1% to the deployer.',
    kind: 'climb',
  },
  {
    n: '05',
    name: 'detonate',
    copy: 'clock at zero? anyone — yes, you — can detonate the round.',
    kind: 'detonate',
  },
  {
    n: '06',
    name: 'claim or redeem',
    copy: 'winners claim their share via claimPot() whenever they want — pull-based, no deadline, no sweep.',
    kind: 'claim',
  },
]

const MATH: [string, string][] = [
  ['ladder', 'at detonation the pot splits 25/18/14/10/8/7/6/5/4/3% from newest ticket to oldest.'],
  ['renormalization', 'fewer than 10 entries? shares renormalize, nobody gets dusted.'],
  ['bonding curve', 'PSP price rides a bonding curve: buys push it up, sells glide it down.'],
  ['fee routing', '60% of each trading fee goes to stakers, 35% to the pot, and 5% to the referral leg. without attribution, that leg splits 4% to the pot and 1% to the deployer.'],
]

// stepped timeline: each beat steps further right (staircase, not a card wall)
const STEP_PAD = ['', 'lg:pl-6', 'lg:pl-12', 'lg:pl-18', 'lg:pl-24', 'lg:pl-30']

export default function Landing() {
  useCaptureReferral()
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

      {/* ── 2. one round, six beats ── */}
      <section className="mt-20">
        <h2 className="font-display text-2xl sm:text-3xl">one round, six beats</h2>
        <ol className="mt-8">
          {BEATS.map((b, i) => (
            <li
              key={b.n}
              className={`flex flex-col items-start gap-6 border-t border-line py-8 sm:flex-row sm:items-center ${STEP_PAD[i]}`}
            >
              <BeatDiagram kind={b.kind} />
              <div className="min-w-0 max-w-md">
                <div className="tabular font-data text-sm text-text-lo">
                  {b.n} · {b.name}
                </div>
                <p className="mt-2 leading-relaxed">{b.copy}</p>
                {b.kind === 'reserve' && (
                  <>
                    {targetChain.testnet && (
                      <p className="mt-3 text-xs leading-relaxed text-text-lo">
                        this testnet uses mock mixETH, which does not earn real yield.
                      </p>
                    )}
                    <a
                      href="https://docs.alchemix.fi/"
                      target="_blank"
                      rel="noopener noreferrer"
                      className="mt-2 inline-block text-xs text-text-lo underline underline-offset-4 hover:text-text-hi"
                    >
                      learn about Alchemix’s mix-yield tokens ↗
                    </a>
                  </>
                )}
              </div>
            </li>
          ))}
        </ol>
      </section>

      <CurveExplainer />

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

      {/* ── 4. settlement after detonation ── */}
      <section className="mt-24 pb-20 text-left">
        <p className="text-sm text-text-lo">settlement after detonation</p>
        <h2 className="mt-4 max-w-4xl font-display text-[clamp(2.25rem,5vw,4rem)] leading-[1.1]">
          compete for the pot. redeem remaining backing after detonation.
        </h2>
        <p className="mt-6 max-w-xl leading-relaxed text-text-lo">
          after detonation, redemption has no deadline. payouts depend on remaining backing and floor rounding; they do not guarantee your original purchase cost.
        </p>
      </section>
    </div>
  )
}
