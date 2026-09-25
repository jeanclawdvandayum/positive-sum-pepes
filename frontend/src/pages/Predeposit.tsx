import AmountSlider from '../components/AmountSlider'
import { AltClock } from '../alt/AltCommon'
import { usePepeDnaVersion } from '../lib/usePepeDnaVersion'
import { capHeadroom, predepositUncapped, predepositLimit, predepositAmountAllowed, predepositProgress, predepositRemainder, ibcoPhaseAt, ibcoEnds, greenWalletHeadroom, openPhaseLimit, greenPhaseLimit } from '../lib/predeposit'
import { usePredepositRules, usePredepositState } from '../lib/usePredepositMinimum'
import { predepositResult, type PredepositEntry } from '../lib/chainResults'
import { useConfirmedWrite } from '../lib/useConfirmedWrite'
import { useEffect, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { useAccount } from 'wagmi'
import { controllerAbi, erc20Abi, legacyControllerAbi, pspTokenAbi, stakerAbi } from '../lib/abi'
import { rpcCall } from '../lib/rpc'
import { useRpcReads } from '../lib/useRpcReads'
import { ADDRESSES, CHAIN_ID, FAUCET_ENABLED, NATIVE_ETH_FAUCET_URL, TESTNET_ETH_FAUCET } from '../lib/config'
import { useRound, useBalances } from '../lib/useRound'
import { useNow } from '../phase/PhaseEngine'
import { fmtAmount, parseAmountToWad, wadToExact } from '../lib/format'
import { bundledGreenlist, treeMatchesRoot } from '../lib/greenlistTrees'
import { parseGreenlistTree, type GreenlistTree } from '../lib/greenlist'
import { RefBanner } from '../components/ReferralCard'
import { FaucetButton } from '../components/Topbar'
import MixLogo from '../components/MixLogo'
import Clock from '../components/Clock'
import ClockBand from '../components/ClockBand'
import PepePicker from '../components/PepePicker'
import { useQuery } from '@tanstack/react-query'
import { renderPepeSvg } from '../lib/pepeRender'
import { dnaOfId } from '../components/PepePicker'

type Step = 'idle' | 'approve' | 'tx' | 'done'


export default function Predeposit({ variant }: { variant?: 'alt' } = {}) {
  const round = useRound()
  const dnaVersion = usePepeDnaVersion(round.staker)
  const { minimum, version: predepositVersion } = usePredepositRules(round.controller)
  const [selectedPepe, setSelectedPepe] = useState<bigint | null>(null)
  const [pickerSeed, setPickerSeed] = useState(1)
  const { address, isConnected } = useAccount()
  const { mix: mixBal } = useBalances(round.token, round.mix)

  const { data: artVersion, isPending: artLoading } = useQuery({
    queryKey: ['predeposit-art-version', CHAIN_ID, round.controller],
    enabled: !!round.controller,
    queryFn: () => rpcCall(round.controller!, controllerAbi, 'PREDEPOSIT_ART_VERSION') as Promise<bigint>,
  })
  const { data: reservedPepe, refetch: refreshPepe } = useQuery({
    queryKey: ['predeposit-pepe', CHAIN_ID, round.controller, address],
    enabled: artVersion === 2n && !!address,
    queryFn: () => rpcCall(round.controller!, controllerAbi, 'predepositPepe', [address!]) as Promise<bigint>,
    refetchInterval: 6000,
  })
  const depositSession = `${address}:${round.controller}`
  const latestDepositSession = useRef(depositSession)
  latestDepositSession.current = depositSession
  const pickerRef = useRef<HTMLDivElement | null>(null)
  useEffect(() => { setSelectedPepe(null); setStep('idle'); setError(null) }, [address, round.controller])
  const depositPepe = reservedPepe && reservedPepe > 0n ? reservedPepe : selectedPepe

  /// Era-aware predepositState + window facts, polled like every other read
  /// in this app (useReadContracts sits idle on custom chains). Legacy v2
  /// rounds decode the 7-tuple; rules v3 the 11-tuple with phase/green.
  const [nonce, setNonce] = useState(0)
  const { state: pd, facts } = usePredepositState(round.controller, 4000, nonce)
  const rules3 = pd !== undefined && pd.phase !== undefined
  const [depositors, setDepositors] = useState<bigint | undefined>(undefined)
  const [myDep, setMyDep] = useState<PredepositEntry | undefined>(undefined)
  const [allowance, setAllowance] = useState<bigint | undefined>(undefined)

  useEffect(() => {
    setMyDep(undefined)
    setDepositors(undefined)
    if (!round.controller) return
    let dead = false
    const entryAbi = predepositVersion === 3n ? controllerAbi : legacyControllerAbi
    async function tick() {
      try {
        const [cnt, dep] = await Promise.all([
          rpcCall(round.controller!, controllerAbi, 'totalPredepositors') as Promise<bigint>,
          address
            ? rpcCall(round.controller!, entryAbi, 'predeposits', [address]).then(predepositResult)
            : Promise.resolve(undefined),
        ])
        if (dead) return
        setDepositors(cnt)
        setMyDep(dep)
      } catch {
        /* controller not resolvable yet — keep last state */
      }
    }
    tick()
    const iv = setInterval(tick, 4000)
    return () => {
      dead = true
      clearInterval(iv)
    }
  }, [round.controller, address, nonce, predepositVersion])

  /// mixETH allowance toward the controller (mix path)
  useEffect(() => {
    if (!address || !round.mix || !round.controller) {
      setAllowance(undefined)
      return
    }
    let dead = false
    async function tick() {
      try {
        const a = (await rpcCall(round.mix!, erc20Abi, 'allowance', [address, round.controller!])) as bigint
        if (!dead) setAllowance(a)
      } catch {
        /* keep last */
      }
    }
    tick()
    const iv = setInterval(tick, 4000)
    return () => {
      dead = true
      clearInterval(iv)
    }
  }, [address, round.mix, round.controller, nonce])

  /// 1s heartbeat for the countdown — shared PhaseEngine tick (B0 refactor:
  /// one app-wide heartbeat instead of a per-page setInterval)
  const nowSec = useNow()

  /// ── greenlist-IBCO (rules v3) ─────────────────────────────────────────
  /// Phase ends + live phase, then membership: the previous round's frozen
  /// PSP holder map first (rootless auto-greenlist), else the csv merkle
  /// tree — bundled per factory at build time, with a manual upload fallback.
  const ZERO = '0x0000000000000000000000000000000000000000' as const
  const { greenEnd, openEnd } = ibcoEnds(pd?.startTime, facts?.greenSec, facts?.openSec, facts?.legacySec, pd?.greenPerWallet)
  const phaseNow = rules3 ? ibcoPhaseAt(nowSec, greenEnd, openEnd) : undefined
  const [prevTokenRaw, greenRootRaw] = useRpcReads([
    { to: round.controller, abi: controllerAbi, functionName: 'PREV_TOKEN' },
    { to: round.controller, abi: controllerAbi, functionName: 'GREEN_ROOT' },
  ], rules3 && !!round.controller, 30000)
  const prevToken = prevTokenRaw as `0x${string}` | undefined
  const greenRoot = greenRootRaw as `0x${string}` | undefined
  const hasPrevToken = !!prevToken && !/^0x0+$/.test(prevToken)
  const [holderRaw] = useRpcReads([
    { to: hasPrevToken ? prevToken : undefined, abi: pspTokenAbi, functionName: 'holder', args: [address ?? ZERO] },
  ], rules3 && hasPrevToken && !!address, 15000)
  const prevHolder = holderRaw as boolean | undefined
  const [uploadedTree, setUploadedTree] = useState<GreenlistTree | undefined>(undefined)
  const [uploadError, setUploadError] = useState<string | null>(null)
  useEffect(() => { setUploadedTree(undefined); setUploadError(null) }, [round.controller])
  const bundledTree = rules3 ? bundledGreenlist(ADDRESSES.factory) : undefined
  const activeTree = treeMatchesRoot(uploadedTree, greenRoot) ? uploadedTree
    : treeMatchesRoot(bundledTree, greenRoot) ? bundledTree : undefined
  const proof = address && activeTree ? activeTree.proofs[address.toLowerCase()] : undefined
  const isMember = prevHolder === true || proof !== undefined
  const hasCsvRoot = !!greenRoot && !/^0x0+$/.test(greenRoot)
  /// green-phase gates: proven member, proven outsider, or unknown (needs
  /// the tree file / the holder read to land).
  const greenGate = phaseNow === 0
    ? isMember ? 'member' as const
      : prevHolder === false || activeTree !== undefined ? 'closed' as const
      : 'unknown' as const
    : undefined

  function onGreenlistFile(file: File | undefined) {
    setUploadError(null)
    if (!file) return
    file.text()
      .then((text) => setUploadedTree(parseGreenlistTree(JSON.parse(text))))
      .catch((e) => setUploadError(e instanceof Error ? e.message : 'could not read that greenlist file'))
  }

  const [amount, setAmount] = useState('')
  const [step, setStep] = useState<Step>('idle')
  const [launchStep, setLaunchStep] = useState<'idle' | 'tx' | 'done'>('idle')
  const [error, setError] = useState<string | null>(null)
  const { writeContractAsync, writeWithApprovals } = useConfirmedWrite()

  const amountWad = parseAmountToWad(amount)
  const hasAllowance = allowance !== undefined && amountWad > 0n && allowance >= amountWad
  const balanceOk = amountWad > 0n && mixBal !== undefined && amountWad <= mixBal
  const busy = step === 'approve' || step === 'tx'

  /// per-wallet predeposit cap (0 = uncapped, e.g. mainnet profile)
  const [walletCap, setWalletCap] = useState<bigint | undefined>(undefined)
  useEffect(() => {
    setWalletCap(undefined)
    if (!round.controller) return
    let dead = false
    rpcCall(round.controller!, controllerAbi, 'PREDEPOSIT_CAP_PER_WALLET')
      .then((v) => { if (!dead) setWalletCap(v as bigint) })
      .catch(() => {})
    return () => { dead = true }
  }, [round.controller])

  const myDepAmount = myDep?.mixETHAmount ?? 0n
  const myGreen = myDep?.greenAmount ?? 0n
  const myOpen = myDepAmount - myGreen
  /// per-wallet cap of the CURRENT phase: green 500/N on the green tranche,
  /// open 10 mix priced off open-phase deposits only (green money never
  /// eats open headroom). Legacy rounds keep the packed wallet-cap slot.
  const phaseWalletHeadroom = phaseNow === 0 && pd?.greenPerWallet !== undefined
    ? greenWalletHeadroom(pd.greenPerWallet, myGreen)
    : phaseNow === 1 && pd?.openPerWallet !== undefined && pd.openPerWallet > 0n
      ? capHeadroom(myOpen, pd.openPerWallet)
      : undefined
  const walletCapExceeded = rules3
    ? phaseWalletHeadroom !== undefined && amountWad > 0n && amountWad > phaseWalletHeadroom
    : walletCap !== undefined && walletCap > 0n && amountWad > 0n && myDepAmount + amountWad > walletCap
  /// the most THIS wallet can still deposit: balance ∧ phase wallet headroom
  /// ∧ global headroom (phase 2 = window over, nothing left to commit)
  const maxDeposit = rules3 && pd
    ? mixBal === undefined || myDep === undefined
      ? undefined
      : phaseNow === 0
        ? greenPhaseLimit(mixBal, pd.total, pd.cap, pd.greenPerWallet ?? 0n, myGreen)
        : phaseNow === 1
          ? openPhaseLimit(mixBal, pd.total, pd.cap, pd.openPerWallet ?? 0n, myDepAmount, myGreen)
          : 0n
    : mixBal !== undefined && pd && walletCap !== undefined && myDep !== undefined
      ? predepositLimit(mixBal, pd.total, pd.cap, walletCap, myDepAmount, predepositVersion) : undefined
  const uncapped = !!pd && predepositUncapped(predepositVersion, pd.cap)
  const globalRemaining = pd && !uncapped ? capHeadroom(pd.total, pd.cap) : undefined
  const globalCapExceeded = globalRemaining !== undefined && amountWad > globalRemaining
  const belowMinimum = amountWad > 0n && amountWad < minimum
  const legacyDust = globalRemaining !== undefined && globalRemaining > 0n && globalRemaining < minimum

  /// Feature 1 (alt motion pass): the commit amount demands a pepe choice.
  /// Shows with or without a connected wallet.
  const needsPepe =
    variant === 'alt' &&
    artVersion === 2n &&
    !(reservedPepe && reservedPepe > 0n) &&
    selectedPepe === null &&
    amountWad > 0n &&
    !pd?.closed
  const amountInvalid = belowMinimum || globalCapExceeded || walletCapExceeded || (amountWad > 0n && !balanceOk)

  /// When the commit field blurs while the picker is being demanded, bring the
  /// highlighted picker on screen — never while the user is typing.
  function onAmountBlur() {
    const el = pickerRef.current
    if (!el || !needsPepe) return
    const rect = el.getBoundingClientRect()
    if (rect.bottom > 0 && rect.top < window.innerHeight) return
    const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches
    el.scrollIntoView({ behavior: reduced ? 'auto' : 'smooth', block: 'center' })
  }

  /// phase-aware deadline: green counts to the open window, open/legacy to
  /// the window end (rules v3; legacy rounds keep the single window)
  const endTime = pd ? (phaseNow === 0 ? greenEnd : openEnd) : undefined
  const remaining = endTime !== undefined ? Math.max(0, Number(endTime - BigInt(nowSec))) : undefined
  const mode = round.mode
  const launched = pd?.closed === true && (mode ?? 0) >= 1
  const greenLocked = greenGate !== undefined && greenGate !== 'member'
  const canSubmit =
    isConnected && !artLoading && !!round.controller && predepositAmountAllowed(amountWad, minimum, maxDeposit) && balanceOk && !walletCapExceeded && !busy && !pd?.closed && !(rules3 && phaseNow === 2) && !greenLocked && (artVersion !== 2n || (reservedPepe !== undefined && depositPepe !== null))


  async function fail(e: unknown) {
    setError(e instanceof Error ? e.message.slice(0, 140) : 'transaction failed')
    setStep('idle')
  }

  async function runDeposit() {
    if (!round.controller || !canSubmit) return
    setError(null)
    const approvals: Parameters<typeof writeWithApprovals>[1] = []
    try {
      if (!round.mix) return
      // Read at submission time: a previous deposit may have consumed the polled allowance.
      const freshAllowance = await rpcCall(round.mix, erc20Abi, 'allowance', [address!, round.controller]) as bigint
      if (latestDepositSession.current !== depositSession) return
      setAllowance(freshAllowance)
      if (artVersion === 2n && !reservedPepe && round.staker && depositPepe !== null) {
        const available = await rpcCall(round.staker, stakerAbi, 'isPepeAvailable', [depositPepe])
        if (!available) { setSelectedPepe(null); throw new Error('That Pepe was just reserved. Choose another Pepe before depositing.') }
      }
      if (freshAllowance < amountWad) {
        setStep('approve')
        approvals.push({
          address: round.mix,
          abi: erc20Abi,
          functionName: 'approve',
          args: [round.controller, amountWad],
        })
      }
      setStep('tx')
      // rules v3 routing: green phase + membership goes through the proof-
      // carrying entry points (holder-proven members pass an empty proof).
      const green = rules3 && phaseNow === 0
      await writeWithApprovals({
        address: round.controller,
        abi: controllerAbi,
        functionName: artVersion === 2n ? (green ? 'predepositGreenWithPepe' : 'predepositWithPepe') : green ? 'predepositGreen' : 'predeposit',
        args: artVersion === 2n
          ? green ? [amountWad, depositPepe!, proof ?? []] : [amountWad, depositPepe!]
          : green ? [amountWad, proof ?? []] : [amountWad],
      }, approvals)
      if (latestDepositSession.current !== depositSession) return
      if (artVersion === 2n) await refreshPepe()
      if (latestDepositSession.current !== depositSession) return
      setAllowance(undefined)
      setStep('done')
      setNonce((n) => n + 1)
    } catch (e) {
      if (latestDepositSession.current !== depositSession) return
      fail(e)
    }
  }

  async function launch() {
    if (!round.controller) return
    setError(null)
    try {
      setLaunchStep('tx')
      await writeContractAsync({
        address: round.controller,
        abi: controllerAbi,
        functionName: 'launchPooledBuy',
      })
      setLaunchStep('done')
      setNonce((n) => n + 1)
    } catch (e) {
      setError(e instanceof Error ? e.message.slice(0, 140) : 'transaction failed')
      setLaunchStep('idle')
    }
  }

  useEffect(() => {
    if (step !== 'done') return
    setAmount('')
    const t = setTimeout(() => setStep('idle'), 2500)
    return () => clearTimeout(t)
  }, [step])

  const pct =
    pd && pd.cap > 0n ? Math.min(100, Number((pd.total * 10000n) / pd.cap) / 100) : 0

  const cta = !isConnected
    ? 'connect wallet'
    : greenLocked
      ? 'greenlist only'
    : rules3 && phaseNow === 2
      ? 'window over'
    : amountWad <= 0n
      ? 'enter an amount'
      : belowMinimum
        ? `this round requires at least ${wadToExact(minimum)} mixETH`
      : globalCapExceeded
        ? 'over the remaining round cap'
      : walletCapExceeded
        ? 'over the remaining wallet cap'
      : !balanceOk
        ? 'insufficient mixETH'
        : step === 'approve'
          ? 'approving…'
          : step === 'tx'
            ? 'confirm in wallet…'
            : hasAllowance
              ? `predeposit ${wadToExact(amountWad)} mixETH`
              : `approve ${wadToExact(amountWad)} mixETH`

  return (
    <div className={`pd-page space-y-4 ${variant === "alt" ? "alt-predeposit" : ""}`}>
      <RefBanner />
      <style>{`
        .pd-picker > div { height: 100%; }
        .pd-reserved-card {
          display: grid; place-items: center; width: min(100%, 300px); aspect-ratio: 1;
          padding: 4px; background: var(--bg-2); border: 1px solid var(--accent);
          border-radius: 12px; box-shadow: 0 5px 14px #0005;
          transform: rotate(-2deg); image-rendering: pixelated;
        }
        .pd-picker .grid { gap: 10px; }
        .pd-progress .mt-4 { margin-top: 10px; }
        .pd-clock > div { padding-top: 16px; padding-bottom: 20px; }
        @media (min-width: 1024px) {
          .pd-grid { align-items: stretch; }
          .pd-page > .px-1 { display: flex; align-items: center; gap: 24px; }
          .pd-page > .px-1 h2 { white-space: nowrap; }
          .pd-page > .px-1 p { margin: 0; max-width: 52rem; }
          .pd-picker .grid { max-width: 370px; margin-inline: auto; }
          .pd-picker > p { margin-top: 8px; }
          .pd-clock > div { padding-block: 8px; }
          .pd-clock h1 { font-size: 24px; margin-bottom: 6px; }
          .pd-clock .clock { transform: scale(.76); margin-block: -18px; }
          .pd-deposit .input-amount { padding: 8px 12px; font-size: 24px; }
          .pd-deposit .btn-primary { padding-block: 10px; }
        }
      `}</style>

      {pd && !pd.closed && endTime !== undefined && (
        phaseNow === 0 ? (
          variant === "alt" ? <section className="predeposit-state pd-green-state">
            <p>the greenlist is open.</p><h1>greenlisted frogs go first.</h1><AltClock deadline={greenEnd}/>
            {greenGate === 'member'
              ? <p>choose your pepe. everyone else joins at the open.</p>
              : <p>the greenlist phase is closed to new faces. the open window follows.</p>}
          </section> : <ClockBand label="greenlist clock" className="pd-clock pd-green-clock">
            <h1 className="mb-3 w-full max-w-4xl text-center font-display text-2xl leading-tight text-[#e8f0f7] sm:mb-3 sm:text-3xl">
              {remaining !== undefined && remaining > 0 ? 'greenlist window ends in:' : 'greenlist window elapsed'}
            </h1>
            <Clock key={round.controller} deadlineMs={Number(endTime) * 1000} label="time until the greenlist window ends" />
          </ClockBand>
        ) : variant === "alt" ? <section className="predeposit-state"><p>the opening is public.</p><h1>get in on the ground floor.</h1><AltClock deadline={endTime}/><p>choose your pepe. join the pooled first buy.</p></section> : <ClockBand label="predeposit clock" className="pd-clock">
          <h1 className="mb-3 w-full max-w-4xl text-center font-display text-2xl leading-tight text-[#e8f0f7] sm:mb-3 sm:text-3xl">
            {remaining !== undefined && remaining > 0 ? 'predeposit window ends in:' : 'predeposit window elapsed'}
          </h1>
          <Clock key={round.controller} deadlineMs={Number(endTime) * 1000} label="time until predeposit window ends" />
        </ClockBand>
      )}
      {/* a. header */}
      <div className="px-1">
        <div className="flex flex-wrap items-center gap-2">
          <h2 className="text-2xl font-black text-slate-900">predeposit</h2>
        </div>
        <p className="mt-1 font-body text-sm leading-relaxed text-slate-500">
          get your frog in the door. deposit mixETH before launch to join the pooled first buy. after launch, claim your share as lePSP, locked earning PSP held in a pepe NFT.
        </p>
      </div>

      <div className="pd-grid grid min-w-0 gap-4 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.05fr)]">
          {/* b. progress */}
          <div className="pd-progress card p-4 lg:col-start-2 lg:row-start-1">
            <div className="mb-1 flex justify-between text-[11px] font-bold uppercase tracking-wide text-slate-400">
              <span>{uncapped ? 'pooled buy-in' : 'window fill'}</span>
              <span className="min-w-0 break-all text-right">{pd ? predepositProgress(pd.total, pd.cap, predepositVersion) : '…'}</span>
            </div>
            {!uncapped && <div className="h-2 overflow-hidden rounded-full bg-sky-100">
              <div
                className="h-full rounded-full bg-gradient-to-r from-sky-400 to-emerald-400"
                style={{ width: `${pct}%` }}
              />
            </div>}
            {rules3 && pd && pd.greenTotal !== undefined && !uncapped && <div className="pd-green-share h-1.5 overflow-hidden rounded-full bg-sky-100" aria-hidden="true">
              <div className="h-full rounded-full bg-emerald-500" style={{ width: `${Math.min(100, Number((pd.greenTotal * 10000n) / (pd.cap > 0n ? pd.cap : 1n)) / 100)}%` }} />
            </div>}
            {pd && <p className="mt-2 break-all text-xs text-slate-500">
              {predepositRemainder(pd.total, pd.cap, predepositVersion)}
              {rules3 && pd.greenTotal !== undefined ? ` · ${wadToExact(pd.greenTotal)} greenlist mixETH` : ''}
            </p>}
            <div className="mt-4 grid grid-cols-2 gap-3">
              <div className="pd-stat rounded-2xl bg-white/80 shadow-sm">
                <div className="text-lg font-black text-slate-900">
                  {depositors !== undefined ? depositors.toString() : '…'}
                </div>
                <div className="text-[11px] font-bold uppercase tracking-wide text-slate-400">depositors</div>
              </div>
              <div className="pd-stat rounded-2xl bg-white/80 shadow-sm">
                <div className="flex flex-wrap items-center gap-2 break-all text-lg font-black text-slate-900">
                  {!isConnected ? '—' : myDep === undefined ? '…' : wadToExact(myDep.mixETHAmount)}
                  {myDep?.claimed && <span className="text-xs font-bold text-emerald-600">claimed ✓</span>}
                </div>
                <div className="text-[11px] font-bold uppercase tracking-wide text-slate-400">your predeposit (mix)</div>
              </div>
            </div>
          </div>

          <div ref={pickerRef} className="pd-picker min-w-0 lg:col-start-1 lg:row-start-1 lg:row-span-2">
          {artVersion === 2n && !pd?.closed && (
            reservedPepe && reservedPepe > 0n ? (
              <div className="card flex flex-col items-center gap-5 p-5 text-center" aria-label="your reserved pepe">
                <div>
                  <h2 className="font-display text-2xl leading-tight">reserved position</h2>
                  <p className="mt-1 font-body text-xs text-text-lo">your pepe is reserved. every top-up goes into this position.</p>
                </div>
                <div className="flex w-full flex-1 items-center justify-center px-2 py-2">
                  <div className="pd-reserved-card">
                    {dnaVersion !== undefined ? <img className="block aspect-square h-full w-full rounded-lg" alt="Your reserved Pepe" src={`data:image/svg+xml,${encodeURIComponent(renderPepeSvg(dnaOfId(reservedPepe), dnaVersion))}`} />
                      : <span className="text-xs text-text-lo">loading pepe…</span>}
                  </div>
                </div>
              </div>
            ) : <PepePicker round={round} selected={selectedPepe} onSelect={setSelectedPepe}
                  seed={pickerSeed} onReroll={() => { setSelectedPepe(null); setPickerSeed(s => s + 1) }}
                  disabled={busy} actionLabel="deposit" attention={variant === 'alt' ? needsPepe : undefined} />
          )}

          </div>
          {/* c. deposit */}
          <div className="pd-deposit card p-4 lg:col-start-2 lg:row-start-2">
            <div className="flex items-center justify-between">
              <h2 className="text-lg font-black text-slate-900">deposit</h2>
              <div className="flex shrink-0 items-center gap-1 rounded-2xl bg-white px-4 py-2 shadow-sm">
                <MixLogo px={18} /> <span className="text-sm font-black text-slate-700">mixETH</span>
              </div>
            </div>

            {greenGate === 'member' && (
              <p className="mt-2 text-xs font-bold text-emerald-600">
                {prevHolder === true ? 'you held PSP last round — the green door is open.' : 'you are on this round’s greenlist.'}
              </p>
            )}

            <div className="mt-3 rounded-2xl border border-sky-100 bg-sky-50/60 p-3">
              <div className="flex items-center justify-between text-xs font-bold text-slate-400">
                <span>commit</span>
                <button
                  type="button"
                  title="fill the most you can deposit"
                  onClick={() => setAmount(wadToExact(maxDeposit))}
                  disabled={busy || maxDeposit === undefined || maxDeposit <= 0n}
                  className="rounded-md px-1.5 py-0.5 transition hover:bg-sky-100 hover:text-sky-600 disabled:opacity-40"
                >
                  balance {fmtAmount(mixBal)}
                  {maxDeposit !== undefined && maxDeposit > 0n && (
                    <span className="ml-1 text-[10px] text-sky-500">MAX</span>
                  )}
                </button>
              </div>
              <input
                className="input-amount mt-2"
                placeholder="0.0"
                value={amount}
                inputMode="decimal"
                onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ''))}
                onBlur={onAmountBlur}
                aria-invalid={variant === 'alt' && amountInvalid ? true : undefined}
              />
              <AmountSlider amount={amount} maximum={maxDeposit} onChange={setAmount} disabled={busy || !!pd?.closed} label="share of your available deposit" />
              {rules3 && phaseWalletHeadroom !== undefined && pd && myDep !== undefined ? (
                <div className="mt-1 break-words text-[11px] font-bold text-slate-400">
                  {phaseNow === 0
                    ? `greenlist cap ${wadToExact(pd.greenPerWallet ?? 0n)} mix · yours ${wadToExact(myGreen)} · ${wadToExact(phaseWalletHeadroom)} left`
                    : `open cap ${wadToExact(pd.openPerWallet ?? 0n)} mix per wallet · yours ${wadToExact(myOpen)} · ${wadToExact(phaseWalletHeadroom)} left`}
                </div>
              ) : walletCap !== undefined && walletCap > 0n && myDep !== undefined && (
                <div className="mt-1 break-words text-[11px] font-bold text-slate-400">
                  per-wallet cap {wadToExact(walletCap)} mix · yours {wadToExact(myDep.mixETHAmount)} ·{' '}
                  {wadToExact(capHeadroom(myDep.mixETHAmount, walletCap))} left
                </div>
              )}
              {greenGate === 'unknown' && hasCsvRoot && (
                <div className="pd-green-upload mt-2">
                  <label className="block text-[11px] font-bold text-slate-400" htmlFor="pd-greenlist-file">
                    on the greenlist? load the round's greenlist file to prove it:
                  </label>
                  <input
                    id="pd-greenlist-file"
                    className="mt-1 w-full text-xs"
                    type="file"
                    accept="application/json,.json"
                    disabled={busy}
                    onChange={(e) => onGreenlistFile(e.target.files?.[0])}
                  />
                  {uploadError && <p role="alert" className="mt-1 text-xs font-bold text-rose-500">{uploadError}</p>}
                </div>
              )}
              {greenGate === 'closed' && (
                <p className="mt-2 break-words text-xs font-bold text-slate-500">
                  the greenlist phase is closed to new faces. the open window starts when the green clock hits zero — {wadToExact(pd?.openPerWallet ?? 10n * 10n ** 18n)} mixETH per wallet.
                </p>
              )}
              {globalCapExceeded && <p className="mt-1 break-words text-xs font-bold text-rose-500">
                {wadToExact(globalRemaining)} mixETH remaining in this round
              </p>}
              {legacyDust && <p className="mt-2 text-xs text-slate-500">
                This deployed round requires at least {wadToExact(minimum)} mixETH per deposit.
                The remainder is smaller than that; launch opens when the window ends.
              </p>}
              {amountWad > 0n && !balanceOk && (
                <div className="mt-1 text-xs font-bold text-rose-500">insufficient balance</div>
              )}
              {amountWad > 0n && walletCapExceeded && (
                <div className="mt-1 text-xs font-bold text-rose-500">
                  over the per-wallet cap — {wadToExact(walletCap === undefined ? undefined : capHeadroom(myDepAmount, walletCap))} mixETH remaining
                </div>
              )}
            </div>

            {(FAUCET_ENABLED || TESTNET_ETH_FAUCET) && (
              <div className="mt-3 flex flex-wrap items-center justify-between gap-2 font-body">
                {FAUCET_ENABLED && <FaucetButton />}
                {TESTNET_ETH_FAUCET && (
                  <a
                    href={NATIVE_ETH_FAUCET_URL}
                    target="_blank"
                    rel="noreferrer"
                    className="text-xs text-text-lo underline underline-offset-4"
                  >
                    get {CHAIN_ID === 84532 ? 'base ' : ''}sepolia ETH ↗
                  </a>
                )}
              </div>
            )}

            <button className="btn-primary mt-4 w-full break-words" disabled={!canSubmit} onClick={runDeposit}>
              {step === 'done' ? '✅ deposited' : cta}
            </button>
            {pd?.closed && (
              <div className="mt-2 text-xs font-bold text-slate-400">predeposits are closed for this round.</div>
            )}
          </div>

          {/* d. launch / claim */}
          {(pd?.launchable || launched) && (
            <div className="card p-4 lg:col-span-2">
              <h2 className="text-lg font-black text-slate-900">{launched ? 'round launched' : 'launch'}</h2>
              {launched ? (
                <>
                  {myDep && myDep.claimed ? (
                    <>
                      <p className="mt-1 text-sm text-slate-500">
                        ✅ claimed. your pepe is holding your first bag on the stake page.
                        your lePSP earns fees. request withdrawal to start its exit schedule.
                      </p>
                      <Link to="/stake" className="btn-primary mt-3 block w-full text-center">
                        see your pepe →
                      </Link>
                    </>
                  ) : myDep && myDep.mixETHAmount > 0n ? (
                    <>
                      <p className="mt-1 text-sm text-slate-500">
                        your first bag is waiting. claim your share of the launch PSP into a pepe NFT,
                        with lePSP earning fees inside.
                      </p>
                      <Link to="/stake" className="btn-primary mt-3 block w-full text-center">
                        claim your PSP on the stake page →
                      </Link>
                    </>
                  ) : (
                    <p className="mt-1 text-sm text-slate-500">
                      the round is live. buy PSP on the play page to join the ladder.
                    </p>
                  )}
                </>
              ) : (
                <>
                  <p className="mt-1 text-sm text-slate-500">
                    {uncapped ? 'the window is over. anyone may launch the pooled genesis buy.' : 'cap reached or window over. anyone may launch the pooled genesis buy.'}
                  </p>
                  <button className="btn-primary mt-3 w-full" disabled={launchStep === 'tx'} onClick={launch}>
                    {launchStep === 'done' ? '✅ launched' : launchStep === 'tx' ? 'confirm in wallet…' : 'launch pooled buy'}
                  </button>
                </>
              )}
            </div>
          )}

          {isConnected && artVersion === 2n && reservedPepe === 0n && selectedPepe === null && !pd?.closed && (
            <p role="alert" className="mt-3 font-body text-sm text-phase-critical">Choose your Pepe above before depositing.</p>
          )}
          {error && <div className="break-words rounded-xl bg-rose-50 p-3 text-xs font-bold text-rose-500">{error}</div>}
      </div>
    </div>
  )
}
