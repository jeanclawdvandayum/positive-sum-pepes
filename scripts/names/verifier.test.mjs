import { test } from 'node:test'
import assert from 'node:assert/strict'
import { decodeAbiParameters, parseAbiParameters, recoverTypedDataAddress } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { issueNamePermit, parsePermitRequest } from './verifier.mjs'
import { permitTypedData } from '../../frontend/src/lib/namePermit.ts'
import { TEST_NAME_PARENT_ID, WNS_ADDRESS } from '../../frontend/src/lib/weiNames.ts'

const account = '0x1111111111111111111111111111111111111111'
const factory = '0x2222222222222222222222222222222222222222'
const registrar = '0x3333333333333333333333333333333333333333'
const gate = '0x4444444444444444444444444444444444444444'
const staker = '0x5555555555555555555555555555555555555555'
const signer = privateKeyToAccount(`0x${'ab'.repeat(32)}`)
const hash = `0x${'12'.repeat(32)}`, blockHash = `0x${'34'.repeat(32)}`
const request = { account, roundId: '7', pepeId: '0' }
const config = { sourceChainId: 84532, factory, gate,
  namespace: { chainId: 1, names: WNS_ADDRESS, parentId: TEST_NAME_PARENT_ID, parentLabel: 'pepetesters', registrar } }
function setup(change = {}) {
  const calls = [], signed = []
  const destination = {
    getChainId: async () => change.destChain ?? 1,
    getBlock: async () => ({ number: 100n, timestamp: change.destTime ?? 2000n, hash: blockHash }),
    readContract: async c => {
      calls.push(['destination', c])
      if (change.fail === c.functionName) throw Error('RPC provider credential secret')
      if (Object.hasOwn(change, c.functionName)) return change[c.functionName]
      const values = {
        REGISTRAR_VERSION: 2n, REGISTRATION_FEE: 500000000000000n, MIN_COMMIT_AGE: 60n, MAX_COMMIT_AGE: 86400n,
        names: WNS_ADDRESS, parentId: TEST_NAME_PARENT_ID, registrationEnabled: true, eligibilityGate: gate,
        commitments: [hash, 1900n, 1n, 1n], commitNonce: 1n, parentEpoch: 1n, gateVersion: 1n,
        ownerOf: registrar, resolve: registrar, records: ['pepetesters', 0n, 999999n, 1n, 0n],
        GATE_VERSION: 1n, sourceChainId: 84532n, factory, MAX_PERMIT_AGE: 180n, signer: signer.address, signerEpoch: 1n,
        registrationPrice: 0n,
      }
      assert(Object.hasOwn(values, c.functionName), c.functionName)
      return values[c.functionName]
    },
  }
  const source = {
    getChainId: async () => change.sourceChain ?? 84532,
    getBlock: async c => {
      const latest = c.blockTag === 'latest' || c.blockNumber === 90n
      return { number: latest ? 90n : 80n, timestamp: latest ? change.latestTime ?? 1998n : change.finalTime ?? 1900n,
        hash: change.reorg && c.blockNumber ? hash : blockHash }
    },
    readContract: async c => {
      calls.push(['source', c])
      if (change.fail === c.functionName) throw Error('source RPC unavailable')
      switch (c.functionName) {
        case 'rounds': return [account, factory, account, true, 'PSP', 'PSP']
        case 'staker': return change.differentStaker && c.blockNumber === 90n ? account : staker
        case 'ownerOf': return (change.transferred && c.blockNumber === 90n) || change.operator ? registrar : account
        case 'positions': return [change.empty || (change.withdrawn && c.blockNumber === 90n) ? 0n : 1n, 0n, 0n, 0n, 0n]
      }
      throw Error(`unexpected ${c.functionName}`)
    },
  }
  return { options: { destination, source, signer: { address: signer.address, signTypedData: async data => {
    signed.push(data); return signer.signTypedData(data)
  } }, config, now: () => 2000n }, calls, signed }
}
test('valid finalized and current position creates a wallet, source, name and destination-bound permit', async () => {
  const { options, calls, signed } = setup()
  const result = await issueNamePermit(options, request)
  assert.equal(result.deadline, '2180')
  assert.equal(result.sourceBlock, '80')
  assert.equal(result.proof.length, 1026)
  assert.equal(signed.length, 1)
  const p = signed[0].message
  assert.equal(p.sourceChainId, 84532n); assert.equal(p.factory, factory)
  assert.equal(p.account, account); assert.equal(p.commitment, hash)
  assert.equal(p.registrar, registrar); assert.equal(p.nonce, 1n)
  assert.equal(p.roundId, 7n); assert.equal(p.pepeId, 0n)
  assert.equal(p.sourceBlock, 80n); assert.equal(p.sourceBlockHash, blockHash)
  assert.equal(signed[0].domain.chainId, 1); assert.equal(signed[0].domain.verifyingContract, gate)
  const raw = decodeAbiParameters(parseAbiParameters('address,address,bytes32,uint256,uint256,uint256,uint256,uint256,uint256,uint256,bytes32,uint256,uint256,uint8,bytes32,bytes32'), result.proof)
  const signature = `${raw[14]}${raw[15].slice(2)}${raw[13].toString(16)}`
  assert.equal(await recoverTypedDataAddress({ ...permitTypedData(1, gate, p), signature }), signer.address)
  assert(calls.filter(([chain, c]) => chain === 'source' && c.functionName === 'positions').some(([, c]) => c.blockNumber === 80n))
  assert(calls.filter(([chain, c]) => chain === 'source' && c.functionName === 'positions').some(([, c]) => c.blockNumber === 90n))
  assert.equal(calls.at(-1)[1].blockNumber, undefined, 'final destination validation must be at latest')
})
test('ownership, principal, finality and deployment failures never produce signatures', async () => {
  const cases = [
    { sourceChain: 1 }, { destChain: 84532 }, { registrationEnabled: false }, { ownerOf: account },
    { eligibilityGate: factory }, { signer: account }, { sourceChainId: 1n }, { factory: account }, { MAX_PERMIT_AGE: 181n },
    { commitments: [hash, 1970n, 1n, 1n] }, { commitments: [hash, 1900n, 2n, 1n] }, { commitNonce: 0n },
    { parentEpoch: 2n }, { gateVersion: 2n }, { transferred: true }, { operator: true }, { empty: true }, { withdrawn: true },
    { latestTime: 1939n }, { latestTime: 2016n }, { finalTime: -1601n }, { destTime: 1939n }, { reorg: true },
    { differentStaker: true }, { fail: 'positions' }, { fail: 'REGISTRAR_VERSION' },
  ]
  for (const change of cases) {
    const { options, signed } = setup(change)
    await assert.rejects(issueNamePermit(options, request), JSON.stringify(change, (_, v) => typeof v === 'bigint' ? v.toString() : v))
    assert.equal(signed.length, 0)
  }
})
test('late destination change suppresses even an already signed response', async () => {
  const { options, signed } = setup({ registrationPrice: 500000000000000n })
  await assert.rejects(issueNamePermit(options, request))
  assert.equal(signed.length, 1)
})
test('aborted verification never signs', async () => {
  const { options, signed } = setup()
  options.signal = AbortSignal.abort()
  await assert.rejects(issueNamePermit(options, request))
  assert.equal(signed.length, 0)
})
test('requests cannot select arbitrary networks, contracts, RPC endpoints or malformed identifiers', () => {
  for (const input of [null, [], {}, { ...request, url: 'https://evil.test' }, { ...request, account: [] },
    { ...request, account: '0x0' }, { ...request, roundId: '0' }, { ...request, roundId: '01' },
    { ...request, pepeId: -1 }, { ...request, pepeId: (2n ** 256n).toString() }, { ...request, pepeId: '1e2' }])
    assert.throws(() => parsePermitRequest(input), error => error.status === 400)
  assert.equal(parsePermitRequest({ ...request, pepeId: (2n ** 256n - 1n).toString() }).pepeId, 2n ** 256n - 1n)
})
