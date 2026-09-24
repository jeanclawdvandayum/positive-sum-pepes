import test from 'node:test'
import assert from 'node:assert/strict'
import { encodeAbiParameters, encodeEventTopics, pad, toEventSelector } from 'viem'
import { hookAbi } from '../src/lib/abi.ts'
import { potClaimDetail } from '../src/lib/potClaimDetail.ts'

// Real-shaped receipt logs, built the way a chain assembles them: topics from
// the event signature, indexed args padded into topics, the rest abi-encoded
// into data. (Same construction as buyFxDetail.test.mjs.)
const HOOK = '0x0000000000000000000000000000000000000abc'
const ME = '0x00000000000000000000000000000000000000ab'
const ALICE = '0x00000000000000000000000000000000000000a1'
const PAYOUT = 1234n * 10n ** 16n // 12.34 mixETH

const potClaimedLog = (amount, who = ME, logIndex = 0) => ({
  address: HOOK,
  topics: encodeEventTopics({ abi: hookAbi, eventName: 'PotClaimed', args: { who } }),
  data: encodeAbiParameters([{ type: 'uint256' }], [BigInt(amount)]),
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
    pad(ME, { size: 32 }),
  ],
  data: encodeAbiParameters([{ type: 'uint256' }], [5n]),
  blockNumber: 4200n,
  blockHash: `0x${'b'.repeat(64)}`,
  transactionHash: `0x${'7'.repeat(64)}`,
  transactionIndex: 0,
  logIndex,
  removed: false,
})

test('a confirmed claimPot reports the receipt’s PotClaimed payout for the claimant', () => {
  assert.equal(potClaimDetail('claimPot', [potClaimedLog(PAYOUT)], ME), PAYOUT)
})

test('the claimant match is case-insensitive', () => {
  assert.equal(potClaimDetail('claimPot', [potClaimedLog(PAYOUT)], ME.toUpperCase()), PAYOUT)
})

test('someone else’s claim in the same receipt is ignored', () => {
  assert.equal(potClaimDetail('claimPot', [potClaimedLog(PAYOUT, ALICE)], ME), undefined)
})

test('a receipt without PotClaimed reports no payout', () => {
  assert.equal(potClaimDetail('claimPot', [], ME), undefined)
  assert.equal(potClaimDetail('claimPot', undefined, ME), undefined)
})

test('an unrelated ERC20 Transfer logged before PotClaimed is ignored', () => {
  assert.equal(potClaimDetail('claimPot', [transferLog(0), potClaimedLog(PAYOUT, ME, 1)], ME), PAYOUT)
})

test('non-claimPot writes never report a payout', () => {
  assert.equal(potClaimDetail('buyWithMix', [potClaimedLog(PAYOUT)], ME), undefined)
  assert.equal(potClaimDetail('claimPot', [potClaimedLog(PAYOUT)], undefined), undefined)
})

test('malformed logs never throw', () => {
  // A log without topics is undecodable; the rest of the receipt still decodes.
  assert.equal(potClaimDetail('claimPot', [{ address: HOOK, data: '0x', topics: [] }, potClaimedLog(PAYOUT, ME, 1)], ME), PAYOUT)
  // A PotClaimed-shaped topic with garbage data reports nothing, never a guess.
  assert.equal(potClaimDetail('claimPot', [{ ...potClaimedLog(PAYOUT), data: '0xdeadbeef' }], ME), undefined)
})
