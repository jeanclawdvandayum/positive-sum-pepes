import type { CurvePoint } from './curve'

export interface SineMarker {
  reserve: number // mixETH, human units
  price: number // mixETH per PSP, human units
  kind: 'boot' | 'anchor' | 'top'
  k: number // quarter-wave index (0..12; treads at 0/4/8/12)
}

export interface SineCurveData {
  truncated?: boolean
  active: boolean
  configured: boolean
  boot: number // human units
  span: number // seam→target distance
  top: number // the reserve endpoint of the third wave
  q0: bigint // launch mint (wei PSP) — supply baked in at boot
  checkpoints: bigint[] // retired — empty for the indefinite curve
  points: CurvePoint[]
  markers: SineMarker[]
}

/** Display-only sampling from the hook's immutable, materialized coefficients.
 * Quotes/minOut always come from the contract. Numbers here use human units. */
export function sampleSineChart(raw: readonly bigint[], liveReserve = 0, version: 1 | 2 = 1): SineCurveData {
  if (version !== 1 && version !== 2) throw new Error('Unsupported sine curve version')
  if (raw.length !== 11) throw new Error('Invalid sine curve response')
  const [p0, preK, boot, target, lam, B, slope, amp, , , q0] = raw.map(v => Number(v) / 1e18)
  if (![p0, preK, boot, target, lam, B, slope, q0].every(v => Number.isFinite(v) && v > 0)) {
    throw new Error('Curve has not been materialized')
  }
  if (!Number.isFinite(liveReserve) || liveReserve < 0) throw new Error('Invalid live reserve')
  // Keep at least one wave / 1,000 mixETH / 10% ahead of the live reserve.
  // Whole-wave boundaries keep the window steady between expansions.
  const waves = Math.max(4, Math.ceil((Math.max(target, sineChartHeadroom(liveReserve, lam, version)) - boot) / lam))
  // Leave numeric headroom for WAD labels and axis calculations. Do not
  // invent a flat price by clamping the exponential itself.
  // SineMath rejects exponential arguments above ~135.306. Stay below
  // that limit for every sine phase, as well as below JS numeric overflow.
  // v2 stores dimensionless growth per boot/wave to support any IBCO size.
  const preGrowth = version === 2 ? preK : preK * boot
  const waveTrend = version === 2 ? slope : slope * lam
  const maxArg = Math.min(135, 600 - Math.log(B))
  const numericEnd = boot + (maxArg - Math.abs(amp)) / waveTrend * lam
  const requestedEnd = boot + waves * lam
  const end = Math.min(requestedEnd, numericEnd)
  const truncated = end < requestedEnd
  const price = (r: number) => r <= boot ? p0 * Math.exp(preGrowth * (r / boot))
    : B * Math.exp(waveTrend * ((r - boot) / lam) - amp * Math.sin(2 * Math.PI * ((r - boot) % lam) / lam))
  const reserves = new Set<number>([0, boot, Math.min(target, end)])
  // Dense local geometry costs no extra RPC reads; cover the predeposit ramp
  // even when the final raise is tiny compared with the wavelength.
  for (let i = 1; i <= 64; i++) reserves.add(boot * i / 64)
  // 128 samples per wave, bounded so deep reserves cannot stall the browser.
  const steps = Math.min(8192, Math.ceil((end - boot) / lam) * 128)
  for (let i = 1; i <= steps; i++) reserves.add(boot + (end - boot) * i / steps)
  const grid = [...reserves].sort((a, b) => a - b)
  let supply = q0
  const points = grid.map((r, i) => {
    if (r > boot) {
      const left = grid[i - 1], d = r - left
      // Simpson integration: mixETH / (mixETH per PSP) is human PSP.
      supply += d * (1 / price(left) + 4 / price(left + d / 2) + 1 / price(r)) / 6
    }
    return { reserve: r, price: price(r), supply: r <= boot
      ? q0 * -Math.expm1(-preGrowth * (r / boot)) / -Math.expm1(-preGrowth) : supply }
  })
  const markers: SineMarker[] = [{ reserve: boot, price: B, kind: 'boot', k: 0 }]
  for (let k = 1; k <= 12; k++) {
    const r = boot + lam * k / 4
    if (r > end) break
    markers.push({ reserve: r, price: price(r), kind: k % 4 === 0 ? 'top' : 'anchor', k })
  }
  return { truncated, active: true, configured: true, boot, span: target - boot, top: target,
    q0: raw[10], checkpoints: [], points, markers }
}

export function sineChartHeadroom(liveReserve: number, wavelength: number, version: 1 | 2 = 1): number {
  return liveReserve + Math.max(version === 1 ? 1000 : 0, wavelength, liveReserve * 0.1)
}
