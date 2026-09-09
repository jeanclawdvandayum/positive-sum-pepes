import { useMemo } from 'react'
import { Link } from 'react-router-dom'
import Clock from '../components/Clock'
import { randomDna, renderPepeSvg } from '../lib/pepeRender'
import { BeatDiagram, DiagramStyles, type BeatKind } from './explainer/diagrams'
import { targetChain } from '../lib/config'
import PayoutSlider from './explainer/PayoutSlider'
import CurveExplainer from './explainer/CurveExplainer'

// Approved manifesto first, then the precise entry, clock and payout rules.
// Illustrations are local CSS. The live clock stays on the shared PhaseEngine.
const BEATS: { name: string; copy: string; kind: BeatKind }[] = [
  {
    name: 'crash the opening party.',
    copy: '24 hours. 1,000 mixETH cap. pick your pepe and join the pooled opening buy. your deposit reserves that face and determines your share. the opening belongs to the people who show up.',
    kind: 'predeposit',
  },
  {
    name: 'give the chart a pulse.',
    copy: 'the sine curve moves through calmer stretches and steep climbs. room to accumulate, room for chaos. something to play beyond the opening candle.',
    kind: 'curve',
  },
  {
    name: 'get paid to stick around.',
    copy: 'stake PSP. stakers split 60% of trading fees. the action pays the people staying for it.',
    kind: 'stake',
  },
  {
    name: 'fight over something.',
    copy: 'buys feed the clock and take ladder spots. when someone detonates the expired round, the tickets still on the ladder split the jackpot. attention has somewhere to go. so does the money.',
    kind: 'jackpot',
  },
  {
    name: 'put a face on your bags.',
    copy: 'your staking position is a pepe NFT. feed it, trade it, keep it after withdrawing. give your financial decisions the face they deserve.',
    kind: 'nft',
  },
  {
    name: 'make the backing work.',
    copy: 'mixETH can earn yield outside the game, growing the ETH behind the reserves. that’s the positive-sum part. fresh value coming in while everyone’s fighting over the pot.',
    kind: 'reserve',
  },
  {
    name: 'settle the wreckage.',
    copy: 'detonation opens every lock and flattens the curve. redeem PSP for its proportional share of the remaining backing whenever you’re ready.',
    kind: 'settle',
  },
  {
    name: 'run it back.',
    copy: 'the token factory needs another ticker and another sales pitch. PSP has another round. after detonation, anyone can help launch its successor. fresh predeposit. fresh token. fresh chart. old claims stay with the old round.',
    kind: 'respawn',
  },
]

const RULES: [string, string][] = [
  ['buying in', 'the minimum buy is 0.005 mixETH, including fees. every full 0.005 mixETH buys one ladder ticket. one wallet can hold several spots.'],
  ['feeding the clock', 'each ticket adds up to 4 minutes and 20 seconds, capped at 69 hours, 4 minutes and 20 seconds in this testnet. a 0.05 mixETH buy takes all ten spots and adds up to 43 minutes and 20 seconds.'],
  ['hitting zero', 'the countdown starts at launch. trading stops at zero. anyone can detonate the round to settle the ladder and open the staking locks.'],
  ['ladder payouts', 'with ten tickets, the pot splits 25/18/14/10/8/7/6/5/4/3% from newest to oldest.'],
  ['smaller ladders', 'one ticket gets the whole pot. with two to nine tickets, each gets a larger share using the same relative weights.'],
  ['trading fees', '60% of each trading fee goes to stakers and 35% goes to the pot.'],
  ['referrals', 'with a recorded referral, the final 5% goes to the referral chain. for everyone else, 4% goes to the pot and 1% goes to the deployer.'],
  ['cashing out', 'ladder winnings stay claimable after detonation. PSP redeems for its proportional share of that round’s remaining mixETH, with payouts rounded down.'],
  ['what’s immutable', 'each round’s deployed contract code stays fixed. the factory owner retains controls for future curves and artwork, the stored UI and pending round reservations.'],
]

export default function Landing() {
  const greeter = useMemo(() => renderPepeSvg(randomDna()), [])

  return (
    <div className="xd-page font-body text-text-hi">
      <DiagramStyles />

      <section className="grid items-center gap-10 pt-10 pb-4 sm:pt-14 lg:grid-cols-[minmax(0,1fr)_17.25rem] lg:gap-12">
        <div className="min-w-0">
          <h1 className="max-w-3xl font-display text-[clamp(3.25rem,7.5vw,6rem)] leading-[1.05] tracking-tight">
            the anti memecoin,<br />
            <span className="text-accent">memecoin.</span>
          </h1>
          <p className="mt-6 text-xl leading-snug sm:text-2xl">
            new ticker. same insiders. same bullshit.
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
          <Link
            to="/play"
            className="mt-8 inline-flex items-center justify-center rounded-xl bg-accent px-7 py-3 text-base font-semibold text-bg-0 transition hover:brightness-110 active:translate-y-[1px]"
          >
            buy psp
          </Link>
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

      <p className="mt-14 font-data text-sm text-text-lo sm:mt-20">every piece has a job.</p>

      <div className="mt-5 grid gap-x-10 lg:grid-cols-2">
        {BEATS.map(b => (
          <section key={b.kind} aria-labelledby={`story-${b.kind}`}
            className="flex min-w-0 flex-col items-start gap-5 border-t border-line py-8 sm:flex-row">
            <BeatDiagram kind={b.kind} />
            <div className="min-w-0">
              <h2 id={`story-${b.kind}`} className="font-display text-2xl leading-tight">{b.name}</h2>
              <p className="mt-3 leading-relaxed text-text-lo">{b.copy}</p>
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
        ))}
      </div>

      <section className="mt-12 rounded-2xl border border-line bg-bg-1 p-6 sm:p-10" aria-labelledby="landing-rules">
        <h2 id="landing-rules" className="font-display text-2xl sm:text-3xl">where the money goes</h2>
        <dl className="mt-8">
          {RULES.map(([term, def]) => (
            <div key={term} className="grid gap-1 border-t border-line py-4 sm:grid-cols-[12rem_1fr] sm:gap-6">
              <dt className="font-data text-sm text-text-lo">{term}</dt>
              <dd className="max-w-2xl leading-relaxed">{def}</dd>
            </div>
          ))}
        </dl>
        <PayoutSlider />
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
