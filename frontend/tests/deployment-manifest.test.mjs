import test from 'node:test'
import assert from 'node:assert/strict'
import { BASE_SEPOLIA_ID, releaseContext, assertRuntimeMatches, verifyFactoryCreation, assertTimingProfile, renderFrontendEnv } from '../scripts/deployment-manifest-lib.mjs'

const address = digit => `0x${digit.repeat(40)}`
const factory = address('1')
const context = { rpcUrl: 'https://provider.example/private-key', chainId: BASE_SEPOLIA_ID, clientVersion: '', rehearsalRequested: false, sourceDirty: false }

test('dirty-source bypass is limited to an explicitly labeled local Base Sepolia Anvil rehearsal', () => {
  assert.deepEqual(releaseContext(context), { rehearsal: false, sourceDirty: false })
  assert.throws(() => releaseContext({ ...context, sourceDirty: true }), /clean source/)
  const rehearsal = { ...context, rpcUrl: 'http://127.0.0.1:18545', clientVersion: 'anvil/v1.3.1', rehearsalRequested: true, sourceDirty: true }
  assert.deepEqual(releaseContext(rehearsal), { rehearsal: true, sourceDirty: true, rehearsalRpc: 'http://127.0.0.1:18545' })
  for (const change of [
    { rpcUrl: 'https://sepolia.base.org' }, { rpcUrl: 'http://127.0.0.1.example/secret' },
    { rpcUrl: 'http://user:secret@127.0.0.1:18545' }, { rpcUrl: 'http://127.0.0.1:18545/key' },
    { rpcUrl: 'http://127.0.0.1:18545/?key=secret' }, { clientVersion: 'reth/v1.3.1' }, { chainId: 8453 },
  ]) assert.throws(() => releaseContext({ ...rehearsal, ...change }))
})

test('runtime matching allows constructor immutables while rejecting changed executable code and bad ranges', () => {
  const artifact = { deployedBytecode: { object: '0x600000005500', immutableReferences: { seed: [{ start: 1, length: 3 }] } } }
  assert.doesNotThrow(() => assertRuntimeMatches('0x60abcdef5500', artifact, 'staker'))
  assert.throws(() => assertRuntimeMatches('0x60abcdef5600', artifact, 'staker'), /Runtime differs/)
  assert.throws(() => assertRuntimeMatches('0x60abcdef550000', artifact, 'staker'), /Runtime differs/)
  assert.throws(() => assertRuntimeMatches('0x', artifact, 'staker'), /Missing/)
  const invalid = { deployedBytecode: { ...artifact.deployedBytecode, immutableReferences: { seed: [{ start: 1, length: 99 }] } } }
  assert.throws(() => assertRuntimeMatches('0x60abcdef5500', invalid, 'staker'), /Invalid immutable/)
})

test('factory history starts at a successful canonical CREATE receipt for that factory', () => {
  const receipt = { status: 'success', contractAddress: factory, transactionHash: `0x${'a'.repeat(64)}`, blockNumber: 100n, blockHash: `0x${'b'.repeat(64)}` }
  const input = { factory, receipt, canonicalBlockHash: receipt.blockHash, snapshotBlock: 120n }
  assert.deepEqual(verifyFactoryCreation(input), { transactionHash: receipt.transactionHash, block: 100n, blockHash: receipt.blockHash })
  for (const altered of [
    { ...receipt, status: 'reverted' }, { ...receipt, contractAddress: address('2') },
    { ...receipt, contractAddress: null }, { ...receipt, blockHash: `0x${'c'.repeat(64)}` }, { ...receipt, blockNumber: 121n },
  ]) assert.throws(() => verifyFactoryCreation({ ...input, receipt: altered }), /Factory creation receipt/)
})

test('timing inspection pins detonation and wallet cap to their separate 64-bit fields', () => {
  const custom = {
    packed: 900n | (3600n << 64n) | (7200n << 128n) | (500n << 192n),
    PREDEPOSIT_DURATION: 900n, VEST_DURATION: 3600n, detWindow: 7200n,
    PREDEPOSIT_CAP_PER_WALLET: 500n * 10n ** 18n, PREDEPOSIT_CAP: 1000n * 10n ** 18n, epochSize: 600n,
  }
  assert.doesNotThrow(() => assertTimingProfile(custom))
  assert.throws(() => assertTimingProfile({ ...custom, detWindow: 500n }), /four-field/)
  assert.throws(() => assertTimingProfile({ ...custom, PREDEPOSIT_CAP_PER_WALLET: 7200n * 10n ** 18n }), /four-field/)
  assert.doesNotThrow(() => assertTimingProfile({ ...custom, packed: 0n, PREDEPOSIT_DURATION: 604800n, VEST_DURATION: 3628800n, detWindow: 259200n, PREDEPOSIT_CAP_PER_WALLET: 0n, epochSize: 604800n }))
})

const manifest = () => ({
  chainId: BASE_SEPOLIA_ID, rehearsal: false, revision: 'a'.repeat(40), block: 125n,
  deployment: { block: 100n },
  addresses: Object.fromEntries(['factory', 'mix', 'zapIn', 'zapOut', 'faucet', 'reinvestor'].map((name, i) => [name, address(String(i + 1))])),
})

test('frontend export uses public RPCs and confirmed creation block, leaving naming disabled for its separate release', () => {
  const env = renderFrontendEnv(manifest())
  assert.match(env, /^VITE_RPC_URL=https:\/\/sepolia\.base\.org$/m)
  assert.match(env, /^VITE_RPC_FALLBACK_URL=https:\/\/base-sepolia-rpc\.publicnode\.com$/m)
  assert.match(env, /^VITE_DEPLOYMENT_BLOCK=100$/m)
  assert.doesNotMatch(env, /^VITE_DEPLOYMENT_BLOCK=125$/m)
  assert.match(env, /^VITE_NAME_REGISTRAR=$/m)
  for (const name of ['factory', 'mix', 'zapIn', 'zapOut', 'faucet', 'reinvestor']) {
    const incomplete = manifest()
    delete incomplete.addresses[name]
    assert.throws(() => renderFrontendEnv(incomplete), /verified .* address/)
  }
  assert.throws(() => renderFrontendEnv({ ...manifest(), deployment: undefined }), /creation receipt/)
  assert.throws(() => renderFrontendEnv({ ...manifest(), chainId: 8453 }), /Base Sepolia/)
})

test('rehearsal frontend reads stay local and cannot fall back to the real testnet', () => {
  const local = { ...manifest(), rehearsal: true }
  assert.throws(() => renderFrontendEnv(local), /loopback RPC/)
  const env = renderFrontendEnv(local, 'http://127.0.0.1:18545')
  assert.match(env, /LOCAL REHEARSAL ONLY/)
  assert.match(env, /^VITE_RPC_URL=http:\/\/127\.0\.0\.1:18545$/m)
  assert.match(env, /^VITE_RPC_FALLBACK_URL=$/m)
  assert.doesNotMatch(env, /sepolia\.base|publicnode/)
})
