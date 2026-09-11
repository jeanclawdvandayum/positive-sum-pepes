import { chartWad } from './chartNumbers'
import { rpcCall } from './rpc'
import { hookAbi } from './abi'
import { sampleSineChart, sineChartHeadroom, type SineCurveData, type SineMarker } from './sineChart'
export type { SineCurveData, SineMarker } from './sineChart'

const cache = new Map<string, Promise<{ raw: bigint[]; data: SineCurveData }>>()

/** Cache immutable coefficients; extend geometry locally as reserves grow. */
export async function loadSineCurve(hook: `0x${string}`, liveReserve = 0): Promise<SineCurveData> {
  const key = hook.toLowerCase()
  let promise = cache.get(key)
  if (!promise) {
    promise = Promise.all([
      rpcCall(hook, hookAbi, 'sineConfigured') as Promise<boolean>,
      rpcCall(hook, hookAbi, 'sineActive') as Promise<boolean>,
      rpcCall(hook, hookAbi, 'sineCurve') as Promise<bigint[]>,
    ]).then(([configured, active, raw]) => {
      if (configured && active) return { raw, data: sampleSineChart(raw, liveReserve) }
      cache.delete(key) // The same predeposit hook can materialize later.
      return { raw, data: { active: false, configured, boot: 0, span: 0, top: 0, q0: 0n,
        checkpoints: [], points: [], markers: [] } }
    })
    cache.set(key, promise)
    promise.catch(() => cache.delete(key))
  }
  const cached = await promise
  const { data, raw } = cached
  if (data.active && !data.truncated && data.points.at(-1)!.reserve < sineChartHeadroom(liveReserve, Number(raw[4]) / 1e18)) {
    cached.data = sampleSineChart(raw, liveReserve)
  }
  return cached.data
}

/// human-readable tag for a marker (chart labels)
export function markerLabel(m: SineMarker, fmtPrice: (v: bigint | undefined) => string): string {
  const p = fmtPrice(chartWad(m.price))
  if (m.kind === 'boot') return `launch ${p}`
  if (m.k === 4) return `wave 1 top ${p}`
  if (m.k === 8) return `wave 2 top ${p}`
  if (m.k === 12) return `target tread ${p}`
  return ''
}
