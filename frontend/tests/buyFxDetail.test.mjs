import test from 'node:test'
import assert from 'node:assert/strict'
import { encodeAbiParameters, encodeEventTopics, pad, toEventSelector } from 'viem'
import { hookAbi } from '../src/lib/abi.ts'
import { buyFxDetail } from '../src/lib/buyFxDetail.ts'

// Real-shaped receipt logs, built the way a chain assembles them: topics from
// the event signature, indexed args padded into topics, the rest abi-encoded
// into data.
const HOOK = '0x0000000000000000000000000000000000000abc'
const BUYER = '0x00000000000000000000000000000000000000ab'
const ALICE = '0x00000000000000000000000000000000000000a1'

const timeAddedLog = (secondsAdded, buyer = BUYER, logIndex = 0) => ({
  address: HOOK,
  topics: encodeEventTopics({ abi: hookAbi, eventName: 'TimeAdded', args: { buyer } }),
  data: encodeAbiParameters([{ type: 'uint256' }, { type: 'uint256' }], [BigInt(secondsAdded), 1789452n]),
  blockNumber: 4200n,
  blockHash: `0x${'b'.repeat(64)}`,
  transactionHash: `0x${'7'.repeat(64)}`,
  transactionIndex: 0,
  logIndex,
  removed: false,
})

const buyLog = logIndex => ({
  address: HOOK,
  topics: encodeEventTopics({ abi: hookAbi, eventName: 'Buy', args: { buyer: BUYER } }),
  data: encodeAbiParameters(
    [{ type: 'uint256' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'uint256' }],
    [10n ** 18n, 10n ** 21n, 10n ** 24n, 10n ** 24n]),
  blockNumber: 4200n,
  blockHash: `0x${'b'.repeat(64)}`,
  transactionHash: `0x${'7'.repeat(64)}`,
  transactionIndex: 0,
  logIndex,
  removed: false,
})

// An unrelated ERC20 Transfer from some token contract, as receipts really mix them.
const transferLog = logIndex => ({
  address: '0x00000000000000000000000000000000000000aa',
  topics: [
    toEventSelector('Transfer(address,address,uint256)'),
    pad(ALICE, { size: 32 }),
    pad(BUYER, { size: 32 }),
  ],
  data: encodeAbiParameters([{ type: 'uint256' }], [5n]),
  blockNumber: 4200n,
  blockHash: `0x${'b'.repeat(64)}`,
  transactionHash: `0x${'7'.repeat(64)}`,
  transactionIndex: 0,
  logIndex,
  removed: false,
})

test('a normal buy reports its confirmed clock extension as +m:ss', () => {
  assert.equal(buyFxDetail([timeAddedLog(138n)]), '+2:18')
})

test('a concurrent buy capped the clock: the chip reports the confirmed seconds (20), not the pre-sign estimate', () => {
  assert.equal(buyFxDetail([timeAddedLog(20n)]), '+0:20')
})

test('zero seconds (clock already at cap) reports no chip', () => {
  assert.equal(buyFxDetail([timeAddedLog(0n)]), undefined)
})

test('a receipt without TimeAdded reports no chip', () => {
  assert.equal(buyFxDetail([]), undefined)
  assert.equal(buyFxDetail([buyLog(0), transferLog(1)]), undefined)
})

test('minutes past the hour stay in m:ss form', () => {
  assert.equal(buyFxDetail([timeAddedLog(4500n)]), '+75:00')
})

test('an unrelated ERC20 Transfer logged before TimeAdded is ignored', () => {
  assert.equal(buyFxDetail([transferLog(0), timeAddedLog(138n, BUYER, 1)]), '+2:18')
})

test('only the first TimeAdded counts and malformed logs never throw', () => {
  const second = timeAddedLog(20n, BUYER, 2)
  assert.equal(buyFxDetail([timeAddedLog(138n, BUYER, 0), second]), '+2:18')
  // A log without topics is undecodable; the rest of the receipt still decodes.
  assert.equal(buyFxDetail([{ address: HOOK, data: '0x', topics: [] }, timeAddedLog(138n, BUYER, 1)]), '+2:18')
  // A TimeAdded-shaped topic with garbage data reports no chip, never a guess.
  const malformed = { ...timeAddedLog(138n), data: '0xdeadbeef' }
  assert.equal(buyFxDetail([malformed]), undefined)
  assert.equal(buyFxDetail(undefined), undefined)
})
