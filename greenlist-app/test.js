// Regression tests for the greenlist app's submission rules.
// Spawns a private server instance (own port, throwaway data dir).
// Run: node --test greenlist-app/test.js
import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = fileURLToPath(new URL('.', import.meta.url))
const PORT = 18421 + Math.floor(Math.random() * 500)
const BASE = `http://127.0.0.1:${PORT}`
const DATA = mkdtempSync(join(tmpdir(), 'gl-test-'))
const TOKEN = 'test-token-do-not-use'

const png = Buffer.from(
  '89504e470d0a1a0a0000000d494844520000000100000001080600000' +
  '01f15c4890000000d49444154789c626001000000ffff03000006000557bfabd4' +
  '0000000049454e44ae426082', 'hex')
const jpg = Buffer.from('ffd8ffe000104a46494600010100000100010000ffd9', 'hex')
const form = (address, file, filename, type) => {
  const b = '----gltest' + Math.random().toString(16).slice(2)
  const parts = []
  parts.push(Buffer.from(`--${b}\r\ncontent-disposition: form-data; name="address"\r\n\r\n${address}\r\n`))
  parts.push(Buffer.from(
    `--${b}\r\ncontent-disposition: form-data; name="meme"; filename="${filename}"\r\ncontent-type: ${type}\r\n\r\n`))
  parts.push(file)
  parts.push(Buffer.from(`\r\n--${b}--\r\n`))
  return { body: Buffer.concat(parts), headers: { 'content-type': `multipart/form-data; boundary=${b}` } }
}
const apply = (address, file, filename, type) => {
  const f = form(address, file, filename, type)
  return fetch(BASE + '/api/apply', { method: 'POST', body: f.body, headers: f.headers })
}

const child = spawn(process.execPath, ['server.js'], {
  cwd: ROOT,
  env: { ...process.env, PORT: String(PORT), GREENLIST_ADMIN_TOKEN: TOKEN, GREENLIST_DATA: DATA },
  stdio: 'ignore',
})
await new Promise((resolve, reject) => {
  child.on('error', reject)
  const t = setInterval(async () => {
    if (await fetch(BASE).then(r => r.ok).catch(() => false)) { clearInterval(t); resolve() }
  }, 100)
  setTimeout(() => reject(new Error('server did not start')), 5000)
})
const A = '0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

test.after(() => { child.kill(); rmSync(DATA, { recursive: true, force: true }) })

test('an approved submission cannot be replaced anonymously', async () => {
  // 1. initial submission
  let r = await apply(A, png, 'a.png', 'image/png')
  assert.equal(r.status, 200)
  // 2. admin approves it
  const list = await (await fetch(BASE + '/api/submissions', { headers: { authorization: `Bearer ${TOKEN}` } })).json()
  const row = list.find(x => x.address === A)
  assert.ok(row, 'submission listed')
  r = await fetch(`${BASE}/api/submissions/${row.id}`, {
    method: 'PATCH',
    headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json' },
    body: JSON.stringify({ status: 'approved' }),
  })
  assert.equal(r.status, 200)
  const memeBefore = Buffer.from(await (await fetch(BASE + row.meme)).arrayBuffer())
  const csvBefore = await (await fetch(BASE + '/api/export.csv', { headers: { authorization: `Bearer ${TOKEN}` } })).text()
  assert.ok(csvBefore.includes(A), 'approved address exported')

  // 3. anonymous resubmission with a DIFFERENT meme — must be rejected
  r = await apply(A, jpg, 'evil.jpg', 'image/jpeg')
  assert.equal(r.status, 409, 'duplicate submission rejected')

  // 4. nothing changed: meme bytes, decision, export
  const list2 = await (await fetch(BASE + '/api/submissions', { headers: { authorization: `Bearer ${TOKEN}` } })).json()
  assert.equal(list2.find(x => x.address === A).status, 'approved', 'decision untouched')
  const memeAfter = Buffer.from(await (await fetch(BASE + row.meme)).arrayBuffer())
  assert.deepEqual(memeAfter, memeBefore, 'meme untouched')
  const csvAfter = await (await fetch(BASE + '/api/export.csv', { headers: { authorization: `Bearer ${TOKEN}` } })).text()
  assert.equal(csvAfter, csvBefore, 'export untouched')
})
