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
import { RandomPepe, clockText, FlipClock } from './AltCommon'

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

const ALT_SHEETS = ['style', 'theme', 'diagrams', 'editorial', 'live', 'polish', 'fx', 'detonation']
/// one id per page lifetime (survives vite HMR module re-evaluation)
const BOOT_ID = ((globalThis as Record<string, unknown>).__pspAltSheetBoot ??= Date.now().toString(36)) as string

export default function AltShell() {
 const {resolved,setMode}=useTheme(), round=useRound(), now=useNow(), location=useLocation()
 const [menu,setMenu]=useState(false)
 // Feature 2 (10): the wallet pepe chip breathes only while a tx is in flight.
 /** Top-bar countdown: a pocket flip board (same tiles, smaller) that shows
 *  the live round's deadline while you're anywhere BUT the play page — on
 *  play itself the big clock owns the countdown, so the mini retires. */
function MiniClock({ round, hidden }: { round: ReturnType<typeof useRound>, hidden: boolean }) {
  const now = useNow()
  // mode 1: the detonation clock. mode 0: the IBCO window (green counts to
  // the open phase, open/legacy to the window end) — same lane as Instrument.
  const deadline = round.mode === 0
    ? (round.greenEnd !== undefined && now < Number(round.greenEnd)
        ? round.greenEnd
        : round.openEnd)
    : round.detonationAt
  if (hidden || (round.mode ?? 1) >= 2 || deadline === undefined || round.mode === undefined && round.detonationAt === undefined) return null
  return <span className="mini-flip" aria-label={round.mode === 0 ? 'countdown to the IBCO window close' : 'countdown to detonation'}><FlipClock text={clockText(Math.max(0, Number(deadline) - now))} /></span>
}

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
  /// dev loads carry a per-boot version query: the browser otherwise keeps a
  /// stale live.css across SPA navigations and edits look "not deployed".
  /// MODULE scope — AltShell re-renders every clock tick and a fresh
  /// Date.now() here reloaded all eight stylesheets every second.
  const sheetV = import.meta.env.DEV ? `?v=${BOOT_ID}` : ''
  return <div className="alt-shell">{ALT_SHEETS.map(name => <link key={name} rel="stylesheet" href={`/alt/${name}.css${sheetV}`} />)}<header className="site-header"><Link className="brand" to="/"><RandomPepe/><span><span className="brand-mark">positive</span> sum<br/><strong>pepes</strong></span></Link><nav className={menu?'open':''} aria-label="Main navigation">{[['/','explainer'],['/play','play'],['/stake','stake'],['/graveyard','graveyard']].map(([to,label])=><NavLink key={to} to={to} end {...slideNav(to)}>{label}<span className="nav-underline" aria-hidden="true"/></NavLink>)}{round.mode===0&&<NavLink to="/predeposit" {...slideNav('/predeposit')}>IBCO<span className="nav-underline" aria-hidden="true"/></NavLink>}</nav><div className="header-tools"><MiniClock round={round} hidden={location.pathname==="/play" || location.pathname==="/trade"} /><button className="icon-button" aria-label={`Switch to ${resolved==='dark'?'light':'dark'} theme`} onClick={()=>setMode(resolved==='dark'?'light':'dark')}>☼</button><ConnectButton.Custom>{({account,chain,openConnectModal,openAccountModal,openChainModal,mounted})=><button className="wallet-button" data-tx-pending={txPending||undefined} disabled={!mounted} onClick={!account?openConnectModal:chain?.unsupported?openChainModal:openAccountModal}>{account?<><WalletPepeArt className="wallet-art" address={account.address as `0x${string}`} staker={round.staker}/><span className="wallet-label"><WalletName address={account.address as `0x${string}`}/></span></>:'connect wallet'}<span>↗</span></button>}</ConnectButton.Custom><button className="icon-button menu-toggle" aria-label="Toggle navigation" aria-expanded={menu} onClick={()=>setMenu(v=>!v)}>☰</button></div></header><main id="app">{round.readError&&<p className="notice" role="status">{round.readError}</p>}<Routes><Route path="/" element={<AltLanding/>}/><Route path="/play" element={<AltPlay/>}/><Route path="/stake" element={<Stake variant="alt"/>}/><Route path="/predeposit" element={<Predeposit variant="alt"/>}/><Route path="/graveyard" element={<AltGraveyard/>}/>{FxLab&&<Route path="/fx-lab" element={<Suspense fallback={null}><FxLab/></Suspense>}/>}<Route path="*" element={<AltLanding/>}/></Routes></main><footer><Link className="footer-wordmark" to="/">positive sum pepes<span>the frogs have a pot problem.</span></Link><div className="footer-links"><a href="/rolling-paper.html">rolling paper ↗</a><Link to="/graveyard">past rounds ↗</Link><a href={`${targetChain.blockExplorers?.default.url??''}/address/${ADDRESSES.factory}`} target="_blank" rel="noreferrer">contracts ↗</a></div><span className="footer-bottom">made of pixels and math.<span>round {round.id.toString()}</span></span></footer><ActionFxLayer/><VictoryModal/></div>
}
