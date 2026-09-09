import test from 'node:test'
import assert from 'node:assert/strict'
import { options, checkNetwork, confirmedDeployment, CHAIN_ID, POOL_MANAGER } from '../../scripts/deployment/base-sepolia.mjs'

const sender = '0x0000000000000000000000000000000000000011'
const factory = '0x0000000000000000000000000000000000000022'
const hash = `0x${'ab'.repeat(32)}`

test('deployment runner defaults to a local rehearsal with the current uncapped testnet profile', () => {
  const opt = options([], {})
  assert.equal(opt.broadcast, false)
  assert.equal(opt.settings.PSP_WALLET_CAP_MIX, '0')
  assert.equal(opt.settings.PSP_PREDEPOSIT_SEC, '86400')
  assert.equal(opt.settings.PSP_VEST_SEC, '3600')
  assert.equal(opt.settings.PSP_DET_SEC, '248660')
})

test('live deployment needs an explicit keystore and sender and refuses private-key CLI input', () => {
  assert.throws(() => options(['--broadcast'], {}), /requires/)
  assert.throws(() => options(['--broadcast', '--account', 'test-wallet'], {}), /requires/)
  assert.throws(() => options(['--private-key', 'secret'], {}), /Unknown argument/)
  assert.throws(() => options(['--verify'], {}), /live Base Sepolia/)
  assert.throws(() => options(['--broadcast', '--account', 'test-wallet', '--sender', '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266'], {}), /public Anvil/)
  assert.equal(options(['--broadcast', '--account', 'test-wallet', '--sender', sender], {}).broadcast, true)
})

test('invalid timing and narrowed sine inputs fail before connecting or writing', () => {
  for (const env of [
    { PSP_VEST_SEC: '7' }, { PSP_VEST_SEC: '0' }, { PSP_DET_SEC: '0' },
    { PSP_PREDEPOSIT_SEC: (2n ** 64n).toString() }, { PSP_SINE_AMPBPS: '16787216' },
    { PSP_WALLET_CAP_MIX: '-1' }, { PSP_SINE_P0: '1e13' },
  ]) assert.throws(() => options([], env))
  assert.equal(options([], { PSP_WALLET_CAP_MIX: '10' }).settings.PSP_WALLET_CAP_MIX, '10')
})

test('network preflight rejects wrong chain, missing pool manager and non-Anvil rehearsal endpoints', async () => {
  const c = {
    getChainId: async () => CHAIN_ID,
    getBlock: async () => ({ number: 123n, hash }),
    getCode: async ({ address, blockNumber }) => {
      assert.equal(address, POOL_MANAGER); assert.equal(blockNumber, 123n); return '0x1234'
    },
    request: async () => 'anvil/v1',
  }
  assert.equal((await checkNetwork(c, { local: true })).number, 123n)
  await assert.rejects(checkNetwork({ ...c, getChainId: async () => 1 }), /84532/)
  await assert.rejects(checkNetwork({ ...c, getCode: async () => '0x' }), /no code/)
  await assert.rejects(checkNetwork({ ...c, request: async () => 'geth' }, { local: true }), /Anvil/)
})

test('addresses come from successful matching receipts and every submitted transaction is checked', async () => {
  const tx = { hash, transactionType: 'CREATE', contractName: 'PSPFactory', contractAddress: factory, transaction: { chainId: '0x14a34' } }
  const receipt = { status: 'success', contractAddress: factory, gasUsed: 1_000_000n, blockNumber: 124n, blockHash: hash }
  const client = { getTransactionReceipt: async () => receipt }
  const result = await confirmedDeployment({ transactions: [tx] }, client)
  assert.equal(result.addresses.PSPFactory.address, factory)
  assert.equal(result.addresses.PSPFactory.transactionHash, hash)
  await assert.rejects(confirmedDeployment({ transactions: [{ ...tx, hash: null }] }, client), /confirmed hash/)
  await assert.rejects(confirmedDeployment({ transactions: [{ ...tx, transaction: { chainId: 1 } }] }, client), /wrong chain/)
  await assert.rejects(confirmedDeployment({ transactions: [tx] }, { getTransactionReceipt: async () => ({ ...receipt, status: 'reverted' }) }), /reverted/)
  await assert.rejects(confirmedDeployment({ transactions: [tx] }, { getTransactionReceipt: async () => ({ ...receipt, contractAddress: sender }) }), /address mismatch/)
  await assert.rejects(confirmedDeployment({ transactions: [tx] }, { getTransactionReceipt: async () => ({ ...receipt, gasUsed: 16_777_217n }) }), /gas budget/)
  await assert.rejects(confirmedDeployment({ transactions: [tx, tx] }, client), /Duplicate deployment role/)
})
