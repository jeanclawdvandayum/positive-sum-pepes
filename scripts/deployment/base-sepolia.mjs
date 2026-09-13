#!/usr/bin/env node
/** Fresh Base Sepolia deployment. Defaults to a disposable local fork rehearsal.
 * Live writes require --broadcast, a named Foundry keystore and its sender.
 * Every run has separate receipts/build inputs and exports, never a live UI edit. */
import fs from 'node:fs'
import path from 'node:path'
import net from 'node:net'
import { fileURLToPath } from 'node:url'
import { spawn, execFileSync } from 'node:child_process'
import { createPublicClient, http, isAddress, keccak256 } from 'viem'

export const CHAIN_ID = 84532
export const POOL_MANAGER = '0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408'
const ANVIL_SENDER = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266'
const root = fileURLToPath(new URL('../../', import.meta.url))
const defaults = {
  PSP_PREDEPOSIT_SEC: '259200', PSP_VEST_SEC: '2419200', PSP_DET_SEC: '248660', PSP_WALLET_CAP_MIX: '0',
  PSP_SINE_P0: '10000000000000', PSP_SINE_PREK: '4477562267871699',
  PSP_SINE_PTARGET: '60000000000000000', PSP_SINE_TARGET_RESERVE: '10000000000000000000000',
  PSP_SINE_AMPBPS: '10000',
}
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))
const writeJson = (file, value) => fs.writeFileSync(file, JSON.stringify(value, (_, v) =>
  typeof v === 'bigint' ? v.toString() : v, 2) + '\n', { mode: 0o600, flag: 'wx' })
const clientFor = url => createPublicClient({ transport: http(url, { timeout: 20000, retryCount: 2 }) })

export function options(argv, env = process.env) {
  const result = { broadcast: false, account: env.PSP_DEPLOY_ACCOUNT, sender: env.PSP_DEPLOYER,
    out: undefined, rpc: env.BASE_SEPOLIA_RPC_URL || 'https://sepolia.base.org', verify: false }
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    if (arg === '--broadcast') result.broadcast = true
    else if (arg === '--dry-run') result.broadcast = false
    else if (arg === '--verify') result.verify = true
    else if (['--account', '--sender', '--out'].includes(arg)) {
      const value = argv[++i]
      if (!value || value.startsWith('--')) throw Error(`Missing value for ${arg}`)
      result[{ '--account': 'account', '--sender': 'sender', '--out': 'out' }[arg]] = value
    } else throw Error(`Unknown argument ${arg}`)
  }
  const url = new URL(result.rpc)
  if (!['https:', 'http:'].includes(url.protocol)) throw Error('RPC must use HTTP(S)')
  if (result.broadcast && (!result.account || !isAddress(result.sender || '') || /^0x0+$/.test(result.sender))) {
    throw Error('--broadcast requires --account KEYSTORE_NAME and --sender ADDRESS (or PSP_DEPLOY_ACCOUNT/PSP_DEPLOYER)')
  }
  if (result.broadcast && result.sender.toLowerCase() === ANVIL_SENDER.toLowerCase()) throw Error('Use a dedicated testnet wallet, not the public Anvil account')
  if (result.verify && !result.broadcast) throw Error('--verify applies to live Base Sepolia deployments only')
  const settings = {}
  for (const [key, fallback] of Object.entries(defaults)) {
    const raw = env[key] || fallback
    if (!/^\d+$/.test(raw)) throw Error(`${key} must be an unsigned integer`)
    settings[key] = BigInt(raw).toString()
  }
  for (const key of ['PSP_PREDEPOSIT_SEC', 'PSP_VEST_SEC', 'PSP_DET_SEC', 'PSP_WALLET_CAP_MIX']) {
    if (BigInt(settings[key]) >= 2n ** 64n) throw Error(`${key} exceeds its 64-bit timing field`)
  }
  if (BigInt(settings.PSP_PREDEPOSIT_SEC) === 0n || BigInt(settings.PSP_DET_SEC) === 0n) throw Error('Use explicit positive testnet windows')
  if (BigInt(settings.PSP_VEST_SEC) < 6n || BigInt(settings.PSP_VEST_SEC) % 6n) throw Error('Vest duration must be positive and divisible by six')
  if (BigInt(settings.PSP_SINE_AMPBPS) > 10000n) throw Error('Sine amplitude must be at most 10000 bps')
  if (env.PSP_DEPLOYER_CUT_TO) {
    if (!isAddress(env.PSP_DEPLOYER_CUT_TO) || /^0x0+$/.test(env.PSP_DEPLOYER_CUT_TO)) throw Error('Invalid PSP_DEPLOYER_CUT_TO')
    settings.PSP_DEPLOYER_CUT_TO = env.PSP_DEPLOYER_CUT_TO
  }
  return { ...result, settings }
}

export async function checkNetwork(client, { local = false } = {}) {
  if (await client.getChainId() !== CHAIN_ID) throw Error('Expected Base Sepolia chain ID 84532')
  if (local && !/anvil/i.test(await client.request({ method: 'web3_clientVersion' }))) throw Error('Rehearsal writes require Anvil')
  const block = await client.getBlock()
  const code = await client.getCode({ address: POOL_MANAGER, blockNumber: block.number })
  if (!code || code === '0x') throw Error('Canonical Base Sepolia PoolManager has no code')
  return { number: block.number, hash: block.hash, poolManagerCodeHash: keccak256(code) }
}

export async function confirmedDeployment(record, client) {
  if (!record.transactions?.length) throw Error('Deployment has no transaction records')
  const addresses = {}, receipts = []
  for (const tx of record.transactions) {
    if (!/^0x[\da-f]{64}$/i.test(tx.hash || '')) throw Error('A deployment transaction is missing its confirmed hash')
    if (Number(BigInt(tx.transaction?.chainId ?? 0)) !== CHAIN_ID) throw Error('Recorded transaction targets the wrong chain')
    const receipt = await client.getTransactionReceipt({ hash: tx.hash })
    if (receipt.status !== 'success') throw Error(`Deployment transaction reverted: ${tx.hash}`)
    if (receipt.gasUsed > 16_777_216n) throw Error('Deployment transaction exceeds the supported per-transaction gas budget')
    if (tx.transactionType === 'CREATE') {
      if (!receipt.contractAddress || receipt.contractAddress.toLowerCase() !== tx.contractAddress?.toLowerCase()) throw Error('Creation receipt address mismatch')
      if (addresses[tx.contractName]) throw Error(`Duplicate deployment role ${tx.contractName}`)
      addresses[tx.contractName] = { address: receipt.contractAddress, transactionHash: tx.hash }
    }
    receipts.push({ hash: tx.hash, block: receipt.blockNumber, blockHash: receipt.blockHash,
      gasUsed: receipt.gasUsed, status: receipt.status, contractAddress: receipt.contractAddress })
  }
  return { addresses, receipts }
}

async function freePort() {
  const server = net.createServer()
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve) })
  const port = server.address().port
  await new Promise(resolve => server.close(resolve))
  return port
}

function run(command, args, { env, log, interactive = false } = {}) {
  return new Promise((resolve, reject) => {
    const fd = log ? fs.openSync(log, 'w', 0o600) : undefined
    const child = spawn(command, args, { cwd: root, env: env || process.env,
      stdio: interactive ? 'inherit' : ['ignore', fd ?? 'inherit', fd ?? 'inherit'] })
    if (fd !== undefined) fs.closeSync(fd)
    child.once('error', reject)
    child.once('exit', code => code === 0 ? resolve() : reject(Error(`${command} failed (${code}). ${log ? `See ${log}` : 'Check its output.'}`)))
  })
}

async function main() {
  if (process.argv.includes('--help')) {
    console.log('Usage: node scripts/deployment/base-sepolia.mjs [--dry-run] [--out DIRECTORY]\n       node scripts/deployment/base-sepolia.mjs --broadcast --account KEYSTORE --sender ADDRESS [--verify] [--out DIRECTORY]\nBASE_SEPOLIA_RPC_URL and PSP timing/sine env overrides are optional. Dry-run creates an isolated local fork. Live frontend env is never changed.')
    return
  }
  const opt = options(process.argv.slice(2))
  const stamp = new Date().toISOString().replace(/[:.]/g, '-')
  const directory = path.resolve(root, opt.out || `out/releases/base-sepolia-${opt.broadcast ? 'live' : 'rehearsal'}-${stamp}`)
  const relative = path.relative(root, directory)
  if (relative === '' || (!relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative))) {
    try { execFileSync('git', ['check-ignore', '-q', path.join(directory, '.release-output')], { cwd: root }) }
    catch { throw Error('Output must be outside the repository or inside an ignored directory such as out/releases') }
  }
  if (fs.existsSync(directory)) throw Error('Choose a new output directory to preserve prior receipts')
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 })
  const revision = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim()
  const sourceDirty = () => execFileSync('git', ['status', '--porcelain', '--untracked-files=all', '--', '.', ':(exclude)broadcast/**'], { cwd: root, encoding: 'utf8' }).trim().length > 0
  const dirty = sourceDirty()
  if (opt.broadcast && dirty) throw Error('Commit the reviewed release inputs before broadcasting (historical broadcast files are excluded)')
  const checkReleaseSource = () => {
    if (!opt.broadcast) return
    const currentRevision = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim()
    if (currentRevision !== revision || sourceDirty()) throw Error('Release source changed during preparation; stopped before the next deployment pass')
  }
  const upstream = await checkNetwork(clientFor(opt.rpc))
  writeJson(path.join(directory, 'plan.json'), { rehearsal: !opt.broadcast, revision, sourceDirty: dirty,
    chainId: CHAIN_ID, poolManager: POOL_MANAGER, fork: upstream, settings: opt.settings,
    signer: opt.broadcast ? opt.sender : ANVIL_SENDER, nameRegistry: 'separate Ethereum rollout; disabled in generated UI env' })
  console.log(`${opt.broadcast ? 'Live Base Sepolia deployment' : 'Local Base Sepolia rehearsal'}: ${directory}`)
  let anvil
  let rpc = opt.rpc
  const stop = () => { if (anvil && anvil.exitCode === null) anvil.kill('SIGTERM') }
  process.once('SIGINT', () => { stop(); process.exit(130) })
  process.once('SIGTERM', () => { stop(); process.exit(143) })
  try {
    if (!opt.broadcast) {
      const port = await freePort()
      rpc = `http://127.0.0.1:${port}`
      const fd = fs.openSync(path.join(directory, 'anvil.log'), 'w', 0o600)
      anvil = spawn('anvil', ['--host', '127.0.0.1', '--port', String(port), '--chain-id', String(CHAIN_ID),
        '--fork-url', opt.rpc, '--fork-block-number', String(upstream.number), '--gas-limit', '16777216',
        '--dump-state', path.join(directory, 'anvil-state.json')],
      { cwd: root, stdio: ['ignore', fd, fd] })
      fs.closeSync(fd)
      anvil.once('error', error => { console.error(`Anvil startup failed: ${error.message}`) })
      let ready = false
      for (let i = 0; i < 40; i++) {
        if (anvil.exitCode !== null) throw Error('Anvil stopped during startup; see anvil.log')
        try { await checkNetwork(clientFor(rpc), { local: true }); ready = true; break } catch { await sleep(250) }
      }
      if (!ready) throw Error('Local Anvil fork did not become ready')
    }
    const client = clientFor(rpc)
    const env = { ...process.env, ...opt.settings, PSP_TESTNET: 'true', PSP_ANVIL: 'false', PSP_FORK: 'false',
      PSP_PM: POOL_MANAGER, PSP_HTML: 'script/testnet-status.html',
      FOUNDRY_BROADCAST: path.join(directory, 'broadcast'), FOUNDRY_BUILD_INFO: 'true',
      FOUNDRY_BUILD_INFO_PATH: path.join(directory, 'build-info'), FOUNDRY_CACHE_PATH: path.join(directory, 'cache') }
    // Wallet material from historical .env exports is never selected by this runner.
    delete env.PRIVATE_KEY
    delete env.ETH_PRIVATE_KEY
    const wallet = opt.broadcast ? ['--account', opt.account, '--sender', opt.sender] : ['--unlocked', '--sender', ANVIL_SENDER]
    // A rehearsal and its upstream share chain ID/block heights. Read their
    // actual endpoint instead of reusing disk-cached state from another fork.
    const common = ['--rpc-url', rpc, '--chain', String(CHAIN_ID), '--no-storage-caching', '--broadcast', '--slow', '--non-interactive', '--gas-estimate-multiplier', '110', ...wallet]
    console.log('Running the deterministic audit gate...')
    await run('bash', ['scripts/check-audit.sh'], { env, log: path.join(directory, 'audit.log') })
    console.log('Deploying fresh factory and three-step genesis...')
    await checkNetwork(client, { local: !opt.broadcast })
    checkReleaseSource()
    await run('forge', ['script', 'script/DeployPSP.s.sol:DeployPSP', ...common], {
      env, log: opt.broadcast ? undefined : path.join(directory, 'deploy.log'), interactive: opt.broadcast })
    const loadBroadcast = name => JSON.parse(fs.readFileSync(path.join(directory, 'broadcast', `${name}.s.sol`, String(CHAIN_ID), 'run-latest.json')))
    const first = await confirmedDeployment(loadBroadcast('DeployPSP'), client)
    const get = role => { const value = first.addresses[role]; if (!value) throw Error(`Missing ${role} creation receipt`); return value }
    const factory = get('PSPFactory')
    Object.assign(env, { PSP_RPC_URL: rpc, PSP_FACTORY: factory.address, PSP_FACTORY_CREATION_TX: factory.transactionHash,
      PSP_ZAPIN: get('PSPZapIn').address, PSP_ZAPOUT: get('PSPZapOut').address,
      PSP_FAUCET: get('MixETHFaucet').address, PSP_ROUND: '1' })
    writeJson(path.join(directory, 'core-receipts.json'), first)
    console.log('Deploying reinvestor against the confirmed round addresses...')
    checkReleaseSource()
    await run('forge', ['script', 'script/DeployReinvestor.s.sol:DeployReinvestor', ...common], {
      env, log: opt.broadcast ? undefined : path.join(directory, 'reinvestor.log'), interactive: opt.broadcast })
    const second = await confirmedDeployment(loadBroadcast('DeployReinvestor'), client)
    if (!second.addresses.PSPReinvestor) throw Error('Missing reinvestor creation receipt')
    env.PSP_REINVESTOR = second.addresses.PSPReinvestor.address
    writeJson(path.join(directory, 'reinvestor-receipts.json'), second)
    if (!opt.broadcast) env.PSP_MANIFEST_REHEARSAL = '1'
    else delete env.PSP_MANIFEST_REHEARSAL
    const manifestPath = path.join(directory, 'manifest.json')
    console.log('Verifying deployment wiring, bytecode and rules; exporting frontend settings...')
    await run('node', ['--experimental-strip-types', 'frontend/scripts/deployment-manifest.mjs',
      factory.address, manifestPath, path.join(directory, 'frontend.env')], { env, log: path.join(directory, 'manifest.log') })
    const manifest = JSON.parse(fs.readFileSync(manifestPath))
    console.log('Testing fresh features, two rounds and old-round exits on a local EVM fork...')
    await run('forge', ['test', '--match-contract', 'BaseSepoliaReleaseTest', '--fork-url', rpc,
      '--fork-block-number', String(manifest.block), '--no-storage-caching', '-vv'], { env: { ...env, PSP_RELEASE_TESTNET: 'true', PSP_RELEASE_FRESH: 'true' },
      log: path.join(directory, 'release-tests.log') })
    if (opt.verify) {
      console.log('Verifying public contract sources...')
      await run('node', ['frontend/scripts/verify-sourcify.mjs', manifestPath, path.join(directory, 'build-info'),
        path.join(directory, 'verification.json')], { log: path.join(directory, 'verification.log') })
    }
    writeJson(path.join(directory, 'result.json'), { rehearsal: !opt.broadcast, revision,
      status: 'passed', manifest: manifestPath, sourceVerification: opt.verify ? 'passed' : 'pending live verification',
      transactions: first.receipts.length + second.receipts.length,
      totalGas: [...first.receipts, ...second.receipts].reduce((sum, receipt) => sum + receipt.gasUsed, 0n),
      localForkStoppedAfterRehearsal: !opt.broadcast })
    console.log(`Ready: ${manifestPath}\nFrontend settings: ${path.join(directory, 'frontend.env')}`)
  } finally { stop() }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error(error.shortMessage || error.message); process.exitCode = 1 })
}
