import { useEffect, useState } from 'react'
import { useAccount } from 'wagmi'
import { assertReinvestor } from './reinvestRules'
import { factoryAbi, controllerAbi, hookAbi, erc20Abi, stakerAbi, reinvestorAbi } from './abi'
import { ADDRESSES, REINVEST_ENABLED } from './config'
import { createRoundMetadataReader } from './roundMetadata'
import { rpcCall } from './rpc'
import { ibcoEnds } from './predeposit'
import { readPredepositLane } from './predepositState'
import type { CurveConfig } from './curve'
import { loadSineCurve, SineCurveData } from './sine'

export interface RoundInfo {
  readError: string | undefined
  reinvestorReady: boolean
  rulesCompatible: boolean | undefined
  id: bigint
  token: `0x${string}` | undefined
  controller: `0x${string}` | undefined
  staker: `0x${string}` | undefined
  hook: `0x${string}` | undefined
  mix: `0x${string}` | undefined
  mode: number | undefined // 0 Predeposit, 1 Active, 2 Flat, 3 Destroyed
  reserve: bigint | undefined
  supply: bigint | undefined
  marginalPrice: bigint | undefined
  /// CLOCK-REDESIGN §2: the ladder pot — 35% of every fee + genesis launch
  /// fee + dust. Paid to the last-10-buyers board at detonation.
  ticketPrice?: bigint
  potBalance: bigint | undefined
  totalLocked: bigint | undefined
  flatTime: bigint | undefined // bomb timestamp — nonzero = flat, locks open
  /// CLOCK-REDESIGN §1: the round's detonation time (SECONDS). undefined =
  /// not armed yet (predeposit), round not in Active mode, or the hook
  /// predates the clock (read reverts — caught, reported as undefined).
  detonationAt: bigint | undefined
  detWindow: bigint | undefined
  predepositClosed: boolean | undefined
  predepositStartTime: bigint | undefined
  totalPredeposit: bigint | undefined
  predepositCap: bigint | undefined
  /// greenlist-IBCO (rules v3) lane: live phase 0 green | 1 open | 2 over,
  /// per-tranche totals/caps, and the window ends (legacy rounds only get
  /// openEnd = start + PREDEPOSIT_DURATION; green fields stay undefined).
  predepositPhase: number | undefined
  greenTotal: bigint | undefined
  greenPerWallet: bigint | undefined
  openPerWallet: bigint | undefined
  greenEnd: bigint | undefined
  openEnd: bigint | undefined
  /// the whole IBCO window's length in seconds, both eras.
  predepositDuration: bigint | undefined
  curve: CurveConfig | undefined
  /// tilted-sine flavor: cached geometry extends locally with the live reserve;
  /// null when the hook runs the legacy zone curve or the RPC failed.
  sine: SineCurveData | null
  /// TICKET_RULES_VERSION of the round's hook (3n = pot-priced dynamic
  /// tickets; legacy constants otherwise). undefined = read pending/failed.
  ticketRules: bigint | undefined
  /// the sliding sine fee at the live reserve (bips of the trade) — the
  /// "average fee" a trader pays right now. undefined = read failed.
  swapFeeBps: bigint | undefined
}

const EMPTY: RoundInfo = {
  readError: undefined,
  reinvestorReady: false,
  rulesCompatible: undefined,
  id: 0n, token: undefined, controller: undefined, staker: undefined, hook: undefined, mix: undefined,
  mode: undefined, reserve: undefined, supply: undefined, marginalPrice: undefined,
  potBalance: undefined,
  ticketRules: undefined,
  swapFeeBps: undefined,
  totalLocked: undefined, predepositClosed: undefined, predepositStartTime: undefined, totalPredeposit: undefined,
  predepositCap: undefined, curve: undefined, flatTime: undefined, sine: null,
  detonationAt: undefined,
  detWindow: undefined,
  predepositPhase: undefined, greenTotal: undefined, greenPerWallet: undefined, openPerWallet: undefined,
  greenEnd: undefined, openEnd: undefined, predepositDuration: undefined,
}

const F = ADDRESSES.factory as `0x${string}`
const readMetadata = createRoundMetadataReader(F, rpcCall)
const wrapperStakers = new Map<string, string>()

// ── shared singleton store ─────────────────────────────────────────────────
// Every component on a page used to run its OWN 11-call polling loop every
// 4s (swap card + chart + stats ≈ 40+ req/s) — enough to trip provider
// rate limits, whose error pages ship without CORS headers and surface in
// the console as opaque CORS failures. ONE loop now feeds all subscribers,
// and failures back off (8s → 60s) instead of hammering through an outage.
type RoundListener = (i: RoundInfo) => void
const listeners = new Set<RoundListener>()
let shared: RoundInfo = EMPTY
let loopStarted = false
let inFlight = false
let backoffMs = 0

function startRoundLoop() {
  if (loopStarted) return
  loopStarted = true
  const schedule = () => setTimeout(tick, backoffMs || 4000)
  async function tick() {
    if (inFlight) return schedule()
    inFlight = true
    try {
      const id = await rpcCall(F, factoryAbi, 'currentRoundId') as bigint
      const { token: rToken, controller: rController, hook: rHook, staker: rStaker,
        mix, cfg, zones, detWindow, rulesCompatible, ticketRules } = await readMetadata(id)
      let wrapperStaker = wrapperStakers.get(ADDRESSES.reinvestor)
      if (REINVEST_ENABLED && !wrapperStaker) {
        wrapperStaker = await Promise.all([
          rpcCall(ADDRESSES.reinvestor, reinvestorAbi, 'staker') as Promise<string>,
          rpcCall(ADDRESSES.reinvestor, reinvestorAbi, 'ATTRIBUTION_VERSION') as Promise<bigint>,
        ]).then(([staker, version]) => { assertReinvestor(staker, staker, version); return staker }).catch(() => undefined)
        if (wrapperStaker) wrapperStakers.set(ADDRESSES.reinvestor, wrapperStaker)
      }
      const reinvestorReady = wrapperStaker?.toLowerCase() === rStaker.toLowerCase()
      // Immutable sine coefficients are cached per hook. Geometry extends
      // locally when the live reserve approaches the sampled window's edge.
      // One batch = one consistent snapshot: pot, the current ticket price
      // (the v3 minimum) and mode move together. A failed price read stays
      // undefined — exposure-increasing actions disable, never fall back —
      // and the next tick retries the transport.
      const [mode, reserve, supply, totalLocked, pd, flatTime, potBalance, sineActive, swapFeeBps, ticketPrice] = await Promise.all([
        rpcCall(rHook, hookAbi, 'mode') as Promise<bigint>,
        rpcCall(rHook, hookAbi, 'reserveMixETH') as Promise<bigint>,
        rpcCall(rHook, hookAbi, 'totalSupplyPSP') as Promise<bigint>,
        rpcCall(rStaker, stakerAbi, 'totalLocked') as Promise<bigint>,
        readPredepositLane(rController),
        rpcCall(rController, controllerAbi, 'flatTime') as Promise<bigint>,
        rpcCall(rHook, hookAbi, 'potBalance') as Promise<bigint>,
        (rpcCall(rHook, hookAbi, 'sineActive') as Promise<boolean>).catch(() => false),
        rpcCall(rHook, hookAbi, 'swapFeeBps').then(value => BigInt(value as number)).catch(() => undefined),
        rpcCall(rHook, hookAbi, 'ticketPrice').then(value => value as bigint).catch(() => undefined),
      ])
      if (!rHook || !rController) return
      // sine flavor: the zone getMarginalPrice is legacy — price comes from
      // the wave at the live reserve
      // sine rounds price off the wave at the live reserve — the legacy
      // zone marginal view read 11,000x the wave price and dragged the
      // chart's you-are-here marker off-scale
      let livePrice: bigint | undefined = undefined
      if (sineActive && reserve) {
        livePrice = await (
          rpcCall(rHook, hookAbi, 'sinePriceAt', [reserve]) as Promise<bigint>
        ).catch(() => undefined)
      }
      // CLOCK-REDESIGN §6.1: the detonation clock rides THIS lane (no new
      // cadence). Active rounds only, and a hook without the clock reverts
      // the read — isolated so one unknown selector can't sink the batch.
      let detonationAt: bigint | undefined
      if (Number(mode) === 1) {
        detonationAt = await (
          rpcCall(rHook, hookAbi, 'detonationAt') as Promise<bigint>
        ).catch(() => undefined)
      }
      // greenlist-IBCO: phase facts + window ends off the era-aware lane —
      // legacy rounds collapse to a single openEnd off PREDEPOSIT_DURATION.
      const windowEnds = ibcoEnds(pd?.state?.startTime, pd?.facts?.greenSec, pd?.facts?.openSec, pd?.facts?.legacySec, pd?.state?.greenPerWallet)
      shared = {
        readError: undefined,
        reinvestorReady,
        rulesCompatible,
        id, token: rToken, controller: rController, staker: rStaker, hook: rHook, mix,
        mode: Number(mode), reserve, supply, marginalPrice: livePrice,
        potBalance, ticketPrice,
        ticketRules,
        swapFeeBps,
        totalLocked,
        predepositClosed: pd?.state?.closed, predepositStartTime: pd?.state?.startTime,
        totalPredeposit: pd?.state?.total, predepositCap: pd?.state?.cap,
        predepositPhase: pd?.state?.phase, greenTotal: pd?.state?.greenTotal,
        greenPerWallet: pd?.state?.greenPerWallet, openPerWallet: pd?.state?.openPerWallet,
        ...windowEnds,
        predepositDuration: windowEnds.openEnd !== undefined && pd?.state?.startTime !== undefined ? windowEnds.openEnd - pd.state.startTime : undefined,
        sine: shared.hook === rHook ? shared.sine : null,
        detonationAt,
        detWindow,
        flatTime,
        curve: { p0: cfg[0], zones: zones.map((z) => ({ ...z })) },
      }
      backoffMs = 0
      listeners.forEach((l) => l(shared))
      // Publish balances and clock before the larger chart sample completes.
      const sine = await loadSineCurve(rHook, Number(reserve) / 1e18).catch(() => shared.sine)
      shared = { ...shared, sine }
      listeners.forEach((l) => l(shared))
    } catch (error) {
      console.warn('Could not refresh PSP round data:', error)
      shared = { ...shared, readError: 'The RPC connection is unavailable. Retrying round data automatically.' }
      listeners.forEach(l => l(shared))
      /* round not resolvable / rpc down — keep last state, back off */
      backoffMs = backoffMs ? Math.min(backoffMs * 2, 60_000) : 8_000
    } finally {
      inFlight = false
    }
    schedule()
  }
  tick()
}

/// Subscribes to the shared round state (single polling loop for the whole
/// app). Raw eth_call — wagmi v2 useReadContracts sits idle on custom chains.
export function useRound(): RoundInfo {
  const [info, setInfo] = useState<RoundInfo>(shared)

  useEffect(() => {
    startRoundLoop()
    const l: RoundListener = (i) => setInfo(i)
    listeners.add(l)
    return () => { listeners.delete(l) }
  }, [])

  return info
}

export function useBalances(token: `0x${string}` | undefined, mix: `0x${string}` | undefined, refreshKey = 0) {
  const { address } = useAccount()
  const [bal, setBal] = useState<{ psp: bigint | undefined; mix: bigint | undefined }>({ psp: undefined, mix: undefined })

  useEffect(() => {
    if (!address || !token) { setBal({ psp: undefined, mix: undefined }); return }
    const who = address
    const pspToken = token
    let dead = false
    async function tick() {
      try {
        const [psp, m] = await Promise.all([
          rpcCall(pspToken, erc20Abi, 'balanceOf', [who]) as Promise<bigint>,
          mix
            ? (rpcCall(mix as `0x${string}`, erc20Abi, 'balanceOf', [who]) as Promise<bigint>)
            : Promise.resolve<bigint | undefined>(undefined),
        ])
        if (!dead) setBal({ psp, mix: m })
      } catch { /* keep last */ }
    }
    tick()
    const iv = setInterval(tick, 4000)
    return () => { dead = true; clearInterval(iv) }
  }, [address, token, mix, refreshKey])

  return bal
}
