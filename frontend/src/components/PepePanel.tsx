import { useEffect, useState } from 'react'
import { useAccount } from 'wagmi'
import { stakerAbi, descriptorAbi } from '../lib/abi'
import { rpcCall } from '../lib/rpc'
import { renderPepeSvg, randomDna } from '../lib/pepeRender'
import type { RoundInfo } from '../lib/useRound'

interface Props {
  round: RoundInfo
  /** bump to force a refetch (e.g. right after a lock tx lands) */
  refreshKey?: number
}

const isZero = (a: string | undefined) => !a || /^0x0+$/.test(a)

/// Your pepe — the ERC-721 position NFT's generative art, rendered by the
/// ON-CHAIN descriptor (eth_call renderSVG(dnaOf(tokenId))). What you see is
/// the actual contract output, not a client-side approximation. The NFT is
/// yours forever: unlocking keeps it as proof you participated.
export default function PepePanel({ round, refreshKey = 0 }: Props) {
  const { address } = useAccount()
  const [tokenId, setTokenId] = useState<bigint | undefined>()
  const [dna, setDna] = useState<bigint | undefined>()
  const [svg, setSvg] = useState<string | null>(null)
  const [artOnline, setArtOnline] = useState(false)
  // teaser pepe for wallet-disconnected / chain-down states — rerolled per mount
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
        if (id === 0n) { setDna(undefined); setSvg(null); return }
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
    return () => { dead = true; clearInterval(iv) }
  }, [address, staker, refreshKey])

  if (!address) {
    return (
      <div className="card flex flex-col items-center justify-center p-5 text-center">
        <div
          className="h-40 w-40 overflow-hidden rounded-2xl border-2 border-dashed border-sky-200 [&>svg]:h-full [&>svg]:w-full"
          dangerouslySetInnerHTML={{ __html: teaser }}
        />
        <p className="mt-3 text-sm font-bold text-slate-500">connect to meet your pepe</p>
        <p className="mt-1 text-xs text-slate-400">here's a random one meanwhile — 100M combinations</p>
      </div>
    )
  }

  if (tokenId === undefined) {
    return (
      <div className="card p-5">
        <div className="flex h-48 items-center justify-center gap-4">
          <div
            className="h-40 w-40 overflow-hidden rounded-2xl opacity-80 [&>svg]:h-full [&>svg]:w-full"
            dangerouslySetInnerHTML={{ __html: teaser }}
          />
          <p className="max-w-[10rem] text-xs font-bold text-slate-400">
            looking for your pepe… if this hangs, the dev chain is down — art still renders locally
          </p>
        </div>
      </div>
    )
  }

  if (tokenId === 0n) {
    return (
      <div className="card flex flex-col items-center p-5 text-center">
        <div className="grid h-40 w-40 place-items-center rounded-2xl border-2 border-dashed border-sky-200 bg-sky-50/50 text-5xl grayscale">
          🥚
        </div>
        <p className="mt-3 text-sm font-black text-slate-700">an un-hatched pepe</p>
        <p className="mt-1 text-xs text-slate-400">
          one transaction hatches it — stake any amount, or zero to just collect the art
        </p>
      </div>
    )
  }

  return (
    <div className="card flex flex-col items-center p-5 text-center">
      <div
        className="h-44 w-44 [&>svg]:h-full [&>svg]:w-full"
        style={svg || dna !== undefined ? undefined : { filter: 'grayscale(1) opacity(0.35)' }}
      >
        {svg || dna !== undefined ? (
          <div
            dangerouslySetInnerHTML={{ __html: svg ?? renderPepeSvg(dna!) }}
            className="h-full w-full"
          />
        ) : (
          <div className="grid h-full w-full place-items-center text-5xl">🐸</div>
        )}
      </div>
      <p className="mt-3 text-sm font-black text-slate-700">
        pepe #{tokenId.toString()} <span className="text-slate-400">· PSPP</span>
      </p>
      <p className="mt-1 break-all text-[10px] text-slate-400">dna 0x{dna?.toString(16)}</p>
      <p className="mt-2 text-xs font-bold text-emerald-600">
        {artOnline
          ? 'rendered on-chain · yours forever'
          : 'local render — same art data the contract draws from'}
      </p>
    </div>
  )
}
