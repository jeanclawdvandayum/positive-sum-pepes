import WalletName from '../components/WalletName'
import WalletPepeArt from '../components/WalletPepeArt'
import { lazy, Suspense, useEffect, useState, useSyncExternalStore, type MouseEvent as ReactMouseEvent } from 'react'
import { flushSync } from 'react-dom'
import { Link, NavLink, Route, Routes, useLocation, useNavigate } from 'react-router-dom'
import { ConnectButton } from '@rainbow-me/rainbowkit'
import { useTheme } from '../lib/theme'
import { useRound } from '../lib/useRound'
import { useNow } from '../phase/PhaseEngine'
import { ADDRESSES, targetChain } from '../lib/config'
import { urgencyFor } from './urgency'
import { transactionToasts, type TxStage } from '../lib/transactionToasts'
import AltLanding from './AltLanding'
import AltPlay from './AltPlay'
import AltGraveyard from './AltGraveyard'
import Stake from '../pages/Stake'
import Predeposit from '../pages/Predeposit'
import ActionFxLayer from './ActionFxLayer'
import VictoryModal from './VictoryModal'
import { RandomPepe, clockText } from './AltCommon'

// Dev-only QA stage for the FX catalog; the DEV guard (plus lazy import) keeps
// it out of production builds entirely.
const FxLab = import.meta.env.DEV ? lazy(() => import('./FxLab')) : undefined

// Feature 2 (4): the active nav underline slides between routes. AltShell
// wraps the route update in document.startViewTransition (canonical React
// pattern: flushSync inside the transition callback). Only when the platform
// supports it and motion is welcome — otherwise plain navigation.
const SLIDE_NAV = typeof document !== 'undefined' && 'startViewTransition' in document
  && !window.matchMedia('(prefers-reduced-motion: reduce)').matches
const TX_PENDING_STAGES: readonly TxStage[] = ['preparing', 'simulating', 'wallet', 'pending']

export default function AltShell() {
 const {resolved,setMode}=useTheme(), round=useRound(), now=useNow(), location=useLocation()
 const [menu,setMenu]=useState(false)
 // Feature 2 (10): the wallet pepe chip breathes only while a tx is in flight.
 const toasts=useSyncExternalStore(transactionToasts.subscribe,transactionToasts.snapshot)
 const txPending=toasts.some(t=>TX_PENDING_STAGES.includes(t.stage))
 const navigate=useNavigate()
 const slideNav=(to:string)=>SLIDE_NAV?{onClick:(event:ReactMouseEvent<HTMLAnchorElement>)=>{
   if(event.button!==0||event.metaKey||event.ctrlKey||event.altKey||event.shiftKey) return
   event.preventDefault()
   document.startViewTransition(()=>{flushSync(()=>navigate(to))})
 }}:{}
 useEffect(()=>{document.documentElement.dataset.theme=resolved;document.body.classList.add('alt-mode');return()=>document.body.classList.remove('alt-mode')},[resolved])
 useEffect(()=>{setMenu(false);window.scrollTo(0,0)},[location.pathname])
 const remaining=round.detonationAt===undefined?0:Math.max(0,Number(round.detonationAt)-now)
 // Clock color rides data-urgency: the carpet-bomb window in mode 1 (only
 // once the detonation deadline is known), the IBCO window in mode 0 —
 // green phase runs its own countdown into the open window, which then
 // counts down to launch (rules v3; legacy rounds are one open window).
 // Bands live in urgencyFor.
 const urgency=round.mode===1&&round.detonationAt!==undefined?urgencyFor(remaining,Number(round.detWindow))
  :round.mode===0&&round.predepositStartTime!==undefined&&!round.predepositClosed&&round.greenEnd!==undefined&&now<Number(round.greenEnd)
   ?urgencyFor(Number(round.greenEnd)-now,Number(round.greenEnd-round.predepositStartTime))
  :round.mode===0&&round.predepositStartTime!==undefined&&!round.predepositClosed&&round.openEnd!==undefined
   ?urgencyFor(Math.max(0,Number(round.openEnd)-now),Number(round.openEnd-(round.greenEnd??round.predepositStartTime)))
   :'idle'
 useEffect(()=>{document.documentElement.dataset.urgency=urgency},[urgency])
 return <div className="alt-shell">{['style','theme','diagrams','editorial','live','polish','fx','detonation'].map(name=><link key={name} rel="stylesheet" href={`/alt/${name}.css`}/>)}<header className="site-header"><Link className="brand" to="/"><RandomPepe/><span><span className="brand-mark">positive</span> sum<br/><strong>pepes</strong></span></Link><nav className={menu?'open':''} aria-label="Main navigation">{[['/','explainer'],['/play','play'],['/stake','stake'],['/graveyard','graveyard']].map(([to,label])=><NavLink key={to} to={to} end {...slideNav(to)}>{label}<span className="nav-underline" aria-hidden="true"/></NavLink>)}{round.mode===0&&<NavLink to="/predeposit" {...slideNav('/predeposit')}>IBCO<span className="nav-underline" aria-hidden="true"/></NavLink>}</nav><div className="header-tools"><span className="mini-clock">{round.mode===1?clockText(remaining):''}</span><button className="icon-button" aria-label={`Switch to ${resolved==='dark'?'light':'dark'} theme`} onClick={()=>setMode(resolved==='dark'?'light':'dark')}>☼</button><ConnectButton.Custom>{({account,chain,openConnectModal,openAccountModal,openChainModal,mounted})=><button className="wallet-button" data-tx-pending={txPending||undefined} disabled={!mounted} onClick={!account?openConnectModal:chain?.unsupported?openChainModal:openAccountModal}>{account?<><WalletPepeArt className="wallet-art" address={account.address as `0x${string}`} staker={round.staker}/><span className="wallet-label"><WalletName address={account.address as `0x${string}`}/></span></>:'connect wallet'}<span>↗</span></button>}</ConnectButton.Custom><button className="icon-button menu-toggle" aria-label="Toggle navigation" aria-expanded={menu} onClick={()=>setMenu(v=>!v)}>☰</button></div></header><main id="app">{round.readError&&<p className="notice" role="status">{round.readError}</p>}<Routes><Route path="/" element={<AltLanding/>}/><Route path="/play" element={<AltPlay/>}/><Route path="/stake" element={<Stake variant="alt"/>}/><Route path="/predeposit" element={<Predeposit variant="alt"/>}/><Route path="/graveyard" element={<AltGraveyard/>}/>{FxLab&&<Route path="/fx-lab" element={<Suspense fallback={null}><FxLab/></Suspense>}/>}<Route path="*" element={<AltLanding/>}/></Routes></main><footer><Link className="footer-wordmark" to="/">positive sum pepes<span>the frogs have a pot problem.</span></Link><div className="footer-links"><a href="/rolling-paper.html">rolling paper ↗</a><Link to="/graveyard">past rounds ↗</Link><a href={`${targetChain.blockExplorers?.default.url??''}/address/${ADDRESSES.factory}`} target="_blank" rel="noreferrer">contracts ↗</a></div><span className="footer-bottom">made of pixels and math.<span>round {round.id.toString()}</span></span></footer><ActionFxLayer/><VictoryModal/></div>
}
