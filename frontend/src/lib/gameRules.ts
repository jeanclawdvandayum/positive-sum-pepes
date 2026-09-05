/** Gross mixETH input; checked against deployed getters before wallet writes. */
export const MIN_BUY_INPUT = 5_000_000_000_000_000n
export const TIME_PER_UNIT = 260n
export const purchaseUnits = (mixIn: bigint) => mixIn / MIN_BUY_INPUT

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

export function assertGameRules(minimum: bigint, seconds: bigint): void {
  if (minimum !== MIN_BUY_INPUT || seconds !== TIME_PER_UNIT) {
    throw new Error('This deployment uses different game rules. Use the interface for that deployment.')
  }
}
