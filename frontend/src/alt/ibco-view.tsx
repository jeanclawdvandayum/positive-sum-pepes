import type { ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { FlipClock, clockText, FaucetDripButton } from './AltCommon'
import { useNow } from '../phase/PhaseEngine'
import { renderPepeSvg } from '../lib/pepeRender'
import { dnaOfId } from '../components/PepePicker'
import { fmtAmount, fmtPepeId, wadToExact } from '../lib/format'
import type { PredepositEntry } from '../lib/chainResults'
import type { PredepositStateView, ControllerFacts } from '../lib/predepositState'

/** The refined IBCO page (mocks 5/11 "IBCO (predeposit)"), purely
 *  presentational: every number arrives computed from Predeposit.tsx —
 *  this view never re-derives limits or deadlines. Sections: hero with the
 *  flip-clock clockbox → the wide POOL strip → the predeposit steps row →
 *  the suspect lineup (the real pepe picker) → deposit slip + pool receipt. */

export interface AltIbcoModel {
  state: PredepositStateView | undefined
  facts: ControllerFacts | undefined
  phaseNow: 0 | 1 | 2 | undefined
  greenEnd: bigint | undefined
  openEnd: bigint | undefined
  depositors: bigint | undefined
  myDep: PredepositEntry | undefined
  roundId: bigint
  walletCap: bigint | undefined
  mixBalance: bigint | undefined
  connected: boolean
  /** the staker's PEPE_DNA_VERSION — art renders in THIS release */
  dnaVersion: bigint
  pickedId: bigint | null
  reservedId: bigint | undefined
  picker: ReactNode
  amount: string
  amountWad: bigint
  onAmount: (v: string) => void
  /** computed by Predeposit.tsx (phase-aware, loaded-account checked) */
  maxDeposit: bigint | undefined
  canSubmit: boolean
  busy: boolean
  stepLabel: string
  onSubmit: () => void
  error: string | null
  launched: boolean
  onLaunch: (() => void) | undefined
  launchable: boolean
  myClaimed: boolean | undefined
}

const POT_BPS = 1000n // 10% of the pool seeds the countdown pot

export default function AltIbcoView(m: AltIbcoModel) {
  const now = useNow()
  const deadline = m.phaseNow === 0 ? m.greenEnd : m.openEnd
  const remaining = deadline !== undefined ? Math.max(0, Number(deadline) - now) : undefined
  const cap = m.state?.cap ?? 1000n * 10n ** 18n
  const total = m.state?.total ?? 0n
  const fillPct = cap > 0n ? Math.min(100, Number((total * 10_000n) / cap) / 100) : 0
  const green = m.phaseNow === 0
  const windowSec = m.facts?.greenSec ?? m.facts?.openSec ?? m.facts?.legacySec ?? 0n
  const picked = m.reservedId && m.reservedId > 0n ? m.reservedId : m.pickedId
  // "your share if it fills" = this wallet's ownership when the pool reaches
  // the cap — prior deposits + this commit over CAP (mock: 250/1000 = 25%),
  // never the immediate pool fraction.
  const ownedIfFilled = (m.myDep?.mixETHAmount ?? 0n) + m.amountWad
  const sharePct = cap > 0n
    ? Math.min(100, Number((ownedIfFilled * 100_000n) / cap) / 1000)
    : 0
  const potCut = m.amountWad * POT_BPS / 10_000n
  const curveCut = m.amountWad - potCut
  const amt = m.amountWad > 0n ? wadToExact(m.amountWad) : null
  const steps = [
    { done: picked != null, n: '1', t: 'pick a suspect', b: 'the pepe you’ll mint' },
    { done: m.canSubmit || m.busy, n: '2', t: 'commit mixETH', b: 'before the window closes' },
    { done: false, n: '3', t: 'claim lePSP', b: 'after launch · same price for all' },
  ]

  return <div className="alt-ibco">
    {/* ── hero ─────────────────────────────────────────────────────────── */}
    <section className="ibco-hero">
      <p className="small-heading">{green ? 'the greenlist is open.' : m.launched ? 'the window is closed.' : 'the opening is public.'}</p>
      <h1>{green ? 'greenlisted frogs go first.' : m.launched ? 'the first buy is pooled.' : 'get in on the ground floor.'}</h1>
      {m.launched ? (
        m.myClaimed === false && m.myDep && m.myDep.mixETHAmount > 0n
          ? <Link className="btn" to="/stake">claim your lePSP in the stake room ↗</Link>
          : <p className="ibco-lead">the pooled buy flew. claim lePSP from the stake room whenever you like.</p>
      ) : (
        <div className="clockbox">
          <div className="clockbox-strip" aria-hidden="true">
            <span>{green ? 'GREENLIST · WINDOW CLOSES IN' : 'IBCO · WINDOW CLOSES IN'}</span>
            <span>{clockText(Number(windowSec))} WINDOW</span>
          </div>
          <FlipClock text={deadline === undefined ? '--:--:--' : clockText(remaining ?? 0)} />
        </div>
      )}
      <p className="ibco-lead">choose your pepe. join the pooled first buy.</p>
    </section>

    {/* ── the pool strip ───────────────────────────────────────────────── */}
    <section className="ibco-pool" aria-label="the pool">
      <div className="pool-tag">
        <span className="pool-label">THE POOL</span>
        <span className="pool-round">round {m.roundId.toString()}</span>
      </div>
      <div className="pool-body">
        <div className="pool-fill-head">
          <span>WINDOW FILL</span>
          <span>{fmtAmount(total, 0)} / {fmtAmount(cap, 0)} MIXETH</span>
        </div>
        <div className="pool-bar" role="progressbar" aria-valuenow={fillPct} aria-valuemin={0} aria-valuemax={100}>
          <span style={{ width: `${fillPct}%` }} />
        </div>
        <p className="pool-note">{cap - total > 0n ? `${fmtAmount(cap - total, 0)} mixETH remaining` : 'pool full — launch is open'}</p>
        <div className="pool-stats">
          <div className="pool-stat">
            <strong>{m.depositors !== undefined ? m.depositors.toString() : '—'}</strong>
            <span>DEPOSITORS</span>
          </div>
          <div className="pool-stat">
            <strong>{!m.connected ? '—' : m.myDep === undefined ? '…' : wadToExact(m.myDep.mixETHAmount)}</strong>
            <span>YOUR PREDEPOSIT</span>
          </div>
          <div className="pool-stat">
            <strong>1 price</strong>
            <span>FOR EVERY FROG</span>
          </div>
        </div>
      </div>
    </section>

    {/* ── steps row ─────────────────────────────────────────────────────── */}
    <section className="ibco-steps">
      <h2>predeposit</h2>
      <div className="steps-grid">
        {steps.map(s => (
          <div key={s.n} className="step">
            <span className={`step-dot ${s.done ? 'done' : ''}`} aria-hidden="true">{s.done ? '✓' : s.n}</span>
            <div><strong>{s.t}</strong><span>{s.b}</span></div>
          </div>
        ))}
      </div>
    </section>

    {/* ── suspects ──────────────────────────────────────────────────────── */}
    <section className="ibco-suspects card" aria-label="choose your accomplice">
      {m.picker}
    </section>

    {/* ── slip + receipt ────────────────────────────────────────────────── */}
    <div className="ibco-bottom">
      <section className="ibco-slip card" aria-label="deposit slip">
        <div className="slip-grid">
          <div className="slip-tile">
            {picked != null
              ? <><span className="slip-face" dangerouslySetInnerHTML={{ __html: renderPepeSvg(dnaOfId(picked), m.dnaVersion) }} />
                 <div className="slip-tile-cap"><span>suspect #{fmtPepeId(picked)}</span><span className="dim">1 of 191,664,000 faces</span></div>
                 <span className="slip-stamp" aria-hidden="true">BOOKED</span></>
              : <><span className="slip-face empty">?</span>
                 <div className="slip-tile-cap"><span>no suspect</span><span className="dim">pick a face first</span></div></>}
          </div>
          <div className="slip-form">
            <div className="slip-head">
              <h2>deposit slip</h2>
              <span className="slip-chip">◎ mixETH</span>
            </div>
            {!m.launched && <>
              <div className="slip-commit-row">
                <label className="input-label" htmlFor="ibco-amount">commit</label>
                <button type="button" className="st-btn slip-max" disabled={m.busy || !m.maxDeposit || m.maxDeposit <= 0n}
                  onClick={() => m.maxDeposit !== undefined && m.onAmount(wadToExact(m.maxDeposit))}>
                  balance {m.mixBalance !== undefined ? fmtAmount(m.mixBalance, 2) : '…'} · max
                </button>
              </div>
              <div className="slip-amount">
                <input id="ibco-amount" inputMode="decimal" autoComplete="off" value={m.amount} disabled={m.busy}
                  onChange={e => m.onAmount(e.target.value.replace(/[^0-9.]/g, ''))} />
                <span className="slip-unit">mixETH</span>
              </div>
              <div className="slip-range">
                <output>{m.maxDeposit && m.amountWad > 0n ? Number((m.amountWad * 100n) / m.maxDeposit) : 0}%</output>
                <input type="range" min="0" max="100" step="1" aria-label="share of your available deposit"
                  value={m.maxDeposit && m.amountWad > 0n ? Math.min(100, Number((m.amountWad * 100n) / m.maxDeposit)) : 0}
                  disabled={m.busy || !m.maxDeposit || m.maxDeposit <= 0n}
                  onChange={e => m.maxDeposit !== undefined && m.onAmount(wadToExact(m.maxDeposit * BigInt(e.target.value) / 100n))} />
                <div className="range-ends"><span>0%</span><span>100% · capped by what’s left in the window</span></div>
              </div>
              {m.error && <p className="slip-error" role="alert">{m.error}</p>}
              {m.launchable && m.onLaunch && <button type="button" className="btn slip-launch" onClick={m.onLaunch}>launch the pooled buy ↗</button>}
              <button type="button" className="btn slip-submit" disabled={!m.canSubmit} onClick={m.onSubmit}>
                {m.busy ? 'confirm in wallet…'
                  // decorative wording ONLY in the valid ready state; every
                  // blocking/approval state keeps its authoritative label
                  : m.canSubmit && picked != null && amt
                    ? `commit ${wadToExact(m.amountWad)} mixETH · book suspect #${fmtPepeId(picked)}`
                    : m.stepLabel}
              </button>
              <div className="slip-frog-money">
                <span>✂ short on frog money?</span>
                <span className="frog-actions">
                  <FaucetDripButton className="st-btn" />
                  <a href="https://www.coinbase.com/faucets/base-ethereum-sepolia-faucet" target="_blank" rel="noreferrer">get base sepolia ETH ↗</a>
                </span>
              </div>
            </>}
            {m.launched && <p className="slip-launched">this window is closed. new deposits join the next round.</p>}
          </div>
        </div>
      </section>

      <section className="ibco-receipt" aria-label="pool receipt">
        <div className="receipt-paper">
          <span className="receipt-title">pool receipt</span>
          <span className="receipt-sub">round {m.roundId.toString()} · preview · {m.myDep?.claimed ? 'claimed' : 'not yet committed'}</span>
          <span className="receipt-rule" aria-hidden="true" />
          <div className="receipt-row"><span>you commit</span><span>{amt ? wadToExact(m.amountWad) : '0.0'}</span></div>
          <div className="receipt-row fee"><span>→ countdown pot 10%</span><span>{amt ? wadToExact(potCut) : '0.0'}</span></div>
          <div className="receipt-row fee"><span>→ first buy on curve 90%</span><span>{amt ? wadToExact(curveCut) : '0.0'}</span></div>
          <span className="receipt-rule" aria-hidden="true" />
          <div className="receipt-row"><span>your share if it fills</span><span>{sharePct.toFixed(1)}%</span></div>
          <div className="receipt-row"><span>price vs. other frogs</span><span>identical</span></div>
          <div className="receipt-row"><span>arrives as</span><span>{picked != null ? `lePSP in suspect #${fmtPepeId(picked)}` : 'lePSP'}</span></div>
          <div className="receipt-row"><span>claim</span><span>after launch</span></div>
          <p className="receipt-note">lePSP is locked earning PSP, held in a pepe NFT.</p>
        </div>
        <div className="receipt-teeth" aria-hidden="true" />
      </section>
    </div>
  </div>
}
