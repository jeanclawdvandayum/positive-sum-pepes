// Alt-UI action FX bus (PLAN Feature 3). Everything here is inert until the
// alt-only ActionFxLayer subscribes: fireFx is a no-op without subscribers and
// the press-capture listeners install lazily on the first subscribe, so the
// original UI never touches the DOM for this module.

import { UserRejectedRequestError } from 'viem'

export type FxKind =
  | 'buy' | 'sell' | 'predeposit' | 'launch' | 'stake' | 'topUp' | 'claimFees' | 'reinvest'
  | 'requestWithdraw' | 'cancelWithdraw' | 'unlock' | 'claimPot' | 'redeem' | 'claimPredeposit'
  | 'claimReferral' | 'nameCommit' | 'nameRegister' | 'refLink' | 'shareImage' | 'faucet'
  | 'transferPepe' | 'approve' | 'spawn' | 'detonate' | 'fail'

/** The minted position NFT a hatch reveals. Production reads its DNA from
 *  `staker.dnaOf(id)`; only the dev lab passes `dna` directly. */
export type FxPepe = { id: bigint; dnaVersion: bigint; staker?: `0x${string}`; dna?: bigint }

export type FxEvent = { id: number; kind: FxKind; anchor?: DOMRect; target?: DOMRect; detail?: string; pepe?: FxPepe }

export type FxOptions = { anchor?: Element | DOMRect; target?: Element | DOMRect | string; detail?: string; pepe?: FxPepe }

/** Every write functionName the UI issues, mapped to its per-action animation. */
const KIND_FOR_FUNCTION: Record<string, FxKind> = {
  buyWithMix: 'buy', buyWithMixGuarded: 'buy',
  sellToMix: 'sell',
  predeposit: 'predeposit', predepositWithPepe: 'predeposit',
  launchPooledBuy: 'launch',
  lock: 'stake', lockWithPepe: 'stake',
  stakeFor: 'topUp',
  claimAllTo: 'claimFees', claim: 'claimFees', claimFees: 'claimFees', claimMany: 'claimFees',
  reinvest: 'reinvest', reinvestAll: 'reinvest',
  requestWithdraw: 'requestWithdraw',
  cancelWithdraw: 'cancelWithdraw',
  withdraw: 'unlock', exit: 'unlock',
  claimPot: 'claimPot',
  redeemBacking: 'redeem',
  claimPredepositPSP: 'claimPredeposit', claimPredepositPSPWithPepe: 'claimPredeposit',
  claimReferralRewards: 'claimReferral',
  commit: 'nameCommit', register: 'nameRegister',
  drip: 'faucet',
  safeTransferFrom: 'transferPepe',
  approve: 'approve', setApprovalForAll: 'approve',
  reserveSpawn: 'spawn', birthStep: 'spawn', birthRound: 'spawn', spawnNextRound: 'spawn',
  detonate: 'detonate',
}

export function fxKindFor(functionName: string): FxKind | undefined {
  return KIND_FOR_FUNCTION[functionName]
}

type Listener = () => void
const listeners = new Set<Listener>()
let events: FxEvent[] = []
let nextId = 1
let installed = false
let lastPress: { el: Element; at: number } | undefined
/** Live source elements per active event, for effects that must touch the real node. */
const anchorElements = new Map<number, Element>()

function rectOf(value: Element | DOMRect | string | undefined): DOMRect | undefined {
  if (!value) return undefined
  if (typeof value === 'string') {
    const el = document.querySelector(value)
    return el?.isConnected ? el.getBoundingClientRect() : undefined
  }
  if (value instanceof Element) return value.isConnected ? value.getBoundingClientRect() : undefined
  return value
}

function press(target: EventTarget | null): void {
  if (!(target instanceof Element)) return
  const el = target.closest('button, [role="button"], a')
  if (el) lastPress = { el, at: Date.now() }
}

function onPointerDown(event: PointerEvent): void { press(event.target) }
function onKeyDown(event: KeyboardEvent): void {
  if (event.key === 'Enter' || event.key === ' ') press(event.target)
}

function install(): void {
  if (installed) return
  installed = true
  document.addEventListener('pointerdown', onPointerDown, { capture: true })
  document.addEventListener('keydown', onKeyDown, { capture: true })
}

/** Last subscriber left → remove the document listeners and all captured
 *  state (layer unmount, HMR): the original UI and reloads inherit nothing. */
function teardown(): void {
  document.removeEventListener('pointerdown', onPointerDown, { capture: true })
  document.removeEventListener('keydown', onKeyDown, { capture: true })
  installed = false
  lastPress = undefined
  events = []
  anchorElements.clear()
}

/** The nearest pressed button-ish element, if it was pressed within the last 2s. */
export function captureAnchor(): Element | undefined {
  if (!lastPress || Date.now() - lastPress.at > 2000 || !lastPress.el.isConnected) return undefined
  return lastPress.el
}

export function fireFx(kind: FxKind, opts: FxOptions = {}): void {
  if (!listeners.size) return
  const id = nextId++
  if (opts.anchor instanceof Element) anchorElements.set(id, opts.anchor)
  const event: FxEvent = { id, kind, anchor: rectOf(opts.anchor), target: rectOf(opts.target), detail: opts.detail, pepe: opts.pepe }
  events = [...events, event]
  listeners.forEach(notify => notify())
}

/** The live element an event's anchor was captured from — the fail shake rides
 *  the real node no matter how long the transaction took. */
export function fxAnchorElement(id: number): Element | undefined {
  const el = anchorElements.get(id)
  return el?.isConnected ? el : undefined
}

export const actionFx = {
  subscribe(listener: Listener): () => void {
    install()
    listeners.add(listener)
    return () => {
      listeners.delete(listener)
      if (!listeners.size) teardown()
    }
  },
  snapshot(): FxEvent[] { return events },
  done(id: number): void {
    if (!events.some(event => event.id === id)) return
    events = events.filter(event => event.id !== id)
    anchorElements.delete(id)
    listeners.forEach(notify => notify())
  },
}

/** A wallet dismissal is the user changing their mind, not a failure to mourn. */
export function isUserRejection(error: unknown): boolean {
  if (error instanceof UserRejectedRequestError) return true
  if ((error as { code?: unknown } | null)?.code === 4001) return true
  const message = error instanceof Error ? error.message : String(error)
  return /user rejected/i.test(message)
}
