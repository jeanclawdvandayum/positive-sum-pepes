import test from 'node:test'
import assert from 'node:assert/strict'
import { userFacingRpcError } from '../src/lib/rpcErrors.ts'

test('explains nested insufficient-allowance revert signatures', () => {
  const failure = new Error('Simulation failed', { cause: new Error('Unable to decode signature "0xfb8f41b2"') })
  assert.match(userFacingRpcError(failure).message, /approval is too small or was already used/)
})
test('explains decoded insufficient allowance and preserves unrelated errors', () => {
  assert.match(userFacingRpcError(new Error('ERC20InsufficientAllowance')).message, /approve the current deposit/)
  const rejected = new Error('User rejected the request')
  assert.equal(userFacingRpcError(rejected), rejected)
})
