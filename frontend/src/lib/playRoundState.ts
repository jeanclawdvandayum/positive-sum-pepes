import type { RoundInfo } from './useRound'
import type { DeadRoundState } from '../pages/play/useDeadRound'

/** Historical settlement must never put a successor's play page into rebirth mode. */
export function playRoundState(
  round: Pick<RoundInfo, 'id' | 'hook' | 'mode' | 'readError'>,
  dead: Pick<DeadRoundState, 'checked' | 'dead' | 'roundId' | 'hook' | 'mode' | 'claimable'>,
  detonatedRoundId?: bigint,
) {
  const knownRound = round.id > 0n && !!round.hook && !/^0x0+$/i.test(round.hook)
  const matchingDead = knownRound && dead.checked && dead.dead && dead.roundId === round.id
    && dead.hook?.toLowerCase() === round.hook?.toLowerCase()
    && (dead.mode === 2 || dead.mode === 3)
  const settled = knownRound && (round.mode === 2 || round.mode === 3
    || detonatedRoundId === round.id || matchingDead)

  return {
    settled,
    spawnFromRoundId: settled && !round.readError ? round.id : undefined,
    claimable: settled && matchingDead ? dead.claimable : undefined,
  }
}
