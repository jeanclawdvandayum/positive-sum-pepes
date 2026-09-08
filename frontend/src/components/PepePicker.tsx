import { useEffect, useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { keccak256, toHex } from 'viem'
import { stakerAbi, descriptorAbi } from '../lib/abi'
import { rpcCall } from '../lib/rpc'
import { renderPepeSvg } from '../lib/pepeRender'
import type { RoundInfo } from '../lib/useRound'
import { PixelIcon } from './PixelIcon'
import { CHAIN_ID } from '../lib/config'
import { usePepeDnaVersion } from '../lib/usePepeDnaVersion'
import { fmtPepeId } from '../lib/format'

const isZero = (a: string | undefined) => !a || /^0x0+$/.test(a)

/// DNA of an unminted candidate ID. Owned NFTs must read dnaOf on-chain:
/// automatic mints can receive different available art after a collision.
export function dnaOfId(id: bigint): bigint {
  return BigInt(keccak256(toHex(id, { size: 32 })))
}

interface Props {
  round: RoundInfo
  selected: bigint | null
  onSelect: (id: bigint | null) => void
  /** re-roll the candidate set */
  seed: number
  onReroll: () => void
  disabled?: boolean
  actionLabel?: string
}

/// The art randomizer — 6 candidate pepes rendered by the ON-CHAIN descriptor
/// (eth_call renderSVG(keccak(id))). What you see is exactly what you'll mint:
/// lockWithPepe(amount, id) commits that id, and its dna is the previewed dna.
/// Refresh rolls 6 fresh ids. This is the "choose your accomplice" step of staking.
export default function PepePicker({ round, selected, onSelect, seed, onReroll, disabled = false, actionLabel = 'stake' }: Props) {
  const staker = round.staker
  const dnaVersion = usePepeDnaVersion(staker)
  const [descriptor, setDescriptor] = useState<string | undefined>()
  const [svgs, setSvgs] = useState<Record<string, string>>({})
  const [localMode, setLocalMode] = useState(false)

  // candidate ids: random uints in a range that never collides with the
  // sequential counter's early ids — user-entropy territory.
  const candidates = useMemo(() => {
    const out: bigint[] = []
    let rng = seed * 2654435761 + 0x9e3779b9
    for (let i = 0; i < 6; i++) {
      rng = (rng * 1103515245 + 12345) >>> 0
      const hi = BigInt(Math.floor(Math.random() * 0xffff)) * 0x100000000n + BigInt(rng)
      out.push(1_000_000_000_000n + hi) // ≥ 1e12, far above sequential ids
    }
    return out
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [seed])

  const { data: available } = useQuery({
    queryKey: ['pepe-candidates', CHAIN_ID, staker, candidates.map(String)],
    enabled: !!staker && dnaVersion === 1n,
    queryFn: () => Promise.all(candidates.map(id => rpcCall(staker!, stakerAbi, 'isPepeAvailable', [id]) as Promise<boolean>)),
    refetchInterval: 6000,
  })
  useEffect(() => {
    if (!disabled && selected !== null && available?.[candidates.indexOf(selected)] === false) onSelect(null)
  }, [selected, available, candidates, onSelect, disabled])

  useEffect(() => {
    if (!staker || isZero(staker)) return
    rpcCall(staker, stakerAbi, 'descriptor')
      .then((d) => setDescriptor(d as string))
      .catch(() => setDescriptor(undefined))
  }, [staker])

  // no descriptor / chain down? render locally from the same art data the
  // contract renders — the picker never shows empty tiles
  useEffect(() => {
    if (descriptor && !isZero(descriptor)) {
      setLocalMode(false)
      return
    }
    const next: Record<string, string> = {}
    for (const id of candidates) next[id.toString()] = renderPepeSvg(dnaOfId(id))
    setSvgs(next)
    setLocalMode(true)
  }, [descriptor, candidates])

  useEffect(() => {
    if (!descriptor || isZero(descriptor)) return
    let dead = false
    const next: Record<string, string> = {}
    const descAddr = descriptor as `0x${string}`
    Promise.all(
      candidates.map(async (id) => {
        const dna = dnaOfId(id)
        const svg = (await rpcCall(descAddr, descriptorAbi, 'renderSVG', [dna])) as string
        next[id.toString()] = svg
      }),
    )
      .then(() => {
        if (!dead) setSvgs(next)
      })
      .catch(() => {
        /* keep whatever rendered */
      })
    return () => {
      dead = true
    }
  }, [descriptor, candidates])

  return (
    <div className="rounded-2xl border border-line bg-bg-1 p-4">
      <div className="flex items-center justify-between gap-3">
        <div className="min-w-0">
          <h2 className="font-display text-lg text-text-hi">choose your accomplice</h2>
          <p className="text-xs leading-relaxed text-text-lo">
            {localMode
              ? 'local preview · pick the pepe you’ll mint'
              : 'pick a face for your financial decisions. this is the pepe you’ll mint.'}
          </p>
        </div>
        <button
          className="st-btn shrink-0 text-xs"
          disabled={disabled}
          onClick={() => {
            onSelect(null)
            onReroll()
          }}
        >
          <PixelIcon name="die" size={16} /> refresh
        </button>
      </div>

      <div className="mt-3 grid grid-cols-3 gap-3">
        {candidates.map((id, index) => {
          const isSel = selected === id
          const taken = available?.[index] === false
          const svg = svgs[id.toString()]
          return (
            <button
              key={id.toString()}
              type="button"
              aria-label={`select pepe #${id}`}
              aria-pressed={isSel}
              disabled={disabled || taken}
              onClick={() => onSelect(isSel ? null : id)}
              className={`relative aspect-square w-full min-w-0 rounded-xl border p-1 transition disabled:cursor-not-allowed disabled:opacity-40 ${
                isSel
                  ? 'border-pepe bg-bg-2 ring-1 ring-pepe'
                  : 'border-line bg-bg-2/50 hover:border-text-lo'
              }`}
            >
              <div className="h-full w-full [&>svg]:h-full [&>svg]:w-full">
                {svg ? (
                  <div dangerouslySetInnerHTML={{ __html: svg }} className="h-full w-full [&>svg]:h-full [&>svg]:w-full" />
                ) : (
                  <div className="skeleton h-full w-full rounded-lg" />
                )}
              </div>
              {taken && <span className="absolute inset-x-1 bottom-1 rounded bg-bg-0 p-1 text-xs text-text-hi">already minted</span>}
              {isSel && (
                <span className="absolute -right-1.5 -top-1.5 grid h-6 w-6 place-items-center rounded-full bg-pepe text-xs text-bg-0">
                  ✓
                </span>
              )}
            </button>
          )
        })}
      </div>

      <p className="mt-2 text-xs text-text-lo">
        {selected
          ? `pepe #${fmtPepeId(selected)} selected · pick another or ${actionLabel} below`
          : 'tap a pepe to select it'}
      </p>
    </div>
  )
}
