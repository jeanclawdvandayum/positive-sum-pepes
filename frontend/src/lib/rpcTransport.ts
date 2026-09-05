import { fallback, http, type HttpTransportConfig } from 'viem'

/** No background ranking probes. A failed public node can fall back for reads
 * and simulations; contract reverts still fail instead of being retried. */
export function rpcTransport(url: string, fallbackUrl?: string, options: Pick<HttpTransportConfig, 'fetchFn' | 'timeout'> = {}) {
  const urls = [...new Set([url, fallbackUrl].filter((v): v is string => Boolean(v)))]
  const transports = urls.map(u => http(u, {
    batch: { batchSize: 20, wait: 20 }, timeout: 12_000, retryCount: 0, ...options,
  }))
  return transports.length === 1 ? transports[0] : fallback(transports, { rank: false, retryCount: 0 })
}
