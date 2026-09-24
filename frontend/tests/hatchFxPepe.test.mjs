import test from 'node:test'
import assert from 'node:assert/strict'
import { encodeAbiParameters, encodeEventTopics, pad, toEventSelector, zeroAddress } from 'viem'
import { stakerAbi } from '../src/lib/abi.ts'
import { hatchFxPepeId } from '../src/lib/hatchFxPepe.ts'

// Real-shaped receipt logs for a predeposit claim: the PSP ERC-20 moves, then
// the staker mints the position NFT.
const STAKER = '0x0000000000000000000000000000000000005ea4'
const IMPOSTOR = '0x0000000000000000000000000000000000000bad'
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

const mintLog = (tokenId, { to = USER, address = STAKER, logIndex = 1 } = {}) => ({
  address,
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

const plain = logs => hatchFxPepeId('claimPredepositPSP', undefined, logs, USER, STAKER)

test('a chosen claim reveals the id the staker minted, which must equal its argument', () => {
  assert.equal(hatchFxPepeId('claimPredepositPSPWithPepe', [4242n], [erc20Mint(0), mintLog(4242n)], USER, STAKER), 4242n)
  assert.equal(hatchFxPepeId('claimPredepositPSPWithPepe', [4242n], [mintLog(4243n)], USER, STAKER), undefined)
  assert.equal(hatchFxPepeId('claimPredepositPSPWithPepe', [4242n], [], USER, STAKER), undefined)
})

test('an automatic claim reveals the wallet-address id it minted', () => {
  assert.equal(plain([erc20Mint(0), mintLog(BigInt(USER))]), BigInt(USER))
})

test('an automatic claim whose address id collided reveals the fallback nextTokenId', () => {
  assert.equal(plain([mintLog(7n)]), 7n)
})

test('only the expected staker, a mint to the claimant, and claim functions count', () => {
  assert.equal(plain([mintLog(77n, { address: IMPOSTOR })]), undefined)
  assert.equal(plain([mintLog(77n, { address: IMPOSTOR, logIndex: 0 }), mintLog(78n)]), 78n)
  assert.equal(plain([mintLog(77n, { to: OTHER })]), undefined)
  assert.equal(plain([{ address: STAKER, data: '0x', topics: [] }]), undefined)
  assert.equal(plain(undefined), undefined)
  assert.equal(hatchFxPepeId('lockWithPepe', [1n, 5n], [mintLog(5n)], USER, STAKER), undefined)
})
