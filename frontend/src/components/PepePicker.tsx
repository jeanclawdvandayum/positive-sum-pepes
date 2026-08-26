import { useEffect, useMemo, useState } from 'react'
import { keccak256, toHex } from 'viem'
import { stakerAbi, descriptorAbi } from '../lib/abi'
import { rpcCall } from '../lib/rpc'
import { renderPepeSvg } from '../lib/pepeRender'
import type { RoundInfo } from '../lib/useRound'

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
    <div className="card p-5">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-lg font-black text-slate-900">🎨 choose your pepe</h2>
          <p className="text-xs text-slate-400">
            {localMode
              ? 'rolled locally — same art data the contract renders'
              : 'rolled fresh from the on-chain renderer · the one you pick is the one you mint'}
          </p>
        </div>
        <button
          className="btn-ghost shrink-0"
          onClick={() => {
            onSelect(null)
            onReroll()
          }}
        >
          🎲 refresh
        </button>
      </div>

      <div className="mt-4 grid grid-cols-3 gap-3">
        {candidates.map((id) => {
          const isSel = selected === id
          const svg = svgs[id.toString()]
          return (
            <button
              key={id.toString()}
              onClick={() => onSelect(isSel ? null : id)}
              className={`relative aspect-square rounded-2xl border-2 p-1 transition ${
                isSel
                  ? 'border-emerald-400 bg-emerald-50 shadow-lg shadow-emerald-100 ring-2 ring-emerald-300'
                  : 'border-sky-100 bg-white hover:border-sky-300 hover:shadow'
              }`}
            >
              <div className="h-full w-full [&>svg]:h-full [&>svg]:w-full">
                {svg ? (
                  <div dangerouslySetInnerHTML={{ __html: svg }} className="h-full w-full" />
                ) : (
                  <div className="grid h-full w-full place-items-center text-3xl opacity-40">🐸</div>
                )}
              </div>
              {isSel && (
                <span className="absolute -right-1.5 -top-1.5 grid h-6 w-6 place-items-center rounded-full bg-emerald-500 text-xs text-[#fff] shadow">
                  ✓
                </span>
              )}
            </button>
          )
        })}
      </div>

      <p className="mt-3 text-center text-xs font-bold text-slate-400">
        {selected
          ? `pepe #${selected.toString()} locked in — pick another or stake below`
          : 'tap a pepe to select it'}
      </p>
    </div>
  )
}
