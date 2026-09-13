import WalletName from '../components/WalletName'
import WalletPepeArt from '../components/WalletPepeArt'
import { useEffect, useState } from 'react'
import { Link, NavLink, Route, Routes, useLocation } from 'react-router-dom'
import { ConnectButton } from '@rainbow-me/rainbowkit'
import { useTheme } from '../lib/theme'
import { useRound } from '../lib/useRound'
import { useNow } from '../phase/PhaseEngine'
import { ADDRESSES, targetChain } from '../lib/config'
import AltLanding from './AltLanding'
import AltPlay from './AltPlay'
import AltGraveyard from './AltGraveyard'
import Stake from '../pages/Stake'
import Predeposit from '../pages/Predeposit'
import { RandomPepe, clockText } from './AltCommon'
export default function AltShell() {
 const {resolved,setMode}=useTheme(), round=useRound(), now=useNow(), location=useLocation()
 const [menu,setMenu]=useState(false)
 useEffect(()=>{document.documentElement.dataset.theme=resolved;document.body.classList.add('alt-mode');return()=>document.body.classList.remove('alt-mode')},[resolved])
 useEffect(()=>{setMenu(false);window.scrollTo(0,0)},[location.pathname])
 const remaining=round.detonationAt===undefined?0:Math.max(0,Number(round.detonationAt)-now)
 useEffect(()=>{const cap=Number(round.detWindow??600n);document.documentElement.dataset.urgency=round.mode!==1?'idle':remaining>cap/2?'safe':remaining>cap/5?'warm':'critical'},[remaining,round.mode,round.detWindow])
 return <div className="alt-shell">{['style','theme','diagrams','editorial','live'].map(name=><link key={name} rel="stylesheet" href={`/alt/${name}.css`}/>)}<header className="site-header"><Link className="brand" to="/"><RandomPepe/><span>positive sum<br/><strong>pepes</strong></span></Link><nav className={menu?'open':''} aria-label="Main navigation">{[['/','explainer'],['/play','play'],['/stake','stake'],['/graveyard','graveyard']].map(([to,label])=><NavLink key={to} to={to} end>{label}</NavLink>)}{round.mode===0&&<NavLink to="/predeposit">IBCO</NavLink>}</nav><div className="header-tools"><span className="mini-clock">{round.mode===1?clockText(remaining):''}</span><button className="icon-button" aria-label={`Switch to ${resolved==='dark'?'light':'dark'} theme`} onClick={()=>setMode(resolved==='dark'?'light':'dark')}>☼</button><ConnectButton.Custom>{({account,chain,openConnectModal,openAccountModal,openChainModal,mounted})=><button className="wallet-button" disabled={!mounted} onClick={!account?openConnectModal:chain?.unsupported?openChainModal:openAccountModal}>{account?<><WalletPepeArt className="wallet-art" address={account.address as `0x${string}`} staker={round.staker}/><span className="wallet-label"><WalletName address={account.address as `0x${string}`}/></span></>:'connect wallet'}<span>↗</span></button>}</ConnectButton.Custom><button className="icon-button menu-toggle" aria-label="Toggle navigation" aria-expanded={menu} onClick={()=>setMenu(v=>!v)}>☰</button></div></header><main id="app">{round.readError&&<p className="notice" role="status">{round.readError}</p>}<Routes><Route path="/" element={<AltLanding/>}/><Route path="/play" element={<AltPlay/>}/><Route path="/stake" element={<Stake variant="alt"/>}/><Route path="/predeposit" element={<Predeposit variant="alt"/>}/><Route path="/graveyard" element={<AltGraveyard/>}/><Route path="*" element={<AltLanding/>}/></Routes></main><footer><Link className="footer-wordmark" to="/">positive sum pepes<span>the frogs have a pot problem.</span></Link><div className="footer-links"><a href="/rolling-paper.html">rolling paper ↗</a><Link to="/graveyard">past rounds ↗</Link><a href={`${targetChain.blockExplorers?.default.url??''}/address/${ADDRESSES.factory}`} target="_blank" rel="noreferrer">contracts ↗</a></div><span className="footer-bottom">made of pixels and math.<span>round {round.id.toString()}</span></span></footer></div>
}
