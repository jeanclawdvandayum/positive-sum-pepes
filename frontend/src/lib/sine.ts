// Tilted-sine curve support (2026-09): the hook runs the INDEFINITE tilted
// sine — one endless wave past the launch seam, trend anchored so the price
// hits pTarget at targetReserve. All curve geometry is static once armed
// (materialized at launch), so the full sample is fetched ONCE per hook
// address and cached — the 4s round loop only re-reads the light live state
// (reserve/supply/price).
import { rpcCall } from './rpc'
import { hookAbi } from './abi'
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

const cache = new Map<string, Promise<SineCurveData>>()

/// Sample the live sine curve off the hook: ~110 uniform reserves across
/// [0, target + one wavelength] plus the exact landmarks (boot, every wave
/// seam, the target tread). Supply comes from numerically integrating
/// dS = dR / P: post-boot it is q0 + ∫_boot^R (matches totalSupplyPSP —
/// q0 is the launch mint), pre-boot the phase is rescaled so supply goes
/// 0 → q0 across the predeposit ramp.
async function sample(hook: `0x${string}`): Promise<SineCurveData> {
  const [configured, active, raw] = await Promise.all([
    rpcCall(hook, hookAbi, 'sineConfigured') as Promise<boolean>,
    rpcCall(hook, hookAbi, 'sineActive') as Promise<boolean>,
    rpcCall(hook, hookAbi, 'sineCurve') as Promise<bigint[]>,
  ])
  // getter shape (2026-09-03): (p0, preK, boot, targetReserve, lam, B,
  // slope, amp, g, W, q0) — no checkpoints, no span, no top.
  const [, , boot, targetReserve, lam, , , , , , q0] = raw
  const bootN = Number(boot) / 1e18
  const targetN = Number(targetReserve) / 1e18
  const lamN = Number(lam) / 1e18
  const endR = targetN + lamN // one wavelength of headroom past the target
  const q0n = Number(q0)

  if (!configured || !active || raw.length < 11 || !(bootN > 0) || !(lamN > 0)) {
    return {
      active: false, configured, boot: bootN, span: targetN - bootN, top: targetN, q0: q0 ?? 0n,
      checkpoints: [], points: [], markers: [],
    }
  }

  // grid: uniform sweep + exact landmarks (boot, wave seams, target tread)
  const N = 100
  const grid = new Set<bigint>()
  const push = (rWad: bigint) => grid.add(rWad)
  push(0n)
  const stepWad = BigInt(Math.round((endR * 1e18) / N))
  for (let i = 1; i <= N; i++) push(stepWad * BigInt(i))
  for (let j = 0; j <= 3; j++) push(boot + lam * BigInt(j))
  const R = [...grid].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0))

  // one eth_call per sample — a one-shot ~110-call burst, cached forever after
  const prices = await Promise.all(
    R.map((r) => rpcCall(hook, hookAbi, 'sinePriceAt', [r]) as Promise<bigint>),
  )

  // cumulative ∫dR/P in wad-PSP (dS_wad = dR_wad / P_wad — 1e18 factors cancel)
  const I = [0]
  for (let i = 1; i < R.length; i++) {
    const dR = Number(R[i] - R[i - 1])
    I.push(I[i - 1] + (dR * (1 / Number(prices[i - 1]) + 1 / Number(prices[i]))) / 2)
  }
  const iBoot = R.indexOf(boot)
  const supplyWad = (i: number) =>
    i <= iBoot ? (q0n * I[i]) / I[iBoot] : q0n + (I[i] - I[iBoot])

  const points: CurvePoint[] = R.map((r, i) => ({
    reserve: Number(r) / 1e18,
    supply: supplyWad(i) / 1e18,
    price: Number(prices[i]) / 1e18,
  }))

  const priceOfR = (rWad: bigint): number => {
    const idx = R.indexOf(rWad)
    return idx >= 0 ? Number(prices[idx]) / 1e18 : 0
  }

  // markers: launch tread + every quarter-wave anchor; the seams (k=4/8/12)
  // are wave tops — flat treads — highlighted as tops
  const markers: SineMarker[] = [{ reserve: bootN, price: priceOfR(boot), kind: 'boot', k: 0 }]
  for (let j = 1; j <= 3; ++j) {
    const seam = boot + lam * BigInt(j)
    markers.push({ reserve: Number(seam) / 1e18, price: priceOfR(seam), kind: 'top', k: 4 * j })
    if (j < 3) {
      for (const q of [1, 2, 3]) {
        const r = boot + lam * BigInt(j) + (lam * BigInt(q)) / 4n
        markers.push({ reserve: Number(r) / 1e18, price: priceOfR(r), kind: 'anchor', k: 4 * j + q })
      }
    }
  }

  return {
    active: true, configured, boot: bootN, span: targetN - bootN, top: targetN, q0,
    checkpoints: [], points, markers,
  }
}

export function loadSineCurve(hook: `0x${string}`): Promise<SineCurveData> {
  let p = cache.get(hook)
  if (!p) {
    p = sample(hook)
    p.catch(() => cache.delete(hook)) // allow retry on transient RPC failure
    cache.set(hook, p)
  }
  return p
}

/// human-readable tag for a marker (chart labels)
export function markerLabel(m: SineMarker, fmtPrice: (v: bigint) => string): string {
  const p = fmtPrice(BigInt(Math.round(m.price * 1e18)))
  if (m.kind === 'boot') return `launch ${p}`
  if (m.k === 4) return `wave 1 top ${p}`
  if (m.k === 8) return `wave 2 top ${p}`
  if (m.k === 12) return `target tread ${p}`
  return ''
}
