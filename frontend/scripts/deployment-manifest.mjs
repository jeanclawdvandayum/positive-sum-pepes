/** Read-only chain inspection. Usage:
 * PSP_RPC_URL=... node --experimental-strip-types frontend/scripts/deployment-manifest.mjs FACTORY OUTPUT.json
 * Do not pass private keys. Publish only after reviewing a clean source revision.
 */
import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { createPublicClient, http, isAddress, keccak256, parseAbi } from 'viem'
import { factoryAbi, controllerAbi, hookAbi } from '../src/lib/abi.ts'
const [factory, output]=process.argv.slice(2)
if(!isAddress(factory??'')||!output||!process.env.PSP_RPC_URL)throw Error('Provide FACTORY OUTPUT.json and PSP_RPC_URL')
const client=createPublicClient({transport:http(process.env.PSP_RPC_URL)})
const block=await client.getBlock()
const read=(address,abi,functionName,args=[])=>client.readContract({address,abi,functionName,args,blockNumber:block.number})
const chainId=await client.getChainId()
const roundId=await read(factory,factoryAbi,'currentRoundId')
const [token,controller,hook,destroyed,name,symbol]=await read(factory,factoryAbi,'rounds',[roundId])
const staker=await read(controller,controllerAbi,'staker')
const mix=await read(factory,factoryAbi,'mixETH')
const registry=await read(factory,factoryAbi,'referralRegistryOf',[roundId])
const addresses={factory,token,controller,hook,staker,mix,registry}
for (const [name, variable] of Object.entries({zapIn:'PSP_ZAPIN',zapOut:'PSP_ZAPOUT',faucet:'PSP_FAUCET',reinvestor:'PSP_REINVESTOR'})) {
 const value=process.env[variable]
 if(value){if(!isAddress(value))throw Error(`Invalid ${variable}`);addresses[name]=value}
}
const addressGetter=name=>parseAbi([`function ${name}() view returns(address)`])
for(const name of ['owner','descriptor','poolManager','hookDeployer','controllerDeployer','stakerDeployer','tokenDeployer']){
 const address=await read(factory,addressGetter(name),name)
 if(name==='owner')continue // signer may be an EOA, not a code-bearing contract
 addresses[name]=address
}
const codeHashes={}
for(const [key,address] of Object.entries(addresses)){
 const code=await client.getCode({address,blockNumber:block.number})
 if(!code||code==='0x')throw Error(`Missing deployed code: ${key}`)
 codeHashes[key]=keccak256(code)
}
const params=await read(hook,parseAbi(['function sineParams() view returns(uint256 p0,uint256 preK,uint256 pTarget,uint256 targetReserve,uint24 ampBps)']),'sineParams')
const minimumBuy=await read(hook,hookAbi,'MIN_BUY_INPUT')
const timePerUnit=await read(hook,hookAbi,'TIME_PER_UNIT')
if(minimumBuy!==5_000_000_000_000_000n||timePerUnit!==260n)throw Error('Deployment does not match approved game rules')
const revision=execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim()
// Historical broadcast receipts may remain dirty; they are execution records,
// not release inputs. All other tracked and untracked inputs must be committed.
const dirty=execFileSync('git',['status','--porcelain','--untracked-files=all','--','.',':(exclude)broadcast/**'],{encoding:'utf8'}).trim().length>0
if(dirty)throw Error('Record a clean source revision before generating a release manifest (historical broadcasts are excluded)')
const uintGetter=name=>parseAbi([`function ${name}() view returns(uint256)`])
const timings={}
for(const name of ['PREDEPOSIT_DURATION','VEST_DURATION','PREDEPOSIT_CAP_PER_WALLET'])timings[name]=await read(controller,uintGetter(name),name)
timings.detWindow=await read(hook,uintGetter('detWindow'),'detWindow')
const owner=await read(factory,addressGetter('owner'),'owner')
if(addresses.reinvestor){
 for(const [getter,target] of [['staker',staker],['psp',token],['mix',mix],['zapIn',addresses.zapIn]]){
  if(!target||String(await read(addresses.reinvestor,addressGetter(getter),getter)).toLowerCase()!==target.toLowerCase())throw Error(`Reinvestor ${getter} wiring mismatch`)
 }
}
const manifest={schema:2,chainId,block:block.number,blockHash:block.hash,revision,owner,addresses,codeHashes,round:{roundId,name,symbol,destroyed},params,timings,rules:{minimumBuy,timePerUnit},sourceVerification:'see companion verification record'}
fs.mkdirSync(path.dirname(output),{recursive:true})
fs.writeFileSync(output,JSON.stringify(manifest,(_,v)=>typeof v==='bigint'?v.toString():v,2)+'\n',{flag:'wx'})
console.log(`Manifest written: ${output}`)
