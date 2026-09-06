import test from 'node:test'
import assert from 'node:assert/strict'
import { createTradeHistoryReader, findRoundStartBlock, summarizeTradeLogs } from '../src/lib/tradeHistory.ts'

const alice = '0x00000000000000000000000000000000000000ab'
const bob = '0x00000000000000000000000000000000000000cd'
const buy = (block, mix, addr = alice, index = 0) => ({
  blockNumber: BigInt(block), logIndex: index, transactionHash: `tx-${block}-${index}`,
  eventName: 'Buy', args: { buyer: addr, mixETHIn: mix, pspOut: 100n },
})
const inRange = (logs, from, to) => logs.filter(log => log.blockNumber >= from && log.blockNumber <= to)

test('round start lookup includes construction, handles timestamp gaps and rejects a lagging head', async () => {
  const stamps = [100n, 102n, 102n, 106n, 110n]
  const read = async block => stamps[Number(block)]
  assert.equal(await findRoundStartBlock(read, 102n, 0n, 4n), 1n)
  assert.equal(await findRoundStartBlock(read, 103n, 0n, 4n), 3n)
  assert.equal(await findRoundStartBlock(read, 100n, 0n, 4n), 0n)
  assert.equal(await findRoundStartBlock(read, 110n, 0n, 4n), 4n)
  await assert.rejects(findRoundStartBlock(read, 111n, 0n, 4n), /ahead/)
})

test('a late round loads from its own creation block, including the first trade', async () => {
  const calls = []
  const logs = [buy(51_600, 7n), buy(52_000, 11n)]
  const reader = createTradeHistoryReader({
    head: async () => 52_000n, timestamp: async block => block * 2n,
    logs: async (from, to) => { calls.push([from, to]); return inRange(logs, from, to) },
  }, 103_200n, 0n)
  assert.equal(reader.snapshot.volumeWad, undefined)
  const result = await reader.poll()
  assert.equal(result.complete, true)
  assert.equal(result.error, false)
  assert.equal(result.volumeWad, 18n)
  assert.equal(result.feesWad, 0n)
  assert.deepEqual(result.entries.map(entry => entry.block), [52_000n, 51_600n])
  assert.ok(calls.every(([from]) => from >= 51_600n))
  assert.equal(reader.snapshot, result, 'completed data stays available when the view remounts')
  const before = calls.length
  await reader.poll()
  assert.equal(calls.length, before, 'an unchanged head reuses completed history')
})

test('recent trades appear before long backfill finishes and partial totals never read as zero', async () => {
  const logs = [buy(0, 5n), buy(14_000, 11n)]
  const reader = createTradeHistoryReader({
    head: async () => 14_000n, timestamp: async block => block,
    logs: async (from, to) => inRange(logs, from, to),
  }, 0n, 0n)
  const first = await reader.poll()
  assert.equal(first.complete, false)
  assert.equal(first.entries[0].block, 14_000n)
  assert.equal(first.volumeWad, undefined)
  assert.equal(first.feesWad, undefined)
  let final = first
  for (let i = 0; i < 4 && !final.complete; i++) final = await reader.poll()
  assert.equal(final.complete, true)
  assert.equal(final.volumeWad, 16n)
  assert.equal(final.entries.length, 2, 'recent/backfill overlap counts each trade once')
})

test('a later failed page retains progress and recent trades, then resumes without skipping totals', async () => {
  const calls = []
  const logs = [buy(500, 5n), buy(1500, 7n), buy(6000, 11n)]
  let fail = true
  const reader = createTradeHistoryReader({
    head: async () => 6000n, timestamp: async block => block,
    logs: async (from, to) => {
      calls.push([from, to])
      if (from === 1000n && fail) { fail = false; throw new Error('rate limited') }
      return inRange(logs, from, to)
    },
  }, 0n, 0n)
  const first = await reader.poll()
  assert.equal(first.error, true)
  assert.equal(first.volumeWad, undefined)
  assert.equal(first.entries[0].block, 6000n)
  await reader.poll()
  assert.equal(calls[3][0], 988n, 'retry resumes at the completed page with reorg overlap')
  const result = await reader.poll()
  assert.equal(result.error, false)
  assert.equal(result.complete, true)
  assert.equal(result.volumeWad, 23n)
  assert.equal(result.entries.length, 3)
})

test('failed refresh keeps known totals and recovers with the new trade', async () => {
  let head = 100n
  let fail = false
  const logs = [buy(90, 5n)]
  const reader = createTradeHistoryReader({
    head: async () => { if (fail) throw new Error('offline'); return head },
    timestamp: async block => block,
    logs: async (from, to) => inRange(logs, from, to),
  }, 0n, 0n)
  await reader.poll()
  fail = true
  const stale = await reader.poll()
  assert.equal(stale.error, true)
  assert.equal(stale.volumeWad, 5n)
  assert.equal(stale.entries.length, 1)
  fail = false
  head = 101n
  logs.push(buy(101, 7n))
  const recovered = await reader.poll()
  assert.equal(recovered.error, false)
  assert.equal(recovered.volumeWad, 12n)
})

test('concurrent subscribers share a poll and different rounds retain separate histories', async () => {
  let release
  const waiting = new Promise(resolve => { release = resolve })
  const source = { head: async () => { await waiting; return 10n }, timestamp: async block => block,
    logs: async (from, to) => inRange([buy(10, 7n)], from, to) }
  const first = createTradeHistoryReader(source, 0n, 0n)
  const a = first.poll()
  const b = first.poll()
  assert.equal(a, b)
  const second = createTradeHistoryReader({ ...source, logs: async () => [] }, 10n, 0n)
  assert.equal(second.snapshot.volumeWad, undefined)
  assert.equal(second.snapshot.entries.length, 0)
  release()
  assert.equal((await a).volumeWad, 7n)
  assert.equal((await second.poll()).volumeWad, 0n, 'zero requires a fully read empty round')
  assert.equal(first.snapshot.volumeWad, 7n)
})

test('summary handles numeric ordering, zero clock extension, fees, sells and duplicate pages', () => {
  const earlier = buy(999, 5n)
  const newer = buy(1000, 11n, alice, 2)
  const time = { ...newer, logIndex: 0, eventName: 'TimeAdded', blockTimestamp: 2000n,
    args: { buyer: alice, secondsAdded: 0n } }
  const fee = { ...newer, logIndex: 1, eventName: 'FeesAdded', args: { mixETHAmount: 3n } }
  const sell = { ...buy(1001, 0n), eventName: 'Sell', args: { seller: bob, pspIn: 50n, mixETHOut: 7n } }
  const result = summarizeTradeLogs([newer, fee, earlier, time, newer, sell, fee], true)
  assert.equal(result.volumeWad, 23n)
  assert.equal(result.feesWad, 3n)
  assert.deepEqual(result.entries.map(entry => entry.kind), ['sell', 'buy', 'buy'])
  assert.equal(result.entries[1].addedMs, 0)
  assert.deepEqual(result.lastTime, { addr: alice, secondsAdded: 0n, atSec: 2000 })
})

test('several buys in one transaction retain their individual clock extensions', () => {
  const first = buy(100, 5n, alice, 1)
  const second = { ...buy(100, 7n, alice, 3), transactionHash: first.transactionHash }
  const timeA = { ...first, logIndex: 0, eventName: 'TimeAdded', args: { buyer: alice, secondsAdded: 260n } }
  const timeB = { ...first, logIndex: 2, eventName: 'TimeAdded', args: { buyer: alice, secondsAdded: 30n } }
  const result = summarizeTradeLogs([second, timeA, first, timeB], true)
  assert.deepEqual(result.entries.map(entry => entry.addedMs), [30_000, 260_000])
  assert.equal(result.volumeWad, 12n)
})

test('a short reorg replaces changed trades and removes orphaned totals', async () => {
  let head = 100n
  let logs = [buy(95, 5n), buy(100, 7n)]
  const reader = createTradeHistoryReader({ head: async () => head, timestamp: async block => block,
    logs: async (from, to) => inRange(logs, from, to) }, 0n, 0n)
  assert.equal((await reader.poll()).volumeWad, 12n)
  head = 99n
  logs = [buy(95, 11n)]
  const changed = await reader.poll()
  assert.equal(changed.volumeWad, 11n)
  assert.equal(changed.entries.length, 1)
  head = 100n
  logs.push(buy(100, 13n))
  assert.equal((await reader.poll()).volumeWad, 24n)
})
