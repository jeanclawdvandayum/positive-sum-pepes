import test from 'node:test'
import assert from 'node:assert/strict'
import { encodeAbiParameters, encodeEventTopics, pad, toEventSelector, zeroAddress } from 'viem'
import { stakerAbi } from '../src/lib/abi.ts'
import { hatchFxPepeId } from '../src/lib/hatchFxPepe.ts'

// Real-shaped receipt logs for a predeposit claim: the PSP ERC-20 moves, then
// the staker mints the position NFT.
const STAKER = '0x0000000000000000000000000000000000005ea4'
const TOKEN = '0x00000000000000000000000000000000000000aa'
const USER = '0x00000000000000000000000000000000000000ab'
const OTHER = '0x00000000000000000000000000000000000000a1'
const meta = logIndex => ({
  blockNumber: 4200n,
  blockHash: `0x${'b'.repeat(64)}`,
  transactionHash: `0x${'7'.repeat(64)}`,
  transactionIndex: 0,
  logIndex,
  removed: false,
})

const mintLog = (tokenId, to = USER, logIndex = 1) => ({
  address: STAKER,
  topics: encodeEventTopics({ abi: stakerAbi, eventName: 'Transfer', args: { from: zeroAddress, to, tokenId } }),
  data: '0x',
  ...meta(logIndex),
})

// ERC-20 Transfer(from, to, value): same selector, only two indexed topics.
const erc20Mint = logIndex => ({
  address: TOKEN,
  topics: [toEventSelector('Transfer(address,address,uint256)'), pad(zeroAddress, { size: 32 }), pad(USER, { size: 32 })],
  data: encodeAbiParameters([{ type: 'uint256' }], [10n ** 21n]),
  ...meta(logIndex),
})

test('a chosen claim hatches the id it was called with', () => {
  assert.equal(hatchFxPepeId('claimPredepositPSPWithPepe', [4242n], [], USER), 4242n)
})

test('a plain claim hatches the reserved id minted to the claimant, past an ERC-20 transfer', () => {
  assert.equal(hatchFxPepeId('claimPredepositPSP', undefined, [erc20Mint(0), mintLog(918273645n)], USER), 918273645n)
})

test('an automatic claim (address-id, genesis art) has no id-derived art', () => {
  assert.equal(hatchFxPepeId('claimPredepositPSP', undefined, [mintLog(BigInt(USER))], USER), undefined)
})

test('mints to someone else, other functions and undecodable receipts reveal nothing', () => {
  assert.equal(hatchFxPepeId('claimPredepositPSP', undefined, [mintLog(77n, OTHER)], USER), undefined)
  assert.equal(hatchFxPepeId('claimPredepositPSP', undefined, [{ address: STAKER, data: '0x', topics: [] }], USER), undefined)
  assert.equal(hatchFxPepeId('claimPredepositPSP', undefined, undefined, USER), undefined)
  assert.equal(hatchFxPepeId('lockWithPepe', [1n, 5n], [mintLog(5n)], USER), undefined)
})
