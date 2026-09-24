// Which position NFT a confirmed predeposit claim minted (alt hatch modal).
// The id comes from the expected staker's ERC-721 mint Transfer in the mined
// receipt; the art is then read on-chain (dnaOf) — never derived locally.
// Automatic claims mint at the wallet-address id, or at nextTokenId when that
// id is taken, so no id is assumed from the account or the args alone.

import { parseEventLogs, zeroAddress, type Log } from 'viem'
import { stakerAbi } from './abi.ts'

const CLAIMS: Record<string, true> = { claimPredepositPSP: true, claimPredepositPSPWithPepe: true }

/**
 * The token id `staker` minted to `account` in `logs`, or undefined when the
 * receipt holds no such mint. A chosen claim must mint exactly its argument.
 */
export function hatchFxPepeId(
  functionName: string,
  args: readonly unknown[] | undefined,
  logs: readonly unknown[] | undefined,
  account: string,
  staker: string,
): bigint | undefined {
  if (!CLAIMS[functionName] || !logs?.length) return undefined
  try {
    for (const log of parseEventLogs({ abi: stakerAbi, eventName: 'Transfer', logs: logs as Log[], strict: true })) {
      if (log.address.toLowerCase() !== staker.toLowerCase()) continue
      const { from, to, tokenId } = log.args
      if (from !== zeroAddress || to.toLowerCase() !== account.toLowerCase()) continue
      if (functionName === 'claimPredepositPSPWithPepe' && args?.[0] !== tokenId) return undefined
      return tokenId
    }
  } catch {
    // Falls through to undefined.
  }
  return undefined
}
