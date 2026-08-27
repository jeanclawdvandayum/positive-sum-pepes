import { useEffect, useMemo, useState } from 'react'
import { useAccount, useReadContracts, useWriteContract } from 'wagmi'
import { parseEther } from 'viem'
import { ADDRESSES, FAUCET_ENABLED, REINVEST_ENABLED } from '../lib/config'
import { controllerAbi, erc20Abi, faucetAbi, stakerAbi, reinvestorAbi, buildPoolKey } from '../lib/abi'
import { useRound, useBalances } from '../lib/useRound'
import { fmtAmount, parseAmountToWad } from '../lib/format'
import MixLogo from './MixLogo'
import PepePanel from './PepePanel'
import PepePicker from './PepePicker'
import PepeCards, { type PepeEntry } from './PepeCards'
import { PspIcon } from './TokenIcon'
import { useEthUsd } from '../lib/useEthUsd'

type Step = 'idle' | 'approve' | 'tx' | 'done'

export default function StakeCard() {
  const round = useRound()
  const { address, isConnected } = useAccount()
  const { psp: pspBal } = useBalances(round.token, round.mix)
  const [amount, setAmount] = useState('')
  const [step, setStep] = useState<Step>('idle')
  const [error, setError] = useState<string | null>(null)
  const [pepeKey, setPepeKey] = useState(0)
  const [pickedId, setPickedId] = useState<bigint | null>(null)
  const [pickerSeed, setPickerSeed] = useState(1)
  const [multiStep, setMultiStep] = useState<'idle' | 'tx' | 'done'>('idle')
  const { writeContractAsync } = useWriteContract()
  const ethUsd = useEthUsd()

  useEffect(() => {
    const t = setInterval(() => setPepeKey((k) => k), 4000) // re-render cadence for countdowns
    return () => clearInterval(t)
  }, [])

  const ZERO = '0x0000000000000000000000000000000000000000' as const
  const baseReads = useReadContracts({
    contracts: [
      { address: round.staker ?? ZERO, abi: stakerAbi, functionName: 'balanceOf', args: [address ?? ZERO] },
      { address: round.controller ?? ZERO, abi: controllerAbi, functionName: 'VEST_DURATION' },
      { address: round.token ?? ZERO, abi: erc20Abi, functionName: 'allowance', args: [address ?? ZERO, round.staker ?? ZERO] },
    ],
    query: { enabled: !!address && !!round.staker && !!round.token, refetchInterval: 6000 },
  })
  const apprReads = useReadContracts({
    contracts: [
      { address: round.staker ?? ZERO, abi: stakerAbi, functionName: 'isApprovedForAll', args: [address ?? ZERO, ADDRESSES.reinvestor] },
    ],
    query: { enabled: REINVEST_ENABLED && !!address && !!round.staker, refetchInterval: 6000 },
  })

  const count = baseReads.data?.[0]?.result as bigint | undefined
  const vest = baseReads.data?.[1]?.result as bigint | undefined
  const allowance = baseReads.data?.[2]?.result as bigint | undefined
  const reinvestApproved = REINVEST_ENABLED ? (apprReads.data?.[0]?.result as boolean | undefined) : undefined

  const n = count !== undefined ? Number(count) : 0

  // per-pepe reads: ids, positions, pendings
  const idReads = useReadContracts({
    contracts: Array.from({ length: n }, (_, i) => ({
      address: round.staker ?? ZERO,
      abi: stakerAbi,
      functionName: 'tokenOfOwnerByIndex' as const,
      args: [address ?? ZERO, BigInt(i)] as const,
    })),
    query: { enabled: !!address && n > 0, refetchInterval: 6000 },
  })
  const ids = useMemo(
    () => (idReads.data ?? []).map((r) => r.result as bigint | undefined).filter((x): x is bigint => x !== undefined),
    [idReads.data],
  )

  const detailReads = useReadContracts({
    contracts: ids.flatMap((id) => [
      { address: round.staker ?? ZERO, abi: stakerAbi, functionName: 'positions', args: [id] },
      { address: round.staker ?? ZERO, abi: stakerAbi, functionName: 'pendingFeesOf', args: [id] },
    ]),
    query: { enabled: ids.length > 0, refetchInterval: 6000 },
  })

  const entries: PepeEntry[] = useMemo(() => {
    const out: PepeEntry[] = []
    for (let i = 0; i < ids.length; i++) {
      const pos = detailReads.data?.[i * 2]?.result as [bigint, bigint, bigint, bigint, bigint] | undefined
      if (!pos) continue
      out.push({ id: ids[i], amount: pos[0], requestTime: pos[2] })
    }
    return out
  }, [ids, detailReads.data])

  const pendings = useMemo(() => {
    const m = new Map<bigint, bigint | undefined>()
    ids.forEach((id, i) => {
      m.set(id, detailReads.data?.[i * 2 + 1]?.result as bigint | undefined)
    })
    return m
  }, [ids, detailReads.data])

  const totalStaked = entries.reduce((a, e) => a + e.amount, 0n)
  const totalValueMix = round.marginalPrice ? (totalStaked * round.marginalPrice) / 10n ** 18n : undefined
  const totalValueUsd = totalValueMix !== undefined && ethUsd ? (Number(totalValueMix) / 1e18) * ethUsd : undefined
  const totalPending = [...pendings.values()].reduce<bigint>((a, p) => a + (p ?? 0n), 0n)
  const stakeableIds = entries.filter((e) => e.requestTime === 0n && e.amount > 0n).map((e) => e.id)

  const refresh = () => setPepeKey((k) => k + 1)

  const amountWad = parseAmountToWad(amount)
  const busy = step === 'approve' || step === 'tx'
  const approved = allowance !== undefined && amountWad > 0n && allowance >= amountWad
  const hasPepes = entries.length > 0
  const zeroHatch = amountWad === 0n && !hasPepes
  const canSubmit =
    isConnected && !!round.staker && !busy && (!hasPepes ? pickedId !== null : true) && (zeroHatch || (amountWad > 0n && (pspBal === undefined || amountWad <= pspBal)))

  const mainLabel = !isConnected
    ? 'connect wallet'
    : step === 'done'
      ? '✅ done'
      : step === 'approve'
        ? 'approving…'
        : busy
          ? 'confirm…'
          : !hasPepes
            ? zeroHatch
              ? '🐸 hatch this pepe (stake 0)'
              : approved
                ? 'stake with this pepe'
                : 'approve & stake'
            : approved
              ? 'stake into a fresh pepe'
              : 'approve & stake'

  async function run(fn: 'lock' | 'lockWithPepe', needsApproval = false) {
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
        ...(fn === 'lock' ? { args: [amountWad] } : { args: [amountWad, pickedId!] }),
      })
      setStep('done')
      setAmount('')
      setPickedId(null)
      refresh()
      setTimeout(() => setStep('idle'), 2500)
    } catch (e) {
      setError(e instanceof Error ? e.message.slice(0, 140) : 'transaction failed')
      setStep('idle')
    }
  }

  async function multiclaim() {
    setError(null)
    try {
      setMultiStep('tx')
      await writeContractAsync({
        address: round.staker!,
        abi: stakerAbi,
        functionName: 'claimAllTo',
        args: [entries.map((e) => e.id), address!],
      })
      setMultiStep('done')
      refresh()
      setTimeout(() => setMultiStep('idle'), 2500)
    } catch (e) {
      setError(e instanceof Error ? e.message.slice(0, 140) : 'transaction failed')
      setMultiStep('idle')
    }
  }

  async function reinvestAll() {
    setError(null)
    try {
      setMultiStep('tx')
      if (!reinvestApproved) {
        await writeContractAsync({
          address: round.staker!,
          abi: stakerAbi,
          functionName: 'setApprovalForAll',
          args: [ADDRESSES.reinvestor, true],
        })
      }
      const key = buildPoolKey(round.mix!, round.token!, round.hook!)
      await writeContractAsync({
        address: ADDRESSES.reinvestor,
        abi: reinvestorAbi,
        functionName: 'reinvestAll',
        args: [stakeableIds, key, 0n, 0n],
      })
      setMultiStep('done')
      refresh()
      setTimeout(() => setMultiStep('idle'), 2500)
    } catch (e) {
      setError(e instanceof Error ? e.message.slice(0, 140) : 'transaction failed')
      setMultiStep('idle')
    }
  }

  /// testnet-only: one drip per click — pay 0.0001 ETH, receive 100 mixETH
  const [dripStep, setDripStep] = useState<'idle' | 'tx' | 'done'>('idle')
  async function drip() {
    setError(null)
    try {
      setDripStep('tx')
      await writeContractAsync({
        address: ADDRESSES.faucet,
        abi: faucetAbi,
        functionName: 'drip',
        value: parseEther('0.0001'),
      })
      setDripStep('done')
      setTimeout(() => setDripStep('idle'), 2500)
    } catch (e) {
      setError(e instanceof Error ? e.message.slice(0, 140) : 'transaction failed')
      setDripStep('idle')
    }
  }

  const multiBusy = multiStep === 'tx'

  return (
    <div className="flex flex-col gap-5">
      <div className="card p-5">
        <h2 className="flex items-center gap-1.5 text-lg font-black text-slate-900">
          <PspIcon px={24} /> stake PSP
        </h2>
        <p className="text-xs text-slate-400">
          indefinite lock · fees flow while you stay · request a withdraw to start the 6-week exit ramp
        </p>

        <div className="mt-4 grid grid-cols-2 gap-3">
          <div className="rounded-2xl bg-sky-50 p-3">
            <div className="text-[11px] font-black uppercase tracking-wide text-slate-400">total PSP staked</div>
            <div className="text-xl font-black text-slate-900">{fmtAmount(totalStaked)}</div>
          </div>
          <div className="rounded-2xl bg-emerald-50 p-3">
            <div className="text-[11px] font-black uppercase tracking-wide text-slate-400">total value staked</div>
            <div className="text-xl font-black text-slate-900">
              {totalValueMix !== undefined ? <>≈{fmtAmount(totalValueMix, 4)} <MixLogo /></> : '—'}
            </div>
            {totalValueUsd !== undefined && (
              <div className="text-[11px] font-bold text-slate-400">≈ ${totalValueUsd < 1 ? totalValueUsd.toFixed(4) : totalValueUsd.toFixed(2)}</div>
            )}
          </div>
        </div>

        {hasPepes && (
          <div className="mt-3 flex flex-col gap-2 sm:flex-row">
            <button
              className="btn-primary flex-1"
              disabled={!isConnected || totalPending === 0n || multiBusy}
              onClick={multiclaim}
            >
              {multiStep === 'done' ? '✅ claimed' : multiBusy ? 'confirm…' : `multiclaim — ${fmtAmount(totalPending, 4)} mixETH`}
            </button>
            {REINVEST_ENABLED && (
              <button
                className="btn-ghost flex-1"
                disabled={!isConnected || totalPending === 0n || stakeableIds.length === 0 || multiBusy}
                onClick={reinvestAll}
              >
                {multiStep === 'done' ? '✅' : reinvestApproved ? '↻ reinvest all' : 'approve & reinvest all'}
              </button>
            )}
          </div>
        )}

        {!hasPepes && (
          <div className="mt-3">
            <PepePicker round={round} selected={pickedId} onSelect={setPickedId} seed={pickerSeed} onReroll={() => setPickerSeed((s) => s + 1)} />
          </div>
        )}

        <div className="mt-3 rounded-2xl border border-sky-100 bg-sky-50/60 p-4">
          <div className="flex items-center justify-between text-xs font-bold text-slate-400">
            <span>stake amount {hasPepes ? '(fresh pepe)' : ''}</span>
            <span className="flex items-center gap-2">
              {!hasPepes && amountWad === 0n && <span className="text-emerald-500">0 = pepe only</span>}
              bal {fmtAmount(pspBal)}
            </span>
          </div>
          <div className="mt-2 flex gap-2">
            <input
              className="input-amount flex-1"
              placeholder={hasPepes ? '0.0 — new pepe' : '0.0 — or nothing, just the pepe'}
              value={amount}
              inputMode="decimal"
              onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ''))}
            />
            <button className="btn-ghost shrink-0" onClick={() => setAmount(pspBal ? (Number(pspBal) / 1e18).toString() : '0')}>
              max
            </button>
          </div>
          <button className="btn-primary mt-3 w-full" disabled={!canSubmit} onClick={() => run(hasPepes ? 'lock' : 'lockWithPepe', !approved)}>
            {mainLabel}
          </button>
          {!hasPepes && pickedId === null && !busy && step !== 'done' && (
            <p className="mt-2 text-center text-xs font-bold text-slate-400">↑ pick a pepe above to enable staking</p>
          )}
        </div>

        {FAUCET_ENABLED && (
          <div className="mt-3 flex items-center justify-between rounded-2xl border border-dashed border-emerald-200 bg-emerald-50/50 px-4 py-2">
            <MixLogo className="mr-3 shrink-0 text-[1.6em]" />
            <div className="flex-1">
              <div className="text-xs font-black text-slate-700">faucet</div>
              <div className="text-[11px] font-bold text-slate-400">100 mixETH per 0.0001 ETH</div>
            </div>
            <button className="btn-ghost ml-3 shrink-0" disabled={!isConnected || busy} onClick={drip}>
              {dripStep === 'done' ? '✅' : dripStep === 'tx' ? 'confirm…' : <><MixLogo px={16} /> get mixETH</>}
            </button>
          </div>
        )}

        {error && <div className="mt-2 break-words text-xs text-rose-500">{error}</div>}
      </div>

      {hasPepes && (
        <div>
          <h3 className="mb-3 text-sm font-black uppercase tracking-wide text-slate-400">your staked pepes</h3>
          <PepeCards round={round} entries={entries} pendings={pendings} vest={vest} approved={reinvestApproved} onDone={refresh} />
        </div>
      )}

      <PepePanel round={round} refreshKey={pepeKey} />
    </div>
  )
}
