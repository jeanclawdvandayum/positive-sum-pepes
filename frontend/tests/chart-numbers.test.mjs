import test from 'node:test'
import assert from 'node:assert/strict'
import { chartWad } from '../src/lib/chartNumbers.ts'
test('unrepresentable chart labels remain unavailable instead of throwing', () => {
  for (const v of [Infinity, -Infinity, NaN, Number.MAX_VALUE]) assert.equal(chartWad(v), undefined)
  assert.equal(chartWad(0), 0n)
  assert.equal(chartWad(10_000_000), BigInt(Math.round(10_000_000 * 1e18)))
})
