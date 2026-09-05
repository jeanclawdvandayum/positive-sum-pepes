import test from 'node:test'
import assert from 'node:assert/strict'
import { parseAbi, encodeFunctionResult } from 'viem'
import { createRpcReader } from '../src/lib/rpcReader.ts'

const abi = parseAbi(['function balanceOf(address) view returns (uint256)'])
const token = '0x0000000000000000000000000000000000000001'
const alice = '0x0000000000000000000000000000000000000002'
const bob = '0x0000000000000000000000000000000000000003'
test('concurrent wallet reads batch and deduplicate without mixing reversed responses', async () => {
  let requests = 0
  const reader = createRpcReader('https://rpc.test/order', { fetchFn: async (_url, init) => {
    requests++
    const batch = JSON.parse(init.body)
    assert.equal(batch.length, 2)
    return Response.json(batch.map((q, i) => ({ jsonrpc: '2.0', id: q.id,
      result: encodeFunctionResult({ abi, functionName: 'balanceOf', result: BigInt(i + 7) }),
    })).reverse())
  } })
  assert.deepEqual(await Promise.all([
    reader.call(token, abi, 'balanceOf', [alice]),
    reader.call(token, abi, 'balanceOf', [alice]),
    reader.call(token, abi, 'balanceOf', [bob]),
  ]), [7n, 7n, 8n])
  assert.equal(requests, 1)
})

test('one reverted read does not replace another wallet balance or silently return zero', async () => {
  const reader = createRpcReader('https://rpc.test/revert', { fetchFn: async (_url, init) => {
    const batch = JSON.parse(init.body)
    return Response.json([
      { jsonrpc: '2.0', id: batch[1].id, error: { code: -32000, message: 'execution reverted' } },
      { jsonrpc: '2.0', id: batch[0].id, result: encodeFunctionResult({ abi, functionName: 'balanceOf', result: 17n }) },
    ])
  } })
  const results = await Promise.allSettled([
    reader.call(token, abi, 'balanceOf', [alice]), reader.call(token, abi, 'balanceOf', [bob]),
  ])
  assert.deepEqual(results[0], { status: 'fulfilled', value: 17n })
  assert.equal(results[1].status, 'rejected')
})

test('a stalled RPC releases the read for the polling hook to retry', async () => {
  const reader = createRpcReader('https://rpc.test/timeout', { timeout: 30, fetchFn: async (_url, init) => new Promise((_resolve, reject) => {
    init.signal.addEventListener('abort', () => reject(init.signal.reason), { once: true })
  }) })
  await assert.rejects(reader.call(token, abi, 'balanceOf', [alice]), /timed out/i)
})
