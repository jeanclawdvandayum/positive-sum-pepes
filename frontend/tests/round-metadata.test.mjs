import test from 'node:test'
import assert from 'node:assert/strict'
import { createRoundMetadataReader } from '../src/lib/roundMetadata.ts'
import { GameRulesMismatch } from '../src/lib/gameRules.ts'
import { userFacingRpcError } from '../src/lib/rpcErrors.ts'
const a = n => `0x${n.toString(16).padStart(40, '0')}`
const values = { rounds: [a(2), a(3), a(4)], mixETH: a(5), staker: a(6),
  curveConfig: [1n, 7200n], detWindow: 7200n, MIN_BUY_INPUT: 5000000000000000n,
  TIME_PER_UNIT: 69n, TICKET_RULES_VERSION: 2n, sineConfigured: true }

test('failed rule reads retry without caching an incompatible deployment', async () => {
  let fail = true, calls = 0
  const read = createRoundMetadataReader(a(1), async (_to, _abi, name) => {
    calls++
    if (name === 'TIME_PER_UNIT' && fail) throw Error('over rate limit')
    return values[name]
  })
  await assert.rejects(read(1n), /over rate limit/)
  fail = false
  assert.equal((await read(1n)).rulesCompatible, true)
  const before = calls
  assert.equal((await read(1n)).rulesCompatible, true)
  assert.equal(calls, before, 'immutable metadata must not be re-polled')
  await read(2n)
  assert.ok(calls > before, 'a successor needs its own validation')
})

test('a real legacy-rule mismatch remains incompatible', async () => {
  const read = createRoundMetadataReader(a(1), async (_to, _abi, name) => name === 'TIME_PER_UNIT' ? 300n : values[name])
  assert.equal((await read(1n)).rulesCompatible, false)
})

test('RPC availability errors stay distinct from contract and game-rule failures', () => {
  const rpc = Error('RPC Request failed', { cause: Error('over rate limit') })
  assert.match(userFacingRpcError(rpc).message, /connection is busy or unavailable/)
  const mismatch = new GameRulesMismatch('Different game rules')
  assert.equal(userFacingRpcError(mismatch), mismatch)
  const revert = Error('RPC Request failed: execution reverted')
  assert.equal(userFacingRpcError(revert), revert)
})
