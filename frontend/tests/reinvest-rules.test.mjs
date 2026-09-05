import test from 'node:test'
import assert from 'node:assert/strict'
import { assertReinvestor } from '../src/lib/reinvestRules.ts'

test('reinvestment requires both current-round wiring and corrected buyer attribution', () => {
  assert.doesNotThrow(() => assertReinvestor('0xAB', '0xab', 1n))
  assert.throws(() => assertReinvestor('0xab', '0xcd', 1n), /unavailable for this round/)
  for (const version of [undefined, 0n, 2n]) {
    assert.throws(() => assertReinvestor('0xab', '0xab', version), /does not credit purchases to the NFT owner/)
  }
})
