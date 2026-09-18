import AmountSlider from '../components/AmountSlider'
import { AltClock } from '../alt/AltCommon'
import { usePepeDnaVersion } from '../lib/usePepeDnaVersion'
import { capHeadroom, predepositUncapped, predepositLimit, predepositAmountAllowed, predepositProgress, predepositRemainder } from '../lib/predeposit'
import { usePredepositRules } from '../lib/usePredepositMinimum'
import { predepositResult } from '../lib/chainResults'
import { useConfirmedWrite } from '../lib/useConfirmedWrite'
import { useEffect, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { useAccount } from 'wagmi'
import { controllerAbi, erc20Abi, stakerAbi } from '../lib/abi'
import { rpcCall } from '../lib/rpc'
import { CHAIN_ID, FAUCET_ENABLED, NATIVE_ETH_FAUCET_URL, TESTNET_ETH_FAUCET } from '../lib/config'
import { useRound, useBalances } from '../lib/useRound'
import { useNow } from '../phase/PhaseEngine'
import { fmtAmount, parseAmountToWad, wadToExact } from '../lib/format'
import { RefBanner } from '../components/ReferralCard'
import { FaucetButton } from '../components/Topbar'
import MixLogo from '../components/MixLogo'
import Clock from '../components/Clock'
import ClockBand from '../components/ClockBand'
import PepePicker from '../components/PepePicker'
import { useQuery } from '@tanstack/react-query'
import { renderPepeSvg } from '../lib/pepeRender'
import { dnaOfId } from '../components/PepePicker'
import StakeStyles from './stake/StakeStyles'

type Step = 'idle' | 'approve' | 'tx' | 'done'

interface PdState {
  total: bigint
  cap: bigint
  startTime: bigint
  closed: boolean
  capReached: boolean
  windowOver: boolean
  launchable: boolean
}


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
  useEffect(() => { setSelectedPepe(null); setStep('idle'); setError(null) }, [address, round.controller])
  const depositPepe = reservedPepe && reservedPepe > 0n ? reservedPepe : selectedPepe

  /// predepositState + duration + depositor count + own deposit, polled like
  /// every other read in this app (useReadContracts sits idle on custom chains)
  const [pd, setPd] = useState<PdState | undefined>(undefined)
  const [duration, setDuration] = useState<bigint | undefined>(undefined)
  const [depositors, setDepositors] = useState<bigint | undefined>(undefined)
  const [myDep, setMyDep] = useState<{ mixETHAmount: bigint; claimed: boolean } | undefined>(undefined)
  const [allowance, setAllowance] = useState<bigint | undefined>(undefined)
  const [nonce, setNonce] = useState(0)

  useEffect(() => {
    setMyDep(undefined)
    setPd(undefined)
    setDuration(undefined)
    setDepositors(undefined)
    if (!round.controller) return
    let dead = false
    async function tick() {
      try {
        const [st, dur, cnt] = await Promise.all([
          rpcCall(round.controller!, controllerAbi, 'predepositState') as Promise<
            [bigint, bigint, bigint, boolean, boolean, boolean, boolean]
          >,
          rpcCall(round.controller!, controllerAbi, 'PREDEPOSIT_DURATION') as Promise<bigint>,
          rpcCall(round.controller!, controllerAbi, 'totalPredepositors') as Promise<bigint>,
        ])
        let dep: { mixETHAmount: bigint; claimed: boolean } | undefined
        if (address) {
          dep = predepositResult(await rpcCall(round.controller!, controllerAbi, 'predeposits', [address]))
        }
        if (dead) return
        setPd({
          total: st[0],
          cap: st[1],
          startTime: st[2],
          closed: st[3],
          capReached: st[4],
          windowOver: st[5],
          launchable: st[6],
        })
        setDuration(dur)
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
  }, [round.controller, address, nonce])

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
  const walletCapExceeded =
    walletCap !== undefined && walletCap > 0n && amountWad > 0n && myDepAmount + amountWad > walletCap
  /// the most THIS wallet can still deposit: balance ∧ wallet headroom ∧ global headroom
  const maxDeposit = mixBal !== undefined && pd && walletCap !== undefined && myDep !== undefined
    ? predepositLimit(mixBal, pd.total, pd.cap, walletCap, myDepAmount, predepositVersion) : undefined
  const uncapped = !!pd && predepositUncapped(predepositVersion, pd.cap)
  const globalRemaining = pd && !uncapped ? capHeadroom(pd.total, pd.cap) : undefined
  const globalCapExceeded = globalRemaining !== undefined && amountWad > globalRemaining
  const belowMinimum = amountWad > 0n && amountWad < minimum
  const legacyDust = globalRemaining !== undefined && globalRemaining > 0n && globalRemaining < minimum

  const endTime = pd && duration !== undefined ? pd.startTime + duration : undefined
  const remaining = endTime !== undefined ? Math.max(0, Number(endTime - BigInt(nowSec))) : undefined
  const mode = round.mode
  const launched = pd?.closed === true && (mode ?? 0) >= 1
  const canSubmit =
    isConnected && !artLoading && !!round.controller && predepositAmountAllowed(amountWad, minimum, maxDeposit) && balanceOk && !walletCapExceeded && !busy && !pd?.closed && (artVersion !== 2n || (reservedPepe !== undefined && depositPepe !== null))

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
      await writeWithApprovals({
        address: round.controller,
        abi: controllerAbi,
        functionName: artVersion === 2n ? 'predepositWithPepe' : 'predeposit',
        args: artVersion === 2n ? [amountWad, depositPepe!] : [amountWad],
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
      <StakeStyles />
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
          .pd-deposit .st-input { padding: 8px 12px; font-size: 24px; }
          .pd-deposit .st-btn { padding-block: 10px; }
        }
      `}</style>

      {pd && !pd.closed && endTime !== undefined && (
        variant === "alt" ? <section className="predeposit-state"><p>the opening is public.</p><h1>get in on the ground floor.</h1><AltClock deadline={endTime}/><p>choose your pepe. join the pooled first buy.</p></section> : <ClockBand label="predeposit clock" className="pd-clock">
          <h1 className="mb-3 w-full max-w-4xl text-center font-display text-2xl leading-tight text-[#e8f0f7] sm:mb-3 sm:text-3xl">
            {remaining !== undefined && remaining > 0 ? 'predeposit window ends in:' : 'predeposit window elapsed'}
          </h1>
          <Clock key={round.controller} deadlineMs={Number(endTime) * 1000} label="time until predeposit window ends" />
        </ClockBand>
      )}
      {/* a. header */}
      <div className="px-1">
        <div className="flex flex-wrap items-center gap-2">
          <h2 className="text-2xl font-semibold text-text-hi">predeposit</h2>
        </div>
        <p className="mt-1 font-body text-sm leading-relaxed text-text-lo">
          get your frog in the door. deposit mixETH before launch to join the opening buy. everyone in it pays the same price and nobody can front-run it. when the round launches, your share arrives already staked as lePSP (locked PSP that earns fees) inside a pepe NFT. 10% of the pool seeds the prize pot; the other 90% buys the PSP.
        </p>
      </div>

      <div className="pd-grid grid min-w-0 gap-4 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.05fr)]">
          {/* b. progress */}
          <div className="pd-progress card p-4 lg:col-start-2 lg:row-start-1">
            <div className="mb-1 flex justify-between text-[11px] font-semibold text-text-lo">
              <span>{uncapped ? 'pooled buy-in' : 'window fill'}</span>
              <span className="min-w-0 break-all text-right">{pd ? predepositProgress(pd.total, pd.cap, predepositVersion) : '…'}</span>
            </div>
            {!uncapped && <div className="h-2 overflow-hidden rounded-full bg-bg-2">
              <div
                className="h-full rounded-full bg-accent"
                style={{ width: `${pct}%` }}
              />
            </div>}
            {pd && <p className="mt-2 break-all text-xs text-text-lo">{predepositRemainder(pd.total, pd.cap, predepositVersion)}</p>}
            <div className="mt-4 grid grid-cols-2 gap-3">
              <div className="pd-stat rounded-xl bg-bg-2">
                <div className="text-lg font-semibold text-text-hi">
                  {depositors !== undefined ? depositors.toString() : '…'}
                </div>
                <div className="text-[11px] font-semibold text-text-lo">depositors</div>
              </div>
              <div className="pd-stat rounded-xl bg-bg-2">
                <div className="flex flex-wrap items-center gap-2 break-all text-lg font-semibold text-text-hi">
                  {!isConnected ? '—' : myDep === undefined ? '…' : wadToExact(myDep.mixETHAmount)}
                  {myDep?.claimed && <span className="text-xs font-bold text-pepe">claimed ✓</span>}
                </div>
                <div className="text-[11px] font-semibold text-text-lo">your predeposit (mix)</div>
              </div>
            </div>
          </div>

          <div className="pd-picker min-w-0 lg:col-start-1 lg:row-start-1 lg:row-span-2">
          {artVersion === 2n && !pd?.closed && (
            reservedPepe && reservedPepe > 0n ? (
              <div className="rounded-2xl border border-line bg-bg-1 flex flex-col items-center gap-5 p-5 text-center" aria-label="your reserved pepe">
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
                  disabled={busy} actionLabel="deposit" />
          )}
          {!(artVersion === 2n && !pd?.closed) && (
            <div className="flex h-full flex-col rounded-2xl border border-line bg-bg-1 p-5">
              <h2 className="font-display text-2xl leading-tight">what you get</h2>
              <ul className="mt-4 space-y-3 text-sm leading-relaxed text-text-lo">
                <li><span className="text-text-hi">the opening price, same for everyone.</span> the whole pool buys in one transaction at launch. no head start, no sales pitch.</li>
                <li><span className="text-text-hi">a pepe holding your PSP.</span> your share lands staked as lePSP the moment the round launches and earns 60% of every trading fee from the first trade.</li>
                <li><span className="text-text-hi">a seed for the pot.</span> 10% of the pool opens the prize pot; that pot prices every ticket in the round.</li>
                <li><span className="text-text-hi">your money back if nothing happens.</span> {pd?.closed ? 'deposits are closed for this round.' : 'until launch, deposits stay in the round contract. anyone can launch once the window ends.'}</li>
              </ul>
            </div>
          )}

          </div>
          {/* c. deposit */}
          <div className="pd-deposit card p-4 lg:col-start-2 lg:row-start-2">
            <div className="flex items-center justify-between">
              <h2 className="text-lg font-semibold text-text-hi">deposit</h2>
              <div className="flex shrink-0 items-center gap-1 rounded-xl border border-line bg-bg-2 px-4 py-2">
                <MixLogo px={18} /> <span className="text-sm font-semibold text-text-hi">mixETH</span>
              </div>
            </div>

            <div className="mt-3 rounded-xl border border-line bg-bg-2 p-3">
              <div className="flex items-center justify-between text-xs font-bold text-text-lo">
                <span>commit</span>
                <button
                  type="button"
                  title="fill the most you can deposit"
                  onClick={() => setAmount(wadToExact(maxDeposit))}
                  disabled={busy || maxDeposit === undefined || maxDeposit <= 0n}
                  className="rounded-md px-1.5 py-0.5 transition hover:bg-bg-1 hover:text-text-hi disabled:opacity-40"
                >
                  balance {fmtAmount(mixBal)}
                  {maxDeposit !== undefined && maxDeposit > 0n && (
                    <span className="ml-1 text-[10px] text-accent">MAX</span>
                  )}
                </button>
              </div>
              <input
                className="st-input mt-2"
                placeholder="0.0"
                value={amount}
                inputMode="decimal"
                onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ''))}
              />
              <AmountSlider amount={amount} maximum={maxDeposit} onChange={setAmount} disabled={busy || !!pd?.closed} label="share of your available deposit" />
              {walletCap !== undefined && walletCap > 0n && myDep !== undefined && (
                <div className="mt-1 break-words text-[11px] font-bold text-text-lo">
                  per-wallet cap {wadToExact(walletCap)} mix · yours {wadToExact(myDep.mixETHAmount)} ·{' '}
                  {wadToExact(capHeadroom(myDep.mixETHAmount, walletCap))} left
                </div>
              )}
              {globalCapExceeded && <p className="mt-1 break-words text-xs font-bold text-phase-critical">
                {wadToExact(globalRemaining)} mixETH remaining in this round
              </p>}
              {legacyDust && <p className="mt-2 text-xs text-text-lo">
                This deployed round requires at least {wadToExact(minimum)} mixETH per deposit.
                The remainder is smaller than that; launch opens when the window ends.
              </p>}
              {amountWad > 0n && !balanceOk && (
                <div className="mt-1 text-xs font-bold text-phase-critical">insufficient balance</div>
              )}
              {amountWad > 0n && walletCapExceeded && (
                <div className="mt-1 text-xs font-bold text-phase-critical">
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

            <button className="st-btn st-btn-primary mt-4 w-full break-words" disabled={!canSubmit} onClick={runDeposit}>
              {step === 'done' ? '✅ deposited' : cta}
            </button>
            {pd?.closed && (
              <div className="mt-2 text-xs font-bold text-text-lo">predeposits are closed for this round.</div>
            )}
          </div>

          {/* d. launch / claim */}
          {(pd?.launchable || launched) && (
            <div className="rounded-2xl border border-line bg-bg-1 p-4 lg:col-span-2">
              <h2 className="text-lg font-semibold text-text-hi">{launched ? 'round launched' : 'launch'}</h2>
              {launched ? (
                <>
                  {myDep && myDep.claimed ? (
                    <>
                      <p className="mt-1 text-sm text-text-lo">
                        ✅ claimed. your pepe is holding your first bag on the stake page.
                        your lePSP earns fees. request withdrawal to start its exit schedule.
                      </p>
                      <Link to="/stake" className="st-btn st-btn-primary mt-3 block w-full text-center">
                        see your pepe →
                      </Link>
                    </>
                  ) : myDep && myDep.mixETHAmount > 0n ? (
                    <>
                      <p className="mt-1 text-sm text-text-lo">
                        your first bag is waiting. claim your share of the launch PSP into a pepe NFT,
                        with lePSP earning fees inside.
                      </p>
                      <Link to="/stake" className="st-btn st-btn-primary mt-3 block w-full text-center">
                        claim your PSP on the stake page →
                      </Link>
                    </>
                  ) : (
                    <p className="mt-1 text-sm text-text-lo">
                      the round is live. buy PSP on the play page to join the ladder.
                    </p>
                  )}
                </>
              ) : (
                <>
                  <p className="mt-1 text-sm text-text-lo">
                    {uncapped ? 'the window is over. anyone may launch the pooled genesis buy.' : 'cap reached or window over. anyone may launch the pooled genesis buy.'}
                  </p>
                  <button className="st-btn st-btn-primary mt-3 w-full" disabled={launchStep === 'tx'} onClick={launch}>
                    {launchStep === 'done' ? '✅ launched' : launchStep === 'tx' ? 'confirm in wallet…' : 'launch pooled buy'}
                  </button>
                </>
              )}
            </div>
          )}

          {isConnected && artVersion === 2n && reservedPepe === 0n && selectedPepe === null && !pd?.closed && (
            <p role="alert" className="mt-3 font-body text-sm text-phase-critical">Choose your Pepe above before depositing.</p>
          )}
          {error && <div className="break-words rounded-xl border border-phase-critical/40 p-3 text-xs font-bold text-phase-critical">{error}</div>}
      </div>
    </div>
  )
}
