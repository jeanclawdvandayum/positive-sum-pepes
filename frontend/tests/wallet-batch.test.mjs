import { test } from 'node:test'
import assert from 'node:assert/strict'
import { supportsAtomicBatch, assertBatchReceipt } from '../src/lib/walletBatch.ts'
import { prepareNftReinvestment } from '../src/lib/nftPermissions.ts'
import { topUpPosition } from '../src/lib/stakeTopUp.ts'

test('atomic detection accepts ready and upgradeable accounts, fails closed otherwise', () => {
  for (const status of ['supported', 'ready']) assert.equal(supportsAtomicBatch({ atomic: { status } }), true)
  for (const value of [undefined, {}, { atomic: true }, { atomic: { status: 'unsupported' } }, { 84532: { atomic: { status: 'supported' } } }]) assert.equal(supportsAtomicBatch(value), false)
})
test('success requires one successful atomic receipt', () => {
  const receipt = { status: 'success', transactionHash: '0xabc' }
  assert.doesNotThrow(() => assertBatchReceipt({ status: 'success', atomic: true, receipts: [receipt] }))
  for (const result of [
    { status: 'failure', atomic: true, receipts: [receipt] },
    { status: 'success', atomic: false, receipts: [receipt] },
    { status: 'success', atomic: true, receipts: [] },
    { status: 'success', atomic: true, receipts: [receipt, receipt] },
    { status: 'success', atomic: true, receipts: [{ ...receipt, status: 'reverted' }] },
  ]) assert.throws(() => assertBatchReceipt(result))
})
const owner = '0x1111111111111111111111111111111111111111'
const operator = '0x2222222222222222222222222222222222222222'
const zero = '0x0000000000000000000000000000000000000000'
test('deferred reinvest approval checks ownership without requiring queued approval to already exist', async () => {
  const queued = []
  const ops = { assertSession() {}, ownerOf: async () => owner, isApprovedForAll: async () => false, getApproved: async () => zero,
    approve: async id => queued.push(id), approveAll: async () => queued.push('all') }
  await prepareNftReinvestment(owner, operator, [1n, 2n, 3n], 1, ops, true, true)
  assert.deepEqual(queued, ['all'])
  await assert.rejects(prepareNftReinvestment(owner, operator, [1n], 1, { ...ops, ownerOf: async () => operator }, true, true), /owners/)
})
test('top-up atomic path executes once and never retries rejected batch', async () => {
  let batches = 0, individual = 0
  const ops = { assertSession() {}, read: async () => ({ owner, withdrawing: false, balance: 10n, allowance: 0n, mode: 1, flatTime: 0n }),
    approve: async () => individual++, stake: async () => individual++, onStep() {}, atomicStake: async () => { batches++; return true } }
  await topUpPosition({ owner, staker: operator, id: 1n, amount: 2n }, ops)
  assert.equal(batches, 1); assert.equal(individual, 0)
  await assert.rejects(topUpPosition({ owner, staker: operator, id: 1n, amount: 2n }, { ...ops, atomicStake: async () => { throw Error('rejected') } }), /rejected/)
  assert.equal(individual, 0)
})

const { confirmAtomicTransaction } = await import('../src/lib/walletBatch.ts')
test('batch confirms chain receipt before success and uses transaction hash, never bundle id', async () => {
  const stages = [], calls = []
  const hash = '0xabc'
  const result = await confirmAtomicTransaction({
    send: async () => { calls.push('send'); return { id: 'bundle-id' } },
    wait: async id => { assert.equal(id, 'bundle-id'); calls.push('wait'); return { status: 'success', atomic: true, receipts: [{ status: 'success', transactionHash: hash }] } },
    confirm: async h => { assert.equal(h, hash); assert.equal(stages.at(-1)[0], 'pending'); calls.push('confirm'); return { status: 'success' } },
    notify: (...stage) => stages.push(stage),
  })
  assert.equal(result, hash)
  assert.deepEqual(calls, ['send', 'wait', 'confirm'])
  assert.deepEqual(stages.at(-1), ['success', hash])
})
test('rejection, timeout, and revert never retry or announce success', async () => {
  for (const failure of ['reject', 'timeout', 'revert']) {
    let sends = 0; const stages = []
    await assert.rejects(confirmAtomicTransaction({
      send: async () => { sends++; if (failure === 'reject') throw Error('rejected'); return { id: 'bundle' } },
      wait: async () => { if (failure === 'timeout') throw Error('timeout'); return { status: 'failure', atomic: true, receipts: [{ status: 'reverted', transactionHash: '0xabc' }] } },
      confirm: async () => { throw Error('must not confirm failed batch') },
      notify: (...stage) => stages.push(stage),
    }))
    assert.equal(sends, 1)
    assert.equal(stages.at(-1)[0], failure === 'timeout' ? 'unknown' : 'failed')
    assert.equal(stages.some(s => s[0] === 'success'), false)
  }
})
