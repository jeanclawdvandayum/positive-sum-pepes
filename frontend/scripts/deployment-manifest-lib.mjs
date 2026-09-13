/** Pure guards shared by the read-only release inspector and focused tests. */
import { isAddress } from 'viem'

export const BASE_SEPOLIA_ID = 84532
export const BASE_SEPOLIA_POOL_MANAGER = '0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408'
const auxiliaryNames = ['zapIn', 'zapOut', 'faucet', 'reinvestor']

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
