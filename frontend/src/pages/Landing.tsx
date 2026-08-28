import type { ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { PixelIcon } from '../components/PixelIcon'
import MixLogo from '../components/MixLogo'
import { useRound } from '../lib/useRound'
import { fmtAmount, fmtPrice } from '../lib/format'

const mechanics = [
  {
    icon: 'chart',
    title: 'bonding curve',
    color: 'from-sky-400 to-sky-500',
    body: 'every buy climbs a preset price curve; every sell walks it back down. no LPs to farm you, no rug to pull — the curve is the market and it never sleeps. it runs as a uniswap v4 hook on a real v4 pool: battle-tested plumbing, zero custodians.',
  },
  {
    icon: 'window',
    title: 'predeposit window',
    color: 'from-emerald-400 to-emerald-500',
    body: 'each round opens with a short predeposit window. up to 500 mixETH gets first position at the seed price and PSP auto-locks at launch. miss it and you buy on the open curve.',
  },
  {
    icon: 'diamond',
    title: 'stake & earn fees',
    color: 'from-teal-400 to-emerald-400',
    body: 'lock PSP and every curve fee flows to stakers pro-rata, in mixETH. your bag yield-farms the degens. extend anytime in the final week.',
  },
  {
    icon: 'bomb',
    title: 'carpet bomb',
    color: 'from-amber-400 to-orange-500',
    body: 'if stakers vote with 69% quorum and a majority, the round is flattened: every lock opens immediately and the curve goes flat so stakers can exit at average backing. after the exit window closes, whatever remains drains to the factory and the next round is born with the treasure.',
  },
  {
    icon: 'sum',
    title: 'positive sum',
    color: 'from-sky-400 to-emerald-400',
    body: 'the whole reserve sits in mixETH, an ETH yield token curated by alchemix dao — defi OGs running trusted infrastructure since 2021 — so the pot earns from outside the game and your backing compounds even when nobody trades. fees recycle to stakers instead of extracting. the math tilts positive for everyone who stays.',
  },
  {
    icon: 'shield',
    title: 'your keys, your pepes',
    color: 'from-cyan-400 to-sky-500',
    body: 'non-custodial end to end. mixETH in, mixETH out — every trade settles against the round pool in a single transaction. no admin keys on the curve, no pausing, no upgrades mid-game.',
  },
]

export default function Landing() {
  const round = useRound()

  return (
    <div>
      {/* hero */}
      <section className="relative overflow-hidden rounded-3xl border border-sky-100 bg-gradient-to-br from-sky-100 via-white to-emerald-100 px-6 py-14 text-center sm:py-20">
        <div className="blob left-[-80px] top-[-60px] h-64 w-64 bg-psp-sky" />
        <div className="blob right-[-60px] bottom-[-80px] h-64 w-64 bg-psp-mint" />
        <div className="relative">
          <div className="flex flex-col items-center justify-center gap-2 sm:flex-row">
            <span className="chip bg-white/80 text-psp-deep shadow-sm">
              round #{round.id.toString()} · {round.mode === 1 ? 'live' : round.mode === 0 ? 'predeposit open' : round.mode === 3 ? 'destroyed' : 'flat'}
            </span>
            <span className="chip bg-white/80 text-psp-deep shadow-sm">built on uniswap v4</span>
          </div>
          <h1 className="mt-4 text-4xl font-black leading-tight text-slate-900 sm:text-6xl">
            the game that pays you{' '}
            <span className="bg-gradient-to-r from-sky-500 to-emerald-500 bg-clip-text text-transparent">
              to stay
            </span>
          </h1>
          <p className="mx-auto mt-4 max-w-2xl text-base text-slate-600 sm:text-lg">
            positive sum pepes is a fully on-chain bonding curve game. buy the dip on the
            curve, stake for a cut of every trade, and vote to carpet-bomb the round when
            the cycle is done — the treasury inherits into round n+1.
          </p>
          <div className="mt-8 flex flex-col items-center justify-center gap-3 sm:flex-row">
            <Link to="/trade" className="btn-primary w-full sm:w-auto">
              start trading →
            </Link>
            <Link to="/stake" className="btn-ghost w-full sm:w-auto">
              stake your pepes
            </Link>
          </div>
          <div className="mx-auto mt-10 grid max-w-2xl grid-cols-3 gap-2 sm:gap-4">
            <HeroStat
              label="reserve"
              value={
                <>
                  {fmtAmount(round.reserve)} <MixLogo px={28} /> mix
                </>
              }
            />
            <HeroStat label="supply" value={`${fmtAmount(round.supply)} PSP`} />
            <HeroStat label="price" value={`${fmtPrice(round.marginalPrice)}`} />
          </div>
        </div>
      </section>

      {/* what is this */}
      <section className="mt-10">
        <h2 className="text-2xl font-black text-slate-900 sm:text-3xl">what is this?</h2>
        <p className="mt-3 text-slate-600">
          a memecoin with a mechanical soul. PSP mints and burns along a deterministic
          price curve denominated in mixETH — an ETH yield token. sells on the curve pay
          a toll that accrues to everyone who stakes, and because the entire reserve
          sits in mixETH, its yield keeps flowing into the pot from outside the game:
          your backing compounds whether the chart is green or not. that outside yield
          is what makes this positive sum — most memecoins recycle nothing. when a
          round is dying, exits are toll-free at exact average backing — nobody pays to
          leave a loser. and there is no team allocation silently diluting
          you: the only way new PSP exists is someone paying real reserves
          in. and the whole engine is a uniswap v4 hook — the curve lives
          inside a real v4 pool, so this is v4-grade plumbing under a meme
          hood, not an erc-20 with a website.
        </p>
      </section>

      {/* mechanics */}
      <section className="mt-10">
        <h2 className="text-2xl font-black text-slate-900 sm:text-3xl">the mechanics</h2>
        <div className="mt-5 grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {mechanics.map((m) => (
            <div key={m.title} className="card p-5">
              <div
                className={`inline-flex h-11 w-11 items-center justify-center rounded-2xl bg-gradient-to-br ${m.color} shadow-md`}
              >
                <PixelIcon name={m.icon} />
              </div>
              <h3 className="mt-3 text-lg font-extrabold text-slate-900">{m.title}</h3>
              <p className="mt-1 text-sm leading-relaxed text-slate-600">{m.body}</p>
            </div>
          ))}
        </div>
      </section>

      {/* lifecycle strip */}
      <section className="card mt-10 overflow-hidden">
        <div className="bg-gradient-to-r from-sky-400 via-cyan-400 to-emerald-400 px-6 py-3 text-sm font-black uppercase tracking-wide text-[#fff]">
          round lifecycle
        </div>
        <div className="grid grid-cols-1 divide-y divide-sky-50 sm:grid-cols-5 sm:divide-x sm:divide-y-0">
          {[
            ['1', 'predeposit', 'capped window, pooled genesis buy'],
            ['2', 'launch', 'seed buys mint initial PSP'],
            ['3', 'trade', 'curve market, fees accrue'],
            ['4', 'carpet bomb', '69% quorum ends it'],
            ['5', 'rebirth', 'treasure seeds round n+1'],
          ].map(([n, t, d]) => (
            <div key={n} className="p-4">
              <div className="text-xs font-black text-sky-400">step {n}</div>
              <div className="font-extrabold text-slate-900">{t}</div>
              <div className="text-xs text-slate-500">{d}</div>
            </div>
          ))}
        </div>
      </section>
    </div>
  )
}

function HeroStat({ label, value }: { label: string; value: ReactNode }) {
  return (
    <div className="rounded-2xl bg-white/80 px-3 py-3 shadow-sm backdrop-blur">
      <div className="text-lg font-black text-slate-900 sm:text-2xl">{value}</div>
      <div className="text-[11px] font-bold uppercase tracking-wide text-slate-400">
        {label}
      </div>
    </div>
  )
}
