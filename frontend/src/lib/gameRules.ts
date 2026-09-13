/** Gross mixETH input; checked against deployed getters before wallet writes. */
export const MIN_BUY_INPUT = 5_000_000_000_000_000n
export const TIME_PER_UNIT = 69n
export const purchaseUnits = (mixIn: bigint, ticketPrice: bigint | undefined = MIN_BUY_INPUT) =>
  ticketPrice !== undefined && ticketPrice > 0n ? mixIn / ticketPrice : 0n
export const linearTicketPrice = (pot: bigint, genesisPot: bigint) =>
  MIN_BUY_INPUT + (pot > genesisPot ? (pot - genesisPot) * 21n / 1_000_000n : 0n)
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

export function assertGameRules(minimum: bigint, seconds: bigint, ticketRules = 2n): void {
  if (minimum !== MIN_BUY_INPUT || seconds !== TIME_PER_UNIT || ticketRules !== 2n) {
    throw new GameRulesMismatch('This deployment uses different game rules. Use the interface for that deployment.')
  }
}
