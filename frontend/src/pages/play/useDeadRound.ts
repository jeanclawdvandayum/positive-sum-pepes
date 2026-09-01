// ─────────────────────────────────────────────────────────────────────────────
// useDeadRound — the post-round lane (CLOCK-REDESIGN §4/§5, §6.4).
//
// detonate() births the next round in the same tx, so AFTER the boom the
// factory's current round is the new predeposit one and the dead round is
// `id - 1` (hook custodies backing + pot forever). This lane finds the dead
// round, whatever shape the transition took:
//   · advanced (the spec'd path): current round is Predeposit, previous
//     round's hook is Flat/Destroyed → dead = previous
//   · not-yet-advanced: the CURRENT round's hook is already Flat/Destroyed
//     → dead = current
// and then runs the redemption-portal read set on it: frozen R/S, pot,
// claimablePot(me), my PSP balance + allowance, my staked positions (for
// the immediate unlock — at Flat withdraw skips the vest entirely).
//
// Cadence mirrors useRpcReads (6s, 8s → 60s backoff). Every read is
// per-read isolated: probes on rounds with no corpse simply answer "no
// dead round", and one reverting read can never sink the tick. Probing is
// cheap (id + rounds + one mode) — the full fan-out only runs on a found
// dead round with a connected wallet.
// ─────────────────────────────────────────────────────────────────────────────

import { useEffect, useState } from 'react'
import { useAccount } from 'wagmi'
import { factoryAbi, hookAbi, controllerAbi, stakerAbi, erc20Abi } from '../../lib/abi'
import { rpcCall } from '../../lib/rpc'
import { ADDRESSES } from '../../lib/config'

export interface DeadPosition {
  id: bigint
  amount: bigint
}

export interface DeadRoundState {
  /** lane has completed at least one tick */
  checked: boolean
  /** a settled round exists (hook in Flat or Destroyed) */
  dead: boolean
  roundId: bigint | undefined
  name: string | undefined
  token: `0x${string}` | undefined
  controller: `0x${string}` | undefined
  hook: `0x${string}` | undefined
  staker: `0x${string}` | undefined
  /** 2 = flat, 3 = destroyed — both redeemable forever */
  mode: number | undefined
  reserve: bigint | undefined
  supply: bigint | undefined
  pot: bigint | undefined
  claimable: bigint | undefined
  pspBal: bigint | undefined
  pspAllowance: bigint | undefined
  positions: DeadPosition[]
}

const IDLE: DeadRoundState = {
  checked: false, dead: false, roundId: undefined, name: undefined,
  token: undefined, controller: undefined, hook: undefined, staker: undefined,
  mode: undefined, reserve: undefined, supply: undefined, pot: undefined,
  claimable: undefined, pspBal: undefined, pspAllowance: undefined, positions: [],
}

type RoundRow = [`0x${string}`, `0x${string}`, `0x${string}`, boolean, string]

const isZeroAddr = (a: string | undefined) => !a || /^0x0+$/.test(a)

/// isolated read: reverts resolve undefined instead of sinking the tick
function get<T>(to: `0x${string}` | undefined, abi: readonly unknown[], fn: string, args: readonly unknown[] = []): Promise<T | undefined> {
  if (!to || isZeroAddr(to)) return Promise.resolve(undefined)
  return rpcCall(to, abi, fn, args) as Promise<T>
}

/// soft read: for views a pre-clock corpse hook never had (potBalance,
/// claimablePot) — their absence must degrade the portal, not kill it
function soft<T>(p: Promise<T | undefined>): Promise<T | undefined> {
  return p.catch(() => undefined)
}

const MAX_POSITIONS = 8 // display + one-click unlock; the stake page owns deep lists

export function useDeadRound(): DeadRoundState {
  const { address } = useAccount()
  const [state, setState] = useState<DeadRoundState>(IDLE)

  useEffect(() => {
    let dead = false
    let timer: ReturnType<typeof setTimeout> | undefined
    let backoff = 0
    const who = address
    const F = ADDRESSES.factory as `0x${string}`

    async function run() {
      try {
        const id = await get<bigint>(F, factoryAbi, 'currentRoundId')
        if (id === undefined) throw new Error('no factory')
        const cur = await get<RoundRow>(F, factoryAbi, 'rounds', [id])
        let deadId: bigint | undefined
        let row = cur
        // shape 1: the current round itself went flat (transition not advanced)
        const curMode = cur?.[2] ? await get<bigint>(cur[2], hookAbi, 'mode') : undefined
        if (curMode !== undefined && Number(curMode) >= 2) {
          deadId = id
        } else if (id > 0n) {
          // shape 2 (spec §4): detonate spawned the next round; the corpse is id-1
          const prev = await get<RoundRow>(F, factoryAbi, 'rounds', [id - 1n])
          const prevMode = prev?.[2] ? await get<bigint>(prev[2], hookAbi, 'mode') : undefined
          if (prevMode !== undefined && Number(prevMode) >= 2) {
            deadId = id - 1n
            row = prev
          }
        }

        if (deadId === undefined || !row) {
          if (!dead) setState({ ...IDLE, checked: true, dead: false })
          backoff = 0
          timer = setTimeout(run, 6000)
          return
        }

        const [token, controller, hook] = [row[0], row[1], row[2]]
        const [mode, reserve, supply, pot, staker] = await Promise.all([
          get<bigint>(hook, hookAbi, 'mode'),
          get<bigint>(hook, hookAbi, 'reserveMixETH'),
          get<bigint>(hook, hookAbi, 'totalSupplyPSP'),
          soft(get<bigint>(hook, hookAbi, 'potBalance')),
          get<`0x${string}`>(controller, controllerAbi, 'staker'),
        ])

        // wallet-scoped reads — skipped entirely without a connection
        let claimable: bigint | undefined
        let pspBal: bigint | undefined
        let pspAllowance: bigint | undefined
        let positions: DeadPosition[] = []
        if (who) {
          const me = who as `0x${string}`
          const [clm, bal, alw, nStaked] = await Promise.all([
            soft(get<bigint>(hook, hookAbi, 'claimablePot', [me])),
            get<bigint>(token, erc20Abi, 'balanceOf', [me]),
            get<bigint>(token, erc20Abi, 'allowance', [me, hook]),
            staker ? get<bigint>(staker, stakerAbi, 'balanceOf', [me]) : Promise.resolve(undefined),
          ])
          claimable = clm
          pspBal = bal
          pspAllowance = alw
          const n = nStaked !== undefined ? Math.min(Number(nStaked), MAX_POSITIONS) : 0
          if (n > 0 && staker) {
            const ids = (
              await Promise.all(
                Array.from({ length: n }, (_, i) =>
                  get<bigint>(staker, stakerAbi, 'tokenOfOwnerByIndex', [me, BigInt(i)]),
                ),
              )
            ).filter((x): x is bigint => x !== undefined)
            const amounts = await Promise.all(
              ids.map((tid) =>
                get<[bigint, ...bigint[]]>(staker, stakerAbi, 'positions', [tid]).then(
                  (p) => (p ? { id: tid, amount: p[0] } : undefined),
                ),
              ),
            )
            positions = amounts.filter((x): x is DeadPosition => x !== undefined && x.amount > 0n)
          }
        }

        if (!dead) {
          setState({
            checked: true,
            dead: true,
            roundId: deadId,
            name: row[4],
            token, controller, hook, staker,
            mode: mode !== undefined ? Number(mode) : undefined,
            reserve, supply, pot, claimable, pspBal, pspAllowance, positions,
          })
          backoff = 0
        }
      } catch {
        /* rpc hiccup — keep last state, back off */
        if (!dead) backoff = backoff ? Math.min(backoff * 2, 60_000) : 8_000
      }
      if (!dead) timer = setTimeout(run, backoff || 6000)
    }

    run()
    return () => {
      dead = true
      if (timer) clearTimeout(timer)
    }
  }, [address])

  return state
}
