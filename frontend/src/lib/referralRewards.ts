type Address = `0x${string}`
type ClaimAction = { address: Address; functionName: string; args?: readonly unknown[]; value?: bigint }

/** Only a missing version selector marks an immutable legacy registry. */
export async function referralRewardsVersion(read: () => Promise<bigint>): Promise<bigint> {
  try { return await read() }
  catch (error) {
    if (error instanceof Error && /no result|execution reverted/i.test(error.message)) return 0n
    throw error
  }
}

/** Claims use the selected round's registry, even after a successor launches. */
export async function verifyReferralClaim(
  reads: { registry: (id: bigint) => Promise<Address>; version: (registry: Address) => Promise<bigint> },
  roundId: bigint | undefined,
  action: ClaimAction,
) {
  if (!roundId || roundId < 1n) throw new Error('Wait for the selected round to load.')
  const registry = await reads.registry(roundId)
  if (/^0x0+$/i.test(registry) || action.address.toLowerCase() !== registry.toLowerCase()
    || action.functionName !== 'claimReferralRewards' || (action.args?.length ?? 0) !== 0
    || (action.value ?? 0n) !== 0n) {
    throw new Error('This claim must use the selected round’s referral registry.')
  }
  if (await reads.version(registry) !== 1n) throw new Error('This round uses a different referral payout method.')
}
