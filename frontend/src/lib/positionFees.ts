/** Current position accounting. Withdrawal clears feesPaid on chain. */
export function positionFeesEarned(paid: bigint | undefined, pending: bigint | undefined): bigint | undefined {
  return paid === undefined || pending === undefined ? undefined : paid + pending
}
