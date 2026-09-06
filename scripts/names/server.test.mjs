import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { createPermitServer, loadConfig } from './server.mjs'
import { PermitError } from './verifier.mjs'
const origin = 'http://127.0.0.1:4173'
async function runServer(t, options = {}) {
  const server = createPermitServer({ origins: [origin], issue: async () => ({ proof: 'fixture' }), ...options })
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
  t.after(() => new Promise(resolve => { server.closeAllConnections(); server.close(resolve) }))
  return (body = '{}', init = {}) => fetch(`http://127.0.0.1:${server.address().port}/permit`, {
    method: 'POST', headers: { Origin: origin, 'Content-Type': 'application/json' }, body, ...init,
  })
}
test('HTTP boundary enforces origin, method, media type, body limit and JSON', async t => {
  let issues = 0
  const send = await runServer(t, { issue: async () => { issues++; return { proof: 'fixture' } } })
  assert.equal((await send('{}', { headers: { Origin: 'https://evil.test', 'Content-Type': 'application/json' } })).status, 403)
  assert.equal((await send(undefined, { method: 'GET', body: undefined })).status, 405)
  assert.equal((await send('{}', { headers: { Origin: origin } })).status, 415)
  assert.equal((await send('x'.repeat(2049))).status, 413)
  assert.equal((await send('{')).status, 400)
  const response = await send()
  assert.equal(response.status, 200); assert.equal(response.headers.get('cache-control'), 'no-store')
  assert.equal(response.headers.get('access-control-allow-origin'), origin)
  assert.equal(issues, 1)
})
test('service errors hide RPC URLs and provider credentials', async t => {
  const send = await runServer(t, { issue: async () => { throw Error('https://secret:key@rpc.test') } })
  const response = await send()
  assert.equal(response.status, 503); assert(!JSON.stringify(await response.json()).includes('secret'))
})
test('stale eligibility is retriable without a paid fallback', async t => {
  const send = await runServer(t, { issue: async () => { throw new PermitError(409, 'Still settling.') } })
  assert.equal((await send()).status, 409)
})
test('rate limit cannot be bypassed by spoofing proxy headers', async t => {
  let issues = 0
  const send = await runServer(t, { rateLimit: 1, issue: async () => { issues++; return {} } })
  assert.equal((await send()).status, 200)
  assert.equal((await send('{}', { headers: { Origin: origin, 'Content-Type': 'application/json', 'X-Forwarded-For': '8.8.8.8' } })).status, 429)
  assert.equal(issues, 1)
})
test('bounded concurrent work rejects extra requests', async t => {
  let release, started
  const ready = new Promise(resolve => { started = resolve })
  const send = await runServer(t, { maxConcurrent: 1, issue: () => { started(); return new Promise(resolve => { release = resolve }) } })
  const pending = send()
  await ready
  assert.equal((await send()).status, 429)
  release({})
  assert.equal((await pending).status, 200)
})

test('operator config keeps a dedicated key private and rejects public HTTP, wildcard origins and key symlinks', t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'psp-name-key-test-'))
  t.after(() => fs.rmSync(dir, { recursive: true }))
  const key = path.join(dir, 'test.key')
  fs.writeFileSync(key, `0x${'ab'.repeat(32)}`, { mode: 0o600 })
  const env = { PSP_NAME_SIGNER_FILE: key, PSP_NAME_CHAIN_ID: '1', PSP_NAME_SOURCE_CHAIN_ID: '84532',
    PSP_NAME_PARENT_LABEL: 'pepetesters', PSP_NAME_GATE: '0x1111111111111111111111111111111111111111',
    PSP_NAME_REGISTRAR: '0x2222222222222222222222222222222222222222', PSP_NAME_FACTORY: '0x3333333333333333333333333333333333333333',
    PSP_NAME_RPC_URL: 'https://ethereum-rpc.publicnode.com', PSP_NAME_SOURCE_RPC_URL: 'https://sepolia.base.org', PSP_NAME_ORIGINS: origin }
  assert.equal(loadConfig(env).config.sourceChainId, 84532)
  fs.chmodSync(key, 0o644)
  assert.throws(() => loadConfig(env), /private file/)
  fs.chmodSync(key, 0o600)
  fs.symlinkSync(key, path.join(dir, 'link.key'))
  assert.throws(() => loadConfig({ ...env, PSP_NAME_SIGNER_FILE: path.join(dir, 'link.key') }), /private file/)
  assert.throws(() => loadConfig({ ...env, PSP_NAME_SOURCE_RPC_URL: 'http://public-rpc.example' }), /HTTPS/)
  assert.throws(() => loadConfig({ ...env, PSP_NAME_ORIGINS: '*' }))
  assert.throws(() => loadConfig({ ...env, PSP_NAME_CHAIN_ID: '1.5' }), /Invalid/)
})
