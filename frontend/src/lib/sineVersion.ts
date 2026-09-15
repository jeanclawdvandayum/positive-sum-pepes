/** Legacy hooks have no version selector. Transport failures must retry. */
export type SineRulesVersion = 1 | 2 | 3

/** v3 (2026-09-14): one continuous curve, softened cube-root growth. */
export const LATEST_SINE_RULES_VERSION = 3

export async function readSineRulesVersion(read: () => Promise<unknown>): Promise<SineRulesVersion> {
  let version: unknown
  try { version = await read() }
  catch (error) {
    let cause: unknown = error
    const seen = new Set<unknown>()
    while (cause instanceof Error && !seen.has(cause)) {
      seen.add(cause)
      if (/execution reverted|returned no data|no result|zero data|cannot decode zero data/i.test(cause.message)) return 1
      cause = cause.cause
    }
    throw error
  }
  if (version === 1n || version === 2n || version === 3n) return Number(version) as SineRulesVersion
  throw new Error('Unsupported sine curve version')
}
