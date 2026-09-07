import test from 'node:test'
import assert from 'node:assert/strict'
import { ensureWalletNetwork } from '../src/lib/walletNetwork.ts'

for (const [from, to] of [[1, 84532], [84532, 1]]) {
  test(`action switches ${from} to ${to} before continuing`, async () => {
    let chainId = from
    const requests = []
    await ensureWalletNetwork('0xabc', to, {
      current: () => ({ address: '0xAbC', chainId }),
      switchTo: async id => { requests.push(id); chainId = id },
    })
    assert.deepEqual(requests, [to])
    assert.equal(chainId, to)
  })
}
test('correct network requires no prompt', async () => {
  await ensureWalletNetwork('0xabc', 84532, {
    current: () => ({ address: '0xabc', chainId: 84532 }),
    switchTo: async () => { assert.fail('unnecessary switch') },
  })
})
test('rejected switch stops the action', async () => {
  await assert.rejects(ensureWalletNetwork('0xabc', 84532, {
    current: () => ({ address: '0xabc', chainId: 1 }),
    switchTo: async () => { throw Error('User rejected') },
  }), /User rejected/)
})
test('account change during switch stops the action', async () => {
  let address = '0xabc'
  await assert.rejects(ensureWalletNetwork(address, 84532, {
    current: () => ({ address, chainId: 1 }),
    switchTo: async () => { address = '0xdef' },
  }), /account changed/)
})
test('wallet that stays on the old network cannot continue', async () => {
  await assert.rejects(ensureWalletNetwork('0xabc', 84532, {
    current: () => ({ address: '0xabc', chainId: 1 }),
    switchTo: async () => {},
  }), /did not switch/)
})
