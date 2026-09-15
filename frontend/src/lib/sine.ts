import { readSineRulesVersion } from './sineVersion'
import { chartWad } from './chartNumbers'
import { rpcCall } from './rpc'
import { hookAbi } from './abi'
import { sampleSineChart, sineChartHeadroom, type SineCurveData, type SineMarker } from './sineChart'
export type { SineCurveData, SineMarker } from './sineChart'

const cache = new Map<string, Promise<{ raw: bigint[]; version: 1 | 2 | 3; data: SineCurveData }>>()

/** Cache immutable coefficients; extend geometry locally as reserves grow.
 * v3 decodes sineV3Info (version-aware, one read); v1/v2 keep sineCurve. */
export async function loadSineCurve(hook: `0x${string}`, liveReserve = 0): Promise<SineCurveData> {
  const key = hook.toLowerCase()
  let promise = cache.get(key)
  if (!promise) {
    promise = Promise.all([
      rpcCall(hook, hookAbi, 'sineConfigured') as Promise<boolean>,
      rpcCall(hook, hookAbi, 'sineActive') as Promise<boolean>,
      readSineRulesVersion(() => rpcCall(hook, hookAbi, 'SINE_RULES_VERSION')),
    ]).then(async ([configured, active, version]) => {
      if (configured && active) {
        const raw = version === 3
          ? await rpcCall(hook, hookAbi, 'sineV3Info') as bigint[]
          : await rpcCall(hook, hookAbi, 'sineCurve') as bigint[]
        return { raw, version, data: sampleSineChart(raw, liveReserve, version) }
      }
      // The same predeposit hook can materialize later.
      return { raw: [] as bigint[], version, data: { active: false, configured, boot: 0, span: 0, top: 0, q0: 0n,
        checkpoints: [], points: [], markers: [] } }
    })
    cache.set(key, promise)
    promise.catch(() => cache.delete(key))
  }
  const cached = await promise
  const { data, raw, version } = cached
  // lam is raw[4] on the v1/v2 tuple, raw[3] on sineV3Info.
  const lam = Number(version === 3 ? raw[3] : raw[4]) / 1e18
  if (data.active && !data.truncated && data.points.at(-1)!.reserve < sineChartHeadroom(liveReserve, lam, version)) {
    cached.data = sampleSineChart(raw, liveReserve, version)
  }
  return cached.data
}

/// human-readable tag for a marker (chart labels)
export function markerLabel(m: SineMarker, fmtPrice: (v: bigint | undefined) => string, version: 1 | 2 | 3 = 1): string {
  const p = fmtPrice(chartWad(m.price))
  if (version === 3) {
    // Cube-root growth: each wave climbs a smaller log-step toward 1,000×.
    if (m.kind === 'boot') return `launch ${p}`
    const wave = m.k / 4
    return wave === 10 ? `wave 10 · 1,000× launch · ${p}` : `wave ${wave} top ${p}`
  }
  if (m.kind === 'boot') return `launch ${p}`
  if (m.k === 4) return `wave 1 top ${p}`
  if (m.k === 8) return `wave 2 top ${p}`
  if (m.k === 12) return `target tread ${p}`
  return ''
}
