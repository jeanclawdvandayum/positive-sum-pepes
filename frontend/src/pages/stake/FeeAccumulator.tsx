import Skeleton from '../../components/Skeleton'

function fmtAccum(n: number): string {
  if (!Number.isFinite(n) || n <= 0) return '0.00000000'
  if (n < 0.001) return n.toFixed(8) // sub-milli drips stay visible while tiny
  return n.toLocaleString('en-US', { minimumFractionDigits: 6, maximumFractionDigits: 6 })
}

export default function FeeAccumulator({
  value,
  connected,
  hasStake,
}: {
  /** Σ feesPaid + pendingFeesOf across the wallet's pepes (existing 6s lane) */
  value: bigint | undefined
  connected: boolean
  hasStake: boolean
}) {
  // designed empty states (spec §8 voice)
  if (!connected) {
    return (
      <div>
        <div className="text-xs text-text-lo">total fees earned</div>
        <p className="mt-2 max-w-[26rem] text-sm leading-relaxed text-text-lo">
          connect your wallet to check what your pepe has earned.
        </p>
      </div>
    )
  }
  if (!hasStake) {
    return (
      <div>
        <div className="text-xs text-text-lo">total fees earned</div>
        <p className="mt-2 max-w-[26rem] text-sm leading-relaxed text-text-lo">
          put PSP in a pepe. let the trading fees come to you.
        </p>
      </div>
    )
  }


  // Chain readings only: paid fees plus the current claimable balance.
  const display = value !== undefined ? Number(value) / 1e18 : 0
  const idle = value === 0n
  const formatted = fmtAccum(display)

  return (
    <div className="min-w-0" style={{ containerType: 'inline-size' }}>
      <div className="text-xs text-text-lo">total fees earned</div>
      {value === undefined ? (
        <Skeleton className="mt-2 h-10 w-60 max-w-full" />
      ) : (
        <>
          <div
            className="st-accum mt-2 pr-2"
            // Size against this column, keeping every digit plus right padding.
            style={{ fontSize: `min(2.25rem, calc((100cqi - 0.5rem) / ${formatted.length * 0.62}))` }}
            role="status"
            aria-label="total fees earned"
          >
            {formatted}
          </div>
          <div className="mt-1.5 text-xs text-text-lo">
            {idle ? 'mixETH · accrued fees appear here' : 'mixETH · claimed + pending across these positions'}
          </div>
        </>
      )}
    </div>
  )
}
