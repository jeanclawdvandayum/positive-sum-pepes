import test from 'node:test'
import assert from 'node:assert/strict'
import {
  bragText, bragUrl, dismissedAmount, isNewWin, pickVictoryMessage, settledRound, VICTORY_MESSAGES, victories,
} from '../src/lib/victoryCards.ts'
import { FAN_CAP, fanAngle, fanHand, shareArt, victoryHand } from '../src/lib/victoryArt.ts'

// The dismissal memory lives in localStorage; node gets an in-memory one.
const storage = new Map()
globalThis.localStorage = {
  getItem: key => storage.get(key) ?? null,
  setItem: (key, value) => { storage.set(key, String(value)) },
  removeItem: key => { storage.delete(key) },
}

const OMG = "OMG!😭Can't believe I won ! Thank you Positive Sum Pepes team ! ❤️ keep doing the great work. 💪🏻💪🏻💪🏻🚀🚀🚀"
const HOOK = '0x00000000000000000000000000000000000ABC01'
const NEXT_HOOK = '0x00000000000000000000000000000000000abc02'
const ME = '0x00000000000000000000000000000000000000Ab'
const PAYOUT = 1234n * 10n ** 16n // 12.34 mixETH

test('every message is reachable, the community entry verbatim among them', () => {
  const picked = VICTORY_MESSAGES.map((_, i) => pickVictoryMessage(() => (i + 0.5) / VICTORY_MESSAGES.length))
  assert.deepEqual(picked, [...VICTORY_MESSAGES])
  assert.ok(VICTORY_MESSAGES.includes(OMG))
  // Math.random's open upper bound never indexes past the list.
  assert.equal(pickVictoryMessage(() => 0.999999999), VICTORY_MESSAGES.at(-1))
})

test('a claim brag leads with the message and carries amount, round and seats', () => {
  const victory = victories.push({ source: 'claim', roundId: 3n, amountMix: PAYOUT, message: VICTORY_MESSAGES[0], seats: 2 })
  const text = bragText(victory)
  assert.ok(text.startsWith(`${VICTORY_MESSAGES[0]}\n\n`))
  assert.ok(text.includes('i just claimed 12.34 mixETH from the round 3 pot with 2 ladder seats'))
  const url = new URL(bragUrl(victory))
  assert.equal(`${url.origin}${url.pathname}`, 'https://x.com/intent/tweet')
  assert.equal(url.searchParams.get('text'), text)
})

test('a settle-detected brag says won; one seat reads singular; unknown seats say nothing', () => {
  const one = victories.push({ source: 'settle', roundId: 9n, amountMix: PAYOUT, message: VICTORY_MESSAGES[1], seats: 1 })
  assert.ok(bragText(one).includes('i just won 12.34 mixETH from the round 9 pot with 1 ladder seat on'))
  const unknown = victories.push({ source: 'settle', roundId: 9n, amountMix: PAYOUT, message: VICTORY_MESSAGES[1] })
  assert.ok(bragText(unknown).includes('round 9 pot on positive sum pepes'))
})

test('every message fits X’s 280 chars with a worst-case amount, round and seat count', () => {
  for (const message of VICTORY_MESSAGES) {
    const text = bragText(victories.push({
      source: 'claim', roundId: 2n ** 64n, amountMix: 10n ** 30n, message, seats: 10,
    }))
    assert.ok(text.length <= 280, `${text.length}: ${message}`)
    assert.ok(text.startsWith(message))
  }
})

test('when the pair would overflow, the victory-info sentence yields before the message', () => {
  const longMessage = 'x'.repeat(270)
  assert.equal(bragText(victories.push({ source: 'claim', roundId: 12n, amountMix: 1n, message: longMessage })), longMessage)
})

test('settle detection: only a round that left Active is settled', () => {
  const active = { id: 7n, hook: HOOK, mode: 1 }
  // Still Active on the lane: nothing to check.
  assert.equal(settledRound(active, active), undefined)
  // The same hook went Flat/Destroyed (the not-yet-advanced shape).
  assert.deepEqual(settledRound(active, { ...active, mode: 2 }), { ...active, mode: 2 })
  assert.deepEqual(settledRound(undefined, { ...active, mode: 3 }), { ...active, mode: 3 })
  // detonate births round 8 in the same tx: the lane now shows its predeposit.
  assert.equal(settledRound(active, { id: 8n, hook: NEXT_HOOK, mode: 0 }), active)
  // Hooks compare case-insensitively.
  assert.equal(settledRound(active, { id: 7n, hook: HOOK.toLowerCase(), mode: 1 }), undefined)
  // Never seen Active, or a stale memory newer than the lane: no guess.
  assert.equal(settledRound(undefined, { id: 8n, hook: NEXT_HOOK, mode: 0 }), undefined)
  assert.equal(settledRound({ id: 9n, hook: NEXT_HOOK, mode: 1 }, { id: 8n, hook: HOOK, mode: 1 }), undefined)
  assert.equal(settledRound(active, undefined), undefined)
})

test('a win is new only when claimable and larger than what was dismissed', () => {
  assert.equal(isNewWin(undefined, undefined), false)
  assert.equal(isNewWin(0n, undefined), false)
  assert.equal(isNewWin(5n, undefined), true)
  assert.equal(isNewWin(5n, 5n), false)
  assert.equal(isNewWin(4n, 5n), false)
  assert.equal(isNewWin(6n, 5n), true)
})

test('the store is inert without a subscriber: nothing queues, nothing opens', () => {
  assert.equal(victories.active, false)
  assert.deepEqual(victories.snapshot(), [])
  assert.equal(victories.offerSettled({ source: 'settle', roundId: 1n, amountMix: 5n, message: 'm', hook: HOOK, account: ME }), undefined)
  assert.deepEqual(victories.snapshot(), [])
})

test('settle wins open once per round and wallet, re-open only when the amount grows', () => {
  const off = victories.subscribe(() => {})
  const offer = amountMix => victories.offerSettled({ source: 'settle', roundId: 7n, amountMix, message: 'm', hook: HOOK, account: ME })
  assert.equal(offer(0n), undefined)
  const first = offer(5n)
  assert.equal(victories.snapshot().length, 1)
  // The 15s recheck finds the same amount: still one entry.
  assert.equal(offer(5n).id, first.id)
  // A grown amount updates the queued entry in place.
  assert.equal(offer(7n).amountMix, 7n)
  assert.equal(victories.snapshot().length, 1)
  victories.dismiss(first.id)
  // Dismissal is remembered per hook + wallet, case-insensitively.
  assert.equal(dismissedAmount(HOOK.toLowerCase(), ME.toUpperCase().replace('0X', '0x')), 7n)
  assert.equal(offer(7n), undefined)
  assert.deepEqual(victories.snapshot(), [])
  const grown = offer(9n)
  assert.equal(grown.amountMix, 9n)
  // A confirmed claim for that hook resolves the pending settle entry.
  victories.resolveSettled(HOOK, ME)
  assert.deepEqual(victories.snapshot(), [])
  off()
})

test('claim victories queue oldest first and never write dismissal memory', () => {
  const off = victories.subscribe(() => {})
  const a = victories.push({ source: 'claim', roundId: 4n, amountMix: 1n, message: 'a', hook: NEXT_HOOK, account: ME, delayMs: 900 })
  const b = victories.push({ source: 'claim', roundId: 4n, amountMix: 2n, message: 'b', hook: NEXT_HOOK, account: ME })
  assert.deepEqual(victories.snapshot().map(v => v.id), [a.id, b.id])
  assert.equal(a.showAt - a.at, 900)
  victories.dismiss(a.id)
  assert.equal(dismissedAmount(NEXT_HOOK, ME), undefined)
  victories.clear()
  off()
})

test('the fan shows at most six pepes and counts the rest', () => {
  assert.equal(FAN_CAP, 6)
  assert.deepEqual(fanHand(0), { shown: 0, more: 0 })
  assert.deepEqual(fanHand(1), { shown: 1, more: 0 })
  assert.deepEqual(fanHand(6), { shown: 6, more: 0 })
  assert.deepEqual(fanHand(8), { shown: 6, more: 2 })
  assert.deepEqual(fanHand(3, 2), { shown: 2, more: 1 })
})

test('the fan is a symmetric arc: at most 12° apart and 56° across', () => {
  assert.equal(fanAngle(0, 1), 0)
  for (const n of [2, 3, 6]) {
    const angles = Array.from({ length: n }, (_, i) => fanAngle(i, n))
    angles.forEach((angle, i) => assert.ok(Math.abs(angle + angles[n - 1 - i]) < 1e-9))
    for (let i = 1; i < n; i++) assert.ok(angles[i] - angles[i - 1] <= 12 + 1e-9)
    assert.ok(angles[n - 1] - angles[0] <= 56 + 1e-9)
  }
})

// ── the art-selection predicate (which pepes the cards and the brag PNG use)
// ── pure logic; the clipboard itself is browser-side and mocked in the DOM
// ── verification, never touched here. ────────────────────────────────────────

const IDENTITY = '<svg viewBox="0 0 69 69" id="wallet"/>'
const hand = svgs => ({ svgs, more: 0 })

test('the hand picks the staker NFT fan, else the wallet’s auto-assigned pepe', () => {
  // No staker to read (lab claim, or a round without one): identity pepe, alone.
  assert.deepEqual(victoryHand({ identity: IDENTITY }), { svgs: [IDENTITY], more: 0, identity: true })
  // The winner's position NFTs: the fan, never the identity pepe.
  const two = ['<svg a/>', '<svg b/>']
  assert.deepEqual(victoryHand({ nfts: hand(two), identity: IDENTITY }), { svgs: two, more: 0, identity: false })
  // The NFT read resolved empty (a wallet with no positions): identity stands in.
  assert.deepEqual(victoryHand({ nfts: hand([]), identity: IDENTITY }), { svgs: [IDENTITY], more: 0, identity: true })
  // First load still in flight and nothing known yet: no hand — the modal
  // renders no card and the brag button waits rather than copy stale art.
  assert.equal(victoryHand({ nftsLoading: true, identity: IDENTITY }), undefined)
  // A background refetch over known art keeps the fan.
  assert.deepEqual(victoryHand({ nfts: hand(two), nftsLoading: true, identity: IDENTITY }), { svgs: two, more: 0, identity: false })
  // Dev-lab mocks bypass chain reads entirely and cap themselves like the fan.
  const mocks = Array.from({ length: 8 }, (_, i) => `<svg m${i}/>`)
  assert.deepEqual(victoryHand({ mockPepes: mocks, identity: IDENTITY }), { svgs: mocks.slice(0, FAN_CAP), more: 8 - FAN_CAP, identity: false })
})

test('claim and settle select art the same way — only the inputs they feed it differ', () => {
  const fan = ['<svg 1/>', '<svg 2/>', '<svg 3/>']
  // The lab claim carries no staker: the wallet pepe, single.
  assert.deepEqual(victoryHand({ identity: IDENTITY }).svgs, [IDENTITY])
  // A real claim carries the round's staker, exactly like settle does: the
  // same NFT fan either way — the source changes the copy, never the art.
  const claim = victoryHand({ nfts: hand(fan), identity: IDENTITY })
  const settle = victoryHand({ nfts: { svgs: fan, more: 2 }, identity: IDENTITY })
  assert.deepEqual(claim.svgs, fan)
  assert.deepEqual(settle, { svgs: fan, more: 2, identity: false })
  // The dev lab's settle win supplies its own pepes.
  assert.deepEqual(victoryHand({ mockPepes: fan, identity: IDENTITY }), { svgs: fan, more: 0, identity: false })
})

test('the brag PNG is exactly the card art: none, the single pepe, or the whole fan', () => {
  // Nothing to show yet: no PNG at all — brag waits, no blank composite.
  assert.equal(shareArt(undefined), undefined)
  assert.equal(shareArt({ svgs: [], more: 0, identity: false }), undefined)
  // One pepe: the single card's own art, not a decorative stand-in.
  const only = '<svg only/>'
  assert.deepEqual(shareArt({ svgs: [only], more: 0, identity: true }), { kind: 'single', svg: only })
  // Several: every card's art in one composite, plus the same "+N more" count.
  const many = ['<svg 1/>', '<svg 2/>', '<svg 3/>', '<svg 4/>']
  const share = shareArt({ svgs: many, more: 5, identity: false })
  assert.equal(share.kind, 'fan')
  assert.deepEqual(share.svgs, many)
  assert.equal(share.svgs.length, 4)
  assert.equal(share.more, 5)
})
