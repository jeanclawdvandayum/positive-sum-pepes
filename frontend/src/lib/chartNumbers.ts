/** Display-only conversion. A failed extrapolation is unavailable, never zero. */
export function chartWad(value: number): bigint | undefined {
  const scaled = value * 1e18
  return Number.isFinite(scaled) ? BigInt(Math.round(scaled)) : undefined
}
