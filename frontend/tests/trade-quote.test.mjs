import test from 'node:test'
import assert from 'node:assert/strict'
import { quoteWithFee } from '../src/lib/tradeQuote.ts'

test('buy fees use gross mixETH input and preserve the quoted PSP output', () => {
  const input = 5_000_000_000_000_019n
  const output = 56_646_000_000_000_000_000n
  for (const rate of [250n, 500n, 1000n]) {
    assert.deepEqual(quoteWithFee('buy', input, output, rate, 1), {
      output, feeMix: input * rate / 10_000n, feeBps: rate,
    })
  }
})

test('sell fee estimates recover gross-based fees within one wei without reducing net output', () => {
  for (let rate = 250n; rate <= 1000n; rate++) {
    for (const gross of [1n, 9n, 10n, 99n, 100n, 10001n, 123456789012345678901234567890n]) {
      const actualFee = gross * rate / 10_000n
      const net = gross - actualFee
      const quote = quoteWithFee('sell', 500n * 10n ** 18n, net, rate, 1)
      assert.equal(quote.output, net)
      assert.ok(quote.feeMix >= actualFee && quote.feeMix <= actualFee + 1n)
    }
  }
})

test('flat sells show zero fees regardless of the sliding-rate getter', () => {
  assert.deepEqual(quoteWithFee('sell', 100n, 25n, 1000n, 2), { output: 25n, feeMix: 0n, feeBps: 0n })
  assert.deepEqual(quoteWithFee('buy', 100n, 25n, 0n, 1), { output: 25n, feeMix: 0n, feeBps: 0n })
})

test('invalid quotes, fee rates and inactive modes cannot produce a fee estimate', () => {
  for (const rate of [-1n, 10_000n, 10_001n]) assert.throws(() => quoteWithFee('buy', 100n, 25n, rate, 1))
  for (const [side, mode] of [['buy', 0], ['buy', 2], ['buy', 3], ['sell', 0], ['sell', 3]]) {
    assert.throws(() => quoteWithFee(side, 100n, 25n, 1000n, mode))
  }
  assert.throws(() => quoteWithFee('buy', 0n, 25n, 1000n, 1))
  assert.throws(() => quoteWithFee('sell', 100n, 0n, 1000n, 1))
})
