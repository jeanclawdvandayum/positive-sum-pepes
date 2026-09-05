import { createPublicClient, encodeFunctionData, decodeFunctionResult, type Address, type Abi, type Chain, type HttpTransportConfig } from 'viem'
import { rpcTransport } from './rpcTransport.ts'

/** Shared read-only transport: batch calls, deduplicate concurrent reads and
 * bound stalled requests. Polling hooks own retries/backoff, avoiding retry storms. */
export function createRpcReader(url: string, options: Pick<HttpTransportConfig, 'fetchFn' | 'timeout'> & { chain?: Chain; fallbackUrl?: string } = {}) {
  const { chain, fallbackUrl, ...httpOptions } = options
  const client = createPublicClient({ chain, batch: { multicall: { batchSize: 4096, wait: 20 } },
    transport: rpcTransport(url, fallbackUrl, httpOptions) })
  const pending = new Map<string, Promise<unknown>>()
  return {
    async call(to: Address, abi: readonly unknown[], functionName: string, args: readonly unknown[] = []): Promise<unknown> {
      if (!/^0x[0-9a-fA-F]{40}$/.test(to) || /^0x0+$/.test(to)) throw new Error(`rpc ${functionName}: no target address`)
      const data = encodeFunctionData({ abi: abi as Abi, functionName, args: args as never })
      const key = `${to.toLowerCase()}:${data}`
      let promise = pending.get(key)
      if (!promise) {
        promise = client.call({ to, data }).then(result => {
          if (!result.data) throw new Error(`rpc ${functionName}: no result`)
          return decodeFunctionResult({ abi: abi as Abi, functionName, data: result.data })
        }).finally(() => pending.delete(key))
        pending.set(key, promise)
      }
      return promise
    },
    async logs(fromBlock: bigint, toBlock: bigint, address: Address, topics: readonly (string | null)[]): Promise<unknown> {
      return client.request({ method: 'eth_getLogs', params: [{
        fromBlock: `0x${fromBlock.toString(16)}`, toBlock: `0x${toBlock.toString(16)}`,
        address, topics: topics as (`0x${string}` | null)[],
      }] }, { dedupe: true })
    },
  }
}
