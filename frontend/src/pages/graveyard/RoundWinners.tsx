import { useEffect, useState } from 'react'
import { fmtAmount, wadToExact } from '../../lib/format'
import { rpcBatchCall } from '../../lib/rpc'
import { readRoundWinners, type RoundWinner } from '../../lib/roundWinners'
import { useWalletPepe } from '../../lib/useWalletPepe'

function WinnerRow({ winner, staker }: { winner: RoundWinner; staker?: `0x${string}` }) {
  const svg = useWalletPepe(winner.address, staker)
  const address = `${winner.address.slice(0, 6)}…${winner.address.slice(-4)}`
  return (
    <li className="grid min-w-0 grid-cols-[3.5rem_minmax(0,1fr)] items-center gap-x-3 gap-y-2 rounded-xl border border-line bg-bg-1 p-3 sm:grid-cols-[3.5rem_minmax(0,1fr)_auto] sm:p-4">
      <span
        role="img" aria-label={`Pepe for ${winner.address}`}
        className="h-14 w-14 overflow-hidden rounded-lg border border-line [&>svg]:block [&>svg]:h-full [&>svg]:w-full"
        style={{ imageRendering: 'pixelated' }}
        dangerouslySetInnerHTML={{ __html: svg }}
      />
      <div className="min-w-0">
        <p className="font-data text-sm text-text-hi" title={winner.address}>{address}</p>
        <p className="mt-1 text-xs leading-relaxed text-text-lo">
          {winner.ranks.length === 1 ? 'seat' : 'seats'} {winner.ranks.map(rank => `#${rank}`).join(', ')}
        </p>
      </div>
      <div className="col-start-2 min-w-0 sm:col-start-auto sm:text-right">
        <p className="break-words font-data text-base text-pot-gold" title={`${wadToExact(winner.payout)} mixETH`}>
          {fmtAmount(winner.payout, 4)} <span className="text-xs">mixETH</span>
        </p>
        <p className="mt-1 text-xs text-text-lo">
          {Number.isInteger(winner.sharePercent) ? winner.sharePercent : winner.sharePercent.toFixed(2)}% of the pot
        </p>
      </div>
    </li>
  )
}

export default function RoundWinners({ hook, staker }: { hook: `0x${string}`; staker?: `0x${string}` }) {
  const [data, setData] = useState<{ hook: string; winners: RoundWinner[]; seats: number }>()
  const [failed, setFailed] = useState(false)
  const [attempt, setAttempt] = useState(0)

  useEffect(() => {
    let stopped = false
    setData(undefined)
    setFailed(false)
    readRoundWinners(rpcBatchCall, hook).then(result => {
      if (!stopped) setData({ hook, ...result })
    }).catch(() => { if (!stopped) setFailed(true) })
    return () => { stopped = true }
  }, [hook, attempt])

  if (failed) return (
    <div className="flex flex-wrap items-center gap-3 py-2 text-sm">
      <p role="alert" className="text-text-lo">the winners list couldn’t load.</p>
      <button onClick={() => { setFailed(false); setAttempt(n => n + 1) }}
        className="rounded-lg border border-line px-3 py-1.5 text-text-hi hover:border-accent focus-visible:outline-2 focus-visible:outline-accent">
        retry winners
      </button>
    </div>
  )
  if (data?.hook !== hook) return <p role="status" className="py-2 text-sm text-text-lo">loading the final ladder…</p>
  if (data.seats === 0) return (
    <p className="py-2 text-sm leading-relaxed text-text-lo">the ladder finished empty. the pot joined this round’s PSP redemption reserves.</p>
  )

  return (
    <div>
      <p className="mb-3 text-xs text-text-lo">
        {data.winners.length} {data.winners.length === 1 ? 'winner' : 'winners'} · {data.seats} winning {data.seats === 1 ? 'seat' : 'seats'} · final prizes, including amounts already claimed
      </p>
      <ul className="flex flex-col gap-2" aria-label="round winners">
        {data.winners.map(winner => <WinnerRow key={winner.address.toLowerCase()} winner={winner} staker={staker} />)}
      </ul>
      <p className="mt-3 text-xs leading-relaxed text-text-lo">
        Pepes show each wallet’s current NFT from this round, or its address Pepe. Prizes are rounded down per seat.
      </p>
    </div>
  )
}
