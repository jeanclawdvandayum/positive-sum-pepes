// The per-action FX catalog (PLAN Feature 3). One small component per kind;
// each resolves its own default target, positions from the event rects, keeps
// ≤~50 DOM particles per burst (the pepe confetti bursts are the largest), and
// reports done via a timer (the layer adds a 4s hard cap). Keyframes and node
// styling live in public/alt/fx.css.

import { useEffect, useRef, useState, type ComponentType } from 'react'
import { fxAnchorElement, type FxKind } from '../../lib/actionFx'
import { center, clampX, clockRect, feedCard, Flash, nudge, Over, queryRect, reducedMotion, useTimedDone, viewportRect, withVars, type FxProps } from './parts'
import { PepeConfetti } from './confetti'

const SEATS = 5
const TICKET_GAP_MS = 120
const TICKET_LAND_MS = 760 // 80% of the .95s flight
const COINS = 8
const CONFETTI = 40
const PIPS = 6

/** Above the anchor when the viewport has room for the 20px glyph; hugging the
 *  anchor's right edge (clamped inside the viewport) when there isn't. */
function hourglassSpot(anchor: DOMRect | undefined, fallback: { x: number; y: number }, top: number): { x: number; y: number } {
  if (top - 32 >= 8) return { x: fallback.x, y: top - 32 }
  const sideX = (anchor?.right ?? fallback.x) + 20
  return { x: Math.min(sideX, window.innerWidth - 24), y: Math.max(top, 8) }
}

/** The seats a buy's tickets land on: the ladder's top rows (newest ticket
 *  first), else the empty-ladder slot, else the panel or explicit target. */
function ladderSeats(target: DOMRect | undefined): DOMRect[] {
  const rows = [...document.querySelectorAll('.ladder-panel .ladder-row')]
    .slice(0, SEATS).map(row => row.getBoundingClientRect()).filter(rect => rect.width > 0)
  if (rows.length) return rows
  const slot = queryRect('.ladder-panel .empty-ladder') ?? target ?? queryRect('.ladder-panel')
  return slot ? [slot, slot, slot] : []
}

/** Ticket punch: pixel stubs print out of the button and land on the ladder's
 *  seats, each seat flashing as it is taken; the clock jolts and a confirmed
 *  +m:ss chip floats off it; happy pepe confetti bursts from the button. */
export function BuyFx({ event, onDone }: FxProps) {
  useTimedDone(onDone, 5000)
  const a = center(event.anchor)
  const [seats] = useState(() => ladderSeats(event.target))
  const [clock] = useState(clockRect)
  useEffect(() => {
    nudge(document.querySelector('.alt-clock') ?? document.querySelector('.mini-clock'), [
      { transform: 'translateY(0)' }, { transform: 'translateY(3px)' }, { transform: 'translateY(-2px)' }, { transform: 'translateY(0)' },
    ], { duration: 240, easing: 'steps(3)' })
    nudge(document.querySelector('.ladder-panel'), [
      { transform: 'translateY(0)' }, { transform: 'translateY(2px)' }, { transform: 'translateY(0)' },
    ], { duration: 180, easing: 'steps(2)', delay: TICKET_LAND_MS })
  }, [])
  const vh = window.innerHeight
  // One shared slot (empty ladder / panel) fans its tickets out side by side.
  const shared = seats.length > 1 && seats[0] === seats[1]
  // A ladder below the fold still receives its tickets: they fly to the edge.
  const landings = seats.map((seat, i) => ({
    x: seat.left + seat.width / 2 + (shared ? (i - 1) * 26 : 0),
    y: Math.min(Math.max(seat.top + seat.height / 2, 20), vh - 20),
  }))
  const chipBelow = clock ? clock.top < 44 : false
  return <>
    <Flash at={a} rect={event.anchor} tone="amber" />
    <PepeConfetti mood="happy" at={a} faces={30} bits={10} />
    {landings.map((land, i) => (
      <span key={i} className="fx-ticket" style={withVars({ left: a.x, top: a.y, animationDelay: `${i * TICKET_GAP_MS}ms` }, {
        '--dx': `${land.x - a.x}px`, '--dy': `${land.y - a.y}px`, '--lift': `${Math.min(land.y, a.y) - a.y - 70}px`,
      })} />
    ))}
    {(shared ? seats.slice(0, 1) : seats).map((seat, i) => (
      <Over key={`seat${i}`} rect={seat} className="fx-seat-take" style={{ animationDelay: `${TICKET_LAND_MS + i * TICKET_GAP_MS}ms` }} />
    ))}
    {/* Truthful chip only (Round 2, Feature 7): no confirmed TimeAdded, no chip. */}
    {clock && event.detail && (
      <span className={`fx-clock-chip${chipBelow ? ' fx-clock-chip-below' : ''}`}
        style={{ left: clampX(clock.left + clock.width / 2, 48), top: chipBelow ? clock.bottom + 6 : clock.top - 6 }}>
        {event.detail}
      </span>
    )}
  </>
}

/** Drain + sulk: mixETH coins slot into the button under a downward shutter
 *  wipe while a burst of rage/angry/sad/meh pepes flies out of it. */
export function SellFx({ event, onDone }: FxProps) {
  useTimedDone(onDone, 5000)
  const a = center(event.anchor)
  return <>
    <Flash at={a} rect={event.anchor} tone="amber" />
    {Array.from({ length: COINS - 1 }, (_, i) => (
      <span key={i} className="fx-coin fx-coin-fall" style={{ left: a.x + (i - 3) * 11, top: a.y - 8, animationDelay: `${i * 60}ms` }} />
    ))}
    <Over rect={event.anchor} className="fx-over-center"><span className="fx-shutter" /></Over>
    <PepeConfetti mood="sad" at={a} faces={32} bits={10} delay={120} />
  </>
}

/** Cannonball: the selected picker tile arcs into the predeposit progress; ripples + total flash. */
export function PredepositFx({ event, onDone }: FxProps) {
  useTimedDone(onDone, 1800)
  const host = useRef<HTMLSpanElement>(null)
  // Measured once: the picker may re-render while the effect is airborne.
  const [tile] = useState(() => document.querySelector<HTMLElement>('.pd-picker [aria-pressed="true"]'))
  const [tileRect] = useState(() => (tile?.isConnected ? tile.getBoundingClientRect() : undefined))
  const origin = center(tileRect ?? event.anchor)
  const t = center(event.target ?? queryRect('.pd-progress'))
  useEffect(() => {
    if (!tile || !host.current || !tileRect) return
    const clone = tile.cloneNode(true) as HTMLElement
    clone.style.animation = 'none'
    clone.style.transition = 'none'
    host.current.replaceChildren(clone)
  }, [tile, tileRect])
  const flyStyle = tileRect
    ? { left: tileRect.left + tileRect.width / 2, top: tileRect.top + tileRect.height / 2,
        width: tileRect.width, height: tileRect.height, marginLeft: -tileRect.width / 2, marginTop: -tileRect.height / 2 }
    : { left: origin.x, top: origin.y }
  return <>
    <Flash at={origin} rect={event.anchor} />
    <span ref={host} className={`fx-ball-fly${tileRect ? '' : ' fx-ball-naked'}`}
      style={withVars(flyStyle, { '--dx': `${t.x - origin.x}px`, '--dy': `${t.y - origin.y}px` })}>
      {!tileRect && <span className="fx-ball-core" />}
    </span>
    {[950, 1120, 1290].map((delay, i) => (
      <span key={delay} className="fx-ring" style={{ left: t.x, top: t.y, animationDelay: `${delay}ms`, animationDuration: `${620 - i * 90}ms` }} />
    ))}
    <Over rect={event.target ?? queryRect('.pd-progress')} className="fx-total-flash" />
  </>
}

/** Ignition: a flare streak rises, the page warms, and the clock digits power on left to right. */
export function LaunchFx({ event, onDone }: FxProps) {
  useTimedDone(onDone, 1500)
  const a = center(event.anchor)
  const clock = clockRect()
  useEffect(() => {
    nudge(document.querySelector('.alt-clock') ?? document.querySelector('.mini-clock'), [
      { filter: 'brightness(.3)' }, { filter: 'brightness(1.8)' }, { filter: 'brightness(1)' },
    ], { duration: 900 })
  }, [])
  return <>
    <Flash at={a} rect={event.anchor} tone="amber" />
    <span className="fx-flare" style={{ left: a.x, top: a.y }} />
    <Over rect={viewportRect()} className="fx-warm" />
    <Over rect={clock} className="fx-clock-reveal" />
  </>
}

/** Clamp: a pixel padlock drops on the anchor, the shackle snaps, chain links flash across. */
export function StakeFx({ event, onDone }: FxProps) {
  useTimedDone(onDone, 1500)
  const a = center(event.anchor)
  return <>
    <Flash at={a} rect={event.anchor} />
    <span className="fx-lock" style={{ left: a.x, top: a.y }}>
      <span className="fx-lock-shackle fx-snap" />
      <span className="fx-lock-body" />
    </span>
    {Array.from({ length: 5 }, (_, i) => (
      <span key={i} className="fx-chain-link-flash" style={{ left: a.x + (i - 2) * 14, top: a.y - 26, animationDelay: `${520 + i * 70}ms` }} />
    ))}
  </>
}

/** Feed: PSP pixels stream into the pepe card, which does a satisfied bounce. */
export function TopUpFx({ event, onDone }: FxProps) {
  useTimedDone(onDone, 1400)
  const a = center(event.anchor)
  const card = feedCard(event.anchor)
  const t = center(card.rect)
  useEffect(() => {
    nudge(card.el, [{ transform: 'scale(1)' }, { transform: 'translateY(-4px) scale(1.03)' }, { transform: 'scale(1)' }],
      { duration: 340, easing: 'steps(3)', delay: 620 })
  }, [card])
  return <>
    <Flash at={a} rect={event.anchor} />
    {Array.from({ length: COINS }, (_, i) => (
      <span key={i} className="fx-bit fx-stream" style={withVars({ left: a.x, top: a.y, animationDelay: `${i * 70}ms` },
        { '--dx': `${t.x - a.x}px`, '--dy': `${t.y - a.y}px` })} />
    ))}
  </>
}

/** Fountain: coins burst up from the button and arc into the wallet chip, which pulses. */
export function ClaimFeesFx({ event, onDone }: FxProps) {
  useTimedDone(onDone, 1500)
  const a = center(event.anchor)
  const chip = event.target ?? queryRect('.wallet-button')
  const t = center(chip)
  useEffect(() => {
    nudge(document.querySelector('.wallet-button'), [{ transform: 'scale(1)' }, { transform: 'scale(1.06)' }, { transform: 'scale(1)' }],
      { duration: 280, easing: 'steps(2)', delay: 720 })
  }, [])
  return <>
    <Flash at={a} rect={event.anchor} tone="amber" />
    {Array.from({ length: COINS }, (_, i) => (
      <span key={i} className="fx-coin fx-coin-arc" style={withVars({ left: a.x, top: a.y, animationDelay: `${i * 55}ms` },
        { '--dx': `${t.x - a.x}px`, '--dy': `${t.y - a.y}px` })} />
    ))}
    <Over rect={chip} className="fx-chip-pulse" />
  </>
}

/** Loop: coins orbit the anchor in a circular trail, then dive into the pepe card under a ⟳ trace. */
export function ReinvestFx({ event, onDone }: FxProps) {
  useTimedDone(onDone, 1700)
  const a = center(event.anchor)
  const card = feedCard(event.anchor)
  const t = center(card.rect)
  useEffect(() => {
    nudge(card.el, [{ transform: 'scale(1)' }, { transform: 'translateY(-4px) scale(1.03)' }, { transform: 'scale(1)' }],
      { duration: 340, easing: 'steps(3)', delay: 1150 })
  }, [card])
  return <>
    <Flash at={a} rect={event.anchor} />
    <span className="fx-orbit" style={{ left: a.x, top: a.y }}>
      {[0, 90, 180, 270].map(deg => (
        <span key={deg} className="fx-coin" style={{ transform: `rotate(${deg}deg) translateX(26px)` }} />
      ))}
    </span>
    <span className="fx-loop-glyph" style={{ left: a.x, top: a.y - 26 }}>⟳</span>
    {[0, 1, 2].map(i => (
      <span key={i} className="fx-coin fx-coin-arc" style={withVars({ left: a.x, top: a.y, animationDelay: `${700 + i * 90}ms` },
        { '--dx': `${t.x - a.x}px`, '--dy': `${t.y - a.y}px` })} />
    ))}
  </>
}

/** Hourglass: the hourglass flips and the six vest pips light in sequence. */
export function RequestWithdrawFx({ event, onDone }: FxProps) {
  useTimedDone(onDone, 1500)
  const a = center(event.anchor)
  const top = event.anchor?.top ?? a.y
  const flip = hourglassSpot(event.anchor, a, top)
  return <>
    <Flash at={a} rect={event.anchor} tone="amber" />
    <span className="fx-hourglass fx-flip-down" style={{ left: flip.x, top: flip.y }} />
    {Array.from({ length: PIPS }, (_, i) => (
      <span key={i} className="fx-pip" style={{ left: a.x + (i - (PIPS - 1) / 2) * 13, top: top - 10 }}>
        <span className="fx-pip-lit" style={{ animationDelay: `${240 + i * 110}ms` }} />
      </span>
    ))}
  </>
}

/** Rewind: the hourglass flips back, the pips unlight in reverse and the padlock re-snaps. */
export function CancelWithdrawFx({ event, onDone }: FxProps) {
  useTimedDone(onDone, 1500)
  const a = center(event.anchor)
  const top = event.anchor?.top ?? a.y
  const flip = hourglassSpot(event.anchor, a, top)
  return <>
    <Flash at={a} rect={event.anchor} />
    <span className="fx-hourglass fx-flip-up" style={{ left: flip.x, top: flip.y }} />
    {Array.from({ length: PIPS }, (_, i) => (
      <span key={i} className="fx-pip" style={{ left: a.x + (i - (PIPS - 1) / 2) * 13, top: top - 10 }}>
        <span className="fx-pip-lit fx-pip-out" style={{ animationDelay: `${240 + (PIPS - 1 - i) * 110}ms` }} />
      </span>
    ))}
    <span className="fx-lock fx-lock-small fx-lock-rewind" style={{ left: clampX(a.x + 54, 14), top: top - 10 }}>
      <span className="fx-lock-shackle fx-snap" />
      <span className="fx-lock-body" />
    </span>
  </>
}

/** Break free: the padlock shackle pops open and the pieces tumble. */
export function UnlockFx({ event, onDone }: FxProps) {
  useTimedDone(onDone, 1300)
  const a = center(event.anchor)
  return <>
    <Flash at={a} rect={event.anchor} tone="amber" />
    <span className="fx-lock" style={{ left: a.x, top: a.y }}>
      <span className="fx-lock-shackle fx-shackle-pop" />
      <span className="fx-lock-body fx-body-fall" />
    </span>
  </>
}

/** Jackpot prelude (Round 5): gold pixel confetti falls from the top edge, a
 *  coin fountain arcs into the wallet chip (which pulses) and the anchor gets
 *  a stamped ✓ seal. The victory modal opens ~0.9s later with the message,
 *  the payout and its own happy pepe burst above the dimmed page. */
export function ClaimPotFx({ event, onDone }: FxProps) {
  useTimedDone(onDone, 3000)
  const a = center(event.anchor)
  const chip = event.target ?? queryRect('.wallet-button')
  const t = center(chip)
  return <>
    <Flash at={a} rect={event.anchor} tone="amber" />
    {Array.from({ length: CONFETTI }, (_, i) => (
      <span key={i} className={`fx-confetti${i % 3 === 1 ? ' fx-confetti-m' : i % 3 === 2 ? ' fx-confetti-l' : ''}${i % 2 ? ' fx-confetti-alt' : ''}`}
        style={withVars({ left: ((i + 0.5) * window.innerWidth) / CONFETTI, top: 0, animationDelay: `${(i * 137) % 400}ms` },
          { '--fall': `${window.innerHeight * (0.42 + (i % 5) * 0.06)}px`, '--sway': `${(i % 2 ? 1 : -1) * (5 + (i % 3) * 3)}px`, '--spin': `${(i % 2 ? 1 : -1) * 270}deg` })} />
    ))}
    {/* the payout arcs into the wallet chip, which pulses as the coins land */}
    {Array.from({ length: COINS }, (_, i) => (
      <span key={`coin${i}`} className="fx-coin fx-coin-arc" style={withVars({ left: a.x, top: a.y, animationDelay: `${120 + i * 60}ms` },
        { '--dx': `${t.x - a.x}px`, '--dy': `${t.y - a.y}px` })} />
    ))}
    <Over rect={chip} className="fx-chip-pulse" />
    <span className="fx-seal" style={{ left: a.x, top: a.y }}>✓</span>
  </>
}

/** Transmute: PSP pixels ignite into embers, which cool into mixETH coins rising from the anchor. */
export function RedeemFx({ event, onDone }: FxProps) {
  useTimedDone(onDone, 1800)
  const a = center(event.anchor)
  return <>
    <Flash at={a} rect={event.anchor} />
    {Array.from({ length: 6 }, (_, i) => (
      <span key={i} className="fx-ember" style={{ left: a.x + (i - 2.5) * 9, top: a.y - 4, animationDelay: `${i * 60}ms` }} />
    ))}
    {Array.from({ length: COINS - 2 }, (_, i) => (
      <span key={i} className="fx-coin fx-coin-rise" style={{ left: a.x + (i - 2.5) * 10, top: a.y, animationDelay: `${480 + i * 95}ms` }} />
    ))}
  </>
}

/** Chain: three nodes link up left to right across the anchor, then coins drop onto it. */
export function ClaimReferralFx({ event, onDone }: FxProps) {
  useTimedDone(onDone, 1600)
  const a = center(event.anchor)
  const top = event.anchor?.top ?? a.y
  return <>
    <Flash at={a} rect={event.anchor} tone="amber" />
    {[-40, 0, 40].map((offset, i) => (
      <span key={offset} className="fx-chain-node" style={{ left: a.x + offset, top: top - 18, animationDelay: `${120 + i * 240}ms` }} />
    ))}
    {[-33, 7].map((offset, i) => (
      <span key={offset} className="fx-chain-bar" style={{ left: a.x + offset, top: top - 18, animationDelay: `${230 + i * 240}ms` }} />
    ))}
    {[0, 1, 2].map(i => (
      <span key={i} className="fx-coin fx-coin-drop-onto" style={{ left: a.x + (i - 1) * 12, top: top - 36, animationDelay: `${840 + i * 110}ms` }} />
    ))}
  </>
}

/** Wax seal: a seal stamps down onto the anchor with a squash and ink splash. */
export function NameCommitFx({ event, onDone }: FxProps) {
  useTimedDone(onDone, 1200)
  const a = center(event.anchor)
  const splashes = 6
  return <>
    <Flash at={a} rect={event.anchor} />
    <span className="fx-wax" style={{ left: a.x, top: a.y }} />
    {Array.from({ length: splashes }, (_, i) => {
      const angle = (i / splashes) * Math.PI * 2
      return <span key={i} className="fx-ink" style={withVars({ left: a.x, top: a.y, animationDelay: `${400 + i * 25}ms` },
        { '--tx': `${Math.cos(angle) * 22}px`, '--ty': `${Math.sin(angle) * 14}px` })} />
    })}
  </>
}

/** Nameplate: a plate slides under the anchor, a typewriter caret sweeps across it, then a sparkle. */
export function NameRegisterFx({ event, onDone }: FxProps) {
  useTimedDone(onDone, 1500)
  const a = center(event.anchor)
  const plateTop = (event.anchor?.bottom ?? a.y + 10) + 14
  const plateX = clampX(a.x, 48)
  return <>
    <Flash at={a} rect={event.anchor} />
    <span className="fx-plate" style={{ left: plateX, top: plateTop }}>
      <span className="fx-caret" />
    </span>
    <span className="fx-spark" style={withVars({ left: plateX + 40, top: plateTop, animationDelay: '1020ms' }, { '--tx': '6px', '--ty': '-14px' })} />
  </>
}

/** Link forge: two chain halves snap together, then a paper plane flies off. */
export function RefLinkFx({ event, onDone }: FxProps) {
  useTimedDone(onDone, 1500)
  const a = center(event.anchor)
  return <>
    <Flash at={a} rect={event.anchor} />
    <span className="fx-half fx-half-l" style={{ left: a.x - 10, top: a.y }} />
    <span className="fx-half fx-half-r" style={{ left: a.x + 10, top: a.y }} />
    <span className="fx-plane" style={{ left: a.x, top: a.y }} />
  </>
}

/** Polaroid: a camera flash, then a mini frame drops and settles. */
export function ShareImageFx({ event, onDone }: FxProps) {
  useTimedDone(onDone, 1200)
  const a = center(event.anchor)
  return <>
    <Flash at={a} rect={event.anchor} />
    <Over rect={viewportRect()} className="fx-white" />
    <span className="fx-polaroid" style={{ left: a.x, top: a.y }} />
  </>
}

/** Drip: three droplets fall from the top of the anchor and splash into the balance. */
export function FaucetFx({ event, onDone }: FxProps) {
  useTimedDone(onDone, 1300)
  const a = center(event.anchor)
  const topY = (event.anchor?.top ?? a.y) - 28
  return <>
    <Flash at={a} rect={event.anchor} />
    {[-10, 0, 10].map((offset, i) => (
      <span key={offset} className="fx-droplet" style={{ left: a.x + offset, top: topY, animationDelay: `${i * 210}ms` }} />
    ))}
    {[-10, 0, 10].map((offset, i) => (
      <span key={`s${offset}`} className="fx-splash-bit" style={{ left: a.x + offset, top: topY + 26, animationDelay: `${250 + i * 210}ms` }} />
    ))}
  </>
}

/** Send-off: a clone of the pepe card slides off to the right with a motion trail. */
export function TransferPepeFx({ event, onDone }: FxProps) {
  useTimedDone(onDone, 1100)
  const card = feedCard(event.anchor)
  const host = useRef<HTMLSpanElement>(null)
  const rect = card.rect
  const a = center(event.anchor)
  useEffect(() => {
    if (!host.current || !(card.el instanceof HTMLElement)) return
    const clone = card.el.cloneNode(true) as HTMLElement
    clone.style.animation = 'none'
    clone.style.transition = 'none'
    host.current.replaceChildren(clone)
  }, [card])
  const box = rect.width || rect.height
    ? { left: rect.left, top: rect.top, width: rect.width, height: rect.height }
    : undefined
  return <>
    <Flash at={a} rect={event.anchor} />
    {box && <span ref={host} className="alt-shell fx-ghost fx-clone-host" style={box} />}
    {box && <span className="fx-trail" style={withVars(box, { '--peak': '.4' })} />}
    {box && <span className="fx-trail fx-trail-far" style={withVars(box, { '--peak': '.2' })} />}
  </>
}

/** Key turn: a small key rotates 90° inside the button. Subtle. */
export function ApproveFx({ event, onDone }: FxProps) {
  useTimedDone(onDone, 900)
  const a = center(event.anchor)
  return <>
    <Flash at={a} rect={event.anchor} />
    <span className="fx-key" style={{ left: a.x, top: a.y }}>
      <span className="fx-key-bow" />
      <span className="fx-key-shaft" />
    </span>
  </>
}

/** Respawn: an egg rolls in (the landing xd-respawn-roll motif), cracks, and a pepe pops out. */
export function SpawnFx({ event, onDone }: FxProps) {
  useTimedDone(onDone, 1600)
  const a = center(event.anchor)
  return <>
    <Flash at={a} rect={event.anchor} />
    <span className="fx-egg" style={{ left: a.x, top: a.y - 18 }} />
    <span className="fx-shell fx-shell-l" style={{ left: a.x - 4, top: a.y - 18 }} />
    <span className="fx-shell fx-shell-r" style={{ left: a.x + 4, top: a.y - 18 }} />
    <span className="fx-pop" style={{ left: a.x + 18, top: a.y - 20 }} />
  </>
}

/** Failure: the anchor shakes 3px twice and flickers red. No particles. */
export function FailFx({ event, onDone }: FxProps) {
  useTimedDone(onDone, 750)
  const a = center(event.anchor)
  useEffect(() => {
    if (reducedMotion()) return
    // The element captured for THIS event — the press that started the failed
    // action, however long the transaction took.
    fxAnchorElement(event.id)?.animate([
      { transform: 'translateX(0)' }, { transform: 'translateX(-3px)' }, { transform: 'translateX(3px)' },
      { transform: 'translateX(-3px)' }, { transform: 'translateX(3px)' }, { transform: 'translateX(0)' },
    ], { duration: 300, easing: 'steps(2)' })
  }, [event.id])
  return <>
    <Flash at={a} rect={event.anchor} tone="red" />
    <Over rect={event.anchor} className="fx-fail-tint" />
  </>
}

/** Every non-modal kind. `detonate` (DetonationSetPiece) and `claimPredeposit`
 *  (HatchModal) are rendered by ActionFxLayer itself. */
export const FX_EFFECTS: Record<Exclude<FxKind, 'detonate' | 'claimPredeposit'>, ComponentType<FxProps>> = {
  buy: BuyFx,
  sell: SellFx,
  predeposit: PredepositFx,
  launch: LaunchFx,
  stake: StakeFx,
  topUp: TopUpFx,
  claimFees: ClaimFeesFx,
  reinvest: ReinvestFx,
  requestWithdraw: RequestWithdrawFx,
  cancelWithdraw: CancelWithdrawFx,
  unlock: UnlockFx,
  claimPot: ClaimPotFx,
  redeem: RedeemFx,
  claimReferral: ClaimReferralFx,
  nameCommit: NameCommitFx,
  nameRegister: NameRegisterFx,
  refLink: RefLinkFx,
  shareImage: ShareImageFx,
  faucet: FaucetFx,
  transferPepe: TransferPepeFx,
  approve: ApproveFx,
  spawn: SpawnFx,
  fail: FailFx,
}
