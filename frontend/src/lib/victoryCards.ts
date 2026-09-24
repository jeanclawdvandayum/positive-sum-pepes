// Persistent victory cards (Round 4): a confirmed claimPot pushes a card that
// stays until the user closes it. Same external-store shape as
// transactionToasts — module-level, snapshot/subscribe — and inert until
// something subscribes, so the original UI never touches it.

import { fmtAmount } from './format.ts'

export type VictoryCard = {
  id: number
  roundId: bigint
  roundName?: string
  amountMix: bigint
  message: string
  txHash?: `0x${string}`
  at: number
}

/** The claimPot banner and card pick one of these at random. Lowercase deadpan,
 *  except the one entry the community supplied verbatim. */
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

export function pickVictoryMessage(): string {
  return VICTORY_MESSAGES[Math.floor(Math.random() * VICTORY_MESSAGES.length)]
}

let cards: VictoryCard[] = []
let nextId = 0
const listeners = new Set<() => void>()

function emit(): void {
  listeners.forEach(listener => listener())
}

export const victoryCards = {
  subscribe(listener: () => void) {
    listeners.add(listener)
    return () => { listeners.delete(listener) }
  },
  snapshot: () => cards,
  /** True while something renders the stack (AltShell). Like fireFx, the store
   *  stays inert without a subscriber: the original UI never accumulates cards. */
  get active() {
    return listeners.size > 0
  },
  /** Newest first, so the stack reads newest-at-top. Returns the card either
   *  way (the dev lab and bragText only need the object), but nothing is
   *  stored without a subscriber. */
  push(entry: Omit<VictoryCard, 'id' | 'at'>): VictoryCard {
    const card: VictoryCard = { ...entry, id: ++nextId, at: Date.now() }
    if (!listeners.size) return card
    cards = [card, ...cards]
    emit()
    return card
  },
  dismiss(id: number) {
    if (!cards.some(card => card.id === id)) return
    cards = cards.filter(card => card.id !== id)
    emit()
  },
  /** The dev lab's reset control. */
  clear() {
    if (!cards.length) return
    cards = []
    emit()
  },
}

/** 'i just claimed 12.34 mixETH from the round 3 pot on positive sum pepes 🚀' */
function victoryInfo(card: VictoryCard): string {
  return `i just claimed ${fmtAmount(card.amountMix)} mixETH from the round ${card.roundId.toString()} pot on positive sum pepes 🚀`
}

/** message first; when the pair overflows X's 280-char post the victory-info
 *  sentence yields before the message does. */
export function bragText(card: VictoryCard): string {
  const info = victoryInfo(card)
  const combined = `${card.message}\n\n${info}`
  if (combined.length <= 280) return combined
  return card.message.slice(0, 280)
}

/** A ready intent URL: message + amount + round, properly encoded. */
export function bragUrl(card: VictoryCard): string {
  return `https://twitter.com/intent/tweet?text=${encodeURIComponent(bragText(card))}`
}
