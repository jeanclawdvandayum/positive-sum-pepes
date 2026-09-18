/** Gross mixETH input; checked against deployed getters before wallet writes. */
export const MIN_BUY_INPUT = 5_000_000_000_000_000n
export const TIME_PER_UNIT = 69n
/// ladder shares, newest seat → oldest (CLOCK-REDESIGN §2); renormalized over the seats actually taken.
export const LADDER_SHARES = [25, 18, 14, 10, 8, 7, 6, 5, 4, 3] as const
/// sine v3 (TICKET_RULES_VERSION 3): the entire accounted pot prices 10,000
/// tickets — ceil(potBalance / 10_000), floored at one wei.
export const TICKETS_PER_POT = 10_000n
export const purchaseUnits = (mixIn: bigint, ticketPrice: bigint | undefined = MIN_BUY_INPUT) =>
  ticketPrice !== undefined && ticketPrice > 0n ? mixIn / ticketPrice : 0n
export const linearTicketPrice = (pot: bigint, genesisPot: bigint) =>
  MIN_BUY_INPUT + (pot > genesisPot ? (pot - genesisPot) * 21n / 1_000_000n : 0n)
/** v3 ticket price mirrored from the hook: integer ceiling, one-wei floor.
 * Display and one-ticket fills use the exact bigint — never a float. */
export const potTicketPrice = (pot: bigint) => {
  if (pot < 0n) throw new Error('Pot balance cannot be negative.')
  const q = pot / TICKETS_PER_POT
  const price = pot % TICKETS_PER_POT !== 0n ? q + 1n : q
  return price === 0n ? 1n : price
}
export class GameRulesMismatch extends Error {}

/** Never convert token amounts to floating point for transaction protection. */
export function minimumOutput(quote: bigint, slippageBps: number): bigint {
  if (quote <= 0n) throw new Error('No executable quote. Refresh and try again.')
  if (!Number.isInteger(slippageBps) || slippageBps < 0 || slippageBps >= 10_000) {
    throw new Error('Slippage must be between 0% and 100% (exclusive).')
  }
  const result = quote * BigInt(10_000 - slippageBps) / 10_000n
  if (result === 0n) throw new Error('Output is too small for slippage protection.')
  return result
}

/** The live gross minimum for the selected round: one current ticket on v3,
 * the historical 0.005 constant on legacy rounds. undefined = unavailable —
 * exposure-increasing actions must stay disabled, never fall back. */
export function minimumBuyInput(
  ticketRules: bigint | undefined, ticketPrice: bigint | undefined,
): bigint | undefined {
  if (ticketRules === 3n) return ticketPrice !== undefined && ticketPrice > 0n ? ticketPrice : undefined
  return ticketRules === 1n || ticketRules === 2n ? MIN_BUY_INPUT : undefined
}

/** A guarded v3 purchase carries the quoted ticket intent; a price move past
 * it must fail clearly before the wallet is opened (the hook reverts
 * TicketPriceMoved as the backstop). */
export function assertTicketGuard(maxTicketPrice: bigint | undefined, liveTicketPrice: bigint | undefined): void {
  if (liveTicketPrice === undefined) throw new Error('The current ticket price is unavailable. Refresh before purchasing.')
  if (maxTicketPrice === undefined || maxTicketPrice <= 0n) {
    throw new Error('This purchase carries no ticket price guard. Refresh for a new quote.')
  }
  if (maxTicketPrice < liveTicketPrice) {
    throw new Error('The ticket price moved after your quote. Refresh for a new price and try again.')
  }
}

export function assertGameRules(minimum: bigint, seconds: bigint, ticketRules = 2n): void {
  if (ticketRules === 3n) {
    // v3: the minimum IS the live ticket price — dynamic, never the 0.005
    // constant. Only immutable facts gate compatibility here.
    if (seconds !== TIME_PER_UNIT || minimum <= 0n) {
      throw new GameRulesMismatch('This deployment uses different game rules. Use the interface for that deployment.')
    }
    return
  }
  if (minimum !== MIN_BUY_INPUT || seconds !== TIME_PER_UNIT || ticketRules !== 2n) {
    throw new GameRulesMismatch('This deployment uses different game rules. Use the interface for that deployment.')
  }
}
