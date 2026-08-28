import { useEffect, useMemo, useState } from 'react'
import { useAccount, useWriteContract } from 'wagmi'
import { useRpcReads } from '../lib/useRpcReads'
import { erc20Abi, hookAbi, controllerAbi, zapInAbi, zapOutAbi, buildPoolKey } from '../lib/abi'
import { rpcCall } from '../lib/rpc'
import { ADDRESSES } from '../lib/config'
import { useRound, useBalances } from '../lib/useRound'
import { fmtAmount, parseAmountToWad, wadToExact } from '../lib/format'
import MixLogo from './MixLogo'
import { PspIcon } from './TokenIcon'

/// mixETH-only swap card (testnet): the mock mixETH has no ETH backing, so
/// every ETH leg (zapInBuy / zapOut / zapInPredeposit) is off the table —
/// buys go buyWithMix, sells go sellToMix, predeposit goes approve+predeposit.
type Side = 'buy' | 'sell'
type Step = 'idle' | 'approve' | 'swap' | 'waiting' | 'done'

export default function SwapCard() {
  const round = useRound()
  const { address, isConnected } = useAccount()
  const { psp: pspBal, mix: mixBal } = useBalances(round.token, round.mix)

  const [side, setSide] = useState<Side>('buy')
  const [amount, setAmount] = useState('')
  const [slippage, setSlippage] = useState(0.01)
  const [customSlip, setCustomSlip] = useState('')
  const [step, setStep] = useState<Step>('idle')
  const [error, setError] = useState<string | null>(null)
  const { writeContractAsync } = useWriteContract()

  /// Flat mode = one-way exit (scoopy 2026-08-29, fix #3): buying is
  /// disabled at the hook (BuyingDisabled) — force the sell side and lock
  /// the toggle so nobody wires a doomed buy.
  useEffect(() => {
    if (round.mode === 2) setSide('sell')
  }, [round.mode])

  const ZERO = '0x0000000000000000000000000000000000000000' as const
  const amountWad = parseAmountToWad(amount)
  const live = round.mode === 1 || round.mode === 2
  const predepositPhase = round.mode === 0

  /// mixETH entering the curve for this input
  const mixIn = useMemo(() => {
    if (side === 'sell') return 0n
    return amountWad
  }, [amountWad, side])

  const pspIn = side === 'sell' ? amountWad : 0n

  /// on-chain quote from the hook itself
  const [quoteRaw, setQuoteRaw] = useState<bigint | undefined>(undefined)
  const flat = round.mode === 2
  useEffect(() => {
    setQuoteRaw(undefined)
    if (!round.hook) return
    if (side === 'buy' ? mixIn <= 0n : pspIn <= 0n) return
    if (flat) {
      // Flat mode pays exact pro-rata (F-9, fee-free) — and the DEPLOYED
      // hook's views are curve-based, so compute locally from live state:
      // sell = psp×R/S · buy = mix×S/R (mirrors _handleFlatSell/_handleFlatBuy).
      setQuoteRaw(
        side === 'buy'
          ? (mixIn * (round.supply ?? 0n)) / (round.reserve ?? 1n)
          : (pspIn * (round.reserve ?? 0n)) / (round.supply ?? 1n),
      )
      return
    }
    let dead = false
    async function tick() {
      try {
        const q = (await rpcCall(
          round.hook!, hookAbi,
          side === 'buy' ? 'getBuyOutput' : 'getSellOutput',
          [side === 'buy' ? mixIn : pspIn],
        )) as bigint
        if (!dead) setQuoteRaw(q)
      } catch {
        if (!dead) setQuoteRaw(undefined)
      }
    }
    tick()
    const iv = setInterval(tick, 4000)
    return () => { dead = true; clearInterval(iv) }
  }, [round.hook, side, mixIn, pspIn, flat, round.mode, round.supply, round.reserve])
  const quoteMixOut = side === 'sell' ? (quoteRaw ?? 0n) : 0n

  /// Sell-fee haircut: the LIVE hook's getSellOutput returns the pre-fee
  /// integral (fixed in src for future deploys; deployed rounds overstate by
  /// SWAP_FEE_BIPS). Read the fee from the hook and haircut sell quotes +
  /// minOut so execution matches the number the user saw.
  const [sellFeeBps, setSellFeeBps] = useState<number>(500)
  useEffect(() => {
    if (!round.hook) return
    let dead = false
    rpcCall(round.hook!, hookAbi, 'SWAP_FEE_BIPS')
      .then((v) => { if (!dead && v !== undefined) setSellFeeBps(Number(v)) })
      .catch(() => {})
    return () => { dead = true }
  }, [round.hook])
  /// Fee applies to curve-mode sells only — flat exits are fee-free (F-9).
  const sellFactor = flat ? 1 : 1 - sellFeeBps / 10000
  const quoteMixAfterFee = BigInt(Math.round(Number(quoteMixOut) * sellFactor))

  const poolKey = useMemo(
    () =>
      round.mix && round.token && round.hook
        ? buildPoolKey(round.mix, round.token, round.hook)
        : undefined,
    [round.mix, round.token, round.hook],
  )

  /// approval target + token for the current action
  const needsApproval = useMemo(() => {
    if (!address || !amountWad) return false
    return true // mix buy: approve mix to zapIn · sell: approve PSP to zapOut · predeposit: approve mix to controller
  }, [address, amountWad])

  const approveToken = side === 'sell' ? round.token : round.mix
  const approveTarget = side === 'sell'
    ? ADDRESSES.zapOut
    : predepositPhase
      ? round.controller
      : ADDRESSES.zapIn

  const allowanceRes = useRpcReads(
    [
      { to: approveToken ?? undefined, abi: erc20Abi, functionName: 'allowance', args: [address ?? ZERO, approveTarget ?? ZERO] },
    ],
    needsApproval && !!approveToken && !!approveTarget,
  )
  const hasAllowance =
    allowanceRes[0] !== undefined &&
    (allowanceRes[0] as bigint) >= (side === 'sell' ? pspIn : mixIn)

  const minOut = useMemo(() => {
    const q = side === 'buy' ? quoteRaw : quoteMixAfterFee
    if (!q) return 0n
    return BigInt(Math.round(Number(q) * (1 - slippage)))
  }, [quoteRaw, quoteMixAfterFee, slippage, side])

  /// Fresh quote at submit — a polled quote can be seconds stale; for large
  /// trades that drift eats the whole slippage budget before the tx lands.
  async function freshMinOut(): Promise<bigint> {
    if (!round.hook) return minOut
    try {
      let q: bigint
      if (flat) {
        const [r, s] = await Promise.all([
          rpcCall(round.hook!, hookAbi, 'reserveMixETH') as Promise<bigint>,
          rpcCall(round.hook!, hookAbi, 'totalSupplyPSP') as Promise<bigint>,
        ])
        q = side === 'buy' ? (mixIn * s) / r : (pspIn * r) / s
      } else {
        q = (await rpcCall(
          round.hook!, hookAbi,
          side === 'buy' ? 'getBuyOutput' : 'getSellOutput',
          [side === 'buy' ? mixIn : pspIn],
        )) as bigint
      }
      const adj = side === 'sell' ? BigInt(Math.round(Number(q) * sellFactor)) : q
      return BigInt(Math.round(Number(adj) * (1 - slippage)))
    } catch {
      return minOut
    }
  }

  const payBalance = side === 'buy' ? mixBal : pspBal
  const payBalanceOk = payBalance === undefined || amountWad <= payBalance

  async function run() {
    setError(null)
    if (!address || !poolKey) return
    try {
      if (predepositPhase) {
        if (!hasAllowance) {
          setStep('approve')
          await writeContractAsync({
            address: round.mix!,
            abi: erc20Abi,
            functionName: 'approve',
            args: [round.controller!, mixIn],
          })
        }
        setStep('waiting')
        await writeContractAsync({
          address: round.controller!,
          abi: controllerAbi,
          functionName: 'predeposit',
          args: [mixIn],
        })
        setStep('done')
        return
      }

      // active trading
      if (side === 'buy') {
        if (!hasAllowance) {
          setStep('approve')
          await writeContractAsync({
            address: round.mix!,
            abi: erc20Abi,
            functionName: 'approve',
            args: [ADDRESSES.zapIn, mixIn],
          })
        }
        setStep('swap')
        await writeContractAsync({
          address: ADDRESSES.zapIn,
          abi: zapInAbi,
          functionName: 'buyWithMix',
          args: [poolKey, mixIn, await freshMinOut(), 0n],
        })
        setStep('done')
        return
      }
      // sell
      if (!hasAllowance) {
        setStep('approve')
        await writeContractAsync({
          address: round.token!,
          abi: erc20Abi,
          functionName: 'approve',
          args: [ADDRESSES.zapOut, pspIn],
        })
      }
      setStep('swap')
      await writeContractAsync({
        address: ADDRESSES.zapOut,
        abi: zapOutAbi,
        functionName: 'sellToMix',
        args: [poolKey, pspIn, await freshMinOut(), 0n],
      })
      setStep('done')
    } catch (e) {
      setError(e instanceof Error ? e.message.slice(0, 140) : 'transaction failed')
      setStep('idle')
    }
  }

  useEffect(() => {
    if (step === 'done') {
      setAmount('')
      const t = setTimeout(() => setStep('idle'), 2500)
      return () => clearTimeout(t)
    }
  }, [step])

  const busy = step === 'approve' || step === 'swap' || step === 'waiting'
  const canSubmit =
    isConnected && !!poolKey && amountWad > 0n && payBalanceOk && !busy && (live || predepositPhase)

  const cta = !isConnected
    ? 'connect wallet'
    : !amountWad
      ? 'enter an amount'
      : !payBalanceOk
        ? `insufficient ${side === 'buy' ? 'mixETH' : 'PSP'}`
        : predepositPhase
          ? hasAllowance
            ? `predeposit ${fmtAmount(mixIn)} mixETH`
            : `approve ${fmtAmount(mixIn)} mixETH`
          : step === 'approve'
            ? 'approving…'
            : needsApproval && !hasAllowance
              ? `approve ${side === 'sell' ? 'PSP' : 'mixETH'}`
              : side === 'buy'
                ? 'buy PSP'
                : 'sell for mixETH'

  return (
    <div className="card p-5">
      <div className="flex items-center justify-between">
        <h2 className="text-lg font-black text-slate-900">
          {predepositPhase ? 'predeposit' : 'swap'}
        </h2>
        {round.mode === 2 && (
          <span className="chip bg-slate-100 text-slate-500">flat — pro-rata, fee-free</span>
        )}
        <div className="flex rounded-full bg-sky-50 p-1">
          <button
            onClick={() => setSide('buy')}
            disabled={round.mode === 2}
            title={round.mode === 2 ? 'buying is disabled while the round is flat' : undefined}
            className={`rounded-full px-4 py-1 text-sm font-bold transition disabled:opacity-30 ${
              side === 'buy' ? 'bg-white text-psp-deep shadow' : 'text-slate-400'
            }`}
          >
            buy
          </button>
          <button
            onClick={() => setSide('sell')}
            disabled={predepositPhase}
            className={`rounded-full px-4 py-1 text-sm font-bold transition disabled:opacity-30 ${
              side === 'sell' ? 'bg-white text-psp-deep shadow' : 'text-slate-400'
            }`}
          >
            sell
          </button>
        </div>
      </div>

      {predepositPhase && round.totalPredeposit !== undefined && round.predepositCap && (
        <div className="mt-3">
          <div className="mb-1 flex justify-between text-[11px] font-bold text-slate-400">
            <span>window fill</span>
            <span>
              {fmtAmount(round.totalPredeposit)} / {fmtAmount(round.predepositCap)} mix
            </span>
          </div>
          <div className="h-2 overflow-hidden rounded-full bg-sky-100">
            <div
              className="h-full rounded-full bg-gradient-to-r from-sky-400 to-emerald-400"
              style={{
                width: `${Math.min(100, Number(round.totalPredeposit * 10000n / round.predepositCap) / 100)}%`,
              }}
            />
          </div>
        </div>
      )}

      {/* pay box */}
      <div className="mt-4 rounded-2xl border border-sky-100 bg-sky-50/60 p-4">
        <div className="flex items-center justify-between text-xs font-bold text-slate-400">
          <span>{side === 'buy' ? 'pay' : 'sell'}</span>
          <button
            type="button"
            title="fill your full balance"
            onClick={() => setAmount(wadToExact(side === 'buy' ? mixBal : pspBal))}
            className="rounded-md px-1.5 py-0.5 transition hover:bg-sky-100 hover:text-sky-600"
          >
            balance{' '}
            {side === 'buy' ? fmtAmount(mixBal) : fmtAmount(pspBal)}
            {((side === 'buy' ? mixBal : pspBal) ?? 0n) > 0n && (
              <span className="ml-1 text-[10px] text-sky-500">MAX</span>
            )}
          </button>
        </div>
        <div className="mt-2 flex items-center gap-2">
          <input
            className="input-amount flex-1"
            placeholder="0.0"
            value={amount}
            inputMode="decimal"
            onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ''))}
          />
          {side === 'buy' ? (
            <div className="shrink-0 rounded-2xl bg-white px-4 py-3 text-lg font-black text-slate-700 shadow-sm">
              <MixLogo px={20} /> mix
            </div>
          ) : (
            <div className="shrink-0 rounded-2xl bg-white px-4 py-3 text-lg font-black text-slate-700 shadow-sm">
              <PspIcon px={20} /> PSP
            </div>
          )}
        </div>
        {payBalance !== undefined && amountWad > payBalance && (
          <div className="mt-1 text-xs font-bold text-rose-500">insufficient balance</div>
        )}
      </div>

      <div className="flex justify-center py-1 text-xl text-sky-300">↓</div>

      {/* receive box */}
      <div className="rounded-2xl border border-emerald-100 bg-emerald-50/60 p-4">
        <div className="flex items-center justify-between text-xs font-bold text-slate-400">
          <span>receive (est.)</span>
        </div>
        <div className="mt-2 flex items-center gap-2">
          <div className="input-amount flex-1 bg-transparent">
            {side === 'buy' ? fmtAmount(quoteRaw, 4) : fmtAmount(quoteMixOut, 4)}
          </div>
          {side === 'buy' ? (
            <div className="shrink-0 rounded-2xl bg-white px-4 py-3 text-lg font-black text-slate-700 shadow-sm">
              <PspIcon px={20} /> PSP
            </div>
          ) : (
            <div className="shrink-0 rounded-2xl bg-white px-4 py-3 text-lg font-black text-slate-700 shadow-sm">
              <MixLogo px={20} /> mix
            </div>
          )}
        </div>
      </div>

      {/* slippage */}
      <div className="mt-3 flex flex-wrap items-center justify-between gap-2 text-xs">
        <span className="font-bold text-slate-400">slippage</span>
        <div className="flex items-center gap-1">
          {[0.005, 0.01, 0.03, 0.05, 0.1].map((s) => (
            <button
              key={s}
              onClick={() => { setSlippage(s); setCustomSlip('') }}
              className={`rounded-lg px-2 py-1 font-bold transition ${
                slippage === s && customSlip === ''
                  ? 'bg-sky-400 text-[#fff]'
                  : 'bg-sky-50 text-slate-500'
              }`}
            >
              {s * 100}%
            </button>
          ))}
          <input
            value={customSlip}
            onChange={(e) => {
              const v = e.target.value.replace(/[^0-9.]/g, '')
              setCustomSlip(v)
              const pct = parseFloat(v)
              if (!Number.isNaN(pct) && pct >= 0 && pct <= 90) setSlippage(pct / 100)
            }}
            inputMode="decimal"
            placeholder="custom %"
            className="w-20 rounded-lg border border-sky-100 bg-white px-2 py-1 text-right font-bold text-slate-600 outline-none focus:border-sky-300"
          />
        </div>
      </div>

      {live && quoteRaw !== undefined && quoteRaw > 0n && (
        <div className="mt-2 space-y-1">
          <div className="flex justify-between text-xs text-slate-400">
            <span>{side === 'sell' ? 'expected out (after fee)' : 'expected out'}</span>
            <span className="font-bold text-slate-500">
              {side === 'buy'
                ? `${fmtAmount(quoteRaw, 4)} PSP`
                : `${fmtAmount(quoteMixAfterFee, 4)} mix`}
            </span>
          </div>
          <div className="flex justify-between text-xs text-slate-400">
            <span>min out (fresh at submit)</span>
            <span className="font-bold text-slate-500">
              {side === 'buy' ? `${fmtAmount(minOut, 4)} PSP` : `${fmtAmount(minOut, 4)} mix`}
            </span>
          </div>
        </div>
      )}

      <button className="btn-primary mt-4 w-full" disabled={!canSubmit} onClick={run}>
        {step === 'done' ? '✅ confirmed' : step === 'waiting' ? 'confirm in wallet…' : cta}
      </button>
      {error && <div className="mt-2 break-words text-xs text-rose-500">{error}</div>}
      {round.mode === 3 && (
        <div className="mt-3 rounded-xl bg-amber-50 p-3 text-xs font-bold text-amber-600">
          💀 this round was carpet-bombed. wait for round n+1.
        </div>
      )}
      {round.mode === 2 && (
        <div className="mt-3 rounded-xl bg-emerald-50 p-3 text-xs font-bold text-emerald-600">
          ⚪ round is dying — exits are toll-free at exact average backing. buying is disabled.
        </div>
      )}
    </div>
  )
}
