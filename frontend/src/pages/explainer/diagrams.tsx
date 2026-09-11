import { useMemo, useState } from 'react'
import MixLogo from '../../components/MixLogo'
import { CurveDiagram } from './CurveExplainer'
import { renderDecorativePepeSvg } from '../../lib/pepeRender'

const randomPepe = () => renderDecorativePepeSvg()

// Illustrations only. CSS handles motion, with a readable static frame for each
// diagram. The real countdown continues to use the shared PhaseEngine.
export function DiagramStyles() {
  return (
    <style>{`
.xd-stage {
  position: relative;
  flex: none;
  width: 10rem;
  height: 7rem;
  overflow: hidden;
  border: 1px solid var(--line);
  border-radius: 0.6rem;
  background: var(--bg-1);
}
.xd-stage svg { display: block; }
.xd-stage text { font: 9px var(--font-data); fill: var(--text-lo); }
.xd-stage .xd-label { fill: var(--text-hi); }
.xd-page :is(a, button, input, summary):focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 4px;
}
.xd-deposit { animation: xd-pool 4s ease-in-out infinite; }
.xd-deposit-b { animation-delay: -1.3s; }
.xd-deposit-c { animation-delay: -2.6s; }
@keyframes xd-pool {
  0%, 15% { transform: translateY(0); opacity: 0; }
  25% { opacity: 1; }
  75% { transform: translateY(39px); opacity: 1; }
  100% { transform: translateY(39px); opacity: 0; }
}
.xd-fee { animation: xd-fee-flow 3s ease-in-out infinite; }
@keyframes xd-fee-flow {
  0% { transform: translateX(-16px); opacity: 0; }
  25%, 70% { opacity: 1; }
  100% { transform: translateX(30px); opacity: 0; }
}
.xd-ticket { animation: xd-ticket-in 4.2s ease-in-out infinite; }
@keyframes xd-ticket-in {
  0% { transform: translate(28px, -12px); opacity: 0; }
  30%, 80% { transform: translate(0, 0); opacity: 1; }
  100% { transform: translate(0, 13px); opacity: 0; }
}
.xd-clock-add { animation: xd-time-add 4.2s ease-in-out infinite; }
@keyframes xd-time-add {
  0%, 15%, 100% { opacity: 0.3; }
  35%, 80% { opacity: 1; }
}
.xd-nft-pepe {
  position: absolute;
  left: 15px;
  top: 23px;
  width: 69px;
  height: 69px;
  overflow: hidden;
  border-radius: 5px;
  image-rendering: pixelated;
}
.xd-nft-pepe > svg { width: 100%; height: 100%; }
.xd-nft-rewards { transform-origin: 126px 82px; animation: xd-earn 4s ease-in-out infinite alternate; }
@keyframes xd-earn { from { transform: scaleY(0.35); } to { transform: scaleY(1); } }
.xd-yield-token { position: absolute; left: 17px; top: 46px; }
.xd-yield-fill { transform-origin: 122px 83px; animation: xd-earn 6s ease-in-out infinite alternate; }
.xd-flatten { transform-origin: 80px 72px; transform: scaleY(0); animation: xd-flat 6s ease-in-out infinite; }
@keyframes xd-flat {
  0%, 15% { transform: scaleY(1); }
  50%, 85% { transform: scaleY(0); }
  100% { transform: scaleY(1); }
}
.xd-respawn-pepe, .xd-respawn-ghost {
  position: absolute;
  left: 45px;
  top: 23px;
  width: 69px;
  height: 69px;
  overflow: hidden;
  border-radius: 5px;
  image-rendering: pixelated;
}
.xd-respawn-pepe > svg, .xd-respawn-ghost > svg { width: 100%; height: 100%; }
.xd-respawn-pepe { animation: xd-die-revive 8s ease-in-out infinite; }
.xd-respawn-ghost { opacity: 0; filter: grayscale(1) brightness(1.5); animation: xd-ghost-rise 8s ease-in-out infinite; }
.xd-respawn-scene { position: absolute; inset: 0; width: 100%; height: 100%; }
.xd-grave { opacity: 0; animation: xd-grave-appear 8s ease-in-out infinite; }
.xd-revive-ring { opacity: 0; transform-origin: 80px 66px; animation: xd-revive-flash 8s ease-out infinite; }
.xd-respawn-still-arrow { display: none; }
/* Fire at 55% of the death/revival cycle, after the ghost fades and before
   the new pepe rises. Reduced motion also stops these rerolls. */
.xd-respawn-roll { position: absolute; opacity: 0; pointer-events: none; animation: xd-respawn-roll 8s linear -3.6s infinite; }
@keyframes xd-respawn-roll { from { opacity: 0; } to { opacity: 0; } }
@keyframes xd-die-revive {
  0%, 14%, 84%, 100% { transform: translate(0, 0) rotate(0deg); filter: grayscale(0); opacity: 1; }
  25% { transform: translate(8px, 7px) rotate(80deg); filter: grayscale(1); opacity: 1; }
  33% { transform: translate(8px, 7px) rotate(80deg); filter: grayscale(1); opacity: 0; }
  60% { transform: translate(0, 20px) scale(0.7); filter: grayscale(1); opacity: 0; }
  74% { transform: translate(0, -3px) scale(1.08); filter: grayscale(0); opacity: 1; }
}
@keyframes xd-ghost-rise {
  0%, 29%, 54%, 100% { opacity: 0; }
  29% { transform: translateY(14px) scale(0.65); }
  36% { transform: translateY(0) scale(0.65); opacity: 0.45; }
  54% { transform: translateY(-40px) scale(0.5); }
}
@keyframes xd-grave-appear {
  0%, 28%, 70%, 100% { opacity: 0; transform: translateY(8px); }
  38%, 57% { opacity: 1; transform: translateY(0); }
}
@keyframes xd-revive-flash {
  0%, 58%, 85%, 100% { opacity: 0; }
  58% { transform: scale(0.4); }
  65% { opacity: 0.8; }
  85% { transform: scale(1.5); }
}
@media (prefers-reduced-motion: reduce) {
  .xd-stage *, .xd-curve-detail * { animation: none !important; }
  .xd-deposit { transform: translateY(22px); }
  .xd-respawn-pepe { transform: translateX(30px); }
  .xd-grave { opacity: 1; transform: translateX(-45px); }
  .xd-respawn-still-arrow { display: block; }
}
`}</style>
  )
}

export type BeatKind = 'predeposit' | 'curve' | 'stake' | 'jackpot' | 'nft' | 'reserve' | 'settle' | 'respawn'

export function BeatDiagram({ kind }: { kind: BeatKind }) {
  const nftPepe = useMemo(() => kind === 'nft' ? randomPepe() : '', [kind])
  return (
    <div className="xd-stage" aria-hidden="true">
      {kind === 'curve' && <CurveDiagram />}

      {kind === 'predeposit' && (
        <svg viewBox="0 0 160 112">
          <text x="80" y="16" textAnchor="middle">public predeposit</text>
          {[28, 72, 116].map((x, i) => (
            <g key={x}>
              <rect x={x} y="27" width="16" height="12" rx="2" fill="var(--bg-2)" stroke="var(--text-lo)" />
              <path d={`M${x + 8} 42 V71 H80`} fill="none" stroke="var(--line)" />
              <rect x={x + 5} y="36" width="6" height="6" rx="1" fill="var(--accent)"
                className={`xd-deposit ${i === 1 ? 'xd-deposit-b' : i === 2 ? 'xd-deposit-c' : ''}`} />
            </g>
          ))}
          <rect x="34" y="75" width="92" height="23" rx="4" fill="var(--bg-2)" stroke="var(--accent)" />
          <text x="80" y="90" textAnchor="middle" className="xd-label">one pooled buy</text>
        </svg>
      )}

      {kind === 'stake' && (
        <svg viewBox="0 0 160 112">
          <text x="16" y="19">trading fees</text>
          <path d="M18 35 H140" stroke="var(--line)" />
          <rect x="40" y="31" width="8" height="8" rx="2" fill="var(--accent)" className="xd-fee" />
          <rect x="16" y="49" width="72" height="22" rx="3" fill="var(--accent)" />
          <rect x="91" y="49" width="42" height="22" rx="2" fill="var(--pot-gold)" />
          <rect x="136" y="49" width="6" height="22" rx="1" fill="var(--text-lo)" />
          <text x="16" y="94" className="xd-label">60% to stakers</text>
        </svg>
      )}

      {kind === 'jackpot' && (
        <svg viewBox="0 0 160 112">
          <text x="80" y="21" textAnchor="middle" className="xd-clock-add"
            style={{ fontFamily: 'var(--font-clock)', fontSize: 16, fill: 'var(--accent)' }}>+4:20</text>
          <text x="80" y="36" textAnchor="middle">per 0.005 mixETH</text>
          {[48, 62, 76].map(y => (
            <rect key={y} x="19" y={y} width="122" height="9" rx="2" fill="var(--bg-2)" stroke="var(--line)" />
          ))}
          <rect x="20" y="48" width="40" height="9" rx="2" fill="var(--pot-gold)" className="xd-ticket" />
          <text x="80" y="102" textAnchor="middle">last 10 tickets</text>
        </svg>
      )}

      {kind === 'nft' && (
        <>
          <span className="xd-nft-pepe" dangerouslySetInnerHTML={{ __html: nftPepe }} />
          <svg viewBox="0 0 160 112">
            <text x="15" y="15">PSP → pepe → fees</text>
            <path d="M93 81 H147" stroke="var(--line)" />
            <g className="xd-nft-rewards" fill="var(--pepe)">
              <rect x="99" y="63" width="9" height="18" rx="2" />
              <rect x="116" y="49" width="9" height="32" rx="2" />
              <rect x="133" y="35" width="9" height="46" rx="2" />
            </g>
            <text x="98" y="97">earned</text>
          </svg>
        </>
      )}

      {kind === 'reserve' && (
        <>
          <div className="xd-yield-token"><MixLogo px={32} /></div>
          <svg viewBox="0 0 160 112">
            <text x="16" y="19">external yield</text>
            <path d="M57 63 H99" stroke="var(--pepe)" strokeDasharray="2 3" />
            <rect x="72" y="60" width="6" height="6" rx="1" fill="var(--pepe)" className="xd-fee" />
            <rect x="107" y="33" width="30" height="51" rx="4" fill="var(--bg-2)" stroke="var(--pepe)" />
            <rect x="110" y="39" width="24" height="42" rx="2" fill="var(--pepe)" className="xd-yield-fill" />
            <text x="80" y="102" textAnchor="middle">ETH per mixETH</text>
          </svg>
        </>
      )}

      {kind === 'settle' && (
        <svg viewBox="0 0 160 112">
          <text x="80" y="17" textAnchor="middle">after detonation</text>
          <path d="M18 29 V85 H143" fill="none" stroke="var(--line)" />
          <path d="M20 72 H142" stroke="var(--accent)" strokeWidth="2" />
          <path d="M20 72 C58 72 54 52 79 52 S104 31 142 31" fill="none"
            stroke="var(--accent)" strokeWidth="3" className="xd-flatten" />
          {[38, 80, 122].map(x => <circle key={x} cx={x} cy="72" r="4" fill="var(--text-hi)" />)}
          <text x="80" y="102" textAnchor="middle">backing / PSP</text>
        </svg>
      )}

      {kind === 'respawn' && <RespawnDiagram />}
    </div>
  )
}

function RespawnDiagram() {
  const [pepeSvg, setPepeSvg] = useState(randomPepe)
  return (
    <>
      <span className="xd-respawn-roll" onAnimationIteration={(event) => {
        if (event.animationName === 'xd-respawn-roll') setPepeSvg(randomPepe())
      }} />
      <span className="xd-respawn-ghost" dangerouslySetInnerHTML={{ __html: pepeSvg }} />
      <span className="xd-respawn-pepe" dangerouslySetInnerHTML={{ __html: pepeSvg }} />
      <svg viewBox="0 0 160 112" className="xd-respawn-scene">
        <path d="M16 94 H144" stroke="var(--line)" />
        <g className="xd-grave">
          <path d="M62 93 V57 A18 18 0 0 1 98 57 V93 Z" fill="var(--bg-2)" stroke="var(--text-lo)" />
          <text x="80" y="67" textAnchor="middle" className="xd-label">RIP</text>
          <text x="80" y="82" textAnchor="middle" className="xd-label">PSP</text>
        </g>
        <circle cx="80" cy="66" r="31" fill="none" stroke="var(--pepe)" strokeWidth="2" className="xd-revive-ring" />
        <path d="M57 68 H70 L65 63 M70 68 L65 73" fill="none" stroke="var(--pepe)" strokeWidth="2" className="xd-respawn-still-arrow" />
        <text x="80" y="15" textAnchor="middle" className="xd-label">die. respawn. repeat.</text>
      </svg>
    </>
  )
}
