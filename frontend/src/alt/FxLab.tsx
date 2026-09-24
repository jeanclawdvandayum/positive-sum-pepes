// FxLab — DEV-ONLY QA stage for the per-action FX catalog (PLAN Feature 3).
// Imported lazily from AltShell behind import.meta.env.DEV, so production
// builds tree-shake this module away. Labels are the FxKind names themselves;
// it ships no copy.

import { useRef, useState } from 'react'
import { fireFx, type FxKind } from '../lib/actionFx'
import { pickVictoryMessage, victoryCards } from '../lib/victoryCards'
import { renderPepeSvg } from '../lib/pepeRender'
import { dnaOfId } from '../components/PepePicker'
import { PixelIcon } from '../components/PixelIcon'

const KINDS: FxKind[] = [
  'buy', 'sell', 'predeposit', 'launch', 'stake', 'topUp', 'claimFees', 'reinvest',
  'requestWithdraw', 'cancelWithdraw', 'unlock', 'claimPot', 'redeem', 'claimPredeposit',
  'claimReferral', 'nameCommit', 'nameRegister', 'refLink', 'shareImage', 'faucet',
  'transferPepe', 'approve', 'spawn', 'fail',
]

/** Realistic default targets per kind; effects resolve the rest themselves.
 *  The buy chip is the confirmed +m:ss only (Round 2, Feature 7). */
const TARGETS: Partial<Record<FxKind, { target?: string; detail?: string }>> = {
  buy: { target: '.ladder-panel', detail: '+1:09' },
  predeposit: { target: '.pd-progress' },
  claimFees: { target: '.wallet-button' },
}

const LADDER_ROWS = [0, 1, 2, 3, 4]
/** The lab hatches release-2 art, like a live round's staker. */
const LAB_DNA_VERSION = 2n
const randomPepeId = () => BigInt(Math.floor(Math.random() * 2 ** 40)) + 1n

export default function FxLab() {
  const anchors = useRef(new Map<FxKind, HTMLButtonElement>())
  const stage = useRef<HTMLDivElement>(null)
  // The pepe the hatch will reveal, shown in the mock card so QA can match it.
  const [pepeId, setPepeId] = useState(randomPepeId)

  const fire = (kind: FxKind, el: Element) => {
    const spec = TARGETS[kind]
    // The lab's claimPot plays the full celebration AND pushes a real victory
    // card: demo payout, demo round, no hash (nothing to link to). The message
    // is picked once so the banner and the card agree.
    if (kind === 'claimPot') {
      const message = pickVictoryMessage()
      fireFx(kind, { anchor: el, target: spec?.target, detail: message })
      victoryCards.push({ roundId: 3n, roundName: 'the fx lab round', amountMix: 1234n * 10n ** 16n, message })
      return
    }
    fireFx(kind, {
      anchor: el, target: spec?.target, detail: spec?.detail,
      pepe: kind === 'claimPredeposit' ? { id: pepeId, dnaVersion: LAB_DNA_VERSION, dna: dnaOfId(pepeId) } : undefined,
    })
  }

  // The hatch is an interactive modal, so the staggered run skips it.
  const fireAll = () => {
    KINDS.filter(kind => kind !== 'claimPredeposit').forEach((kind, i) => setTimeout(() => {
      const el = anchors.current.get(kind)
      if (el) fire(kind, el)
    }, i * 220))
  }

  const kindButton = (kind: FxKind) => (
    <button key={kind} className="st-btn fx-lab-btn" onClick={e => fire(kind, e.currentTarget)}
      ref={el => { if (el) anchors.current.set(kind, el) }}>
      {kind}
    </button>
  )

  return (
    <div className="fx-lab">
      <div>
        <h1 className="fx-lab-title">fx lab</h1>
        <p className="fx-lab-note">dev only · one button per FxKind · effects need ActionFxLayer (alt shell)</p>
        <div className="fx-lab-grid">{KINDS.map(kindButton)}</div>
        <div className="fx-lab-row">
          <button className="st-btn st-btn-primary" onClick={fireAll}>fire all (staggered)</button>
          <button className="st-btn" onClick={e => fireFx('detonate', { anchor: e.currentTarget, target: '.fx-lab-stage' })}>
            detonate
          </button>
          {/* the hatch with no knowable id reveals a decorative pepe */}
          <button className="st-btn" onClick={e => fireFx('claimPredeposit', { anchor: e.currentTarget })}>
            claimPredeposit (no id)
          </button>
          <button className="st-btn" onClick={() => victoryCards.clear()}>clear victory cards</button>
        </div>
        <div className="fx-lab-states">
          <DetonateState state="armed" />
          <DetonateState state="pending" />
          <DetonateState state="done" />
        </div>
      </div>
      <div className="fx-lab-stage" ref={stage}>
        <div className="instrument">
          <div className="clock alt-clock">00:00:00</div>
        </div>
        <section className="ladder-panel">
          <div className="ladder">
            {LADDER_ROWS.map(i => (
              <div key={i} className="ladder-row">
                <span className="rank">{i + 1}</span>
                <span className="bar"><span /></span>
              </div>
            ))}
          </div>
        </section>
        <div className="pd-progress card p-4" data-testid="mock-progress">
          <div className="pd-bar"><span /></div>
        </div>
        <div className="rounded-2xl card p-4 fx-lab-pepe">
          <div className="fx-lab-pepe-art">
            <img alt="" src={`data:image/svg+xml,${encodeURIComponent(renderPepeSvg(dnaOfId(pepeId), LAB_DNA_VERSION))}`} />
            <button className="st-btn fx-lab-btn" onClick={() => setPepeId(randomPepeId())}>hatch id {String(pepeId)} ↻</button>
          </div>
          {/* feed/loop/send-off fire from inside the mock pepe card */}
          <div className="fx-lab-grid">
            {['topUp', 'reinvest', 'transferPepe'].map(kind => kindButton(kind as FxKind))}
          </div>
        </div>
      </div>
    </div>
  )
}

/** Exact alt DetonateButton markup, pinned to one data-state for QA (dev only). */
function DetonateState({ state }: { state: 'armed' | 'pending' | 'done' }) {
  const label = state === 'pending' ? 'detonating…' : state === 'done' ? 'detonated ✓' : 'detonate'
  return (
    <button
      data-state={state}
      data-pending={state === 'pending' || undefined}
      disabled={state !== 'armed'}
      aria-label="detonate — settle the round"
      className="tx-action relative flex items-center gap-2.5 overflow-hidden rounded-xl border border-phase-critical/60 bg-phase-critical/10 px-8 py-3 font-display text-xl text-phase-critical transition hover:bg-phase-critical/20 active:translate-y-[1px] disabled:cursor-wait disabled:opacity-80 alt-detonate"
    >
      <span className="pl-btn-fill" aria-hidden="true" />
      <span className="dtn-stripes" aria-hidden="true" />
      <span className="dtn-bomb">
        <PixelIcon name="bomb" size={26} />
        <span className="dtn-spark" aria-hidden="true" />
      </span>
      <span className="relative">{label}</span>
      <span className="dtn-fuse" aria-hidden="true" />
    </button>
  )
}
