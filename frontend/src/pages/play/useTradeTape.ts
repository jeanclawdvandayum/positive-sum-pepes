import { useEffect, useMemo, useState } from 'react'
import { usePublicClient } from 'wagmi'
import { parseAbiItem } from 'viem'
import { useRound } from '../../lib/useRound'

// ─────────────────────────────────────────────────────────────────────────────
// useTradeTape — the play page's ONE getLogs lane (REDESIGN-B2 §2/§6).
//
// This is the StatsPanel lane moved 1:1 into the play tree (StatsPanel was
// dissolved when its cards folded into the TickerBar): same three getLogs
// pulls — Buy + Sell from the hook, FeesAdded from the controller, fromBlock
// 0 — and the same watchBlockNumber re-pull per new block. NO new chain
// calls, NO new cadence (red-line: read fan-out stays centralized; this is
// the lane's single new home).
//
// Feeds: the live tape (per-trade entries), the TickerBar (volume / fees to
// stakers), the curve's entry mark (vw avg buy price of the connected
// address — derived from these same logs, nothing extra read), and the
// clock's TimeAdded lane (CLOCK-REDESIGN §6.6: same getLogs pull, one more
// event — a buy that injected time renders as one row with its +5:00, and
// the newest injection drives the clock panel's "last added" line).
// ─────────────────────────────────────────────────────────────────────────────

export interface TapeEntry {
  id: string // `${block}-${logIndex}` — stable keys across per-block re-pulls
  kind: 'buy' | 'sell'
  addr: `0x${string}`
  pspWad: bigint
  mixWad: bigint
  price: number // mixETH per PSP
  block: bigint
  logIndex: number
  /// CLOCK-REDESIGN §1/§6: set when this buy's tx also emitted TimeAdded —
  /// the whole-PSP time injection (+5:00 per whole psp) rides the SAME tx
  /// as the Buy, so the tape folds both into one row instead of duplicating.
  addedMs?: number
}

/// newest TimeAdded — feeds the clock panel's "last added by X · Ym ago" line.
export interface LastTimeAdded {
  addr: `0x${string}`
  wholePsp: bigint
  /** block timestamp in unix seconds, when the RPC provides it on logs */
  atSec: number | undefined
}

const buyEvent = parseAbiItem(
  'event Buy(address indexed buyer, uint256 mixETHIn, uint256 pspOut, uint256 newSupply, uint256 newReserveMixETH)',
)
const sellEvent = parseAbiItem(
  'event Sell(address indexed seller, uint256 pspIn, uint256 mixETHOut, uint256 newSupply, uint256 newReserveMixETH)',
)
const feesEvent = parseAbiItem('event FeesAdded(uint256 mixETHAmount)')
const timeEvent = parseAbiItem(
  'event TimeAdded(address indexed buyer, uint256 wholePsp, uint256 newDetonationAt)',
)

export function useTradeTape() {
  const round = useRound()
  const client = usePublicClient()
  const [entries, setEntries] = useState<TapeEntry[]>([]) // newest first
  const [feesWad, setFeesWad] = useState<bigint>(0n)
  const [volumeWad, setVolumeWad] = useState<bigint>(0n)
  const [lastTime, setLastTime] = useState<LastTimeAdded | undefined>(undefined)

  useEffect(() => {
    if (!client || !round.hook || !round.controller) return
    const c = client
    const hookAddr = round.hook
    const ctrlAddr = round.controller
    let dead = false

    async function load() {
      const [buys, sells, feeLogs, timeLogs] = await Promise.all([
        c.getLogs({ address: hookAddr, event: buyEvent, fromBlock: 0n }),
        c.getLogs({ address: hookAddr, event: sellEvent, fromBlock: 0n }),
        c.getLogs({ address: ctrlAddr, event: feesEvent, fromBlock: 0n }),
        // same lane, same pull — the clock's injection event (spec §6.6)
        c.getLogs({ address: hookAddr, event: timeEvent, fromBlock: 0n }),
      ])
      if (dead) return

      // TimeAdded(txHash) → wholePsp: buys fold their +5:00 into one row
      const addedByTx = new Map<string, bigint>()
      let newest: LastTimeAdded | undefined
      let newestBn = -1n
      let newestLi = -1
      for (const l of timeLogs) {
        const who = l.args.buyer
        const whole = l.args.wholePsp
        if (!who || whole === undefined) continue
        if (l.transactionHash) addedByTx.set(l.transactionHash, whole)
        // numeric recency (block, then logIndex) — string keys mis-sort
        // across digit lengths ("999-9" > "1000-0")
        const li = l.logIndex ?? 0
        if (l.blockNumber > newestBn || (l.blockNumber === newestBn && li > newestLi)) {
          newestBn = l.blockNumber
          newestLi = li
          newest = {
            addr: who as `0x${string}`,
            wholePsp: whole,
            atSec: l.blockTimestamp !== undefined ? Number(l.blockTimestamp) : undefined,
          }
        }
      }
      setLastTime(newest)

      const t: TapeEntry[] = []
      let volume = 0n
      for (const l of buys) {
        const mix = l.args.mixETHIn
        const psp = l.args.pspOut
        if (mix === undefined || psp === undefined || psp <= 0n) continue
        const whole = l.transactionHash ? addedByTx.get(l.transactionHash) : undefined
        t.push({
          id: `${l.blockNumber}-${l.logIndex ?? 0}`,
          kind: 'buy',
          addr: l.args.buyer as `0x${string}`,
          pspWad: psp,
          mixWad: mix,
          price: Number(mix) / Number(psp),
          block: l.blockNumber,
          logIndex: l.logIndex ?? 0,
          addedMs: whole !== undefined ? Number(whole) * 300_000 : undefined, // 5min/whole psp
        })
        volume += mix
      }
      for (const l of sells) {
        const psp = l.args.pspIn
        const mix = l.args.mixETHOut
        if (mix === undefined || psp === undefined || psp <= 0n) continue
        t.push({
          id: `${l.blockNumber}-${l.logIndex ?? 0}`,
          kind: 'sell',
          addr: l.args.seller as `0x${string}`,
          pspWad: psp,
          mixWad: mix,
          price: Number(mix) / Number(psp),
          block: l.blockNumber,
          logIndex: l.logIndex ?? 0,
        })
        volume += mix
      }
      // ascending by block, then logIndex (stable tape order within a block)
      t.sort((a, b) =>
        a.block < b.block ? -1 : a.block > b.block ? 1 : a.logIndex - b.logIndex,
      )
      setEntries(t.reverse())
      setVolumeWad(volume)
      setFeesWad(feeLogs.reduce((acc, l) => acc + (l.args.mixETHAmount ?? 0n), 0n))
    }

    load().catch(() => {})
    const un = client.watchBlockNumber({ onBlockNumber: () => load().catch(() => {}) })
    return () => {
      dead = true
      un()
    }
  }, [client, round.hook, round.controller])

  const counts = useMemo(() => {
    let buys = 0
    for (const e of entries) if (e.kind === 'buy') buys++
    return { buys, sells: entries.length - buys, count: entries.length }
  }, [entries])

  // per-address buy sums → vw avg entry price (mixETH per PSP), logs only
  const entryByAddr = useMemo(() => {
    const m = new Map<`0x${string}`, { mix: bigint; psp: bigint }>()
    for (const e of entries) {
      if (e.kind !== 'buy') continue
      const acc = m.get(e.addr) ?? { mix: 0n, psp: 0n }
      acc.mix += e.mixWad
      acc.psp += e.pspWad
      m.set(e.addr, acc)
    }
    return m
  }, [entries])

  function entryPriceOf(addr: `0x${string}` | undefined): number | undefined {
    if (!addr) return undefined
    const acc = entryByAddr.get(addr)
    if (!acc || acc.psp <= 0n) return undefined
    return Number(acc.mix) / Number(acc.psp)
  }

  return { entries, feesWad, volumeWad, lastTime, ...counts, entryPriceOf }
}
