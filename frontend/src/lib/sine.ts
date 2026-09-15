import { chartWad } from './chartNumbers'
import { rpcCall } from './rpc'
import { hookAbi } from './abi'
import type { SineMarker } from './sineChart'
import { createSineCurveReader } from './sineReader'
export type { SineCurveData, SineMarker } from './sineChart'

export const loadSineCurve = createSineCurveReader((hook, name) => rpcCall(hook, hookAbi, name))

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
