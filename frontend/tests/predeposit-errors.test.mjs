import test from 'node:test'
import assert from 'node:assert/strict'
import { userFacingRpcError } from '../src/lib/rpcErrors.ts'

test('explains nested insufficient-allowance revert signatures', () => {
  const failure = new Error('Simulation failed', { cause: new Error('Unable to decode signature "0xfb8f41b2"') })
  assert.match(userFacingRpcError(failure).message, /approval is too small or was already used/)
})
test('explains decoded insufficient allowance and preserves unrelated errors', () => {
  // token-neutral: the same selector fires for PSP (grave exit) and mixETH
  assert.match(userFacingRpcError(new Error('ERC20InsufficientAllowance')).message, /re-approve/)
  const rejected = new Error('User rejected the request')
  assert.equal(userFacingRpcError(rejected), rejected)
})
