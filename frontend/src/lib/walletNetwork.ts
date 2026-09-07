/** Switch before an action, preserving the account that initiated it. */
export async function ensureWalletNetwork(
  account: string,
  chainId: number,
  wallet: {
    current: () => { address?: string; chainId?: number }
    switchTo: (chainId: number) => Promise<unknown>
  },
) {
  const assertAccount = () => {
    if (wallet.current().address?.toLowerCase() !== account.toLowerCase()) {
      throw new Error('The wallet account changed. Try again with the intended wallet.')
    }
  }
  assertAccount()
  if (wallet.current().chainId !== chainId) await wallet.switchTo(chainId)
  assertAccount()
  if (wallet.current().chainId !== chainId) throw new Error('The wallet did not switch networks. Please try again.')
}
