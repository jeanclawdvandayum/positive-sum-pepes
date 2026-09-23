import test from 'node:test'
import assert from 'node:assert/strict'
import { urgencyFor } from '../src/alt/urgency.ts'

test('band edges: exactly 30% is safe, below is warm', () => {
 assert.equal(urgencyFor(30, 100), 'safe') // exactly 30% → green
 assert.equal(urgencyFor(3000, 10000), 'safe')
 assert.equal(urgencyFor(3001, 10000), 'safe')
 assert.equal(urgencyFor(2999, 10000), 'warm') // just below 30% → yellow
})
test('band edges: exactly 10% is warm, below is critical', () => {
 assert.equal(urgencyFor(10, 100), 'warm') // exactly 10% → yellow
 assert.equal(urgencyFor(1001, 10000), 'warm') // just above 10% → yellow
 assert.equal(urgencyFor(999, 10000), 'critical') // just below 10% → red
})
test('zero remaining is critical', () => {
 assert.equal(urgencyFor(0, 100), 'critical')
 assert.equal(urgencyFor(0, 259200), 'critical')
})
test('total 0 or unknown is idle', () => {
 assert.equal(urgencyFor(50, 0), 'idle')
 assert.equal(urgencyFor(50, undefined), 'idle')
 assert.equal(urgencyFor(50, NaN), 'idle')
 assert.equal(urgencyFor(50, -5), 'idle')
})
test('remaining beyond total (clock extended) is safe', () => {
 assert.equal(urgencyFor(120, 100), 'safe')
})
test('live shapes: carpet-bomb window and IBCO predeposit window', () => {
 assert.equal(urgencyFor(216000, 259200), 'safe') // ~60h of 72h predeposit left
 assert.equal(urgencyFor(600, 1800), 'safe') // a third of the bomb window left
 assert.equal(urgencyFor(90, 1800), 'critical') // 5% of the bomb window left
})
