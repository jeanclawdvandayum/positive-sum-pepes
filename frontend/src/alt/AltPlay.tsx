import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useAccount } from 'wagmi'
import { useRound } from '../lib/useRound'
import { useNow } from '../phase/PhaseEngine'
import { useDisplayName } from '../lib/useDisplayName'
import { fmtAmount } from '../lib/format'
import { groupRoundWinners } from '../lib/roundWinners'
import { useLadderBoard, type BoardState } from '../pages/play/useLadderBoard'
import { useTradeTape } from '../pages/play/useTradeTape'
import WalletName from '../components/WalletName'
import WalletPepeArt from '../components/WalletPepeArt'
import SwapCard from '../components/SwapCard'
import CurveChart from '../components/CurveChart'
import DetonateButton from '../pages/play/DetonateButton'
import SpawnRoundPanel from '../pages/play/SpawnRoundPanel'
import { ADDRESSES } from '../lib/config'
import { RefBanner } from '../components/ReferralCard'
import Tape from '../pages/play/Tape'
import { AltClock, clockText, RandomPepe, Faucet } from './AltCommon'
import Predeposit from '../pages/Predeposit'
const weights=[25,18,14,10,8,7,6,5,4,3]
function Leader({address}:{address:`0x${string}`}) { const name=useDisplayName(address,'anon pepe'); return <span>{name.split('.')[0]}</span> }
function Ladder({board,staker}:{board:BoardState;staker?:`0x${string}`}) {
 const {address}=useAccount()
 const count=board.ticketCount===undefined?undefined:Number(board.ticketCount>10n?10n:board.ticketCount)
 const denom=weights.slice(0,count??0).reduce((a,b)=>a+b,0)
 return <section className="ladder-panel"><div className="board-head"><h2>the ladder.</h2><p>your cut if it blows now.<br/>everyone wants your seat.</p></div><div id="board-content">{count===undefined?<p role="status">loading the ladder…</p>:count===0?<div className="empty-ladder"><RandomPepe/><h3>the first seat is yours to take.</h3><p>one occupied seat gets the whole pot.</p></div>:<div className="ladder">{Array.from({length:10},(_,i)=>{const seat=board.seats[i];return <div key={i} className={`ladder-row ${address&&seat?.addr.toLowerCase()===address.toLowerCase()?'you':''}`} style={{'--share':`${weights[i]*4}%`} as React.CSSProperties}><span className="rank">{String(i+1).padStart(2,'0')}</span>{seat?<><WalletPepeArt className="ladder-art" address={seat.addr} staker={staker}/><div className="ladder-person"><strong><WalletName address={seat.addr}/></strong><small>{i===0?'the seat to beat':'ladder spot'}</small></div><div className="ladder-payout"><strong>{fmtAmount(board.pot===undefined?undefined:board.pot*BigInt(weights[i])/BigInt(denom),4)}</strong><small>mixETH · {(weights[i]*100/denom).toFixed(1)}%</small></div></>:<span className="muted">{i<count?'loading holder…':'open seat'}</span>}</div>})}</div>}</div><p className="board-note">newest ticket first. selling PSP keeps your seats until another buy pushes them out.</p></section>
}
export default function AltPlay() {
 const round=useRound(), board=useLadderBoard(round.hook), tape=useTradeTape(), now=useNow()
 const [done,setDone]=useState(false)
 const settled=(round.mode??0)>=2
 const count=Number((board.ticketCount??0n)>10n?10n:board.ticketCount??0n)
 const buyers=board.seats.slice(0,count).map(s=>s?.addr)
 const prize=board.pot!==undefined && buyers.every((a):a is `0x${string}`=>!!a) ? groupRoundWinners(board.pot,buyers)[0]?.payout : undefined
 if(round.mode===0) return <Predeposit variant="alt"/>
 if(round.mode===undefined) return <div className="page-heading" role="status"><h1>finding the round.</h1><p>{round.readError??'loading the clock and contracts…'}</p></div>
 return <><section className="play-clockband"><h1>{settled?'the round is flat. the claims are open.':round.detonationAt!==undefined&&Number(round.detonationAt)<=now?'clock at zero. somebody pull the pin.':<>{board.seats[0]?<Leader address={board.seats[0].addr}/>:<span>anon pepe</span>} is <em>carpet bombing</em> for <span className="money bombing-money">{fmtAmount(prize,4)} <span className="pixel-unit">mixETH</span></span> in:</>}</h1><AltClock deadline={round.detonationAt} settled={settled}/><div className="pot-line">total pot <strong>{fmtAmount(round.potBalance,4)}</strong> mixETH</div><div className="clock-details"><span>round {round.id.toString()}</span><span>{clockText(Number(round.detWindow??0n))} max</span><span>reserves {fmtAmount(round.reserve,3)} mixETH</span></div><DetonateButton round={round} onDetonated={()=>setDone(true)}/></section><RefBanner/><div className="live-tape"><Tape entries={tape.entries} loading={!tape.complete} error={tape.error}/></div>{settled&&<><div className="notice">redemption and claims stay with this round. <Link to="/graveyard">head to the graveyard ↗</Link></div><SpawnRoundPanel key={round.id.toString()} factory={ADDRESSES.factory} destroyedRoundId={round.id}/></>}{done&&!settled&&<p role="status">refreshing the settled round…</p>}<div className="play-grid"><SwapCard variant="alt" board={board}/><Ladder board={board} staker={round.staker}/></div><Faucet/><section className="section actual-curve"><div className="chart-head"><h2>the curve has a pulse.</h2><p>buying climbs. selling retraces.</p></div><CurveChart hasTrades={tape.count>0}/><div className="curve-readout"><span>trade fee <strong>{round.swapFeeBps===undefined?'…':`${Number(round.swapFeeBps)/100}%`}</strong></span><span>volume <strong>{fmtAmount(tape.volumeWad,3)} mixETH</strong></span><span>fees to stakers <strong>{fmtAmount(tape.feesWad,3)} mixETH</strong></span></div></section></>
}
