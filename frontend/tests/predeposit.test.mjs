import { test } from 'node:test'
import assert from 'node:assert/strict'
import { parseAmountToWad, wadToExact } from '../src/lib/format.ts'
import { MIN_BUY_INPUT } from '../src/lib/gameRules.ts'
import { capHeadroom, predepositUncapped, predepositLimit, predepositMinimum, predepositAmountAllowed, predepositProgress, predepositRemainder, ibcoPhaseAt, ibcoEnds, greenWalletHeadroom, greenPhaseLimit, openPhaseLimit } from '../src/lib/predeposit.ts'
const cap = 500n * 10n ** 18n

test('499.9999999 stays visibly below 500 and MAX preserves its exact dust remainder', () => {
  const total = parseAmountToWad('499.9999999')
  const max = predepositLimit(cap, total, cap, 0n, 0n)
  assert.equal(predepositProgress(total, cap), '499.9999999 / 500 mixETH')
  assert.equal(wadToExact(max), '0.0000001')
  assert.equal(predepositRemainder(total, cap), '0.0000001 mixETH remaining')
  assert.equal(parseAmountToWad(wadToExact(max)), cap - total)
  assert(predepositAmountAllowed(max, predepositMinimum(1n), max))
  assert(!predepositAmountAllowed(max + 1n, predepositMinimum(1n), max))
})
test('the live round remainder and one-wei cap boundary never become rounded 500/500', () => {
  for (const dust of [100000000n, 1n]) {
    const total = cap - dust
    assert.notEqual(predepositProgress(total, cap), '500 / 500 mixETH')
    assert.equal(parseAmountToWad(wadToExact(predepositLimit(cap, total, cap, 0n, 0n))), dust)
    assert.equal(capHeadroom(total, cap), dust)
  }
  assert.equal(predepositRemainder(cap - 1n, cap), '0.000000000000000001 mixETH remaining')
})
test('all positive sub-buy-minimum deposits qualify, beyond just a final-cap-fill exception', () => {
  for (const amount of [1n, 2n, 100000000n, MIN_BUY_INPUT - 1n, MIN_BUY_INPUT])
    assert(predepositAmountAllowed(amount, predepositMinimum(1n), cap))
  assert(!predepositAmountAllowed(0n, 1n, cap))
  assert(!predepositAmountAllowed(-1n, 1n, cap))
  assert(!predepositAmountAllowed(1n, 1n, undefined))
  assert(!predepositAmountAllowed(1n, 1n, 0n))
})
test('legacy and unreadable deployments retain their actual old minimum', () => {
  assert.equal(predepositMinimum(1n), 1n)
  assert.equal(predepositMinimum(2n), 1n)
  assert.equal(predepositMinimum(3n), 1n) // v3 predeposits stay any-positive
  for (const version of [undefined, null, 0n, 4n, '1', 1]) {
    const minimum = predepositMinimum(version)
    assert.equal(minimum, MIN_BUY_INPUT)
    assert(!predepositAmountAllowed(1n, minimum, cap))
    assert(predepositAmountAllowed(MIN_BUY_INPUT, minimum, cap))
  }
})
test('MAX respects wallet headroom, global headroom and balance, clamping already-filled caps', () => {
  assert.equal(predepositLimit(100n, 10n, cap, 50n, 49n), 1n)
  assert.equal(predepositLimit(5n, 10n, cap, 50n, 0n), 5n)
  assert.equal(predepositLimit(100n, cap - 3n, cap, 0n, 1000000n), 3n)
  assert.equal(predepositLimit(100n, cap, cap, 0n, 0n), 0n)
  assert.equal(predepositLimit(100n, cap + 1n, cap, 0n, 0n), 0n)
  assert.equal(predepositLimit(100n, 0n, cap, 50n, 51n), 0n)
})
test('wei-scale MAX remains exact across a deterministic range of wallet, balance and global limits', () => {
  for (let dust = 1n; dust <= 512n; dust++) {
    const total = cap - dust
    const wallet = dust % 31n, balance = dust % 23n
    const limit = predepositLimit(balance, total, cap, cap, cap - wallet)
    assert(limit >= 0n && limit <= dust && limit <= wallet && limit <= balance)
    assert.equal(parseAmountToWad(wadToExact(limit)), limit)
    assert.equal(predepositAmountAllowed(limit, 1n, limit), limit > 0n)
    assert(!predepositAmountAllowed(limit + 1n, 1n, limit))
  }
})

test('version two zero-cap IBCOs take exact wallet balance, including tiny and very large raises', () => {
  assert.equal(predepositMinimum(2n), 1n)
  for (const total of [0n, 1n, cap, 10n ** 60n]) {
    for (const balance of [1n, cap, 10n ** 50n]) {
      assert.equal(predepositLimit(balance, total, 0n, 0n, total, 2n), balance)
      assert(predepositAmountAllowed(balance, predepositMinimum(2n), balance))
    }
    assert.equal(predepositLimit(100n, total, 0n, 50n, 49n, 2n), 1n)
    assert.equal(predepositLimit(100n, total, 0n, 50n, 50n, 2n), 0n)
  }
  assert.equal(predepositProgress(cap, 0n, 2n), '500 mixETH pooled')
  assert.equal(predepositRemainder(cap, 0n, 2n), 'uncapped IBCO')
})
test('zero means unlimited only with the exact on-chain version capability', () => {
  for (const version of [undefined, null, 0n, 1n, 3n, '2', 2]) {
    assert.equal(predepositUncapped(version, 0n), false)
    assert.equal(predepositLimit(cap, cap, 0n, 0n, 0n, version), 0n)
  }
  assert.equal(predepositUncapped(2n, 0n), true)
  // Historical caps stay enforced even if a new version is misconfigured.
  assert.equal(predepositUncapped(2n, cap), false)
  assert.equal(predepositLimit(cap, cap - 1n, cap, 0n, 0n, 2n), 1n)
})


/// ── greenlist-IBCO (rules v3): phase boundaries, window ends, cap math ──

const mix = (n) => parseAmountToWad(String(n))

test('phase flips exactly at the green and open boundaries the contract uses', () => {
  const start = 1000n, greenSec = 86400n, openSec = 86400n
  const greenEnd = start + greenSec, openEnd = greenEnd + openSec
  assert.equal(ibcoPhaseAt(Number(greenEnd) - 1, greenEnd, openEnd), 0)
  assert.equal(ibcoPhaseAt(Number(greenEnd), greenEnd, openEnd), 1)
  assert.equal(ibcoPhaseAt(Number(openEnd) - 1, greenEnd, openEnd), 1)
  assert.equal(ibcoPhaseAt(Number(openEnd), greenEnd, openEnd), 2)
  assert.equal(ibcoPhaseAt(Number(openEnd) + 987654, greenEnd, openEnd), 2)
  // no ends decoded yet → unknown, never a wrong phase
  assert.equal(ibcoPhaseAt(Number(greenEnd), undefined, undefined), undefined)
  assert.equal(ibcoPhaseAt(Number(greenEnd), undefined, openEnd), 1)
})

test('window ends follow the era: legacy single window, v3 two windows, rootless v3 one open window', () => {
  const start = 5000n
  assert.deepEqual(ibcoEnds(start, undefined, undefined, 7200n, undefined), { greenEnd: undefined, openEnd: start + 7200n })
  assert.deepEqual(ibcoEnds(start, 60n, 30n, undefined, 50n), { greenEnd: start + 60n, openEnd: start + 90n })
  // greenPerWallet = 0: no members, the whole window is one OPEN_DURATION
  assert.deepEqual(ibcoEnds(start, 60n, 30n, undefined, 0n), { greenEnd: undefined, openEnd: start + 30n })
  assert.deepEqual(ibcoEnds(undefined, 60n, 30n, undefined, 50n), { greenEnd: undefined, openEnd: undefined })
})

test('green-phase MAX respects the 500/N per-wallet cap, the shared round cap and balance', () => {
  assert.equal(greenPhaseLimit(mix(1000), mix(200), mix(1000), mix(50), mix(12)), mix(38))
  assert.equal(greenPhaseLimit(mix(10), mix(200), mix(1000), mix(50), mix(12)), mix(10))
  assert.equal(greenPhaseLimit(mix(1000), mix(990), mix(1000), mix(50), mix(0)), mix(10))
  assert.equal(greenPhaseLimit(mix(1000), mix(200), mix(1000), mix(50), mix(50)), 0n)
  assert.equal(greenWalletHeadroom(mix(50), mix(12)), mix(38))
  assert.equal(greenWalletHeadroom(mix(50), mix(77)), 0n)
  // a zero green cap (rootless round) leaves nothing to commit in green
  assert.equal(greenWalletHeadroom(0n, mix(50)), 0n)
})

test('open-phase MAX prices only open money against the 10-mix cap — green never eats open headroom', () => {
  const openCap = mix(10)
  // 12 committed, 12 of it green → open spend 0 → full 10 available
  assert.equal(openPhaseLimit(mix(1000), mix(200), mix(1000), openCap, mix(12), mix(12)), openCap)
  // 12 committed, 5 green → open spend 7 → 3 left
  assert.equal(openPhaseLimit(mix(1000), mix(200), mix(1000), openCap, mix(12), mix(5)), mix(3))
  // already at the cap
  assert.equal(openPhaseLimit(mix(1000), mix(200), mix(1000), openCap, mix(10), 0n), 0n)
  // balance and the shared round cap still clamp
  assert.equal(openPhaseLimit(mix(4), mix(200), mix(1000), openCap, mix(0), 0n), mix(4))
  assert.equal(openPhaseLimit(mix(1000), mix(998), mix(1000), openCap, mix(0), 0n), mix(2))
})