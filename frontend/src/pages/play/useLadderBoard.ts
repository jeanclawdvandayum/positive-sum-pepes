// ─────────────────────────────────────────────────────────────────────────────
// useLadderBoard — the ticket lane (CLOCK-REDESIGN §2, §6.5).
//
// Reads the rolling last-10 board off a hook — board(0..9) + potBalance() —
// for BOTH consumers: the live ladder (rolling seats while the round trades)
// and the settled ladder (final distribution after detonation). Cadence
// mirrors useRpcReads exactly (6s, back off 8s → 60s through outages) — the
// sanctioned lane speed, nothing aggressive.
//
// Per-read isolation: an empty seat may revert OR return zeros (both shapes
// tolerated, both render as the designed empty seat) and must never sink
// the batch — the PotBoard contract is "board reads, no invented calls".
// Seat 0 is the NEWEST ticket (the ladder's #1, the 25% seat).
// ─────────────────────────────────────────────────────────────────────────────

import { useEffect, useState } from 'react'
import { hookAbi } from '../../lib/abi'
import { rpcCall } from '../../lib/rpc'

export interface BoardTicket {
  addr: `0x${string}`
  pspWad: bigint
  mixWad: bigint
  ts: bigint
}

export interface BoardState {
  /** 10 slots, newest first; undefined = empty seat */
  seats: (BoardTicket | undefined)[]
  /** pot escrowed on this hook — the payout-if-now / frozen payout base */
  pot: bigint | undefined
}

const EMPTY: BoardState = { seats: Array.from({ length: 10 }, () => undefined), pot: undefined }

const isZeroAddr = (a: string) => !a || /^0x0+$/.test(a)

export function useLadderBoard(hook: `0x${string}` | undefined): BoardState {
  const [state, setState] = useState<BoardState>(EMPTY)

  useEffect(() => {
    if (!hook) {
      setState(EMPTY)
      return
    }
    const target = hook
    let dead = false
    let timer: ReturnType<typeof setTimeout> | undefined
    let backoff = 0

    async function run() {
      try {
        const [seats, pot] = await Promise.all([
          Promise.all(
            Array.from({ length: 10 }, (_, i) =>
              rpcCall(target, hookAbi, 'board', [BigInt(i)])
                .then((r) => {
                  const [addr, psp, mix, ts] = r as [`0x${string}`, bigint, bigint, bigint]
                  if (isZeroAddr(addr) || psp === 0n) return undefined
                  return { addr, pspWad: psp, mixWad: mix, ts } satisfies BoardTicket
                })
                .catch(() => undefined), // seat past ticketCount — empty
            ),
          ),
          rpcCall(target, hookAbi, 'potBalance')
            .catch(() => undefined) as Promise<bigint | undefined>,
        ])
        if (!dead) {
          setState({ seats, pot })
          backoff = 0
        }
      } catch {
        /* rpc down — keep last state, back off */
        if (!dead) backoff = backoff ? Math.min(backoff * 2, 60_000) : 8_000
      }
      if (!dead) timer = setTimeout(run, backoff || 6000)
    }

    run()
    return () => {
      dead = true
      if (timer) clearTimeout(timer)
    }
  }, [hook])

  return state
}
