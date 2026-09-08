/** Resolves only after successful inclusion, including a repriced replacement. */
export async function confirmTransaction<P>(steps: {
  simulate: (params: P) => Promise<unknown>
  submit: (params: P) => Promise<`0x${string}`>
  wait: (hash: `0x${string}`) => Promise<{ status: string; transactionHash: `0x${string}`; replacementReason?: string }>
}, params: P, notify?: (stage: 'simulating' | 'wallet' | 'pending' | 'success' | 'failed' | 'unknown', hash?: `0x${string}`, detail?: string) => void): Promise<`0x${string}`> {
  let hash: `0x${string}` | undefined
  let resolved = false
  try {
    notify?.('simulating')
    await steps.simulate(params)
    notify?.('wallet')
    hash = await steps.submit(params)
    notify?.('pending', hash)
    const receipt = await steps.wait(hash)
    hash = receipt.transactionHash
    resolved = true
    if (receipt.replacementReason && receipt.replacementReason !== 'repriced') throw new Error('Transaction was cancelled or replaced with a different action.')
    if (receipt.status !== 'success') throw new Error(`Transaction reverted: ${receipt.transactionHash}`)
    notify?.('success', hash)
    return hash
  } catch (error) {
    const detail = error instanceof Error ? ('shortMessage' in error ? String(error.shortMessage) : error.message) : 'Transaction failed.'
    notify?.(hash && !resolved ? 'unknown' : 'failed', hash, detail.slice(0, 200))
    throw error
  }
}
