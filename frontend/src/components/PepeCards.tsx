import { useEffect, useMemo, useState } from 'react'
import { useAccount, useWriteContract } from 'wagmi'
import { ADDRESSES, REINVEST_ENABLED } from '../lib/config'
import { stakerAbi, reinvestorAbi, buildPoolKey } from '../lib/abi'
import { fmtAmount, fmtCountdown } from '../lib/format'
import { renderPepeSvg } from '../lib/pepeRender'
import { dnaOfId } from './PepePicker'
import MixLogo from './MixLogo'
import type { RoundInfo } from '../lib/useRound'
import { useEthUsd } from '../lib/useEthUsd'

/// One card per staked pepe. Rows: art · amount + value · unlock state ·
/// [cancel-request|withdraw] · [claim – X mixETH] [reinvest].

export interface PepeEntry {
  id: bigint
  amount: bigint
  requestTime: bigint
}

type CardStep = 'idle' | 'tx' | 'done'

function Art({ id }: { id: bigint }) {
  const svg = useMemo(() => renderPepeSvg(dnaOfId(id)), [id])
  return (
    <div
      className="flex h-32 items-center justify-center rounded-2xl bg-gradient-to-b from-sky-50 to-emerald-50 dark:from-slate-800 dark:to-slate-900 [&>svg]:h-28 [&>svg]:w-28"
      dangerouslySetInnerHTML={{ __html: svg }}
    />
  )
}

export function PepeCard({
  round,
  entry,
  vest,
  pending,
  isFlat,
  approved,
  onDone,
}: {
  round: RoundInfo
  entry: PepeEntry
  vest: bigint | undefined
  pending: bigint | undefined
  isFlat: boolean
  approved: boolean | undefined
  onDone: () => void
}) {
  const { isConnected } = useAccount()
  const { writeContractAsync } = useWriteContract()
  const ethUsd = useEthUsd()
  const [step, setStep] = useState<CardStep>('idle')
  const [error, setError] = useState<string | null>(null)
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000))

  useEffect(() => {
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000)
    return () => clearInterval(t)
  }, [])

  const { id, amount, requestTime } = entry
  const decaying = requestTime > 0n
  const vestEnd = requestTime > 0n && vest ? Number(requestTime + vest) : undefined
  const decayed = vestEnd !== undefined && now >= vestEnd
  const elapsed = vest ? requestTime > 0n ? BigInt(now) - requestTime : 0n : 0n
  const powerLeft =
    !decaying || !vest
      ? undefined
      : elapsed >= vest
        ? 0
        : Number((amount - (amount * elapsed) / vest) * 10000n / amount) / 100

  const valueMix = round.marginalPrice ? (amount * round.marginalPrice) / 10n ** 18n : undefined
  const valueUsd = valueMix !== undefined && ethUsd ? (Number(valueMix) / 1e18) * ethUsd : undefined

  const busy = step === 'tx'
  const canWithdraw = amount > 0n && (isFlat || decayed)
  const canCancel = decaying && amount > 0n
  const canRequest = !decaying && amount > 0n && !isFlat
  const canClaim = isConnected && pending !== undefined && pending > 0n
  const canReinvest = canClaim && !decaying && REINVEST_ENABLED && !isFlat

  async function act(fn: 'requestWithdraw' | 'cancelWithdraw' | 'withdraw' | 'claimFees') {
    setError(null)
    try {
      setStep('tx')
      await writeContractAsync({ address: round.staker!, abi: stakerAbi, functionName: fn, args: [id] })
      setStep('done')
      onDone()
      setTimeout(() => setStep('idle'), 2500)
    } catch (e) {
      setError(e instanceof Error ? e.message.slice(0, 120) : 'tx failed')
      setStep('idle')
    }
  }

  async function reinvest() {
    setError(null)
    try {
      if (!approved) {
        setStep('tx')
        await writeContractAsync({
          address: round.staker!,
          abi: stakerAbi,
          functionName: 'setApprovalForAll',
          args: [ADDRESSES.reinvestor, true],
        })
      }
      setStep('tx')
      const key = buildPoolKey(round.mix!, round.token!, round.hook!)
      await writeContractAsync({
        address: ADDRESSES.reinvestor,
        abi: reinvestorAbi,
        functionName: 'reinvest',
        args: [id, key, 0n, 0n],
      })
      setStep('done')
      onDone()
      setTimeout(() => setStep('idle'), 2500)
    } catch (e) {
      setError(e instanceof Error ? e.message.slice(0, 120) : 'tx failed')
      setStep('idle')
    }
  }

  const dateStr = (ts: number) => new Date(ts * 1000).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' })

  return (
    <div className="card flex flex-col gap-3 p-4">
      <div className="flex items-center justify-between">
        <span className="text-xs font-black uppercase tracking-wide text-slate-400">pepe #{id.toString()}</span>
        {amount === 0n && <span className="badge-ghost text-[10px]">unstaked pepe</span>}
        {decaying && !decayed && (
          <span className="text-[10px] font-black text-amber-600">{powerLeft !== undefined ? `${powerLeft}% power` : 'decaying'}</span>
        )}
        {decayed && <span className="text-[10px] font-black text-emerald-600">fully unlocked</span>}
      </div>

      <Art id={id} />

      <div className="grid grid-cols-2 gap-2 text-sm">
        <div>
          <div className="text-[10px] font-black uppercase tracking-wide text-slate-400">staked</div>
          <div className="font-black text-slate-900 dark:text-slate-100">{fmtAmount(amount)}</div>
        </div>
        <div className="text-right">
          <div className="text-[10px] font-black uppercase tracking-wide text-slate-400">value</div>
          <div className="font-black text-slate-900 dark:text-slate-100">
            {valueMix !== undefined ? (
              <>
                ≈{fmtAmount(valueMix, 4)} <MixLogo />
              </>
            ) : (
              '—'
            )}
          </div>
          {valueUsd !== undefined && (
            <div className="text-[10px] font-bold text-slate-400">≈ ${valueUsd < 1 ? valueUsd.toFixed(4) : valueUsd.toFixed(2)}</div>
          )}
        </div>
      </div>

      <div className="flex items-center justify-between rounded-xl bg-slate-50 dark:bg-slate-800/60 px-3 py-2 text-xs">
        <span className="font-bold text-slate-500">
          {isFlat ? '🚨 bomb opened all locks' : decaying ? (decayed ? 'unlocked' : 'unlocks (vesting)') : 'indefinite lock'}
        </span>
        <span className="font-black text-psp-deep dark:text-sky-300">
          {isFlat
            ? 'withdraw anytime'
            : decaying
              ? decayed
                ? 'withdraw anytime'
                : vestEnd
                  ? `${fmtCountdown(vestEnd - now)} · ${dateStr(vestEnd)}`
                  : '…'
              : 'no expiry — request to exit'}
        </span>
      </div>

      <div className="grid grid-cols-2 gap-2">
        <button
          className="btn-ghost text-xs"
          disabled={busy || (decaying ? !canCancel : !canRequest)}
          onClick={() => act(decaying ? 'cancelWithdraw' : 'requestWithdraw')}
          title={decaying ? 'stop the decay, restore full power' : 'start the 6-week exit ramp'}
        >
          {decaying ? '↩ keep staking' : '⛏ request withdraw'}
        </button>
        <button
          className="btn-ghost text-xs"
          disabled={busy || !canWithdraw}
          onClick={() => act('withdraw')}
          title={decaying ? (decayed || isFlat ? 'withdraw principal' : 'withdrawable after the vest') : 'request a withdraw first'}
        >
          <span className={canWithdraw ? '' : 'opacity-50'}>withdraw</span>
        </button>
      </div>

      <div className="grid grid-cols-2 gap-2">
        <button className="btn-primary text-xs" disabled={busy || !canClaim} onClick={() => act('claimFees')}>
          {step === 'done' ? '✅ claimed' : `claim — ${fmtAmount(pending, 4) || '0'} mixETH`}
        </button>
        {REINVEST_ENABLED && (
          <button className="btn-ghost text-xs" disabled={busy || !canReinvest} onClick={reinvest}>
            {step === 'done' ? '✅' : busy ? 'confirm…' : approved ? '↻ reinvest' : 'approve & reinvest'}
          </button>
        )}
      </div>

      {error && <div className="break-words text-[10px] text-rose-500">{error}</div>}
    </div>
  )
}

export default function PepeCards({
  round,
  entries,
  pendings,
  vest,
  approved,
  onDone,
}: {
  round: RoundInfo
  entries: PepeEntry[]
  pendings: Map<bigint, bigint | undefined>
  vest: bigint | undefined
  approved: boolean | undefined
  onDone: () => void
}) {
  const isFlat = round.flatTime !== undefined && round.flatTime > 0n
  return (
    <div className="grid gap-3 sm:grid-cols-2">
      {entries.map((e) => (
        <PepeCard
          key={e.id.toString()}
          round={round}
          entry={e}
          vest={vest}
          pending={pendings.get(e.id)}
          isFlat={isFlat}
          approved={approved}
          onDone={onDone}
        />
      ))}
    </div>
  )
}
