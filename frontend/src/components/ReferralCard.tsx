import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useAccount } from 'wagmi'
import { factoryAbi, registryAbi, stakerAbi } from '../lib/abi'
import { rpcCall, rpcBatchCall } from '../lib/rpc'
import { ADDRESSES, CHAIN_ID } from '../lib/config'
import { matchingReferral, parseReferral, referralKey, referralParams, savedReferral, type ReferralHint } from '../lib/referrals'
import { useRound } from '../lib/useRound'
import ReferralShare from './ReferralShare'

const ZERO_ADDR = /^0x0+$/
const registryVersions = new Map<string, bigint>()

/// A link identifies the NFT, chain and immutable round registry together.
export function refLinkFor(pepeId: bigint, registry: string): string {
  return `${window.location.origin}${window.location.pathname}#/?${referralParams(pepeId, CHAIN_ID, registry)}`
}

interface RefProfile {
  registry: `0x${string}` | undefined
  pepeIds: bigint[]
  version?: bigint
  attributed: boolean | undefined
  refNft: bigint | undefined // 0n = unattributed
}

const EMPTY_PROFILE: RefProfile = { registry: undefined, pepeIds: [], attributed: undefined, refNft: undefined }

const ReferralContext = createContext<{ profile: RefProfile; hint: bigint; invalidLink: boolean }>({ profile: EMPTY_PROFILE, hint: 0n, invalidLink: false })

/// Capture once at the router root, so any landing route and private browsing
/// retain a hint across navigation. Cache keys prevent round/chain ID reuse.
export function ReferralProvider({ children }: { children: ReactNode }) {
  const round = useRound()
  const { address } = useAccount()
  const [params, setParams] = useSearchParams()
  const [hints, setHints] = useState<Record<string, ReferralHint>>({})
  const [invalidLink, setInvalidLink] = useState(false)
  const [captured, setCaptured] = useState<ReferralHint | null>(null)
  const scope = `${CHAIN_ID}:${ADDRESSES.factory}:${round.id}:${round.staker}:${address}`
  const [state, setState] = useState<{ scope: string; profile: RefProfile }>()
  const profile = state?.scope === scope ? state.profile : EMPTY_PROFILE
  const query = params.toString()

  useEffect(() => {
    if (!params.has('ref')) return
    const hint = parseReferral(params)
    setCaptured(hint)
    setInvalidLink(!hint || hint.chainId !== CHAIN_ID)
    if (hint && hint.chainId === CHAIN_ID) {
      const key = referralKey(hint.chainId, hint.registry)
      setHints(prev => ({ ...prev, [key]: hint }))
      try { localStorage.setItem(key, JSON.stringify(hint)) } catch { /* memory survives navigation */ }
    }
    setParams(prev => {
      const next = new URLSearchParams(prev)
      for (const key of ['ref', 'refRegistry', 'refChain']) next.delete(key)
      return next
    }, { replace: true })
  // The stable serialized query avoids capture loops as routes rerender.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [query, setParams])

  useEffect(() => {
    if (!round.id) return
    let dead = false
    let running = false
    async function tick() {
      if (running) return
      running = true
      try {
        const reg = await rpcCall(ADDRESSES.factory, factoryAbi, 'referralRegistryOf', [round.id]) as `0x${string}`
        if (ZERO_ADDR.test(reg)) throw new Error('Registry unavailable')
        const versionKey = referralKey(CHAIN_ID, reg)
        let version = registryVersions.get(versionKey)
        try {
          if (version === undefined) version = await rpcCall(reg, registryAbi, 'PURCHASE_REFERRAL_VERSION') as bigint
        }
        catch (error) {
          // Legacy selector absence is distinct from an RPC transport failure.
          if (error instanceof Error && /no result|execution reverted/i.test(error.message)) version = 0n
          else throw error
        }
        if (version !== undefined) registryVersions.set(versionKey, version)
        let pepeIds: bigint[] = []
        let attributed: boolean | undefined
        let refNft: bigint | undefined
        if (address) {
          const values = await rpcBatchCall(reg, registryAbi, [
            { functionName: 'attributed', args: [address] },
            { functionName: 'traderRefNftOf', args: [address] },
          ])
          attributed = values[0] as boolean
          refNft = values[1] as bigint
        }
        if (address && round.staker) {
          const count = Number(await rpcCall(round.staker, stakerAbi, 'balanceOf', [address]))
          // Bounded RPC concurrency even for wallets with many NFTs.
          for (let i = 0; i < count; i += 8) {
            const ids = await Promise.all(Array.from({ length: Math.min(8, count - i) }, (_, j) =>
              rpcCall(round.staker!, stakerAbi, 'tokenOfOwnerByIndex', [address, BigInt(i + j)])))
            pepeIds.push(...ids as bigint[])
          }
        }
        if (!dead) setState({ scope, profile: { registry: reg, version, pepeIds, attributed, refNft } })
      } catch {
        if (!dead) setState({ scope, profile: EMPTY_PROFILE })
      } finally { running = false }
    }
    tick()
    const iv = setInterval(tick, 4000)
    return () => { dead = true; clearInterval(iv) }
  }, [scope, round.id, round.staker, address])

  const key = profile.registry ? referralKey(CHAIN_ID, profile.registry) : ''
  useEffect(() => {
    if (!key) return
    try {
      const hint = savedReferral(localStorage.getItem(key))
      if (hint) setHints(prev => prev[key] ? prev : { ...prev, [key]: hint })
    } catch { /* memory-only private mode */ }
  }, [key])
  const incoming = parseReferral(params)
  const hint = matchingReferral(incoming ?? hints[key] ?? null, CHAIN_ID, profile.registry)
  return <ReferralContext.Provider value={{ profile, hint, invalidLink: invalidLink || !!(captured && profile.registry && !matchingReferral(captured, CHAIN_ID, profile.registry)) }}>{children}</ReferralContext.Provider>
}

export function useReferral(): RefProfile { return useContext(ReferralContext).profile }
export function usePurchaseReferral(): bigint { return useContext(ReferralContext).hint }

/// canReferNft(nftId) poll — whether a pepe id is a valid referrer target.
export function useCanRefer(registry: `0x${string}` | undefined, nftId: bigint | null): boolean | undefined {
  const key = `${registry}:${nftId}`
  const [state, setState] = useState<{ key: string; ok: boolean }>()
  useEffect(() => {
    if (!registry || nftId === null) {
      return
    }
    let dead = false
    async function tick() {
      try {
        const r = (await rpcCall(registry!, registryAbi, 'canReferNft', [nftId])) as boolean
        if (!dead) setState({ key, ok: r })
      } catch {
        if (!dead) setState(undefined)
      }
    }
    tick()
    const iv = setInterval(tick, 4000)
    return () => {
      dead = true
      clearInterval(iv)
    }
  }, [registry, nftId, key])
  return state?.key === key ? state.ok : undefined
}

export default function ReferralCard() {
  const { isConnected } = useAccount()
  const { pepeIds, registry, version } = useReferral()
  const [selected, setSelected] = useState<bigint | null>(null)
  const [copied, setCopied] = useState(false)

  const ids = useMemo(() => [...pepeIds].sort((a, b) => (a < b ? -1 : 1)), [pepeIds])
  const active = selected !== null && ids.includes(selected) ? selected : (ids[0] ?? null)
  const canRefer = useCanRefer(registry, active)
  const link = active !== null && registry && version === 1n ? refLinkFor(active, registry) : ''

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
      {version === 0n && <p className="mt-3 text-xs text-text-lo">referral links open with the next testnet deployment.</p>}
      {!isConnected ? (
        <p className="mt-2 text-sm text-slate-500">invite the usual suspects. connect your wallet to get your pepe’s referral link.</p>
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
          <button className="btn-primary mt-3 w-full" disabled={!link || canRefer !== true} onClick={copyLink}>
            {copied ? 'copied ✓' : 'copy referral link'}
          </button>
          <ReferralShare tokenId={active} link={link} enabled={canRefer === true} />
          {canRefer === false && (
            <div className="mt-2 text-xs font-bold text-amber-600">
              pepe #{active?.toString()} needs referral eligibility before purchases can record its referral.
            </div>
          )}
        </>
      )}
      <p className="mt-3 text-xs leading-relaxed text-slate-400">
        share your link with the group chat. their first eligible PSP purchase through your link locks in the referral for this round. its trades then pay your referral chain from the trading fee.
      </p>
    </div>
  )
}

/// Informational only. The purchase transaction records an eligible referral.
export function RefBanner() {
  const { profile, hint, invalidLink } = useContext(ReferralContext)
  const { attributed, refNft, version } = profile
  if (attributed && refNft) return <div className="rounded-xl border border-line bg-bg-1 px-4 py-3 text-xs text-text-lo">
    referred by pepe #{refNft.toString()} · locked for this round.
  </div>
  if (invalidLink) return <p role="status" className="text-xs text-text-lo">this referral link needs a current round and network. fresh links are available on the stake page.</p>
  if (!hint) return null
  return <div role="status" className="rounded-xl border border-line bg-bg-1 px-4 py-3 text-xs text-text-lo">
    {version === 1n
      ? `pepe #${hint} is included in your next PSP purchase. an eligible referral locks for this round; your trading fee stays the same.`
      : 'this testnet round needs updated referral contracts to include a referral in a purchase.'}
  </div>
}
