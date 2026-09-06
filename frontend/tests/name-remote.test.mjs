import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readNameRegistration, NAME_REGISTRATION_FEE } from '../src/lib/nameRegistration.ts'
import { requestNamePermit } from '../src/lib/namePermit.ts'
import { TEST_NAME_PARENT_ID, WNS_ADDRESS } from '../src/lib/weiNames.ts'
const account = '0x1111111111111111111111111111111111111111'
const factory = '0x2222222222222222222222222222222222222222'
const registrar = '0x3333333333333333333333333333333333333333'
const gate = '0x4444444444444444444444444444444444444444'
const ns = { chainId: 1, parentId: TEST_NAME_PARENT_ID, names: WNS_ADDRESS, parentLabel: 'pepetesters', registrar }
function clients(options = {}) {
  const seen = []
  const destination = {
    getChainId: async () => 1,
    getBlock: async () => ({ number: 100n, timestamp: 2000n }),
    readContract: async c => {
      seen.push(['destination', c])
      const values = { REGISTRAR_VERSION: 2n, REGISTRATION_FEE: NAME_REGISTRATION_FEE, MIN_COMMIT_AGE: 60n, MAX_COMMIT_AGE: 86400n,
        names: WNS_ADDRESS, parentId: TEST_NAME_PARENT_ID, registrationEnabled: true, eligibilityGate: gate,
        commitments: [`0x${'00'.repeat(32)}`, 0n, 1n, 1n], commitNonce: 0n, parentEpoch: 1n, gateVersion: 1n,
        ownerOf: registrar, resolve: registrar, records: ['pepetesters', 0n, 99999n, 1n, 0n], GATE_VERSION: 1n,
        sourceChainId: options.gateChain ?? 84532n, factory, signer: options.signer ?? account, signerEpoch: 1n, MAX_PERMIT_AGE: 180n,
        registrationPrice: NAME_REGISTRATION_FEE }
      assert(Object.hasOwn(values, c.functionName), `game read leaked onto Ethereum: ${c.functionName}`)
      return values[c.functionName]
    },
  }
  const source = {
    getChainId: async () => options.sourceChain ?? 84532,
    getBlock: async () => ({ number: 90n, timestamp: options.sourceTime ?? BigInt(Math.floor(Date.now() / 1000)) }),
    readContract: async c => {
      seen.push(['source', c])
      if (options.fail) throw Error('source RPC unavailable')
      const values = { currentRoundId: 1n, rounds: [account, factory, account, true, 'PSP', 'PSP'], staker: factory,
        balanceOf: options.empty ? 0n : 1n, tokenOfOwnerByIndex: 0n, ownerOf: account, positions: [1n, 0n, 0n, 0n, 0n] }
      assert(Object.hasOwn(values, c.functionName)); return values[c.functionName]
    },
  }
  return { destination, source, seen }
}
const quote = c => readNameRegistration(c.destination, ns, factory, account, undefined, { client: c.source, chainId: 84532 })
test('hybrid quote keeps PSP reads on source and WNS reads on destination', async () => {
  const c = clients(), result = await quote(c)
  assert.equal(result.price, 0n)
  assert.equal(result.proof.length, 130, 'NFT hint is exchanged for a permit at reveal')
  assert(c.seen.every(([chain, read]) => read.blockNumber === (chain === 'source' ? 90n : 100n)))
  assert(!c.seen.some(([, read]) => read.functionName === 'registrationPrice'), 'an unsigned source hint is never submitted as a remote permit')
})
test('empty wallets use exact paid path while source failures, wrong chain or revoked signer block free quoting', async () => {
  assert.equal((await quote(clients({ empty: true }))).price, NAME_REGISTRATION_FEE)
  for (const change of [{ fail: true }, { sourceTime: 1n }, { sourceChain: 1 }, { gateChain: 8453n }, { signer: `0x${'00'.repeat(20)}` }])
    await assert.rejects(quote(clients(change)))
})
test('permit transport accepts only a bounded, complete contract proof', async t => {
  const old = globalThis.fetch
  t.after(() => { globalThis.fetch = old })
  const proof = `0x${'ab'.repeat(512)}`
  globalThis.fetch = async (_url, request) => {
    assert.deepEqual(JSON.parse(request.body), { account, roundId: '1', pepeId: '0' })
    return new Response(JSON.stringify({ proof }))
  }
  assert.equal(await requestNamePermit('https://verifier.example', account, 1n, 0n), proof)
  for (const body of [JSON.stringify({ proof: '0x' }), 'x'.repeat(4097), '{}', '{']) {
    globalThis.fetch = async () => new Response(body)
    await assert.rejects(requestNamePermit('https://verifier.example', account, 1n, 0n))
  }
})
test('verifier outages and unsettled ownership produce errors rather than a paid permit', async t => {
  const old = globalThis.fetch
  t.after(() => { globalThis.fetch = old })
  for (const status of [409, 429, 503]) {
    globalThis.fetch = async () => new Response('{}', { status })
    await assert.rejects(requestNamePermit('https://verifier.example', account, 1n, 0n))
  }
})
