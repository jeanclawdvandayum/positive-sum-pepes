// FxLab — DEV-ONLY QA stage for the per-action FX catalog (PLAN Feature 3).
// Imported lazily from AltShell behind import.meta.env.DEV, so production
// builds tree-shake this module away. Labels are the FxKind names themselves;
// it ships no copy.

import { useRef, useState } from 'react'
import { useAccount } from 'wagmi'
import { fireFx, type FxKind } from '../lib/actionFx'
import { pickVictoryMessage, victories } from '../lib/victoryCards'
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

// All ten ladder spots, art on the first four (mixed occupied/empty escape).
const LADDER_ROWS = Array.from({ length: 10 }, (_, i) => i)
/** The lab hatches release-2 art, like a live round's staker. */
const LAB_DNA_VERSION = 2n
const randomPepeId = () => BigInt(Math.floor(Math.random() * 2 ** 40)) + 1n
/** A connected wallet's own identity pepe, else a fixed demo wallet's. */
const LAB_WALLET: `0x${string}` = '0x00000000000000000000000000000000006c4b1a'
const LADDER_ART = Array.from({ length: 4 }, () => renderPepeSvg(dnaOfId(randomPepeId()), LAB_DNA_VERSION))
const mockHand = (count: number) => Array.from({ length: count }, () => renderPepeSvg(dnaOfId(randomPepeId()), LAB_DNA_VERSION))

export default function FxLab() {
  const { address } = useAccount()
  const anchors = useRef(new Map<FxKind, HTMLButtonElement>())
  const stage = useRef<HTMLDivElement>(null)
  // The pepe the hatch will reveal, shown in the mock card so QA can match it.
  const [pepeId, setPepeId] = useState(randomPepeId)

  const fire = (kind: FxKind, el: Element) => {
    const spec = TARGETS[kind]
    // The lab's claimPot plays the real claim path: the celebration, then the
    // victory modal with a receipt-style payout (demo round, no hash — nothing
    // to link to) and the wallet's identity pepe (no staker → no NFTs).
    if (kind === 'claimPot') {
      fireFx(kind, { anchor: el, target: spec?.target })
      victories.push({
        source: 'claim', roundId: 3n, roundName: 'the fx lab round', amountMix: 1234n * 10n ** 16n,
        message: pickVictoryMessage(), seats: 2, account: address ?? LAB_WALLET, delayMs: 900,
      })
      return
    }
    fireFx(kind, {
      anchor: el, target: spec?.target, detail: spec?.detail,
      pepe: kind === 'claimPredeposit' ? { id: pepeId, dnaVersion: LAB_DNA_VERSION, dna: dnaOfId(pepeId) } : undefined,
    })
  }

  // The settle path: an unclaimed claimablePot-style amount and a mock hand.
  const settleWin = (pepes: number) => victories.push({
    source: 'settle', roundId: 3n, roundName: 'the fx lab round', amountMix: 420_690n * 10n ** 13n,
    message: pickVictoryMessage(), seats: 3, account: address ?? LAB_WALLET, mockPepes: mockHand(pepes),
  })

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
          <button className="st-btn" onClick={() => settleWin(3)}>settle win · 3 pepes</button>
          <button className="st-btn" onClick={() => settleWin(8)}>settle win · 8 pepes</button>
          <button className="st-btn" onClick={() => victories.clear()}>clear victories</button>
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
                {LADDER_ART[i] !== undefined && <span className="ladder-art" dangerouslySetInnerHTML={{ __html: LADDER_ART[i] }} />}
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
