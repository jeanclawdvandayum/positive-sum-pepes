import { minimumOutput, MIN_BUY_INPUT } from '../lib/gameRules'
import { useConfirmedWrite } from '../lib/useConfirmedWrite'
import { predepositResult } from '../lib/chainResults'
import { useEffect, useMemo, useState } from 'react'
import { useAccount } from 'wagmi'
import { ADDRESSES, FAUCET_ENABLED, REINVEST_ENABLED } from '../lib/config'
import { controllerAbi, erc20Abi, faucetAbi, hookAbi, stakerAbi, reinvestorAbi, buildPoolKey } from '../lib/abi'
import { useRound, useBalances } from '../lib/useRound'
import { useRpcReads } from '../lib/useRpcReads'
import { rpcCall } from '../lib/rpc'
import { fmtAmount, parseAmountToWad, wadToExact } from '../lib/format'
import MixLogo from '../components/MixLogo'
import PepePicker from '../components/PepePicker'
import PepeCards, { type PepeEntry } from '../components/PepeCards'
import { PspIcon } from '../components/TokenIcon'
import { PixelIcon } from '../components/PixelIcon'
import TickerBar, { type TickerItem } from '../components/TickerBar'
import { useEthUsd } from '../lib/useEthUsd'
import StakeStyles from './stake/StakeStyles'
import IdentityPanel from './stake/IdentityPanel'
import ReferralsCard from './stake/ReferralsCard'
import { useNftVersion } from '../lib/useNftVersion'
import { useNftReinvestment } from '../lib/useNftReinvestment'

// ─────────────────────────────────────────────────────────────────────────────
// /stake — the den: "your pepe works here" (REDESIGN-B3).
//
// Left: identity/fees → referrals and .wei. Right: six-pepe picker → stake form.
// Owned positions span both columns below. Mobile keeps overview → picker/form
// → referrals → positions in source order. Round history lives in the graveyard.
//
// Every read/write below is StakeCard's, carried over unchanged — same
// useRpcReads batches, same cadences, same approve→lock flow, same error
// truncation. Only the composition is new. The old carpet-bomb vote card is
// NOT mounted (see phase output) — the new game's boom is permissionless and
// belongs to the play page's clock.
// ─────────────────────────────────────────────────────────────────────────────

type Step = 'idle' | 'approve' | 'tx' | 'done'

export default function Stake() {
  const round = useRound()
  const nftVersion = useNftVersion(round.staker)
  const nftReinvestment = useNftReinvestment(round.staker, nftVersion)
  const { address, isConnected } = useAccount()
  const [pepeKey, setPepeKey] = useState(0)
  const { psp: pspBal } = useBalances(round.token, round.mix, pepeKey)
  const [amount, setAmount] = useState('')
  const [step, setStep] = useState<Step>('idle')
  const [error, setError] = useState<string | null>(null)
  const [pickedId, setPickedId] = useState<bigint | null>(null)
  const [pickerSeed, setPickerSeed] = useState(1)
  const [multiStep, setMultiStep] = useState<'idle' | 'tx' | 'done'>('idle')
  const { writeContractAsync } = useConfirmedWrite()
  const ethUsd = useEthUsd()

  const ZERO = '0x0000000000000000000000000000000000000000' as const
  const baseResults = useRpcReads(
    [
      { to: round.staker, abi: stakerAbi, functionName: 'balanceOf', args: [address ?? ZERO] },
      { to: round.controller, abi: controllerAbi, functionName: 'VEST_DURATION' },
      { to: round.token, abi: erc20Abi, functionName: 'allowance', args: [address ?? ZERO, round.staker ?? ZERO] },
      { to: round.staker, abi: stakerAbi, functionName: 'pendingFeesMixETH' },
    ],
    !!address && !!round.staker && !!round.token,
    6000, pepeKey,
  )
  const apprResults = useRpcReads(
    [
      { to: round.staker, abi: stakerAbi, functionName: 'isApprovedForAll', args: [address ?? ZERO, ADDRESSES.reinvestor] },
    ],
    REINVEST_ENABLED && !!address && !!round.staker,
    6000, pepeKey,
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
    6000, pepeKey,
  )
  const ids = useMemo(
    () => idResults.filter((x): x is bigint => x !== undefined),
    [idResults],
  )

  const detailResults = useRpcReads(
    ids.flatMap((id) => [
      { to: round.staker, abi: stakerAbi, functionName: 'positions', args: [id] },
      { to: round.staker, abi: stakerAbi, functionName: 'pendingFeesOf', args: [id] },
      { to: round.staker, abi: stakerAbi, functionName: 'isWithdrawing', args: [id] },
    ]),
    ids.length > 0,
    6000, pepeKey,
  )

  const entries: PepeEntry[] = useMemo(() => {
    const out: PepeEntry[] = []
    for (let i = 0; i < ids.length; i++) {
      const pos = detailResults[i * 3] as [bigint, bigint, bigint, bigint, bigint] | undefined
      if (!pos) continue
      out.push({ id: ids[i], amount: pos[0], requestEpoch: pos[2], withdrawing: detailResults[i * 3 + 2] as boolean | undefined })
    }
    return out
  }, [ids, detailResults])

  const pendings = useMemo(() => {
    const m = new Map<bigint, bigint | undefined>()
    ids.forEach((id, i) => {
      m.set(id, detailResults[i * 3 + 1] as bigint | undefined)
    })
    return m
  }, [ids, detailResults])

  const totalStaked = entries.reduce((a, e) => a + e.amount, 0n)
  const totalValueMix = round.marginalPrice ? (totalStaked * round.marginalPrice) / 10n ** 18n : undefined
  const totalValueUsd = totalValueMix !== undefined && ethUsd ? (Number(totalValueMix) / 1e18) * ethUsd : undefined
  const totalPending = [...pendings.values()].reduce<bigint>((a, p) => a + (p ?? 0n), 0n)
  const stakeableIds = entries.filter((e) => e.withdrawing === false && e.amount > 0n).map((e) => e.id)

  /// share of the 60% staker stream = your locked PSP / all locked PSP
  const sharePct =
    round.totalLocked !== undefined && round.totalLocked > 0n
      ? Number((totalStaked * 1_000_000n) / round.totalLocked) / 10_000
      : undefined

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
      ? '✓ done'
      : step === 'approve'
        ? 'approving…'
        : busy
          ? 'confirm…'
          : !hasPepes
            ? zeroHatch
              ? 'hatch this pepe (stake 0)'
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
      await nftReinvestment.prepare(stakeableIds)
      const key = buildPoolKey(round.mix!, round.token!, round.hook!)
      const fees = (await Promise.all(stakeableIds.map(id => rpcCall(round.staker!, stakerAbi, 'pendingFeesOf', [id]) as Promise<bigint>))).reduce((sum, fee) => sum + fee, 0n)
      if (fees < MIN_BUY_INPUT) throw new Error('Reinvest requires at least 0.005 mixETH in accrued fees.')
      const quote = await rpcCall(round.hook!, hookAbi, 'getBuyOutput', [fees]) as bigint
      nftReinvestment.assertSession()
      await writeContractAsync({
        address: ADDRESSES.reinvestor,
        abi: reinvestorAbi,
        functionName: 'reinvestAll',
        args: [stakeableIds, key, minimumOutput(quote, 100), BigInt(Math.floor(Date.now() / 1000) + 600)],
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
    setMyDep(undefined)
    if (!round.controller || !address || (round.mode ?? 0) < 1) return
    let dead = false
    const c = round.controller
    const who = address
    async function tick() {
      try {
        const d = predepositResult(await rpcCall(c, controllerAbi, 'predeposits', [who]))
        if (!dead) setMyDep(d)
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

  // bottom stat cards folded into the continuous ticker (B3 item 5)
  const tickerItems: TickerItem[] = [
    { label: 'round', value: round.id.toString() },
    { label: 'your stake', value: `${fmtAmount(totalStaked)} psp` },
    ...(totalValueMix !== undefined
      ? [{ label: 'staked value', value: `≈ ${fmtAmount(totalValueMix, 4)} mix` }]
      : []),
    ...(totalValueUsd !== undefined
      ? [
          {
            label: 'in usd',
            value: `≈ $${totalValueUsd < 1 ? totalValueUsd.toFixed(4) : totalValueUsd.toFixed(2)}`,
          },
        ]
      : []),
    { label: 'your pepes', value: String(entries.length) },
    { label: 'fees earned', value: `${fmtAmount(totalPending, 4)} mix` },
    ...(round.totalLocked !== undefined
      ? [{ label: 'all psp locked', value: `${fmtAmount(round.totalLocked)} psp` }]
      : []),
  ]

  // multiclaim / reinvest — mounted inside the identity panel under the
  // accumulator (the fees it counts are the fees it claims)
  const claimRow = hasPepes ? (
    <div className="mt-4 flex flex-col gap-2 sm:flex-row">
      <button
        type="button"
        className="st-btn st-btn-primary flex-1"
        disabled={!isConnected || totalPending === 0n || multiBusy}
        onClick={multiclaim}
      >
        {multiStep === 'done' ? '✓ claimed' : multiBusy ? 'confirm…' : `multiclaim — ${fmtAmount(totalPending, 4)} mixETH`}
      </button>
      {round.reinvestorReady && (
        <button
          type="button"
          className="st-btn flex-1"
          disabled={!isConnected || totalPending === 0n || stakeableIds.length === 0 || multiBusy || nftVersion === undefined}
          onClick={reinvestAll}
        >
          {multiStep === 'done' ? '✓' : reinvestApproved ? '↻ reinvest all' : 'approve & reinvest all'}
          {!reinvestApproved && <span className="mt-1 block text-[10px] font-normal">
            {nftVersion === 1 ? 'approve each included Pepe · transfer and fee-claim permission' : nftVersion === 0 ? 'collection approval · transfers and fee claims for all Pepes' : 'checking approvals…'}
          </span>}
        </button>
      )}
    </div>
  ) : null

  return (
    <div className="st-page font-body text-text-hi">
      <StakeStyles />

      <div className="grid grid-cols-1 items-start gap-4 lg:grid-cols-2 lg:grid-rows-[auto_1fr]">
        {/* ── left: identity and earned fees ── */}
        <div className="flex min-w-0 flex-col gap-4">
          {claimable && (
            <section className="rounded-2xl border border-pepe bg-bg-1 p-5">
              <h2 className="font-display text-lg">your first bag is waiting</h2>
              <p className="mt-1 text-xs leading-relaxed text-text-lo">
                your {fmtAmount(myDep!.mixETHAmount)} mixETH predeposit bought a share of the launch PSP.
                claim it into a fresh pepe NFT. your PSP stays staked, and you keep your share of the fees earned before claiming.
              </p>
              <button
                type="button"
                className="st-btn st-btn-primary mt-3 w-full"
                disabled={claimStep === 'tx' || busy}
                onClick={claimGenesis}
              >
                {claimStep === 'done' ? '✓ claimed' : claimStep === 'tx' ? 'confirm in wallet…' : 'claim your genesis PSP'}
              </button>
            </section>
          )}

          <IdentityPanel
            round={round}
            refreshKey={pepeKey}
            staked={totalStaked}
            valueMix={totalValueMix}
            valueUsd={totalValueUsd}
            sharePct={sharePct}
            feesValue={totalPending}
            connected={isConnected}
            hasStake={hasPepes}
            parked={parked}
            claimRow={claimRow}
          />
        </div>

        {/* ── right: choose a pepe, then stake ── */}
        <div className="flex min-w-0 flex-col gap-4 lg:col-start-2 lg:row-span-2 lg:row-start-1">
          <PepePicker
            round={round}
            selected={pickedId}
            onSelect={setPickedId}
            seed={pickerSeed}
            onReroll={() => setPickerSeed((s) => s + 1)}
          />

          {/* stake form — function unchanged, placeholder verbatim */}
          <section className="rounded-2xl border border-line bg-bg-1 p-5" aria-label="stake psp">
            <h2 className="flex items-center gap-2 font-display text-lg">
              <PspIcon px={20} /> stake psp
            </h2>
            <p className="mt-1 text-xs text-text-lo">
              park your PSP with your pepe. staked PSP earns trading fees; requesting withdrawal starts a six-epoch exit.
            </p>

            <div className="mt-4">
              <div className="flex items-center justify-between gap-2 text-xs text-text-lo">
                <span>stake amount {hasPepes ? (pickedId !== null ? '(picked pepe)' : '(fresh pepe)') : ''}</span>
                <span className="flex items-center gap-2">
                  {!hasPepes && amountWad === 0n && <span className="text-pepe">0 = pepe only</span>}
                  <span className="tabular font-data">bal {fmtAmount(pspBal)}</span>
                </span>
              </div>
              <div className="mt-2 flex gap-2">
                <input
                  className="st-input min-w-0 flex-1"
                  placeholder={hasPepes ? '0.0 — new pepe' : '0.0 — zero gets you the pepe'}
                  value={amount}
                  inputMode="decimal"
                  onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ''))}
                />
                <button type="button" className="st-btn shrink-0" onClick={() => setAmount(wadToExact(pspBal))}>
                  max
                </button>
              </div>
              <button
                type="button"
                className="st-btn st-btn-primary mt-3 w-full"
                disabled={!canSubmit}
                onClick={() => run(pickedId !== null ? 'lockWithPepe' : 'lock', !approved)}
              >
                {mainLabel}
              </button>
              {hasPepes && (
                <button type="button" className="st-btn mt-2 w-full" disabled={!isConnected || busy} onClick={hatch}>
                  {step === 'tx' ? 'confirm…' : 'hatch another pepe (stake 0)'}
                </button>
              )}
              {!hasPepes && pickedId === null && !busy && step !== 'done' && (
                <p className="mt-2 text-center text-xs text-text-lo">↑ pick a pepe above to enable staking</p>
              )}

              {FAUCET_ENABLED && (
                <div className="mt-4 flex items-center justify-between rounded-xl border border-dashed border-line px-4 py-2">
                  <MixLogo className="mr-3 shrink-0 text-[1.6em]" />
                  <div className="flex-1">
                    <div className="text-xs font-semibold">faucet</div>
                    <div className="text-[11px] text-text-lo">free playtest mixETH · 1000 per click</div>
                  </div>
                  <button
                    type="button"
                    className="st-btn ml-3 shrink-0 text-xs"
                    disabled={!isConnected || busy}
                    onClick={drip}
                  >
                    {dripStep === 'done' ? '✓' : dripStep === 'tx' ? 'confirm…' : 'get mixETH'}
                  </button>
                </div>
              )}

              {error && <div className="mt-2 break-words text-xs text-phase-critical">{error}</div>}
            </div>
          </section>

        </div>

        {/* ── below the overview on desktop; after the form on mobile ── */}
        <div className="flex min-w-0 flex-col gap-4 lg:col-start-1 lg:row-start-2">
          <ReferralsCard />

          <div className="flex items-start gap-3 rounded-2xl border border-line bg-bg-2 p-4">
            <span className="mt-0.5 shrink-0">
              <PixelIcon name="diamond" size={18} />
            </span>
            <div>
              <div className="text-sm font-semibold">pepe names — .wei</div>
              <p className="mt-1 text-xs leading-relaxed text-text-lo">
                give your accomplice an alias. .wei names are planned for a future registry launch.
                your pepe number identifies your NFT today.
              </p>
            </div>
          </div>

        </div>
      </div>

      {hasPepes && (
        <section className="mt-6" aria-label="your staked pepes">
          <h2 className="mb-3 font-display text-xl">your staked pepes</h2>
          <PepeCards round={round} entries={entries} pendings={pendings} vest={vest} approved={reinvestApproved} nftVersion={nftVersion} walletBalance={pspBal} onDone={refresh} />
        </section>
      )}

      {/* bottom stats = one continuous ticker, same component as play */}
      <div className="mt-6 border-t border-line py-3">
        <TickerBar items={tickerItems} />
      </div>
    </div>
  )
}
