import test from 'node:test'
import assert from 'node:assert/strict'
import { encodeAbiParameters, encodeEventTopics, pad, toEventSelector } from 'viem'
import { hookAbi } from '../src/lib/abi.ts'
import { potClaimDetail } from '../src/lib/potClaimDetail.ts'
import { bragText, bragUrl, VICTORY_MESSAGES, victoryCards } from '../src/lib/victoryCards.ts'

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

test('the community-supplied victory message is in the rotation verbatim', () => {
  assert.ok(VICTORY_MESSAGES.includes(
    "OMG!😭Can't believe I won ! Thank you Positive Sum Pepes team ! ❤️ keep doing the great work. 💪🏻💪🏻💪🏻🚀🚀🚀",
  ))
})

test('brag text leads with the message and carries amount + round within X’s limit', () => {
  const card = victoryCards.push({ roundId: 3n, roundName: 'the fx lab round', amountMix: PAYOUT, message: VICTORY_MESSAGES[0] })
  const text = bragText(card)
  assert.ok(text.startsWith(VICTORY_MESSAGES[0]))
  assert.ok(text.includes('12.34 mixETH'))
  assert.ok(text.includes('round 3 pot'))
  assert.ok(text.length <= 280)
  const url = bragUrl(card)
  assert.ok(url.startsWith('https://twitter.com/intent/tweet?text='))
  assert.ok(url.includes(encodeURIComponent('12.34 mixETH from the round 3 pot')))
  victoryCards.dismiss(card.id)
})

test('when the pair would overflow, the victory-info sentence yields before the message', () => {
  const longMessage = 'x'.repeat(270)
  const card = victoryCards.push({ roundId: 12n, amountMix: 1n, message: longMessage })
  assert.equal(bragText(card), longMessage)
  victoryCards.dismiss(card.id)
})

test('the store is inert without a subscriber and live with one', () => {
  // Nothing subscribes in this file: the pushes above must not have accumulated.
  assert.equal(victoryCards.active, false)
  assert.deepEqual(victoryCards.snapshot(), [])
  victoryCards.push({ roundId: 1n, amountMix: 2n, message: VICTORY_MESSAGES[1] })
  assert.deepEqual(victoryCards.snapshot(), [])
  const seen = []
  const off = victoryCards.subscribe(() => {})
  const off2 = victoryCards.subscribe(() => { seen.push(victoryCards.snapshot().length) })
  assert.equal(victoryCards.active, true)
  const live = victoryCards.push({ roundId: 1n, amountMix: 2n, message: VICTORY_MESSAGES[2] })
  assert.equal(victoryCards.snapshot().length, 1)
  assert.deepEqual(seen, [1])
  victoryCards.dismiss(live.id)
  assert.deepEqual(victoryCards.snapshot(), [])
  off()
  off2()
  assert.equal(victoryCards.active, false)
})
