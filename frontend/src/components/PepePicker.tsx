import { useEffect, useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { keccak256, toHex } from 'viem'
import { stakerAbi } from '../lib/abi'
import { rpcCall } from '../lib/rpc'
import { renderPepeSvg } from '../lib/pepeRender'
import type { RoundInfo } from '../lib/useRound'
import { PixelIcon } from './PixelIcon'
import { CHAIN_ID } from '../lib/config'
import { usePepeDnaVersion } from '../lib/usePepeDnaVersion'
import { fmtPepeId } from '../lib/format'

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
  /** alt UI only: pulse the picker so the IBCO commit flow points here (public/alt/polish.css) */
  attention?: boolean
}

/// The art randomizer — 6 candidate pepes rendered LOCALLY from the bundled
/// art data (dna = keccak(id), the exact dna the round will mint). The chain
/// is consulted only for availability (isPepeAvailable) and the round's DNA
/// version; no per-tile renderSVG eth_calls.
/// Refresh rolls 6 fresh ids. This is the "choose your accomplice" step of staking.
export default function PepePicker({ round, selected, onSelect, seed, onReroll, disabled = false, actionLabel = 'stake', attention }: Props) {
  const staker = round.staker
  const dnaVersion = usePepeDnaVersion(staker)
  const [svgs, setSvgs] = useState<Record<string, string>>({})

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
  }, [seed, staker])

  const { data: available } = useQuery({
    queryKey: ['pepe-candidates', CHAIN_ID, staker, candidates.map(String)],
    enabled: !!staker && (dnaVersion === 1n || dnaVersion === 2n || dnaVersion === 3n),
    queryFn: () => Promise.all(candidates.map(id => rpcCall(staker!, stakerAbi, 'isPepeAvailable', [id]) as Promise<boolean>)),
    refetchInterval: 6000,
  })
  // render all candidates locally (bundled art data, round DNA version)
  useEffect(() => {
    if (dnaVersion === undefined) { setSvgs({}); return }
    const next: Record<string, string> = {}
    for (const id of candidates) next[id.toString()] = renderPepeSvg(dnaOfId(id), dnaVersion)
    setSvgs(next)
  }, [candidates, dnaVersion])

  useEffect(() => {
    if (!disabled && selected !== null && (!candidates.includes(selected) || available?.[candidates.indexOf(selected)] === false)) onSelect(null)
  }, [selected, available, candidates, onSelect, disabled])


  return (
    <div className="rounded-2xl border border-line bg-bg-1 p-4" data-attention={attention === undefined ? undefined : String(attention)}>
      <div className="flex items-center justify-between gap-3">
        <div className="min-w-0">
          <h2 className="font-display text-lg text-text-hi">choose your accomplice</h2>
          <p className="text-xs leading-relaxed text-text-lo">
            {'pick a face for your financial decisions. this is the pepe you’ll mint.'}
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
          {/* key=seed: alt CSS spins the die (polish.css) each time the set re-rolls */}
          <PixelIcon name="die" size={16} key={seed} /> refresh
        </button>
      </div>

      <div className="mt-3 grid grid-cols-3 gap-3" data-pepe-grid="">
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
              disabled={disabled || taken || !svg || dnaVersion === undefined}
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

      <p className="picker-hint mt-2 text-xs text-text-lo">
        {selected
          ? `pepe #${fmtPepeId(selected)} selected · pick another or ${actionLabel} below`
          : 'tap a pepe to select it'}
      </p>
    </div>
  )
}
