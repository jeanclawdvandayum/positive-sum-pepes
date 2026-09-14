import test from 'node:test'
import assert from 'node:assert/strict'
import { decodeFunctionData, encodeFunctionData } from 'viem'
import { registryAbi } from '../src/lib/abi.ts'
import { referralRewardsVersion, verifyReferralClaim } from '../src/lib/referralRewards.ts'

const registry = '0x1111111111111111111111111111111111111111'
const other = '0x2222222222222222222222222222222222222222'
const claim = { address: registry, functionName: 'claimReferralRewards' }

test('legacy selector absence hides the new rewards path, while connection errors remain errors', async () => {
  assert.equal(await referralRewardsVersion(async () => 1n), 1n)
  assert.equal(await referralRewardsVersion(async () => { throw new Error('execution reverted') }), 0n)
  assert.equal(await referralRewardsVersion(async () => { throw new Error('returned no result') }), 0n)
  await assert.rejects(referralRewardsVersion(async () => { throw new Error('RPC rate limit') }), /RPC rate limit/)
  await assert.rejects(referralRewardsVersion(async () => { throw new Error('Failed to fetch') }), /Failed to fetch/)
})

test('claims verify the selected historic registry without consulting the latest round or NFT balance', async () => {
  const calls = []
  await verifyReferralClaim({
    registry: async id => { calls.push(['round', id]); return registry },
    version: async address => { calls.push(['version', address]); return 1n },
  }, 1n, claim)
  assert.deepEqual(calls, [['round', 1n], ['version', registry]])
})

test('claim exception rejects wrong round targets, unrelated actions, recipients and native ETH', async () => {
  const reads = { registry: async () => registry, version: async () => 1n }
  for (const action of [
    { ...claim, address: other },
    { ...claim, functionName: 'buyWithMix' },
    { ...claim, functionName: 'approve', args: [other, 100n] },
    { ...claim, args: [other] },
    { ...claim, value: 1n },
  ]) await assert.rejects(verifyReferralClaim(reads, 1n, action), /selected round/)
  for (const id of [undefined, 0n, -1n]) await assert.rejects(verifyReferralClaim(reads, id, claim), /selected round/)
  await assert.rejects(verifyReferralClaim({ ...reads, registry: async () => '0x' + '0'.repeat(40) }, 1n, claim), /selected round/)
})

test('claim preflight fails closed on legacy, future-version and unreadable registries', async () => {
  for (const version of [0n, 2n]) {
    await assert.rejects(verifyReferralClaim({ registry: async () => registry, version: async () => version }, 1n, claim), /different referral payout/)
  }
  await assert.rejects(verifyReferralClaim({ registry: async () => registry, version: async () => { throw new Error('RPC offline') } }, 1n, claim), /RPC offline/)
})

test('referral claim calldata contains no arbitrary payout recipient', () => {
  const data = encodeFunctionData({ abi: registryAbi, functionName: 'claimReferralRewards' })
  const decoded = decodeFunctionData({ abi: registryAbi, data })
  assert.equal(decoded.functionName, 'claimReferralRewards')
  assert.equal(decoded.args, undefined)
  assert.equal(data.length, 10)
})
