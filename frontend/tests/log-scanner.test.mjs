import test from 'node:test'
import assert from 'node:assert/strict'
import { createLogScanner } from '../src/lib/logScanner.ts'

test('history starts at deployment, advances in bounded pages and replaces reorg overlap', async () => {
  const calls=[]
  let revision=1
  const scan=createLogScanner(async (from,to)=>{
    calls.push([from,to]);return [{blockNumber:to,revision}]
  },100n,{pageSize:10n,maxPages:2n,overlap:2n})
  await scan.poll(125n)
  assert.deepEqual(calls,[[100n,109n],[110n,119n]])
  const log2=await scan.poll(125n)
  assert.deepEqual(calls.slice(2),[[118n,125n]])
  const count=calls.length
  await scan.poll(125n)
  assert.equal(calls.length,count)
  revision=2
  const log3=await scan.poll(127n)
  assert.ok(log3.every(log=>log.blockNumber<124n || log.revision===2))
  assert.ok(!log3.includes(log2.at(-1)), 'replaced tail is removed')
})

test('failed history pages do not skip events on retry', async () => {
  let fail=true
  const calls=[]
  const scan=createLogScanner(async (from,to)=>{
    calls.push([from,to]);if(fail)throw Error('rate limit');return [{blockNumber:to}]
  },100n)
  await assert.rejects(scan.poll(110n), /rate limit/)
  fail=false
  assert.deepEqual(await scan.poll(110n),[{blockNumber:110n}])
  assert.deepEqual(calls,[[100n,110n],[100n,110n]])
})
