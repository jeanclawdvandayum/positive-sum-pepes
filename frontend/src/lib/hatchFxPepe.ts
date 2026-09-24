// Which pepe a confirmed predeposit claim hatched (alt hatch modal). No new
// chain reads: a chosen claim names its id in the write args; a plain claim
// mints the id the depositor reserved at predeposit time, and the mined
// receipt's ERC-721 mint Transfer names it.

import { parseEventLogs, zeroAddress, type Log } from 'viem'
import { stakerAbi } from './abi.ts'

/**
 * The id whose art is `keccak(id)` (dnaOfId), or undefined when the art is not
 * id-derived or cannot be known:
 * - `claimPredepositPSPWithPepe(id)` → the argument.
 * - `claimPredepositPSP()` → the id minted to `account` in `logs`. A depositor
 *   without a reservation gets an automatic mint whose id is their address and
 *   whose art is the wallet's genesis DNA, not keccak(id) → undefined.
 * Anything else, or an undecodable receipt → undefined.
 */
export function hatchFxPepeId(
  functionName: string,
  args: readonly unknown[] | undefined,
  logs: readonly unknown[] | undefined,
  account: string,
): bigint | undefined {
  if (functionName === 'claimPredepositPSPWithPepe') {
    const id = args?.[0]
    return typeof id === 'bigint' && id > 0n ? id : undefined
  }
  if (functionName !== 'claimPredepositPSP' || !logs?.length) return undefined
  try {
    for (const log of parseEventLogs({ abi: stakerAbi, eventName: 'Transfer', logs: logs as Log[], strict: true })) {
      const { from, to, tokenId } = log.args
      if (from !== zeroAddress || to.toLowerCase() !== account.toLowerCase()) continue
      return tokenId === BigInt(account) ? undefined : tokenId
    }
  } catch {
    // Falls through to undefined.
  }
  return undefined
}
