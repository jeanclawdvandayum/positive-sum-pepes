import { stakerAbi } from './abi'
import { rpcCall } from './rpc'

/** Bounded concurrency without silently truncating a wallet's assets. */
export async function mapBatched<T, R>(items: T[], read: (item: T) => Promise<R>, size = 8): Promise<R[]> {
  const results: R[] = []
  for (let i = 0; i < items.length; i += size) {
    results.push(...await Promise.all(items.slice(i, i + size).map(read)))
  }
  return results
}

/** Graveyard collections include empty NFTs, which remain owned after withdrawal. */
export async function readPositions(staker: `0x${string}`, owner: `0x${string}`, includeEmpty = false) {
  const count = await rpcCall(staker, stakerAbi, 'balanceOf', [owner]) as bigint
  if (count > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('Position count exceeds supported enumeration.')
  const indices = Array.from({ length: Number(count) }, (_, i) => BigInt(i))
  const positions = await mapBatched(indices, async i => {
    const id = await rpcCall(staker, stakerAbi, 'tokenOfOwnerByIndex', [owner, i]) as bigint
    const [result, pendingFees] = await Promise.all([
      rpcCall(staker, stakerAbi, 'positions', [id]) as Promise<bigint[]>,
      rpcCall(staker, stakerAbi, 'pendingFeesOf', [id]) as Promise<bigint>,
    ])
    return { id, amount: result[0], pendingFees }
  })
  return includeEmpty ? positions : positions.filter(p => p.amount > 0n || p.pendingFees > 0n)
}
