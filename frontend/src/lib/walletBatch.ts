import { userFacingContractError } from './contractErrors.ts'

/** EIP-5792 atomic support includes wallets that can upgrade with user consent. */
export function supportsAtomicBatch(capabilities: unknown): boolean {
  const status = (capabilities as { atomic?: { status?: string } } | undefined)?.atomic?.status
  return status === 'supported' || status === 'ready'
}

export function assertBatchReceipt(result: {
  status?: string; atomic?: boolean; receipts?: readonly { status: string; transactionHash: string }[]
}) {
  if (result.status !== 'success') throw new Error('The wallet batch failed. Check its status before retrying.')
  if (result.atomic !== true || result.receipts?.length !== 1 || result.receipts[0].status !== 'success') {
    throw new Error('The wallet did not confirm one successful atomic transaction. Check its status before retrying.')
  }
}

type Hash = `0x${string}`
type BatchResult = { status?: string; atomic?: boolean; receipts?: readonly { status: string; transactionHash: Hash }[] }
/** One submission only. A bundle id is not a transaction hash. */
export async function confirmAtomicTransaction(operations: {
  send: () => Promise<{ id: string }>
  wait: (id: string) => Promise<BatchResult>
  confirm: (hash: Hash) => Promise<{ status: string }>
  notify: (stage: 'wallet' | 'pending' | 'success' | 'failed' | 'unknown', hash?: Hash, detail?: string) => void
}) {
  let submitted = false, failed = false
  let hash: Hash | undefined
  try {
    operations.notify('wallet')
    const { id } = await operations.send()
    submitted = true
    operations.notify('pending')
    const result = await operations.wait(id)
    hash = result.receipts?.[0]?.transactionHash
    if (hash) operations.notify('pending', hash)
    failed = result.status === 'failure' || result.receipts?.some(r => r.status === 'reverted') === true
    assertBatchReceipt(result)
    const receipt = await operations.confirm(hash!)
    if (receipt.status !== 'success') { failed = true; throw new Error('The atomic transaction reverted.') }
    operations.notify('success', hash)
    return hash!
  } catch (error) {
    error = userFacingContractError(error)
    operations.notify(submitted && !failed ? 'unknown' : 'failed', hash,
      error instanceof Error ? error.message.slice(0, 200) : 'Batch failed.')
    throw error
  }
}
