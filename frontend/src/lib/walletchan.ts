import { injected } from 'wagmi/connectors'
import type { Wallet } from '@rainbow-me/rainbowkit'
import type { EIP1193Provider } from 'viem'

// Official EIP-6963 identifier. Never select an unrelated injected wallet.
let provider: EIP1193Provider | undefined
if (typeof window !== 'undefined') {
  window.addEventListener('eip6963:announceProvider', ((event: CustomEvent) => {
    if (event.detail?.info?.rdns === 'com.walletchan') provider = event.detail.provider
  }) as EventListener)
  window.dispatchEvent(new Event('eip6963:requestProvider'))
}
export const walletchanWallet = (): Wallet => ({
  id: 'walletchan', name: 'WalletChan', rdns: 'com.walletchan',
  iconUrl: '/walletchan.png', iconBackground: '#171421',
  installed: Boolean(provider),
  downloadUrls: { browserExtension: 'https://walletchan.com/' },
  createConnector: details => config => ({
    ...injected({ target: { id: 'walletchan', name: 'WalletChan', provider: () => provider } })(config),
    ...details,
  }),
})
