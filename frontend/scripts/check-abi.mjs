import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { encodeFunctionData, decodeFunctionData, toFunctionSelector, toEventSelector } from 'viem'
import * as declared from '../src/lib/abi.ts'
import { wnsAbi } from '../src/lib/weiNames.ts'
import { remoteNameGateAbi } from '../src/lib/namePermit.ts'
import { nameRegistrarAbi, nameGateAbi } from '../src/lib/nameRegistration.ts'
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..')
const sources={factoryAbi:'PSPFactory',controllerAbi:'RoundController',hookAbi:'CurveHook',stakerAbi:'PSPStaker',registryAbi:'PSPReferralRegistry',zapInAbi:'PSPZapIn',zapOutAbi:'PSPZapOut',reinvestorAbi:'PSPReinvestor',faucetAbi:'MixETHFaucet',descriptorAbi:'PepeDescriptor',wnsAbi:'IWeiNames',nameRegistrarAbi:'PSPNameRegistrar',nameGateAbi:'PSPStakeNameGate',remoteNameGateAbi:'PSPRemoteNameGate'}
const allDeclared = { ...declared, wnsAbi, nameRegistrarAbi, nameGateAbi, remoteNameGateAbi }
// Static tuples and flat outputs encode identically. Preserve dynamic tuple
// boundaries while normalizing static struct return shapes (positions).
function types(params=[]) { return params.flatMap(p=>p.type==='tuple' && p.components.every(c=>!['string','bytes','tuple'].includes(c.type)&&!c.type.includes('[')) ? types(p.components) : [p.type==='tuple'?`(${types(p.components)})`:p.type]) }
let checked=0
for(const [key,name] of Object.entries(sources)) {
 const abi=JSON.parse(fs.readFileSync(path.join(root,'out',name+'.sol',name+'.json'))).abi
 for(const item of allDeclared[key]) {
  if(!['function','event'].includes(item.type))continue
  const selector=item.type==='function'?toFunctionSelector:toEventSelector
  const actual=abi.find(a=>a.type===item.type&&selector(a)===selector(item))
  assert(actual,`${key}: missing ${item.type} ${item.name}`)
  if(item.type==='function') assert.deepEqual(types(item.outputs),types(actual.outputs),`${key}.${item.name}: output drift`)
  else {
   assert.deepEqual(item.inputs.map(p=>Boolean(p.indexed)),actual.inputs.map(p=>Boolean(p.indexed)),`${key}.${item.name}: event index drift`)
   assert.deepEqual(item.inputs.map(p=>p.name),actual.inputs.map(p=>p.name),`${key}.${item.name}: decoded event field drift`)
  }
  checked++
 }
}
const a='0x0000000000000000000000000000000000000001',b='0x0000000000000000000000000000000000000002',h='0x0000000000000000000000000000000000000003'
const key=declared.buildPoolKey(b,a,h)
const args=[key,5_000_000_000_000_000n,1n,1800000000n]
const encoded=encodeFunctionData({abi:declared.zapInAbi,functionName:'buyWithMix',args})
assert.equal(decodeFunctionData({abi:declared.zapInAbi,data:encoded}).args[0].fee,0x800000)
assert.equal(encoded,encodeFunctionData({abi:declared.zapInAbi,functionName:'buyWithMix',args:[[a,b,0x800000,60,h],...args.slice(1)]}))
console.log(`ABI gate: ${checked} functions/events match Foundry artifacts; PoolKey encoding exact.`)
