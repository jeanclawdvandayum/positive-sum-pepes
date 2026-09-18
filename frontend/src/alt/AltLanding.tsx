import { useEffect, useMemo, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { landingMarkup } from './landingTemplate'
import { Instrument, durationText } from './AltCommon'
import { useRound } from '../lib/useRound'
import { useRpcReads } from '../lib/useRpcReads'
import { controllerAbi } from '../lib/abi'
import { renderDecorativePepeSvg } from '../lib/pepeRender'
export default function AltLanding() {
  const ref=useRef<HTMLDivElement>(null), [slot,setSlot]=useState<Element|null>(null)
  const round=useRound()
  const [duration]=useRpcReads([{to:round.controller,abi:controllerAbi,functionName:'PREDEPOSIT_DURATION'}],!!round.controller,15000)
  const html=useMemo(()=>landingMarkup(100,durationText(typeof duration==='bigint'?duration:undefined),durationText(round.detWindow)),[duration,round.detWindow])
  const content=useMemo(()=>({__html:html}),[html])
  useEffect(()=>{setSlot(ref.current?.querySelector('#hero-instrument')??null)},[html])
  return <div ref={ref} onClick={e=>{if((e.target as Element).closest('[data-action="scroll-how"]')){e.preventDefault();ref.current?.querySelector('#how-it-works')?.scrollIntoView({behavior:'smooth'})}}} onAnimationIteration={e=>{
    if(e.animationName==='xd-respawn-roll') { const svg=renderDecorativePepeSvg(); e.currentTarget.querySelectorAll<HTMLImageElement>('.xd-respawn-pepe,.xd-respawn-ghost').forEach(img=>img.src=`data:image/svg+xml,${encodeURIComponent(svg)}`) }
  }} onInput={e=>{const target=e.target as HTMLInputElement;if(target.id==='pot-slider'){ref.current?.querySelectorAll<HTMLElement>('[data-payout-bar]').forEach((el,i)=>{el.textContent=`${(Number(target.value)*[25,18,14,10,8,7,6,5,4,3][i]/100).toFixed(2)} mix`});const out=ref.current?.querySelector('#pot-output');if(out)out.textContent=`${target.value} mixETH`;const pot=Number(target.value);const t=ref.current?.querySelector('#ticket-output');if(t)t.textContent=`${(pot/10000).toLocaleString('en-US',{maximumFractionDigits:6})} mixETH`;const top=ref.current?.querySelector('#top-output');if(top)top.textContent=`${(pot*0.25).toFixed(2)} mixETH`}}}><div dangerouslySetInnerHTML={content}/>{slot&&createPortal(<Instrument/>,slot)}</div>
}
