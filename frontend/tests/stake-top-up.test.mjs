import test from 'node:test'
import assert from 'node:assert/strict'
import { parseTopUpAmount, topUpPosition } from '../src/lib/stakeTopUp.ts'
import { wadToExact } from '../src/lib/format.ts'

const owner = '0x00000000000000000000000000000000000000aA'
const stranger = '0x00000000000000000000000000000000000000bb'
const staker = '0x00000000000000000000000000000000000000cc'
const target = { owner, staker, id: 202n, amount: 25n * 10n ** 18n }
const initial = { owner: owner.toLowerCase(), withdrawing: false, balance: target.amount * 2n, allowance: 0n, mode: 1, flatTime: 0n }

function fixture(overrides = {}) {
  const state = { ...initial, ...overrides }
  const events = []
  let session = true
  const operations = {
    assertSession: () => { if (!session) throw new Error('session changed') },
    read: async () => { events.push('read'); return { ...state } },
    approve: async (spender, amount) => {
      events.push(['approve', spender, amount])
      state.allowance = amount
    },
    stake: async (user, id, amount) => { events.push(['stakeFor', user, id, amount]) },
    onStep: step => { events.push(step) },
  }
  return { state, events, operations, changeSession: () => { session = false } }
}

test('top-up input preserves exact Max and single-wei amounts without rounding', () => {
  const balance = 987654321012345678901234567890n
  assert.equal(parseTopUpAmount(wadToExact(balance)), balance)
  assert.equal(parseTopUpAmount('.000000000000000001'), 1n)
  assert.equal(parseTopUpAmount(' 25. '), target.amount)
  for (const value of ['', '.', '0', '-0.1', '1.2.3', '1e18', '1,000', '+1', '0.0000000000000000001', 'Infinity', (2n ** 256n).toString()]) {
    assert.equal(parseTopUpAmount(value), undefined, value)
  }
})

test('top-up approves only the requested amount and keeps the owner and NFT id', async () => {
  const { events, operations } = fixture()
  await topUpPosition(target, operations)
  assert.deepEqual(events, ['checking', 'read', 'approve', ['approve', staker, target.amount],
    'checking', 'read', 'stake', ['stakeFor', owner, 202n, target.amount]])
})

test('existing PSP allowance skips a redundant approval', async () => {
  const { events, operations } = fixture({ allowance: target.amount })
  await topUpPosition(target, operations)
  assert.deepEqual(events, ['checking', 'read', 'stake', ['stakeFor', owner, 202n, target.amount]])
})

test('insufficient balance, transferred NFT, withdrawal and dead rounds never request approval', async () => {
  const cases = [
    [{ balance: target.amount - 1n }, /Not enough PSP/],
    [{ owner: stranger }, /no longer owned/],
    [{ withdrawing: true }, /Cancel.*withdrawal/],
    [{ mode: 2 }, /round has ended/],
    [{ mode: 3 }, /round has ended/],
    [{ flatTime: 123n }, /round has ended/],
  ]
  for (const [state, error] of cases) {
    const { events, operations } = fixture(state)
    await assert.rejects(topUpPosition(target, operations), error)
    assert.deepEqual(events, ['checking', 'read'])
  }
})

test('approval rejection, revert or unknown confirmation cannot proceed to staking', async () => {
  for (const error of ['User rejected', 'Transaction reverted', 'timeout']) {
    const { events, operations } = fixture()
    operations.approve = async () => { throw new Error(error) }
    await assert.rejects(topUpPosition(target, operations), new RegExp(error))
    assert.ok(!events.includes('stake'))
  }
})

test('state changes during approval are rechecked before the second wallet transaction', async () => {
  for (const change of [
    state => { state.owner = stranger },
    state => { state.withdrawing = true },
    state => { state.mode = 2 },
    state => { state.balance = 0n },
    state => { state.allowance = 0n },
  ]) {
    const { state, events, operations } = fixture()
    const approve = operations.approve
    operations.approve = async (...args) => { await approve(...args); change(state) }
    await assert.rejects(topUpPosition(target, operations))
    assert.equal(events.filter(event => event === 'read').length, 2)
    assert.ok(!events.includes('stake'))
  }
})

test('wallet, chain or round change while checking or approving stops the top-up', async () => {
  for (const stage of ['read', 'approve']) {
    const { operations, events, changeSession } = fixture()
    const original = operations[stage]
    operations[stage] = async (...args) => { const result = await original(...args); changeSession(); return result }
    await assert.rejects(topUpPosition(target, operations), /session changed/)
    assert.ok(!events.includes('stake'))
  }
})

test('failed staking receipt propagates as a failure and never repeats the write', async () => {
  const { operations, events } = fixture({ allowance: target.amount })
  operations.stake = async () => { throw new Error('Transaction reverted') }
  await assert.rejects(topUpPosition(target, operations), /Transaction reverted/)
  assert.equal(events.filter(event => event === 'stake').length, 1)
})
