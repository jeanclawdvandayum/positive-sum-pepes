// Pin JS renderer output for independent Solidity parity tests.
import {buildSync} from '../frontend/node_modules/esbuild/lib/main.js'
import {keccak256, stringToHex} from '../frontend/node_modules/viem/_esm/index.js'
import {readFileSync, writeFileSync} from 'node:fs'
import assert from 'node:assert/strict'
const bundled=buildSync({entryPoints:['frontend/src/lib/pepeRender.ts'],bundle:true,write:false,format:'esm',platform:'node'}).outputFiles[0].text
const {renderPepeSvg}=await import('data:text/javascript;base64,'+Buffer.from(bundled).toString('base64'))
const dna=[0n,10n,11n,10n<<4n,10n<<8n,10n<<12n,11n<<12n,10n<<16n,0xffffffffn,0x99999999n,0xaaaaaaaaaan,0x123456789abcdn]
const output=JSON.stringify({dna:dna.map(Number),expanded:dna.map(d=>keccak256(stringToHex(renderPepeSvg(d,2n)))),legacy:dna.map(d=>keccak256(stringToHex(renderPepeSvg(d,1n))))},null,2)+'\n'
// Restrict fixture values to safe JSON numbers.
assert(dna.every(d=>d<=BigInt(Number.MAX_SAFE_INTEGER)))
if(process.argv.includes('--check'))assert.equal(readFileSync('script/expanded-art-fixtures.json','utf8'),output)
else writeFileSync('script/expanded-art-fixtures.json',output)
console.log('Expanded and legacy client renderer fixtures verified')
