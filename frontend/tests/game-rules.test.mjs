import test from 'node:test'
import assert from 'node:assert/strict'
import { assertGameRules, MIN_BUY_INPUT, TIME_PER_UNIT, purchaseUnits, minimumOutput } from '../src/lib/gameRules.ts'

test('minimum ladder threshold, multiple seats, and 69-second increments',()=>{
 assert.equal(purchaseUnits(MIN_BUY_INPUT-1n),0n)
 assert.equal(purchaseUnits(MIN_BUY_INPUT),1n)
 assert.equal(purchaseUnits(MIN_BUY_INPUT*10n),10n)
 assert.equal(purchaseUnits(MIN_BUY_INPUT*3n-1n),2n)
 assert.equal(TIME_PER_UNIT*10n,690n)
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
  assert.doesNotThrow(() => assertGameRules(5_000_000_000_000_000n, 69n))
  assert.throws(() => assertGameRules(5_000_000_000_000_000n, 300n), /different game rules/)
  assert.throws(() => assertGameRules(1n, 69n), /different game rules/)
})

test('linear tickets rise smoothly from the genesis pot and floor only whole tickets', async () => {
 const { linearTicketPrice } = await import('../src/lib/gameRules.ts')
 const wad = 10n ** 18n, genesis = 100n * wad
 assert.equal(linearTicketPrice(genesis, genesis), MIN_BUY_INPUT)
 assert.equal(linearTicketPrice(genesis + 100n * wad, genesis), 7100000000000000n)
 assert.equal(linearTicketPrice(genesis + 1000n * wad, genesis), 26000000000000000n)
 assert.equal(linearTicketPrice(genesis + wad / 2n, genesis), 5010500000000000n)
 const price = linearTicketPrice(genesis + wad, genesis)
 assert.equal(purchaseUnits(price - 1n, price), 0n)
 assert.equal(purchaseUnits(price * 10n, price), 10n)
 assert.equal(TIME_PER_UNIT * 10n, 690n)
 assert.equal(purchaseUnits(wad, 0n), 0n)
 assert.throws(() => assertGameRules(MIN_BUY_INPUT, 69n, 0n), /different game rules/)
})
