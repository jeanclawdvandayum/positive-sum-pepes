import { readFileSync, writeFileSync } from 'fs'
import { decodeAbiParameters, parseAbiParameters } from 'viem'
import { marginalPrice, sampleCurve } from './src/lib/curve.ts'
const h = readFileSync('/tmp/z.hex', 'utf8').trim()
const zones = decodeAbiParameters(parseAbiParameters('(uint256 startSupply,uint256 endSupply,uint256 rate,bool isExponential)[]'), h)[0]
const p0 = 100000000000000n
const cc = { p0, zones }
writeFileSync('/tmp/live_zones.json', JSON.stringify(zones.map(z => ({ s: z.startSupply.toString(), e: z.endSupply.toString(), r: z.rate.toString(), f: z.isExponential })), null, 1))
const pts = sampleCurve(cc, 3333000000000000000000000n)
console.log('n pts:', pts.length)
const probe = [0, 1, 2, 5, 20, 40, 60, 80, 100, 150, 200, 250, 300, pts.length - 1]
for (const i of probe) console.log(i, JSON.stringify(pts[i]))
// expected anchor reserves
for (const [s, label] of [[0n, 'leg1 A'], [0n, 'skip']]) { break }
const legEnds = zones.filter((z, i) => i > 0 && i < zones.length - 1 && !z.isExponential).map(z => z.startSupply)
console.log('tread zone starts (=leg E boundaries, supply):', legEnds.slice(0, 5).map(x => (Number(x) / 1e18).toExponential(3)).join(' '))
// find where price crosses decades and what reserve the integrator reports
for (const t of [1e-3, 1e-2, 0.1, 1]) {
  const hit = pts.find(p => p.price >= t)
  console.log(`price>=${t}: supply=${hit?.supply?.toExponential(3)} reserve=${hit?.reserve?.toExponential(3)}`)
}
