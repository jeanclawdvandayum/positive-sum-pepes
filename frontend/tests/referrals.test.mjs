import test from 'node:test'
import assert from 'node:assert/strict'
import { encodeFunctionData, decodeFunctionData } from 'viem'
import { registryAbi, buildPoolKey } from '../src/lib/abi.ts'
import { parseReferral, referralParams, referralKey, matchingReferral, savedReferral, purchaseReferral, assertReferralPurchase } from '../src/lib/referrals.ts'
const registry = '0x1111111111111111111111111111111111111111'
const nextRegistry = '0x2222222222222222222222222222222222222222'
const hook = '0x3333333333333333333333333333333333333333'
const chain = 84532
const hint = parseReferral(new URLSearchParams(referralParams(7n, chain, registry)))

test('generated link round-trips with chain and round registry scope', () => {
  assert.deepEqual(hint, { nftId: '7', chainId: chain, registry })
  assert.equal(matchingReferral(hint, chain, registry), 7n)
})
test('old rounds and other chains cannot reuse an NFT id as a referral', () => {
  assert.equal(matchingReferral(hint, chain, nextRegistry), 0n)
  assert.equal(matchingReferral(hint, 1, registry), 0n)
  assert.equal(matchingReferral(hint, chain, undefined), 0n)
  assert.notEqual(referralKey(chain, registry), referralKey(chain, nextRegistry))
  assert.notEqual(referralKey(chain, registry), referralKey(1, registry))
})
test('legacy id-only links and unscoped persisted values are rejected', () => {
  assert.equal(parseReferral(new URLSearchParams('ref=7')), null)
  assert.equal(savedReferral('7'), null)
})
test('a scoped hint survives reload without becoming on-chain attribution', () => {
  assert.deepEqual(savedReferral(JSON.stringify(hint)), hint)
  assert.equal(purchaseReferral(7n, false), 7n)
  assert.equal(purchaseReferral(7n, true), 0n)
})
test('malformed and overflowing parameters never reach a transaction', () => {
  for (const id of ['0', '-1', '1.2', 'abc', '0x7', (1n << 256n).toString(), '1'.repeat(10000)]) {
    assert.equal(parseReferral(new URLSearchParams({ ref: id, refRegistry: registry, refChain: String(chain) })), null)
  }
  for (const addr of ['0x0', '0x' + '0'.repeat(40), 'bad', registry + 'f']) {
    assert.equal(parseReferral(new URLSearchParams({ ref: '7', refRegistry: addr, refChain: String(chain) })), null)
  }
  assert.equal(savedReferral('{broken'), null)
})
test('uint256 maximum is accepted and case-normalized registry keys match', () => {
  const upper = '0xABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD'
  const id = (1n << 256n) - 1n
  const parsed = parseReferral(new URLSearchParams(referralParams(id, chain, upper)))
  assert.equal(matchingReferral(parsed, chain, upper.toLowerCase()), id)
  assert.equal(referralKey(chain, upper), referralKey(chain, upper.toLowerCase()))
})
test('recorded attribution always wins over an incoming link', () => {
  for (const id of [0n, 1n, 7n, (1n << 256n) - 1n]) assert.equal(purchaseReferral(id, true), 0n)
})
test('an unresolved wallet referral never silently drops the incoming hint', () => {
  assert.throws(() => purchaseReferral(7n, undefined), /Checking your round referral/)
  assert.equal(purchaseReferral(0n, false), 0n)
})
test('purchase and approval preflight rejects legacy or stale round targets', () => {
  const expected = { registry, hook, version: 1n }
  assertReferralPurchase(expected, registry, hook)
  assert.throws(() => assertReferralPurchase({ ...expected, version: 0n }, registry, hook))
  assert.throws(() => assertReferralPurchase(expected, nextRegistry, hook))
  assert.throws(() => assertReferralPurchase(expected, registry, nextRegistry))
})
test('buy calldata contains the referral alongside price protection; no trader override exists', () => {
  const key = buildPoolKey(registry, nextRegistry, hook)
  const args = [key, 5000000000000000n, 123n, 2000000000n, 7n]
  const data = encodeFunctionData({ abi: registryAbi, functionName: 'buyWithMix', args })
  const decoded = decodeFunctionData({ abi: registryAbi, data })
  assert.equal(decoded.functionName, 'buyWithMix')
  assert.deepEqual(decoded.args, args)
  assert.equal(decoded.args.length, 5)
})
