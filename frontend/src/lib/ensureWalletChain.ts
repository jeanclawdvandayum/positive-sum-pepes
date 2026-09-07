import { getAccount, switchChain } from '@wagmi/core'
import { wagmiConfig } from './config'
import { ensureWalletNetwork } from './walletNetwork'

export function ensureWalletChain(account: string, chainId: number) {
  return ensureWalletNetwork(account, chainId, {
    current: () => getAccount(wagmiConfig),
    switchTo: id => {
      const chain = wagmiConfig.chains.find(chain => chain.id === id)
      if (!chain) throw new Error('This network is not configured for this site.')
      return switchChain(wagmiConfig, { chainId: chain.id })
    },
  })
}
