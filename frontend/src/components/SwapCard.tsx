import AltTrade from '../alt/AltTrade'
import type { BoardState } from '../pages/play/useLadderBoard'
import { Link } from 'react-router-dom'
import { usePurchaseReferral, useReferral } from './ReferralCard'
import { purchaseReferral } from '../lib/referrals'
import { purchaseUnits, TIME_PER_UNIT, minimumOutput, minimumBuyInput, assertTicketGuard } from '../lib/gameRules'
import { usePredepositRules } from '../lib/usePredepositMinimum'
import { capHeadroom, predepositUncapped, predepositLimit, predepositAmountAllowed, predepositProgress, predepositRemainder } from '../lib/predeposit'
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
/// buys go buyWithMix, sells go sellToMix; predeposits use their dedicated picker page.
type Side = 'buy' | 'sell'
type Step = 'idle' | 'approve' | 'swap' | 'waiting' | 'done'

export default function SwapCard({ variant, board }: { variant?: 'alt'; board?: BoardState } = {}) {
  const round = useRound()
  const { minimum: pdMinimum, version: pdVersion } = usePredepositRules(round.mode === 0 ? round.controller : undefined)
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
  const { writeWithApprovals } = useConfirmedWrite({ referralPurchase: { roundId: round.id, registry: referral.registry } })
  const burstRef = useRef<BurstHandle>(null)

  /// Flat mode = one-way exit (scoopy 2026-08-29, fix #3): buying is
  /// disabled at the hook (BuyingDisabled) — force the sell side and lock
  /// the toggle so nobody wires a doomed buy.
  useEffect(() => {
    if (round.mode === 2) setSide('sell')
    if (round.mode === 0) setSide('buy')
  }, [round.mode])

  const ZERO = '0x0000000000000000000000000000000000000000' as const
  const amountWad = parseAmountToWad(amount)
  const live = round.mode === 1 || round.mode === 2
  const predepositPhase = round.mode === 0
  /// v3 prices tickets from the live pot: the minimum IS one current ladder
  /// spot. undefined = unavailable — exposure-increasing actions stay
  /// disabled (never a 0.005 fallback); legacy rounds keep their constant.
  const minimum = minimumBuyInput(round.ticketRules, round.ticketPrice)
  /// v3 purchase routes carry the quoted ticket intent (TicketPriceMoved is
  /// the hook-side backstop). Version-gated: legacy rounds keep the old
  /// selectors and their authoritative static minimum.
  const guarded = round.ticketRules === 3n
  /// CLOCK-REDESIGN §1/§6.2: at zero the hook reverts every trade
  /// (TradingHalted) — the tabs hard-disable and the card goes deadpan.
  /// Mode stays Active until someone presses detonate, so this is the
  /// between-zero-and-boom state exactly.
  const halted = clockZero && round.mode === 1
  const pdReads = useRpcReads([
    { to: round.controller, abi: controllerAbi, functionName: 'predepositState' },
    { to: round.controller, abi: controllerAbi, functionName: 'PREDEPOSIT_CAP_PER_WALLET' },
    { to: round.controller, abi: controllerAbi, functionName: 'predeposits', args: [address ?? ZERO] },
  ], predepositPhase && !!round.controller && !!address, 4000, step === 'done' ? 1 : 0)
  const pdState = pdReads[0] as [bigint, bigint, bigint, boolean, boolean, boolean, boolean] | undefined
  const pdWalletCap = pdReads[1] as bigint | undefined
  const pdDeposit = (pdReads[2] as [bigint, boolean] | undefined)?.[0]
  const pdTotal = pdState?.[0] ?? round.totalPredeposit
  const pdCap = pdState?.[1] ?? round.predepositCap
  const pdUncapped = pdCap !== undefined && predepositUncapped(pdVersion, pdCap)
  const pdRemaining = !pdUncapped && pdTotal !== undefined && pdCap !== undefined ? capHeadroom(pdTotal, pdCap) : undefined
  const pdMax = mixBal !== undefined && pdState && pdWalletCap !== undefined && pdDeposit !== undefined
    ? predepositLimit(mixBal, pdState[0], pdState[1], pdWalletCap, pdDeposit, pdVersion) : undefined
  const pdAllowed = side === 'buy' && !!pdState && !pdState[3]
    && predepositAmountAllowed(amountWad, pdMinimum, pdMax)


  /// mixETH entering the curve for this input
  const mixIn = useMemo(() => {
    if (side === 'sell') return 0n
    return amountWad
  }, [amountWad, side])

  const pspIn = side === 'sell' ? amountWad : 0n

  // Quote, fee rate and mode must describe the same input and chain snapshot.
  // The ticket price is sampled in the same batch: that exact bigint becomes
  // the guarded route's maxTicketPrice at submit.
  const quoteKey = `${round.hook}:${side}:${amountWad}:${round.mode}:${halted}`
  const [quoteState, setQuoteState] = useState<{ key: string; quote?: TradeQuote; failed?: boolean; ticketPrice?: bigint }>()
  const quote = quoteState?.key === quoteKey ? quoteState.quote : undefined
  const quoteFailed = quoteState?.key === quoteKey && quoteState.failed
  const quotedTicketPrice = quoteState?.key === quoteKey ? quoteState.ticketPrice : undefined
  const quoteRaw = quote?.output
  useEffect(() => {
    if (!round.hook || !live || halted || amountWad <= 0n ||
      (side === 'buy' && (round.mode === 2 || minimum === undefined || mixIn < minimum))) return
    let dead = false
    let timer: ReturnType<typeof setTimeout> | undefined
    let backoff = 0
    async function tick() {
      try {
        const [output, rate, mode, ticketPrice] = await rpcBatchCall(round.hook!, hookAbi, [
          { functionName: side === 'buy' ? 'getBuyOutput' : 'getSellOutput', args: [amountWad] },
          { functionName: 'swapFeeBps' },
          { functionName: 'mode' },
          { functionName: 'ticketPrice' },
        ])
        const quoted = quoteWithFee(side, amountWad, output as bigint, BigInt(rate as number), Number(mode))
        if (!dead) { setQuoteState({ key: quoteKey, quote: quoted, ticketPrice: ticketPrice as bigint }); backoff = 0 }
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
  }, [quoteKey, round.hook, side, amountWad, mixIn, round.mode, live, halted, minimum])
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
    if (!address || !poolKey || busy || predepositPhase) return
    if (side === 'buy' && !predepositPhase && referralBlocked) { setError('Referral purchases require the updated round contracts.'); return }
    if (predepositPhase && !pdAllowed) { setError('Check the exact remaining cap and this round’s deposit rules.'); return }
    if (side === 'buy' && !predepositPhase && minimum === undefined) {
      setError('The current ticket price is unavailable. Refresh and try again.')
      return
    }
    if (side === 'buy' && !predepositPhase && minimum !== undefined && mixIn < minimum) {
      setError(`Minimum purchase is ${wadToExact(minimum)} mixETH.`)
      return
    }
    setStep('waiting') // lock the action before the fresh allowance RPC
    const approvals: Parameters<typeof writeWithApprovals>[1] = []
    try {
      // active trading
      if (side === 'buy') {
        const referrerNftId = purchaseReferral(hint, referral.attributed)
        // The spender changes on upgraded rounds; never reuse a cached zap allowance.
        const currentAllowance = await rpcCall(round.mix!, erc20Abi, 'allowance', [address, buyTarget]) as bigint
        if (currentAllowance < mixIn) {
          setStep('approve')
          approvals.push({
            address: round.mix!,
            abi: erc20Abi,
            functionName: 'approve',
            args: [buyTarget, mixIn],
          })
        }
        setStep('swap')
        const output = await freshMinOut()
        const deadline = BigInt(Math.floor(Date.now() / 1000) + 600)
        // The quoted ticket price travels with the guarded purchase; a price
        // rise past it reverts (TicketPriceMoved) before any mixETH moves.
        const maxTicketPrice = guarded ? quotedTicketPrice : undefined
        if (guarded) assertTicketGuard(maxTicketPrice, round.ticketPrice)
        if (atomicPurchase) {
          if (guarded) {
            await writeWithApprovals({
              address: buyTarget, abi: registryAbi, functionName: 'buyWithMixGuarded',
              args: [poolKey, mixIn, output, deadline, referrerNftId, maxTicketPrice!],
            }, approvals)
          } else {
            await writeWithApprovals({
              address: buyTarget, abi: registryAbi, functionName: 'buyWithMix',
              args: [poolKey, mixIn, output, deadline, referrerNftId],
            }, approvals)
          }
        } else if (guarded) {
          await writeWithApprovals({
            address: buyTarget, abi: zapInAbi, functionName: 'buyWithMixGuarded',
            args: [poolKey, mixIn, output, deadline, maxTicketPrice!],
          }, approvals)
        } else {
          await writeWithApprovals({
            address: buyTarget, abi: zapInAbi, functionName: 'buyWithMix',
            args: [poolKey, mixIn, output, deadline],
          }, approvals)
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
        approvals.push({
          address: round.token!,
          abi: erc20Abi,
          functionName: 'approve',
          args: [ADDRESSES.zapOut, pspIn],
        })
      }
      setStep('swap')
      await writeWithApprovals({
        address: ADDRESSES.zapOut,
        abi: zapOutAbi,
        functionName: 'sellToMix',
        args: [poolKey, pspIn, await freshMinOut(), BigInt(Math.floor(Date.now() / 1000) + 600)],
      }, approvals)
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
    setAmount(wadToExact(round.ticketPrice))
    setQuoteState(undefined)
    setError(null)
    setStep('idle')
  }

  const canSubmit =
    isConnected && !!poolKey && !(side === 'buy' && !predepositPhase && referralBlocked) && amountWad > 0n &&
    (predepositPhase
      ? pdAllowed
      : side !== 'buy' || (minimum !== undefined && mixIn >= minimum)) &&
    (predepositPhase || (quoteRaw ?? 0n) > 0n) && payBalanceOk && !busy && !halted && (live || predepositPhase)

  const cta = !isConnected
    ? 'connect wallet'
    : !amountWad
      ? 'enter an amount'
      : !payBalanceOk
        ? `insufficient ${side === 'buy' ? 'mixETH' : 'PSP'}`
        : side === 'buy' && !predepositPhase && minimum === undefined
          ? 'ticket price unavailable — refresh'
          : predepositPhase
          ? amountWad < pdMinimum ? `this round requires ${wadToExact(pdMinimum)} mixETH`
            : pdMax !== undefined && amountWad > pdMax ? 'over the remaining cap'
            : hasAllowance
            ? `predeposit ${wadToExact(mixIn)} mixETH`
            : `approve ${wadToExact(mixIn)} mixETH`
          : step === 'approve'
            ? 'approving…'
            : needsApproval && !hasAllowance
              ? `approve ${side === 'sell' ? 'PSP' : 'mixETH'}`
              : side === 'buy'
                ? 'buy PSP'
                : 'sell for mixETH'

  if (variant === 'alt' && !predepositPhase) return <AltTrade
    side={side} amount={amount} setAmount={setAmount} changeSide={changeSide}
    busy={busy} buyDisabled={!!buyDisabled} balance={payBalance} quote={quote}
    quoteRaw={quoteRaw} quoteFailed={!!quoteFailed} slippage={slippage} setSlippage={setSlippage}
    canSubmit={canSubmit} cta={cta} run={run} error={error} board={board}
  />

  if (predepositPhase) return (
    <div className="rounded-xl border border-line bg-bg-1 p-5 font-body">
      <h2 className="font-display text-lg">predeposit</h2>
      <p className="mt-2 text-sm text-text-lo">pick your pepe and join the pooled first buy.</p>
      <Link className="mt-4 block rounded-lg bg-pepe p-3 text-center font-bold text-bg-0" to="/predeposit">choose your pepe &amp; deposit</Link>
    </div>
  )

  return (
    <div className="flex h-full flex-col rounded-xl border border-line bg-bg-1 p-5 font-body">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h2 className="font-display text-lg text-text-hi">
          {predepositPhase ? 'predeposit' : 'swap'}
        </h2>
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

      {predepositPhase && pdTotal !== undefined && pdCap !== undefined && pdCap > 0n && (
        <div className="mt-3">
          <div className="mb-1 flex flex-wrap justify-between gap-1 text-[11px] font-semibold text-text-lo">
            <span>{pdUncapped ? 'pooled buy-in' : 'window fill'}</span>
            <span className="tabular min-w-0 break-all font-data">
              {predepositProgress(pdTotal, pdCap, pdVersion)}
            </span>
          </div>
          <div className="h-2 overflow-hidden rounded-full bg-bg-2">
            <div
              className="h-full rounded-full bg-accent transition-[width]"
              style={{
                width: `${(pdCap > 0n ? Math.min(100, Number(pdTotal * 10000n / pdCap) / 100) : 0)}%`,
              }}
            />
          </div>
          <p className="mt-2 break-all text-xs text-text-lo">{predepositRemainder(pdTotal, pdCap, pdVersion)}</p>
          {pdWalletCap !== undefined && pdWalletCap > 0n && pdDeposit !== undefined &&
            <p className="mt-1 break-all text-xs text-text-lo">your wallet has {wadToExact(capHeadroom(pdDeposit, pdWalletCap))} mixETH of cap remaining</p>}
          {pdRemaining !== undefined && pdRemaining > 0n && pdRemaining < pdMinimum &&
            <p className="mt-2 text-xs text-text-lo">This deployed round requires at least {wadToExact(pdMinimum)} mixETH per deposit.
              The remainder is smaller than that; launch opens when the window ends.</p>}
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
            title={predepositPhase ? 'fill the maximum allowed by your balance and both caps' : 'fill your full balance'}
            disabled={busy}
            onClick={() => setAmount(wadToExact(predepositPhase ? pdMax : side === 'buy' ? mixBal : pspBal))}
            className="rounded-md px-1.5 py-0.5 transition hover:bg-bg-1 hover:text-text-hi"
          >
            balance{' '}
            <span className="tabular font-data">
              {side === 'buy' ? fmtAmount(mixBal) : fmtAmount(pspBal)}
            </span>
            {((predepositPhase ? pdMax : side === 'buy' ? mixBal : pspBal) ?? 0n) > 0n && (
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
            disabled={busy || !round.ticketPrice}
            className="flex w-full flex-wrap items-center justify-between gap-x-2 gap-y-1 rounded-lg border border-line bg-bg-1 px-3 py-2 text-xs transition hover:border-accent disabled:cursor-not-allowed disabled:opacity-40"
          >
            <span className="font-semibold text-accent">buy 1 ladder spot</span>
            <span className="tabular font-data text-text-lo">{wadToExact(round.ticketPrice)} mixETH</span>
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

      {live && amountWad > 0n && (side === 'sell' || (minimum !== undefined && mixIn >= minimum)) && (
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
          {predepositPhase ? pdMinimum === 1n ? 'any positive mixETH amount' : `this round’s minimum: ${wadToExact(pdMinimum)} mixETH` : minimum === undefined ? 'minimum unavailable' : `minimum ${wadToExact(minimum)} mixETH`}{!predepositPhase && ` · ${purchaseUnits(mixIn, quotedTicketPrice ?? 0n) > 10n ? 10n : purchaseUnits(mixIn, quotedTicketPrice ?? 0n)} ${purchaseUnits(mixIn, quotedTicketPrice ?? 0n) === 1n ? 'seat' : 'seats'} · +${purchaseUnits(mixIn, quotedTicketPrice ?? 0n) * TIME_PER_UNIT / 60n}m ${purchaseUnits(mixIn, quotedTicketPrice ?? 0n) * TIME_PER_UNIT % 60n}s before the clock cap`}
          {!predepositPhase && ' · estimated at the current ticket price. Other trades can change it before yours lands.'}
        </p>
      )}
      {/* slippage */}
      <div className="mt-3 flex flex-wrap items-center justify-between gap-2 text-xs">
        <span className="font-semibold text-text-lo">slippage</span>
        <div className="flex min-w-0 flex-wrap items-center gap-1">
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
