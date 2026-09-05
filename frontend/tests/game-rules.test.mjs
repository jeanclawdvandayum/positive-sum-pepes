import test from 'node:test'
import assert from 'node:assert/strict'
import { assertGameRules, MIN_BUY_INPUT, TIME_PER_UNIT, purchaseUnits, minimumOutput } from '../src/lib/gameRules.ts'

test('minimum ladder threshold, multiple seats, and 4:20 increments',()=>{
 assert.equal(purchaseUnits(MIN_BUY_INPUT-1n),0n)
 assert.equal(purchaseUnits(MIN_BUY_INPUT),1n)
 assert.equal(purchaseUnits(MIN_BUY_INPUT*10n),10n)
 assert.equal(purchaseUnits(MIN_BUY_INPUT*3n-1n),2n)
 assert.equal(TIME_PER_UNIT*10n,2600n)
})
test('split orders cannot manufacture seats or time from remainders',()=>{
 for(let i=1n;i<1000n;i++){
  const a=MIN_BUY_INPUT+i*1234567890123n,b=MIN_BUY_INPUT+i*123456789321n
  assert(purchaseUnits(a)+purchaseUnits(b)<=purchaseUnits(a+b))
 }
})
test('slippage preserves exact integer floor beyond JS number precision',()=>{
 const q=123456789012345678901234567890n
 assert.equal(minimumOutput(q,100),q*9900n/10000n)
 assert.equal(minimumOutput(q,0),q)
 for(const invalid of [-1,10000,NaN,1.5])assert.throws(()=>minimumOutput(q,invalid))
 assert.throws(()=>minimumOutput(0n,100))
 assert.throws(()=>minimumOutput(1n,100))
})


test('legacy deployment rules cannot authorize new-interface actions', () => {
  assert.doesNotThrow(() => assertGameRules(5_000_000_000_000_000n, 260n))
  assert.throws(() => assertGameRules(5_000_000_000_000_000n, 300n), /different game rules/)
  assert.throws(() => assertGameRules(1n, 260n), /different game rules/)
})
