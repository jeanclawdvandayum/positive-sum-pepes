import test from 'node:test'
import assert from 'node:assert/strict'
import { addressPepeDna, createWalletPepeReader, walletPepeKey } from '../src/lib/walletPepe.ts'
import { fmtPepeId } from '../src/lib/format.ts'

const address = '0x00000000000000000000000000000000000000ab'
const other = '0x00000000000000000000000000000000000000cd'
const staker = '0x0000000000000000000000000000000000000001'
const descriptor = '0x0000000000000000000000000000000000000002'
const svg = '<svg viewBox="0 0 69 69"><rect width="69" height="69" /></svg>'

function fixture() {
  const state = { id: 7n, owner: address, dna: 42n, descriptor, artCalls: 0, offline: false }
  const read = createWalletPepeReader(async (_to, _abi, name) => {
    if (name === 'primaryOf') return state.id
    if (name === 'ownerOf') return state.owner
    if (name === 'dnaOf') return state.dna
    if (name === 'descriptor') return state.descriptor
    if (name === 'renderSVG') {
      state.artCalls++
      if (state.offline) throw Error('RPC unavailable')
      return svg
    }
    throw Error(`unexpected call ${name}`)
  })
  return { state, read }
}

test('address DNA is stable across casing/reloads and differs for different wallets', () => {
  const upper = `0x${address.slice(2).toUpperCase()}`
  assert.equal(addressPepeDna(address), addressPepeDna(upper))
  assert.notEqual(addressPepeDna(address), addressPepeDna(other))
  assert.equal(walletPepeKey(address, staker), walletPepeKey(upper, staker))
  assert.notEqual(walletPepeKey(address, staker), walletPepeKey(other, staker))
  assert.notEqual(walletPepeKey(address, staker), walletPepeKey(address, descriptor))
})

test('legacy address placeholders retain their full-width and padded-address golden vectors', () => {
  for (const [wallet, dna] of [
    ['0x0000000000000000000000000000000000000001', 'b10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6'],
    [address, 'fc377260a69a39dd786235c89f4bcd5d9639157731cac38071a0508750eb115a'],
    ['0xffffffffffffffffffffffffffffffffffffffff', 'd4e438d33b9d837cd8ac2c60c0ab93462b774f17bb358eb7e74d97f49064fd72'],
  ]) assert.equal(addressPepeDna(wallet), BigInt(`0x${dna}`))
})

test('an unminted wallet uses the collision-aware preview, then its immutable minted DNA', async () => {
  let minted = false, preview = 0n
  const read = createWalletPepeReader(async (_to, _abi, name) => {
    if (name === 'primaryOf') return minted ? BigInt(address) : 0n
    if (name === 'genesisPepeDna') return preview
    if (name === 'ownerOf') return address
    if (name === 'dnaOf') return 0n
    if (name === 'descriptor') return '0x0000000000000000000000000000000000000000'
    throw Error(name)
  })
  assert.deepEqual(await read(address, staker), { dna: 0n })
  minted = true; preview = 123n
  assert.deepEqual(await read(address, staker), { tokenId: BigInt(address), dna: 0n })
})

test('the same unminted wallet uses each round’s own seeded preview', async () => {
  const nextStaker = '0x0000000000000000000000000000000000000003'
  const read = createWalletPepeReader(async (to, _abi, name) => {
    if (name === 'primaryOf') return 0n
    if (name === 'genesisPepeDna') return to === staker ? 42n : 123n
    throw Error(name)
  })
  assert.deepEqual(await read(address, staker), { dna: 42n })
  assert.deepEqual(await read(address, nextStaker), { dna: 123n })
  assert.deepEqual(await read(address, staker), { dna: 42n })
})

test('large address-derived NFT IDs fit labels without changing bigint identity', () => {
  assert.equal(fmtPepeId(1n), '1')
  assert.equal(fmtPepeId(123456789012n), '123456789012')
  const id = BigInt('0xffffffffffffffffffffffffffffffffffffffff')
  assert.equal(fmtPepeId(id), '146150…2975')
  assert.equal(id.toString(), '1461501637330902918203684832716283019655932542975')
})

test('primary NFT art replaces fallback, including zero-DNA NFTs, without re-fetching cached art', async () => {
  const { state, read } = fixture()
  state.dna = 0n
  assert.deepEqual(await read(address, staker), { tokenId: 7n, dna: 0n, svg })
  assert.deepEqual(await read(address, staker), { tokenId: 7n, dna: 0n, svg })
  assert.equal(state.artCalls, 1)
})

test('no-NFT state is not cached: minting and transfers change the next read', async () => {
  const { state, read } = fixture()
  state.id = 0n
  assert.deepEqual(await read(address, staker), { dna: addressPepeDna(address) })
  state.id = 7n
  assert.equal((await read(address, staker)).tokenId, 7n)
  state.owner = other
  assert.deepEqual(await read(address, staker), { dna: addressPepeDna(address) })
  assert.equal((await read(other, staker)).tokenId, 7n)
  state.id = 0n
  assert.deepEqual(await read(other, staker), { dna: addressPepeDna(other) })
})

test('failed renderer falls back to the owned DNA and retries successfully', async () => {
  const { state, read } = fixture()
  state.offline = true
  assert.deepEqual(await read(address, staker), { tokenId: 7n, dna: 42n })
  state.offline = false
  assert.deepEqual(await read(address, staker), { tokenId: 7n, dna: 42n, svg })
  assert.equal(state.artCalls, 2)
})

test('art cache separates stakers and renderer changes', async () => {
  const { state, read } = fixture()
  await read(address, staker)
  await read(address, other)
  state.descriptor = other
  await read(address, other)
  assert.equal(state.artCalls, 3)
})

test('missing staker needs no RPC and ownership lookup failures remain retryable', async () => {
  let failed = true
  const read = createWalletPepeReader(async (_to, _abi, name) => {
    if (failed) throw Error('connection failed')
    if (name === 'genesisPepeDna') throw Error('legacy selector unavailable')
    return 0n
  })
  assert.deepEqual(await read(address), { dna: addressPepeDna(address) })
  await assert.rejects(read(address, staker), /connection failed/)
  failed = false
  assert.deepEqual(await read(address, staker), { dna: addressPepeDna(address) })
})
