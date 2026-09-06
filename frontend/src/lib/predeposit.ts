import { MIN_BUY_INPUT } from './gameRules.ts'
import { wadToExact } from './format.ts'

/** Missing/older capability keeps the deployed legacy floor. Never infer
 * transaction limits from compact display strings or JavaScript floats. */
export const predepositMinimum = (version: unknown) => version === 1n ? 1n : MIN_BUY_INPUT
export const capHeadroom = (total: bigint, cap: bigint) => total < cap ? cap - total : 0n
export function predepositLimit(balance: bigint, total: bigint, cap: bigint, walletCap: bigint, deposited: bigint) {
  const global = capHeadroom(total, cap)
  const wallet = walletCap > 0n ? capHeadroom(deposited, walletCap) : global
  return [balance, global, wallet].reduce((a, b) => a < b ? a : b)
}
export function predepositAmountAllowed(amount: bigint, minimum: bigint, limit: bigint | undefined) {
  return limit !== undefined && amount > 0n && amount >= minimum && amount <= limit
}
export function predepositProgress(total: bigint, cap: bigint) {
  return `${wadToExact(total)} / ${wadToExact(cap)} mixETH`
}
export function predepositRemainder(total: bigint, cap: bigint) {
  return `${wadToExact(capHeadroom(total, cap))} mixETH remaining`
}
