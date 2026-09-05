import { createPublicClient, http, encodeFunctionData, decodeFunctionResult, type Address, type Abi, type HttpTransportConfig } from 'viem'

/** Shared read-only transport: batch calls, deduplicate concurrent reads and
 * bound stalled requests. Polling hooks own retries/backoff, avoiding retry storms. */
export function createRpcReader(url: string, options: Pick<HttpTransportConfig, 'fetchFn' | 'timeout'> = {}) {
  const client = createPublicClient({ transport: http(url, {
    batch: { batchSize: 20, wait: 10 }, timeout: 20_000, retryCount: 0, ...options,
  }) })
  return {
    async call(to: Address, abi: readonly unknown[], functionName: string, args: readonly unknown[] = []): Promise<unknown> {
      if (!/^0x[0-9a-fA-F]{40}$/.test(to) || /^0x0+$/.test(to)) throw new Error(`rpc ${functionName}: no target address`)
      const data = encodeFunctionData({ abi: abi as Abi, functionName, args: args as never })
      const result = await client.request({ method: 'eth_call', params: [{ to, data }, 'latest'] }, { dedupe: true })
      if (!result) throw new Error(`rpc ${functionName}: no result`)
      return decodeFunctionResult({ abi: abi as Abi, functionName, data: result })
    },
    async logs(fromBlock: bigint, toBlock: bigint, address: Address, topics: readonly (string | null)[]): Promise<unknown> {
      return client.request({ method: 'eth_getLogs', params: [{
        fromBlock: `0x${fromBlock.toString(16)}`, toBlock: `0x${toBlock.toString(16)}`,
        address, topics: topics as (`0x${string}` | null)[],
      }] }, { dedupe: true })
    },
  }
}
