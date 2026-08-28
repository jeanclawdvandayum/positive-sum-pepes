import { useEffect, useState } from 'react'
import { useAccount, useBalance, useWriteContract } from 'wagmi'
import { controllerAbi, erc20Abi, zapInAbi } from '../lib/abi'
import { rpcCall } from '../lib/rpc'
import { ADDRESSES, CHAIN_ID, FAUCET_ENABLED, SEPOLIA_ETH_FAUCET_URL } from '../lib/config'
import { useRound, useBalances } from '../lib/useRound'
import { fmtAmount, fmtCountdown, parseAmountToWad } from '../lib/format'
import ReferralCard, { RefBanner } from '../components/ReferralCard'
import { FaucetButton } from '../components/Topbar'

type Path = 'MIX' | 'ETH'
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
  const { address, isConnected } = useAccount()
  const { mix: mixBal } = useBalances(round.token, round.mix)
  const { data: ethBal } = useBalance({ address })

  /// predepositState + duration + depositor count + own deposit, polled like
  /// every other read in this app (useReadContracts sits idle on custom chains)
  const [pd, setPd] = useState<PdState | undefined>(undefined)
  const [duration, setDuration] = useState<bigint | undefined>(undefined)
  const [depositors, setDepositors] = useState<bigint | undefined>(undefined)
  const [myDep, setMyDep] = useState<{ mixETHAmount: bigint; claimed: boolean } | undefined>(undefined)
  const [allowance, setAllowance] = useState<bigint | undefined>(undefined)
  const [nonce, setNonce] = useState(0)

  useEffect(() => {
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
          dep = (await rpcCall(round.controller!, controllerAbi, 'predeposits', [address])) as {
            mixETHAmount: bigint
            claimed: boolean
          }
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

  /// 1s heartbeat for the countdown
  const [nowSec, setNowSec] = useState(() => Math.floor(Date.now() / 1000))
  useEffect(() => {
    const t = setInterval(() => setNowSec(Math.floor(Date.now() / 1000)), 1000)
    return () => clearInterval(t)
  }, [])

  const [path, setPath] = useState<Path>('MIX')
  const [amount, setAmount] = useState('')
  const [step, setStep] = useState<Step>('idle')
  const [launchStep, setLaunchStep] = useState<'idle' | 'tx' | 'done'>('idle')
  const [claimStep, setClaimStep] = useState<'idle' | 'tx' | 'done'>('idle')
  const [error, setError] = useState<string | null>(null)
  const { writeContractAsync } = useWriteContract()

  const amountWad = parseAmountToWad(amount)
  const hasAllowance = allowance !== undefined && amountWad > 0n && allowance >= amountWad
  const balanceOk =
    amountWad > 0n &&
    (path === 'ETH' ? ethBal === undefined || amountWad <= ethBal.value : mixBal === undefined || amountWad <= mixBal)
  const busy = step === 'approve' || step === 'tx'

  const endTime = pd && duration !== undefined ? pd.startTime + duration : undefined
  const remaining = endTime !== undefined ? Math.max(0, Number(endTime - BigInt(nowSec))) : undefined
  const mode = round.mode
  const badge = mode !== undefined ? MODE_BADGES[mode] : undefined
  const launched = pd?.closed === true && (mode ?? 0) >= 1
  const canSubmit =
    isConnected && !!round.controller && amountWad > 0n && balanceOk && !busy && !pd?.closed && !pd?.launchable

  async function fail(e: unknown) {
    setError(e instanceof Error ? e.message.slice(0, 140) : 'transaction failed')
    setStep('idle')
  }

  async function runDeposit() {
    if (!round.controller || amountWad <= 0n) return
    setError(null)
    try {
      if (path === 'ETH') {
        setStep('tx')
        await writeContractAsync({
          address: ADDRESSES.zapIn,
          abi: zapInAbi,
          functionName: 'zapInPredeposit',
          args: [round.controller, 0n],
          value: amountWad,
        })
      } else {
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
      }
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

  async function claim() {
    if (!round.controller) return
    setError(null)
    try {
      setClaimStep('tx')
      await writeContractAsync({
        address: round.controller,
        abi: controllerAbi,
        functionName: 'claimPredepositPSP',
      })
      setClaimStep('done')
      setNonce((n) => n + 1)
    } catch (e) {
      setError(e instanceof Error ? e.message.slice(0, 140) : 'transaction failed')
      setClaimStep('idle')
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
      : !balanceOk
        ? `insufficient ${path === 'ETH' ? 'ETH' : 'mixETH'}`
        : step === 'approve'
          ? 'approving…'
          : step === 'tx'
            ? 'confirm in wallet…'
            : path === 'ETH'
              ? `predeposit ${fmtAmount(amountWad)} ETH`
              : hasAllowance
                ? `predeposit ${fmtAmount(amountWad)} mixETH`
                : `approve ${fmtAmount(amountWad)} mixETH`

  return (
    <div className="space-y-4">
      <RefBanner />

      {/* a. header */}
      <div className="card p-5">
        <div className="flex flex-wrap items-center gap-2">
          <h1 className="text-2xl font-black text-slate-900">predeposit</h1>
          {round.id > 0n && <span className="chip bg-sky-100 text-sky-700">round #{round.id.toString()}</span>}
          {badge && <span className={`chip ${badge.cls}`}>{badge.label}</span>}
          {pd?.capReached && <span className="chip bg-emerald-100 text-emerald-700">cap reached</span>}
          {pd?.windowOver && <span className="chip bg-amber-100 text-amber-700">window over</span>}
          {pd && !pd.closed && remaining !== undefined && (
            <span className="chip border border-sky-100 bg-white text-slate-500">⏳ {fmtCountdown(remaining)}</span>
          )}
        </div>
        <p className="mt-1 text-sm text-slate-500">
          commit mixETH (or plain ETH) before launch — everything pools into the genesis buy, then claim your PSP.
        </p>
      </div>

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
        <div className="space-y-4">
          {/* b. progress */}
          <div className="card p-5">
            <div className="mb-1 flex justify-between text-[11px] font-bold uppercase tracking-wide text-slate-400">
              <span>window fill</span>
              <span>{pd ? `${fmtAmount(pd.total)} / ${fmtAmount(pd.cap)} mix` : '…'}</span>
            </div>
            <div className="h-2 overflow-hidden rounded-full bg-sky-100">
              <div
                className="h-full rounded-full bg-gradient-to-r from-sky-400 to-emerald-400"
                style={{ width: `${pct}%` }}
              />
            </div>
            <div className="mt-4 grid grid-cols-2 gap-3">
              <div className="rounded-2xl bg-white/80 px-3 py-3 shadow-sm">
                <div className="text-lg font-black text-slate-900">
                  {depositors !== undefined ? depositors.toString() : '…'}
                </div>
                <div className="text-[11px] font-bold uppercase tracking-wide text-slate-400">depositors</div>
              </div>
              <div className="rounded-2xl bg-white/80 px-3 py-3 shadow-sm">
                <div className="flex items-center gap-2 text-lg font-black text-slate-900">
                  {!isConnected ? '—' : myDep === undefined ? '…' : fmtAmount(myDep.mixETHAmount)}
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
              <div className="flex rounded-full bg-sky-50 p-1">
                {(['MIX', 'ETH'] as Path[]).map((p) => (
                  <button
                    key={p}
                    onClick={() => setPath(p)}
                    disabled={step === 'approve' || step === 'tx'}
                    className={`rounded-full px-4 py-1 text-sm font-bold transition disabled:opacity-30 ${
                      path === p ? 'bg-white text-psp-deep shadow' : 'text-slate-400'
                    }`}
                  >
                    {p === 'MIX' ? 'mixETH' : 'ETH'}
                  </button>
                ))}
              </div>
            </div>

            <div className="mt-4 rounded-2xl border border-sky-100 bg-sky-50/60 p-4">
              <div className="flex items-center justify-between text-xs font-bold text-slate-400">
                <span>commit</span>
                <span>
                  balance{' '}
                  {path === 'ETH' ? (ethBal ? fmtAmount(ethBal.value, 4) : '…') : fmtAmount(mixBal)}
                </span>
              </div>
              <input
                className="input-amount mt-2"
                placeholder="0.0"
                value={amount}
                inputMode="decimal"
                onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ''))}
              />
              {amountWad > 0n && !balanceOk && (
                <div className="mt-1 text-xs font-bold text-rose-500">insufficient balance</div>
              )}
              {path === 'ETH' && (
                <div className="mt-1 text-xs text-slate-400">wraps to mixETH and predeposits in one tx</div>
              )}
            </div>

            {(FAUCET_ENABLED || CHAIN_ID === 11155111) && (
              <div className="mt-3 space-y-2">
                {FAUCET_ENABLED && <FaucetButton full />}
                {CHAIN_ID === 11155111 && (
                  <a
                    href={SEPOLIA_ETH_FAUCET_URL}
                    target="_blank"
                    rel="noreferrer"
                    className="btn-ghost w-full"
                  >
                    get sepolia ETH ↗
                  </a>
                )}
              </div>
            )}

            <button className="btn-primary mt-4 w-full" disabled={!canSubmit} onClick={runDeposit}>
              {step === 'done' ? '✅ deposited' : cta}
            </button>
            {pd?.closed && (
              <div className="mt-2 text-xs font-bold text-slate-400">predeposit window is closed — no new deposits.</div>
            )}
          </div>

          {/* d. launch / claim */}
          {(pd?.launchable || launched) && (
            <div className="card p-5">
              <h2 className="text-lg font-black text-slate-900">{launched ? 'round launched' : 'launch'}</h2>
              {launched ? (
                <>
                  <p className="mt-1 text-sm text-slate-500">
                    predeposit closed — your PSP is minted into the staker genesis lock (auto-locked, claims anytime).
                  </p>
                  <button className="btn-primary mt-3 w-full" disabled={claimStep === 'tx'} onClick={claim}>
                    {claimStep === 'done' ? '✅ claimed' : claimStep === 'tx' ? 'confirm in wallet…' : 'claim your PSP'}
                  </button>
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
