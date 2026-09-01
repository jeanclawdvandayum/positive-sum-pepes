import { useEffect, useMemo, useState } from 'react'
import { keccak256, toHex } from 'viem'
import { stakerAbi, descriptorAbi } from '../lib/abi'
import { rpcCall } from '../lib/rpc'
import { renderPepeSvg } from '../lib/pepeRender'
import type { RoundInfo } from '../lib/useRound'
import { PixelIcon } from './PixelIcon'

const isZero = (a: string | undefined) => !a || /^0x0+$/.test(a)

/// dna of a candidate pepe id — mirrors PSPStaker.dnaOf (pure keccak).
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
}

/// The art randomizer — 6 candidate pepes rendered by the ON-CHAIN descriptor
/// (eth_call renderSVG(keccak(id))). What you see is exactly what you'll mint:
/// lockWithPepe(amount, id) commits that id, and its dna is the previewed dna.
/// Refresh rolls 6 fresh ids. This is the "choose your pepe" step of staking.
export default function PepePicker({ round, selected, onSelect, seed, onReroll }: Props) {
  const staker = round.staker
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
          <h2 className="font-display text-lg text-text-hi">choose your pepe</h2>
          <p className="truncate text-xs text-text-lo">
            {localMode
              ? 'rolled locally — same art data the contract renders'
              : 'rolled fresh from the on-chain renderer · the one you pick is the one you mint'}
          </p>
        </div>
        <button
          className="st-btn shrink-0 text-xs"
          onClick={() => {
            onSelect(null)
            onReroll()
          }}
        >
          <PixelIcon name="die" size={16} /> refresh
        </button>
      </div>

      {/* compact horizontal strip — not a grid (B3 item 2) */}
      <div className="mt-3 flex gap-2 overflow-x-auto pb-1">
        {candidates.map((id) => {
          const isSel = selected === id
          const svg = svgs[id.toString()]
          return (
            <button
              key={id.toString()}
              onClick={() => onSelect(isSel ? null : id)}
              className={`relative h-24 w-24 shrink-0 rounded-xl border p-1 transition sm:h-28 sm:w-28 ${
                isSel
                  ? 'border-pepe bg-bg-2 ring-1 ring-pepe'
                  : 'border-line bg-bg-2/50 hover:border-text-lo'
              }`}
            >
              <div className="h-full w-full [&>svg]:h-full [&>svg]:w-full">
                {svg ? (
                  <div dangerouslySetInnerHTML={{ __html: svg }} className="h-full w-full" />
                ) : (
                  <div className="skeleton h-full w-full rounded-lg" />
                )}
              </div>
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
          ? `pepe #${selected.toString()} locked in — pick another or stake below`
          : 'tap a pepe to select it'}
      </p>
    </div>
  )
}
