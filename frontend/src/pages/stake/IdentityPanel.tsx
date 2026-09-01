// ─────────────────────────────────────────────────────────────────────────────
// IdentityPanel — the den's lead panel (REDESIGN-B3 item 1): the user's pepe
// rendered BIG (pixelated, integer multiples of the 69px source: 207 / 276px),
// or the random preview when disconnected; name (pepe # until the .wei registry
// opens); beneath: staked amount, share of the 60% stream, and the live fee
// accumulator — plus the multiclaim/reinvest row and the parked-fees note.
//
// Art lane is PepePanel's, unchanged: primaryOf → dnaOf → descriptor.renderSVG
// every 6s, local mirror fallback, teaser while disconnected. No new reads.
// ─────────────────────────────────────────────────────────────────────────────

import { useEffect, useState, type ReactNode } from 'react'
import { useAccount } from 'wagmi'
import { stakerAbi, descriptorAbi } from '../../lib/abi'
import { rpcCall } from '../../lib/rpc'
import { renderPepeSvg, randomDna } from '../../lib/pepeRender'
import { fmtAmount } from '../../lib/format'
import type { RoundInfo } from '../../lib/useRound'
import Skeleton from '../../components/Skeleton'
import FeeAccumulator from './FeeAccumulator'

const isZero = (a: string | undefined) => !a || /^0x0+$/.test(a)

interface Props {
  round: RoundInfo
  /** bump to force a refetch (e.g. right after a lock tx lands) */
  refreshKey: number
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
  refreshKey,
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
  const [tokenId, setTokenId] = useState<bigint | undefined>()
  const [dna, setDna] = useState<bigint | undefined>()
  const [svg, setSvg] = useState<string | null>(null)
  const [artOnline, setArtOnline] = useState(false)
  // random preview for disconnected / loading / un-hatched states — per mount
  const [teaser] = useState(() => renderPepeSvg(randomDna()))

  const staker = round.staker

  useEffect(() => {
    if (!address || isZero(staker)) return
    let dead = false
    async function tick() {
      try {
        const id = (await rpcCall(staker!, stakerAbi, 'primaryOf', [address])) as bigint
        if (dead) return
        setTokenId(id)
        if (id === 0n) {
          setDna(undefined)
          setSvg(null)
          return
        }
        const d = (await rpcCall(staker!, stakerAbi, 'dnaOf', [id])) as bigint
        if (dead) return
        setDna(d)
        const desc = (await rpcCall(staker!, stakerAbi, 'descriptor')) as `0x${string}`
        if (dead) return
        if (!isZero(desc)) {
          const art = (await rpcCall(desc, descriptorAbi, 'renderSVG', [d])) as string
          if (dead) return
          setSvg(art)
          setArtOnline(true)
        } else {
          setArtOnline(false)
        }
      } catch {
        /* staker not resolvable — keep last */
      }
    }
    tick()
    const iv = setInterval(tick, 6000)
    return () => {
      dead = true
      clearInterval(iv)
    }
  }, [address, staker, refreshKey])

  // ── art + name states ──
  let art: string | null
  let nameLine: ReactNode
  let subLine: ReactNode

  if (!address) {
    art = teaser
    nameLine = 'connect to meet your pepe'
    subLine = "here's a random one meanwhile — 100M combinations"
  } else if (tokenId === undefined) {
    art = teaser
    nameLine = <Skeleton className="h-6 w-40" />
    subLine = 'looking for your pepe… if this hangs, the dev chain is down — art still renders locally'
  } else if (tokenId === 0n) {
    art = teaser
    nameLine = 'an un-hatched pepe'
    subLine = 'one transaction hatches it — stake any amount, or zero to just collect the art'
  } else {
    art = svg ?? (dna !== undefined ? renderPepeSvg(dna) : null)
    nameLine = (
      <>
        pepe #{tokenId.toString()} <span className="text-text-lo">· pspp</span>
      </>
    )
    subLine = artOnline
      ? 'rendered on-chain · yours forever'
      : 'local render — same art data the contract draws from'
  }

  const dimmed = !!address && tokenId === 0n // un-hatched: the preview sleeps

  return (
    <section className="rounded-2xl border border-line bg-bg-1 p-5 sm:p-6" aria-label="your pepe">
      <div className="flex flex-col gap-6 sm:flex-row sm:gap-8">
        {/* the pepe, big — integer multiples of the 69px source (2× / 4×) */}
        <div className="relative shrink-0 self-center sm:self-start">
          <div
            className="h-[138px] w-[138px] overflow-hidden rounded-xl border border-line sm:h-[276px] sm:w-[276px] [&>svg]:h-full [&>svg]:w-full"
            style={{
              imageRendering: 'pixelated',
              filter: dimmed ? 'grayscale(0.7) opacity(0.55)' : undefined,
            }}
            aria-label={address ? 'your pepe' : 'a random pepe'}
            dangerouslySetInnerHTML={{ __html: art ?? '' }}
          />
        </div>

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

          {/* the emotional core */}
          <div className="mt-5 border-t border-line pt-4">
            <FeeAccumulator value={feesValue} connected={connected} hasStake={hasStake} />
            {claimRow}
            {parked > 0n && (
              <p className="mt-3 text-xs leading-relaxed text-text-lo">
                {fmtAmount(parked)} mixETH of swap fees parked — no staked weight yet, so they attach on
                the next trade once weight exists. nothing is lost while waiting.
              </p>
            )}
          </div>
        </div>
      </div>
    </section>
  )
}
