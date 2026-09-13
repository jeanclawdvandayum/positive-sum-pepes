import { MIN_BUY_INPUT } from './gameRules.ts'
import { wadToExact } from './format.ts'

/** Capability checks preserve the limits of each deployed round. */
export const predepositMinimum = (version: unknown) => version === 1n || version === 2n ? 1n : MIN_BUY_INPUT
export const predepositUncapped = (version: unknown, cap: bigint) => version === 2n && cap === 0n
export const capHeadroom = (total: bigint, cap: bigint) => total < cap ? cap - total : 0n
export function predepositLimit(balance: bigint, total: bigint, cap: bigint, walletCap: bigint, deposited: bigint, version?: unknown) {
  const global = predepositUncapped(version, cap) ? balance : capHeadroom(total, cap)
  const wallet = walletCap > 0n ? capHeadroom(deposited, walletCap) : balance
  return [balance, global, wallet].reduce((a, b) => a < b ? a : b)
}
export function predepositAmountAllowed(amount: bigint, minimum: bigint, limit: bigint | undefined) {
  return limit !== undefined && amount > 0n && amount >= minimum && amount <= limit
}
export function predepositProgress(total: bigint, cap: bigint, version?: unknown) {
  return predepositUncapped(version, cap) ? `${wadToExact(total)} mixETH pooled`
    : `${wadToExact(total)} / ${wadToExact(cap)} mixETH`
}
export function predepositRemainder(total: bigint, cap: bigint, version?: unknown) {
  return predepositUncapped(version, cap) ? 'uncapped IBCO'
    : `${wadToExact(capHeadroom(total, cap))} mixETH remaining`
}
