import test from 'node:test'
import assert from 'node:assert/strict'
import { positionFeesEarned } from '../src/lib/positionFees.ts'
test('claims and reinvestment move pending to paid without resetting earned fees', () => {
  const earned = positionFeesEarned(8n, 12n)
  assert.equal(earned, 20n)
  assert.equal(positionFeesEarned(20n, 0n), earned)
  assert.equal(positionFeesEarned(20n, 3n), 23n)
})
test('missing reads remain unknown instead of presenting partial fee totals', () => {
  assert.equal(positionFeesEarned(undefined, 12n), undefined)
  assert.equal(positionFeesEarned(8n, undefined), undefined)
  assert.equal(positionFeesEarned(0n, 0n), 0n)
})
