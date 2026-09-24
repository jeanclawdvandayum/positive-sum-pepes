// The victory celebration reports only confirmed facts (Round 4): the
// mixETHAmount of the PotClaimed event in the mined receipt, matched to the
// claimant. No estimate and no second chain read — the confirm step already
// holds the receipt.

import { parseEventLogs, type Log } from 'viem'
import { hookAbi } from './abi.ts'

/** The confirmed pot payout for `account` as a wei bigint; undefined when the
 *  write is not a claimPot, the receipt carries no PotClaimed, or the only
 *  claims pay someone else. Unrelated events and malformed logs are ignored —
 *  a receipt that cannot be decoded reports no card. */
export function potClaimDetail(
  functionName: string,
  logs: readonly unknown[] | undefined,
  account: string | undefined,
): bigint | undefined {
  if (functionName !== 'claimPot' || !account || !logs?.length) return undefined
  const claimant = account.toLowerCase()
  try {
    for (const log of parseEventLogs({ abi: hookAbi, logs: logs as Log[], strict: false })) {
      if (log.eventName !== 'PotClaimed') continue
      const { who, mixETHAmount } = (log.args ?? {}) as { who?: string; mixETHAmount?: bigint }
      if (typeof mixETHAmount !== 'bigint' || typeof who !== 'string') continue
      if (who.toLowerCase() !== claimant) continue
      return mixETHAmount
    }
  } catch {
    // Falls through to undefined.
  }
  return undefined
}
