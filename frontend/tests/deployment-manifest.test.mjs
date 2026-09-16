import test from 'node:test'
import { keccak256 } from 'viem'
import assert from 'node:assert/strict'
import { BASE_SEPOLIA_ID, releaseContext, assertRuntimeMatches, verifyFactoryCreation, assertTimingProfile, renderFrontendEnv, discoverRegistryInitCode, readSineDeploymentState, assertSineDataMatches } from '../scripts/deployment-manifest-lib.mjs'

const address = digit => `0x${digit.repeat(40)}`
const factory = address('1')
const context = { rpcUrl: 'https://provider.example/private-key', chainId: BASE_SEPOLIA_ID, clientVersion: '', rehearsalRequested: false, sourceDirty: false }

const oracleArtifact = { abi: [{ type: 'function', name: 'registryInitOracle', inputs: [], outputs: [{ type: 'address' }] }] }

function sineReader(changes = {}) {
  const values = { SINE_RULES_VERSION: 3n, TICKET_RULES_VERSION: 3n, MIN_BUY_INPUT: 5_000_000_000_000_000n,
    TIME_PER_UNIT: 69n, ticketPrice: 5_000_000_000_000_000n, potBalance: 50n * 10n ** 18n,
    sineV3Info: [3n, 75_000_000_000_000n, 450n * 10n ** 18n, 955n * 10n ** 18n, 10_000n * 10n ** 18n, 10n ** 25n, address('7')],
    sineV3Table: address('7'), sineConfigured: true, sineActive: true, gameSinePL: 75_000_000_000_000n,
    dataShardCount: 4n, dataShard: [address('a'),address('b'),address('c'),address('d')],
    lamAt: 955n * 10n ** 18n, genesisQ: 10n ** 25n, ...changes }
  const calls = []
  const read = async (target, abi, name, args) => {
    calls.push({ target, name, args })
    assert.equal(abi[0].name, name)
    if (!(name in values)) throw Error(`Unexpected getter: ${name}`)
    if (values[name] instanceof Error) throw values[name]
    return name === 'dataShard' ? values[name][Number(args[0])] : values[name]
  }
  return { read, calls, values }
}

test('v3 manifest reads the versioned curve, pins its helper and checks materialization', async () => {
  const { read, calls } = sineReader()
  const result = await readSineDeploymentState(read, factory, address('2'))
  assert.equal(result.curve.helper, address('7'))
  assert.equal(result.curve.target, 10_000n * 10n ** 18n)
  assert.equal(result.params.launchPrice, 75_000_000_000_000n)
  assert.equal(result.ticketPrice, result.minimumBuy)
  assert.deepEqual(calls.slice(0, 2).map(call => call.name), ['SINE_RULES_VERSION', 'TICKET_RULES_VERSION'])
  assert.equal(calls.some(call => call.name === 'sineParams'), false)
  assert.deepEqual(calls.find(call => call.name === 'genesisQ').args,
    [450n * 10n ** 18n, 955n * 10n ** 18n, 75_000_000_000_000n])
})

test('unlaunched v3 manifest accepts the fixed 0.005 floor with no materialized curve', async () => {
  const { read, calls } = sineReader({ MIN_BUY_INPUT: 5_000_000_000_000_000n, ticketPrice: 5_000_000_000_000_000n,
    potBalance: 0n, sineActive: false,
    sineV3Info: [3n, 75_000_000_000_000n, 0n, 0n, 0n, 0n, address('7')] })
  const result = await readSineDeploymentState(read, factory, address('2'))
  assert.equal(result.minimumBuy, 5_000_000_000_000_000n)
  assert.equal(result.curve.active, false)
  assert.equal(calls.some(call => call.name === 'genesisQ'), false)
})

test('v3 manifest rejects stale minima, helper substitution and invalid materialized values', async () => {
  const base = sineReader().values
  const alteredTuple = (index, value) => ({ sineV3Info: base.sineV3Info.map((entry, i) => i === index ? value : entry) })
  for (const changes of [
    { MIN_BUY_INPUT: 1n }, { ticketPrice: 0n }, { potBalance: base.potBalance + 1n }, { TIME_PER_UNIT: 260n },
    { dataShardCount: 3n }, { dataShard: Array(4).fill(address('a')) },
    { dataShard: [address('a'),address('b'),address('c'),address('0')] },
    { sineV3Table: address('8') }, { sineConfigured: false }, { gameSinePL: 1n },
    alteredTuple(0, 2n), alteredTuple(2, 0n), alteredTuple(3, 1n), alteredTuple(4, 1n), alteredTuple(5, 1n),
  ]) await assert.rejects(readSineDeploymentState(sineReader(changes).read, factory, address('2')), /mismatch|clock rules/)
})

test('legacy manifest keeps the original parameter tuple and static minimum', async () => {
  const params = [1n, 2n, 3n, 4n, 10000]
  const { read, calls } = sineReader({ SINE_RULES_VERSION: 2n, TICKET_RULES_VERSION: 2n,
    sineParams: params, genesisPotBalance: 50n * 10n ** 18n })
  const result = await readSineDeploymentState(read, factory, address('2'))
  assert.deepEqual(result.params, params)
  assert.equal(result.curve, undefined)
  assert.equal(calls.some(call => call.name === 'sineV3Info' || call.name === 'sineV3Table'), false)
})

test('unknown versions and failed version reads never fall back to legacy curve decoding', async () => {
  for (const change of [{ SINE_RULES_VERSION: 4n }, { TICKET_RULES_VERSION: 2n }, { SINE_RULES_VERSION: Error('RPC unavailable') }]) {
    const { read, calls } = sineReader(change)
    await assert.rejects(readSineDeploymentState(read, factory, address('2')), /version|RPC unavailable/)
    assert.equal(calls.some(call => call.name === 'sineParams' || call.name === 'sineV3Info'), false)
  }
})

test('registry helper discovery requires the current getter and rejects failed or invalid reads', async () => {
  let reads = 0
  const discovered = await discoverRegistryInitCode({ artifact: oracleArtifact, readOracle: async () => { ++reads; return address('7') } })
  assert.equal(discovered, address('7'))
  assert.equal(reads, 1)
  await assert.rejects(discoverRegistryInitCode({ artifact: oracleArtifact, readOracle: async () => { throw Error('RPC unavailable') } }), /RPC unavailable/)
  for (const result of [undefined, '0x1234', address('0')]) {
    await assert.rejects(discoverRegistryInitCode({ artifact: oracleArtifact, readOracle: async () => result }), /Invalid registry/)
  }
})

test('legacy deployer artifacts omit the helper without an RPC probe', async () => {
  let reads = 0
  const result = await discoverRegistryInitCode({ artifact: { abi: [] }, readOracle: async () => { ++reads; throw Error('legacy getter absent') } })
  assert.equal(result, undefined)
  assert.equal(reads, 0)
  await assert.rejects(discoverRegistryInitCode({ artifact: {}, readOracle: async () => address('7') }), /Missing ControllerDeployer ABI/)
  const malformed = { abi: [{ ...oracleArtifact.abi[0], outputs: [{ type: 'bytes' }] }] }
  await assert.rejects(discoverRegistryInitCode({ artifact: malformed, readOracle: async () => address('7') }), /Unsupported registryInitOracle/)
})

test('registry helper executable code must match without immutable exclusions', () => {
  const artifact = { deployedBytecode: { object: '0x6000600055', immutableReferences: {} } }
  assert.doesNotThrow(() => assertRuntimeMatches('0x6000600055', artifact, 'registryInitCode'))
  assert.throws(() => assertRuntimeMatches('0x6001600055', artifact, 'registryInitCode'), /Runtime differs/)
  assert.throws(() => assertRuntimeMatches('0x', artifact, 'registryInitCode'), /Missing/)
})

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
    PREDEPOSIT_RULES_VERSION: 1n,
    packed: 900n | (3600n << 64n) | (7200n << 128n) | (500n << 192n),
    PREDEPOSIT_DURATION: 900n, VEST_DURATION: 3600n, detWindow: 7200n,
    PREDEPOSIT_CAP_PER_WALLET: 500n * 10n ** 18n, PREDEPOSIT_CAP: 1000n * 10n ** 18n, epochSize: 600n,
  }
  assert.doesNotThrow(() => assertTimingProfile(custom))
  assert.throws(() => assertTimingProfile({ ...custom, detWindow: 500n }), /four-field/)
  assert.throws(() => assertTimingProfile({ ...custom, PREDEPOSIT_CAP_PER_WALLET: 7200n * 10n ** 18n }), /four-field/)
  assert.doesNotThrow(() => assertTimingProfile({ ...custom, packed: 0n, PREDEPOSIT_DURATION: 604800n, VEST_DURATION: 3628800n, detWindow: 259200n, PREDEPOSIT_CAP_PER_WALLET: 0n, epochSize: 604800n }))
})

test('uncapped version two defaults and short playtest overrides are independently verified', () => {
  const current = {
    PREDEPOSIT_RULES_VERSION: 2n, packed: 0n,
    PREDEPOSIT_DURATION: 259200n, VEST_DURATION: 2419200n, detWindow: 248660n,
    PREDEPOSIT_CAP_PER_WALLET: 0n, PREDEPOSIT_CAP: 0n, epochSize: 403200n,
  }
  assert.doesNotThrow(() => assertTimingProfile(current))
  assert.doesNotThrow(() => assertTimingProfile({ ...current,
    packed: 60n | (3600n << 64n) | (90n << 128n),
    PREDEPOSIT_DURATION: 60n, VEST_DURATION: 3600n, detWindow: 90n, epochSize: 600n,
  }))
  for (const change of [{ PREDEPOSIT_RULES_VERSION: 3n }, { PREDEPOSIT_RULES_VERSION: undefined },
    { PREDEPOSIT_CAP: 1000n * 10n ** 18n }, { VEST_DURATION: 3628800n }, { detWindow: 15600n }]) {
    assert.throws(() => assertTimingProfile({ ...current, ...change }))
  }
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

test('sine data authentication checks the full STOP-prefixed runtime and exact length', () => {
  const code = '0x000102030405'
  const expected = { bytes: 6, hash: keccak256(code) }
  assertSineDataMatches(code, expected, 'shard')
  for (const altered of ['0x010102030405', '0x000102030406', '0x0001020304', '0x']) {
    assert.throws(() => assertSineDataMatches(altered, expected, 'shard'), /differs/)
  }
  assert.throws(() => assertSineDataMatches(code, {...expected, bytes: 24577}, 'shard'), /differs/)
})
