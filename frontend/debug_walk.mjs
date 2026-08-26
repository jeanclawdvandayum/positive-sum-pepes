import { readFileSync } from 'fs'
import { decodeAbiParameters, parseAbiParameters } from 'viem'
import { marginalPrice } from './src/lib/curve.ts'
const h = readFileSync('/tmp/z.hex', 'utf8').trim()
const zones = decodeAbiParameters(parseAbiParameters('(uint256 startSupply,uint256 endSupply,uint256 rate,bool isExponential)[]'), h)[0]
const cc = { p0: 100000000000000n, zones }
console.log('zones:', zones.length)
// walk grid points like sampleCurve does, printing progress
const perZone = 10
const grid = [0n]
for (const z of cc.zones) {
  if (z.startSupply > 0n) grid.push(z.startSupply)
  const finite = z.endSupply < 2n ** 200n
  if (finite) {
    const s0 = Number(z.startSupply), s1 = Number(z.endSupply)
    if (s1 > s0) for (let i = 1; i <= perZone; i++) {
      const t = i / (perZone + 1)
      const s = s0 === 0 ? s1 * t : s0 * Math.pow(s1 / s0, t)
      grid.push(BigInt(Math.round(s * 1e18)))
    }
  } else {
    const s0 = Number(z.startSupply)
    const sCap = Math.max(s0 * 3, 3333000000000000000000000 * 1.15)
    for (let i = 1; i <= 12; i++) grid.push(BigInt(Math.round(s0 * Math.pow(sCap / s0, i / 12) * 1e18)))
  }
}
console.log('grid size:', grid.length, 'min:', grid[0].toString(), 'max:', grid[grid.length-1].toString())
grid.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0))
console.log('sorted')
const seen = new Set()
let n = 0
for (const g of grid) {
  const key = g.toString()
  if (seen.has(key)) continue
  seen.add(key)
  const t0 = Date.now()
  const p = marginalPrice(g, cc)
  n++
  if (Date.now() - t0 > 500) console.log('SLOW at', g.toString(), Date.now() - t0, 'ms')
  if (n % 50 === 0) console.log('progress', n, 'price', p.toString())
}
console.log('done', n, 'calls')
