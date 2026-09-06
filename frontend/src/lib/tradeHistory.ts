import { parseAbi } from 'viem'
import { createLogScanner } from './logScanner.ts'

type Address = `0x${string}`
export const tradeEvents = parseAbi([
  'event Buy(address indexed buyer, uint256 mixETHIn, uint256 pspOut, uint256 newSupply, uint256 newReserveMixETH)',
  'event Sell(address indexed seller, uint256 pspIn, uint256 mixETHOut, uint256 newSupply, uint256 newReserveMixETH)',
  'event FeesAdded(uint256 mixETHAmount)',
  'event TimeAdded(address indexed buyer, uint256 secondsAdded, uint256 newDetonationAt)',
])

export interface TradeLog {
  blockNumber: bigint
  logIndex: number | null
  transactionHash: string | null
  blockTimestamp?: bigint | null
  eventName: string
  args: { buyer?: Address; seller?: Address; mixETHIn?: bigint; pspOut?: bigint;
    pspIn?: bigint; mixETHOut?: bigint; mixETHAmount?: bigint; secondsAdded?: bigint }
}

export interface TapeEntry {
  id: string
  kind: 'buy' | 'sell'
  addr: Address
  pspWad: bigint
  mixWad: bigint
  price: number
  block: bigint
  logIndex: number
  addedMs?: number
}

export interface LastTimeAdded {
  addr: Address
  secondsAdded: bigint
  atSec: number | undefined
}

export interface TradeHistory {
  entries: TapeEntry[]
  lastTime: LastTimeAdded | undefined
  volumeWad: bigint | undefined
  feesWad: bigint | undefined
  complete: boolean
  error: boolean
}

export const EMPTY_HISTORY: TradeHistory = {
  entries: [], lastTime: undefined, volumeWad: undefined, feesWad: undefined,
  complete: false, error: false,
}

/** Controller construction pins predepositStartTime to its block timestamp.
 * Locate that inclusive block without rescanning earlier rounds' history. */
export async function findRoundStartBlock(
  timestamp: (block: bigint) => Promise<bigint>, startTime: bigint, floor: bigint, head: bigint,
): Promise<bigint> {
  if (floor > head || startTime > await timestamp(head)) throw new Error('Round start is ahead of the RPC head')
  let low = floor
  let high = head
  while (low < high) {
    const mid = (low + high) / 2n
    if (await timestamp(mid) < startTime) low = mid + 1n
    else high = mid
  }
  return low
}

/** Events can overlap during catch-up. A block/log index is counted once and
 * the newer copy wins, including zero-second TimeAdded events at the clock cap. */
export function summarizeTradeLogs(logs: readonly TradeLog[], complete: boolean): TradeHistory {
  const unique = new Map<string, TradeLog>()
  for (const log of logs) unique.set(`${log.blockNumber}-${log.logIndex}`, log)
  const ordered = [...unique.values()].sort((a, b) =>
    a.blockNumber === b.blockNumber ? (a.logIndex ?? 0) - (b.logIndex ?? 0)
      : a.blockNumber < b.blockNumber ? -1 : 1)
  let lastTime: LastTimeAdded | undefined
  let feesWad = 0n
  for (const log of ordered) {
    if (log.eventName === 'FeesAdded') feesWad += log.args.mixETHAmount ?? 0n
    if (log.eventName !== 'TimeAdded' || !log.args.buyer || log.args.secondsAdded === undefined) continue
    lastTime = { addr: log.args.buyer, secondsAdded: log.args.secondsAdded,
      atSec: log.blockTimestamp == null ? undefined : Number(log.blockTimestamp) }
  }
  let volumeWad = 0n
  const entries: TapeEntry[] = []
  // The hook emits TimeAdded before its corresponding Buy. A batch can buy
  // several times in one transaction, so consuming each event preserves its
  // own extension instead of stamping every buy with the transaction's last one.
  const pendingTime = new Map<string, { buyer: Address; seconds: bigint }>()
  for (const log of ordered) {
    if (log.eventName === 'TimeAdded' && log.transactionHash && log.args.buyer && log.args.secondsAdded !== undefined) {
      pendingTime.set(log.transactionHash, { buyer: log.args.buyer, seconds: log.args.secondsAdded })
    }
    const kind = log.eventName === 'Buy' ? 'buy' : log.eventName === 'Sell' ? 'sell' : undefined
    if (!kind) continue
    const { args } = log
    const psp = kind === 'buy' ? args.pspOut : args.pspIn
    const mix = kind === 'buy' ? args.mixETHIn : args.mixETHOut
    const addr = kind === 'buy' ? args.buyer : args.seller
    if (!addr || psp === undefined || psp <= 0n || mix === undefined) continue
    const time = kind === 'buy' && log.transactionHash ? pendingTime.get(log.transactionHash) : undefined
    const added = time?.buyer.toLowerCase() === addr.toLowerCase() ? time.seconds : undefined
    if (kind === 'buy' && log.transactionHash) pendingTime.delete(log.transactionHash)
    entries.push({ id: `${log.blockNumber}-${log.logIndex}`, kind, addr,
      pspWad: psp, mixWad: mix, price: Number(mix) / Number(psp),
      block: log.blockNumber, logIndex: log.logIndex ?? 0,
      addedMs: added === undefined ? undefined : Number(added) * 1000 })
    volumeWad += mix
  }
  return { entries: entries.reverse(), lastTime, complete, error: false,
    volumeWad: complete ? volumeWad : undefined, feesWad: complete ? feesWad : undefined }
}

interface HistorySource {
  head: () => Promise<bigint>
  timestamp: (block: bigint) => Promise<bigint>
  logs: (from: bigint, to: bigint) => Promise<TradeLog[]>
}

/** One reusable session per round. Recent trades load first, totals wait for
 * complete history, and failed refreshes preserve the last successful snapshot. */
export function createTradeHistoryReader(source: HistorySource, startTime: bigint, deploymentBlock: bigint) {
  let snapshot = EMPTY_HISTORY
  let startBlock: bigint | undefined
  let scanner: ReturnType<typeof createLogScanner<TradeLog>> | undefined
  let pending: Promise<TradeHistory> | undefined
  let recent: TradeLog[] = []
  let recentHead = -1n
  return {
    get snapshot() { return snapshot },
    poll(): Promise<TradeHistory> {
      if (pending) return pending
      pending = (async () => {
        try {
          const head = await source.head()
          startBlock ??= await findRoundStartBlock(source.timestamp, startTime, deploymentBlock, head)
          scanner ??= createLogScanner(source.logs, startBlock)
          if (!snapshot.complete && recentHead !== head) {
            const from = head - 999n > startBlock ? head - 999n : startBlock
            recent = await source.logs(from, head)
            recentHead = head
            snapshot = summarizeTradeLogs(recent, false)
          }
          const logs = await scanner.poll(head)
          const complete = scanner.scannedThrough !== undefined && scanner.scannedThrough >= head
          snapshot = summarizeTradeLogs(complete ? logs : [...logs, ...recent], complete)
          if (complete) recent = []
        } catch {
          snapshot = { ...snapshot, error: true }
        }
        return snapshot
      })().finally(() => { pending = undefined })
      return pending
    },
  }
}
