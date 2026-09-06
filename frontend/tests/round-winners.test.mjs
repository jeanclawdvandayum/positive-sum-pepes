import test from 'node:test'
import assert from 'node:assert/strict'
import { groupRoundWinners, readRoundWinners } from '../src/lib/roundWinners.ts'

const address = n => `0x${n.toString(16).padStart(40, '0')}`
const hook = address(100)
const alice = address(171)
const bob = address(205)

test('a full final ladder awards the canonical shares in newest-seat order', () => {
  const result = groupRoundWinners(1000n, Array.from({ length: 10 }, (_, i) => address(i + 1)))
  assert.deepEqual(result.map(w => w.payout), [250n, 180n, 140n, 100n, 80n, 70n, 60n, 50n, 40n, 30n])
  assert.deepEqual(result.map(w => w.ranks), [[1], [2], [3], [4], [5], [6], [7], [8], [9], [10]])
})

test('wallet totals sum individually floored prizes, including case-insensitive repeated seats', () => {
  const upperAlice = `0x${alice.slice(2).toUpperCase()}`
  const result = groupRoundWinners(10n, [alice, bob, upperAlice])
  // Alice holds the first and third seats on a three-seat ladder.
  // With two seats of one owner: floor(250/43) + floor(180/43) = 9, not 10.
  assert.equal(result.length, 2)
  assert.deepEqual(result[0].ranks, [1, 3])
  assert.equal(result[0].payout, 6n)
  assert.equal(result[1].payout, 3n)
  const allAlice = groupRoundWinners(10n, [alice, upperAlice])
  assert.equal(allAlice[0].payout, 9n)
  assert.equal(allAlice[0].sharePercent, 100)
})

test('a single seat wins the whole pot and a zero-seat round has an empty winners list', () => {
  assert.deepEqual(groupRoundWinners(123n, [alice]), [{ address: alice, ranks: [1], payout: 123n, sharePercent: 100 }])
  assert.deepEqual(groupRoundWinners(0n, []), [])
})

test('archive reads only the final ten seats and never subtracts already claimed winnings', async () => {
  const calls = []
  const read = async (target, _abi, batch) => {
    assert.equal(target, hook)
    calls.push(...batch)
    if (batch[0].functionName === 'mode') return [2, 1000n, 123_456_789n]
    return batch.map(() => [alice, 0n, 1n, 42n])
  }
  const result = await readRoundWinners(read, hook)
  assert.equal(result.seats, 10)
  assert.equal(result.winners.length, 1)
  assert.equal(result.winners[0].payout, 1000n)
  assert.deepEqual(calls.slice(3).map(c => c.args[0]), [0n, 1n, 2n, 3n, 4n, 5n, 6n, 7n, 8n, 9n])
  assert.ok(calls.every(c => !['claimablePot', 'potPaid', 'seatClaimed'].includes(c.functionName)))
})

test('small ladders read only occupied seats and renormalize; an empty ladder needs no board calls', async () => {
  let count = 2n
  const read = async (_target, _abi, calls) => {
    if (calls[0].functionName === 'mode') return [3, count ? 43n : 0n, count]
    assert.equal(calls.length, 2)
    return [[alice, 1n, 1n, 1n], [bob, 1n, 1n, 1n]]
  }
  assert.deepEqual((await readRoundWinners(read, hook)).winners.map(w => w.payout), [25n, 18n])
  count = 0n
  assert.deepEqual(await readRoundWinners(read, hook), { seats: 0, winners: [] })
})

test('a failed or missing seat rejects the list instead of inflating the other winners’ shares', async () => {
  const failing = async (_target, _abi, calls) => {
    if (calls[0].functionName === 'mode') return [2, 43n, 2n]
    throw new Error('RPC unavailable')
  }
  await assert.rejects(readRoundWinners(failing, hook), /RPC unavailable/)
  await assert.rejects(readRoundWinners(async (_target, _abi, calls) =>
    calls[0].functionName === 'mode' ? [2, 43n, 2n] : [[alice, 1n, 1n, 1n]], hook), /Incomplete/)
  await assert.rejects(readRoundWinners(async (_target, _abi, calls) =>
    calls[0].functionName === 'mode' ? [2, 43n, 2n] : [[alice, 1n, 1n, 1n], undefined], hook), /Invalid/)
})

test('live rounds and invalid winner addresses cannot appear as finalized results', async () => {
  for (const mode of [0, 1, undefined]) {
    await assert.rejects(readRoundWinners(async () => [mode, 100n, 1n], hook), /unavailable/)
  }
  assert.throws(() => groupRoundWinners(100n, [address(0)]), /Invalid winner/)
  assert.throws(() => groupRoundWinners(100n, ['not an address']), /Invalid winner/)
})

test('different dead rounds read their own hook and preserve their own winners', async () => {
  const nextHook = address(101)
  const read = async (target, _abi, calls) => {
    if (calls[0].functionName === 'mode') return [2, target === hook ? 7n : 11n, 1n]
    return [[target === hook ? alice : bob, 1n, 1n, 1n]]
  }
  const [first, second] = await Promise.all([readRoundWinners(read, hook), readRoundWinners(read, nextHook)])
  assert.equal(first.winners[0].address, alice)
  assert.equal(first.winners[0].payout, 7n)
  assert.equal(second.winners[0].address, bob)
  assert.equal(second.winners[0].payout, 11n)
})
