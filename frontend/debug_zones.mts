import { readFileSync } from 'fs'
import { marginalPrice } from '/Users/clawdbot/clawd/positive-sum-pepes/frontend/src/lib/curve.ts'
const zones = JSON.parse(readFileSync('/tmp/live_zones.json', 'utf8')).map((z: any) => ({ startSupply: BigInt(z.s), endSupply: BigInt(z.e), rate: BigInt(z.r), isExponential: z.f }))
const cc = { p0: 100000000000000n, zones }
const WAD = 1e18
// numeric reserve integral, per-zone, fine grid (trapezoid on marginalPrice)
let reserve = 0
let prevS = 0
let prevP = 1e-4
const per = 60
console.log('idx kind      dS(PSP)      dR(mix)     R0        R1        P0        P1     growth')
for (let i = 0; i < zones.length; i++) {
  const z = zones[i]
  const open = z.endSupply > 2n ** 200n
  const s1 = open ? z.startSupply * 3n / 2n : z.endSupply
  const r0 = reserve
  const p0z = Number(marginalPrice(z.startSupply, cc)) / WAD
  for (let j = 1; j <= per; j++) {
    const s = z.startSupply + (s1 - z.startSupply) * BigInt(j) / BigInt(per)
    const p = Number(marginalPrice(s, cc)) / WAD
    const sf = Number(s) / WAD
    reserve += (prevP + p) / 2 * (sf - prevS)
    prevS = sf
    prevP = p
  }
  const p1z = open ? p0z : Number(marginalPrice(z.endSupply, cc)) / WAD
  console.log(
    String(i).padStart(3),
    z.isExponential ? 'exp' : 'log',
    ((Number(s1 - z.startSupply)) / WAD).toExponential(2).padStart(11),
    (reserve - r0).toExponential(2).padStart(11),
    r0.toExponential(2).padStart(9),
    reserve.toExponential(2).padStart(9),
    p0z.toExponential(2).padStart(9),
    p1z.toExponential(2).padStart(9),
    (p1z / p0z).toFixed(4),
  )
  if (open) break
}
// visual geometry: per leg, fraction of leg's reserve-span taken by cliff vs tread
// and slope ratio (decades of price per decade of reserve)
console.log('\nleg geometry (cliff vs tread, log-log slope):')
for (let leg = 0; leg < 16; leg++) {
  const cliff = zones[leg * 2], tread = zones[leg * 2 + 1]
  if (!tread || tread.startSupply > 2n ** 200n) break
  // compute spans from the table above conceptually — use marginalPrice walk directly
  // cliff span in R: integrate
  const span = (z: typeof cliff, open: boolean) => {
    let r = 0, ps = 0, pp = Number(marginalPrice(z.startSupply, cc)) / WAD
    const s1 = open ? z.startSupply : z.endSupply
    for (let j = 1; j <= 40; j++) {
      const s = z.startSupply + (s1 - z.startSupply) * BigInt(j) / 40n
      const p = Number(marginalPrice(s, cc)) / WAD
      const sf = Number(s) / WAD
      r += (pp + p) / 2 * (sf - ps)
      ps = sf; pp = p
    }
    return r
  }
  const rc = span(cliff, false), rt = span(tread, false)
  const pc0 = Number(marginalPrice(cliff.startSupply, cc)) / WAD
  const pc1 = Number(marginalPrice(cliff.endSupply, cc)) / WAD
  const pt1 = Number(marginalPrice(tread.endSupply, cc)) / WAD
  const slope = (dP: number, dR: number, R0: number, R1: number) => Math.log10(dP) / Math.log10(R1 / Math.max(R0, 1e-9))
  console.log(`leg ${String(leg+1).padStart(2)}: cliffR=${rc.toFixed(0).padStart(6)} treadR=${rt.toFixed(0).padStart(6)} ratio=${(rc/(rc+rt)).toFixed(2)} | cliffGrowth=${(pc1/pc0).toFixed(3)} treadGrowth=${(pt1/pc1).toFixed(3)} | cliffLogSlope≈${(Math.log10(pc1/pc0)/Math.log10((rc*0.7+1)/(0.3*rc+1))).toFixed(2)} treadLogSlope≈${(Math.log10(pt1/pc1)/Math.log10((rc+rt)/(rc+rt*0.3))).toFixed(2)}`)
}
