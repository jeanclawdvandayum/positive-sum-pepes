/** Receipt-checked ticket lifecycle. Uses only an unlocked, local Anvil node.
 * First run DeployPSP with PSP_ANVIL=1 on this node. No environment secrets used.
 * node frontend/scripts/anvil-tickets.mjs
 */
import assert from 'node:assert/strict'
import { readFileSync, writeFileSync } from 'node:fs'
import { createPublicClient, createWalletClient, http, maxUint256, parseEther, decodeEventLog } from 'viem'
import { anvil } from 'viem/chains'
const url = 'http://127.0.0.1:18545'
const client = createPublicClient({ chain: anvil, transport: http(url) })
const wallet = createWalletClient({ chain: anvil, transport: http(url) })
assert.equal(await client.getChainId(), 31337)
assert.match(await client.request({method:'web3_clientVersion'}), /anvil/i)
const [owner, alice, bob, trader] = await wallet.getAddresses()
const artifact = name => JSON.parse(readFileSync(new URL(`../../out/${name}.sol/${name}.json`, import.meta.url)))
const broadcast = JSON.parse(readFileSync(new URL('../../broadcast/DeployPSP.s.sol/31337/run-latest.json', import.meta.url)))
const deployed = name => broadcast.transactions.find(t => t.contractName === name && t.transactionType === 'CREATE').contractAddress
const factory = deployed('PSPFactory'), mix = deployed('MockMixETH'), zap = deployed('PSPZapIn'), zapOut = deployed('PSPZapOut')
const read = (address, name, functionName, args=[]) => client.readContract({ address, abi:artifact(name).abi, functionName, args })
const receipts=[]
async function tx(account,address,name,functionName,args=[],expected='success') {
 const hash=await wallet.writeContract({account,address,abi:artifact(name).abi,functionName,args,gas:30_000_000n})
 const receipt=await client.waitForTransactionReceipt({hash})
 assert.equal(receipt.status,expected,`${functionName}: ${hash}`)
 receipts.push({functionName,hash,status:receipt.status,gas:receipt.gasUsed.toString()})
 console.log(`${expected}: ${functionName} ${hash}`)
 return receipt
}
async function warp(seconds) { await client.request({method:'evm_increaseTime',params:[Number(seconds)]});await client.request({method:'evm_mine'}) }
const now=async()=> (await client.getBlock()).timestamp
const eq=assert.equal
const eth=parseEther
const key=(token,hook)=>({currency0:mix.toLowerCase()<token.toLowerCase()?mix:token,currency1:mix.toLowerCase()<token.toLowerCase()?token:mix,fee:0x800000,tickSpacing:60,hooks:hook})
const [token,ctrl,hook]=await read(factory,'PSPFactory','rounds',[1n])
const staker=await read(ctrl,'RoundController','stakerAddress')
const pool=key(token,hook)
eq(await read(hook,'CurveHook','TIME_PER_UNIT'),69n)
eq(await read(hook,'CurveHook','detWindow'),248660n)
eq(await read(ctrl,'RoundController','PREDEPOSIT_CAP'),0n)
eq(await read(ctrl,'RoundController','PREDEPOSIT_RULES_VERSION'),2n)
eq(await read(ctrl,'RoundController','PREDEPOSIT_DURATION'),259200n)
eq(await read(ctrl,'RoundController','VEST_DURATION'),2419200n)
// Check every deployment receipt, not simulation addresses or console output.
for(const t of broadcast.transactions) eq((await client.getTransactionReceipt({hash:t.hash})).status,'success')
for(const a of [alice,bob,trader]) {
 await tx(a,mix,'MockMixETH','faucet',[eth('11000000')])
 await tx(a,mix,'MockMixETH','approve',[ctrl,maxUint256])
 await tx(a,mix,'MockMixETH','approve',[zap,maxUint256])
}
await tx(alice,ctrl,'RoundController','predepositWithPepe',[eth('400'),1n])
await tx(bob,ctrl,'RoundController','predepositWithPepe',[eth('1'),1n],'reverted')
eq(await read(ctrl,'RoundController','totalPredepositMixETH'),eth('400'))
await tx(bob,ctrl,'RoundController','predepositWithPepe',[eth('600'),2n])
await tx(trader,ctrl,'RoundController','predepositWithPepe',[eth('1000'),3n])
eq(await read(ctrl,'RoundController','totalPredepositMixETH'),eth('2000'))
await tx(trader,ctrl,'RoundController','launchPooledBuy',[],'reverted')
await warp(259200)
await tx(trader,ctrl,'RoundController','launchPooledBuy')
eq(await read(hook,'CurveHook','ticketPrice'),eth('.005'))
const baseline=await read(hook,'CurveHook','potBalance')
eq(await read(hook,'CurveHook','genesisPotBalance'),baseline)
await tx(alice,ctrl,'RoundController','claimPredepositPSP')
eq((await read(staker,'PSPStaker','ownerOf',[1n])).toLowerCase(),alice.toLowerCase())
const dna=await read(staker,'PSPStaker','dnaOf',[1n])
// Leave Bob unclaimed until after detonation, to exercise the graveyard route.
await warp(1200)
async function buy(amount, expectedTickets, capped=false) {
 const price=await read(hook,'CurveHook','ticketPrice'), count=await read(hook,'CurveHook','ticketCount'), deadline=await read(hook,'CurveHook','detonationAt')
 const quote=await read(hook,'CurveHook','getBuyOutput',[amount])
 const before=await read(token,'PSPToken','balanceOf',[trader])
 const r=await tx(trader,zap,'PSPZapIn','buyWithMix',[pool,amount,quote,await now()+100n])
 eq(await read(token,'PSPToken','balanceOf',[trader]),before+quote)
 eq(amount/price,expectedTickets)
 eq(await read(hook,'CurveHook','ticketCount'),count+expectedTickets)
 const stamp=(await client.getBlock({blockNumber:r.blockNumber})).timestamp
 const uncapped=deadline+69n*expectedTickets, cap=stamp+248660n
 eq(await read(hook,'CurveHook','detonationAt'),uncapped>cap?cap:uncapped)
 if(capped) eq(await read(hook,'CurveHook','detonationAt'),cap)
 const pot=await read(hook,'CurveHook','potBalance')
 eq(await read(hook,'CurveHook','ticketPrice'),eth('.005')+(pot-baseline)*21n/1_000_000n)
 const added=r.logs.flatMap(log=>{try{return [decodeEventLog({abi:artifact('CurveHook').abi,...log})]}catch{return []}}).find(e=>e.eventName==='TimeAdded')
 assert(added,'TimeAdded emitted')
}
await buy(eth('.05'),10n)
await buy(eth('.005'),0n)
await buy((await read(hook,'CurveHook','ticketPrice'))*10n,10n)
// Sells fund the pot and raise ticket prices, but add no seats or time.
const sellAmount=(await read(token,'PSPToken','balanceOf',[trader]))/3n
await tx(trader,token,'PSPToken','approve',[zapOut,maxUint256])
const beforeSellCount=await read(hook,'CurveHook','ticketCount'), beforeSellTime=await read(hook,'CurveHook','detonationAt'), beforeSellPrice=await read(hook,'CurveHook','ticketPrice')
await tx(trader,zapOut,'PSPZapOut','sellToMix',[pool,sellAmount,1n,await now()+100n])
eq(await read(hook,'CurveHook','ticketCount'),beforeSellCount)
eq(await read(hook,'CurveHook','detonationAt'),beforeSellTime)
assert(await read(hook,'CurveHook','ticketPrice')>beforeSellPrice)
// Large buy regression: bounded ten-slot writes and capped clock.
const beforeWhale=await client.request({method:'evm_snapshot'})
await buy(eth('10000000'),eth('10000000')/await read(hook,'CurveHook','ticketPrice'),true)
eq(await read(hook,'CurveHook','seatedCount'),10n)
// At this extreme the curve rounds further output to zero. Fail closed.
eq(await read(hook,'CurveHook','getBuyOutput',[eth('1')]),0n)
const extremeBalance=await read(mix,'MockMixETH','balanceOf',[trader])
await tx(trader,zap,'PSPZapIn','buyWithMix',[pool,eth('1'),1n,await now()+100n],'reverted')
eq(await read(mix,'MockMixETH','balanceOf',[trader]),extremeBalance)
await client.request({method:'evm_revert',params:[beforeWhale]})
await buy(eth('100'),eth('100')/await read(hook,'CurveHook','ticketPrice'),true)
// Compound earned fees through the production reinvestor.
const riArtifact=artifact('PSPReinvestor')
const riHash=await wallet.deployContract({account:owner,abi:riArtifact.abi,bytecode:riArtifact.bytecode.object,args:[staker,zap,mix,token],gas:10_000_000n})
const riReceipt=await client.waitForTransactionReceipt({hash:riHash});eq(riReceipt.status,'success')
const reinvestor=riReceipt.contractAddress
await tx(alice,staker,'PSPStaker','setApprovalForAll',[reinvestor,true])
assert(await read(staker,'PSPStaker','pendingFeesOf',[1n])>eth('.005'))
const beforeStake=(await read(staker,'PSPStaker','positions',[1n]))
await tx(alice,reinvestor,'PSPReinvestor','reinvestAll',[[1n],pool,1n,await now()+100n])
assert((await read(staker,'PSPStaker','positions',[1n]))[0]>beforeStake[0])
eq(await read(staker,'PSPStaker','dnaOf',[1n]),dna)
await tx(alice,staker,'PSPStaker','requestWithdraw',[1n])
await tx(alice,staker,'PSPStaker','cancelWithdraw',[1n])
// Expiry cannot be revived by a buy. Failed trade leaves balances intact.
await warp((await read(hook,'CurveHook','detonationAt'))-await now()+1n)
const failedBalance=await read(mix,'MockMixETH','balanceOf',[trader])
await tx(trader,zap,'PSPZapIn','buyWithMix',[pool,eth('1'),1n,await now()+100n],'reverted')
eq(await read(mix,'MockMixETH','balanceOf',[trader]),failedBalance)
await tx(trader,ctrl,'RoundController','detonate')
eq(await read(hook,'CurveHook','mode'),2)
const winnings=await read(hook,'CurveHook','claimablePot',[alice]);assert(winnings>0n)
const balance=await read(mix,'MockMixETH','balanceOf',[alice])
await tx(alice,hook,'CurveHook','claimPot')
eq(await read(mix,'MockMixETH','balanceOf',[alice]),balance+winnings)
await tx(bob,ctrl,'RoundController','claimPredepositPSP')
eq((await read(staker,'PSPStaker','ownerOf',[2n])).toLowerCase(),bob.toLowerCase())
await tx(alice,staker,'PSPStaker','withdraw',[1n])
eq(await read(staker,'PSPStaker','dnaOf',[1n]),dna)
const bag=await read(token,'PSPToken','balanceOf',[alice]);assert(bag>0n)
await tx(alice,token,'PSPToken','approve',[hook,bag])
await tx(alice,hook,'CurveHook','redeemBacking',[bag])
eq(await read(token,'PSPToken','balanceOf',[alice]),0n)
// Twelve-hour delay before respawn must not consume the new predeposit window.
await warp(43200)
await tx(trader,factory,'PSPFactory','reserveSpawn',[1n])
for(let i=0;i<3;i++) await tx(trader,factory,'PSPFactory','birthStep')
const [token2,ctrl2,hook2]=await read(factory,'PSPFactory','rounds',[2n])
const state=await read(ctrl2,'RoundController','predepositState')
eq(state[5],false)
assert(await now()-state[2]<60n)
await tx(alice,mix,'MockMixETH','approve',[ctrl2,maxUint256])
await tx(alice,ctrl2,'RoundController','predepositWithPepe',[eth('5000'),1n])
await tx(trader,ctrl2,'RoundController','launchPooledBuy',[],'reverted')
await warp(259200)
await tx(trader,ctrl2,'RoundController','launchPooledBuy')
eq(await read(hook2,'CurveHook','ticketPrice'),eth('.005'))
eq(await read(hook2,'CurveHook','ticketCount'),0n)
await warp(100)
const deadline2=await read(hook2,'CurveHook','detonationAt')
await tx(trader,zap,'PSPZapIn','buyWithMix',[key(token2,hook2),eth('.005'),1n,await now()+100n])
eq(await read(hook2,'CurveHook','ticketCount'),1n)
eq(await read(hook2,'CurveHook','detonationAt'),deadline2+69n)
const curve1=await read(hook,'CurveHook','sineCurve'), curve2=await read(hook2,'CurveHook','sineCurve')
assert(curve1[3]>=eth('40000')-3n&&curve1[3]<=eth('40000'))
assert(curve2[3]>=eth('100000')-3n&&curve2[3]<=eth('100000'))
eq(curve1[5],curve2[5])
writeFileSync('/tmp/psp-spec-anvil-curves.json',JSON.stringify({curve1,curve2},(_,v)=>typeof v==='bigint'?v.toString():v,2))
writeFileSync('/tmp/psp-ticket-anvil-receipts.json',JSON.stringify({factory,receipts},null,2))
console.log(`PASS: ${receipts.length} checked action receipts, deployment receipts verified, two rounds exercised.`)
