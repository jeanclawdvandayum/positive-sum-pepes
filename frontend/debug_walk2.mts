import { readFileSync } from 'fs'
import { sampleCurve } from '/Users/clawdbot/clawd/positive-sum-pepes/frontend/src/lib/curve.ts'
const zones = JSON.parse(readFileSync('/tmp/live_zones.json', 'utf8')).map((z: any) => ({ startSupply: BigInt(z.s), endSupply: BigInt(z.e), rate: BigInt(z.r), isExponential: z.f }))
const cc = { p0: 100000000000000n, zones }
const pts = sampleCurve(cc, 3333000000000000000000000n)
console.log('n pts:', pts.length)
for (const i of [0, 1, 2, 5, 20, 40, 60, 100, 200, pts.length - 1]) console.log(i, pts[i].supply.toExponential(3), pts[i].price.toExponential(3), pts[i].reserve.toExponential(3))
for (const t of [1e-3, 1e-2, 0.1, 1]) {
  const hit = pts.find(p => p.price >= t)
  console.log(`price>=${t}: supply=${hit?.supply?.toExponential(3)} reserve=${hit?.reserve?.toExponential(3)}`)
}
