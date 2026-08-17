import { useEffect, useMemo, useState } from 'react'
import { useAccount, useReadContracts, useWriteContract } from 'wagmi'
import { controllerAbi, erc20Abi } from '../lib/abi'
import { useRound, useBalances } from '../lib/useRound'
import { fmtAmount, fmtCountdown, parseAmountToWad } from '../lib/format'

type Step = 'idle' | 'approve' | 'tx' | 'waiting' | 'done'

export default function StakeCard() {
  const round = useRound()
  const { address, isConnected } = useAccount()
  const { psp: pspBal } = useBalances(round.token, round.mix)
  const [amount, setAmount] = useState('')
  const [step, setStep] = useState<Step>('idle')
  const [error, setError] = useState<string | null>(null)
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000))
  const { writeContractAsync } = useWriteContract()

  useEffect(() => {
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000)
    return () => clearInterval(t)
  }, [])

  const ZERO = '0x0000000000000000000000000000000000000000' as const
  const reads = useReadContracts({
    contracts: [
      { address: round.controller ?? ZERO, abi: controllerAbi, functionName: 'locks', args: [address ?? ZERO] },
      { address: round.controller ?? ZERO, abi: controllerAbi, functionName: 'accFeePerShareMixETH' },
      { address: round.controller ?? ZERO, abi: controllerAbi, functionName: 'RELOCK_WINDOW' },
      { address: round.token ?? ZERO, abi: erc20Abi, functionName: 'allowance', args: [address ?? ZERO, round.controller ?? ZERO] },
    ],
    query: { enabled: !!address && !!round.controller && !!round.token },
  })

  const lockArr = reads.data?.[0]?.result as [bigint, bigint, bigint, bigint] | undefined
  const lock = lockArr
    ? { amount: lockArr[0], rewardDebt: lockArr[1], lockTime: lockArr[2], unlockTime: lockArr[3] }
    : undefined
  const accPerShare = reads.data?.[1].result as bigint | undefined
  const relockWindow = reads.data?.[2].result as bigint | undefined
  const allowance = reads.data?.[3].result as bigint | undefined

  const pending = useMemo(() => {
    if (!lock || !accPerShare || lock.amount === 0n) return 0n
    const gross = (lock.amount * accPerShare) / 10n ** 18n
    return gross > lock.rewardDebt ? gross - lock.rewardDebt : 0n
  }, [lock, accPerShare])

  const amountWad = parseAmountToWad(amount)
  const canExtend =
    !!lock &&
    lock.amount > 0n &&
    relockWindow !== undefined &&
    now >= Number(lock.unlockTime - relockWindow) &&
    now < Number(lock.unlockTime)
  const isFlat = round.flatTime !== undefined && round.flatTime > 0n
  const canUnlock =
    !!lock && lock.amount > 0n && (now >= Number(lock.unlockTime) || isFlat)

  async function run(fn: 'lock' | 'relock' | 'unlock' | 'claimFees', needsApproval = false) {
    setError(null)
    try {
      if (needsApproval && round.token && round.controller) {
        setStep('approve')
        await writeContractAsync({
          address: round.token,
          abi: erc20Abi,
          functionName: 'approve',
          args: [round.controller, amountWad],
        })
      }
      setStep('tx')
      await writeContractAsync({
        address: round.controller!,
        abi: controllerAbi,
        functionName: fn,
        ...(fn === 'lock' ? { args: [amountWad] } : {}),
      })
      setStep('done')
      setAmount('')
      setTimeout(() => setStep('idle'), 2500)
    } catch (e) {
      setError(e instanceof Error ? e.message.slice(0, 140) : 'transaction failed')
      setStep('idle')
    }
  }

  const busy = step === 'approve' || step === 'tx' || step === 'waiting'
  const approved = allowance !== undefined && allowance >= amountWad && amountWad > 0n

  return (
    <div className="card p-5">
      <h2 className="text-lg font-black text-slate-900">💎 stake PSP</h2>
      <p className="text-xs text-slate-400">90-day lock · every trade fee flows to stakers</p>

      <div className="mt-4 grid grid-cols-2 gap-3">
        <div className="rounded-2xl bg-sky-50 p-3">
          <div className="text-[11px] font-black uppercase tracking-wide text-slate-400">
            your PSP
          </div>
          <div className="text-xl font-black text-slate-900">{fmtAmount(pspBal)}</div>
        </div>
        <div className="rounded-2xl bg-emerald-50 p-3">
          <div className="text-[11px] font-black uppercase tracking-wide text-slate-400">
            staked
          </div>
          <div className="text-xl font-black text-slate-900">{fmtAmount(lock?.amount)}</div>
        </div>
      </div>

      {lock && lock.amount > 0n && (
        <div className="mt-3 flex items-center justify-between rounded-2xl border border-emerald-100 bg-white px-4 py-2.5 text-sm">
          <span className="font-bold text-slate-500">
            {isFlat ? '🚨 lock force-opened' : canUnlock ? '🔓 unlocked' : '⏳ unlocks in'}
          </span>
          <span className="font-black text-psp-deep">
            {isFlat
              ? 'bomb opened all locks'
              : canUnlock
                ? 'withdraw anytime'
                : fmtCountdown(Number(lock.unlockTime) - now)}
          </span>
        </div>
      )}

      <div className="mt-3 rounded-2xl border border-sky-100 bg-sky-50/60 p-4">
        <div className="flex items-center justify-between text-xs font-bold text-slate-400">
          <span>stake amount</span>
          <span>bal {fmtAmount(pspBal)}</span>
        </div>
        <div className="mt-2 flex gap-2">
          <input
            className="input-amount flex-1"
            placeholder="0.0"
            value={amount}
            inputMode="decimal"
            onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ''))}
          />
          <button
            className="btn-ghost shrink-0"
            onClick={() => setAmount(pspBal ? (Number(pspBal) / 1e18).toString() : '0')}
          >
            max
          </button>
        </div>
        <button
          className="btn-primary mt-3 w-full"
          disabled={!isConnected || !amountWad || busy || (pspBal !== undefined && amountWad > pspBal)}
          onClick={() => run('lock', !approved)}
        >
          {step === 'done'
            ? '✅ staked'
            : step === 'approve'
              ? 'approving…'
              : busy
                ? 'confirm…'
                : approved
                  ? 'stake'
                  : 'approve & stake'}
        </button>
      </div>

      <div className="mt-3 flex flex-col gap-2 sm:flex-row">
        <button className="btn-ghost flex-1" disabled={!canExtend || busy} onClick={() => run('relock')}>
          🔄 extend +90d {canExtend ? '' : '(final week only)'}
        </button>
        <button className="btn-ghost flex-1" disabled={!canUnlock || busy} onClick={() => run('unlock')}>
          🔓 withdraw
        </button>
      </div>

      <div className="mt-4 rounded-2xl border border-emerald-100 bg-gradient-to-r from-emerald-50 to-sky-50 p-4">
        <div className="flex items-center justify-between">
          <div>
            <div className="text-[11px] font-black uppercase tracking-wide text-slate-400">
              staking rewards
            </div>
            <div className="text-xl font-black text-emerald-600">
              {fmtAmount(pending, 4)} <span className="text-sm">mixETH</span>
            </div>
          </div>
          <button
            className="btn-primary"
            disabled={!isConnected || pending === 0n || busy}
            onClick={() => run('claimFees')}
          >
            {step === 'done' ? '✅' : 'claim'}
          </button>
        </div>
      </div>

      {error && <div className="mt-2 break-words text-xs text-rose-500">{error}</div>}
    </div>
  )
}
