import test from 'node:test'
import assert from 'node:assert/strict'
import { addressPepeDna, createWalletPepeReader, walletPepeKey } from '../src/lib/walletPepe.ts'

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
  const read = createWalletPepeReader(async () => {
    if (failed) throw Error('connection failed')
    return 0n
  })
  assert.deepEqual(await read(address), { dna: addressPepeDna(address) })
  await assert.rejects(read(address, staker), /connection failed/)
  failed = false
  assert.deepEqual(await read(address, staker), { dna: addressPepeDna(address) })
})
