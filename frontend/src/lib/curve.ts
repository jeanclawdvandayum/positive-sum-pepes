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
/// Grid concentrates points around zone boundaries where the curve bends.
export function sampleCurve(cc: CurveConfig, liveSupply: bigint, n = 320): CurvePoint[] {
  // chart domain: up to 1.15x the larger of (live supply, last finite zone end)
  const finiteEnds = cc.zones.filter((z) => z.endSupply < 2n ** 100n).map((z) => z.endSupply)
  const domainEnd =
    finiteEnds.length > 0 ? finiteEnds[finiteEnds.length - 1] : liveSupply * 115n / 100n
  const sMax = (domainEnd > liveSupply ? domainEnd : liveSupply * 115n / 100n)

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

  // include every zone boundary in the grid so bends land on sample points
  const bounds = cc.zones.map((z) => z.startSupply).filter((b) => b > 0n && b < sMax)
  const grid: bigint[] = []
  for (let i = 0; i <= n; i++) {
    grid.push(BigInt(Math.round((Number(sMax) * i) / n)))
  }
  for (const b of bounds) if (!grid.some((g) => Number(g) === Number(b))) grid.push(b)
  grid.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0))

  for (const g of grid) {
    if (g > BigInt(Math.round(prevS * WAD)) - 1n) push(g)
  }
  return pts
}
