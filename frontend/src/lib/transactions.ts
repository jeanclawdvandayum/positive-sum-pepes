/** Resolves only after successful inclusion, including a repriced replacement. */
export async function confirmTransaction<P>(steps: {
  simulate: (params: P) => Promise<unknown>
  submit: (params: P) => Promise<`0x${string}`>
  wait: (hash: `0x${string}`) => Promise<{ status: string; transactionHash: `0x${string}`; replacementReason?: string }>
}, params: P): Promise<`0x${string}`> {
  await steps.simulate(params)
  const hash = await steps.submit(params)
  const receipt = await steps.wait(hash)
  if (receipt.replacementReason && receipt.replacementReason !== 'repriced') throw new Error('Transaction was cancelled or replaced with a different action.')
  if (receipt.status !== 'success') throw new Error(`Transaction reverted: ${receipt.transactionHash}`)
  return receipt.transactionHash
}
