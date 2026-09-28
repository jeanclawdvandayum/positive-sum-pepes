import type { ReactNode } from 'react'
import { FlipClock, clockText } from './AltCommon'
import { useNow } from '../phase/PhaseEngine'
import { renderPepeSvg } from '../lib/pepeRender'
import { dnaOfId } from '../components/PepePicker'
import { fmtAmount, fmtPepeId, parseAmountToWad, wadToExact } from '../lib/format'
import { predepositLimit } from '../lib/predeposit'
import type { PredepositEntry } from '../lib/chainResults'
import type { PredepositStateView, ControllerFacts } from '../lib/predepositState'


/** The refined IBCO page (mock "F/G · IBCO (predeposit)"): hero band with
 *  the flip clock in the clockbox, the POOL card (fill bar + stats), the
 *  suspect lineup with a picked-suspect plate, and the deposit slip.
 *  Everything renders from the same model Predeposit.tsx already computes —
 *  this view is alt-only presentation. */

export interface AltIbcoModel {
  state: PredepositStateView | undefined
  facts: ControllerFacts | undefined
  /** phase: 0 green, 1 open, 2 over (derived; legacy = 1/2) */
  phaseNow: 0 | 1 | 2 | undefined
  greenEnd: bigint | undefined
  openEnd: bigint | undefined
  depositors: bigint | undefined
  myDep: PredepositEntry | undefined
  minimum: bigint
  roundId: bigint
  roundName: string
  walletCap: bigint | undefined
  mixBalance: bigint | undefined
  greenMember: boolean | undefined
  connected: boolean
  artVersion: bigint
  /** the current reservation or selection */
  pickedId: bigint | null
  reservedId: bigint | undefined
  /** the PepePicker (all candidate/availability logic stays there) */
  picker: ReactNode
  amount: string
  onAmount: (v: string) => void
  onMax: () => void
  canSubmit: boolean
  busy: boolean
  stepLabel: string
  onSubmit: () => void
  error: string | null
  launched: boolean
  onLaunch: (() => void) | undefined
  launchable: boolean
}

export default function AltIbcoView(m: AltIbcoModel) {
  const now = useNow()
  const deadline = m.phaseNow === 0 ? m.greenEnd : m.openEnd
  const remaining = deadline !== undefined ? Math.max(0, Number(deadline) - now) : undefined
  const cap = m.state?.cap ?? 1000n * 10n ** 18n
  const total = m.state?.total ?? 0n
  const fillPct = cap > 0n ? Math.min(100, Number((total * 10_000n) / cap) / 100) : 0
  const green = m.phaseNow === 0
  const maxDeposit = m.mixBalance !== undefined && m.state
    ? predepositLimit(m.mixBalance, m.state.total, m.state.cap, m.walletCap ?? 0n, m.myDep?.mixETHAmount ?? 0n, m.facts?.rules)
    : undefined
  return <div className="alt-ibco">
    <section className="ibco-hero">
      <p className="small-heading">{green ? 'the greenlist is open.' : m.phaseNow === 1 ? 'the opening is public.' : 'the window is closed.'}</p>
      <h1>{green ? 'greenlisted frogs go first.' : m.phaseNow === 1 ? 'get in on the ground floor.' : 'the first buy is pooled.'}</h1>
      <div className="clockbox">
        <div className="clockbox-strip" aria-hidden="true">
          <span>{green ? 'GREENLIST · WINDOW CLOSES IN' : 'IBCO · WINDOW CLOSES IN'}</span>
          <span>{clockText(Number(m.facts?.greenSec ?? m.facts?.openSec ?? m.facts?.legacySec ?? 0n))} WINDOW</span>
        </div>
        <FlipClock text={deadline === undefined ? '--:--:--' : clockText(remaining ?? 0)} />
      </div>
      <p className="ibco-lead">choose your pepe. join the pooled first buy.</p>
    </section>

    <div className="ibco-grid">
      <section className="ibco-pool card" aria-label="the pool">
        <div className="pool-tag">
          <span className="pool-label">THE POOL</span>
          <span className="pool-round">{m.roundName || `round ${m.roundId.toString()}`}</span>
        </div>
        <div className="pool-body">
          <div className="pool-fill-head">
            <span>{m.state && m.facts?.rules === 3n ? 'WINDOW FILL' : 'POOLED BUY-IN'}</span>
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
              <strong>{green ? `${fmtAmount(m.state?.greenPerWallet ?? 0n, 0)} cap` : '1 price'}</strong>
              <span>{green ? 'PER WALLET' : 'FOR EVERY FROG'}</span>
            </div>
          </div>
          <div className="pool-steps" aria-hidden="true">
            <span className="pool-step done">✓ pick a suspect</span>
            <span className={`pool-step ${m.amount ? 'now' : ''}`}>{m.pickedId !== null || m.reservedId ? '✓' : '2'} commit mixETH</span>
            <span className="pool-step">3 claim lePSP</span>
          </div>
        </div>
      </section>

      <section className="ibco-suspects card" aria-label="choose your accomplice">
        {m.picker}
      </section>

      <section className="ibco-slip card" aria-label="deposit slip">
        <div className="slip-head">
          <h2>deposit slip</h2>
          <span className="slip-status">{m.launched ? 'WINDOW CLOSED' : green ? 'GREENLIST PHASE' : 'OPEN PHASE'}</span>
        </div>
        <div className="slip-picked">
          {m.reservedId !== undefined && m.reservedId > 0n
            ? <><span className="slip-face" dangerouslySetInnerHTML={{ __html: renderPepeSvg(dnaOfId(m.reservedId), m.artVersion) }} />
               <div><strong>pepe #{fmtPepeId(m.reservedId)} reserved</strong><span>further deposits join this pepe</span></div></>
            : m.pickedId !== null
              ? <><span className="slip-face" dangerouslySetInnerHTML={{ __html: renderPepeSvg(dnaOfId(m.pickedId), m.artVersion) }} />
                 <div><strong>suspect #{fmtPepeId(m.pickedId)}</strong><span>commits with your deposit</span></div></>
              : <><span className="slip-face empty">?</span>
                 <div><strong>no suspect picked</strong><span>pick a face above first</span></div></>}
        </div>
        <label className="input-label" htmlFor="ibco-amount">commit mixETH</label>
        <div className="slip-amount">
          <input id="ibco-amount" inputMode="decimal" autoComplete="off" value={m.amount} disabled={m.busy || m.launched}
            onChange={e => m.onAmount(e.target.value.replace(/[^0-9.]/g, ''))} />
          <button type="button" className="st-btn" disabled={m.busy || maxDeposit === undefined || maxDeposit <= 0n}
            onClick={m.onMax}>max {maxDeposit !== undefined ? fmtAmount(maxDeposit, 2) : '…'}</button>
        </div>
        <input className="slip-range" type="range" min="0" max="100" value={maxDeposit && parseAmountToWad(m.amount) > 0n ? Math.min(100, Number((parseAmountToWad(m.amount) * 100n) / maxDeposit)) : 0}
          disabled={m.busy || m.launched} onChange={e => { const v = Number(e.target.value); if (maxDeposit) m.onAmount(wadToExact(maxDeposit * BigInt(v) / 100n)) }}
          aria-label="share of your available deposit" />
        {m.error && <p className="slip-error" role="alert">{m.error}</p>}
        {m.launchable && !m.launched && m.launchable && <button type="button" className="btn" onClick={m.onLaunch}>launch the pooled buy ↗</button>}
        <button type="button" className="btn slip-submit" disabled={!m.canSubmit} onClick={m.onSubmit}>
          {m.busy ? 'confirm in wallet…' : m.stepLabel}
        </button>
        <p className="slip-note">claim lePSP after launch · same price for all</p>
      </section>
    </div>
  </div>
}
