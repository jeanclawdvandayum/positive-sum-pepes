import { decodeAbiParameters, parseAbiParameters } from 'viem'
import { readFileSync } from 'fs'
const h = readFileSync('/tmp/z.hex', 'utf8').trim()
const zones = decodeAbiParameters(parseAbiParameters('(uint256 startSupply,uint256 endSupply,uint256 rate,bool isExponential)[]'), h)[0]
console.log(`zones: ${zones.length}`)
const starts = zones.map(z => z.startSupply), ends = zones.map(z => z.endSupply)
console.log('starts at 0:', starts[0] === 0n, '| contiguous:', ends.slice(0, -1).every((e, i) => e === starts[i + 1]), '| tail open:', zones[zones.length - 1].endSupply === 2n ** 256n - 1n)
const expz = zones.filter(z => z.isExponential), logz = zones.filter(z => !z.isExponential)
console.log(`exp: ${expz.length}  log: ${logz.length}`)
const M = expz.slice(1).map(z => Math.exp(Number(z.rate) / 1e18 * Number(z.endSupply - z.startSupply) / 1e18))
console.log('cliffs M:', M.map(m => m.toFixed(4)).join(' '), `(min ${Math.min(...M).toFixed(4)} max ${Math.max(...M).toFixed(4)})`)
console.log(`tail starts at S = ${Number(zones[zones.length - 1].startSupply) / 1e18} PSP`)
