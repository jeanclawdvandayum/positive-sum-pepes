// The buy chip reports only confirmed facts (Round 2, Feature 7): the
// secondsAdded of the first TimeAdded event in the mined receipt. No estimate
// and no seat count — seats cannot be derived exactly from the events.

import { parseEventLogs, type Log } from 'viem'
import { hookAbi } from './abi.ts'

/** The clock string for the first TimeAdded in `logs` ('+2:18', minutes may
 *  exceed 59: '+75:00'); undefined when the buy hit the cap (secondsAdded 0)
 *  or the receipt carries no TimeAdded. Unrelated events and malformed logs
 *  are ignored — a receipt that cannot be decoded reports no chip. */
export function buyFxDetail(logs: readonly unknown[] | undefined): string | undefined {
  if (!logs?.length) return undefined
  try {
    for (const log of parseEventLogs({ abi: hookAbi, logs: logs as Log[], strict: false })) {
      if (log.eventName !== 'TimeAdded') continue
      const { secondsAdded } = (log.args ?? {}) as { secondsAdded?: bigint }
      const seconds = typeof secondsAdded === 'bigint' ? Number(secondsAdded) : 0
      if (seconds <= 0) return undefined
      return `+${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`
    }
  } catch {
    // Falls through to undefined.
  }
  return undefined
}
