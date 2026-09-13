import { userFacingContractError } from './contractErrors.ts'

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
  const readable = userFacingContractError(error)
  if (readable !== error) return readable
  let current = error
  const seen = new Set<unknown>()
  while (current instanceof Error && !seen.has(current)) {
    seen.add(current)
    if (/0xfb8f41b2|ERC20InsufficientAllowance/.test(current.message)) {
      return new Error('The mixETH approval is too small or was already used. Try again to approve the current deposit amount.', { cause: error })
    }
    current = current.cause
  }
  return isRpcUnavailable(error)
    ? new Error('The RPC connection is busy or unavailable. No new transaction was submitted. Wait a moment and try again.', { cause: error })
    : error
}
