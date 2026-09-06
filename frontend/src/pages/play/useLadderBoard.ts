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
  seats: (BoardTicket | undefined)[]
  pot: bigint | undefined
  ticketCount: bigint | undefined
}

const EMPTY: BoardState = {
  seats: Array.from({ length: 10 }, () => undefined),
  pot: undefined,
  ticketCount: undefined,
}

const isZeroAddr = (a: string) => !a || /^0x0+$/.test(a)

export function useLadderBoard(hook: `0x${string}` | undefined): BoardState {
  const [state, setState] = useState<{ hook?: `0x${string}`; board: BoardState }>({ board: EMPTY })

  useEffect(() => {
    if (!hook) {
      setState({ board: EMPTY })
      return
    }
    const target: `0x${string}` = hook
    let dead = false
    let timer: ReturnType<typeof setTimeout> | undefined
    let backoff = 0

    async function run() {
      try {
        // per-promise catch with typed results — Promise.allSettled produces
        // a union type that leaks BoardTicket into the pot/ticketCount lanes
        const seatPromises = Array.from({ length: 10 }, (_, i) =>
          rpcCall(target, hookAbi, 'board', [BigInt(i)])
            .then((r) => {
              const [addr, psp, mix, ts] = r as [`0x${string}`, bigint, bigint, bigint]
              if (isZeroAddr(addr) || psp === 0n) return undefined
              return { addr, pspWad: psp, mixWad: mix, ts } satisfies BoardTicket
            })
            .catch(() => undefined as BoardTicket | undefined),
        )
        const potPromise = rpcCall(target, hookAbi, 'potBalance')
          .catch(() => undefined) as Promise<bigint | undefined>
        const tcPromise = rpcCall(target, hookAbi, 'ticketCount')
          .catch(() => undefined) as Promise<bigint | undefined>

        const [seatsRaw, pot, ticketCount] = await Promise.all([
          Promise.all(seatPromises),
          potPromise,
          tcPromise,
        ]) as [(BoardTicket | undefined)[], bigint | undefined, bigint | undefined]

        if (dead) return

        setState((snapshot) => {
          // Stale data is useful only for the SAME hook. A new round starts
          // empty even when its first read fails; never inherit old winners.
          const prev = snapshot.hook === target ? snapshot.board : EMPTY
          // stale-while-revalidate: if a seat read failed (undefined) but the
          // previous state had data, keep the old data instead of flashing empty
          const tc = ticketCount ?? prev.ticketCount ?? 0n
          const merged = seatsRaw.map((s, i) => {
            if (s !== undefined) return s
            if (BigInt(i) >= tc) return undefined // on-chain empty
            return prev.seats[i] // read failed — keep stale
          })
          return {
            hook: target,
            board: {
              seats: merged,
              pot: pot !== undefined ? pot : prev.pot,
              ticketCount: ticketCount !== undefined ? ticketCount : prev.ticketCount,
            },
          }
        })
        backoff = 0
      } catch {
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

  return state.hook === hook ? state.board : EMPTY
}
