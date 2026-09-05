import { fmtAmount, wadToExact } from '../lib/format'
import { parseTopUpAmount, type TopUpStep } from '../lib/stakeTopUp'

export default function PositionTopUp({ id, balance, value, open, busy, step, blockedReason, onValue, onToggle, onSubmit }: {
  id: bigint
  balance: bigint | undefined
  value: string
  open: boolean
  busy: boolean
  step: TopUpStep | undefined
  blockedReason: string | undefined
  onValue: (value: string) => void
  onToggle: () => void
  onSubmit: () => void
}) {
  const amount = parseTopUpAmount(value)
  const inputError = value.trim() && !amount
    ? 'Enter a positive amount with up to 18 decimal places.'
    : amount && balance !== undefined && amount > balance
      ? 'Not enough PSP in your wallet.'
      : undefined
  const inputId = `top-up-${id}`
  const label = step === 'checking' ? 'checking position…'
    : step === 'approve' ? 'approving PSP…'
      : step === 'stake' ? 'adding PSP…' : 'confirm add PSP'
  return (
    <div className="flex flex-col gap-2">
      <button className="st-btn text-xs" disabled={busy || !!blockedReason} onClick={onToggle}
        aria-expanded={open} aria-controls={`${inputId}-form`}>
        {open ? 'cancel top-up' : '+ add PSP'}
      </button>
      {blockedReason && <p className="text-[10px] text-text-lo">{blockedReason}</p>}
      {open && (
        <form id={`${inputId}-form`} className="flex flex-col gap-2 rounded-xl bg-bg-2 p-3"
          onSubmit={event => { event.preventDefault(); if (!busy && !blockedReason && amount && balance !== undefined && amount <= balance) onSubmit() }}>
          <label htmlFor={inputId} className="text-xs text-text-hi">add PSP to pepe #{id.toString()}</label>
          <p className="text-[10px] text-text-lo">Keeps this NFT and adds to its existing stake.</p>
          <div className="flex items-center justify-between text-[10px] text-text-lo">
            <span title={balance === undefined ? undefined : `${wadToExact(balance)} PSP`}>wallet: {fmtAmount(balance, 4)} PSP</span>
            <button type="button" className="font-semibold text-accent disabled:opacity-40" disabled={busy || !!blockedReason || balance === undefined || balance === 0n}
              onClick={() => onValue(wadToExact(balance))}>Max</button>
          </div>
          <input id={inputId} className="st-input !py-2 !text-sm" inputMode="decimal" autoComplete="off" placeholder="0.0 PSP"
            value={value} onChange={event => onValue(event.target.value)} disabled={busy || !!blockedReason}
            aria-invalid={!!inputError} aria-describedby={inputError ? `${inputId}-error` : undefined} />
          {inputError && <p id={`${inputId}-error`} className="text-[10px] text-phase-critical">{inputError}</p>}
          <button type="submit" className="st-btn st-btn-primary text-xs"
            disabled={busy || !!blockedReason || !amount || balance === undefined || amount > balance}>
            {label}
          </button>
          <p className="text-[10px] text-text-lo">Approve PSP if prompted, then confirm the top-up.</p>
        </form>
      )}
    </div>
  )
}
