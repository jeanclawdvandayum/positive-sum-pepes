export interface TradeQuote {
  output: bigint
  feeMix: bigint
  feeBps: bigint
}

/** The output getter already includes the fee. Keep that executable quote intact. */
export function quoteWithFee(side: 'buy' | 'sell', input: bigint, output: bigint, feeBps: bigint, mode: number): TradeQuote {
  if (input <= 0n || output <= 0n) throw new Error('No executable quote.')
  if (mode === 2 && side === 'sell') return { output, feeMix: 0n, feeBps: 0n }
  if (mode !== 1) throw new Error('Trading is not active.')
  if (feeBps < 0n || feeBps >= 10_000n) throw new Error('Invalid trade fee.')
  const feeMix = side === 'buy'
    ? input * feeBps / 10_000n
    // net = gross - floor(gross * bps / 10000). Gross is not exposed by the
    // deployed sell getter. This estimate may exceed the actual fee by one wei
    // at the protocol's supported rates (2.5–10%); never deduct it again.
    : output * feeBps / (10_000n - feeBps)
  return { output, feeMix, feeBps }
}
