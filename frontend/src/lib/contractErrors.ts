import { decodeErrorResult, parseAbi, toFunctionSelector } from 'viem'

/** Hook errors can propagate through the controller, routers, or V4 wrapper. */
export const curveErrorSignatures = [
  'error PredepositCapacityExceeded()',
  'error SwapTooLarge()',
  'error SwapTooSmall()',
  'error ZeroOutput()',
  'error TradingHalted()',
  'error InvalidParams()',
  'error ExpPriceArg()',
  'error FullMulDivFailed()',
  'error MulWadFailed()',
  'error DivWadFailed()',
  // v3 (2026-09-14): a guarded purchase route sampled a live ticket price
  // above the caller's quoted maxTicketPrice — nothing moved, refresh.
  'error TicketPriceMoved()',
  'error SineV3Domain()',
  'error SineV3PriceDomain()',
  'error SineV3PriceOverflow()',
  'error SineV3PrimitiveDomain()',
  'error SineV3Coefficient()',
  'error SineV3DataMismatch()',
  'error SineV3InverseDidNotConverge()',
  'error InvalidRoundHook()',
  'error WrappedError(address target, bytes4 selector, bytes reason, bytes details)',
] as const
const abi = parseAbi(curveErrorSignatures)
const arithmetic = 'This amount exceeds the contract’s arithmetic capacity. Try a smaller amount.'
const messages: Record<string, string> = {
  PredepositCapacityExceeded: 'This pool is too small at its launch price to allocate every deposit proportionally. It needs more backing before more deposits can be recorded.',
  SwapTooLarge: 'This trade exceeds the maximum input or output for one transaction. Try a smaller amount.',
  SwapTooSmall: 'This trade is below the minimum supported amount. Increase the amount.',
  ZeroOutput: 'This trade would return zero tokens. Check the amount and quote.',
  TradingHalted: 'The round’s timer has ended. Detonation opens settlement and claims.',
  InvalidParams: 'These values cannot form a valid curve. Check the amount and round configuration.',
  ExpPriceArg: 'This trade reaches beyond the curve’s supported price range. Try a smaller amount.',
  FullMulDivFailed: arithmetic,
  MulWadFailed: arithmetic,
  DivWadFailed: arithmetic,
  TicketPriceMoved: 'The ticket price rose past your quoted maximum before the trade landed. Nothing was spent — refresh for a new quote.',
  SineV3Domain: 'This trade exceeds the curve’s supported reserve range. Try a smaller amount.',
  SineV3PriceDomain: 'This trade reaches a price the curve cannot represent. Try a smaller amount.',
  SineV3PriceOverflow: 'This trade reaches a price the curve cannot represent. Try a smaller amount.',
  SineV3PrimitiveDomain: 'This trade exceeds the curve’s supported reserve range. Try a smaller amount.',
  SineV3Coefficient: 'The curve’s settlement data failed an internal consistency check. The transaction reverted. Report this failure before retrying.',
  SineV3DataMismatch: 'The curve’s settlement data does not match its deployment record. The transaction reverted. Report this failure.',
  SineV3InverseDidNotConverge: 'The curve could not calculate a complete sell quote. The transaction reverted. Report this quote failure before retrying.',
  InvalidRoundHook: 'This reinvestment targets a different round. Refresh the selected position before retrying.',
}
const selectors = new Map(Object.keys(messages).map(name => [toFunctionSelector(`${name}()`), name]))

function decodedName(value: unknown, depth = 0): string | undefined {
  if (depth > 4) return undefined
  if (typeof value === 'string' && /^0x[\da-f]+$/i.test(value) && value.length <= 131072) {
    try { return decodedName(decodeErrorResult({ abi, data: value as `0x${string}` }), depth + 1) }
    catch { return undefined }
  }
  if (!value || typeof value !== 'object') return undefined
  const { errorName, args } = value as { errorName?: string; args?: readonly unknown[] }
  if (errorName === 'WrappedError' && Array.isArray(args)) return decodedName(args[2], depth + 1)
  return errorName && Object.hasOwn(messages, errorName) ? errorName : undefined
}

/** Translate known reverts only. Preserve wallet rejections and receipt status. */
export function userFacingContractError(error: unknown): unknown {
  let current = error
  const seen = new Set<unknown>()
  while (current instanceof Error && !seen.has(current)) {
    seen.add(current)
    const message = current.message
    if (Object.values(messages).includes(message)) return error
    let name = decodedName((current as Error & { data?: unknown }).data)
    if (!name) name = Object.keys(messages).find(key => new RegExp(`\\b${key}\\b`).test(message))
    // An older ABI may only report the four-byte selector.
    if (!name) {
      const signature = /(?:signature|data)[\s:\"']+(0x[\da-f]{8})(?![\da-f])/i.exec(message)?.[1]
      if (signature) name = selectors.get(signature.toLowerCase() as `0x${string}`)
    }
    if (name) return new Error(messages[name], { cause: error })
    current = current.cause
  }
  return error
}
