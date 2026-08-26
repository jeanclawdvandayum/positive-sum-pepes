import { useEffect, useMemo, useState } from 'react'
import { usePublicClient } from 'wagmi'
import { parseAbiItem } from 'viem'
import { useRound } from '../lib/useRound'
import { fmtAmount, fmtPrice } from '../lib/format'

interface Trade {
  block: bigint
  price: number // mixETH per PSP
  volume: number // mixETH
  kind: 'buy' | 'sell'
}

const buyEvent = parseAbiItem(
  'event Buy(address indexed buyer, uint256 mixETHIn, uint256 pspOut, uint256 newSupply, uint256 newReserveMixETH)',
)
const sellEvent = parseAbiItem(
  'event Sell(address indexed seller, uint256 pspIn, uint256 mixETHOut, uint256 newSupply, uint256 newReserveMixETH)',
)
const feesEvent = parseAbiItem('event FeesAdded(uint256 mixETHAmount)')

export default function StatsPanel() {
  const round = useRound()
  const client = usePublicClient()
  const [trades, setTrades] = useState<Trade[]>([])
  const [fees, setFees] = useState<bigint>(0n)

  useEffect(() => {
    if (!client || !round.hook || !round.controller) return
    const c = client
    const hookAddr = round.hook
    const ctrlAddr = round.controller
    let dead = false

    async function load() {
      const [buys, sells, feeLogs] = await Promise.all([
        c.getLogs({ address: hookAddr, event: buyEvent, fromBlock: 0n }),
        c.getLogs({ address: hookAddr, event: sellEvent, fromBlock: 0n }),
        c.getLogs({ address: ctrlAddr, event: feesEvent, fromBlock: 0n }),
      ])
      if (dead) return

      const t: Trade[] = []
      for (const l of buys) {
        const mix = Number(l.args.mixETHIn) / 1e18
        const psp = Number(l.args.pspOut) / 1e18
        if (psp > 0) t.push({ block: l.blockNumber, price: mix / psp, volume: mix, kind: 'buy' })
      }
      for (const l of sells) {
        const psp = Number(l.args.pspIn) / 1e18
        const mix = Number(l.args.mixETHOut) / 1e18
        if (psp > 0) t.push({ block: l.blockNumber, price: mix / psp, volume: mix, kind: 'sell' })
      }
      t.sort((a, b) => (a.block < b.block ? -1 : a.block > b.block ? 1 : 0))
      setTrades(t)
      setFees(feeLogs.reduce((acc, l) => acc + (l.args.mixETHAmount ?? 0n), 0n))
    }

    load().catch(() => {})
    const un = client.watchBlockNumber({ onBlockNumber: () => load().catch(() => {}) })
    return () => {
      dead = true
      un()
    }
  }, [client, round.hook, round.controller])

  const stats = useMemo(() => {
    const volume = trades.reduce((a, t) => a + t.volume, 0)
    const last = trades[trades.length - 1]
    const prev = trades[trades.length - 2]
    const change = last && prev && prev.price > 0 ? (last.price - prev.price) / prev.price : null
    return { volume, last, change, count: trades.length }
  }, [trades])

  const spark = useMemo(() => {
    const tail = trades.slice(-40)
    if (tail.length < 2) return null
    const w = 220
    const h = 56
    const lo = Math.min(...tail.map((t) => t.price))
    const hi = Math.max(...tail.map((t) => t.price))
    const span = hi - lo || hi || 1
    const d = tail
      .map((t, i) => {
        const x = (i / (tail.length - 1)) * w
        const y = h - ((t.price - lo) / span) * h
        return `${i === 0 ? 'M' : 'L'}${x.toFixed(1)},${y.toFixed(1)}`
      })
      .join('')
    return { d, w, h }
  }, [trades])

  return (
    <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
      <div className="card p-5">
        <h3 className="text-xs font-black uppercase tracking-wide text-slate-400">volume</h3>
        <div className="mt-1 text-2xl font-black text-slate-900">
          {fmtAmount(BigInt(Math.round(stats.volume * 1e18)))}
          <span className="ml-1 text-sm font-bold text-slate-400">mixETH</span>
        </div>
        <div className="mt-2 text-xs font-bold text-slate-400">
          {stats.count} trades all-time this round
        </div>
        <div className="mt-3 flex gap-2 text-[11px] font-bold">
          <span className="chip bg-sky-100 text-sky-700">
            🟦 buys {trades.filter((t) => t.kind === 'buy').length}
          </span>
          <span className="chip bg-emerald-100 text-emerald-700">
            🟩 sells {trades.filter((t) => t.kind === 'sell').length}
          </span>
        </div>
      </div>

      <div className="card p-5">
        <h3 className="text-xs font-black uppercase tracking-wide text-slate-400">
          price history
        </h3>
        <div className="mt-1 flex items-baseline gap-2">
          <span className="text-2xl font-black text-slate-900">
            {stats.last ? fmtPrice(BigInt(Math.round(stats.last.price * 1e18))) : '—'}
          </span>
          {stats.change !== null && (
            <span
              className={`text-sm font-black ${
                stats.change >= 0 ? 'text-emerald-500' : 'text-rose-500'
              }`}
            >
              {stats.change >= 0 ? '▲' : '▼'} {(Math.abs(stats.change) * 100).toFixed(2)}%
            </span>
          )}
        </div>
        {spark ? (
          <svg viewBox={`0 0 ${spark.w} ${spark.h}`} className="mt-2 h-14 w-full">
            <path
              d={spark.d}
              fill="none"
              stroke="url(#curveStroke2)"
              strokeWidth="2.5"
              strokeLinecap="round"
            />
            <defs>
              <linearGradient id="curveStroke2" x1="0" y1="0" x2="1" y2="0">
                <stop offset="0%" stopColor="#38bdf8" />
                <stop offset="100%" stopColor="#4ade80" />
              </linearGradient>
            </defs>
          </svg>
        ) : (
          <div className="mt-2 h-14 text-xs text-slate-300">no trades yet</div>
        )}
        <div className="text-[11px] font-bold text-slate-400">
          last 40 trades · mixETH per PSP
        </div>
      </div>

      <div className="card p-5">
        <h3 className="text-xs font-black uppercase tracking-wide text-slate-400">
          fees generated
        </h3>
        <div className="mt-1 text-2xl font-black text-slate-900">
          {fmtAmount(fees)}
          <span className="ml-1 text-sm font-bold text-slate-400">mixETH</span>
        </div>
        <div className="mt-2 text-xs font-bold text-slate-400">
          4.5% → stakers on every trade · 0.5% → referrals
        </div>
        {round.totalLocked !== undefined && round.totalLocked > 0n && (
          <div className="mt-3 text-[11px] font-bold text-emerald-600">
            💎 {fmtAmount(round.totalLocked)} PSP staked and earning
          </div>
        )}
      </div>
    </div>
  )
}
