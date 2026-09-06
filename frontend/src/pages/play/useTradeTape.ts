import { DEPLOYMENT_BLOCK, CHAIN_ID } from '../../lib/config'
import { useEffect, useMemo, useState } from 'react'
import { usePublicClient } from 'wagmi'
import { useRound } from '../../lib/useRound'
import { createTradeHistoryReader, EMPTY_HISTORY, tradeEvents, type TradeHistory } from '../../lib/tradeHistory'
export type { TapeEntry, LastTimeAdded } from '../../lib/tradeHistory'

type HistoryReader = ReturnType<typeof createTradeHistoryReader>
// Keep a few round sessions across route changes. Each reader coalesces in-flight
// polls, and its key includes the client/network plus both contract addresses.
const readers = new Map<string, HistoryReader>()

export function useTradeTape() {
  const round = useRound()
  const client = usePublicClient({ chainId: CHAIN_ID })
  const reader = useMemo(() => {
    if (!client || !round.hook || !round.controller || round.predepositStartTime === undefined) return undefined
    const { hook, controller, predepositStartTime } = round
    const key = `${client.uid}:${hook}:${controller}:${predepositStartTime}`
    let cached = readers.get(key)
    if (!cached) {
      cached = createTradeHistoryReader({
        head: () => client.getBlockNumber({ cacheTime: 0 }),
        timestamp: async blockNumber => (await client.getBlock({ blockNumber })).timestamp,
        logs: (fromBlock, toBlock) => client.getLogs({
          address: [hook, controller], events: tradeEvents, fromBlock, toBlock, strict: true,
        }),
      }, predepositStartTime, DEPLOYMENT_BLOCK)
      readers.set(key, cached)
      if (readers.size > 4) readers.delete(readers.keys().next().value!)
    }
    return cached
  }, [client, round.hook, round.controller, round.predepositStartTime])
  const [state, setState] = useState<{ reader?: HistoryReader; history: TradeHistory }>({ history: EMPTY_HISTORY })
  // Never carry an earlier round's events or totals into a newly selected round.
  const history = state.reader === reader ? state.history : reader?.snapshot ?? EMPTY_HISTORY

  useEffect(() => {
    if (!reader) return
    let dead = false
    let timer: ReturnType<typeof setTimeout> | undefined
    let backoff = 0
    async function tick() {
      const history = await reader!.poll()
      if (dead) return
      setState({ reader, history })
      backoff = history.error ? Math.min(backoff ? backoff * 2 : 2000, 60_000) : 0
      // Catch up bounded pages promptly. Only the live poll waits twelve seconds.
      timer = setTimeout(tick, backoff || (history.complete ? 12_000 : 500))
    }
    tick()
    return () => { dead = true; if (timer) clearTimeout(timer) }
  }, [reader])

  const counts = useMemo(() => {
    const buys = history.entries.filter(entry => entry.kind === 'buy').length
    return { buys, sells: history.entries.length - buys, count: history.entries.length }
  }, [history.entries])
  const entryByAddr = useMemo(() => {
    const sums = new Map<string, { mix: bigint; psp: bigint }>()
    if (!history.complete) return sums
    for (const entry of history.entries) {
      if (entry.kind !== 'buy') continue
      const key = entry.addr.toLowerCase()
      const sum = sums.get(key) ?? { mix: 0n, psp: 0n }
      sum.mix += entry.mixWad
      sum.psp += entry.pspWad
      sums.set(key, sum)
    }
    return sums
  }, [history.entries, history.complete])
  function entryPriceOf(addr: `0x${string}` | undefined): number | undefined {
    const sum = addr ? entryByAddr.get(addr.toLowerCase()) : undefined
    return sum && sum.psp > 0n ? Number(sum.mix) / Number(sum.psp) : undefined
  }
  return { ...history, ...counts, entryPriceOf }
}
