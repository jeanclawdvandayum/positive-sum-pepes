/** Incremental history with bounded RPC ranges and a reorg overlap. Failed
 * pages leave the cursor unchanged; concurrent polls share one request. */
export function createLogScanner<T extends { blockNumber: bigint }>(
  read: (fromBlock: bigint, toBlock: bigint) => Promise<T[]>,
  startBlock: bigint,
  { pageSize = 1000n, maxPages = 4n, overlap = 12n } = {},
) {
  let cursor = startBlock
  let lastHead = -1n
  let logs: T[] = []
  let pending: Promise<T[]> | undefined
  return {
    poll(head: bigint): Promise<T[]> {
      if (pending) return pending
      if (head === lastHead && cursor > head) return Promise.resolve(logs)
      pending = (async () => {
        const next = cursor < head + 1n ? cursor : head + 1n
        const from = next - overlap > startBlock ? next - overlap : startBlock
        if (from > head) return logs
        const last = from + pageSize * maxPages - 1n
        const end = last < head ? last : head
        const fresh: T[] = []
        for (let at = from; at <= end; at += pageSize) {
          const to = at + pageSize - 1n < end ? at + pageSize - 1n : end
          fresh.push(...await read(at, to))
        }
        logs = logs.filter(log => log.blockNumber < from).concat(fresh)
        cursor = end + 1n
        lastHead = head
        return logs
      })().finally(() => { pending = undefined })
      return pending
    },
  }
}
