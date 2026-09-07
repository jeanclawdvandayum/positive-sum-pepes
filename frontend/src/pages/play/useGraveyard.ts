import { readPositions, mapBatched } from '../../lib/positions'
import { useEffect, useState } from 'react'
import { useAccount } from 'wagmi'
import { factoryAbi, controllerAbi, hookAbi, erc20Abi } from '../../lib/abi'
import { rpcCall } from '../../lib/rpc'
import { ADDRESSES } from '../../lib/config'

// useGraveyard — enumerates ALL dead rounds (hook in Flat or Destroyed) and
// reads the connected wallet's redeemable PSP + staked positions on each.
// One 6s tick, batched per round, per-read isolated.

export interface GraveyardRound {
  roundId: bigint
  name: string
  symbol: string
  token: `0x${string}`
  controller: `0x${string}`
  hook: `0x${string}`
  staker: `0x${string}` | undefined
  mode: number // 2 flat, 3 destroyed
  reserve: bigint
  supply: bigint
  pot: bigint | undefined
  pspBal: bigint
  claimablePot: bigint
  pspAllowance: bigint
  positions: { id: bigint; amount: bigint; pendingFees: bigint }[]
  unclaimedPredeposit: boolean
}

type RoundRow = [`0x${string}`, `0x${string}`, `0x${string}`, boolean, string]

export function useGraveyard(): {
  rounds: GraveyardRound[]
  checked: boolean
  error: string | null
} {
  const { address } = useAccount()
  const [rounds, setRounds] = useState<GraveyardRound[]>([])
  const [error, setError] = useState<string | null>(null)
  const [checked, setChecked] = useState(false)

  useEffect(() => {
    setRounds([])
    setChecked(false)
    setError(null)
    let dead = false
    let timer: ReturnType<typeof setTimeout> | undefined
    let backoff = 0
    const F = ADDRESSES.factory as `0x${string}`

    async function run() {
      try {
        const curId = (await rpcCall(F, factoryAbi, 'currentRoundId')) as bigint
        const found: GraveyardRound[] = []

        // probe every round 1..currentRoundId for a dead hook
        const probes = await mapBatched(
          Array.from({ length: Number(curId) }, (_, i) => BigInt(i + 1)),
          async rid => ({ rid, row: await rpcCall(F, factoryAbi, 'rounds', [rid]) as RoundRow }),
        )

        for (const probe of probes) {
          if (!probe) continue
          const { rid, row } = probe
          const [token, controller, hook] = [row[0], row[1], row[2]]
          const mode = (await rpcCall(hook, hookAbi, 'mode')) as bigint | undefined
          if (mode === undefined || Number(mode) < 2) continue // not dead

          const [reserve, supply, staker, pot] = await Promise.all([
            rpcCall(hook, hookAbi, 'reserveMixETH') as Promise<bigint>,
            rpcCall(hook, hookAbi, 'totalSupplyPSP') as Promise<bigint>,
            rpcCall(controller, controllerAbi, 'staker') as Promise<`0x${string}` | undefined>,
            // Frozen distribution base, not redemption reserves. An unavailable
            // archive amount must not block the existing exit controls.
            (rpcCall(hook, hookAbi, 'potBalance') as Promise<bigint>).catch(() => undefined),
          ])

          const gr: GraveyardRound = {
            roundId: rid, name: row[4] ?? `Round ${rid}`, symbol: '',
            token: token as `0x${string}`, controller: controller as `0x${string}`, hook: hook as `0x${string}`,
            staker, mode: Number(mode), reserve: reserve ?? 0n, supply: supply ?? 0n, pot,
            pspBal: 0n, pspAllowance: 0n, positions: [], claimablePot: 0n, unclaimedPredeposit: false,
          }

          // wallet-scoped reads
          if (address) {
            const me = address as `0x${string}`
            const [bal, alw] = await Promise.all([
              rpcCall(token as `0x${string}`, erc20Abi, 'balanceOf', [me]) as Promise<bigint>,
              rpcCall(token as `0x${string}`, erc20Abi, 'allowance', [me, hook as `0x${string}`]) as Promise<bigint>,
            ])
            gr.pspBal = bal
            gr.pspAllowance = alw

            gr.claimablePot = await rpcCall(hook, hookAbi, 'claimablePot', [me]) as bigint
            const deposit = await rpcCall(controller, controllerAbi, 'predeposits', [me]) as [bigint, boolean]
            gr.unclaimedPredeposit = deposit[0] > 0n && !deposit[1]
            if (staker) gr.positions = await readPositions(staker, me, true)
          }
          found.push(gr)
        }

        if (!dead) {
          setError(null)
          setRounds(found)
          setChecked(true)
          backoff = 0
        }
      } catch {
        if (!dead) setError('Could not refresh all holdings. Previously loaded values may be stale; retrying.')
        if (!dead) backoff = backoff ? Math.min(backoff * 2, 60_000) : 8_000
      }
      if (!dead) timer = setTimeout(run, backoff || 6000)
    }

    run()
    return () => { dead = true; if (timer) clearTimeout(timer) }
  }, [address])

  return { rounds, checked, error }
}
