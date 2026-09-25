// Greenlist application service — zero dependencies (node:http + node:sqlite).
// Collects ONLY an ethereum address and one meme image (png/jpg/jpeg) per
// submission: no IPs, no user agents, no timestamps are stored.
//
//   node greenlist-app/server.js        (PORT, GREENLIST_ADMIN_TOKEN env optional)
//
// Pages:  /        apply (alt-ui theme)
//         /admin   review submissions, approve/deny, export the approved CSV
// API:    POST /api/apply             multipart: address + image
//         GET  /api/submissions       admin token
//         PATCH /api/submissions/:id  admin token, {status:"approved"|"denied"|"pending"}
//         GET  /api/export.csv        admin token, approved addresses only
// Theme:  /alt/** served from ../frontend/public/alt (the alt UI's own sheets).
import { createServer } from 'node:http'
import { DatabaseSync } from 'node:sqlite'
import { randomBytes } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs'
import { extname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = fileURLToPath(new URL('.', import.meta.url))
const DATA = process.env.GREENLIST_DATA || join(ROOT, 'data')
const MEMES = join(DATA, 'memes')
const PUBLIC = join(ROOT, 'public')
const ALT = join(ROOT, '..', 'frontend', 'public', 'alt')
const STUDIO = join(ROOT, '..', 'studio-420')
const PORT = Number(process.env.PORT || 8421)
const MAX_BODY = 8 * 1024 * 1024

mkdirSync(MEMES, { recursive: true })
const tokenFile = join(DATA, 'admin-token')
let ADMIN_TOKEN = process.env.GREENLIST_ADMIN_TOKEN
if (!ADMIN_TOKEN) {
  if (existsSync(tokenFile)) ADMIN_TOKEN = readFileSync(tokenFile, 'utf8').trim()
  else {
    ADMIN_TOKEN = randomBytes(24).toString('base64url')
    writeFileSync(tokenFile, ADMIN_TOKEN + '\n', { mode: 0o600 })
  }
}

// ── store: id + address + meme + decision. nothing else. ────────────────────
const db = new DatabaseSync(join(DATA, 'greenlist.db'))
db.exec(`
  CREATE TABLE IF NOT EXISTS submissions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    address TEXT NOT NULL UNIQUE,
    meme_file TEXT NOT NULL,
    meme_type TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending'
  );
`)

// ── helpers ──────────────────────────────────────────────────────────────────
const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.woff2': 'font/woff2',
  '.svg': 'image/svg+xml',
}
const isEth = a => /^0x[0-9a-fA-F]{40}$/.test(a ?? '')
const sniff = b =>
  b.length > 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47
    ? 'image/png'
    : b.length > 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff
      ? 'image/jpeg'
      : null
/** Minimal binary-safe multipart/form-data parser → Map(field → {value}|{filename,data}) */
function parseMultipart(body, contentType) {
  const m = /boundary=(?:"([^"]+)"|([^;]+))/i.exec(contentType)
  if (!m) return null
  const boundary = Buffer.from('--' + (m[1] ?? m[2]))
  const out = new Map()
  let i = body.indexOf(boundary)
  while (i !== -1) {
    const start = i + boundary.length
    if (body.slice(start, start + 2).toString() === '--') break
    const headEnd = body.indexOf('\r\n\r\n', start)
    const next = body.indexOf(boundary, headEnd)
    if (headEnd === -1 || next === -1) break
    const head = body.slice(start, headEnd).toString()
    const nameM = /name="([^"]+)"/.exec(head)
    const fileM = /filename="([^"]*)"/.exec(head)
    const typeM = /content-type:\s*([^\r\n]+)/i.exec(head)
    if (nameM) {
      const data = body.slice(headEnd + 4, next - 2) // strip the trailing \r\n
      out.set(nameM[1], fileM
        ? { filename: fileM[1], contentType: typeM?.[1]?.trim(), data }
        : { value: data.toString() })
    }
    i = next
  }
  return out
}

const json = (res, code, value) => {
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8' })
  res.end(JSON.stringify(value))
}
const isAdmin = req => {
  const h = req.headers.authorization || ''
  const url = new URL(req.url, 'http://x')
  return h === `Bearer ${ADMIN_TOKEN}` || url.searchParams.get('token') === ADMIN_TOKEN
}
const serveFile = (res, path, notFound = 404) => {
  try {
    const data = readFileSync(path)
    res.writeHead(200, { 'content-type': TYPES[extname(path).toLowerCase()] ?? 'application/octet-stream' })
    res.end(data)
  } catch {
    res.writeHead(notFound, { 'content-type': 'text/plain' })
    res.end('not found')
  }
}
const readBody = (req, res, limit, then) => {
  const chunks = []
  let size = 0
  let dead = false
  req.on('data', c => {
    if (dead) return
    size += c.length
    if (size > limit) {
      dead = true
      json(res, 413, { error: 'the meme is too large (8MB max)' })
      req.destroy()
      return
    }
    chunks.push(c)
  })
  req.on('end', () => { if (!dead) then(Buffer.concat(chunks)) })
}

// ── routes ───────────────────────────────────────────────────────────────────
createServer((req, res) => {
  const url = new URL(req.url, 'http://x')

  if (req.method === 'POST' && url.pathname === '/api/apply') {
    return readBody(req, res, MAX_BODY, body => {
      const form = parseMultipart(body, req.headers['content-type'] ?? '')
      const address = (form?.get('address')?.value ?? '').trim().toLowerCase()
      const meme = form?.get('meme')
      if (!isEth(address)) return json(res, 400, { error: 'a valid ethereum address is required' })
      const kind = meme?.data?.length ? sniff(meme.data) : null
      if (!kind) return json(res, 400, { error: 'attach a png, jpg or jpeg image' })
      // One submission per address, permanently: an anonymous resubmit
      // must never be able to replace a meme or reset a decision (a
      // replaced-and-pending row drops out of the approved export).
      const existing = db.prepare('SELECT 1 FROM submissions WHERE address = ?').get(address)
      if (existing) return json(res, 409, { error: 'this address has already submitted a meme' })
      const ext = kind === 'image/png' ? '.png' : '.jpg'
      const name = address.slice(2, 14) + '-' + randomBytes(4).toString('hex') + ext
      writeFileSync(join(MEMES, name), meme.data, { mode: 0o600 })
      db.prepare(
        'INSERT INTO submissions (address, meme_file, meme_type, status) VALUES (?, ?, ?, ?)',
      ).run(address, name, kind, 'pending')
      json(res, 200, { ok: true })
    })
  }

  if (req.method === 'GET' && url.pathname === '/api/submissions') {
    if (!isAdmin(req)) return json(res, 401, { error: 'admin token required' })
    const rows = db.prepare('SELECT id, address, meme_file, meme_type, status FROM submissions ORDER BY id').all()
    return json(res, 200, rows.map(r => ({ ...r, meme: `/memes/${r.meme_file}` })))
  }

  if (req.method === 'PATCH' && url.pathname.startsWith('/api/submissions/')) {
    if (!isAdmin(req)) return json(res, 401, { error: 'admin token required' })
    const id = Number(url.pathname.split('/').pop())
    if (!Number.isInteger(id)) return json(res, 400, { error: 'bad id' })
    return readBody(req, res, 4096, body => {
      let status
      try { ({ status } = JSON.parse(body.toString() || '{}')) } catch {}
      if (!['approved', 'denied', 'pending'].includes(status)) {
        return json(res, 400, { error: 'status must be approved, denied or pending' })
      }
      const r = db.prepare('UPDATE submissions SET status = ? WHERE id = ?').run(status, id)
      return json(res, r.changes ? 200 : 404, r.changes ? { ok: true } : { error: 'not found' })
    })
  }

  if (req.method === 'GET' && url.pathname === '/api/export.csv') {
    if (!isAdmin(req)) return json(res, 401, { error: 'admin token required' })
    const rows = db.prepare("SELECT address FROM submissions WHERE status = 'approved' ORDER BY id").all()
    res.writeHead(200, {
      'content-type': 'text/csv; charset=utf-8',
      'content-disposition': 'attachment; filename="greenlist.csv"',
    })
    res.end(rows.map(r => r.address).join('\n') + (rows.length ? '\n' : ''))
    return
  }

  if (url.pathname === '/') return serveFile(res, join(PUBLIC, 'index.html'))
  if (url.pathname === '/collection') return serveFile(res, join(PUBLIC, 'collection.html'))
  if (url.pathname.startsWith('/420/')) {
    const rel = url.pathname.slice('/420/'.length)
    // only the byte-exact compiler + the embedded 420 art state
    if (!/^\w+\.js$/.test(rel) || !['compiler.js', 'defaults.js'].includes(rel)) {
      res.writeHead(404); return res.end()
    }
    return serveFile(res, join(STUDIO, rel === 'compiler.js' ? rel : join('src', rel)))
  }
  if (url.pathname === '/admin') return serveFile(res, join(PUBLIC, 'admin.html'))
  if (url.pathname === '/app.css') return serveFile(res, join(PUBLIC, 'app.css'))
  if (url.pathname === '/app.js') return serveFile(res, join(PUBLIC, 'app.js'))
  if (url.pathname.startsWith('/memes/')) {
    const name = url.pathname.slice('/memes/'.length)
    if (!/^[\w-]+\.(png|jpe?g)$/.test(name)) { res.writeHead(400); return res.end() }
    return serveFile(res, join(MEMES, name))
  }
  if (url.pathname.startsWith('/alt/')) {
    const rel = url.pathname.slice('/alt/'.length)
    if (!/^[\w./-]+$/.test(rel) || rel.includes('..')) { res.writeHead(400); return res.end() }
    return serveFile(res, join(ALT, rel))
  }
  res.writeHead(404, { 'content-type': 'text/plain' })
  res.end('not found')
}).listen(PORT, '127.0.0.1', () => {
  console.log(`greenlist app on http://127.0.0.1:${PORT} — admin at /admin`)
})
