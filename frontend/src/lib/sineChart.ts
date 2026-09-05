import type { CurvePoint } from './curve'

export interface SineMarker {
  reserve: number // mixETH, human units
  price: number // mixETH per PSP, human units
  kind: 'boot' | 'anchor' | 'top'
  k: number // quarter-wave index (0..12; treads at 0/4/8/12)
}

export interface SineCurveData {
  active: boolean
  configured: boolean
  boot: number // human units
  span: number // seam→target distance
  top: number // the target reserve (the 0.06 tread)
  q0: bigint // launch mint (wei PSP) — supply baked in at boot
  checkpoints: bigint[] // retired — empty for the indefinite curve
  points: CurvePoint[]
  markers: SineMarker[]
}

/** Display-only sampling from the hook's immutable, materialized coefficients.
 * Quotes/minOut always come from the contract. Numbers here use human units. */
export function sampleSineChart(raw: readonly bigint[]): SineCurveData {
  if (raw.length !== 11) throw new Error('Invalid sine curve response')
  const [p0, preK, boot, target, lam, B, slope, amp, , , q0] = raw.map(v => Number(v) / 1e18)
  if (![p0, preK, boot, target, lam, B, slope, q0].every(v => Number.isFinite(v) && v > 0)) {
    throw new Error('Curve has not been materialized')
  }
  const price = (r: number) => r <= boot ? p0 * Math.exp(preK * r)
    : B * Math.exp(slope * (r - boot) - amp * Math.sin(2 * Math.PI * ((r - boot) % lam) / lam))
  const reserves = new Set<number>([0, boot, target])
  // Dense local geometry costs no extra RPC reads; cover the predeposit ramp
  // even when the final raise is tiny compared with the wavelength.
  for (let i = 1; i <= 64; i++) reserves.add(boot * i / 64)
  for (let i = 1; i <= 512; i++) reserves.add(boot + 4 * lam * i / 512)
  const grid = [...reserves].sort((a, b) => a - b)
  let supply = q0
  const points = grid.map((r, i) => {
    if (r > boot) {
      const left = grid[i - 1], d = r - left
      // Simpson integration: mixETH / (mixETH per PSP) is human PSP.
      supply += d * (1 / price(left) + 4 / price(left + d / 2) + 1 / price(r)) / 6
    }
    return { reserve: r, price: price(r), supply: r <= boot
      ? q0 * -Math.expm1(-preK * r) / -Math.expm1(-preK * boot) : supply }
  })
  const markers: SineMarker[] = [{ reserve: boot, price: B, kind: 'boot', k: 0 }]
  for (let k = 1; k <= 12; k++) {
    const r = boot + lam * k / 4
    markers.push({ reserve: r, price: price(r), kind: k % 4 === 0 ? 'top' : 'anchor', k })
  }
  return { active: true, configured: true, boot, span: target - boot, top: target,
    q0: raw[10], checkpoints: [], points, markers }
}
