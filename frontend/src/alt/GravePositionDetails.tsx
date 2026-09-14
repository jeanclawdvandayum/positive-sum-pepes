import { graveTag } from '../lib/graveTag'
import { useEffect, useState } from 'react'
import { useAccount, usePublicClient } from 'wagmi'
import { parseAbiItem } from 'viem'
import { controllerAbi, stakerAbi } from '../lib/abi'
import { ADDRESSES, CHAIN_ID, DEPLOYMENT_BLOCK } from '../lib/config'
import { useRpcReads } from '../lib/useRpcReads'
import { useNftVersion } from '../lib/useNftVersion'
import { readRoundWinners } from '../lib/roundWinners'
import { rpcBatchCall } from '../lib/rpc'
import PositionNftControls from '../components/PositionNftControls'
import type { GraveyardRound } from '../pages/play/useGraveyard'
const locked=parseAbiItem('event Locked(address indexed user, uint256 indexed pepeId, uint256 amount)')
const withdrawn=parseAbiItem('event Withdrawn(address indexed user, uint256 indexed pepeId, uint256 amount)')
const transferred=parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)')
const ZERO='0x0000000000000000000000000000000000000000' as const
const cache=new Map<string,string>()
// A dead round's final ladder never changes — one fetch serves every badge on the card.
const winnersCache=new Map<string,Awaited<ReturnType<typeof readRoundWinners>>>()
export default function GravePositionDetails({round,id,amount}:{round:GraveyardRound;id:bigint;amount:bigint}){
 const {address}=useAccount(),client=usePublicClient({chainId:CHAIN_ID}),version=useNftVersion(round.staker)
 const [busy,setBusy]=useState(false),[refresh,setRefresh]=useState(0),[tag,setTag]=useState('')
 const [approved,all]=useRpcReads([{to:round.staker,abi:stakerAbi,functionName:'getApproved',args:[id]},{to:round.staker,abi:stakerAbi,functionName:'isApprovedForAll',args:[address,ADDRESSES.reinvestor]}],!!address&&!!round.staker,6000,refresh)
 useEffect(()=>{let dead=false;if(!client||!round.staker)return;const staker=round.staker,key=`${CHAIN_ID}:${staker}:${id}`;setTag(cache.get(key)??'');if(cache.has(key))return
 void(async()=>{
   const flat=await client.readContract({address:round.controller,abi:controllerAbi,functionName:'flatTime'}) as bigint
   let lo=DEPLOYMENT_BLOCK??0n,hi=await client.getBlockNumber()
   // Last block at or before settlement. This preserves the former owner's result after transfers.
   while(lo<hi){const mid=(lo+hi+1n)/2n;if((await client.getBlock({blockNumber:mid})).timestamp<=flat)lo=mid;else hi=mid-1n}
   // Public RPCs prune historical STATE, so ownerOf at a dead block fails — Transfer
   // LOGS still serve from round birth. Replay them: the last mint/transfer before
   // settlement is the settlement owner.
   let owner:`0x${string}`|undefined,lateClaim=false
   for(let from=DEPLOYMENT_BLOCK??0n;from<=lo;from+=50000n){if(dead)return
     for(const log of await client.getLogs({address:staker,event:transferred,args:{tokenId:id},fromBlock:from,toBlock:from+49999n<lo?from+49999n:lo}))if(log.args.to&&log.args.to!==ZERO)owner=log.args.to}
   if(!owner){
     // Reserved predeposit NFTs can first mint after the round settles.
     const head=await client.getBlockNumber()
     for(let from=lo+1n;from<=head&&!owner;from+=50000n){if(dead)return
       const logs=await client.getLogs({address:staker,event:transferred,args:{from:ZERO,tokenId:id},fromBlock:from,toBlock:from+49999n<head?from+49999n:head})
       if(logs[0]?.args.to){owner=logs[0].args.to;lateClaim=true}}
     if(!owner)throw Error('Settlement owner unavailable')}
   const cached=winnersCache.get(round.hook)
   const summary=cached??await readRoundWinners(rpcBatchCall,round.hook)
   if(!cached)winnersCache.set(round.hook,summary)
   const {winners}=summary
   const ranks=winners.find(w=>w.address.toLowerCase()===owner.toLowerCase())?.ranks??[]
   let hadStake=amount>0n||lateClaim
   if(!ranks.length&&!hadStake){for(let from=DEPLOYMENT_BLOCK??0n;from<=lo;from+=2000n){if(dead)return;const to=from+1999n<lo?from+1999n:lo;const [a,b]=await Promise.all([client.getLogs({address:staker,event:locked,args:{pepeId:id},fromBlock:from,toBlock:to}),client.getLogs({address:staker,event:withdrawn,args:{pepeId:id},fromBlock:from,toBlock:to})]);if([...a,...b].some(log=>(log.args.amount??0n)>0n)){hadStake=true;break}}}
   const text=graveTag(ranks,hadStake);cache.set(key,text);if(!dead)setTag(text)
 })().catch(()=>{if(!dead)setTag('round history unavailable')});return()=>{dead=true}
},[client,round.staker,round.controller,round.hook,id,amount])
return <><p className="grave-tag">{tag||'reading the round…'}</p><p className="text-xs text-text-lo mb-3">{tag.startsWith('took')||tag.startsWith('ran')?'held by a ladder winner at settlement. ladder winnings belong to that wallet.':''}</p>{round.staker&&<PositionNftControls staker={round.staker} roundId={round.roundId} id={id} amount={amount} version={version} approved={approved as `0x${string}`|undefined} approvedAll={all as boolean|undefined} disabled={busy} onBusy={setBusy} onDone={()=>setRefresh(n=>n+1)}/>}</>
}
