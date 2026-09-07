import { capHeadroom, predepositLimit, predepositAmountAllowed, predepositProgress, predepositRemainder } from '../lib/predeposit'
import { usePredepositMinimum } from '../lib/usePredepositMinimum'
import { predepositResult } from '../lib/chainResults'
import { useConfirmedWrite } from '../lib/useConfirmedWrite'
import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { useAccount } from 'wagmi'
import { controllerAbi, erc20Abi } from '../lib/abi'
import { rpcCall } from '../lib/rpc'
import { CHAIN_ID, FAUCET_ENABLED, NATIVE_ETH_FAUCET_URL, TESTNET_ETH_FAUCET } from '../lib/config'
import { useRound, useBalances } from '../lib/useRound'
import { useNow } from '../phase/PhaseEngine'
import { fmtAmount, parseAmountToWad, wadToExact } from '../lib/format'
import ReferralCard, { RefBanner } from '../components/ReferralCard'
import { FaucetButton } from '../components/Topbar'
import MixLogo from '../components/MixLogo'
import Clock from '../components/Clock'
import ClockBand from '../components/ClockBand'

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

const MODE_BADGES: Record<number, { label: string; cls: string }> = {
  0: { label: 'predeposit', cls: 'bg-sky-100 text-sky-700' },
  1: { label: 'active', cls: 'bg-emerald-100 text-emerald-700' },
  2: { label: 'flat', cls: 'bg-slate-100 text-slate-500' },
  3: { label: 'destroyed', cls: 'bg-amber-100 text-amber-700' },
}

export default function Predeposit() {
  const round = useRound()
  const minimum = usePredepositMinimum(round.controller)
  const { address, isConnected } = useAccount()
  const { mix: mixBal } = useBalances(round.token, round.mix)

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
  const { writeContractAsync } = useConfirmedWrite()

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
    ? predepositLimit(mixBal, pd.total, pd.cap, walletCap, myDepAmount) : undefined
  const globalRemaining = pd ? capHeadroom(pd.total, pd.cap) : undefined
  const globalCapExceeded = globalRemaining !== undefined && amountWad > globalRemaining
  const belowMinimum = amountWad > 0n && amountWad < minimum
  const legacyDust = globalRemaining !== undefined && globalRemaining > 0n && globalRemaining < minimum

  const endTime = pd && duration !== undefined ? pd.startTime + duration : undefined
  const remaining = endTime !== undefined ? Math.max(0, Number(endTime - BigInt(nowSec))) : undefined
  const mode = round.mode
  const badge = mode !== undefined ? MODE_BADGES[mode] : undefined
  const launched = pd?.closed === true && (mode ?? 0) >= 1
  const canSubmit =
    isConnected && !!round.controller && predepositAmountAllowed(amountWad, minimum, maxDeposit) && balanceOk && !walletCapExceeded && !busy && !pd?.closed

  async function fail(e: unknown) {
    setError(e instanceof Error ? e.message.slice(0, 140) : 'transaction failed')
    setStep('idle')
  }

  async function runDeposit() {
    if (!round.controller || !canSubmit) return
    setError(null)
    try {
      if (!round.mix) return
      if (!hasAllowance) {
        setStep('approve')
        await writeContractAsync({
          address: round.mix,
          abi: erc20Abi,
          functionName: 'approve',
          args: [round.controller, amountWad],
        })
      }
      setStep('tx')
      await writeContractAsync({
        address: round.controller,
        abi: controllerAbi,
        functionName: 'predeposit',
        args: [amountWad],
      })
      setStep('done')
      setNonce((n) => n + 1)
    } catch (e) {
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
    <div className="space-y-4">
      <RefBanner />

      {pd && !pd.closed && endTime !== undefined && (
        <ClockBand label="predeposit clock">
          <h1 className="mb-5 w-full max-w-4xl text-center font-display text-2xl leading-tight text-[#e8f0f7] sm:mb-6 sm:text-3xl">
            {remaining !== undefined && remaining > 0 ? 'predeposit window ends in:' : 'predeposit window elapsed'}
          </h1>
          <Clock key={round.controller} deadlineMs={Number(endTime) * 1000} label="time until predeposit window ends" />
        </ClockBand>
      )}
      {/* a. header */}
      <div className="card p-5">
        <div className="flex flex-wrap items-center gap-2">
          <h2 className="text-2xl font-black text-slate-900">predeposit</h2>
          {round.id > 0n && <span className="chip bg-sky-100 text-sky-700">round #{round.id.toString()}</span>}
          {badge && <span className={`chip ${badge.cls}`}>{badge.label}</span>}
          {pd?.capReached && <span className="chip bg-emerald-100 text-emerald-700">cap reached</span>}
          {pd?.windowOver && <span className="chip bg-amber-100 text-amber-700">window over</span>}
        </div>
        <p className="mt-1 text-sm text-slate-500">
          get your frog in the door. deposit mixETH before launch to join the pooled first buy. after launch, claim your share as PSP staked in a pepe NFT.
        </p>
      </div>

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
        <div className="space-y-4">
          {/* b. progress */}
          <div className="card p-5">
            <div className="mb-1 flex justify-between text-[11px] font-bold uppercase tracking-wide text-slate-400">
              <span>window fill</span>
              <span className="min-w-0 break-all text-right">{pd ? predepositProgress(pd.total, pd.cap) : '…'}</span>
            </div>
            <div className="h-2 overflow-hidden rounded-full bg-sky-100">
              <div
                className="h-full rounded-full bg-gradient-to-r from-sky-400 to-emerald-400"
                style={{ width: `${pct}%` }}
              />
            </div>
            {pd && <p className="mt-2 break-all text-xs text-slate-500">{predepositRemainder(pd.total, pd.cap)}</p>}
            <div className="mt-4 grid grid-cols-2 gap-3">
              <div className="rounded-2xl bg-white/80 px-3 py-3 shadow-sm">
                <div className="text-lg font-black text-slate-900">
                  {depositors !== undefined ? depositors.toString() : '…'}
                </div>
                <div className="text-[11px] font-bold uppercase tracking-wide text-slate-400">depositors</div>
              </div>
              <div className="rounded-2xl bg-white/80 px-3 py-3 shadow-sm">
                <div className="flex flex-wrap items-center gap-2 break-all text-lg font-black text-slate-900">
                  {!isConnected ? '—' : myDep === undefined ? '…' : wadToExact(myDep.mixETHAmount)}
                  {myDep?.claimed && <span className="text-xs font-bold text-emerald-600">claimed ✓</span>}
                </div>
                <div className="text-[11px] font-bold uppercase tracking-wide text-slate-400">your predeposit (mix)</div>
              </div>
            </div>
          </div>

          {/* c. deposit */}
          <div className="card p-5">
            <div className="flex items-center justify-between">
              <h2 className="text-lg font-black text-slate-900">deposit</h2>
              <div className="flex shrink-0 items-center gap-1 rounded-2xl bg-white px-4 py-2 shadow-sm">
                <MixLogo px={18} /> <span className="text-sm font-black text-slate-700">mixETH</span>
              </div>
            </div>

            <div className="mt-4 rounded-2xl border border-sky-100 bg-sky-50/60 p-4">
              <div className="flex items-center justify-between text-xs font-bold text-slate-400">
                <span>commit</span>
                <button
                  type="button"
                  title="fill the most you can deposit"
                  onClick={() => setAmount(wadToExact(maxDeposit))}
                  disabled={maxDeposit === undefined || maxDeposit <= 0n}
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
              />
              {walletCap !== undefined && walletCap > 0n && myDep !== undefined && (
                <div className="mt-1 break-words text-[11px] font-bold text-slate-400">
                  per-wallet cap {wadToExact(walletCap)} mix · yours {wadToExact(myDep.mixETHAmount)} ·{' '}
                  {wadToExact(capHeadroom(myDep.mixETHAmount, walletCap))} left
                </div>
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
              <div className="mt-3 space-y-2">
                {FAUCET_ENABLED && <FaucetButton full />}
                {TESTNET_ETH_FAUCET && (
                  <a
                    href={NATIVE_ETH_FAUCET_URL}
                    target="_blank"
                    rel="noreferrer"
                    className="btn-ghost w-full"
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
            <div className="card p-5">
              <h2 className="text-lg font-black text-slate-900">{launched ? 'round launched' : 'launch'}</h2>
              {launched ? (
                <>
                  {myDep && myDep.claimed ? (
                    <>
                      <p className="mt-1 text-sm text-slate-500">
                        ✅ claimed. your pepe is holding your first bag on the stake page.
                        the PSP stays staked until you request withdrawal, which starts the six-epoch exit.
                      </p>
                      <Link to="/stake" className="btn-primary mt-3 block w-full text-center">
                        see your pepe →
                      </Link>
                    </>
                  ) : myDep && myDep.mixETHAmount > 0n ? (
                    <>
                      <p className="mt-1 text-sm text-slate-500">
                        your first bag is waiting. claim your share of the launch PSP into a pepe NFT,
                        with the PSP staked inside.
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
                    cap reached or window over — anyone may launch the pooled genesis buy.
                  </p>
                  <button className="btn-primary mt-3 w-full" disabled={launchStep === 'tx'} onClick={launch}>
                    {launchStep === 'done' ? '✅ launched' : launchStep === 'tx' ? 'confirm in wallet…' : 'launch pooled buy'}
                  </button>
                </>
              )}
            </div>
          )}

          {error && <div className="break-words rounded-xl bg-rose-50 p-3 text-xs font-bold text-rose-500">{error}</div>}
        </div>

        {/* e. referral link generator */}
        <ReferralCard />
      </div>
    </div>
  )
}
