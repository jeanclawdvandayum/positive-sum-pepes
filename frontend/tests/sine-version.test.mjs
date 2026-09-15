import test from 'node:test'
import assert from 'node:assert/strict'
import { readSineRulesVersion } from '../src/lib/sineVersion.ts'

test('new and explicit legacy sine versions resolve without interpretation guesses', async () => {
  assert.equal(await readSineRulesVersion(async () => 3n), 3)
  assert.equal(await readSineRulesVersion(async () => 2n), 2)
  assert.equal(await readSineRulesVersion(async () => 1n), 1)
  for (const version of [undefined, 0n, 4n, 2, '2'])
    await assert.rejects(readSineRulesVersion(async () => version), /Unsupported sine/)
})
test('only a missing legacy selector falls back, while transport failures retry', async () => {
  for (const message of ['execution reverted', 'Cannot decode zero data ("0x") with ABI parameters.', 'rpc SINE_RULES_VERSION: no result']) {
    assert.equal(await readSineRulesVersion(async () => { throw Error(message) }), 1)
  }
  for (const message of ['HTTP request failed', 'Rate limit exceeded', 'connection timeout']) {
    await assert.rejects(readSineRulesVersion(async () => { throw Error(message) }), new RegExp(message))
  }
})
