import { useEffect, useState } from 'react'
import { useAccount, useReadContracts, useWriteContract } from 'wagmi'
import { controllerAbi, erc20Abi, stakerAbi } from '../lib/abi'
import { useRound, useBalances } from '../lib/useRound'
import { fmtAmount, fmtCountdown, parseAmountToWad } from '../lib/format'
import PepePanel from './PepePanel'
import PepePicker from './PepePicker'

type Step = 'idle' | 'approve' | 'tx' | 'done'

export default function StakeCard() {
  const round = useRound()
  const { address, isConnected } = useAccount()
  const { psp: pspBal } = useBalances(round.token, round.mix)
  const [amount, setAmount] = useState('')
  const [step, setStep] = useState<Step>('idle')
  const [error, setError] = useState<string | null>(null)
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000))
  const [pepeKey, setPepeKey] = useState(0)
  const [pickedId, setPickedId] = useState<bigint | null>(null)
  const [pickerSeed, setPickerSeed] = useState(1)
  const { writeContractAsync } = useWriteContract()

  useEffect(() => {
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000)
    return () => clearInterval(t)
  }, [])

  const ZERO = '0x0000000000000000000000000000000000000000' as const
  const reads = useReadContracts({
    contracts: [
      { address: round.staker ?? ZERO, abi: stakerAbi, functionName: 'positions', args: [address ?? ZERO] },
      { address: round.staker ?? ZERO, abi: stakerAbi, functionName: 'pendingFeesOf', args: [address ?? ZERO] },
      { address: round.staker ?? ZERO, abi: stakerAbi, functionName: 'tokenOf', args: [address ?? ZERO] },
      { address: round.controller ?? ZERO, abi: controllerAbi, functionName: 'RELOCK_WINDOW' },
      { address: round.token ?? ZERO, abi: erc20Abi, functionName: 'allowance', args: [address ?? ZERO, round.staker ?? ZERO] },
    ],
    query: { enabled: !!address && !!round.staker && !!round.token, refetchInterval: 4000 },
  })

  const posArr = reads.data?.[0]?.result as [bigint, bigint, bigint, bigint] | undefined
  const pos = posArr
    ? { amount: posArr[0], rewardDebt: posArr[1], lockTime: posArr[2], unlockTime: posArr[3] }
    : undefined
  const pending = reads.data?.[1]?.result as bigint | undefined
  const tokenId = reads.data?.[2]?.result as bigint | undefined
  const relockWindow = reads.data?.[3]?.result as bigint | undefined
  const allowance = reads.data?.[4]?.result as bigint | undefined

  const hasPepe = tokenId !== undefined && tokenId > 0n

  const amountWad = parseAmountToWad(amount)
  const canExtend =
    !!pos &&
    pos.amount > 0n &&
    relockWindow !== undefined &&
    now >= Number(pos.unlockTime - relockWindow) &&
    now < Number(pos.unlockTime)
  const isFlat = round.flatTime !== undefined && round.flatTime > 0n
  const canUnlock =
    !!pos && pos.amount > 0n && (now >= Number(pos.unlockTime) || isFlat)

  async function run(fn: 'lock' | 'lockWithPepe' | 'relock' | 'unlock' | 'claimFees', needsApproval = false) {
    setError(null)
    try {
      if (needsApproval && round.token && round.staker && amountWad > 0n) {
        setStep('approve')
        await writeContractAsync({
          address: round.token,
          abi: erc20Abi,
          functionName: 'approve',
          args: [round.staker, amountWad],
        })
      }
      setStep('tx')
      await writeContractAsync({
        address: round.staker!,
        abi: stakerAbi,
        functionName: fn,
        ...(fn === 'lock'
          ? { args: [amountWad] }
          : fn === 'lockWithPepe'
            ? { args: [amountWad, pickedId!] }
            : {}),
      })
      setStep('done')
      setAmount('')
      setPickedId(null)
      setPepeKey((k) => k + 1)
      setTimeout(() => setStep('idle'), 2500)
    } catch (e) {
      setError(e instanceof Error ? e.message.slice(0, 140) : 'transaction failed')
      setStep('idle')
    }
  }

  const busy = step === 'approve' || step === 'tx'
  const approved = allowance !== undefined && amountWad > 0n && allowance >= amountWad
  // fresh-pepe path: chosen art required; amount 0 = hatch the pepe only
  const zeroHatch = amountWad === 0n && !hasPepe
  const canSubmit =
    isConnected &&
    !!round.staker &&
    !busy &&
    (!hasPepe ? pickedId !== null : true) &&
    (zeroHatch || (amountWad > 0n && (pspBal === undefined || amountWad <= pspBal)))

  const mainLabel = !isConnected
    ? 'connect wallet'
    : step === 'done'
      ? '✅ done'
      : step === 'approve'
        ? 'approving…'
        : busy
          ? 'confirm…'
          : !hasPepe
            ? zeroHatch
              ? '🐸 hatch this pepe (stake 0)'
              : approved
                ? 'stake with this pepe'
                : 'approve & stake'
            : approved
              ? 'stake'
              : 'approve & stake'

  const submitFn = hasPepe ? 'lock' : 'lockWithPepe'

  return (
    <div className="card p-5">
      <h2 className="text-lg font-black text-slate-900">💎 stake PSP</h2>
      <p className="text-xs text-slate-400">
        90-day lock · every trade fee flows to stakers · your pepe stays with you forever
      </p>

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
          <div className="text-xl font-black text-slate-900">{fmtAmount(pos?.amount)}</div>
        </div>
      </div>

      {pos && pos.amount > 0n && (
        <div className="mt-3 flex items-center justify-between rounded-2xl border border-emerald-100 bg-white px-4 py-2.5 text-sm">
          <span className="font-bold text-slate-500">
            {isFlat ? '🚨 lock force-opened' : canUnlock ? '🔓 unlocked' : '⏳ unlocks in'}
          </span>
          <span className="font-black text-psp-deep">
            {isFlat
              ? 'bomb opened all locks'
              : canUnlock
                ? 'withdraw anytime'
                : fmtCountdown(Number(pos.unlockTime) - now)}
          </span>
        </div>
      )}

      {isConnected && !hasPepe && (
        <div className="mt-3">
          <PepePicker
            round={round}
            selected={pickedId}
            onSelect={setPickedId}
            seed={pickerSeed}
            onReroll={() => setPickerSeed((s) => s + 1)}
          />
        </div>
      )}

      <div className="mt-3 rounded-2xl border border-sky-100 bg-sky-50/60 p-4">
        <div className="flex items-center justify-between text-xs font-bold text-slate-400">
          <span>stake amount</span>
          <span className="flex items-center gap-2">
            {!hasPepe && amountWad === 0n && <span className="text-emerald-500">0 = pepe only</span>}
            bal {fmtAmount(pspBal)}
          </span>
        </div>
        <div className="mt-2 flex gap-2">
          <input
            className="input-amount flex-1"
            placeholder={hasPepe ? '0.0' : '0.0 — or nothing, just the pepe'}
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
          disabled={!canSubmit}
          onClick={() => run(submitFn, !approved)}
        >
          {mainLabel}
        </button>
        {!hasPepe && pickedId === null && !busy && step !== 'done' && (
          <p className="mt-2 text-center text-xs font-bold text-slate-400">
            ↑ pick a pepe above to enable staking
          </p>
        )}
      </div>

      <div className="mt-3 flex flex-col gap-2 sm:flex-row">
        <button className="btn-ghost flex-1" disabled={!canExtend || busy} onClick={() => run('relock')}>
          🔄 extend +90d {canExtend ? '' : '(final week only)'}
        </button>
        <button className="btn-ghost flex-1" disabled={!canUnlock || busy} onClick={() => run('unlock')}>
          🔓 withdraw (keep pepe)
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
            disabled={!isConnected || !pending || pending === 0n || busy}
            onClick={() => run('claimFees')}
          >
            {step === 'done' ? '✅' : 'claim'}
          </button>
        </div>
      </div>

      {error && <div className="mt-2 break-words text-xs text-rose-500">{error}</div>}

      <div className="mt-4">
        <PepePanel round={round} refreshKey={pepeKey} />
      </div>
    </div>
  )
}
