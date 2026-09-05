/** Preserve contract and wallet failures, while avoiding raw RPC bodies in UI. */
export function isRpcUnavailable(error: unknown): boolean {
  let current = error
  const seen = new Set<unknown>()
  let unavailable = false
  while (current instanceof Error && !seen.has(current)) {
    seen.add(current)
    if (current.name === 'ContractFunctionRevertedError' || /execution reverted/i.test(current.message)) return false
    unavailable ||= /over rate limit|rate limit exceeded|too many requests|status: 429|http request failed|fetch failed|failed to fetch|timed out|timeout|network request failed/i.test(current.message)
    current = current.cause
  }
  return unavailable
}

export function userFacingRpcError(error: unknown): unknown {
  return isRpcUnavailable(error)
    ? new Error('The RPC connection is busy or unavailable. No new transaction was submitted. Wait a moment and try again.', { cause: error })
    : error
}
