/// TS port of CurveMath.marginalPrice — only the price walk, which is all the
/// chart needs (no Newton integrals; reserve is integrated numerically below).
/// All inputs/outputs are 1e18 wads, matching the contract.

export interface Zone {
  startSupply: bigint // 1e18
  endSupply: bigint // 1e18
  rate: bigint // 1e18
  isExponential: boolean
}

export interface CurveConfig {
  p0: bigint // price at supply 0, 1e18
  zones: Zone[]
}

const WAD = 1e18

/// marginal price at supply s (wad), faithful to CurveMath including the
/// carried price across zones and the lnAbs floor in log zones.
export function marginalPrice(s: bigint, cc: CurveConfig): bigint {
  if (s === 0n) return cc.p0
  let price = cc.p0
  for (const z of cc.zones) {
    if (s <= z.startSupply) break
    const evalPoint = s < z.endSupply ? s : z.endSupply
    if (z.isExponential) {
      // P = P_start * e^(k * delta)
      const delta = Number(evalPoint - z.startSupply) / WAD
      const k = Number(z.rate) / WAD
      price = BigInt(Math.round(Number(price) * Math.exp(Math.min(k * delta, 135))))
    } else {
      // P = P_start * (1 + k * |ln(s / s_start)|)  — contract clamps ln to >= 0
      const sStart = Number(z.startSupply) / WAD
      const sEv = Math.min(Number(evalPoint) / WAD, 1e10)
      const lnAbs = Math.abs(Math.log(sEv / sStart))
      const k = Number(z.rate) / WAD
      price = BigInt(Math.round(Number(price) * (1 + k * lnAbs)))
    }
    if (s <= z.endSupply) break
  }
  return price
}

export interface CurvePoint {
  reserve: number // mixETH, human units
  supply: number // PSP, human units
  price: number // mixETH per PSP, human units
}

/// Sample the curve: reserve(s) via numeric integration of marginalPrice.
/// Grid: per-zone geometric — every zone (cliff, tread, seed, tail) gets the
/// same number of interior points, so every leg stays resolved no matter how
/// late/small it is. Required for the log-x chart (2026-08-19): a
/// uniform-in-supply grid starves the late legs to zero points and fakes a
/// smooth line. Tail zone (open end) gets a log ramp beyond its start.
export function sampleCurve(cc: CurveConfig, liveSupply: bigint, perZone = 10): CurvePoint[] {
  const pts: CurvePoint[] = []
  let reserve = 0
  let prevS = 0
  let prevP = Number(cc.p0) / WAD
  const push = (sWad: bigint) => {
    const p = Number(marginalPrice(sWad, cc)) / WAD
    const s = Number(sWad) / WAD
    const ds = s - prevS
    // trapezoid in human units
    reserve += ((prevP + p) / 2) * ds
    prevS = s
    prevP = p
    pts.push({ reserve, supply: s, price: p })
  }

  // grid: zone boundaries + geometric interior points per zone
  const grid: bigint[] = [0n]
  for (const z of cc.zones) {
    if (z.startSupply > 0n) grid.push(z.startSupply)
    const finite = z.endSupply < 2n ** 200n
    if (finite) {
      const s0 = Number(z.startSupply)
      const s1 = Number(z.endSupply)
      if (s1 > s0) {
        // geometric interp; zones starting at 0 fall back to linear.
        // NOTE: s0/s1 are wad-scale floats — do NOT multiply by WAD again.
        for (let i = 1; i <= perZone; i++) {
          const t = i / (perZone + 1)
          const s = s0 === 0 ? s1 * t : s0 * Math.pow(s1 / s0, t)
          grid.push(BigInt(Math.round(s)))
        }
      }
    } else {
      // open tail: log ramp to 3x its start (bounded by live supply too)
      const s0 = Number(z.startSupply)
      const sCap = Math.max(s0 * 3, Number(liveSupply) * 1.15)
      for (let i = 1; i <= 12; i++) {
        grid.push(BigInt(Math.round(s0 * Math.pow(sCap / s0, i / 12))))
      }
    }
  }
  grid.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0))
  const seen = new Set<string>()
  for (const g of grid) {
    const key = g.toString()
    if (!seen.has(key)) {
      seen.add(key)
      push(g)
    }
  }
  return pts
}
