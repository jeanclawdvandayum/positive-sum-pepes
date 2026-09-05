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
  'buy PSP to take a place on the ladder and add time to the clock. each new ticket pushes the older ones down. when the clock reaches zero, anyone can detonate the round. the tickets left on the ladder share the pot. stake your PSP to earn trading fees along the way.'

const BEATS: { n: string; name: string; copy: string; kind: BeatKind }[] = [
  {
    n: '01',
    name: 'backed by mixETH',
    copy: 'the game holds its reserves in Alchemix’s mixETH, an ETH vault token (ERC-4626). yield earned outside the game can increase the ETH value of each mixETH held in reserve. trades, fees and rewards are all counted in mixETH.',
    kind: 'reserve',
  },
  {
    n: '02',
    name: 'start the clock',
    copy: 'the countdown starts when the round launches. buys add time, up to the round’s full starting duration.',
    kind: 'arm',
  },
  {
    n: '03',
    name: 'buy a ladder spot',
    copy: 'each full 0.005 mixETH in a buy gets you one ticket and adds up to 4 minutes and 20 seconds. a 0.05 mixETH buy takes all ten spots and adds up to 43 minutes and 20 seconds. fees are included in those amounts.',
    kind: 'buy',
  },
  {
    n: '04',
    name: 'earn trading fees',
    copy: 'stake PSP in a pepe NFT to earn trading fees. stakers receive 60% of each fee. you can claim your rewards or reinvest them into your pepe.',
    kind: 'climb',
  },
  {
    n: '05',
    name: 'detonate',
    copy: 'when the clock reaches zero, trading stops. anyone can press detonate to settle the round and open every staked position for withdrawal.',
    kind: 'detonate',
  },
  {
    n: '06',
    name: 'claim or redeem',
    copy: 'claim your ladder winnings and redeem your PSP for a share of that round’s remaining mixETH. both stay available whenever you’re ready.',
    kind: 'claim',
  },
]

const MATH: [string, string][] = [
  ['ladder payouts', 'with ten tickets, the pot splits 25/18/14/10/8/7/6/5/4/3% from newest to oldest. one wallet can hold several spots.'],
  ['smaller ladders', 'one ticket gets the whole pot. with two to nine tickets, each gets a larger share using the same relative weights.'],
  ['trading fees', '60% of each trading fee goes to stakers and 35% goes to the pot.'],
  ['referrals', 'with a recorded referral, the final 5% goes to the referral chain. for everyone else, 4% goes to the pot and 1% goes to the deployer.'],
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
            <p className="mt-2 text-xs text-text-lo">the countdown starts at launch.</p>
          </div>
          <span
            className="block h-[138px] w-[138px] shrink-0 overflow-hidden rounded-lg border border-line sm:h-[207px] sm:w-[207px] [&>svg]:h-full [&>svg]:w-full"
            style={{ imageRendering: 'pixelated' }}
            aria-label="a greeter pepe"
            dangerouslySetInnerHTML={{ __html: greeter }}
          />
        </div>

        <h1 className="mt-10 font-display text-[clamp(4rem,8vw,6rem)] leading-[1.05] tracking-tight">
          get in, loser. we’re taking the pot.
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
        <h2 className="font-display text-2xl sm:text-3xl">how a round works</h2>
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
                        this testnet uses free practice mixETH with 0% yield.
                      </p>
                    )}
                    <a
                      href="https://docs.alchemix.fi/"
                      target="_blank"
                      rel="noopener noreferrer"
                      className="mt-2 inline-block text-xs text-text-lo underline underline-offset-4 hover:text-text-hi"
                    >
                      read more about mixETH at Alchemix ↗
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
        <h2 className="font-display text-2xl sm:text-3xl">where the money goes</h2>
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
        <p className="text-sm text-text-lo">after the round</p>
        <h2 className="mt-4 max-w-4xl font-display text-[clamp(2.25rem,5vw,4rem)] leading-[1.1]">
          redeem your PSP when you’re ready
        </h2>
        <p className="mt-6 max-w-xl leading-relaxed text-text-lo">
          after detonation, you can redeem PSP at any time for its share of that round’s
          remaining mixETH. payouts are rounded down and can be worth less than you paid.
        </p>
      </section>
    </div>
  )
}
