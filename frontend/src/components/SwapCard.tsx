import { useEffect, useMemo, useRef, useState } from 'react'
import { useAccount, useWriteContract } from 'wagmi'
import { useRpcReads } from '../lib/useRpcReads'
import { erc20Abi, hookAbi, controllerAbi, zapInAbi, zapOutAbi, buildPoolKey } from '../lib/abi'
import { rpcCall } from '../lib/rpc'
import { ADDRESSES } from '../lib/config'
import { useRound, useBalances } from '../lib/useRound'
import { fmtAmount, parseAmountToWad, wadToExact } from '../lib/format'
import { injectTime, usePhase } from '../phase/PhaseEngine'
import MixLogo from './MixLogo'
import { PspIcon } from './TokenIcon'
import { PixelIcon } from './PixelIcon'
import PixelBurst, { type BurstHandle } from './PixelBurst'

/// mixETH-only swap card (testnet): the mock mixETH has no ETH backing, so
/// every ETH leg (zapInBuy / zapOut / zapInPredeposit) is off the table —
/// buys go buyWithMix, sells go sellToMix, predeposit goes approve+predeposit.
type Side = 'buy' | 'sell'
type Step = 'idle' | 'approve' | 'swap' | 'waiting' | 'done'

export default function SwapCard() {
  const round = useRound()
  const { zero: clockZero } = usePhase()
  const { address, isConnected } = useAccount()
  const { psp: pspBal, mix: mixBal } = useBalances(round.token, round.mix)

  const [side, setSide] = useState<Side>('buy')
  const [amount, setAmount] = useState('')
  const [slippage, setSlippage] = useState(0.01)
  const [customSlip, setCustomSlip] = useState('')
  const [step, setStep] = useState<Step>('idle')
  const [error, setError] = useState<string | null>(null)
  const { writeContractAsync } = useWriteContract()
  const burstRef = useRef<BurstHandle>(null)

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
  /// CLOCK-REDESIGN §1/§6.2: at zero the hook reverts every trade
  /// (TradingHalted) — the tabs hard-disable and the card goes deadpan.
  /// Mode stays Active until someone presses detonate, so this is the
  /// between-zero-and-boom state exactly.
  const halted = clockZero && round.mode === 1

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
        // B2 §4 wiring — VISUAL ONLY until round wiring lands: a whole-PSP
        // buy feeds the machine. +5:00 per WHOLE psp, discrete (quote-based
        // estimate; injectTime flashes the clock digits + floats the chip).
        // Predeposit genesis buys are excluded — the clock isn't armed yet.
        {
          const wholePsp = quoteRaw !== undefined ? Number(quoteRaw) / 1e18 : 0
          const minutes = Math.floor(wholePsp) * 5
          if (minutes > 0) injectTime(minutes * 60_000)
          burstRef.current?.fire()
        }
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
    isConnected && !!poolKey && amountWad > 0n && payBalanceOk && !busy && !halted && (live || predepositPhase)

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
    <div className="flex h-full flex-col rounded-xl border border-line bg-bg-1 p-5 font-body">
      <div className="flex items-center justify-between gap-2">
        <h2 className="font-display text-lg text-text-hi">
          {predepositPhase ? 'predeposit' : 'swap'}
        </h2>
        {round.mode === 2 && (
          <span className="rounded-full border border-line px-2.5 py-0.5 text-xs text-text-lo">
            flat — pro-rata, fee-free
          </span>
        )}
        <div className="flex rounded-full bg-bg-2 p-1">
          <button
            onClick={() => setSide('buy')}
            disabled={round.mode === 2 || halted}
            title={
              halted
                ? 'the clock is at zero — no more moves'
                : round.mode === 2
                  ? 'buying is disabled while the round is flat'
                  : undefined
            }
            className={`rounded-full px-4 py-1 text-sm font-semibold transition disabled:opacity-30 ${
              side === 'buy' ? 'bg-accent text-bg-0' : 'text-text-lo hover:text-text-hi'
            }`}
          >
            buy
          </button>
          <button
            onClick={() => setSide('sell')}
            disabled={predepositPhase || halted}
            className={`rounded-full px-4 py-1 text-sm font-semibold transition disabled:opacity-30 ${
              side === 'sell' ? 'bg-accent text-bg-0' : 'text-text-lo hover:text-text-hi'
            }`}
          >
            sell
          </button>
        </div>
      </div>

      {predepositPhase && round.totalPredeposit !== undefined && round.predepositCap && (
        <div className="mt-3">
          <div className="mb-1 flex justify-between text-[11px] font-semibold text-text-lo">
            <span>window fill</span>
            <span className="tabular font-data">
              {fmtAmount(round.totalPredeposit)} / {fmtAmount(round.predepositCap)} mix
            </span>
          </div>
          <div className="h-2 overflow-hidden rounded-full bg-bg-2">
            <div
              className="h-full rounded-full bg-accent transition-[width]"
              style={{
                width: `${Math.min(100, Number(round.totalPredeposit * 10000n / round.predepositCap) / 100)}%`,
              }}
            />
          </div>
        </div>
      )}

      {halted ? (
        <div className="mt-4 flex flex-1 flex-col items-center justify-center gap-2.5 rounded-lg border border-phase-critical/40 p-6 text-center">
          <PixelIcon name="bomb" size={22} />
          <p className="font-display text-lg text-text-hi">
            the clock struck zero. no more moves.
          </p>
          <p className="max-w-xs text-xs leading-relaxed text-text-lo">
            the next move is detonation — the pot settles, the curve flattens, the exits open. nothing left to buy, nothing left to sell.
          </p>
        </div>
      ) : (
      <>
      {/* pay box */}
      <div className="mt-4 rounded-lg border border-line bg-bg-2 p-4">
        <div className="flex items-center justify-between text-xs font-semibold text-text-lo">
          <span>{side === 'buy' ? 'pay' : 'sell'}</span>
          <button
            type="button"
            title="fill your full balance"
            onClick={() => setAmount(wadToExact(side === 'buy' ? mixBal : pspBal))}
            className="rounded-md px-1.5 py-0.5 transition hover:bg-bg-1 hover:text-text-hi"
          >
            balance{' '}
            <span className="tabular font-data">
              {side === 'buy' ? fmtAmount(mixBal) : fmtAmount(pspBal)}
            </span>
            {((side === 'buy' ? mixBal : pspBal) ?? 0n) > 0n && (
              <span className="ml-1 text-[10px] text-accent">MAX</span>
            )}
          </button>
        </div>
        <div className="mt-2 flex items-center gap-2">
          <input
            className="tabular w-full flex-1 rounded-lg border border-line bg-bg-0 px-4 py-3 font-data text-2xl text-text-hi outline-none transition placeholder:text-text-lo/60 focus:border-accent"
            placeholder="0.0"
            value={amount}
            inputMode="decimal"
            onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ''))}
          />
          {side === 'buy' ? (
            <div className="shrink-0 rounded-lg border border-line bg-bg-1 px-4 py-3 text-lg font-semibold text-text-hi">
              <MixLogo px={20} /> mix
            </div>
          ) : (
            <div className="shrink-0 rounded-lg border border-line bg-bg-1 px-4 py-3 text-lg font-semibold text-text-hi">
              <PspIcon px={20} /> PSP
            </div>
          )}
        </div>
        {payBalance !== undefined && amountWad > payBalance && (
          <div className="mt-1 text-xs font-semibold text-phase-critical">insufficient balance</div>
        )}
      </div>

      <div className="flex justify-center py-1 text-lg text-text-lo" aria-hidden="true">
        ↓
      </div>

      {/* receive box */}
      <div className="rounded-lg border border-line bg-bg-2 p-4">
        <div className="flex items-center justify-between text-xs font-semibold text-text-lo">
          <span>receive (est.)</span>
        </div>
        <div className="mt-2 flex items-center gap-2">
          <div className="tabular flex-1 font-data text-2xl text-text-hi">
            {side === 'buy' ? fmtAmount(quoteRaw, 4) : fmtAmount(quoteMixOut, 4)}
          </div>
          {side === 'buy' ? (
            <div className="shrink-0 rounded-lg border border-line bg-bg-1 px-4 py-3 text-lg font-semibold text-text-hi">
              <PspIcon px={20} /> PSP
            </div>
          ) : (
            <div className="shrink-0 rounded-lg border border-line bg-bg-1 px-4 py-3 text-lg font-semibold text-text-hi">
              <MixLogo px={20} /> mix
            </div>
          )}
        </div>
      </div>

      {/* slippage */}
      <div className="mt-3 flex flex-wrap items-center justify-between gap-2 text-xs">
        <span className="font-semibold text-text-lo">slippage</span>
        <div className="flex items-center gap-1">
          {[0.005, 0.01, 0.03, 0.05, 0.1].map((s) => (
            <button
              key={s}
              onClick={() => { setSlippage(s); setCustomSlip('') }}
              className={`rounded-lg px-2 py-1 font-semibold transition ${
                slippage === s && customSlip === ''
                  ? 'bg-accent text-bg-0'
                  : 'bg-bg-2 text-text-lo hover:text-text-hi'
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
            className="tabular w-20 rounded-lg border border-line bg-bg-0 px-2 py-1 text-right font-data text-text-hi outline-none focus:border-accent"
          />
        </div>
      </div>

      {live && quoteRaw !== undefined && quoteRaw > 0n && (
        <div className="mt-2 space-y-1">
          <div className="flex justify-between text-xs text-text-lo">
            <span>{side === 'sell' ? 'expected out (after fee)' : 'expected out'}</span>
            <span className="tabular font-data font-semibold text-text-hi">
              {side === 'buy'
                ? `${fmtAmount(quoteRaw, 4)} PSP`
                : `${fmtAmount(quoteMixAfterFee, 4)} mix`}
            </span>
          </div>
          <div className="flex justify-between text-xs text-text-lo">
            <span>min out (fresh at submit)</span>
            <span className="tabular font-data font-semibold text-text-hi">
              {side === 'buy' ? `${fmtAmount(minOut, 4)} PSP` : `${fmtAmount(minOut, 4)} mix`}
            </span>
          </div>
        </div>
      )}

      </>
      )}

      {!halted && (
      <div className="relative mt-auto">
        {/* audit r1 fix 6: the dead zone between the slippage row and the CTA
            gets ONE quiet on-voice line — the real fee routing (stakers + pot
            + a fixed 0.5%-of-volume referral carve-out, stated without
            numbers so it stays true across the fee's wave regimes). Curve
            mode only: flat exits are fee-free (F-9) and predeposit has no
            swaps, so the line never lies. Panel height untouched. */}
        {round.mode === 1 && (
          <p className="mb-2 text-center text-xs text-text-lo">
            swap fees feed the pot, the stakers, and whoever's link brought you
          </p>
        )}
        <button
          data-pending={busy || undefined}
          className={`relative mt-4 w-full overflow-hidden rounded-xl px-5 py-3 font-semibold transition active:translate-y-[1px] disabled:cursor-not-allowed disabled:opacity-40 ${
            busy || step === 'done'
              ? 'bg-accent text-bg-0'
              : 'border border-line bg-bg-2 text-text-hi hover:border-accent'
          }`}
          disabled={!canSubmit}
          onClick={run}
        >
          <span className="pl-btn-fill" aria-hidden="true" />
          <span className="relative">
            {step === 'done' ? '✓ confirmed' : step === 'waiting' ? 'confirm in wallet…' : cta}
          </span>
        </button>
        <PixelBurst ref={burstRef} />
      </div>
      )}
      {error && <div className="mt-2 break-words text-xs text-phase-critical">{error}</div>}
      {round.mode === 3 && (
        <div className="mt-3 flex items-start gap-2 rounded-lg border border-phase-critical/40 p-3 text-xs font-semibold text-phase-critical">
          <PixelIcon name="bomb" size={16} />
          <span>this round was carpet-bombed. wait for round n+1.</span>
        </div>
      )}
      {round.mode === 2 && (
        <div className="mt-3 flex items-start gap-2 rounded-lg border border-line p-3 text-xs font-semibold text-text-lo">
          <span className="mt-1 inline-block h-2 w-2 shrink-0 rounded-[2px] bg-accent" aria-hidden="true" />
          <span>round is dying — exits are toll-free at exact average backing. buying is disabled.</span>
        </div>
      )}
    </div>
  )
}
