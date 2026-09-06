import { test } from 'node:test'
import assert from 'node:assert/strict'
import { decodeAbiParameters, parseAbiParameters } from 'viem'
import { assertNameFeeQuote, isNameLabel, normalizeNameLabel, nameCommitment, parseNamePlan, findNameEligibilityProof,
  readNameRegistration, NAME_REGISTRATION_FEE } from '../src/lib/nameRegistration.ts'
import { TEST_NAME_PARENT_ID, WNS_ADDRESS } from '../src/lib/weiNames.ts'

const account = '0x1111111111111111111111111111111111111111'
const factory = '0x2222222222222222222222222222222222222222'
const registrar = '0x3333333333333333333333333333333333333333'
const gate = '0x4444444444444444444444444444444444444444'
const ns = { chainId: 31337, parentId: TEST_NAME_PARENT_ID, names: WNS_ADDRESS, parentLabel: 'pepetesters', registrar }
const salt = `0x${'ab'.repeat(32)}`

test('losing eligibility cannot silently turn a reviewed free registration into a paid transaction', () => {
  assert.throws(() => assertNameFeeQuote(0n, NAME_REGISTRATION_FEE), /fee changed/)
  assert.throws(() => assertNameFeeQuote(undefined, NAME_REGISTRATION_FEE), /fee changed/)
  assert.doesNotThrow(() => assertNameFeeQuote(0n, 0n))
  assert.doesNotThrow(() => assertNameFeeQuote(NAME_REGISTRATION_FEE, NAME_REGISTRATION_FEE))
})

test('name plans persist exactly and reject malformed local-storage data', () => {
  const plan = { label: 'frog-69', salt }
  assert.deepEqual(parseNamePlan(JSON.stringify(plan)), plan)
  for (const p of [null, '{', '{}', JSON.stringify({ label: 'frog', salt: [salt] }), JSON.stringify({ label: 'f.r', salt }), JSON.stringify({ label: 'frog', salt: '0x12' })]) {
    assert.equal(parseNamePlan(p), undefined)
  }
})
test('label validation covers the contract boundaries', () => {
  for (const good of ['a', '0', 'a-b', 'a'.repeat(32)]) assert(isNameLabel(good))
  for (const bad of ['', 'A', 'a'.repeat(33), 'a b', 'a.b', '-a', 'a-', 'frög', '<a>']) assert(!isNameLabel(bad))
  assert.equal(normalizeNameLabel('FROG-69'), 'frog-69')
})
test('commitments bind the name, secret, wallet, network, parent and registrar', () => {
  const p = { label: 'frog', salt }
  const original = nameCommitment(ns, account, p)
  for (const other of [{ ...ns, chainId: 1 }, { ...ns, parentId: 1n }, { ...ns, registrar: factory }]) {
    assert.notEqual(nameCommitment(other, account, p), original)
  }
  assert.notEqual(nameCommitment(ns, factory, p), original)
  assert.notEqual(nameCommitment(ns, account, { ...p, label: 'frog2' }), original)
  assert.notEqual(nameCommitment(ns, account, { ...p, salt: `0x${'12'.repeat(32)}` }), original)
})

function reader(overrides = {}) {
  const calls = []
  const client = {
    getChainId: async () => overrides.chainId ?? ns.chainId,
    getBlock: async () => ({ number: 100n, timestamp: 200n }),
    readContract: async c => {
      calls.push(c)
      if (overrides.failAt === c.functionName) throw Error('RPC unavailable')
      if (c.functionName in overrides) return overrides[c.functionName]
      const defaults = {
        REGISTRAR_VERSION: 2n, REGISTRATION_FEE: NAME_REGISTRATION_FEE, MIN_COMMIT_AGE: 60n,
        MAX_COMMIT_AGE: 86400n, names: ns.names, parentId: ns.parentId, registrationEnabled: true,
        eligibilityGate: gate, commitments: [`0x${'00'.repeat(32)}`, 0n, 1n, 1n], parentEpoch: 1n,
        gateVersion: 1n, commitNonce: 0n, ownerOf: c.address === ns.names ? registrar : account, resolve: registrar,
        records: ['pepetesters', 0n, 999999n, 1n, 0n], factory, currentRoundId: 0n,
        registrationPrice: NAME_REGISTRATION_FEE,
      }
      if (c.functionName in defaults) return defaults[c.functionName]
      throw Error(`Unexpected read: ${c.functionName}`)
    },
  }
  return { client, calls }
}
test('registration preflight pins custody, rules, proof and fee to one block', async () => {
  const { client, calls } = reader()
  const state = await readNameRegistration(client, ns, factory, account)
  assert.equal(state.price, NAME_REGISTRATION_FEE)
  assert.equal(state.proof, '0x')
  assert(calls.every(c => c.blockNumber === 100n))
})
test('wrong network, ABI rules, parent, custody, epoch and source block registration', async () => {
  for (const change of [
    { chainId: 84532 }, { REGISTRAR_VERSION: 1n }, { REGISTRATION_FEE: 1n },
    { parentId: 1n }, { names: factory }, { MIN_COMMIT_AGE: 0n }, { MAX_COMMIT_AGE: 100000n },
    { registrationEnabled: false }, { ownerOf: account }, { parentEpoch: 2n },
    { resolve: '0x0000000000000000000000000000000000000000' }, { factory: account },
    { registrationPrice: 1n },
  ]) await assert.rejects(readNameRegistration(reader(change).client, ns, factory, account))
})
test('unavailable eligibility never quietly charges a funded wallet', async () => {
  await assert.rejects(readNameRegistration(reader({ failAt: 'currentRoundId' }).client, ns, factory, account), /RPC unavailable/)
})
test('eligibility enumeration reaches older rounds and NFTs after the first batch', async () => {
  const calls = []
  const recent = '0x5555555555555555555555555555555555555555'
  const older = '0x6666666666666666666666666666666666666666'
  const client = { readContract: async c => {
    calls.push(c)
    switch (c.functionName) {
      case 'currentRoundId': return 2n
      case 'rounds': return [account, c.args[0] === 2n ? recent : older, account, false, 'PSP', 'PSP']
      case 'staker': return c.address
      case 'balanceOf': return c.address === recent ? 1n : 12n
      case 'tokenOfOwnerByIndex': return c.args[1]
      case 'positions': return [c.address === older && c.args[0] === 11n ? 1n : 0n, 0n, 0n, 0n, 0n]
      case 'ownerOf': return account
    }
    throw Error('Unexpected read')
  } }
  const proof = await findNameEligibilityProof(client, factory, account, 100n)
  assert.deepEqual(decodeAbiParameters(parseAbiParameters('uint256,uint256'), proof), [1n, 11n])
  assert(calls.every(c => c.blockNumber === 100n))
})
test('cancelled eligibility scans stop before further round reads', async () => {
  const abort = new AbortController()
  abort.abort()
  await assert.rejects(findNameEligibilityProof(reader({ currentRoundId: 2n }).client, factory, account, 100n, abort.signal), { name: 'AbortError' })
})
