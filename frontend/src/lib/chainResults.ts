/** Multiple Solidity return values decode as an array, even when named.
 * Rules v3 grew the middle greenAmount field; legacy rounds still return
 * the 2-tuple off the same mapping — claimed is last in both eras. */
export interface PredepositEntry {
  mixETHAmount: bigint
  greenAmount: bigint
  claimed: boolean
}

export function predepositResult(raw: unknown): PredepositEntry {
  if (!Array.isArray(raw) || typeof raw[0] !== 'bigint' || typeof raw[raw.length - 1] !== 'boolean') {
    throw new Error('Invalid predeposit response')
  }
  const greenAmount = raw.length >= 3 && typeof raw[1] === 'bigint' ? raw[1] : 0n
  return { mixETHAmount: raw[0], greenAmount, claimed: raw[raw.length - 1] }
}
