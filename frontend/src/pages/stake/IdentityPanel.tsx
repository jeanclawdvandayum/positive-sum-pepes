import { useState, type ReactNode } from 'react'
import { useAccount } from 'wagmi'
import { renderPepeSvg, randomDna } from '../../lib/pepeRender'
import { fmtAmount } from '../../lib/format'
import type { RoundInfo } from '../../lib/useRound'
import PepeStack from './PepeStack'
import FeeAccumulator from './FeeAccumulator'

interface Props {
  ids: bigint[]
  round: RoundInfo
  staked: bigint
  valueMix: bigint | undefined
  valueUsd: number | undefined
  /** user PSP / totalLocked — their cut of the 60% staker stream */
  sharePct: number | undefined
  feesValue: bigint | undefined
  connected: boolean
  hasStake: boolean
  parked: bigint
  /** multiclaim / reinvest row — logic lives in the page container */
  claimRow?: ReactNode
}

export default function IdentityPanel({
  round,
  ids,
  staked,
  valueMix,
  valueUsd,
  sharePct,
  feesValue,
  connected,
  hasStake,
  parked,
  claimRow,
}: Props) {
  const { address } = useAccount()
  const [teaser] = useState(() => renderPepeSvg(randomDna()))
  const staker = round.staker
  const nameLine = 'staked position(s)'
  const subLine = !address ? 'connect your wallet to find your pepe.'
    : ids.length > 0 ? 'your pepes. your share of the trading fees.'
    : 'pick your accomplice below. add PSP to stake, or enter zero to mint the NFT.'

  return (
    <section className="rounded-2xl border border-line bg-bg-1 p-5 sm:p-6" aria-label="your pepe">
      <div className="grid min-w-0 grid-cols-1 gap-6 sm:grid-cols-2">
        {/* the pepe, big — integer multiples of the 69px source (2× / 4×) */}
        {ids.length > 0 ? <PepeStack key={`${address}:${staker}`} ids={ids} staker={staker} /> : (
          <div className="aspect-square w-full max-w-[276px] overflow-hidden rounded-xl border border-line [&>svg]:h-full [&>svg]:w-full"
            style={{ imageRendering: 'pixelated', filter: address ? 'grayscale(0.7) opacity(0.55)' : undefined }}
            aria-label="a random pepe" dangerouslySetInnerHTML={{ __html: teaser }} />
        )}

        <div className="min-w-0 flex-1">
          <h1 className="font-display text-2xl leading-tight">{nameLine}</h1>
          <p className="mt-1 text-xs text-text-lo">{subLine}</p>

          <dl className="mt-5 grid grid-cols-1 gap-x-6 gap-y-2 border-t border-line pt-4 text-sm sm:grid-cols-2">
            <div className="flex items-baseline justify-between gap-3 sm:block">
              <dt className="text-xs text-text-lo">staked</dt>
              <dd className="tabular font-data text-text-hi">
                {fmtAmount(staked)} <span className="text-xs text-text-lo">psp</span>
              </dd>
            </div>
            <div className="flex items-baseline justify-between gap-3 sm:block">
              <dt className="text-xs text-text-lo">value</dt>
              <dd className="tabular font-data text-text-hi">
                {valueMix !== undefined ? (
                  <>
                    ≈ {fmtAmount(valueMix, 4)} <span className="text-xs text-text-lo">mix</span>
                  </>
                ) : (
                  '…'
                )}
                {valueUsd !== undefined && (
                  <span className="ml-2 text-xs text-text-lo">
                    ≈ ${valueUsd < 1 ? valueUsd.toFixed(4) : valueUsd.toFixed(2)}
                  </span>
                )}
              </dd>
            </div>
            <div className="flex items-baseline justify-between gap-3 sm:block">
              <dt className="text-xs text-text-lo">stream share</dt>
              <dd className="tabular font-data text-text-hi">
                {sharePct !== undefined ? `${sharePct.toFixed(sharePct < 0.01 ? 4 : 2)}%` : '…'}{' '}
                <span className="text-xs text-text-lo">of the 60%</span>
              </dd>
            </div>
          </dl>

        </div>
      </div>
      <div className="mt-5 min-w-0 border-t border-line pt-4">
        <FeeAccumulator value={feesValue} connected={connected} hasStake={hasStake} />
        {claimRow}
        {parked > 0n && <p className="mt-3 text-xs leading-relaxed text-text-lo">
          {fmtAmount(parked)} mixETH in trading fees carried forward. later trades can distribute them once enough fees and eligible staking weight are available.
        </p>}
      </div>
    </section>
  )
}
