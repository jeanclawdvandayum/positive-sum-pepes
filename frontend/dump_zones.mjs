import { decodeAbiParameters, parseAbiParameters } from 'viem'
import { readFileSync, writeFileSync } from 'fs'
const h = readFileSync('/tmp/z.hex', 'utf8').trim()
const zones = decodeAbiParameters(parseAbiParameters('(uint256 startSupply,uint256 endSupply,uint256 rate,bool isExponential)[]'), h)[0]
writeFileSync('/tmp/live_zones.json', JSON.stringify(zones.map(z => ({ s: z.startSupply.toString(), e: z.endSupply.toString(), r: z.rate.toString(), f: z.isExponential }))))
console.log('dumped', zones.length, 'zones')
