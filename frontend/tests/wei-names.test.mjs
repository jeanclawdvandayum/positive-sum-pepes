import { test } from 'node:test'
import assert from 'node:assert/strict'
import { childNameId, readVerifiedName, TEST_NAME_PARENT_ID, WEI_NODE, WNS_ADDRESS } from '../src/lib/weiNames.ts'

const alice = '0x1111111111111111111111111111111111111111'
const bob = '0x2222222222222222222222222222222222222222'
const registrar = '0x3333333333333333333333333333333333333333'
const ns = { chainId: 1, names: WNS_ADDRESS, parentId: TEST_NAME_PARENT_ID, parentLabel: 'pepetesters', registrar }
const id = childNameId(ns.parentId, 'frog')
function mock(overrides = {}) {
  const calls = []
  const values = { primaryName: id, records: ['frog', ns.parentId, 0n, 1n, 1n], ownerOf: alice, resolve: alice, ...overrides }
  return { calls, client: {
    getChainId: async () => values.chainId ?? 1,
    getBlockNumber: async () => 100n,
    readContract: async (call) => { calls.push(call); if (values.failure) throw Error('RPC down'); return values[call.functionName] },
  } }
}

test('WNS namehash matches the actual pepetesters.wei parent token', () => {
  assert.equal(childNameId(BigInt(WEI_NODE), 'pepetesters'), TEST_NAME_PARENT_ID)
})
test('registered app name appears without a separate WNS primary transaction; all reads share a block', async () => {
  const { client, calls } = mock()
  assert.equal(await readVerifiedName(client, ns, alice), 'frog.pepetesters.wei')
  assert.equal(calls[0].address, registrar)
  assert(calls.every(c => c.blockNumber === 100n))
})
test('canonical WNS primary names work before a PSP registrar is configured', async () => {
  const { client, calls } = mock()
  assert.equal(await readVerifiedName(client, { ...ns, registrar: undefined }, alice), 'frog.pepetesters.wei')
  assert.equal(calls[0].address, WNS_ADDRESS)
})
test('transferred, redirected and expired names do not label the previous wallet', async () => {
  for (const change of [{ ownerOf: bob }, { resolve: bob }, { resolve: '0x0000000000000000000000000000000000000000' }]) {
    assert.equal(await readVerifiedName(mock(change).client, ns, alice), undefined)
  }
})
test('forged reverse mappings and names under another parent are rejected', async () => {
  for (const records of [['fake', ns.parentId, 0n, 1n, 1n], ['frog', 1n, 0n, 1n, 1n]]) {
    assert.equal(await readVerifiedName(mock({ records }).client, ns, alice), undefined)
  }
})
test('unsafe Unicode, markup, dot and whitespace labels remain addresses', async () => {
  for (const label of ['fro\u202eg', '<frog>', 'x.pepe', 'frog ', 'frög', '-frog', 'frog-', 'FROG']) {
    const badId = childNameId(ns.parentId, label)
    assert.equal(await readVerifiedName(mock({ primaryName: badId, records: [label, ns.parentId, 0n, 1n, 1n] }).client, ns, alice), undefined)
  }
})
test('wrong networks, misconfigured parents and unavailable RPC fail closed', async () => {
  await assert.rejects(readVerifiedName(mock({ chainId: 84532 }).client, ns, alice), /network mismatch/)
  await assert.rejects(readVerifiedName(mock().client, { ...ns, parentLabel: 'pepe' }, alice), /parent mismatch/)
  await assert.rejects(readVerifiedName(mock({ failure: true }).client, ns, alice), /RPC down/)
})
test('an unregistered wallet resolves to no name', async () => {
  assert.equal(await readVerifiedName(mock({ primaryName: 0n }).client, ns, alice), undefined)
})
