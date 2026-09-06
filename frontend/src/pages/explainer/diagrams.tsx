import MixLogo from '../../components/MixLogo'
import { CurveDiagram } from './CurveExplainer'

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
.xd-page[data-illustrations-paused="true"] :is(.xd-stage, .xd-curve-detail) * {
  animation-play-state: paused !important;
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
.xd-new-chart { stroke-dasharray: 1; stroke-dashoffset: 0; animation: xd-respawn 6s ease-in-out infinite; }
@keyframes xd-respawn {
  0%, 15% { stroke-dashoffset: 1; opacity: 0.3; }
  70%, 90% { stroke-dashoffset: 0; opacity: 1; }
  100% { stroke-dashoffset: 0; opacity: 0.3; }
}
@media (prefers-reduced-motion: reduce) {
  .xd-stage *, .xd-curve-detail * { animation: none !important; }
  .xd-motion-toggle { display: none; }
  .xd-deposit { transform: translateY(22px); }
}
`}</style>
  )
}

export type BeatKind = 'predeposit' | 'curve' | 'stake' | 'jackpot' | 'nft' | 'reserve' | 'settle' | 'respawn'

export function BeatDiagram({ kind, pepeSvg }: { kind: BeatKind; pepeSvg: string }) {
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
          <span className="xd-nft-pepe" dangerouslySetInnerHTML={{ __html: pepeSvg }} />
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

      {kind === 'respawn' && (
        <svg viewBox="0 0 160 112">
          <text x="16" y="18">next round</text>
          <path d="M124 13 A10 10 0 1 0 143 20 M143 11 V20 H134" fill="none" stroke="var(--accent)" strokeWidth="2" />
          <path d="M18 37 V87 H143" fill="none" stroke="var(--line)" />
          <path d="M19 81 H142" stroke="var(--text-lo)" strokeDasharray="2 4" opacity="0.4" />
          <path d="M20 81 C48 81 49 67 65 67 S94 46 109 46 S124 33 142 33" fill="none"
            stroke="var(--accent)" strokeWidth="3" pathLength="1" className="xd-new-chart" />
          <text x="80" y="103" textAnchor="middle">fresh chart</text>
        </svg>
      )}
    </div>
  )
}
