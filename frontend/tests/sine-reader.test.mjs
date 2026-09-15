import test from 'node:test'
import assert from 'node:assert/strict'
import { createSineCurveReader } from '../src/lib/sineReader.ts'

const hook = '0x000000000000000000000000000000000000000a'
const info = [3n, 75_000_000_000_000n, 450n * 10n ** 18n,
  955n * 10n ** 18n, 10_000n * 10n ** 18n, 7_711_482n * 10n ** 18n, hook]

test('a prelaunch chart refreshes when the same hook launches, then caches its coefficients', async () => {
  let active = false, calls = 0
  const read = createSineCurveReader(async (_hook, name) => {
    calls++
    if (name === 'sineConfigured') return true
    if (name === 'sineActive') return active
    if (name === 'SINE_RULES_VERSION') return 3n
    assert.equal(name, 'sineV3Info')
    return info
  })
  assert.equal((await read(hook)).active, false)
  active = true
  const launched = await read(hook, 450)
  assert.equal(launched.active, true)
  assert.equal(launched.top, 10_000)
  const before = calls
  assert.equal((await read(hook.toUpperCase())).active, true)
  assert.equal(calls, before, 'same address casing must reuse immutable coefficients')
  const extended = await read(hook, 20_000)
  assert.ok(extended.points.at(-1).reserve > launched.points.at(-1).reserve)
  assert.equal(calls, before, 'extending the chart requires no new chain reads')
})

test('failed coefficient reads retry rather than caching a permanent chart failure', async () => {
  let fail = true
  const read = createSineCurveReader(async (_hook, name) => {
    if (name === 'sineConfigured' || name === 'sineActive') return true
    if (name === 'SINE_RULES_VERSION') return 3n
    if (fail) throw Error('RPC unavailable')
    return info
  })
  await assert.rejects(read(hook), /RPC unavailable/)
  fail = false
  assert.equal((await read(hook)).active, true)
})

test('a successor hook gets an independent coefficient read', async () => {
  const seen = new Set()
  const read = createSineCurveReader(async (address, name) => {
    seen.add(address)
    if (name === 'sineConfigured' || name === 'sineActive') return true
    if (name === 'SINE_RULES_VERSION') return 3n
    return info
  })
  await read(hook)
  await read('0x000000000000000000000000000000000000000b')
  assert.equal(seen.size, 2)
})
