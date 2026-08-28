import { useEffect, useMemo, useState } from 'react'
import { useAccount, useWriteContract } from 'wagmi'
import { ADDRESSES, FAUCET_ENABLED, REINVEST_ENABLED } from '../lib/config'
import { controllerAbi, erc20Abi, faucetAbi, stakerAbi, reinvestorAbi, buildPoolKey } from '../lib/abi'
import { useRound, useBalances } from '../lib/useRound'
import { useRpcReads } from '../lib/useRpcReads'
import { rpcCall } from '../lib/rpc'
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
  const baseResults = useRpcReads(
    [
      { to: round.staker, abi: stakerAbi, functionName: 'balanceOf', args: [address ?? ZERO] },
      { to: round.controller, abi: controllerAbi, functionName: 'VEST_DURATION' },
      { to: round.token, abi: erc20Abi, functionName: 'allowance', args: [address ?? ZERO, round.staker ?? ZERO] },
      { to: round.staker, abi: stakerAbi, functionName: 'pendingFeesMixETH' },
    ],
    !!address && !!round.staker && !!round.token,
  )
  const apprResults = useRpcReads(
    [
      { to: round.staker, abi: stakerAbi, functionName: 'isApprovedForAll', args: [address ?? ZERO, ADDRESSES.reinvestor] },
    ],
    REINVEST_ENABLED && !!address && !!round.staker,
  )

  const count = baseResults[0] as bigint | undefined
  const vest = baseResults[1] as bigint | undefined
  const allowance = baseResults[2] as bigint | undefined
  const feesInFlight = baseResults[3] as bigint | undefined

  /// fees are credited to stakers the instant they land (live accumulator —
  /// 2026-08-28 redesign). `pendingFeesMixETH` is only nonzero when there is
  /// no staked weight at all (e.g. pre-launch): those park until weight
  /// exists, then attach on the next trade.
  const parked = feesInFlight ?? 0n
  const reinvestApproved = REINVEST_ENABLED ? (apprResults[0] as boolean | undefined) : undefined

  const n = count !== undefined ? Number(count) : 0

  // per-pepe reads: ids, positions, pendings
  const idResults = useRpcReads(
    Array.from({ length: n }, (_, i) => ({
      to: round.staker,
      abi: stakerAbi,
      functionName: 'tokenOfOwnerByIndex',
      args: [address ?? ZERO, BigInt(i)],
    })),
    !!address && n > 0,
  )
  const ids = useMemo(
    () => idResults.filter((x): x is bigint => x !== undefined),
    [idResults],
  )

  const detailResults = useRpcReads(
    ids.flatMap((id) => [
      { to: round.staker, abi: stakerAbi, functionName: 'positions', args: [id] },
      { to: round.staker, abi: stakerAbi, functionName: 'pendingFeesOf', args: [id] },
    ]),
    ids.length > 0,
  )

  const entries: PepeEntry[] = useMemo(() => {
    const out: PepeEntry[] = []
    for (let i = 0; i < ids.length; i++) {
      const pos = detailResults[i * 2] as [bigint, bigint, bigint, bigint, bigint, bigint, bigint, bigint] | undefined
      if (!pos) continue
      out.push({ id: ids[i], amount: pos[0], requestEpoch: pos[2] })
    }
    return out
  }, [ids, detailResults])

  const pendings = useMemo(() => {
    const m = new Map<bigint, bigint | undefined>()
    ids.forEach((id, i) => {
      m.set(id, detailResults[i * 2 + 1] as bigint | undefined)
    })
    return m
  }, [ids, detailResults])

  const totalStaked = entries.reduce((a, e) => a + e.amount, 0n)
  const totalValueMix = round.marginalPrice ? (totalStaked * round.marginalPrice) / 10n ** 18n : undefined
  const totalValueUsd = totalValueMix !== undefined && ethUsd ? (Number(totalValueMix) / 1e18) * ethUsd : undefined
  const totalPending = [...pendings.values()].reduce<bigint>((a, p) => a + (p ?? 0n), 0n)
  const stakeableIds = entries.filter((e) => e.requestEpoch === 0n && e.amount > 0n).map((e) => e.id)

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
              ? pickedId !== null
                ? 'stake into the picked pepe'
                : 'stake into a fresh pepe'
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

  /// Hatch a fresh unstaked pepe — contract supports lock(0) for owners who
  /// already hold pepes; the main button only offers amount > 0 stakes then.
  async function hatch() {
    setError(null)
    try {
      setStep('tx')
      await writeContractAsync({
        address: round.staker!,
        abi: stakerAbi,
        ...(pickedId !== null
          ? { functionName: 'lockWithPepe' as const, args: [0n, pickedId] as const }
          : { functionName: 'lock' as const, args: [0n] as const }),
      })
      setStep('done')
      setPickedId(null)
      setPickerSeed((s) => s + 1)
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

  /// testnet-only: free mixETH mint — one click, 1000 mixETH, no ETH needed
  const [dripStep, setDripStep] = useState<'idle' | 'tx' | 'done'>('idle')
  async function drip() {
    setError(null)
    try {
      setDripStep('tx')
      await writeContractAsync({
        address: ADDRESSES.faucet,
        abi: faucetAbi,
        functionName: 'drip',
        args: [1000n * 10n ** 18n],
      })
      setDripStep('done')
      setTimeout(() => setDripStep('idle'), 2500)
    } catch (e) {
      setError(e instanceof Error ? e.message.slice(0, 140) : 'transaction failed')
      setDripStep('idle')
    }
  }

  /// Unclaimed genesis share — the claim lives HERE now (the predeposit page
  /// is a launch-phase view; post-launch users look for their PSP on stake).
  /// Polls predeposits(address) once the curve is live; claiming mints a
  /// fresh pepe with the share locked in.
  const [myDep, setMyDep] = useState<{ mixETHAmount: bigint; claimed: boolean } | undefined>(undefined)
  const [claimStep, setClaimStep] = useState<'idle' | 'tx' | 'done' | 'err'>('idle')
  useEffect(() => {
    if (!round.controller || !address || (round.mode ?? 0) < 1) return
    let dead = false
    const c = round.controller
    const who = address
    async function tick() {
      try {
        // named-tuple return decodes as { mixETHAmount, claimed } in viem
        const d = (await rpcCall(c, controllerAbi, 'predeposits', [who])) as unknown as {
          mixETHAmount: bigint
          claimed: boolean
        }
        if (!dead && typeof d.mixETHAmount === 'bigint') {
          setMyDep({ mixETHAmount: d.mixETHAmount, claimed: d.claimed })
        }
      } catch { /* keep last */ }
    }
    tick()
    const iv = setInterval(tick, 6000)
    return () => { dead = true; clearInterval(iv) }
  }, [round.controller, round.mode, address])

  async function claimGenesis() {
    setError(null)
    if (!round.controller) return
    try {
      setClaimStep('tx')
      await writeContractAsync({
        address: round.controller,
        abi: controllerAbi,
        functionName: 'claimPredepositPSP',
      })
      setClaimStep('done')
      refresh()
      setTimeout(() => setClaimStep('idle'), 2500)
    } catch (e) {
      setError(e instanceof Error ? e.message.slice(0, 140) : 'claim failed')
      setClaimStep('idle')
    }
  }

  const claimable = (round.mode ?? 0) >= 1 && myDep !== undefined && !myDep.claimed && myDep.mixETHAmount > 0n

  const multiBusy = multiStep === 'tx'

  return (
    <div className="flex flex-col gap-5">
      {claimable && (
        <div className="card border-2 border-emerald-200 p-5">
          <h2 className="flex items-center gap-1.5 text-lg font-black text-slate-900">
            🐸 unclaimed genesis share
          </h2>
          <p className="mt-1 text-xs text-slate-500">
            your predeposit ({fmtAmount(myDep!.mixETHAmount)} mixETH) has an unclaimed pro-rata PSP share
            waiting — claiming mints a fresh pepe with the PSP locked in, earning fees from day one.
          </p>
          <button className="btn-primary mt-3 w-full" disabled={claimStep === 'tx' || busy} onClick={claimGenesis}>
            {claimStep === 'done' ? '✅ claimed' : claimStep === 'tx' ? 'confirm in wallet…' : 'claim your genesis PSP'}
          </button>
        </div>
      )}
      {parked > 0n && (
        <div className="card p-4">
          <p className="text-xs font-bold text-slate-500">
            ⏳ {fmtAmount(parked)} mixETH of swap fees parked — no staked weight yet, so they
            attach on the next trade once weight exists. nothing is lost while waiting.
          </p>
        </div>
      )}
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

        <div className="mt-3">
          <PepePicker round={round} selected={pickedId} onSelect={setPickedId} seed={pickerSeed} onReroll={() => setPickerSeed((s) => s + 1)} />
        </div>

        <div className="mt-3 rounded-2xl border border-sky-100 bg-sky-50/60 p-4">
          <div className="flex items-center justify-between text-xs font-bold text-slate-400">
            <span>stake amount {hasPepes ? (pickedId !== null ? '(picked pepe)' : '(fresh pepe)') : ''}</span>
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
          <button className="btn-primary mt-3 w-full" disabled={!canSubmit} onClick={() => run(pickedId !== null ? 'lockWithPepe' : 'lock', !approved)}>
            {mainLabel}
          </button>
          {hasPepes && (
            <button className="btn-ghost mt-2 w-full" disabled={!isConnected || busy} onClick={hatch}>
              {step === 'tx' ? 'confirm…' : '🐸 hatch another pepe (stake 0)'}
            </button>
          )}
          {!hasPepes && pickedId === null && !busy && step !== 'done' && (
            <p className="mt-2 text-center text-xs font-bold text-slate-400">↑ pick a pepe above to enable staking</p>
          )}
        </div>

        {FAUCET_ENABLED && (
          <div className="mt-3 flex items-center justify-between rounded-2xl border border-dashed border-emerald-200 bg-emerald-50/50 px-4 py-2">
            <MixLogo className="mr-3 shrink-0 text-[1.6em]" />
            <div className="flex-1">
              <div className="text-xs font-black text-slate-700">faucet</div>
              <div className="text-[11px] font-bold text-slate-400">free playtest mixETH · 1000 per click</div>
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
