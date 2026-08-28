import { useEffect, useMemo, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useAccount, useWriteContract } from 'wagmi'
import { factoryAbi, registryAbi, stakerAbi } from '../lib/abi'
import { rpcCall } from '../lib/rpc'
import { ADDRESSES } from '../lib/config'
import { useRound } from '../lib/useRound'

const REF_KEY = 'psp-ref'
const ZERO_ADDR = /^0x0+$/

/// referral link for a staked pepe: lands visitors on the predeposit page
/// (round entry point) with the referrer's NFT id in the hash-query.
export function refLinkFor(pepeId: bigint): string {
  return `${window.location.origin}${window.location.pathname}#/predeposit?ref=${pepeId}`
}

function readSavedRef(): bigint | null {
  try {
    const raw = localStorage.getItem(REF_KEY)
    if (!raw) return null
    const id = BigInt(raw)
    return id > 0n ? id : null
  } catch {
    return null
  }
}

interface RefProfile {
  registry: `0x${string}` | undefined
  pepeIds: bigint[]
  attributed: boolean | undefined
  refNft: bigint | undefined // 0n = unattributed
}

const EMPTY_PROFILE: RefProfile = { registry: undefined, pepeIds: [], attributed: undefined, refNft: undefined }

/// shared poll: registry address for the round, the wallet's staked pepe ids,
/// and its attribution state. 4s cadence like every other read in the app.
function useReferral(): RefProfile {
  const round = useRound()
  const { address } = useAccount()
  const [profile, setProfile] = useState<RefProfile>(EMPTY_PROFILE)

  useEffect(() => {
    if (!round.id) return
    let dead = false
    async function tick() {
      try {
        const reg = (await rpcCall(ADDRESSES.factory, factoryAbi, 'referralRegistryOf', [round.id])) as `0x${string}`
        const liveReg = reg && !ZERO_ADDR.test(reg) ? reg : undefined
        let pepeIds: bigint[] = []
        let attributed: boolean | undefined
        let refNft: bigint | undefined
        if (address && round.staker) {
          const count = Number((await rpcCall(round.staker, stakerAbi, 'balanceOf', [address])) as bigint)
          const ids = await Promise.all(
            Array.from({ length: count }, (_, i) =>
              rpcCall(round.staker!, stakerAbi, 'tokenOfOwnerByIndex', [address, BigInt(i)]),
            ),
          )
          pepeIds = ids as bigint[]
        }
        if (address && liveReg) {
          attributed = (await rpcCall(liveReg, registryAbi, 'attributed', [address])) as boolean
          refNft = (await rpcCall(liveReg, registryAbi, 'traderRefNftOf', [address])) as bigint
        }
        if (dead) return
        setProfile({ registry: liveReg, pepeIds, attributed, refNft })
      } catch {
        /* round/registry not resolvable yet — keep last state */
      }
    }
    tick()
    const iv = setInterval(tick, 4000)
    return () => {
      dead = true
      clearInterval(iv)
    }
  }, [round.id, round.staker, address])

  return profile
}

/// canReferNft(nftId) poll — whether a pepe id is a valid referrer target.
function useCanRefer(registry: `0x${string}` | undefined, nftId: bigint | null): boolean | undefined {
  const [ok, setOk] = useState<boolean | undefined>(undefined)
  useEffect(() => {
    if (!registry || nftId === null) {
      setOk(undefined)
      return
    }
    let dead = false
    async function tick() {
      try {
        const r = (await rpcCall(registry!, registryAbi, 'canReferNft', [nftId])) as boolean
        if (!dead) setOk(r)
      } catch {
        /* keep last */
      }
    }
    tick()
    const iv = setInterval(tick, 4000)
    return () => {
      dead = true
      clearInterval(iv)
    }
  }, [registry, nftId])
  return ok
}

export default function ReferralCard() {
  const { isConnected } = useAccount()
  const { pepeIds, registry } = useReferral()
  const [selected, setSelected] = useState<bigint | null>(null)
  const [copied, setCopied] = useState(false)

  const ids = useMemo(() => [...pepeIds].sort((a, b) => (a < b ? -1 : 1)), [pepeIds])
  const active = selected !== null && ids.includes(selected) ? selected : (ids[0] ?? null)
  const canRefer = useCanRefer(registry, active)
  const link = active !== null ? refLinkFor(active) : ''

  useEffect(() => {
    if (!copied) return
    const t = setTimeout(() => setCopied(false), 2000)
    return () => clearTimeout(t)
  }, [copied])

  async function copyLink() {
    try {
      await navigator.clipboard.writeText(link)
      setCopied(true)
    } catch {
      window.prompt('copy your referral link', link)
      setCopied(true)
    }
  }

  return (
    <div className="card p-5">
      <h2 className="text-lg font-black text-slate-900">referrals</h2>
      {!isConnected ? (
        <p className="mt-2 text-sm text-slate-500">connect a wallet to generate referral links.</p>
      ) : ids.length === 0 ? (
        <div className="mt-3 rounded-xl bg-sky-50 p-3 text-sm font-bold text-slate-500">
          stake a pepe to unlock referral links
        </div>
      ) : (
        <>
          <select
            value={active !== null ? active.toString() : ''}
            onChange={(e) => setSelected(BigInt(e.target.value))}
            className="mt-3 w-full rounded-2xl border border-sky-100 bg-sky-50/60 px-4 py-3 font-bold text-slate-800 outline-none transition focus:border-psp-sky focus:bg-white"
          >
            {ids.map((id) => (
              <option key={id.toString()} value={id.toString()}>
                pepe #{id.toString()}
              </option>
            ))}
          </select>
          <div className="mt-3 break-all rounded-xl border border-sky-100 bg-sky-50/60 p-3 font-mono text-[11px] leading-relaxed text-slate-500">
            {link}
          </div>
          <button className="btn-primary mt-3 w-full" onClick={copyLink}>
            {copied ? 'copied ✓' : 'copy referral link'}
          </button>
          {canRefer === false && (
            <div className="mt-2 text-xs font-bold text-amber-600">
              pepe #{active?.toString()} isn't referral-eligible yet — visitors can't bind to it.
            </div>
          )}
        </>
      )}
      <p className="mt-3 text-xs leading-relaxed text-slate-400">
        share your link — when they connect and bind, their trades pay you referral fees from the round's swap fees.
      </p>
    </div>
  )
}

/// visitor side: captures ?ref= from the URL (Predeposit + Trade pages),
/// persists it, strips it, and offers the one-shot registry.record() bind.
export function RefBanner() {
  const { isConnected } = useAccount()
  const [searchParams, setSearchParams] = useSearchParams()
  const [dismissed, setDismissed] = useState(false)
  const [justBound, setJustBound] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const { writeContractAsync } = useWriteContract()

  // capture → persist → strip (keep any other params)
  const refParam = searchParams.get('ref')
  useEffect(() => {
    if (!refParam) return
    try {
      localStorage.setItem(REF_KEY, refParam)
    } catch {
      /* private mode — banner simply won't persist */
    }
    setSearchParams(
      (prev) => {
        const next = new URLSearchParams(prev)
        next.delete('ref')
        return next
      },
      { replace: true },
    )
  }, [refParam, setSearchParams])

  const ref = useMemo(() => readSavedRef(), [refParam])
  const { registry, attributed, refNft } = useReferral()
  const canRefer = useCanRefer(registry, ref)

  const boundToRef = ref !== null && refNft !== undefined && refNft === ref
  const canBind = isConnected && ref !== null && attributed === false && canRefer === true

  async function bind() {
    if (ref === null || !registry) return
    setError(null)
    try {
      await writeContractAsync({
        address: registry,
        abi: registryAbi,
        functionName: 'record',
        args: [ref],
      })
      setJustBound(true)
    } catch (e) {
      setError(e instanceof Error ? e.message.slice(0, 140) : 'transaction failed')
    }
  }

  if (ref === null || dismissed) return null

  // already attributed to this referrer (or just bound) — subtle line only
  if (boundToRef || justBound) {
    return (
      <div className="card px-4 py-3 text-xs font-bold text-emerald-600">
        ✅ referred by pepe #{ref.toString()} — attribution bound.
      </div>
    )
  }

  // attributed to something else — subtle line, no CTA
  if (isConnected && attributed === true) {
    return (
      <div className="card px-4 py-3 text-xs font-bold text-slate-400">
        referred by pepe #{ref.toString()}
      </div>
    )
  }

  // connected but nothing bindable (ineligible referrer / state unknown) — stay quiet
  if (isConnected && !canBind) return null

  return (
    <div className="card flex flex-wrap items-center gap-2 px-4 py-3">
      <span className="flex-1 text-xs font-bold text-slate-500">
        {isConnected
          ? `you were referred by pepe #${ref.toString()} — bind attribution?`
          : `you were referred by pepe #${ref.toString()} — connect a wallet to bind`}
      </span>
      {canBind && (
        <button type="button" onClick={bind} className="btn-ghost px-3 py-1.5 text-xs">
          bind attribution
        </button>
      )}
      <button
        type="button"
        title="dismiss"
        onClick={() => setDismissed(true)}
        className="rounded-full px-2 py-1 text-xs font-bold text-slate-300 transition hover:bg-sky-50 hover:text-slate-500"
      >
        ✕
      </button>
      {error && <div className="w-full break-words text-xs text-rose-500">{error}</div>}
    </div>
  )
}
