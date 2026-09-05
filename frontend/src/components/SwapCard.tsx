import { usePurchaseReferral, useReferral } from './ReferralCard'
import { purchaseReferral } from '../lib/referrals'
import { MIN_BUY_INPUT, purchaseUnits, TIME_PER_UNIT, minimumOutput } from '../lib/gameRules'
import { useConfirmedWrite } from '../lib/useConfirmedWrite'
import { useEffect, useMemo, useRef, useState } from 'react'
import { useAccount } from 'wagmi'
import { useRpcReads } from '../lib/useRpcReads'
import { erc20Abi, hookAbi, controllerAbi, registryAbi, zapInAbi, zapOutAbi, buildPoolKey } from '../lib/abi'
import { rpcCall, rpcBatchCall } from '../lib/rpc'
import { ADDRESSES } from '../lib/config'
import { useRound, useBalances } from '../lib/useRound'
import { fmtAmount, parseAmountToWad, wadToExact } from '../lib/format'
import { injectTime, usePhase } from '../phase/PhaseEngine'
import MixLogo from './MixLogo'
import { PspIcon } from './TokenIcon'
import { PixelIcon } from './PixelIcon'
import PixelBurst, { type BurstHandle } from './PixelBurst'
import { quoteWithFee, type TradeQuote } from '../lib/tradeQuote'

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
  const referral = useReferral()
  const hint = usePurchaseReferral()
  const atomicPurchase = referral.version === 1n && !!referral.registry
  const buyTarget = atomicPurchase ? referral.registry! : ADDRESSES.zapIn
  const referralLoading = referral.registry === undefined || referral.version === undefined
  const referralBlocked = referralLoading || (hint > 0n && referral.attributed !== true && !atomicPurchase)
  const { writeContractAsync } = useConfirmedWrite({ referralPurchase: { roundId: round.id, registry: referral.registry } })
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

  // Quote, fee rate and mode must describe the same input and chain snapshot.
  const quoteKey = `${round.hook}:${side}:${amountWad}:${round.mode}:${halted}`
  const [quoteState, setQuoteState] = useState<{ key: string; quote?: TradeQuote; failed?: boolean }>()
  const quote = quoteState?.key === quoteKey ? quoteState.quote : undefined
  const quoteFailed = quoteState?.key === quoteKey && quoteState.failed
  const quoteRaw = quote?.output
  useEffect(() => {
    if (!round.hook || !live || halted || amountWad <= 0n || (side === 'buy' && (round.mode === 2 || mixIn < MIN_BUY_INPUT))) return
    let dead = false
    let timer: ReturnType<typeof setTimeout> | undefined
    let backoff = 0
    async function tick() {
      try {
        const [output, rate, mode] = await rpcBatchCall(round.hook!, hookAbi, [
          { functionName: side === 'buy' ? 'getBuyOutput' : 'getSellOutput', args: [amountWad] },
          { functionName: 'swapFeeBps' },
          { functionName: 'mode' },
        ])
        const quoted = quoteWithFee(side, amountWad, output as bigint, BigInt(rate as number), Number(mode))
        if (!dead) { setQuoteState({ key: quoteKey, quote: quoted }); backoff = 0 }
      } catch {
        if (!dead) {
          setQuoteState({ key: quoteKey, failed: true })
          backoff = backoff ? Math.min(backoff * 2, 60_000) : 8000
        }
      }
      if (!dead) timer = setTimeout(tick, backoff || 4000)
    }
    tick()
    return () => { dead = true; if (timer) clearTimeout(timer) }
  }, [quoteKey, round.hook, side, amountWad, mixIn, round.mode, live, halted])
  const quoteMixOut = side === 'sell' ? quoteRaw : undefined

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
      : buyTarget

  const allowanceRes = useRpcReads(
    [
      { to: approveToken ?? undefined, abi: erc20Abi, functionName: 'allowance', args: [address ?? ZERO, approveTarget ?? ZERO] },
    ],
    needsApproval && !!approveToken && !!approveTarget,
  )
  const hasAllowance =
    allowanceRes[0] !== undefined &&
    (allowanceRes[0] as bigint) >= (side === 'sell' ? pspIn : mixIn)

  // AUD-5: the hook already returns POST-FEE outputs. A failed fresh quote
  // must abort; never silently fall back to zero protection or a stale quote.
  async function freshMinOut(): Promise<bigint> {
    if (!round.hook) throw new Error('Round is unavailable.')
    const q = await rpcCall(round.hook, hookAbi,
      side === 'buy' ? 'getBuyOutput' : 'getSellOutput',
      [side === 'buy' ? mixIn : pspIn]) as bigint
    return minimumOutput(q, Math.round(slippage * 10_000))
  }

  const minOut = useMemo(() => {
    try { return minimumOutput(quoteRaw ?? 0n, Math.round(slippage * 10_000)) }
    catch { return 0n }
  }, [quoteRaw, slippage])

  const payBalance = side === 'buy' ? mixBal : pspBal
  const payBalanceOk = payBalance === undefined || amountWad <= payBalance

  async function run() {
    setError(null)
    if (!address || !poolKey || busy) return
    if (side === 'buy' && !predepositPhase && referralBlocked) { setError('Referral purchases require the updated round contracts.'); return }
    if (side === 'buy' && mixIn < MIN_BUY_INPUT) { setError('Minimum purchase is 0.005 mixETH.'); return }
    setStep('waiting') // lock the action before the fresh allowance RPC
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
        const referrerNftId = purchaseReferral(hint, referral.attributed)
        // The spender changes on upgraded rounds; never reuse a cached zap allowance.
        const currentAllowance = await rpcCall(round.mix!, erc20Abi, 'allowance', [address, buyTarget]) as bigint
        if (currentAllowance < mixIn) {
          setStep('approve')
          await writeContractAsync({
            address: round.mix!,
            abi: erc20Abi,
            functionName: 'approve',
            args: [buyTarget, mixIn],
          })
        }
        setStep('swap')
        const output = await freshMinOut()
        const deadline = BigInt(Math.floor(Date.now() / 1000) + 600)
        if (atomicPurchase) {
          await writeContractAsync({
            address: buyTarget, abi: registryAbi, functionName: 'buyWithMix',
            args: [poolKey, mixIn, output, deadline, referrerNftId],
          })
        } else {
          await writeContractAsync({
            address: buyTarget, abi: zapInAbi, functionName: 'buyWithMix',
            args: [poolKey, mixIn, output, deadline],
          })
        }
        setStep('done')
        // The chain receipt is confirmed. Only animate the actual capped extension.
        if (round.hook) {
          const deadline = await rpcCall(round.hook, hookAbi, 'detonationAt').catch(() => undefined) as bigint | undefined
          if (deadline !== undefined && round.detonationAt !== undefined) {
            const added = deadline - round.detonationAt
            if (added > 0n) injectTime(Number(added) * 1000)
          }
        }
        burstRef.current?.fire()
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
        args: [poolKey, pspIn, await freshMinOut(), BigInt(Math.floor(Date.now() / 1000) + 600)],
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
  const buyDisabled = busy || halted || (round.mode !== 0 && round.mode !== 1)
  const sellDisabled = busy || halted || !live

  function changeSide(next: Side) {
    if (next === side || (next === 'buy' ? buyDisabled : sellDisabled)) return
    setSide(next)
    // The input token changes too; never reinterpret a mixETH amount as PSP.
    setAmount('')
    setQuoteState(undefined)
    setError(null)
    setStep('idle')
  }

  function chooseLadderSpot() {
    if (round.mode !== 1 || halted || busy) return
    setSide('buy')
    setAmount(wadToExact(MIN_BUY_INPUT))
    setQuoteState(undefined)
    setError(null)
    setStep('idle')
  }

  const canSubmit =
    isConnected && !!poolKey && !(side === 'buy' && !predepositPhase && referralBlocked) && amountWad > 0n && (side !== 'buy' || mixIn >= MIN_BUY_INPUT) && (predepositPhase || (quoteRaw ?? 0n) > 0n) && payBalanceOk && !busy && !halted && (live || predepositPhase)

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
            type="button"
            onClick={() => changeSide('buy')}
            disabled={buyDisabled}
            aria-pressed={side === 'buy'}
            title={
              halted
                ? 'the clock is at zero. trading has stopped.'
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
            type="button"
            onClick={() => changeSide('sell')}
            disabled={sellDisabled}
            aria-pressed={side === 'sell'}
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
            time’s up. somebody press the button.
          </p>
          <p className="max-w-xs text-xs leading-relaxed text-text-lo">
            trading has stopped. detonation settles the pot, opens staked positions for withdrawal, and makes PSP redeemable for remaining mixETH.
          </p>
        </div>
      ) : (
      <>
      {/* pay box */}
      <div className="mt-4 flex min-h-48 flex-1 flex-col rounded-lg border border-line bg-bg-2 p-4">
        <div className="flex items-center justify-between text-xs font-semibold text-text-lo">
          <span>{side === 'buy' ? 'pay' : 'sell'}</span>
          <button
            type="button"
            title="fill your full balance"
            disabled={busy}
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
        <div className="my-3 flex flex-1 items-center gap-2">
          <input
            className="tabular min-w-0 w-full flex-1 rounded-lg border border-line bg-bg-0 px-4 py-4 font-data text-3xl text-text-hi outline-none transition placeholder:text-text-lo/60 focus:border-accent"
            placeholder="0.0"
            aria-label={side === 'buy' ? 'mixETH to pay' : 'PSP to sell'}
            disabled={busy}
            value={amount}
            inputMode="decimal"
            onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ''))}
          />
          {side === 'buy' ? (
            <div className="inline-flex shrink-0 items-center gap-1.5 rounded-lg border border-line bg-bg-1 px-3 py-4 text-lg font-semibold leading-none text-text-hi">
              <MixLogo px={20} /><span>mix</span>
            </div>
          ) : (
            <div className="inline-flex shrink-0 items-center gap-1.5 rounded-lg border border-line bg-bg-1 px-3 py-4 text-lg font-semibold leading-none text-text-hi">
              <PspIcon px={20} /><span>PSP</span>
            </div>
          )}
        </div>
        {payBalance !== undefined && amountWad > payBalance && (
          <div className="mt-1 text-xs font-semibold text-phase-critical">insufficient balance</div>
        )}
        {round.mode === 1 && (
          <button
            type="button"
            onClick={chooseLadderSpot}
            disabled={busy}
            className="flex w-full flex-wrap items-center justify-between gap-x-2 gap-y-1 rounded-lg border border-line bg-bg-1 px-3 py-2 text-xs transition hover:border-accent disabled:cursor-not-allowed disabled:opacity-40"
          >
            <span className="font-semibold text-accent">buy 1 ladder spot</span>
            <span className="tabular font-data text-text-lo">{wadToExact(MIN_BUY_INPUT)} mixETH</span>
          </button>
        )}
      </div>

      <div className="flex justify-center py-1">
        <button
          type="button"
          onClick={() => changeSide(side === 'buy' ? 'sell' : 'buy')}
          disabled={side === 'buy' ? sellDisabled : buyDisabled}
          aria-label={side === 'buy' ? 'switch to selling PSP' : 'switch to buying PSP'}
          title={side === 'buy' ? 'switch to sell' : 'switch to buy'}
          className="grid h-10 w-10 place-items-center rounded-full border border-line bg-bg-1 text-lg text-text-lo transition hover:border-accent hover:text-accent disabled:cursor-not-allowed disabled:opacity-30"
        >
          <span aria-hidden="true">↓</span>
        </button>
      </div>

      {/* receive box */}
      <div className="flex min-h-40 flex-1 flex-col rounded-lg border border-line bg-bg-2 p-4">
        <div className="flex items-center justify-between text-xs font-semibold text-text-lo">
          <span>receive (est., after fee)</span>
        </div>
        <div className="mt-3 flex flex-1 items-center gap-2">
          <div className="tabular min-w-0 flex-1 break-words font-data text-3xl text-text-hi">
            {side === 'buy' ? fmtAmount(quoteRaw, 4) : fmtAmount(quoteMixOut, 4)}
          </div>
          {side === 'buy' ? (
            <div className="inline-flex shrink-0 items-center gap-1.5 rounded-lg border border-line bg-bg-1 px-3 py-4 text-lg font-semibold leading-none text-text-hi">
              <PspIcon px={20} /><span>PSP</span>
            </div>
          ) : (
            <div className="inline-flex shrink-0 items-center gap-1.5 rounded-lg border border-line bg-bg-1 px-3 py-4 text-lg font-semibold leading-none text-text-hi">
              <MixLogo px={20} /><span>mix</span>
            </div>
          )}
        </div>
      </div>

      {live && amountWad > 0n && (side === 'sell' || mixIn >= MIN_BUY_INPUT) && (
        <div className="mt-3 rounded-lg border border-line px-3 py-2 text-xs">
          <div className="flex flex-wrap items-center justify-between gap-1 text-text-lo">
            <span>trade fee (est.){quote && ` · ${(Number(quote.feeBps) / 100).toFixed(2)}%`}</span>
            <span className="tabular font-data font-semibold text-text-hi" title={quote ? `${wadToExact(quote.feeMix)} mixETH` : undefined}>
              {quote ? `≈ ${fmtAmount(quote.feeMix, 8)} mixETH` : quoteFailed ? 'unavailable' : 'estimating…'}
            </span>
          </div>
          <p className="mt-1 text-[10px] text-text-lo">
            {quote?.feeBps === 0n ? 'Trading fee: 0%.' : side === 'buy' ? 'Included in your payment.' : 'Already deducted from the receive amount.'}
            {' '}Network gas is extra, shown in your wallet.
          </p>
        </div>
      )}

      {side === 'buy' && (
        <p className="mt-3 text-xs text-text-lo">
          minimum 0.005 mixETH{!predepositPhase && ` · ${purchaseUnits(mixIn) > 10n ? 10n : purchaseUnits(mixIn)} ${purchaseUnits(mixIn) === 1n ? 'seat' : 'seats'} · +${Number(purchaseUnits(mixIn) * TIME_PER_UNIT / 60n)}m ${purchaseUnits(mixIn) * TIME_PER_UNIT % 60n}s before the clock cap`}
        </p>
      )}
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
            <span>expected out (after fee)</span>
            <span className="tabular font-data font-semibold text-text-hi">
              {side === 'buy'
                ? `${fmtAmount(quoteRaw, 4)} PSP`
                : `${fmtAmount(quoteMixOut, 4)} mix`}
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
      <div className="relative pt-4">
        {/* The pay/receive panels absorb spare height above the submit action. */}
        {side === 'buy' && round.mode === 1 && referralLoading && <p role="status" className="text-xs text-text-lo">checking the round’s purchase settings…</p>}
        {round.mode === 1 && (
          <p className="text-xs leading-relaxed text-text-lo">
            the pot gets fed. stakers get their cut. your swap fee covers both.
          </p>
        )}
        <button
          data-pending={busy || undefined}
          className={`relative mt-3 w-full overflow-hidden rounded-xl px-5 py-3 font-semibold transition active:translate-y-[1px] disabled:cursor-not-allowed disabled:opacity-40 ${
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
          <span>this round went boom. claim winnings and redeem PSP in the graveyard.</span>
        </div>
      )}
      {round.mode === 2 && (
        <div className="mt-3 flex items-start gap-2 rounded-lg border border-line p-3 text-xs font-semibold text-text-lo">
          <span className="mt-1 inline-block h-2 w-2 shrink-0 rounded-[2px] bg-accent" aria-hidden="true" />
          <span>this round has ended. redeem PSP for its share of remaining mixETH with a 0% trading fee. payouts are rounded down.</span>
        </div>
      )}
    </div>
  )
}
