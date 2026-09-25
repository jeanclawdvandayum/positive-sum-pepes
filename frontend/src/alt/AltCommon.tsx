import { useEffect, useRef, useState } from 'react'
import { useAccount } from 'wagmi'
import { Link } from 'react-router-dom'
import { renderDecorativePepeSvg } from '../lib/pepeRender'
import { useNow } from '../phase/PhaseEngine'
import { useRound } from '../lib/useRound'
import { faucetAbi } from '../lib/abi'
import { ibcoPhaseAt } from '../lib/predeposit'
import { ADDRESSES, FAUCET_ENABLED } from '../lib/config'
import { fmtAmount } from '../lib/format'
import { useConfirmedWrite } from '../lib/useConfirmedWrite'
import { useLadderBoard } from '../pages/play/useLadderBoard'
import WalletPepeArt from '../components/WalletPepeArt'
import WalletName from '../components/WalletName'

export function clockText(seconds: number) {
  const s = Math.max(0, Math.floor(seconds))
  return `${Math.floor(s / 3600).toString().padStart(2,'0')}:${Math.floor(s % 3600 / 60).toString().padStart(2,'0')}:${(s % 60).toString().padStart(2,'0')}`
}
export function durationText(seconds?: bigint) {
  if (seconds === undefined) return 'the configured window'
  return seconds % 86400n === 0n ? `${seconds / 86400n} days` : seconds % 60n === 0n ? `${seconds / 60n} minutes` : clockText(Number(seconds))
}
export function RandomPepe({ className = '' }: { className?: string }) {
  const [svg, setSvg] = useState(renderDecorativePepeSvg)
  useEffect(() => { const timer = setInterval(() => setSvg(renderDecorativePepeSvg()), 20000); return () => clearInterval(timer) }, [])
  return <div className={`random-pepe ${className}`} role="img" aria-label="a random Pepe" dangerouslySetInnerHTML={{ __html: svg }} />
}
export function AltClock({ deadline, settled = false }: { deadline?: bigint; settled?: boolean }) {
  const now = useNow()
  return <div className="clock alt-clock" role="timer" aria-label="countdown">{settled ? '--:--:--' : deadline === undefined ? '--:--:--' : clockText(Math.max(0, Number(deadline)-now))}</div>
}
export function Faucet() {
  const { isConnected } = useAccount()
  const { writeContractAsync } = useConfirmedWrite()
  const [busy,setBusy] = useState(false)
  const [error,setError] = useState('')
  if (!FAUCET_ENABLED) return null
  return <div className="alt-faucet"><span>need mixETH?</span><button className="tx-action" disabled={!isConnected || busy} onClick={async()=>{
    setBusy(true); setError('')
    try { await writeContractAsync({address:ADDRESSES.faucet,abi:faucetAbi,functionName:'drip',args:[1000n*10n**18n]}) }
    catch(e) { setError(e instanceof Error ? e.message : 'Request failed.') }
    finally { setBusy(false) }
  }}>{busy?'confirming…':'get mixETH ↗'}</button>{error&&<p role="alert">{error}</p>}</div>
}
export function Instrument() {
  const round=useRound(), board=useLadderBoard(round.hook), now=useNow()
  const pre=round.mode===0
  // rules v3: green phase runs to greenEnd, then the open window to openEnd;
  // legacy rounds and rootless v3 rounds are a single open window.
  const phase=ibcoPhaseAt(now,round.greenEnd,round.openEnd)
  const deadline=pre?(phase===0?round.greenEnd:round.openEnd):round.detonationAt
  const live=round.mode===1&&deadline!==undefined&&Number(deadline)>now&&(board.ticketCount??0n)>0n
  const count=Number((board.ticketCount??0n)>10n?10n:board.ticketCount??0n)
  const pot=fmtAmount(pre?round.totalPredeposit:round.potBalance,3)
  const potRef=useRef<HTMLElement>(null)
  const prevPot=useRef(pot)
  useEffect(()=>{ // alt polish item 9: the digits flash when the pot value moves
    if(prevPot.current===pot) return
    const was=prevPot.current
    prevPot.current=pot
    if(!/\d/.test(was)) return // skip the loading '…' → first value
    const el=potRef.current
    if(!el) return
    const reduced=window.matchMedia('(prefers-reduced-motion: reduce)').matches
    el.animate(reduced?[{opacity:.35},{opacity:1}]:[{filter:'brightness(2.1)'},{filter:'brightness(1)'}],{duration:reduced?260:600,easing:'ease-out'})
  },[pot])
  const status=pre?(phase===0?'the greenlist opening':phase===2?'the opening is closed':'the pooled opening'):live?'countdown running':'waiting for the next move'
  return <div className="instrument"><div className="instrument-top"><strong>round {round.id.toString().padStart(2,'0')}</strong><span className="instrument-status">{status}</span></div><AltClock deadline={deadline} settled={(round.mode??0)>=2}/><div className="instrument-pot"><span>{pre?'pooled for the opening buy':'total pot'}</span><strong ref={potRef}>{pot} <small>mixETH</small></strong></div><div className="instrument-details"><span>{pre?'IBCO':'next ticket'} <b>{pre?(round.predepositCap?`${fmtAmount(round.predepositCap,0)} mixETH cap`:'uncapped'):`${fmtAmount(round.ticketPrice,8)} mixETH`}</b></span><span>clock cap <b>{clockText(Number(round.detWindow??0n))}</b></span></div>{live?<div className="face-podium">{[1,0,2].filter(i=>i<count).map(i=>{const seat=board.seats[i];return seat?<div className={`podium-card podium-rank-${i+1}`} key={i}><WalletPepeArt className="podium-art" address={seat.addr} staker={round.staker}/><small>#{i+1} · <WalletName address={seat.addr}/></small></div>:null})}</div>:<RandomPepe className="hero-random"/>}<div className="instrument-foot"><span>every round starts here.</span><Link to={pre?'/predeposit':'/play'}>{pre?'join the opening':'see the ladder'} ↗</Link></div></div>
}
