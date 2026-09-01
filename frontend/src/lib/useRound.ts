import { useEffect, useState } from 'react'
import { useAccount } from 'wagmi'
import { factoryAbi, controllerAbi, hookAbi, erc20Abi, stakerAbi } from './abi'
import { ADDRESSES } from './config'
import { rpcCall } from './rpc'
import type { CurveConfig, Zone } from './curve'
import { loadSineCurve, SineCurveData } from './sine'

export interface RoundInfo {
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
  totalLocked: bigint | undefined
  flatTime: bigint | undefined // bomb timestamp — nonzero = flat, locks open
  /// CLOCK-REDESIGN §1: the round's detonation time (SECONDS). undefined =
  /// not armed yet (predeposit), round not in Active mode, or the hook
  /// predates the clock (read reverts — caught, reported as undefined).
  detonationAt: bigint | undefined
  predepositClosed: boolean | undefined
  totalPredeposit: bigint | undefined
  predepositCap: bigint | undefined
  curve: CurveConfig | undefined
  /// tilted-sine flavor: static geometry sampled once per hook (cached);
  /// null when the hook runs the legacy zone curve or the RPC failed.
  sine: SineCurveData | null
}

const EMPTY: RoundInfo = {
  id: 0n, token: undefined, controller: undefined, staker: undefined, hook: undefined, mix: undefined,
  mode: undefined, reserve: undefined, supply: undefined, marginalPrice: undefined,
  totalLocked: undefined, predepositClosed: undefined, totalPredeposit: undefined,
  predepositCap: undefined, curve: undefined, flatTime: undefined, sine: null,
  detonationAt: undefined,
}

const F = ADDRESSES.factory as `0x${string}`

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
      const [id, mix] = await Promise.all([
        rpcCall(F, factoryAbi, 'currentRoundId') as Promise<bigint>,
        rpcCall(F, factoryAbi, 'mixETH') as Promise<`0x${string}`>,
      ])
      const [rToken, rController, rHook] = (await rpcCall(F, factoryAbi, 'rounds', [id])) as [
        `0x${string}`, `0x${string}`, `0x${string}`,
      ]
      const rStaker = (await rpcCall(rController, controllerAbi, 'staker')) as `0x${string}`
      // sine geometry is static once armed — the cached sampler runs once per
      // hook; the 4s loop below only refreshes the live scalars.
      const sine = await loadSineCurve(rHook).catch(() => null)
      const [mode, reserve, supply, mp, cfg, zones, totalLocked, pd, flatTime] = await Promise.all([
        rpcCall(rHook, hookAbi, 'mode') as Promise<bigint>,
        rpcCall(rHook, hookAbi, 'reserveMixETH') as Promise<bigint>,
        rpcCall(rHook, hookAbi, 'totalSupplyPSP') as Promise<bigint>,
        rpcCall(rHook, hookAbi, 'getMarginalPrice') as Promise<bigint>,
        rpcCall(rHook, hookAbi, 'curveConfig') as Promise<bigint>,
        rpcCall(rHook, hookAbi, 'getCurveZones') as Promise<Zone[]>,
        rpcCall(rStaker, stakerAbi, 'totalLocked') as Promise<bigint>,
        rpcCall(rController, controllerAbi, 'predepositState') as Promise<
          [bigint, bigint, bigint, boolean, boolean, boolean, boolean]
        >,
        rpcCall(rController, controllerAbi, 'flatTime') as Promise<bigint>,
      ])
      if (!rHook || !rController) return
      // sine flavor: the zone getMarginalPrice is legacy — price comes from
      // the wave at the live reserve
      let livePrice = mp as bigint
      if (sine?.active && reserve) {
        livePrice = (await rpcCall(rHook, hookAbi, 'sinePriceAt', [reserve])) as bigint
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
      shared = {
        id, token: rToken, controller: rController, staker: rStaker, hook: rHook, mix,
        mode: Number(mode), reserve, supply, marginalPrice: livePrice,
        totalLocked,
        predepositClosed: pd[3], totalPredeposit: pd[0], predepositCap: pd[1],
        flatTime,
        curve: { p0: cfg, zones: zones.map((z) => ({ ...z })) },
        sine,
        detonationAt,
      }
      backoffMs = 0
      listeners.forEach((l) => l(shared))
    } catch {
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

export function useBalances(token: `0x${string}` | undefined, mix: `0x${string}` | undefined) {
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
  }, [address, token, mix])

  return bal
}
