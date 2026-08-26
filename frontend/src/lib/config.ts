import { http, cookieStorage, createStorage } from 'wagmi'
import { base, mainnet } from 'wagmi/chains'
import { defineChain } from 'viem'
import { getDefaultConfig } from '@rainbow-me/rainbowkit'

const env = import.meta.env

const anvil = defineChain({
  id: 31337,
  name: 'Anvil',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [env.VITE_RPC_URL || 'http://127.0.0.1:8545'] } },
})

export const CHAIN_ID = Number(env.VITE_CHAIN_ID || 8453)

const targetChain = CHAIN_ID === 31337 ? anvil : CHAIN_ID === 1 ? mainnet : base

export const ADDRESSES = {
  factory: (env.VITE_FACTORY || '0x') as `0x${string}`,
  zapIn: (env.VITE_ZAP_IN || '0x') as `0x${string}`,
  zapOut: (env.VITE_ZAP_OUT || '0x') as `0x${string}`,
}

export const wagmiConfig = getDefaultConfig({
  appName: 'Positive Sum Pepes',
  projectId: env.VITE_WC_PROJECT_ID || '9a469b7e0f5b4b1f8c3d2e6a5b7c8d9f',
  chains: [targetChain],
  storage: createStorage({ storage: cookieStorage }),
  transports: {
    [targetChain.id]: http(env.VITE_RPC_URL || undefined, { batch: true }),
  },
  ssr: false,
})
