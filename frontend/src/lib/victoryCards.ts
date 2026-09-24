// The pot victory modal's store (Round 5). Two paths feed it:
//  · claim  — a confirmed claimPot pushes the RECEIPT-decoded payout
//             (useConfirmedWrite + potClaimDetail; never an estimate);
//  · settle — the alt shell sees the round leave Active and the wallet's
//             claimablePot on that hook is > 0 (VictoryModal's watcher).
// Same external-store shape as transactionToasts — module-level,
// snapshot/subscribe — and inert until something subscribes, so the original
// UI never touches it. The modal shows the oldest queued victory first.

import { fmtAmount } from './format.ts'

type Address = `0x${string}`

export type VictorySource = 'claim' | 'settle'

export type Victory = {
  id: number
  source: VictorySource
  roundId: bigint
  roundName?: string
  /** claim: the receipt's PotClaimed payout; settle: claimablePot(account),
   *  already the combined total across every seat the wallet held. */
  amountMix: bigint
  message: string
  /** the wallet's seats on the final ladder (groupRoundWinners), when known */
  seats?: number
  account?: Address
  /** the settled hook that pays the pot (seat count, dismissal memory) */
  hook?: Address
  /** the round's staker (the winner's position NFTs) */
  staker?: Address
  txHash?: `0x${string}`
  /** dev lab only: ready-made pepe art instead of chain reads */
  mockPepes?: string[]
  /** don't open before this (ms epoch): the claim burst / detonation play first */
  showAt: number
  at: number
}

export type VictoryEntry = Omit<Victory, 'id' | 'at' | 'showAt'> & { delayMs?: number }

/** One pick per victory, shared by the modal and the brag post. Lowercase
 *  deadpan, except the one entry the community supplied verbatim. */
export const VICTORY_MESSAGES: readonly string[] = [
  'you took the pot. the ladder bows.',
  'newest seat, biggest cut. enjoy.',
  'someone pull the pin? you got paid.',
  'the pot had your name on it. quietly.',
  'you waited out the clock. the clock blinked.',
  'clean exit. the ladder will miss you. it will get over it.',
  'paid in full. try to look surprised at the party.',
  'the pot is empty now. you are the reason.',
  'one ticket, one heartbeat, one payout.',
  'detonated, collected, unbothered.',
  'the smoke cleared and there you were, holding the bag of money instead.',
  "OMG!😭Can't believe I won ! Thank you Positive Sum Pepes team ! ❤️ keep doing the great work. 💪🏻💪🏻💪🏻🚀🚀🚀",
]

export function pickVictoryMessage(random: () => number = Math.random): string {
  return VICTORY_MESSAGES[Math.min(VICTORY_MESSAGES.length - 1, Math.floor(random() * VICTORY_MESSAGES.length))]
}

// ── settle detection ────────────────────────────────────────────────────────

/** One observation of the round lane (useRound). */
export type RoundSighting = { id: bigint; hook: Address; staker?: Address; mode: number }

/** The settled round whose claimablePot the wallet should check, if any:
 *  the current round once it is flat/destroyed, or — because detonate births
 *  the next round in the same tx — the last round seen Active once the lane
 *  has moved on to a newer round. A round still Active is never settled. */
export function settledRound(lastActive: RoundSighting | undefined, current: RoundSighting | undefined): RoundSighting | undefined {
  if (current && current.mode >= 2) return current
  if (!lastActive || !current) return undefined
  if (current.hook.toLowerCase() === lastActive.hook.toLowerCase()) return undefined
  return current.id > lastActive.id ? lastActive : undefined
}

const WATCH_STORAGE = 'psp-alt:victory-watch'

/** The last round the alt shell saw Active survives reloads, so a detonation
 *  that landed while the tab was closed still finds its settled hook. */
export function loadLastActive(): RoundSighting | undefined {
  try {
    const raw = typeof localStorage === 'undefined' ? null : localStorage.getItem(WATCH_STORAGE)
    const saved = raw ? JSON.parse(raw) as { id?: unknown; hook?: unknown; staker?: unknown } : undefined
    if (!saved || typeof saved.id !== 'string' || typeof saved.hook !== 'string' || !/^0x[0-9a-fA-F]{40}$/.test(saved.hook)) return undefined
    const staker = typeof saved.staker === 'string' && /^0x[0-9a-fA-F]{40}$/.test(saved.staker) ? saved.staker as Address : undefined
    return { id: BigInt(saved.id), hook: saved.hook as Address, staker, mode: 1 }
  } catch {
    return undefined
  }
}

export function saveLastActive(sighting: RoundSighting): void {
  try {
    if (typeof localStorage === 'undefined') return
    localStorage.setItem(WATCH_STORAGE, JSON.stringify({ id: sighting.id.toString(), hook: sighting.hook, staker: sighting.staker }))
  } catch {
    // Private mode / quota: settle detection falls back to this session.
  }
}

/** A settle-detected win opens only for something claimable that the wallet
 *  hasn't already dismissed at this amount or more. */
export function isNewWin(amount: bigint | undefined, dismissed: bigint | undefined): boolean {
  return amount !== undefined && amount > 0n && (dismissed === undefined || amount > dismissed)
}

const settleKey = (hook: Address, account: Address) => `${hook.toLowerCase()}:${account.toLowerCase()}`
const SEEN_STORAGE = 'psp-alt:victory-dismissed'

function readSeen(): Record<string, string> {
  try {
    const raw = typeof localStorage === 'undefined' ? null : localStorage.getItem(SEEN_STORAGE)
    const parsed = raw ? JSON.parse(raw) as unknown : undefined
    return parsed && typeof parsed === 'object' ? parsed as Record<string, string> : {}
  } catch {
    return {}
  }
}

/** The amount a wallet last dismissed for this hook (localStorage, alt only). */
export function dismissedAmount(hook: Address, account: Address): bigint | undefined {
  const value = readSeen()[settleKey(hook, account)]
  try { return value === undefined ? undefined : BigInt(value) } catch { return undefined }
}

function rememberDismissal(hook: Address, account: Address, amount: bigint): void {
  try {
    if (typeof localStorage === 'undefined') return
    localStorage.setItem(SEEN_STORAGE, JSON.stringify({ ...readSeen(), [settleKey(hook, account)]: amount.toString() }))
  } catch {
    // Private mode / quota: the modal may re-open next visit. Harmless.
  }
}

// ── the store ───────────────────────────────────────────────────────────────

let queue: Victory[] = []
let nextId = 0
const listeners = new Set<() => void>()

function emit(): void {
  listeners.forEach(listener => listener())
}

function build({ delayMs = 0, ...entry }: VictoryEntry): Victory {
  const at = Date.now()
  return { ...entry, id: ++nextId, at, showAt: at + delayMs }
}

export const victories = {
  subscribe(listener: () => void) {
    listeners.add(listener)
    return () => { listeners.delete(listener) }
  },
  /** Oldest first: the modal shows queue[0]. */
  snapshot: () => queue,
  /** True while something renders the modal (AltShell). Like fireFx, the
   *  store stays inert without a subscriber. */
  get active() {
    return listeners.size > 0
  },
  /** Returns the victory either way (the dev lab and bragText only need the
   *  object), but nothing is queued without a subscriber. */
  push(entry: VictoryEntry): Victory {
    const victory = build(entry)
    if (!listeners.size) return victory
    queue = [...queue, victory]
    emit()
    return victory
  },
  /** The settle path: at most one queued entry per (hook, wallet); a grown
   *  amount updates it in place; a dismissed amount never re-opens. */
  offerSettled(entry: VictoryEntry & { hook: Address; account: Address }): Victory | undefined {
    if (!listeners.size || !isNewWin(entry.amountMix, dismissedAmount(entry.hook, entry.account))) return undefined
    const key = settleKey(entry.hook, entry.account)
    const queued = queue.find(v => v.source === 'settle' && v.hook && v.account && settleKey(v.hook, v.account) === key)
    if (queued) {
      if (entry.amountMix <= queued.amountMix) return queued
      const grown = { ...queued, amountMix: entry.amountMix }
      queue = queue.map(v => v.id === queued.id ? grown : v)
      emit()
      return grown
    }
    return victories.push(entry)
  },
  /** Closing a settle-detected win remembers its amount for that wallet+hook. */
  dismiss(id: number) {
    const victory = queue.find(v => v.id === id)
    if (!victory) return
    if (victory.source === 'settle' && victory.hook && victory.account) rememberDismissal(victory.hook, victory.account, victory.amountMix)
    queue = queue.filter(v => v.id !== id)
    emit()
  },
  /** A confirmed claim settles the same wallet's pending settle entry. */
  resolveSettled(hook: Address, account: Address) {
    const key = settleKey(hook, account)
    const next = queue.filter(v => !(v.source === 'settle' && v.hook && v.account && settleKey(v.hook, v.account) === key))
    if (next.length === queue.length) return
    queue = next
    emit()
  },
  /** The dev lab's reset control. */
  clear() {
    if (!queue.length) return
    queue = []
    emit()
  },
}

// ── brag on X ───────────────────────────────────────────────────────────────

/** 'i just claimed 12.34 mixETH from the round 3 pot with 2 ladder seats on positive sum pepes 🚀' */
function victoryInfo(victory: Victory): string {
  const verb = victory.source === 'claim' ? 'claimed' : 'won'
  const seats = victory.seats === undefined || victory.seats < 1 ? ''
    : ` with ${victory.seats} ladder seat${victory.seats === 1 ? '' : 's'}`
  return `i just ${verb} ${fmtAmount(victory.amountMix)} mixETH from the round ${victory.roundId.toString()} pot${seats} on positive sum pepes 🚀`
}

/** The X post: message first; when the pair overflows X's 280-char post the
 *  victory-info sentence yields before the message does. */
export function bragText(victory: Victory): string {
  const combined = `${victory.message}\n\n${victoryInfo(victory)}`
  if (combined.length <= 280) return combined
  return victory.message.slice(0, 280)
}

/** A ready x.com intent URL: message + amount + round (+ seats), encoded. X
 *  can't take an image through the intent; the modal copies the PNG first. */
export function bragUrl(victory: Victory): string {
  return `https://x.com/intent/tweet?text=${encodeURIComponent(bragText(victory))}`
}
