/// Tilted-sine curve support (2026-08): the hook can run the sine pricing
/// curve instead of the zone curve. All curve geometry is static once armed,
/// so the full sample is fetched ONCE per hook address and cached — the
/// 4s round loop only re-reads the light live state (reserve/supply/price).
import { rpcCall } from './rpc'
import { hookAbi } from './abi'
import type { CurvePoint } from './curve'

export interface SineMarker {
  reserve: number // mixETH, human units
  price: number // mixETH per PSP, human units
  kind: 'boot' | 'anchor' | 'top'
  k: number // quarter-wave index (0..12)
}

export interface SineCurveData {
  active: boolean
  configured: boolean
  boot: number // human units
  span: number
  top: number // boot + span
  q0: bigint // launch mint (wei PSP) — supply baked in at boot
  checkpoints: bigint[] // 13× cumulative curve supply at anchors (wei PSP)
  points: CurvePoint[]
  markers: SineMarker[]
}

const cache = new Map<string, Promise<SineCurveData>>()

/// Sample the live sine curve off the hook: ~100 uniform reserves across
/// [0, top + 1500] plus the exact anchors (boot, every quarter-wave, top).
/// Supply comes from numerically integrating dS = dR / P: post-boot it is
/// q0 + ∫_boot^R (matches totalSupplyPSP — q0 is the launch mint), pre-boot
/// the phase is rescaled so supply goes 0 → q0 across the predeposit ramp.
export function loadSineCurve(hook: `0x${string}`): Promise<SineCurveData> {
  let p = cache.get(hook)
  if (!p) {
    p = sample(hook)
    p.catch(() => cache.delete(hook)) // allow retry on transient RPC failure
    cache.set(hook, p)
  }
  return p
}

async function sample(hook: `0x${string}`): Promise<SineCurveData> {
  const [configured, active, raw, cps] = await Promise.all([
    rpcCall(hook, hookAbi, 'sineConfigured') as Promise<boolean>,
    rpcCall(hook, hookAbi, 'sineActive') as Promise<boolean>,
    rpcCall(hook, hookAbi, 'sineCurve') as Promise<bigint[]>,
    rpcCall(hook, hookAbi, 'getSineCheckpoints') as Promise<[bigint, ...bigint[]]>,
  ])
  const [, , boot, span, segWidth, , , , , , , q0] = raw
  const bootN = Number(boot) / 1e18
  const spanN = Number(span) / 1e18
  const topN = bootN + spanN
  const endR = topN + 1500 // headroom past the top shows the tail
  const q0n = Number(q0)

  if (!configured || !active || raw.length < 12 || !(bootN > 0)) {
    return {
      active: false, configured, boot: bootN, span: spanN, top: topN, q0: q0 ?? 0n,
      checkpoints: [...cps], points: [], markers: [],
    }
  }

  // grid: uniform sweep + exact landmarks (boot, 12 quarter-wave anchors, top)
  const N = 100
  const grid = new Set<bigint>()
  const push = (rWad: bigint) => grid.add(rWad)
  push(0n)
  const stepWad = BigInt(Math.round((endR * 1e18) / N))
  for (let i = 1; i <= N; i++) push(stepWad * BigInt(i))
  for (let k = 0; k <= 12; k++) push(boot + segWidth * BigInt(k))
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

  // markers: launch tread + every quarter-wave anchor; tops at k=4/8/12
  const at = (k: number) => R.indexOf(boot + segWidth * BigInt(k))
  const anchorPrice = (k: number) => Number(prices[at(k)]) / 1e18
  const markers: SineMarker[] = [{ reserve: bootN, price: anchorPrice(0), kind: 'boot', k: 0 }]
  for (let k = 1; k <= 12; k++) {
    markers.push({
      reserve: Number(boot + segWidth * BigInt(k)) / 1e18,
      price: anchorPrice(k),
      kind: k % 4 === 0 ? 'top' : 'anchor',
      k,
    })
  }

  return {
    active: true, configured, boot: bootN, span: spanN, top: topN, q0,
    checkpoints: [...cps], points, markers,
  }
}

/// human-readable tag for a marker (chart labels)
export function markerLabel(m: SineMarker, fmtPrice: (v: bigint) => string): string {
  const p = fmtPrice(BigInt(Math.round(m.price * 1e18)))
  if (m.kind === 'boot') return `launch ${p}`
  if (m.k === 4) return `wave 1 top ${p}`
  if (m.k === 8) return `wave 2 top ${p}`
  if (m.k === 12) return `top ${p}`
  return ''
}
