/** Pure guards shared by the read-only release inspector and focused tests. */
import { isAddress, keccak256, parseAbi } from 'viem'

export const BASE_SEPOLIA_ID = 84532
export const BASE_SEPOLIA_POOL_MANAGER = '0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408'
const auxiliaryNames = ['zapIn', 'zapOut', 'faucet', 'reinvestor']

/** Read versions before incompatible curve getters. The caller pins every read to one block. */
export async function readSineDeploymentState(read, factory, hook) {
  const uint = (address, name) => read(address, parseAbi([`function ${name}() view returns(uint256)`]), name)
  const addr = (address, name) => read(address, parseAbi([`function ${name}() view returns(address)`]), name)
  const [sineVersion, ticketVersion] = await Promise.all([
    uint(hook, 'SINE_RULES_VERSION'), uint(hook, 'TICKET_RULES_VERSION'),
  ])
  if ((sineVersion !== 2n && sineVersion !== 3n) || ticketVersion !== sineVersion) {
    throw Error('Unsupported or mismatched sine and ticket rules versions')
  }
  const [minimumBuy, timePerUnit, ticketPrice, potBalance] = await Promise.all([
    uint(hook, 'MIN_BUY_INPUT'), uint(hook, 'TIME_PER_UNIT'), uint(hook, 'ticketPrice'), uint(hook, 'potBalance'),
  ])
  if (timePerUnit !== 69n) throw Error('Deployment does not match approved clock rules')
  if (sineVersion === 2n) {
    const params = await read(hook, parseAbi(['function sineParams() view returns(uint256 p0,uint256 preK,uint256 pTarget,uint256 targetReserve,uint24 ampBps)']), 'sineParams')
    const genesisPot = await uint(hook, 'genesisPotBalance')
    const growth = potBalance > genesisPot ? potBalance - genesisPot : 0n
    if (minimumBuy !== 5_000_000_000_000_000n || ticketPrice !== minimumBuy + growth * 21n / 1_000_000n) {
      throw Error('Legacy ticket rules mismatch')
    }
    return { sineVersion, ticketVersion, minimumBuy, timePerUnit, ticketPrice, potBalance, params }
  }
  const [raw, helper, configured, active, factoryLaunchPrice] = await Promise.all([
    read(hook, parseAbi(['function sineV3Info() view returns(uint256 version,uint256 pL,uint256 boot,uint256 lam,uint256 target,uint256 q0,address table)']), 'sineV3Info'),
    addr(factory, 'sineV3Table'),
    read(hook, parseAbi(['function sineConfigured() view returns(bool)']), 'sineConfigured'),
    read(hook, parseAbi(['function sineActive() view returns(bool)']), 'sineActive'),
    uint(factory, 'gameSinePL'),
  ])
  const [version, launchPrice, boot, wavelength, target, genesisSupply, table] = raw
  if (version !== 3n || !isAddress(helper) || /^0x0{40}$/i.test(helper) || table.toLowerCase() !== helper.toLowerCase()) {
    throw Error('Sine v3 helper or tuple version mismatch')
  }
  if (!configured || launchPrice < 1_000_000_000n || launchPrice > 10n ** 18n || launchPrice !== factoryLaunchPrice) {
    throw Error('Sine v3 launch price or configuration mismatch')
  }
  const ceiling = potBalance / 10_000n + (potBalance % 10_000n === 0n ? 0n : 1n)
  // Pre-launch the pot is unseeded and the minimum is the fixed 0.005
  // legacy floor; once the genesis fee seeds the pot, tickets price from it.
  const expectedTicket = active ? (ceiling === 0n ? 1n : ceiling) : 5_000_000_000_000_000n
  if (ticketPrice !== expectedTicket || minimumBuy !== ticketPrice) throw Error('Sine v3 pot price or minimum mismatch')
  const shardCount = await uint(helper, 'dataShardCount')
  if (shardCount !== 4n) throw Error('Sine v3 data shard count mismatch')
  const dataShards = await Promise.all(Array.from({ length: 4 }, (_, index) =>
    read(helper, parseAbi(['function dataShard(uint256 index) view returns(address)']), 'dataShard', [BigInt(index)])))
  if (dataShards.some(value => !isAddress(value) || /^0x0{40}$/i.test(value)) ||
      new Set(dataShards.map(value => value.toLowerCase())).size !== 4) throw Error('Sine v3 data shard address mismatch')
  if (active) {
    const expectedWavelength = await read(helper, parseAbi(['function lamAt(uint256 bootWei) pure returns(uint256)']), 'lamAt', [boot])
    const expectedSupply = await read(helper, parseAbi(['function genesisQ(uint256 boot,uint256 lam,uint256 pL) view returns(uint256)']), 'genesisQ', [boot, wavelength, launchPrice])
    if (boot <= 0n || wavelength !== expectedWavelength || target !== boot + 10n * wavelength || genesisSupply <= 0n || genesisSupply !== expectedSupply) {
      throw Error('Sine v3 materialized curve mismatch')
    }
  } else if (boot !== 0n || wavelength !== 0n || target !== 0n || genesisSupply !== 0n) {
    throw Error('Inactive sine v3 curve has materialized values')
  }
  return { sineVersion, ticketVersion, minimumBuy, timePerUnit, ticketPrice, potBalance,
    params: { launchPrice }, curve: { active, boot, wavelength, target, genesisSupply, helper, dataShards } }
}

export async function discoverRegistryInitCode({ artifact, readOracle }) {
  if (!Array.isArray(artifact.abi)) throw Error('Missing ControllerDeployer ABI')
  const getter = artifact.abi.find(item => item.type === 'function' && item.name === 'registryInitOracle')
  if (!getter) return undefined
  if (getter.inputs?.length !== 0 || getter.outputs?.length !== 1 || getter.outputs[0].type !== 'address') {
    throw Error('Unsupported registryInitOracle getter')
  }
  const address = await readOracle()
  if (!isAddress(address || '') || /^0x0{40}$/i.test(address)) throw Error('Invalid registry creation-code helper address')
  return address
}

export function releaseContext({ rpcUrl, chainId, clientVersion, rehearsalRequested, sourceDirty }) {
  if (chainId !== BASE_SEPOLIA_ID) throw Error('Fresh release inspection requires Base Sepolia chain ID 84532')
  let rehearsalRpc
  if (rehearsalRequested) {
    const url = new URL(rpcUrl)
    const loopback = ['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)
    if (!loopback || !['http:', 'https:'].includes(url.protocol) || url.username || url.password ||
        url.pathname !== '/' || url.search || url.hash || !/^anvil(?:\/|\b)/i.test(clientVersion)) {
      throw Error('Rehearsal mode requires a plain loopback Anvil RPC on chain 84532')
    }
    rehearsalRpc = url.origin
  } else if (sourceDirty) {
    throw Error('Record a clean source revision before generating a release manifest (historical broadcasts are excluded)')
  }
  return { rehearsal: rehearsalRequested, sourceDirty, ...(rehearsalRpc ? { rehearsalRpc } : {}) }
}

/** Match every compiled runtime byte except compiler-declared immutable slots. */
export function assertRuntimeMatches(code, artifact, label) {
  const runtime = artifact.deployedBytecode
  if (!/^0x[0-9a-f]+$/i.test(code || '') || !/^0x[0-9a-f]+$/i.test(runtime?.object || '')) {
    throw Error(`Missing or unlinked runtime: ${label}`)
  }
  if (Object.values(runtime.linkReferences || {}).some(file => Object.keys(file).length)) {
    throw Error(`Linked runtime needs explicit library verification: ${label}`)
  }
  if (code.length !== runtime.object.length) throw Error(`Runtime differs from release artifact: ${label}`)
  const actual = Buffer.from(code.slice(2), 'hex')
  const expected = Buffer.from(runtime.object.slice(2), 'hex')
  for (const refs of Object.values(runtime.immutableReferences || {})) {
    for (const { start, length } of refs) {
      if (!Number.isInteger(start) || !Number.isInteger(length) || start < 0 || length <= 0 || start + length > actual.length) {
        throw Error(`Invalid immutable reference: ${label}`)
      }
      actual.fill(0, start, start + length)
      expected.fill(0, start, start + length)
    }
  }
  if (!actual.equals(expected)) throw Error(`Runtime differs from release artifact: ${label}`)
}

export function verifyFactoryCreation({ factory, receipt, canonicalBlockHash, snapshotBlock }) {
  if (receipt.status !== 'success' || receipt.contractAddress?.toLowerCase() !== factory.toLowerCase() ||
      receipt.blockNumber > snapshotBlock || receipt.blockHash?.toLowerCase() !== canonicalBlockHash?.toLowerCase()) {
    throw Error('Factory creation receipt is unsuccessful, mismatched, unconfirmed at the snapshot, or noncanonical')
  }
  return { transactionHash: receipt.transactionHash, block: receipt.blockNumber, blockHash: receipt.blockHash }
}

export function assertTimingProfile(timings) {
  const version = timings.PREDEPOSIT_RULES_VERSION
  if (version !== 1n && version !== 2n) throw Error('Unsupported predeposit rules version')
  const current = version === 2n
  const packed = timings.packed
  const mask = (1n << 64n) - 1n
  const predeposit = packed === 0n ? (current ? 3n : 7n) * 86400n : packed & mask
  const vest = packed === 0n ? (current ? 28n : 42n) * 86400n : (packed >> 64n) & mask
  const clock = ((packed >> 128n) & mask) || (current ? 248660n : 72n * 3600n)
  const walletCap = ((packed >> 192n) & mask) * 10n ** 18n
  if (timings.PREDEPOSIT_DURATION !== predeposit || timings.VEST_DURATION !== vest ||
      timings.detWindow !== clock || timings.PREDEPOSIT_CAP_PER_WALLET !== walletCap ||
      timings.PREDEPOSIT_CAP !== (current ? 0n : 1000n * 10n ** 18n) || timings.epochSize !== vest / 6n) {
    throw Error('Deployed timing/cap getters do not match the four-field factory timing profile')
  }
}

export function renderFrontendEnv(manifest, rehearsalRpc) {
  if (manifest.chainId !== BASE_SEPOLIA_ID || !manifest.deployment) {
    throw Error('Frontend export requires Base Sepolia and a verified factory creation receipt')
  }
  for (const name of ['factory', 'mix', ...auxiliaryNames]) {
    if (!isAddress(manifest.addresses[name] || '') || /^0x0{40}$/i.test(manifest.addresses[name])) {
      throw Error(`Frontend export requires a verified ${name} address`)
    }
  }
  if (manifest.rehearsal && !rehearsalRpc) throw Error('Rehearsal frontend export requires its loopback RPC')
  const entries = {
    VITE_CHAIN_ID: BASE_SEPOLIA_ID,
    VITE_RPC_URL: manifest.rehearsal ? rehearsalRpc : 'https://sepolia.base.org',
    VITE_RPC_FALLBACK_URL: manifest.rehearsal ? '' : 'https://base-sepolia-rpc.publicnode.com',
    VITE_FACTORY: manifest.addresses.factory,
    VITE_ZAP_IN: manifest.addresses.zapIn,
    VITE_ZAP_OUT: manifest.addresses.zapOut,
    VITE_MIX: manifest.addresses.mix,
    VITE_FAUCET: manifest.addresses.faucet,
    VITE_REINVESTOR: manifest.addresses.reinvestor,
    VITE_DEPLOYMENT_BLOCK: manifest.deployment.block,
    // Naming has a separate mainnet release and custody ceremony. Never copy
    // old registrar/verifier targets onto a fresh testnet game deployment.
    VITE_NAME_REGISTRAR: '',
    VITE_WC_PROJECT_ID: '',
  }
  return `# ${manifest.rehearsal ? 'LOCAL REHEARSAL ONLY' : 'Fresh Base Sepolia release'}\n` +
    `# Source ${manifest.revision}; inspected block ${manifest.block}\n` +
    '# Generated for review. Copy into the frontend only when switching deployments.\n' +
    Object.entries(entries).map(([key, value]) => `${key}=${value}`).join('\n') + '\n'
}

/** Verify the returned data, not the compiler's unreachable default runtime. */
export function assertSineDataMatches(code, expected, label) {
  if (!/^0x00[0-9a-f]+$/i.test(code || '') || !Number.isInteger(expected?.bytes) ||
      (code.length - 2) / 2 !== expected.bytes || expected.bytes > 24576 ||
      keccak256(code).toLowerCase() !== expected.hash?.toLowerCase()) {
    throw Error(`Sine v3 data differs from generated source: ${label}`)
  }
}
