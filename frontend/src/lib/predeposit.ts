import { MIN_BUY_INPUT } from './gameRules.ts'
import { wadToExact } from './format.ts'


/// Normalized predepositState across rules eras: v3 controllers return an
/// 11-tuple (…, phase, greenTotal, greenPerWallet, openPerWallet), legacy
/// v1/v2 the old 7-tuple off the SAME selector. The shape IS the version
/// detector — green fields stay undefined on legacy rounds.
export interface PredepositStateView {
  total: bigint
  cap: bigint
  startTime: bigint
  closed: boolean
  capReached: boolean
  windowOver: boolean
  launchable: boolean
  phase: number | undefined
  greenTotal: bigint | undefined
  greenPerWallet: bigint | undefined
  openPerWallet: bigint | undefined
}

export function normalizePredepositState(raw: unknown): PredepositStateView | undefined {
  if (!Array.isArray(raw) || raw.length < 7) return undefined
  const total = typeof raw[0] === 'bigint' ? raw[0] : undefined
  const cap = typeof raw[1] === 'bigint' ? raw[1] : undefined
  const startTime = typeof raw[2] === 'bigint' ? raw[2] : undefined
  const [closed, capReached, windowOver, launchable] = [raw[3], raw[4], raw[5], raw[6]]
  if (total === undefined || cap === undefined || startTime === undefined) return undefined
  if (![closed, capReached, windowOver, launchable].every((flag) => typeof flag === 'boolean')) return undefined
  const word = (value: unknown) => (typeof value === 'bigint' ? value : undefined)
  const phase = word(raw[7])
  return {
    total, cap, startTime,
    closed, capReached, windowOver, launchable,
    phase: phase === undefined ? undefined : Number(phase),
    greenTotal: word(raw[8]),
    greenPerWallet: word(raw[9]),
    openPerWallet: word(raw[10]),
  }
}
/** Capability checks preserve the limits of each deployed round. */
export const predepositMinimum = (version: unknown) => version === 1n || version === 2n || version === 3n ? 1n : MIN_BUY_INPUT
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

/// ── greenlist-IBCO (rules v3) phase math ────────────────────────────────
/// Mirrors RoundController: green window [start, start+GREEN), open window
/// up to start+GREEN+OPEN — except a round with zero greenlist members
/// (greenPerWallet = 0) runs one OPEN-duration window for everyone.

export function ibcoPhaseAt(nowSec: number, greenEnd: bigint | undefined, openEnd: bigint | undefined): 0 | 1 | 2 | undefined {
  if (openEnd === undefined) return undefined
  const now = BigInt(Math.floor(Math.max(0, nowSec)))
  if (greenEnd !== undefined && now < greenEnd) return 0
  return now < openEnd ? 1 : 2
}

/// Window ends off a controller's immutables: greenSec/openSec on v3,
/// PREDEPOSIT_DURATION on legacy rounds. startTime comes from state.
export function ibcoEnds(
  startTime: bigint | undefined,
  greenSec: bigint | undefined,
  openSec: bigint | undefined,
  legacySec: bigint | undefined,
  greenPerWallet: bigint | undefined,
): { greenEnd: bigint | undefined; openEnd: bigint | undefined } {
  if (startTime === undefined) return { greenEnd: undefined, openEnd: undefined }
  if (greenSec !== undefined && openSec !== undefined) {
    return greenPerWallet === 0n
      ? { greenEnd: undefined, openEnd: startTime + openSec }
      : { greenEnd: startTime + greenSec, openEnd: startTime + greenSec + openSec }
  }
  return { greenEnd: undefined, openEnd: legacySec !== undefined ? startTime + legacySec : undefined }
}

/// Green tranche headroom: the 500/N per-wallet cap less this wallet's
/// green deposits (contract: greenAmount + amount > GREEN_PER_WALLET).
export function greenWalletHeadroom(greenPerWallet: bigint, myGreen: bigint): bigint {
  return greenPerWallet > 0n ? capHeadroom(myGreen, greenPerWallet) : 0n
}

/// The most a wallet can still commit in the green phase.
export function greenPhaseLimit(balance: bigint, total: bigint, cap: bigint, greenPerWallet: bigint, myGreen: bigint): bigint {
  return [balance, capHeadroom(total, cap), greenWalletHeadroom(greenPerWallet, myGreen)].reduce((a, b) => (a < b ? a : b))
}

/// The most a wallet can still commit in the open phase — the 10-mix cap
/// prices OPEN deposits only (contract: mixETHAmount - greenAmount + amount
/// > OPEN_PER_WALLET), so green money never eats open headroom.
export function openPhaseLimit(balance: bigint, total: bigint, cap: bigint, openPerWallet: bigint, myTotal: bigint, myGreen: bigint): bigint {
  const wallet = openPerWallet > 0n ? capHeadroom(myTotal - myGreen, openPerWallet) : balance
  return [balance, capHeadroom(total, cap), wallet].reduce((a, b) => (a < b ? a : b))
}
