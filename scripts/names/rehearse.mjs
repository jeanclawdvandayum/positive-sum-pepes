/** End-to-end rehearsal: real Base Sepolia contracts (live reads or a local fork) -> actual
 * verifier HTTP response -> canonical WNS on a LOCAL Ethereum Anvil fork.
 * Every mutation client is checked for loopback URL, chain 31337 and Anvil. */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import { createPublicClient, createWalletClient, http, parseAbi, keccak256, decodeAbiParameters, parseAbiParameters } from 'viem'
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts'
import { createPermitServer } from './server.mjs'
import { issueNamePermit } from './verifier.mjs'
import { readNameRegistration, nameRegistrarAbi, nameCommitment } from '../../frontend/src/lib/nameRegistration.ts'
import { readVerifiedName, WNS_ADDRESS, TEST_NAME_PARENT_ID } from '../../frontend/src/lib/weiNames.ts'
const url = process.env.NAMES_REHEARSAL_RPC || 'http://127.0.0.1:8548'
const parsed = new URL(url)
assert.equal(parsed.protocol, 'http:'); assert(['127.0.0.1', 'localhost'].includes(parsed.hostname))
const destination = createPublicClient({ transport: http(url, { timeout: 15000, retryCount: 0 }) })
assert.equal(await destination.getChainId(), 31337)
assert.match(await destination.request({ method: 'web3_clientVersion' }), /anvil/i)
assert.equal(keccak256(await destination.getCode({ address: WNS_ADDRESS })), '0x5b791c832d4373a8d4f977c37d6973a5dbe0924c6d287a2effaa549be31c0221')
const admin = '0x1d52Ad18c074b8125fBCFDFcD01773c6BEdbd88A'
const bob = '0x0000000000000000000000000000000000000B0b'
const signer = privateKeyToAccount(generatePrivateKey()) // disposable, no funds
const sourceUrl = process.env.NAMES_REHEARSAL_SOURCE_RPC || 'https://sepolia.base.org'
const source = createPublicClient({ transport: http(sourceUrl, { timeout: 10000, retryCount: 0 }) })
assert.equal(await source.getChainId(), 84532)
const sourceIsFork = ['127.0.0.1', 'localhost'].includes(new URL(sourceUrl).hostname)
if (sourceIsFork) {
  assert.match(await source.request({ method: 'web3_clientVersion' }), /anvil/i)
  // Preserve real PSP storage from the pinned source snapshot, while mining
  // local blocks to exercise fresh/finalized RPC handling without wall waits.
  const now = Math.floor(Date.now() / 1000)
  await source.request({ method: 'evm_setNextBlockTimestamp', params: [now - 200] })
  await source.request({ method: 'anvil_mine', params: ['0xb4', '0x1'] })
}

const factory = '0xc79b74dacf99a82f1b1e847948338f9263913a59'
const artifact = name => JSON.parse(fs.readFileSync(`out/${name}.sol/${name}.json`, 'utf8'))
const wallet = account => createWalletClient({ account, transport: http(url) })
const send = async (who, params) => {
  const hash = await wallet(who).writeContract({ ...params, chain: null })
  const receipt = await destination.waitForTransactionReceipt({ hash })
  assert.equal(receipt.status, 'success'); return receipt
}
for (const who of [admin, bob]) {
  await destination.request({ method: 'anvil_impersonateAccount', params: [who] })
  await destination.request({ method: 'anvil_setBalance', params: [who, '0x8ac7230489e80000'] })
}
async function deploy(name, args) {
  const data = artifact(name)
  const hash = await wallet(admin).deployContract({ abi: data.abi, bytecode: data.bytecode.object, args, chain: null })
  const receipt = await destination.waitForTransactionReceipt({ hash })
  assert.equal(receipt.status, 'success'); assert(receipt.contractAddress)
  return receipt.contractAddress
}
let server
try {
  const gate = await deploy('PSPRemoteNameGate', [admin, signer.address, 84532n, factory])
  const registrar = await deploy('PSPNameRegistrar', [WNS_ADDRESS, TEST_NAME_PARENT_ID, admin, gate])
  const ns = { chainId: 31337, names: WNS_ADDRESS, parentId: TEST_NAME_PARENT_ID, parentLabel: 'pepetesters', registrar }
  const config = { namespace: ns, sourceChainId: 84532, factory, gate }
  const wns = { address: WNS_ADDRESS, abi: parseAbi(['function safeTransferFrom(address,address,uint256)', 'function ownerOf(uint256) view returns (address)']) }
  await send(admin, { ...wns, functionName: 'safeTransferFrom', args: [admin, registrar, TEST_NAME_PARENT_ID] })
  const reg = { address: registrar, abi: nameRegistrarAbi }
  await send(admin, { address: registrar, abi: artifact('PSPNameRegistrar').abi, functionName: 'setRegistrationEnabled', args: [true] })
  const block = await destination.getBlock()
  // At a historical fork there is room to make the reservation mature without
  // sleeping or pretending that the live source chain has advanced.
  const now = Math.floor(Date.now() / 1000)
  assert(Number(block.timestamp) < now - 90, 'Start a fresh fork at the documented historical block.')
  await destination.request({ method: 'evm_setNextBlockTimestamp', params: [now - 90] })
  const plan = { label: `psp-verifier-${now.toString(36)}`, salt: generatePrivateKey() }
  const paid = { label: `psp-paid-${now.toString(36)}`, salt: generatePrivateKey() }
  await send(admin, { ...reg, functionName: 'commit', args: [nameCommitment(ns, admin, plan)] })
  await send(bob, { ...reg, functionName: 'commit', args: [nameCommitment(ns, bob, paid)] })
  await destination.request({ method: 'evm_setNextBlockTimestamp', params: [now] })
  await destination.request({ method: 'evm_mine' })
  const state = await readNameRegistration(destination, ns, factory, admin, undefined, { client: source, chainId: 84532 })
  assert.equal(state.price, 0n, 'The chosen snapshot must contain a funded PSP NFT for the test wallet.')
  const [roundId, pepeId] = decodeAbiParameters(parseAbiParameters('uint256,uint256'), state.proof)
  server = createPermitServer({ origins: ['http://127.0.0.1:4173'], issue: (input, signal) => issueNamePermit({ destination, source, signer, config, signal }, input) })
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
  const response = await fetch(`http://127.0.0.1:${server.address().port}/permit`, { method: 'POST',
    headers: { Origin: 'http://127.0.0.1:4173', 'Content-Type': 'application/json' },
    body: JSON.stringify({ account: admin, roundId: roundId.toString(), pepeId: pepeId.toString() }) })
  const permit = await response.json()
  assert.equal(response.status, 200, JSON.stringify(permit))
  assert.equal(await destination.readContract({ ...reg, functionName: 'registrationPrice', args: [admin, permit.proof] }), 0n)
  const freeReceipt = await send(admin, { ...reg, functionName: 'register', args: [plan.label, plan.salt, permit.proof], value: 0n })
  await assert.rejects(destination.readContract({ ...reg, functionName: 'registrationPrice', args: [admin, permit.proof] }), 'consumed permit replay')
  const paidReceipt = await send(bob, { ...reg, functionName: 'register', args: [paid.label, paid.salt, '0x'], value: 500000000000000n })
  assert.equal(await readVerifiedName(destination, ns, admin), `${plan.label}.pepetesters.wei`)
  assert.equal(await readVerifiedName(destination, ns, bob), `${paid.label}.pepetesters.wei`)
  assert.equal(await destination.getBalance({ address: registrar }), 500000000000000n)
  await send(admin, { address: registrar, abi: artifact('PSPNameRegistrar').abi, functionName: 'recoverParent', args: [admin] })
  assert.equal((await destination.readContract({ ...wns, functionName: 'ownerOf', args: [TEST_NAME_PARENT_ID] })).toLowerCase(), admin.toLowerCase())
  console.log(JSON.stringify({ result: 'PASS: Base Sepolia PSP state -> HTTP permit -> local canonical WNS free/paid mint, display, replay rejection and parent recovery',
    sourceIsFork, sourceChainId: 84532, sourceFactory: factory, roundId: roundId.toString(), pepeId: pepeId.toString(),
    sourceFinalizedBlock: permit.sourceBlock, destinationChainId: 31337, gate, registrar,
    freeGas: freeReceipt.gasUsed.toString(), paidGas: paidReceipt.gasUsed.toString(),
    realDomainsTransferred: false, mainnetTransactionsBroadcast: false }, null, 2))
} finally {
  if (server) await new Promise(resolve => { server.closeAllConnections(); server.close(resolve) })
  for (const who of [admin, bob]) await destination.request({ method: 'anvil_stopImpersonatingAccount', params: [who] })
}
