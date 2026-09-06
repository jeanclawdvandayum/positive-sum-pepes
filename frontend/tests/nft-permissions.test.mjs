import test from 'node:test'
import assert from 'node:assert/strict'
import { nftRecipient, prepareNftReinvestment, assertNftManagement } from '../src/lib/nftPermissions.ts'
const owner = '0x0000000000000000000000000000000000000011'
const receiver = '0x0000000000000000000000000000000000000022'
const staker = '0x0000000000000000000000000000000000000033'
const operator = '0x0000000000000000000000000000000000000044'
const zero = '0x0000000000000000000000000000000000000000'
function fixture() {
  const approvals = new Map()
  const owners = new Map([[1n, owner], [2n, owner]])
  let all = false, session = true
  const writes = []
  const ops = {
    assertSession: () => { if (!session) throw Error('session changed') },
    ownerOf: async id => owners.get(id),
    isApprovedForAll: async () => all,
    getApproved: async id => approvals.get(id) ?? zero,
    approve: async id => { writes.push(id); approvals.set(id, operator) },
    approveAll: async () => { writes.push('all'); all = true },
  }
  return { ops, approvals, owners, writes, disconnect: () => { session = false }, approveAll: () => { all = true } }
}
const prepare = (f, ids = [1n, 2n], version = 1) => prepareNftReinvestment(owner, operator, ids, version, f.ops)

test('safe transfer input rejects malformed, zero, self and staking-contract recipients', () => {
  assert.equal(nftRecipient(` ${receiver} `, owner, staker), receiver)
  for (const value of ['', '0x12', zero, owner, staker, 'alice.eth', `${receiver}0`]) {
    assert.throws(() => nftRecipient(value, owner, staker))
  }
})
test('upgraded reinvestment grants only missing individual approvals', async () => {
  const f = fixture(); f.approvals.set(1n, operator)
  await prepare(f)
  assert.deepEqual(f.writes, [2n])
  await prepare(f)
  assert.deepEqual(f.writes, [2n])
})
test('existing collection approval works and legacy fallback stays explicit', async () => {
  const f = fixture(); f.approveAll()
  await prepare(f); assert.deepEqual(f.writes, [])
  const legacy = fixture(); legacy.ops.getApproved = () => { throw Error('unsupported') }
  await prepare(legacy, [1n], 0); assert.deepEqual(legacy.writes, ['all'])
})
test('unknown capability or invalid batches cause zero approval writes', async () => {
  for (const ids of [[], [1n, 1n], Array.from({ length: 65 }, (_, i) => BigInt(i + 1))]) {
    const f = fixture(); await assert.rejects(prepare(f, ids)); assert.deepEqual(f.writes, [])
  }
  const f = fixture()
  await assert.rejects(prepareNftReinvestment(owner, operator, [1n], undefined, f.ops), /Waiting/)
  assert.deepEqual(f.writes, [])
})
test('transferred NFT stops approval for the entire batch before a wallet prompt', async () => {
  const f = fixture(); f.owners.set(2n, receiver)
  await assert.rejects(prepare(f), /changed owners/)
  assert.deepEqual(f.writes, [])
})
test('wallet or ownership changes during the first approval stop subsequent signatures', async () => {
  for (const change of [f => f.disconnect(), f => f.owners.set(2n, receiver)]) {
    const f = fixture(); const original = f.ops.approve
    f.ops.approve = async id => { await original(id); change(f) }
    await assert.rejects(prepare(f))
    assert.deepEqual(f.writes, [1n])
  }
})
test('rejected, reverted and unconfirmed approvals never proceed', async () => {
  for (const reason of ['rejected', 'reverted', 'timeout']) {
    const f = fixture(); f.ops.approve = async id => { f.writes.push(id); throw Error(reason) }
    await assert.rejects(prepare(f), new RegExp(reason))
    assert.deepEqual(f.writes, [1n])
  }
})
test('revocation of an earlier approval is rechecked after later approvals', async () => {
  const f = fixture(); const original = f.ops.approve
  f.ops.approve = async id => { await original(id); if (id === 2n) f.approvals.delete(1n) }
  await assert.rejects(prepare(f), /approval changed/)
})
test('round-specific NFT management admits only safe transfers and revocations', () => {
  const check = action => assertNftManagement(staker, owner, operator, { address: staker, ...action })
  check({ functionName: 'safeTransferFrom', args: [owner, receiver, 1n] })
  check({ functionName: 'approve', args: [zero, 1n] })
  check({ functionName: 'setApprovalForAll', args: [operator, false] })
  for (const action of [
    { address: receiver, functionName: 'approve', args: [zero, 1n] },
    { functionName: 'safeTransferFrom', args: [receiver, owner, 1n] },
    { functionName: 'safeTransferFrom', args: [owner, zero, 1n] },
    { functionName: 'safeTransferFrom', args: [owner, receiver, 1n], value: 1n },
    { functionName: 'transferFrom', args: [owner, receiver, 1n] },
    { functionName: 'approve', args: [operator, 1n] },
    { functionName: 'setApprovalForAll', args: [operator, true] },
    { functionName: 'setApprovalForAll', args: [receiver, false] },
    { functionName: 'stakeFor', args: [owner, 1n, 100n] },
  ]) assert.throws(() => check(action))
})
