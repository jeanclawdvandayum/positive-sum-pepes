import test from 'node:test'
import assert from 'node:assert/strict'
import { parseAbi, encodeFunctionResult } from 'viem'
import { createRpcReader } from '../src/lib/rpcReader.ts'
import { hookAbi } from '../src/lib/abi.ts'

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

test('chain-aware view reads use one Multicall3 eth_call and keep each result attached to its request', async () => {
  const { baseSepolia } = await import('viem/chains')
  const { multicall3Abi, decodeFunctionData } = await import('viem')
  let count=0
  const reader=createRpcReader('https://rpc.test/multicall', { chain:baseSepolia, fetchFn:async (_url, init)=>{
    count++
    const request=JSON.parse(init.body)
    const q=Array.isArray(request)?request[0]:request
    assert.equal(q.params[0].to.toLowerCase(),baseSepolia.contracts.multicall3.address.toLowerCase())
    const decoded=decodeFunctionData({abi:multicall3Abi,data:q.params[0].data})
    assert.equal(decoded.args[0].length,2)
    const result=encodeFunctionResult({abi:multicall3Abi,functionName:'aggregate3',result:decoded.args[0].map((call,i)=>({
      success:true,returnData:encodeFunctionResult({abi,functionName:'balanceOf',result:BigInt(i+20)}),
    }))})
    const response={jsonrpc:'2.0',id:q.id,result}
    return Response.json(Array.isArray(request)?[response]:response)
  }})
  assert.deepEqual(await Promise.all([reader.call(token,abi,'balanceOf',[alice]),reader.call(token,abi,'balanceOf',[bob])]),[20n,21n])
  assert.equal(count,1)
})

test('a rate-limited provider falls back for reads without dropping their arguments', async () => {
  const urls=[]
  const reader=createRpcReader('https://rpc.test/limited', {fallbackUrl:'https://rpc.test/healthy',fetchFn:async (url, init)=>{
    urls.push(String(url))
    const body=JSON.parse(init.body),qs=Array.isArray(body)?body:[body]
    const replies=qs.map(q=>String(url).endsWith('/limited')
      ? {jsonrpc:'2.0',id:q.id,error:{code:-32005,message:'over rate limit'}}
      : {jsonrpc:'2.0',id:q.id,result:encodeFunctionResult({abi,functionName:'balanceOf',result:99n})})
    return Response.json(Array.isArray(body)?replies:replies[0])
  }})
  assert.equal(await reader.call(token,abi,'balanceOf',[alice]),99n)
  assert.deepEqual(urls,['https://rpc.test/limited','https://rpc.test/healthy'])
})

test('quote, rate and mode are read in one explicit aggregate at the same block', async () => {
  const { baseSepolia } = await import('viem/chains')
  const { multicall3Abi, decodeFunctionData } = await import('viem')
  const calls = [{ functionName: 'getSellOutput', args: [100n] }, { functionName: 'swapFeeBps' }, { functionName: 'mode' }]
  const values = [90n, 1000, 1]
  let requests = 0
  const reader = createRpcReader('https://rpc.test/quote', { chain: baseSepolia, fetchFn: async (_url, init) => {
    requests++
    const body = JSON.parse(init.body), qs = Array.isArray(body) ? body : [body]
    assert.equal(qs.length, 1)
    const q = qs[0]
    const aggregate = decodeFunctionData({ abi: multicall3Abi, data: q.params[0].data })
    assert.equal(aggregate.args[0].length, 3)
    const result = encodeFunctionResult({ abi: multicall3Abi, functionName: 'aggregate3', result: aggregate.args[0].map((call, i) => {
      assert.equal(call.target.toLowerCase(), token)
      const decoded = decodeFunctionData({ abi: hookAbi, data: call.callData })
      assert.equal(decoded.functionName, calls[i].functionName)
      if (i === 0) assert.deepEqual(decoded.args, [100n])
      return { success: true, returnData: encodeFunctionResult({ abi: hookAbi, functionName: calls[i].functionName, result: values[i] }) }
    }) })
    const reply = { jsonrpc: '2.0', id: q.id, result }
    return Response.json(Array.isArray(body) ? [reply] : reply)
  } })
  assert.deepEqual(await reader.batchCall(token, hookAbi, calls), values)
  assert.equal(requests, 1)
})

test('a missing fee read rejects the entire quote snapshot', async () => {
  const { baseSepolia } = await import('viem/chains')
  const { multicall3Abi } = await import('viem')
  const reader = createRpcReader('https://rpc.test/partial-quote', { chain: baseSepolia, fetchFn: async (_url, init) => {
    const body = JSON.parse(init.body), q = Array.isArray(body) ? body[0] : body
    const result = encodeFunctionResult({ abi: multicall3Abi, functionName: 'aggregate3', result: [
      { success: true, returnData: encodeFunctionResult({ abi, functionName: 'balanceOf', result: 90n }) },
      { success: false, returnData: '0x' },
    ] })
    const reply = { jsonrpc: '2.0', id: q.id, result }
    return Response.json(Array.isArray(body) ? [reply] : reply)
  } })
  await assert.rejects(reader.batchCall(token, abi, [{ functionName: 'balanceOf', args: [alice] }, { functionName: 'balanceOf', args: [bob] }]))
})
