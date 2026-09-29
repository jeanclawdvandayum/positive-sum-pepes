// Exit-guard regression: the one-tx grave-zap path was rejected wholesale by
// RS-5 ("This action is not an exit from the selected round.") because the
// allowlist predated the zap. Pins every branch of assertRoundExit.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

// exitRules imports ./config, which reads import.meta.env — unavailable to
// plain node. Compile-and-run through esbuild-style strip with a shimmed env
// by running it in a temp project where VITE_GRAVE_ZAP is baked.
const tmp = mkdtempSync(join(tmpdir(), 'exit-rules-'))
try {
  // config stub with the same ADDRESSES shape, fed from the test env
  const cfg = `
    export const ADDRESSES = { graveZap: process.env.ZAP_FOR_TEST || '0x' }
  `
  writeFileSync(join(tmp, 'config-stub.mjs'), cfg)
  const src = await (await import('node:fs/promises')).readFile(new URL('../src/lib/exitRules.ts', import.meta.url), 'utf8')
  // keep the .ts extension so node's strip-types loader handles the types
  writeFileSync(join(tmp, 'exitRules.ts'),
    src.replace("import { ADDRESSES } from './config'", "import { ADDRESSES } from './config-stub.mjs'"))

  const zap = '0x20a38823d0c4c40d9a3fc53b9870a6580edeaeb3'
  process.env.ZAP_FOR_TEST = zap
  const rules = await import(join(tmp, 'exitRules.ts'))
  const round = {
    token: '0xtoken', controller: '0xcontroller', hook: '0xhook', staker: '0xstaker',
  }
  const act = (address, functionName, args = []) => ({ address, functionName, args })

  test('zap exit legs are valid exits', () => {
    rules.assertRoundExit(round, act(zap, 'exit', [round.hook, round.staker, [], 0n, 0n, 0n]))
    rules.assertRoundExit(round, act(round.staker, 'setApprovalForAll', [zap, true]))
    rules.assertRoundExit(round, act(round.token, 'approve', [zap, 5n]))
  })

  test('zap exit bound to THIS round only', () => {
    assert.throws(() => rules.assertRoundExit(round, act(zap, 'exit', ['0xotherhook', round.staker])))
    assert.throws(() => rules.assertRoundExit(round, act(zap, 'exit', [round.hook, '0xotherstaker'])))
  })

  test('operator grant only to the zap, only true', () => {
    assert.throws(() => rules.assertRoundExit(round, act(round.staker, 'setApprovalForAll', ['0xstranger', true])))
    assert.throws(() => rules.assertRoundExit(round, act(round.staker, 'setApprovalForAll', [zap, false])))
  })

  test('token approve only to hook or zap', () => {
    assert.throws(() => rules.assertRoundExit(round, act(round.token, 'approve', ['0xstranger', 5n])))
  })

  test('strangers and unknown selectors still rejected', () => {
    assert.throws(() => rules.assertRoundExit(round, act('0xstranger', 'exit', [round.hook, round.staker])))
    assert.throws(() => rules.assertRoundExit(round, act(zap, 'sweep', [])))
    assert.throws(() => rules.assertRoundExit(round, act(round.staker, 'transferFrom', [round.token, zap, 1n])))
  })
} finally {
  rmSync(tmp, { recursive: true, force: true })
}
