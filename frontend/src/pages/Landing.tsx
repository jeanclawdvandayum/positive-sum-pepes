import { useMemo } from 'react'
import { Link } from 'react-router-dom'
import Clock from '../components/Clock'
import { renderDecorativePepeSvg } from '../lib/pepeRender'
import { BeatDiagram, DiagramStyles, type BeatKind } from './explainer/diagrams'
import { targetChain } from '../lib/config'
import PayoutSlider from './explainer/PayoutSlider'
import CurveExplainer from './explainer/CurveExplainer'

// Approved manifesto first, then the precise entry, clock and payout rules.
// Illustrations are local CSS. The live clock stays on the shared PhaseEngine.
const BEATS: { name: string; copy: string; kind: BeatKind }[] = [
  {
    name: 'crash the opening party.',
    copy: 'three days. a public opening buy. pick your pepe and join the pool. your deposit reserves that face and determines your share. the opening belongs to the people who show up.',
    kind: 'predeposit',
  },
  {
    name: 'give the chart a pulse.',
    copy: 'one sine curve runs through the opening buy and trading. ten waves reach 1,000 times the launch price. softened cube-root growth gives earlier waves larger percentage gains. wave width scales with the square root of the opening backing.',
    kind: 'curve',
  },
  {
    name: 'get paid to stick around.',
    copy: 'lock PSP as lePSP, locked earning PSP. lePSP positions split 60% of trading fees. request withdrawal to start a four-week exit. the action pays the people staying for it.',
    kind: 'stake',
  },
  {
    name: 'fight over something.',
    copy: 'every buy takes a ticket, adds time to the clock and sits at seat #1. when the clock hits zero, whoever detonates settles it: the last ten tickets split the prize pot. attention has somewhere to go. so does the money.',
    kind: 'jackpot',
  },
  {
    name: 'put a face on your bags.',
    copy: 'your lePSP position is a pepe NFT. feed it, trade it, keep it after withdrawing. give your financial decisions the face they deserve.',
    kind: 'nft',
  },
  {
    name: 'make the backing work.',
    copy: 'mixETH can earn yield outside the game, growing the ETH behind the reserves. that’s the positive-sum part. fresh value coming in while everyone’s fighting over the pot.',
    kind: 'reserve',
  },
  {
    name: 'settle the wreckage.',
    copy: 'detonation opens every lock and ends trading. redeem PSP for its proportional share of the remaining backing whenever you’re ready.',
    kind: 'settle',
  },
  {
    name: 'run it back.',
    copy: 'the token factory needs another ticker and another sales pitch. PSP has another round. after detonation, anyone can help launch its successor. fresh predeposit. fresh token. fresh chart. old claims stay with the old round.',
    kind: 'respawn',
  },
]

const RULES: [string, string][] = [
  ['buying in', 'the minimum buy is one ticket. a ticket costs the whole prize pot divided by 10,000, rounded up to wei, with a one-wei floor. the opening pot counts. one wallet can hold several tickets.'],
  ['feeding the clock', 'each whole ticket adds up to 69 seconds, capped at the round’s starting duration. the default maximum is 69 hours, 4 minutes and 20 seconds. test rounds can use shorter clocks. ten tickets add up to 11 minutes and 30 seconds. each buy uses the ticket price before its fees enter the pot.'],
  ['hitting zero', 'the countdown starts at launch. trading stops at zero. anyone can detonate the round to settle the ladder and open the staking locks.'],
  ['ladder payouts', 'with ten tickets, the pot splits 25/18/14/10/8/7/6/5/4/3% from newest to oldest.'],
  ['smaller ladders', 'one ticket gets the whole pot. with two to nine tickets, each gets a larger share using the same relative weights.'],
  ['trading fees', 'the fee starts at 10% and decreases with reserves to 2.5% at wave ten. 60% of each fee goes to stakers and 35% goes to the pot.'],
  ['referrals', 'with a recorded referral, the final 5% goes to the referral chain. for everyone else, 4% goes to the pot and 1% goes to the deployer.'],
  ['cashing out', 'ladder winnings stay claimable after detonation. PSP redeems for its proportional share of that round’s remaining mixETH, with payouts rounded down.'],
  ['what’s immutable', 'each round’s deployed contract code stays fixed. the factory owner retains controls for future curves and artwork, the stored UI and pending round reservations.'],
]

const CORE: BeatKind[] = ['predeposit', 'jackpot', 'stake', 'settle']
const LOOP = BEATS.filter(b => CORE.includes(b.kind)).sort((a, b) => CORE.indexOf(a.kind) - CORE.indexOf(b.kind))
const REST = BEATS.filter(b => !CORE.includes(b.kind))

const PLAIN: [string, string][] = [
  ['buy in', 'every buy of at least one ticket puts you at seat #1 on a ten-seat ladder.'],
  ['the clock', 'every ticket adds up to 69 seconds. the clock never goes above where it started.'],
  ['zero', 'trading stops. anyone can detonate. the ten seats split the prize pot, 25% for #1 down to 3% for #10.'],
  ['the pot', 'seeded by 10% of the opening buy, fed by 35% of every trading fee. it only grows.'],
  ['cash out', 'ladder winnings stay claimable forever. every PSP redeems for its share of the backing.'],
]

function Beat({ b }: { b: (typeof BEATS)[number] }) {
  return (
    <section aria-labelledby={`story-${b.kind}`}
      className="flex min-w-0 flex-col items-start gap-5 border-t border-line py-8 sm:flex-row">
      <BeatDiagram kind={b.kind} />
      <div className="min-w-0">
        <h2 id={`story-${b.kind}`} className="font-display text-2xl leading-tight">{b.name}</h2>
        <p className="mt-3 max-w-2xl leading-relaxed text-text-lo">{b.copy}</p>
        {b.kind === 'reserve' && (
          <div className="mt-4 border-l-2 border-line pl-3 text-xs leading-relaxed text-text-lo">
            <p>Alchemix’s mixETH is an ETH vault token (ERC-4626). trades and rewards are counted in mixETH.</p>
            {targetChain.testnet && <p className="mt-2">this testnet uses free practice mixETH with 0% yield.</p>}
            <a href="https://docs.alchemix.fi/" target="_blank" rel="noopener noreferrer"
              className="mt-2 inline-block underline underline-offset-4 hover:text-text-hi">
              more about mixETH ↗
            </a>
          </div>
        )}
      </div>
    </section>
  )
}

export default function Landing() {
  const greeter = useMemo(() => renderDecorativePepeSvg(), [])

  return (
    <div className="xd-page font-body text-text-hi">
      <DiagramStyles />

      <section className="grid items-center gap-10 pt-10 pb-4 sm:pt-14 lg:grid-cols-[minmax(0,1fr)_17.25rem] lg:gap-12">
        <div className="min-w-0">
          <h1 className="max-w-3xl font-display text-[clamp(3.25rem,7.5vw,6rem)] leading-[1.05] tracking-tight">
            the anti memecoin,<br />
            <span className="text-accent">memecoin.</span>
          </h1>
          <p className="mt-6 max-w-2xl text-xl leading-snug sm:text-2xl">
            every buy takes a ticket and feeds the clock. when it hits zero, the last ten
            buyers split the pot. then every PSP redeems for its backing.
          </p>
          <p className="mt-4 text-lg text-text-lo">
            new ticker. same insiders. same bullshit. not here.
          </p>
          <p className="mt-5 max-w-xl leading-relaxed text-text-lo">
            too much of crypto runs on disposable tokens. insiders get the head start.
            everyone else gets the sales pitch. launch, dump, repeat.
          </p>
          <p className="mt-4 max-w-xl leading-relaxed text-text-lo">
            PSP creates something <em>new</em>, mashing together defi locking, bonding curves,
            passive yield, and NFTs, and turbocharging them with human greed as fellow degens
            fight for the pot.
          </p>
          <div className="mt-8 flex flex-wrap items-center gap-3">
            <Link
              to="/play"
              className="inline-flex items-center justify-center rounded-xl bg-accent px-7 py-3 text-base font-semibold text-bg-0 transition hover:brightness-110 active:translate-y-[1px]"
            >
              buy psp
            </Link>
            <a
              href="#how-it-works"
              className="inline-flex items-center justify-center rounded-xl border border-line px-6 py-3 text-base text-text-hi transition hover:border-accent"
            >
              how it works · 30 seconds
            </a>
          </div>
        </div>

        <div className="flex min-w-0 flex-wrap items-center gap-6 lg:flex-col lg:items-start">
          <span
            className="block h-[138px] w-[138px] shrink-0 overflow-hidden rounded-xl border border-line sm:h-[207px] sm:w-[207px] lg:h-[276px] lg:w-[276px] [&>svg]:h-full [&>svg]:w-full"
            style={{ imageRendering: 'pixelated' }}
            role="img"
            aria-label="a greeter pepe"
            dangerouslySetInnerHTML={{ __html: greeter }}
          />
          <div>
            <Clock variant="mini" />
            <p className="mt-2 text-xs text-text-lo">the countdown starts at launch.</p>
          </div>
        </div>
      </section>

      <p id="how-it-works" className="mt-14 scroll-mt-24 font-data text-sm text-text-lo sm:mt-20">the loop. four beats.</p>

      <div className="mt-5 max-w-4xl">
        {LOOP.map(b => <Beat key={b.kind} b={b} />)}
      </div>

      <p className="mt-12 font-data text-sm text-text-lo">the rest of the machine.</p>

      <div className="mt-5 max-w-4xl">
        {REST.map(b => <Beat key={b.kind} b={b} />)}
      </div>

      <section className="mt-12 rounded-2xl border border-line bg-bg-1 p-6 sm:p-10" aria-labelledby="landing-rules">
        <h2 id="landing-rules" className="font-display text-2xl sm:text-3xl">where the money goes</h2>
        <dl className="mt-6">
          {PLAIN.map(([term, def]) => (
            <div key={term} className="grid gap-1 border-t border-line py-3 sm:grid-cols-[12rem_1fr] sm:gap-6">
              <dt className="font-data text-sm text-text-lo">{term}</dt>
              <dd className="max-w-2xl leading-relaxed">{def}</dd>
            </div>
          ))}
        </dl>
        <PayoutSlider />
        <h3 className="mt-10 font-display text-xl">the exact rules</h3>
        <dl className="mt-4">
          {RULES.map(([term, def]) => (
            <div key={term} className="grid gap-1 border-t border-line py-4 sm:grid-cols-[12rem_1fr] sm:gap-6">
              <dt className="font-data text-sm text-text-lo">{term}</dt>
              <dd className="max-w-2xl leading-relaxed">{def}</dd>
            </div>
          ))}
        </dl>
        <details className="xd-curve-detail mt-8 border-t border-line pt-5">
          <summary className="cursor-pointer text-text-lo hover:text-text-hi">take a closer look at the curve</summary>
          <CurveExplainer />
        </details>
      </section>

      <section className="py-16 sm:py-24">
        <h2 className="max-w-4xl font-display text-[clamp(2.75rem,6vw,5rem)] leading-[1.1]">let the game respawn.</h2>
        <p className="mt-6 max-w-2xl leading-relaxed text-text-lo">
          immutable round code. anyone can settle an expired round and help launch the next.
          the game keeps going as long as people keep coming back.
        </p>
        <Link to="/play" className="mt-6 inline-flex items-center gap-3 text-accent underline underline-offset-4">
          get in, loser. we’re taking the pot. <span aria-hidden="true">↗</span>
        </Link>
      </section>
    </div>
  )
}
