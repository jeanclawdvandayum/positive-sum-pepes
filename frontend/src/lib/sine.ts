import { rpcCall } from './rpc'
import { hookAbi } from './abi'
import { sampleSineChart, type SineCurveData, type SineMarker } from './sineChart'
export type { SineCurveData, SineMarker } from './sineChart'

const cache = new Map<string, Promise<SineCurveData>>()

/** Three reads on first load, then no RPC work for the chart after launch. */
export function loadSineCurve(hook: `0x${string}`): Promise<SineCurveData> {
  const key = hook.toLowerCase()
  let promise = cache.get(key)
  if (!promise) {
    promise = Promise.all([
      rpcCall(hook, hookAbi, 'sineConfigured') as Promise<boolean>,
      rpcCall(hook, hookAbi, 'sineActive') as Promise<boolean>,
      rpcCall(hook, hookAbi, 'sineCurve') as Promise<bigint[]>,
    ]).then(([configured, active, raw]) => {
      if (configured && active) return sampleSineChart(raw)
      cache.delete(key) // The same predeposit hook can materialize later.
      return { active: false, configured, boot: 0, span: 0, top: 0, q0: 0n,
        checkpoints: [], points: [], markers: [] }
    })
    cache.set(key, promise)
    promise.catch(() => cache.delete(key))
  }
  return promise
}

/// human-readable tag for a marker (chart labels)
export function markerLabel(m: SineMarker, fmtPrice: (v: bigint) => string): string {
  const p = fmtPrice(BigInt(Math.round(m.price * 1e18)))
  if (m.kind === 'boot') return `launch ${p}`
  if (m.k === 4) return `wave 1 top ${p}`
  if (m.k === 8) return `wave 2 top ${p}`
  if (m.k === 12) return `target tread ${p}`
  return ''
}
