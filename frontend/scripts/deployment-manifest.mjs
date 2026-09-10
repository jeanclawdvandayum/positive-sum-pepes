/** Read-only Base Sepolia release inspection. Usage:
 * PSP_RPC_URL=... PSP_ZAPIN=... PSP_ZAPOUT=... PSP_FAUCET=... PSP_REINVESTOR=...
 * PSP_FACTORY_CREATION_TX=... node --experimental-strip-types frontend/scripts/deployment-manifest.mjs FACTORY OUTPUT.json [FRONTEND.env]
 * Never pass private keys. Rehearsals require PSP_MANIFEST_REHEARSAL=1 and a loopback Anvil RPC.
 */
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFileSync } from 'node:child_process'
import { createPublicClient, http, isAddress, keccak256, parseAbi } from 'viem'
import { factoryAbi, controllerAbi, hookAbi, stakerAbi } from '../src/lib/abi.ts'
import { BASE_SEPOLIA_POOL_MANAGER, releaseContext, assertRuntimeMatches, verifyFactoryCreation, assertTimingProfile, renderFrontendEnv } from './deployment-manifest-lib.mjs'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
const addressGetter = name => parseAbi([`function ${name}() view returns(address)`])
const uintGetter = name => parseAbi([`function ${name}() view returns(uint256)`])
const boolGetter = name => parseAbi([`function ${name}() view returns(bool)`])
const loadArtifact = (name, file = name) => JSON.parse(fs.readFileSync(path.join(root, 'out', `${file}.sol`, `${name}.json`)))
const equalAddress = (a, b) => typeof a === 'string' && typeof b === 'string' && a.toLowerCase() === b.toLowerCase()
// RPC errors can contain provider credentials. Give context without printing the transport's error/cause.
async function checked(context, operation) {
  try { return await operation() } catch { throw Error(`Chain inspection failed: ${context}`) }
}

async function main() {
  const [factory, output, frontendOutput, ...extra] = process.argv.slice(2)
  if (!isAddress(factory || '') || !output || extra.length || !process.env.PSP_RPC_URL) {
    throw Error('Provide FACTORY OUTPUT.json [FRONTEND.env] and PSP_RPC_URL')
  }
  if (frontendOutput) {
    const target = path.resolve(frontendOutput)
    const frontendRoot = path.join(root, 'frontend')
    if (path.dirname(target) === frontendRoot && /^\.env(?:\.|$)/.test(path.basename(target))) {
      throw Error('Export to a review artifact outside active frontend .env files')
    }
    if (target === path.resolve(output)) throw Error('Manifest and frontend env need separate output paths')
  }
  for (const target of [output, frontendOutput].filter(Boolean)) {
    if (fs.existsSync(target)) throw Error(`Output already exists: ${target}`)
  }
  const client = createPublicClient({ transport: http(process.env.PSP_RPC_URL) })
  const chainId = await checked('chain ID', () => client.getChainId())
  const rehearsalRequested = process.env.PSP_MANIFEST_REHEARSAL === '1'
  const clientVersion = rehearsalRequested ? await checked('client version', () => client.request({ method: 'web3_clientVersion' })) : ''
  const revision = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim()
  const sourceDirty = execFileSync('git', ['status', '--porcelain', '--untracked-files=all', '--', '.', ':(exclude)broadcast/**'], { cwd: root, encoding: 'utf8' }).trim().length > 0
  const { rehearsal, rehearsalRpc } = releaseContext({ rpcUrl: process.env.PSP_RPC_URL, chainId, clientVersion, rehearsalRequested, sourceDirty })
  const block = await checked('snapshot block', () => client.getBlock())
  const read = (address, abi, functionName, args = []) => checked(`${functionName} at ${address}`, () => client.readContract({ address, abi, functionName, args, blockNumber: block.number }))
  const roundId = await read(factory, factoryAbi, 'currentRoundId')
  if (roundId === 0n) throw Error('Factory genesis birth has not completed')
  const [token, controller, hook, destroyed, name, symbol] = await read(factory, factoryAbi, 'rounds', [roundId])
  const staker = await read(controller, controllerAbi, 'staker')
  const mix = await read(factory, factoryAbi, 'mixETH')
  const registry = await read(factory, factoryAbi, 'referralRegistryOf', [roundId])
  const addresses = { factory, token, controller, hook, staker, mix, registry }
  for (const [name, variable] of Object.entries({ zapIn: 'PSP_ZAPIN', zapOut: 'PSP_ZAPOUT', faucet: 'PSP_FAUCET', reinvestor: 'PSP_REINVESTOR' })) {
    const value = process.env[variable]
    if (value) {
      if (!isAddress(value)) throw Error(`Invalid ${variable}`)
      addresses[name] = value
    } else if (frontendOutput) throw Error(`Frontend export requires ${variable}`)
  }
  for (const name of ['descriptor', 'poolManager', 'hookDeployer', 'controllerDeployer', 'stakerDeployer', 'tokenDeployer']) {
    addresses[name] = await read(factory, addressGetter(name), name)
  }
  if (!equalAddress(addresses.poolManager, BASE_SEPOLIA_POOL_MANAGER)) throw Error('Factory uses a different Base Sepolia PoolManager')
  const owner = await read(factory, addressGetter('owner'), 'owner')
  addresses.hookInitCode = await read(addresses.hookDeployer, addressGetter('initOracle'), 'initOracle')
  addresses.hookCodeFirst = await read(addresses.hookInitCode, addressGetter('first'), 'first')
  addresses.hookCodeSecond = await read(addresses.hookInitCode, addressGetter('second'), 'second')
  addresses.artData = await read(addresses.descriptor, addressGetter('artData'), 'artData')
  const codeHashes = {}, codes = {}
  for (const [key, address] of Object.entries(addresses)) {
    const code = await checked(`deployed code for ${key}`, () => client.getCode({ address, blockNumber: block.number }))
    if (!code || code === '0x') throw Error(`Missing deployed code: ${key}`)
    codes[key] = code
    codeHashes[key] = keccak256(code)
  }
  // Counterparty/timing immutables are checked via the getters below. Exact
  // executable bytes and metadata distinguish fresh source from legacy APIs
  // with unchanged version numbers (including block-hash genesis art).
  const artifacts = {}
  const runtimeContracts = { factory: 'PSPFactory', token: 'PSPToken', controller: 'RoundController', hook: 'CurveHook', staker: 'PSPStaker', registry: 'PSPReferralRegistry', mix: 'SepoliaMixETH', descriptor: 'PepeExpandedDescriptor', hookDeployer: 'HookDeployer', controllerDeployer: 'ControllerDeployer', stakerDeployer: 'StakerDeployer', tokenDeployer: 'TokenDeployer', hookInitCode: 'HookInitCode', zapIn: 'PSPZapIn', zapOut: 'PSPZapOut', faucet: 'MixETHFaucet', reinvestor: 'PSPReinvestor' }
  for (const [key, contract] of Object.entries(runtimeContracts)) {
    if (!addresses[key]) continue
    const artifact = loadArtifact(contract, contract === 'TokenDeployer' ? 'ControllerDeployer' : contract)
    assertRuntimeMatches(codes[key], artifact, key)
    artifacts[key] = { contract, runtimeMatchesIgnoringImmutables: true, artifactRuntimeHash: keccak256(artifact.deployedBytecode.object) }
  }
  const artHex = fs.readFileSync(path.join(root, 'src/art/ExpandedPepeArt.sol'), 'utf8').match(/DATA = hex"([0-9a-fA-F]+)"/)[1]
  if (codes.artData.toLowerCase() !== ('0x00' + artHex).toLowerCase()) throw Error('Expanded art storage differs from release source')
  if (await read(addresses.descriptor, uintGetter('ART_VERSION'), 'ART_VERSION') !== 2n) throw Error('Expanded descriptor version mismatch')
  const shards = [codes.hookCodeFirst, codes.hookCodeSecond]
  if (shards.some(code => !code.startsWith('0x00'))) throw Error('Hook code shard is not STOP-prefixed')
  const storedCreationCode = '0x' + shards.map(code => code.slice(4)).join('')
  if (storedCreationCode.toLowerCase() !== loadArtifact('CurveHook').bytecode.object.toLowerCase()) throw Error('On-chain hook creation code differs from the release artifact')

  const wiring = {}
  async function wire(role, getter, expected) {
    if (!expected || !equalAddress(await read(addresses[role], addressGetter(getter), getter), expected)) throw Error(`${role}.${getter} wiring mismatch`)
    wiring[`${role}.${getter}`] = expected
  }
  for (const [role, getter, expected] of [
    ['controller', 'factory', factory], ['controller', 'owner', factory], ['controller', 'pspToken', token], ['controller', 'mixETH', mix], ['controller', 'hook', hook],
    ['token', 'factory', factory], ['token', 'controller', controller],
    ['staker', 'controller', controller], ['staker', 'psp', token], ['staker', 'descriptor', addresses.descriptor],
    ['hook', 'controller', controller], ['hook', 'referralRegistry', registry], ['hook', 'poolManager', addresses.poolManager],
    ['registry', 'staker', staker],
  ]) await wire(role, getter, expected)
  const deployerCutTo = await read(factory, addressGetter('deployerCutTo'), 'deployerCutTo')
  await wire('hook', 'deployerCutTo', deployerCutTo)
  if (await read(controller, uintGetter('factoryRoundId'), 'factoryRoundId') !== roundId) throw Error('Controller round ID wiring mismatch')
  if (await read(factory, boolGetter('reservationActive'), 'reservationActive')) throw Error('Factory has an unfinished birth reservation')
  if (!await read(factory, boolGetter('useSine'), 'useSine')) throw Error('Factory is not configured for sine rounds')
  for (const role of ['zapIn', 'zapOut']) if (addresses[role]) {
    await wire(role, 'mixETH', mix)
    await wire(role, 'poolManager', addresses.poolManager)
  }
  if (addresses.faucet) await wire('faucet', 'mixETH', mix)
  if (addresses.reinvestor) for (const [getter, target] of [['staker', staker], ['psp', token], ['mix', mix], ['zapIn', addresses.zapIn]]) await wire('reinvestor', getter, target)

  const params = await read(hook, parseAbi(['function sineParams() view returns(uint256 p0,uint256 preK,uint256 pTarget,uint256 targetReserve,uint24 ampBps)']), 'sineParams')
  const minimumBuy = await read(hook, hookAbi, 'MIN_BUY_INPUT')
  const timePerUnit = await read(hook, hookAbi, 'TIME_PER_UNIT')
  if (minimumBuy !== 5_000_000_000_000_000n || timePerUnit !== 260n) throw Error('Deployment does not match approved game rules')
  const features = {}
  for (const [role, getter] of [['controller', 'PREDEPOSIT_RULES_VERSION'], ['registry', 'PURCHASE_REFERRAL_VERSION'], ['staker', 'NFT_INTERFACE_VERSION'], ['staker', 'PEPE_DNA_VERSION'], ...(addresses.reinvestor ? [['reinvestor', 'ATTRIBUTION_VERSION']] : [])]) {
    const version = await read(addresses[role], uintGetter(getter), getter)
    if (version !== (getter === 'PEPE_DNA_VERSION' ? 2n : 1n)) throw Error(`Unsupported ${getter}`)
    features[getter] = version
  }
  const supportsAbi = parseAbi(['function supportsInterface(bytes4) view returns(bool)'])
  features.nftInterfaces = {}
  for (const [label, id] of Object.entries({ erc165: '0x01ffc9a7', erc721: '0x80ac58cd', metadata: '0x5b5e139f', invalid: '0xffffffff' })) {
    const supported = await read(staker, supportsAbi, 'supportsInterface', [id])
    if (supported !== (label !== 'invalid')) throw Error(`NFT ${label} interface mismatch`)
    features.nftInterfaces[label] = supported
  }
  features.genesisPreview = { wallet: '0x0000000000000000000000000000000000000001', dna: await read(staker, stakerAbi, 'genesisPepeDna', ['0x0000000000000000000000000000000000000001']) }
  features.genesisArt = 'round-block-hash-seed-with-wallet-and-collision-resolution'
  await read(staker, stakerAbi, 'dnaOf', [0n])
  if (await read(staker, stakerAbi, 'isPepeAvailable', [0n])) throw Error('Zero chosen NFT ID is unexpectedly available')
  const timings = {}
  for (const name of ['PREDEPOSIT_DURATION', 'VEST_DURATION', 'PREDEPOSIT_CAP_PER_WALLET', 'PREDEPOSIT_CAP', 'predepositStartTime']) timings[name] = await read(controller, uintGetter(name), name)
  timings.detWindow = await read(hook, uintGetter('detWindow'), 'detWindow')
  timings.packed = await read(factory, uintGetter('roundTimings'), 'roundTimings')
  timings.epochSize = await read(staker, uintGetter('epochSize'), 'epochSize')
  assertTimingProfile(timings)
  const feeBps = {}
  for (const [name, expected] of Object.entries({ FEE_BPS_PRE_WAVE: 1000n, FEE_BPS_ABOVE_WAVE: 250n, STAKER_BPS: 6000n, POT_BPS: 3500n, REFERRAL_LEG_BPS: 500n, DEPLOYER_BPS: 100n })) {
    feeBps[name] = await read(hook, uintGetter(name), name)
    if (feeBps[name] !== expected) throw Error(`${name} differs from approved fee rules`)
  }
  const mode = await read(hook, hookAbi, 'mode')
  let deployment
  if (process.env.PSP_FACTORY_CREATION_TX) {
    if (!/^0x[0-9a-f]{64}$/i.test(process.env.PSP_FACTORY_CREATION_TX)) throw Error('Invalid PSP_FACTORY_CREATION_TX')
    const receipt = await checked('factory creation receipt', () => client.getTransactionReceipt({ hash: process.env.PSP_FACTORY_CREATION_TX }))
    const creationBlock = await checked('factory creation block', () => client.getBlock({ blockNumber: receipt.blockNumber }))
    deployment = verifyFactoryCreation({ factory, receipt, canonicalBlockHash: creationBlock.hash, snapshotBlock: block.number })
  } else if (frontendOutput) throw Error('Frontend export requires PSP_FACTORY_CREATION_TX from the confirmed deployment')
  // Detect a reorganization while collecting reads at the pinned block.
  const finalBlock = await checked('snapshot recheck', () => client.getBlock({ blockNumber: block.number }))
  if (finalBlock.hash !== block.hash) throw Error('Snapshot block changed during inspection; retry')
  const manifest = { schema: 3, chainId, block: block.number, blockHash: block.hash, revision, sourceDirty, rehearsal, owner, deployerCutTo, addresses, codeHashes, artifacts, hookCreationCodeMatchesArtifact: true, deployment, round: { roundId, name, symbol, destroyed, mode }, params, timings, rules: { minimumBuy, minimumPredeposit: 1n, timePerUnit, feeBps }, features, wiring, sourceVerification: 'Runtime matches local artifacts except immutable slots; see companion explorer verification record' }
  const frontendEnv = frontendOutput ? renderFrontendEnv(manifest, rehearsalRpc) : undefined
  for (const target of [output, frontendOutput].filter(Boolean)) fs.mkdirSync(path.dirname(target), { recursive: true })
  fs.writeFileSync(output, JSON.stringify(manifest, (_, value) => typeof value === 'bigint' ? value.toString() : value, 2) + '\n', { flag: 'wx' })
  if (frontendOutput) fs.writeFileSync(frontendOutput, frontendEnv, { flag: 'wx' })
  console.log(`Manifest written: ${output}`)
  if (frontendOutput) console.log(`Frontend review env written: ${frontendOutput}`)
}
main().catch(error => { console.error(error.message); process.exitCode = 1 })
