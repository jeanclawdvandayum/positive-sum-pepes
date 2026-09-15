import { readSineRulesVersion } from './sineVersion.ts'
import { sampleSineChart, sineChartHeadroom, type SineCurveData } from './sineChart.ts'

type Address = `0x${string}`
type Read = (hook: Address, name: string) => Promise<unknown>

/** Cache curve coefficients only after launch. Failed and prelaunch reads retry. */
export function createSineCurveReader(read: Read) {
  const cache = new Map<string, Promise<{ raw: bigint[]; version: 1 | 2 | 3; data: SineCurveData }>>()
  return async (hook: Address, liveReserve = 0): Promise<SineCurveData> => {
    const key = hook.toLowerCase()
    let promise = cache.get(key)
    if (!promise) {
      promise = Promise.all([
        read(hook, 'sineConfigured') as Promise<boolean>,
        read(hook, 'sineActive') as Promise<boolean>,
        readSineRulesVersion(() => read(hook, 'SINE_RULES_VERSION')),
      ]).then(async ([configured, active, version]) => {
        if (configured && active) {
          const raw = await read(hook, version === 3 ? 'sineV3Info' : 'sineCurve') as bigint[]
          return { raw, version, data: sampleSineChart(raw, liveReserve, version) }
        }
        return { raw: [] as bigint[], version, data: { active: false, configured, boot: 0, span: 0, top: 0, q0: 0n,
          checkpoints: [], points: [], markers: [] } }
      })
      cache.set(key, promise)
    }
    let cached: Awaited<typeof promise>
    try { cached = await promise }
    catch (error) {
      if (cache.get(key) === promise) cache.delete(key)
      throw error
    }
    const { data, raw, version } = cached
    if (!data.active) {
      // AUD-V3-4: launch changes this state on the same hook address.
      if (cache.get(key) === promise) cache.delete(key)
      return data
    }
    const lam = Number(version === 3 ? raw[3] : raw[4]) / 1e18
    if (!data.truncated && data.points.at(-1)!.reserve < sineChartHeadroom(liveReserve, lam, version)) {
      cached.data = sampleSineChart(raw, liveReserve, version)
    }
    return cached.data
  }
}
