import test from 'node:test'
import assert from 'node:assert/strict'
import { REFERRAL_QUIPS, pickReferralQuip, referralPostText, referralXIntent, loadReferralPepe } from '../src/lib/referralShare.ts'
import { parseReferral } from '../src/lib/referrals.ts'

test('20 distinct quips leave room for the testnet label and X-shortened referral URL', () => {
  assert.equal(REFERRAL_QUIPS.length, 20)
  assert.equal(new Set(REFERRAL_QUIPS).size, 20)
  for (const quip of REFERRAL_QUIPS) {
    assert.ok(referralPostText(quip, 84532).length + 1 + 23 <= 280)
  }
})

test('reroll can reach either end of the list while skipping the current quip', () => {
  assert.equal(pickReferralQuip(-1, () => 0), 0)
  assert.equal(pickReferralQuip(0, () => 0), 1)
  assert.equal(pickReferralQuip(19, () => 0.9999), 18)
  assert.equal(pickReferralQuip(10, () => 0.9999), 19)
})

test('X intent preserves the complete referral scope and full uint256 ID', () => {
  const id = (2n ** 256n - 1n).toString()
  const registry = '0x1234567890abcdef1234567890abcdef12345678'
  const link = `https://pepes.example/app/#/?ref=${id}&refChain=84532&refRegistry=${registry}`
  const text = referralPostText('frogs & friends. #PSP\n100% pixels + greed?', 84532)
  const intent = new URL(referralXIntent(text, link))
  assert.equal(intent.origin, 'https://x.com')
  assert.equal(intent.pathname, '/intent/tweet')
  assert.equal(intent.searchParams.get('text'), text)
  assert.equal(intent.searchParams.get('url'), link)
  const receivedLink = new URL(intent.searchParams.get('url'))
  assert.deepEqual(parseReferral(new URLSearchParams(receivedLink.hash.split('?')[1])), {
    nftId: id, registry, chainId: 84532,
  })
})

test('practice-network shares identify the playtest while mainnet shares keep the brand', () => {
  assert.match(referralPostText('quip', 84532), /Base Sepolia playtest/)
  assert.match(referralPostText('quip', 11155111), /Sepolia playtest/)
  assert.match(referralPostText('quip', 31337), /local playtest/)
  assert.equal(referralPostText('quip', 8453), 'quip\n\npositive sum pepes')
})

test('shared art uses selected NFT on-chain DNA including zero, rather than deriving it from its ID', async () => {
  const staker = '0x1111111111111111111111111111111111111111'
  const descriptor = '0x2222222222222222222222222222222222222222'
  const id = 2n ** 255n + 123n
  const svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 69 69"/>'
  const calls = []
  const result = await loadReferralPepe(staker, id, async (to, _abi, name, args) => {
    calls.push({ to, name, args })
    if (name === 'dnaOf') return 0n
    if (name === 'descriptor') return descriptor
    if (name === 'renderSVG') return svg
    throw new Error('Unexpected read')
  })
  assert.equal(result, svg)
  assert.deepEqual(calls, [
    { to: staker, name: 'dnaOf', args: [id] },
    { to: staker, name: 'descriptor', args: undefined },
    { to: descriptor, name: 'renderSVG', args: [0n] },
  ])
})

test('failed DNA reads stay retryable and never substitute another Pepe', async () => {
  await assert.rejects(loadReferralPepe('0x1111111111111111111111111111111111111111', 1n,
    async () => { throw new Error('RPC unavailable') }), /RPC unavailable/)
})
