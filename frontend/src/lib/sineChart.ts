import type { CurvePoint } from './curve'
import type { SineRulesVersion } from './sineVersion'

export interface SineMarker {
  reserve: number // mixETH, human units
  price: number // mixETH per PSP, human units
  kind: 'boot' | 'anchor' | 'top' | 'milestone'
  k: number // quarter-wave index (v1/v2: 0..12; v3: n*4 for wave n=0..10)
}

export interface SineCurveData {
  truncated?: boolean
  active: boolean
  configured: boolean
  boot: number // human units
  span: number // seam→target distance
  top: number // v1/v2: third-wave reserve · v3: boot + 10*lam target
  q0: bigint // launch mint (wei PSP) — supply baked in at boot
  checkpoints: bigint[] // retired — empty for the indefinite curve
  points: CurvePoint[]
  markers: SineMarker[]
}

/// v3 softened cube-root growth (2026-09-14). One price formula across
/// prelaunch and active reserves; display-only floats, never amounts.
export const SINE_V3 = {
  /** K = ln(1000) / (∛11 − 1): ten waves reach 1,000× the launch price. */
  maxWaves: 4096,
  K: Math.log(1000) / (Math.cbrt(11) - 1),
  /** s(x) = x − sin(2πx)/(2π) — the monotone signed phase. */
  s: (x: number) => x - Math.sin(2 * Math.PI * x) / (2 * Math.PI),
  /** H(z) = sign(z)·(∛(1+|z|) − 1) — the softened cube-root shape. */
  H: (z: number) => Math.sign(z) * (Math.cbrt(1 + Math.abs(z)) - 1),
  /** Wave-n milestone multiple: 1000^(∛(1+n)−1)/(∛11−1), n = 0..10. */
  milestone: (n: number) => Math.pow(1000, (Math.cbrt(1 + n) - 1) / (Math.cbrt(11) - 1)),
}

/** Display-only sampling from the hook's immutable, materialized coefficients.
 * Quotes/minOut always come from the contract. Numbers here use human units.
 * raw is the version-matched read: v1/v2 `sineCurve` (11 fields), v3
 * `sineV3Info` (7 fields: version, pL, boot, lam, target, q0, table). */
export function sampleSineChart(raw: readonly bigint[], liveReserve = 0, version: SineRulesVersion = 1): SineCurveData {
  if (version !== 1 && version !== 2 && version !== 3) throw new Error('Unsupported sine curve version')
  if (version === 3) return sampleSineV3Chart(raw, liveReserve)
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

/// v3: include the full nonnegative prelaunch reserve range and ten milestones.
/// Supply is anchored at the materialized genesis mint.
export function sampleSineV3Chart(raw: readonly bigint[], liveReserve = 0): SineCurveData {
  if (raw.length !== 7) throw new Error('Invalid sine curve response')
  const [pL, boot, lam, target] = [raw[1], raw[2], raw[3], raw[4]].map(v => Number(v) / 1e18)
  const q0 = raw[5]
  if (![pL, boot, lam, target].every(v => Number.isFinite(v) && v > 0) || q0 <= 0n) {
    throw new Error('Curve has not been materialized')
  }
  if (!Number.isFinite(liveReserve) || liveReserve < 0) throw new Error('Invalid live reserve')
  const price = (r: number) => pL * Math.exp(SINE_V3.K * SINE_V3.H(SINE_V3.s((r - boot) / lam)))
  // Start with twelve postlaunch waves, then extend toward the live reserve.
  const waves = Math.max(12, Math.ceil((Math.max(target, sineChartHeadroom(liveReserve, lam, 3)) - boot) / lam))
  // Beyond this endpoint the remaining integral is below one mintable PSP
  // wei throughout the admitted launch domain. Match settlement capacity.
  const supportedEnd = boot + SINE_V3.maxWaves * lam
  const requestedEnd = boot + waves * lam
  const end = Math.min(requestedEnd, supportedEnd)
  const truncated = end < requestedEnd
  const start = 0
  const reserves = new Set<number>([start, 0, boot, Math.min(target, end)])
  for (let i = 1; i <= 64; i++) reserves.add(boot * i / 64) // prelaunch ramp
  const steps = Math.min(4096, Math.ceil((end - start) / lam) * 32)
  for (let i = 1; i <= steps; i++) reserves.add(start + (end - start) * i / steps)
  // Keep the launch and early waves resolved when distant reserves expand
  // the chart. A uniform distant grid would lose their supply curvature.
  const detailStart = Math.max(start, boot - 16 * lam)
  const detailEnd = Math.min(end, boot + 16 * lam)
  const detailSteps = Math.ceil((detailEnd - detailStart) / lam) * 128
  for (let i = 0; i <= detailSteps; i++) reserves.add(detailStart + (detailEnd - detailStart) * i / detailSteps)
  const grid = [...reserves].sort((a, b) => a - b)
  const bootIndex = grid.findIndex(r => r >= boot)
  const humanQ0 = Number(q0) / 1e18
  const supplies = new Array<number>(grid.length).fill(0)
  supplies[bootIndex] = humanQ0
  // Simpson per grid segment, anchored at boot and walked both directions.
  const step = (i: number, j: number) => {
    const a = grid[i], b = grid[j], d = b - a
    return d * (1 / price(a) + 4 / price(a + d / 2) + 1 / price(b)) / 6
  }
  for (let j = bootIndex + 1; j < grid.length; j++) supplies[j] = supplies[j - 1] + step(j - 1, j)
  for (let i = bootIndex - 1; i >= 0; i--) {
    supplies[i] = Math.max(0, supplies[i + 1] - step(i, i + 1))
    if (grid[i] === 0) supplies[i] = 0 // Q(0) = 0
  }
  const points: CurvePoint[] = grid.map((r, i) => ({ reserve: r, price: price(r), supply: supplies[i] }))
  // Ten postlaunch wave milestones plus the launch: multiples 1 → 1000.
  // Do NOT label each wave a fixed doubling — cube-root growth shapes log price.
  const markers: SineMarker[] = []
  for (let n = 0; n <= 10; n++) {
    const r = boot + lam * n
    if (r > end) break
    markers.push({ reserve: r, price: price(r), kind: n === 0 ? 'boot' : n === 10 ? 'milestone' : 'top', k: n * 4 })
  }
  return { truncated, active: true, configured: true, boot, span: target - boot, top: target,
    q0, checkpoints: [], points, markers }
}

export function sineChartHeadroom(liveReserve: number, wavelength: number, version: SineRulesVersion = 1): number {
  return liveReserve + Math.max(version === 1 ? 1000 : 0, wavelength, liveReserve * 0.1)
}
