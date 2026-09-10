import { cookieStorage, createStorage } from 'wagmi'
import { base, baseSepolia, mainnet, sepolia } from 'wagmi/chains'
import { defineChain, type Transport } from 'viem'
import { getDefaultConfig } from '@rainbow-me/rainbowkit'
import { walletchanWallet } from './walletchan'
import {
  injectedWallet, metaMaskWallet, coinbaseWallet, trustWallet,
  phantomWallet, rabbyWallet, rainbowWallet, okxWallet,
  uniswapWallet, zerionWallet, ledgerWallet, walletConnectWallet,
} from '@rainbow-me/rainbowkit/wallets'
import { rpcTransport } from './rpcTransport'

const env = import.meta.env

const anvil = defineChain({
  id: 31337,
  name: 'Anvil',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [env.VITE_RPC_URL || 'http://127.0.0.1:8545'] } },
})

export const CHAIN_ID = Number(env.VITE_CHAIN_ID || 8453)

export const targetChain =
  CHAIN_ID === 31337
    ? anvil
    : CHAIN_ID === 1
      ? mainnet
      : CHAIN_ID === 11155111
        ? sepolia
        : CHAIN_ID === 84532
          ? baseSepolia
          : base

export const ADDRESSES = {
  factory: (env.VITE_FACTORY || '0x') as `0x${string}`,
  zapIn: (env.VITE_ZAP_IN || '0x') as `0x${string}`,
  zapOut: (env.VITE_ZAP_OUT || '0x') as `0x${string}`,
  mix: (env.VITE_MIX || '0x') as `0x${string}`,
  faucet: (env.VITE_FAUCET || '0x') as `0x${string}`,
  reinvestor: (env.VITE_REINVESTOR || '0x') as `0x${string}`,
}

/// testnet faucet UI is env-gated: hidden unless both addresses are configured.
export const FAUCET_ENABLED = Boolean(env.VITE_MIX && env.VITE_FAUCET)

/// external faucet for the chain's native ETH (linked from onboarding UI).
/// ETH Sepolia: PoW faucet. Base Sepolia: Coinbase's official faucet
/// (also accepts Alchemy's: https://www.alchemy.com/faucets/base-sepolia).
export const NATIVE_ETH_FAUCET_URL =
  CHAIN_ID === 84532
    ? 'https://www.coinbase.com/faucets/base-ethereum-sepolia-faucet'
    : 'https://sepolia-faucet.pk910.de/'

/// true when the connected chain is one of the supported testnets that needs
/// a native-ETH faucet link in onboarding.
export const TESTNET_ETH_FAUCET = CHAIN_ID === 11155111 || CHAIN_ID === 84532

/// reinvest buttons are env-gated the same way.
export const REINVEST_ENABLED = Boolean(env.VITE_REINVESTOR)
export const RPC_URL = env.VITE_RPC_URL || targetChain.rpcUrls.default.http[0]
export const RPC_FALLBACK_URL = env.VITE_RPC_FALLBACK_URL as string | undefined
export const DEPLOYMENT_BLOCK = BigInt(env.VITE_DEPLOYMENT_BLOCK || '0')

// Naming lives on Ethereum even while the game lives on Base Sepolia.
const separateNameChain = Boolean(env.VITE_NAME_REGISTRAR) && Number(env.VITE_NAME_CHAIN_ID || 1) === 1 && CHAIN_ID !== 1

export const wagmiConfig = getDefaultConfig({
  appName: 'Positive Sum Pepes',
  projectId: env.VITE_WC_PROJECT_ID || '',
  // WalletConnect-backed entries require this app's own relay project ID.
  // Preserve extension access while deployment credentials are being configured.
  wallets: env.VITE_WC_PROJECT_ID ? [{
    groupName: 'Wallets',
    wallets: [metaMaskWallet, coinbaseWallet, trustWallet, phantomWallet,
      rabbyWallet, rainbowWallet, okxWallet, uniswapWallet, zerionWallet,
      ledgerWallet, walletchanWallet, walletConnectWallet, injectedWallet],
  }] : [{ groupName: 'Browser wallets', wallets: [walletchanWallet, injectedWallet] }],
  chains: separateNameChain ? [targetChain, mainnet] : [targetChain],
  batch: { multicall: { batchSize: 4096, wait: 20 } },
  storage: createStorage({ storage: cookieStorage }),
  transports: {
    ...(separateNameChain ? { [mainnet.id]: rpcTransport(env.VITE_NAME_RPC_URL || 'https://ethereum-rpc.publicnode.com') } : {}),
    [targetChain.id]: rpcTransport(RPC_URL, RPC_FALLBACK_URL),
  } as Record<number, Transport>,
  ssr: false,
})
