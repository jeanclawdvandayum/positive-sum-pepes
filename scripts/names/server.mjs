import http from 'node:http'
import fs from 'node:fs'
import { pathToFileURL } from 'node:url'
import { createPublicClient, http as rpc, isAddress } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { childNameId, WEI_NODE, WNS_ADDRESS } from '../../frontend/src/lib/weiNames.ts'
import { issueNamePermit, PermitError } from './verifier.mjs'

export function createPermitServer({ issue, origins, maxConcurrent = 4, rateLimit = 10, maxBuckets = 4096 }) {
  let active = 0
  const buckets = new Map()
  return http.createServer({ requestTimeout: 5000, headersTimeout: 5000, maxHeaderSize: 8192 }, async (req, res) => {
    const reply = (code, data) => {
      res.writeHead(code, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' })
      res.end(JSON.stringify(data))
    }
    const origin = req.headers.origin
    if (typeof origin !== 'string' || !origins.includes(origin)) return reply(403, { error: 'Origin rejected.' })
    res.setHeader('Access-Control-Allow-Origin', origin)
    res.setHeader('Vary', 'Origin')
    if (req.url !== '/permit') return reply(404, { error: 'Unknown endpoint.' })
    if (req.method === 'OPTIONS') {
      res.setHeader('Access-Control-Allow-Methods', 'POST')
      res.setHeader('Access-Control-Allow-Headers', 'Content-Type')
      res.writeHead(204); return res.end()
    }
    if (req.method !== 'POST') return reply(405, { error: 'POST required.' })
    if (!/^application\/json(?:;|$)/i.test(req.headers['content-type'] ?? '')) return reply(415, { error: 'JSON required.' })
    // Never trust caller-supplied X-Forwarded-For. A local reverse proxy shares
    // one bucket unless it enforces its own per-client limits upstream.
    const ip = req.socket.remoteAddress ?? 'unknown', now = Date.now()
    for (const [key, bucket] of buckets) if (bucket.until <= now) buckets.delete(key)
    const bucket = buckets.get(ip) ?? { count: 0, until: now + 60_000 }
    if (active >= maxConcurrent || bucket.count >= rateLimit || (!buckets.has(ip) && buckets.size >= maxBuckets)) {
      res.setHeader('Retry-After', '60'); return reply(429, { error: 'Try again shortly.' })
    }
    bucket.count++; buckets.set(ip, bucket); active++
    req.setTimeout(5000, () => req.destroy())
    let size = 0, body = ''
    const bodyTimer = setTimeout(() => req.destroy(), 5000)
    const abort = new AbortController()
    const timer = setTimeout(() => abort.abort(), 20_000)
    const disconnected = () => { if (!res.writableEnded) abort.abort() }
    res.on('close', disconnected)
    try {
      for await (const chunk of req) {
        size += chunk.length
        if (size > 2048) { reply(413, { error: 'Request too large.' }); return }
        body += chunk.toString('utf8')
      }
      clearTimeout(bodyTimer)
      let input
      try { input = JSON.parse(body) } catch { throw new PermitError(400, 'Invalid JSON.') }
      const result = await issue(input, abort.signal)
      abort.signal.throwIfAborted()
      if (!res.destroyed) reply(200, result)
    } catch (error) {
      // RPC diagnostics can contain provider credentials. Never return/log
      // their raw messages, key material, request bodies or signatures.
      if (!res.destroyed) reply(error instanceof PermitError ? error.status : 503,
        { error: error instanceof PermitError ? error.message : 'Verifier temporarily unavailable.' })
    } finally {
      clearTimeout(bodyTimer); clearTimeout(timer); res.off('close', disconnected); active--
    }
  })
}

export function loadConfig(env = process.env) {
  const required = key => { if (!env[key]) throw Error(`Set ${key}.`); return env[key] }
  const address = key => { const value = required(key); if (!isAddress(value) || BigInt(value) === 0n) throw Error(`Invalid ${key}.`); return value }
  const chain = key => { const id = Number(required(key)); if (!Number.isSafeInteger(id) || id < 1) throw Error(`Invalid ${key}.`); return id }
  const endpoint = key => {
    const value = required(key), url = new URL(value)
    if (url.protocol !== 'https:' && !(url.protocol === 'http:' && ['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)))
      throw Error(`Use HTTPS or a loopback RPC for ${key}.`)
    return value
  }
  const keyFile = required('PSP_NAME_SIGNER_FILE')
  const stat = fs.lstatSync(keyFile)
  if (!stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o077) !== 0 || stat.uid !== process.getuid())
    throw Error('Signer file must be a private file owned by this service account (chmod 600).')
  const key = fs.readFileSync(keyFile, 'utf8').trim()
  if (!/^0x[0-9a-fA-F]{64}$/.test(key)) throw Error('Invalid signer key file.')
  const signer = privateKeyToAccount(key)
  const parentLabel = required('PSP_NAME_PARENT_LABEL')
  if (!/^[a-z0-9-]{1,32}$/.test(parentLabel)) throw Error('Invalid parent label.')
  const config = { sourceChainId: chain('PSP_NAME_SOURCE_CHAIN_ID'), factory: address('PSP_NAME_FACTORY'), gate: address('PSP_NAME_GATE'),
    namespace: { chainId: chain('PSP_NAME_CHAIN_ID'), names: WNS_ADDRESS,
      registrar: address('PSP_NAME_REGISTRAR'), parentId: childNameId(BigInt(WEI_NODE), parentLabel), parentLabel } }
  const origins = required('PSP_NAME_ORIGINS').split(',').map(s => s.trim())
  for (const origin of origins) {
    const url = new URL(origin)
    if (url.origin !== origin || (url.protocol !== 'https:' && !(url.protocol === 'http:' && ['localhost', '127.0.0.1'].includes(url.hostname))))
      throw Error('Name origins must be exact HTTPS origins or loopback development origins.')
  }
  return { config, signer, origins, sourceUrl: endpoint('PSP_NAME_SOURCE_RPC_URL'), destinationUrl: endpoint('PSP_NAME_RPC_URL') }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const { config, signer, origins, sourceUrl, destinationUrl } = loadConfig()
    const server = createPermitServer({ origins, issue: (input, signal) => {
      const client = url => createPublicClient({ transport: rpc(url, { timeout: 8000, retryCount: 0, fetchOptions: { signal } }) })
      return issueNamePermit({ config, signer, source: client(sourceUrl), destination: client(destinationUrl), signal }, input)
    } })
    const port = Number(process.env.PSP_NAME_PORT || 8788)
    if (!Number.isInteger(port) || port < 1 || port > 65535) throw Error('Invalid PSP_NAME_PORT.')
    server.listen(port, '127.0.0.1', () => console.log(`Name verifier listening on 127.0.0.1:${port}; signer ${signer.address}`))
    for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => process.exit(0)))
  } catch (error) { console.error(error.message); process.exitCode = 1 }
}
