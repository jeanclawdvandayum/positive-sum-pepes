import { useEffect, useState } from 'react'
import { rpcCall } from './rpc'

export type RpcRead = {
  to: `0x${string}` | undefined
  abi: readonly unknown[]
  functionName: string
  args?: readonly unknown[]
}

const keyOf = (reads: RpcRead[]) =>
  reads
    .map((r) => `${r.to ?? ''}:${r.functionName}:${(r.args ?? []).map((a) => String(a)).join(',')}`)
    .join('|')

/// useReadContracts minus wagmi: same ordered-results shape, but raw
/// eth_call through our rpc layer — the wagmi multicall path sits idle
/// forever on locally-defined chains (see useRound's header note: every
/// read in this app goes through rpcCall for exactly this reason).
/// Polls every intervalMs, backs off 8s → 60s through rpc outages, and
/// resolves undefined for undefined targets (matches the old optional
/// `enabled` semantics when callers pass placeholders).
export function useRpcReads(reads: RpcRead[], enabled = true, intervalMs = 6000) {
  const [results, setResults] = useState<Array<unknown | undefined>>(() => reads.map(() => undefined))
  const key = keyOf(reads)

  useEffect(() => {
    if (!enabled) return
    let dead = false
    let timer: ReturnType<typeof setTimeout> | undefined
    let backoff = 0

    async function run() {
      try {
        const out = await Promise.all(
          reads.map((r) =>
            r.to ? rpcCall(r.to, r.abi, r.functionName, r.args ?? []) : Promise.resolve(undefined),
          ),
        )
        if (!dead) {
          setResults(out)
          backoff = 0
        }
      } catch {
        /* rpc down — keep last results, back off */
        if (!dead) backoff = backoff ? Math.min(backoff * 2, 60_000) : 8_000
      }
      if (!dead) timer = setTimeout(run, backoff || intervalMs)
    }

    run()
    return () => {
      dead = true
      if (timer) clearTimeout(timer)
    }
    // reads identity changes per render — the serialized key is the dep
  }, [key, enabled])

  return results
}
