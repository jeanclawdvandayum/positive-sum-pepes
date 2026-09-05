/** Keep expanding logarithmic axes readable across many price/reserve decades. */
export function logTicks(min: number, max: number, budget = 12): number[] {
  if (!(min > 0 && max >= min) || !Number.isFinite(max)) return []
  const ticks: number[] = []
  for (let e = Math.floor(Math.log10(min)); e <= Math.floor(Math.log10(max)); e++) {
    for (const m of [1, 2, 5]) {
      const v = m * 10 ** e
      if (v >= min && v <= max) {
        ticks.push(v)
      }
    }
  }
  if (ticks.length <= budget) return ticks
  const stride = Math.ceil((ticks.length - 1) / (budget - 1))
  const spaced = ticks.filter((_, i) => i % stride === 0)
  // Preserve the highest tick so the expanded range is visible on the axis.
  if (spaced.at(-1) !== ticks.at(-1)) spaced.push(ticks.at(-1)!)
  return spaced
}
