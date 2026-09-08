import test from 'node:test'
import assert from 'node:assert/strict'
import { confirmTransaction } from '../src/lib/transactions.ts'

test('dependent operations wait for successful mining and use replacement hash',async()=>{
 const events=[]
 const steps={simulate:async()=>events.push('simulate'),submit:async()=>{events.push('submit');return '0x01'},wait:async hash=>{assert.equal(hash,'0x01');events.push('confirmed');return {status:'success',transactionHash:'0x02',replacementReason:'repriced'}}}
 assert.equal(await confirmTransaction(steps,{}),'0x02')
 events.push('next operation')
 assert.deepEqual(events,['simulate','submit','confirmed','next operation'])
})
test('failed simulation never opens wallet',async()=>{
 await assert.rejects(confirmTransaction({simulate:async()=>{throw Error('revert')},submit:async()=>assert.fail('must not submit'),wait:async()=>assert.fail('must not wait')},{}),/revert/)
})
test('submitted but reverted transaction is not success',async()=>{
 await assert.rejects(confirmTransaction({simulate:async()=>{},submit:async()=>'0x01',wait:async()=>({status:'reverted',transactionHash:'0x01'})},{}),/Transaction reverted/)
})
test('timeout remains unknown, never marks the operation successful',async()=>{
 await assert.rejects(confirmTransaction({simulate:async()=>{},submit:async()=>'0x01',wait:async()=>{throw Error('timeout')}},{}),/timeout/)
})


test('successful cancellation or replacement is not a successful game action', async () => {
  for (const replacementReason of ['cancelled', 'replaced']) {
    await assert.rejects(confirmTransaction({
      simulate: async () => {}, submit: async () => '0xabc',
      wait: async () => ({ status: 'success', transactionHash: '0xdef', replacementReason }),
    }, {}), /cancelled or replaced/)
  }
})

test('toast lifecycle follows confirmation and replacement hash', async () => {
 const events=[]
 await confirmTransaction({simulate:async()=>{},submit:async()=>'0x01',wait:async()=>({status:'success',transactionHash:'0x02',replacementReason:'repriced'})},{},(...event)=>events.push(event))
 assert.deepEqual(events.map(e=>e[0]),['simulating','wallet','pending','success'])
 assert.equal(events.at(-1)[1],'0x02')
})
test('toast distinguishes unknown confirmation from reverted receipt', async () => {
 for (const timeout of [true,false]) {
  const events=[]
  await assert.rejects(confirmTransaction({simulate:async()=>{},submit:async()=>'0x01',wait:async()=>{if(timeout)throw Error('timeout');return {status:'reverted',transactionHash:'0x02'}}},{},(...event)=>events.push(event)))
  assert.equal(events.at(-1)[0],timeout?'unknown':'failed')
  assert.equal(events.at(-1)[1],timeout?'0x01':'0x02')
 }
})
test('wallet rejection has no invented explorer hash', async () => {
 const events=[]
 await assert.rejects(confirmTransaction({simulate:async()=>{},submit:async()=>{throw Error('rejected')},wait:async()=>assert.fail('no submission')},{},(...event)=>events.push(event)))
 assert.equal(events.at(-1)[0],'failed')
 assert.equal(events.at(-1)[1],undefined)
})
