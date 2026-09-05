/** Multiple Solidity return values decode as an array, even when named. */
export function predepositResult(raw: unknown): { mixETHAmount: bigint; claimed: boolean } {
  if (!Array.isArray(raw) || typeof raw[0] !== 'bigint' || typeof raw[1] !== 'boolean') {
    throw new Error('Invalid predeposit response')
  }
  return { mixETHAmount: raw[0], claimed: raw[1] }
}
