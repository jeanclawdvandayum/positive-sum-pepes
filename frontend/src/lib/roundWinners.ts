import { hookAbi } from './abi.ts'

type Address = `0x${string}`
type BatchRead = (
  to: Address,
  abi: readonly unknown[],
  calls: readonly { functionName: string; args?: readonly unknown[] }[],
) => Promise<readonly unknown[]>

export interface RoundWinner {
  address: Address
  ranks: number[]
  payout: bigint
  sharePercent: number
}

// CurveHook._ladderBps, newest seat first. Claims floor each seat separately,
// then sum a wallet's seats; flooring the combined share would overstate prizes.
const WEIGHTS = [2500n, 1800n, 1400n, 1000n, 800n, 700n, 600n, 500n, 400n, 300n]

export function groupRoundWinners(pot: bigint, buyers: readonly Address[]): RoundWinner[] {
  if (pot < 0n || buyers.length > WEIGHTS.length) throw new Error('Invalid final ladder')
  const denominator = WEIGHTS.slice(0, buyers.length).reduce((sum, weight) => sum + weight, 0n)
  const winners = new Map<string, RoundWinner>()
  buyers.forEach((address, index) => {
    if (!/^0x[0-9a-fA-F]{40}$/.test(address) || /^0x0+$/i.test(address)) {
      throw new Error('Invalid winner address')
    }
    const key = address.toLowerCase()
    const winner = winners.get(key) ?? { address, ranks: [], payout: 0n, sharePercent: 0 }
    winner.ranks.push(index + 1)
    winner.payout += pot * WEIGHTS[index] / denominator
    winners.set(key, winner)
  })
  return [...winners.values()].map(winner => ({
    ...winner,
    sharePercent: Number(winner.ranks.reduce((sum, rank) => sum + WEIGHTS[rank - 1], 0n)) * 100 / Number(denominator),
  }))
}

/** The settled hook keeps the full pot and final board after claims. Read that
 * archive, rather than claimablePot (which drops to zero once a wallet claims).
 * A failed seat read rejects the whole list instead of renormalizing partial data. */
export async function readRoundWinners(read: BatchRead, hook: Address) {
  const [mode, pot, ticketCount] = await read(hook, hookAbi, [
    { functionName: 'mode' },
    { functionName: 'potBalance' },
    { functionName: 'ticketCount' },
  ])
  if ((Number(mode) !== 2 && Number(mode) !== 3) || typeof pot !== 'bigint' ||
      typeof ticketCount !== 'bigint' || ticketCount < 0n) {
    throw new Error('Final ladder is unavailable')
  }
  const seats = Number(ticketCount > 10n ? 10n : ticketCount)
  const board = seats === 0 ? [] : await read(hook, hookAbi,
    Array.from({ length: seats }, (_, i) => ({ functionName: 'board', args: [BigInt(i)] })),
  )
  if (board.length !== seats) throw new Error('Incomplete final ladder')
  const buyers = board.map(row => {
    if (!Array.isArray(row) || typeof row[0] !== 'string') throw new Error('Invalid final ladder')
    return row[0] as Address
  })
  return { winners: groupRoundWinners(pot, buyers), seats }
}
