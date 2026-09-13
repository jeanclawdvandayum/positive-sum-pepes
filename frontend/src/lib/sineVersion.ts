/** Legacy hooks have no version selector. Transport failures must retry. */
export async function readSineRulesVersion(read: () => Promise<unknown>): Promise<1 | 2> {
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
  if (version === 1n || version === 2n) return Number(version) as 1 | 2
  throw new Error('Unsupported sine curve version')
}
