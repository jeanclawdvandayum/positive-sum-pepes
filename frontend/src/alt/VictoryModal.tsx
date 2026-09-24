// The pot victory modal (PLAN Round 5), fed by the victories store. Mounted
// ONLY in AltShell — the store is inert and the original UI untouched without
// this subscriber. Two paths open it:
//  · claim  — useConfirmedWrite pushes the receipt-decoded claimPot payout;
//  · settle — SettleWatch sees the round lane leave Active and the connected
//             wallet's claimablePot on that settled hook is > 0.
// A dimmed backdrop (z 9500: over the FX layer, under the toasts), a gold-
// trimmed square card with a hard shadow, a happy pepe confetti burst on open,
// the message, the amount, the round and the winner's pepes as PNG cards —
// fanned out when there are several. × / Esc / click-outside dismiss it.

import { useCallback, useEffect, useLayoutEffect, useMemo, useReducer, useRef, useState, useSyncExternalStore, type CSSProperties } from 'react'
import { createPortal } from 'react-dom'
import { Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useAccount } from 'wagmi'
import { actionFx } from '../lib/actionFx'
import { hookAbi, stakerAbi } from '../lib/abi'
import { CHAIN_ID, targetChain } from '../lib/config'
import { fmtAmount } from '../lib/format'
import { renderPepeSvg } from '../lib/pepeRender'
import { referralPepePng } from '../lib/referralShare'
import { readRoundWinners } from '../lib/roundWinners'
import { rpcBatchCall, rpcCall } from '../lib/rpc'
import { useRound } from '../lib/useRound'
import { useWalletPepe } from '../lib/useWalletPepe'
import { fanAngle, fanHand, fanPng, FAN_PIVOT } from '../lib/victoryArt'
import {
  bragUrl, loadLastActive, pickVictoryMessage, saveLastActive, settledRound, victories,
  type RoundSighting, type Victory,
} from '../lib/victoryCards'
import { PepeConfetti } from './fx/confetti'
import { reducedMotion } from './fx/parts'

/** A settle-detected win waits this long, so a detonation set-piece that the
 *  same receipt fires gets the stage first (the modal also holds while one runs). */
const SETTLE_GRACE_MS = 4000
/** claimablePot recheck while a settled round is in view — one eth_call. */
const CLAIMABLE_POLL_MS = 15_000
const ZERO: `0x${string}` = '0x0000000000000000000000000000000000000000'

/** Watches the round lane for settlement and offers the wallet's win. */
function SettleWatch() {
  const round = useRound()
  const { address } = useAccount()
  const [lastActive, setLastActive] = useState(loadLastActive)
  const { id, hook, staker, mode } = round
  useEffect(() => {
    if (mode !== 1 || !hook || lastActive?.hook.toLowerCase() === hook.toLowerCase()) return
    const sighting = { id, hook, staker, mode }
    saveLastActive(sighting)
    setLastActive(sighting)
  }, [id, hook, staker, mode, lastActive])
  const current: RoundSighting | undefined = hook && mode !== undefined ? { id, hook, staker, mode } : undefined
  const settled = settledRound(lastActive, current)
  const claimable = useQuery({
    queryKey: ['victory-claimable', CHAIN_ID, settled?.hook, address],
    enabled: !!settled && !!address,
    queryFn: async () => {
      const [hookMode, amount] = await Promise.all([
        rpcCall(settled!.hook, hookAbi, 'mode') as Promise<bigint>,
        rpcCall(settled!.hook, hookAbi, 'claimablePot', [address]) as Promise<bigint>,
      ])
      return Number(hookMode) >= 2 ? amount : 0n
    },
    staleTime: CLAIMABLE_POLL_MS - 5000, refetchInterval: CLAIMABLE_POLL_MS, retry: false,
  })
  const amount = claimable.data
  const settledHook = settled?.hook
  const settledId = settled?.id
  const settledStaker = settled?.staker
  useEffect(() => {
    if (!settledHook || settledId === undefined || !address || amount === undefined) return
    victories.offerSettled({
      source: 'settle', roundId: settledId, amountMix: amount, message: pickVictoryMessage(),
      account: address, hook: settledHook, staker: settledStaker, delayMs: SETTLE_GRACE_MS,
    })
  }, [amount, settledHook, settledId, settledStaker, address])
  return null
}

type Hand = { svgs: string[]; more: number; identity: boolean }

/** The winner's position NFTs in the round's staker (first six, local art from
 *  on-chain DNA), else the wallet's assigned pepe; the lab passes mocks. */
function useHand(victory: Victory): Hand | undefined {
  const owner = victory.account ?? ZERO
  const nfts = useQuery({
    queryKey: ['victory-pepes', CHAIN_ID, victory.staker, owner],
    enabled: !victory.mockPepes && !!victory.staker && !!victory.account,
    staleTime: Infinity, retry: 1,
    queryFn: async () => {
      const staker = victory.staker!
      const [total, version] = await Promise.all([
        rpcCall(staker, stakerAbi, 'balanceOf', [owner]) as Promise<bigint>,
        (rpcCall(staker, stakerAbi, 'PEPE_DNA_VERSION') as Promise<bigint>).catch(() => 1n),
      ])
      const { shown, more } = fanHand(Number(total))
      const ids = await Promise.all(Array.from({ length: shown }, (_, i) =>
        rpcCall(staker, stakerAbi, 'tokenOfOwnerByIndex', [owner, BigInt(i)]) as Promise<bigint>))
      const dnas = await Promise.all(ids.map(tokenId => rpcCall(staker, stakerAbi, 'dnaOf', [tokenId]) as Promise<bigint>))
      return { svgs: dnas.map(dna => renderPepeSvg(dna, version)), more }
    },
  })
  const identity = useWalletPepe(owner, victory.staker)
  if (victory.mockPepes) {
    const { shown, more } = fanHand(victory.mockPepes.length)
    return { svgs: victory.mockPepes.slice(0, shown), more, identity: false }
  }
  if (nfts.data?.svgs.length) return { ...nfts.data, identity: false }
  if (nfts.fetchStatus === 'fetching' && !nfts.data) return undefined
  return { svgs: [identity], more: 0, identity: true }
}

type Art = { key: string; cards: string[]; share: Blob; shareUrl: string }

/** Every card is a PNG raster of its pepe; the share image is the single
 *  pepe's PNG or the whole fan composited with the same geometry. */
function useArt(hand: Hand | undefined): Art | undefined {
  const key = hand ? `${hand.more}|${hand.svgs.join('|')}` : ''
  const [art, setArt] = useState<Art>()
  useEffect(() => {
    if (!hand) return
    let live = true
    const urls: string[] = []
    void (async () => {
      const blobs = await Promise.all(hand.svgs.map(referralPepePng))
      const share = blobs.length === 1 ? blobs[0] : await fanPng(hand.svgs, hand.more)
      if (!live) return
      const cards = blobs.map(blob => URL.createObjectURL(blob))
      const shareUrl = blobs.length === 1 ? cards[0] : URL.createObjectURL(share)
      urls.push(...cards, ...(blobs.length === 1 ? [] : [shareUrl]))
      setArt({ key, cards, share, shareUrl })
    })().catch(() => {})
    return () => {
      live = false
      urls.forEach(url => URL.revokeObjectURL(url))
    }
    // hand identity changes per render; the serialized key is the dep
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key])
  return art?.key === key ? art : undefined
}

function VictoryDialog({ victory }: { victory: Victory }) {
  const quiet = useMemo(reducedMotion, [])
  const cardRef = useRef<HTMLDivElement>(null)
  const closeRef = useRef<HTMLButtonElement>(null)
  const close = useCallback(() => victories.dismiss(victory.id), [victory.id])
  const [burst, setBurst] = useState<{ x: number; y: number; w: number }>()
  const [hint, setHint] = useState<{ copied: boolean } | undefined>()
  const [busy, setBusy] = useState(false)

  // Focus the close control on open; Esc dismisses; focus returns on close.
  useEffect(() => {
    const previous = document.activeElement instanceof HTMLElement ? document.activeElement : undefined
    closeRef.current?.focus({ preventScroll: true })
    const onKey = (event: KeyboardEvent) => { if (event.key === 'Escape') close() }
    window.addEventListener('keydown', onKey)
    return () => {
      window.removeEventListener('keydown', onKey)
      if (previous?.isConnected) previous.focus({ preventScroll: true })
    }
  }, [close])
  // The burst launches from the card's top edge, measured once on open.
  useLayoutEffect(() => {
    const rect = cardRef.current?.getBoundingClientRect()
    if (rect) setBurst({ x: rect.left + rect.width / 2, y: rect.top + 10, w: rect.width })
  }, [])

  const winners = useQuery({
    queryKey: ['victory-seats', CHAIN_ID, victory.hook],
    enabled: victory.seats === undefined && !!victory.hook && !!victory.account,
    queryFn: () => readRoundWinners(rpcBatchCall, victory.hook!),
    staleTime: Infinity, retry: 1,
  })
  const seats = victory.seats ?? winners.data?.winners
    .find(winner => winner.address.toLowerCase() === victory.account?.toLowerCase())?.ranks.length
  const hand = useHand(victory)
  const art = useArt(hand)
  const count = hand?.svgs.length ?? 0
  const explorer = targetChain.blockExplorers?.default
  const round = `round ${victory.roundId.toString()}${victory.roundName && victory.roundName !== `round ${victory.roundId}` ? ` · ${victory.roundName}` : ''}`

  async function brag() {
    if (busy) return
    setBusy(true)
    let copied = false
    try {
      // Write while this page has focus: the PNG is ready before the click,
      // so the clipboard write stays inside the user gesture.
      if (art && typeof ClipboardItem !== 'undefined' && navigator.clipboard?.write) {
        await navigator.clipboard.write([new ClipboardItem({ 'image/png': art.share })])
        copied = true
      }
    } catch {
      copied = false
    }
    setHint({ copied })
    setBusy(false)
    window.open(bragUrl({ ...victory, seats }), '_blank', 'noopener,noreferrer')
  }

  return createPortal(
    <div className="vm-backdrop" onClick={event => { if (event.target === event.currentTarget) close() }}>
      {/* the burst rises from the card's top edge and falls behind it */}
      {!quiet && burst && [-0.3, 0.3].map((side, i) => (
        <PepeConfetti key={i} mood="happy" at={{ x: burst.x + side * burst.w, y: burst.y }} faces={10} bits={6} delay={60 + i * 160} stagger={180} />
      ))}
      <div ref={cardRef} className="vm-card" role="dialog" aria-modal="true" aria-labelledby={`vm-head-${victory.id}`}
        data-source={victory.source}>
        <button ref={closeRef} type="button" className="vm-close" aria-label="close" onClick={close}>×</button>
        <p className="vm-kicker">{round}</p>
        <h2 id={`vm-head-${victory.id}`} className="vm-head">{victory.source === 'claim' ? 'POT CLAIMED' : 'YOU WON THE POT'}</h2>
        <p className="vm-amount">{fmtAmount(victory.amountMix)} <span className="vm-unit">mixETH</span></p>
        <p className="vm-seats">
          {seats !== undefined && seats > 0 ? `from ${seats} seat${seats === 1 ? '' : 's'} on the final ladder` : 'from the final ladder'}
          {victory.source === 'settle' ? ' · unclaimed' : ''}
        </p>
        <p className="vm-message">{victory.message}</p>
        <div className="vm-hand" data-count={count} aria-hidden={!art}
          style={{ '--pivot': FAN_PIVOT } as CSSProperties}>
          {Array.from({ length: count }, (_, i) => (
            <span key={i} className="vm-pepe" style={{ '--a': `${fanAngle(i, count)}deg`, '--i': i } as CSSProperties}>
              {art && <img src={art.cards[i]} alt={hand?.identity ? 'your wallet pepe' : `your pepe ${i + 1}`} draggable={false} />}
            </span>
          ))}
          {!!hand?.more && <span className="vm-more">+{hand.more} more</span>}
        </div>
        <p className="vm-hand-label">{hand?.identity ? 'your wallet pepe' : count > 1 ? 'your pepes' : count ? 'your pepe' : 'finding your pepes…'}</p>
        <div className="vm-actions">
          <button type="button" className="vm-brag" disabled={!art || busy} onClick={brag}>brag on X ↗</button>
          {victory.source === 'settle' && <Link className="vm-link" to="/graveyard" onClick={close}>claim in the graveyard ↗</Link>}
          {victory.txHash && explorer && (
            <a className="vm-link" href={`${explorer.url}/tx/${victory.txHash}`} target="_blank" rel="noopener noreferrer">view tx ↗</a>
          )}
        </div>
        <p className="vm-hint" role="status">
          {hint?.copied && 'image copied — paste it in your post'}
          {hint && !hint.copied && art && <>image not copied — <a href={art.shareUrl} download={`psp-pot-round-${victory.roundId}.png`}>save the png</a> and attach it</>}
        </p>
      </div>
    </div>,
    document.body,
  )
}

export default function VictoryModal() {
  const queue = useSyncExternalStore(victories.subscribe, victories.snapshot)
  const fx = useSyncExternalStore(actionFx.subscribe, actionFx.snapshot)
  const detonating = fx.some(event => event.kind === 'detonate')
  const head = queue[0]
  const [now, tick] = useReducer(() => Date.now(), 0, () => Date.now())
  const wait = head ? head.showAt - now : 0
  useEffect(() => {
    if (wait <= 0) return
    const timer = setTimeout(tick, wait)
    return () => clearTimeout(timer)
  }, [wait])
  // A queued entry arriving later than the last tick re-reads the clock.
  useEffect(tick, [head?.id])
  return <>
    <SettleWatch />
    {head && wait <= 0 && !detonating && <VictoryDialog key={head.id} victory={head} />}
  </>
}
