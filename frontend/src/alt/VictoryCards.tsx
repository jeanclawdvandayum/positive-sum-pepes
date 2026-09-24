// Persistent victory cards (PLAN Round 4): one per confirmed claimPot, fed by
// the victoryCards store. Mounted ONLY in AltShell — the store is inert and
// the original UI untouched without this subscriber. Cards stay until closed
// (no auto-dismiss), stack bottom-left below the toasts (z-index 9500 < 10000),
// and carry their own mount-time mini burst (skipped under reduced motion).

import { useMemo, useState, useSyncExternalStore, type CSSProperties } from 'react'
import { targetChain } from '../lib/config'
import { fmtAmount } from '../lib/format'
import { renderDecorativePepeSvg } from '../lib/pepeRender'
import { bragUrl, victoryCards, type VictoryCard } from '../lib/victoryCards'
import { reducedMotion } from './fx/parts'

/** The visible stack; older cards collapse into a '+N more' line. */
const VISIBLE = 4

/** Deterministic mini burst per card mount: same flight on every render, so
 *  QA screenshots and repeat claims read the same. */
const BITS = Array.from({ length: 12 }, (_, i) => {
  const angle = (i / 12) * Math.PI * 2 + 0.35
  const reach = 26 + (i % 3) * 12
  return {
    tx: `${Math.round(Math.cos(angle) * reach)}px`,
    ty: `${Math.round(Math.sin(angle) * reach - 14)}px`,
    delay: `${i * 26}ms`,
  }
})

function VictoryCardItem({ card }: { card: VictoryCard }) {
  const svg = useMemo(() => renderDecorativePepeSvg(), [])
  const quiet = useMemo(reducedMotion, [])
  const explorer = targetChain.blockExplorers?.default
  return (
    <article className="victory-card">
      {!quiet && BITS.map((bit, i) => (
        <i key={i} className="victory-bit" style={{ '--tx': bit.tx, '--ty': bit.ty, animationDelay: bit.delay } as CSSProperties} />
      ))}
      <span className="victory-pepe" aria-hidden="true">
        <img src={`data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`} alt="" />
      </span>
      <div className="victory-body">
        <span className="victory-head">POT CLAIMED</span>
        <span className="victory-amount">{fmtAmount(card.amountMix)} mixETH</span>
        <span className="victory-round">round {card.roundId.toString()}{card.roundName ? ` · ${card.roundName}` : ''}</span>
        <p className="victory-message">{card.message}</p>
        <div className="victory-links">
          {card.txHash && explorer && (
            <a href={`${explorer.url}/tx/${card.txHash}`} target="_blank" rel="noopener noreferrer">view tx ↗</a>
          )}
          <a href={bragUrl(card)} target="_blank" rel="noopener noreferrer">brag on X ↗</a>
        </div>
      </div>
      <button type="button" className="victory-close" aria-label="Dismiss victory card" onClick={() => victoryCards.dismiss(card.id)}>×</button>
    </article>
  )
}

export default function VictoryCards() {
  const cards = useSyncExternalStore(victoryCards.subscribe, victoryCards.snapshot)
  const [expanded, setExpanded] = useState(false)
  if (!cards.length) return null
  const visible = expanded ? cards : cards.slice(0, VISIBLE)
  const hidden = cards.length - visible.length
  return (
    <div className="victory-stack" aria-live="polite" aria-label="Pot claim victories">
      {visible.map(card => <VictoryCardItem key={card.id} card={card} />)}
      {hidden > 0 && <button type="button" className="victory-more" onClick={() => setExpanded(true)}>+{hidden} more</button>}
      {expanded && cards.length > VISIBLE && <button type="button" className="victory-more" onClick={() => setExpanded(false)}>show less</button>}
    </div>
  )
}
