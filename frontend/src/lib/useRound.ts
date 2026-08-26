import { useEffect, useState } from 'react'
import { useAccount } from 'wagmi'
import { factoryAbi, controllerAbi, hookAbi, erc20Abi, stakerAbi } from './abi'
import { ADDRESSES } from './config'
import { rpcCall } from './rpc'
import type { CurveConfig, Zone } from './curve'

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
  predepositClosed: boolean | undefined
  totalPredeposit: bigint | undefined
  predepositCap: bigint | undefined
  curve: CurveConfig | undefined
}

const EMPTY: RoundInfo = {
  id: 0n, token: undefined, controller: undefined, staker: undefined, hook: undefined, mix: undefined,
  mode: undefined, reserve: undefined, supply: undefined, marginalPrice: undefined,
  totalLocked: undefined, predepositClosed: undefined, totalPredeposit: undefined,
  predepositCap: undefined, curve: undefined, flatTime: undefined,
}

const F = ADDRESSES.factory as `0x${string}`

/// Resolves the factory's current round + live state via direct JSON-RPC
/// polling. (wagmi v2 useReadContracts sits idle on our custom chain — raw
/// eth_call from the same page resolves fine, so we cut out the middleman.)
export function useRound(): RoundInfo {
  const [info, setInfo] = useState<RoundInfo>(EMPTY)

  useEffect(() => {
    let dead = false
    async function tick() {
      try {
        const id = (await rpcCall(F, factoryAbi, 'currentRoundId')) as bigint
        const mix = (await rpcCall(F, factoryAbi, 'mixETH')) as `0x${string}`
        const [rToken, rController, rHook] = (await rpcCall(F, factoryAbi, 'rounds', [id])) as [
          `0x${string}`, `0x${string}`, `0x${string}`,
        ]
        const rStaker = (await rpcCall(rController, controllerAbi, 'staker')) as `0x${string}`
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
        if (dead || !rHook || !rController) return
        setInfo({
          id, token: rToken, controller: rController, staker: rStaker, hook: rHook, mix,
          mode: Number(mode), reserve, supply, marginalPrice: mp,
          totalLocked,
          predepositClosed: pd[3], totalPredeposit: pd[0], predepositCap: pd[1],
          flatTime,
          curve: { p0: cfg, zones: zones.map((z) => ({ ...z })) },
        })
      } catch {
        /* round not resolvable yet — keep last state */
      }
    }
    tick()
    const iv = setInterval(tick, 4000)
    return () => { dead = true; clearInterval(iv) }
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
