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
// v3: the whole genesis pot prices 10,000 spots. 2000 gross -> 200 pot -> 0.02
eq(await read(hook,'CurveHook','ticketPrice'),eth('.02'))
eq(await read(hook,'CurveHook','SINE_RULES_VERSION'),3n)
eq(await read(hook,'CurveHook','TICKET_RULES_VERSION'),3n)
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
 const q=pot/10000n
 eq(await read(hook,'CurveHook','ticketPrice'),pot%10000n?q+1n:(q||1n))
 const added=r.logs.flatMap(log=>{try{return [decodeEventLog({abi:artifact('CurveHook').abi,...log})]}catch{return []}}).find(e=>e.eventName==='TimeAdded')
 assert(added,'TimeAdded emitted')
}
await buy(eth('.05'),eth('.05')/await read(hook,'CurveHook','ticketPrice'))
// v3: below one current spot, buys REVERT (the minimum is exactly one spot)
{ const bal=await read(mix,'MockMixETH','balanceOf',[trader])
  await tx(trader,zap,'PSPZapIn','buyWithMix',[pool,(await read(hook,'CurveHook','ticketPrice'))-1n,1n,await now()+100n],'reverted')
  eq(await read(mix,'MockMixETH','balanceOf',[trader]),bal) }
await buy((await read(hook,'CurveHook','ticketPrice'))*10n,10n)
// Sells fund the pot and raise ticket prices, but add no seats or time.
const sellAmount=(await read(token,'PSPToken','balanceOf',[trader]))/3n
await tx(trader,token,'PSPToken','approve',[zapOut,maxUint256])
const beforeSellCount=await read(hook,'CurveHook','ticketCount'), beforeSellTime=await read(hook,'CurveHook','detonationAt'), beforeSellPrice=await read(hook,'CurveHook','ticketPrice')
await tx(trader,zapOut,'PSPZapOut','sellToMix',[pool,sellAmount,1n,await now()+100n])
eq(await read(hook,'CurveHook','ticketCount'),beforeSellCount)
eq(await read(hook,'CurveHook','detonationAt'),beforeSellTime)
assert(await read(hook,'CurveHook','ticketPrice')>beforeSellPrice)
// Large buy regression: bounded ten-slot writes and capped clock. v3 caps the
// reserve domain at target + 64 waves (= boot + 74 waves; ~143k mix here).
// Below the tenth-wave target buys skim 10% to fees, so only 90% of gross
// reaches the curve — overspend GROSS by the fee ratio to pierce the edge.
// (The old 10M-mix stress buy is an explicit capacity error now.)
const beforeWhale=await client.request({method:'evm_snapshot'})
{ const [,lam,target]=await read(hook,'CurveHook','sineV3')
  const edge=target+64n*lam, headroom=edge-await read(hook,'CurveHook','reserveMixETH')
  const overspend=headroom*10n/9n+1n
  const extremeBalance=await read(mix,'MockMixETH','balanceOf',[trader])
  await tx(trader,zap,'PSPZapIn','buyWithMix',[pool,overspend,1n,await now()+100n],'reverted')
  eq(await read(mix,'MockMixETH','balanceOf',[trader]),extremeBalance)
  await buy(headroom*95n/100n,headroom*95n/100n/await read(hook,'CurveHook','ticketPrice'),true) }
eq(await read(hook,'CurveHook','seatedCount'),10n)
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
// v3: 5000 gross -> 500 pot -> 0.05 per spot
eq(await read(hook2,'CurveHook','ticketPrice'),eth('.05'))
eq(await read(hook2,'CurveHook','ticketCount'),0n)
await warp(100)
const deadline2=await read(hook2,'CurveHook','detonationAt')
const tp2=await read(hook2,'CurveHook','ticketPrice')
await tx(trader,zap,'PSPZapIn','buyWithMix',[key(token2,hook2),tp2,1n,await now()+100n])
eq(await read(hook2,'CurveHook','ticketCount'),1n)
eq(await read(hook2,'CurveHook','detonationAt'),deadline2+69n)
// v3 curves: lam = 955*sqrt(boot/450); target = boot + 10*lam (exact ints)
const curve1=await read(hook,'CurveHook','sineV3'), curve2=await read(hook2,'CurveHook','sineV3')
eq(curve1[0],eth('1800'))                       // boot = 90% of 2000 gross
eq(curve1[1],eth('1910'))                       // 955*sqrt(1800/450) = 955*2
eq(curve1[2],eth('1800')+10n*curve1[1])
eq(curve2[0],eth('4500'))                       // boot = 90% of 5000 gross
assert(curve2[1]*curve2[1]/10n<=eth('3820')*eth('3820')/10n) // sqrt scaling sanity
eq(curve2[2],eth('4500')+10n*curve2[1])
eq(curve1[3]>0n && curve2[3]>curve1[3],true)    // genesis supply grows with boot
writeFileSync('/tmp/psp-spec-anvil-curves-v3.json',JSON.stringify({curve1,curve2},(_,v)=>typeof v==='bigint'?v.toString():v,2))
writeFileSync('/tmp/psp-ticket-anvil-receipts.json',JSON.stringify({factory,receipts},null,2))
console.log(`PASS: ${receipts.length} checked action receipts, deployment receipts verified, two rounds exercised.`)
