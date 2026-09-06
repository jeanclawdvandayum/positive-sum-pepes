import { createPublicClient, isAddress, type Address } from 'viem'
import { rpcTransport } from './rpcTransport'
import { childNameId, WEI_NODE, WNS_ADDRESS, type NameNamespace } from './weiNames'

const env = import.meta.env
const parentLabel = env.VITE_NAME_PARENT_LABEL || (Number(env.VITE_CHAIN_ID) === 84532 ? 'pepetesters' : 'pepe')
const registrar = isAddress(env.VITE_NAME_REGISTRAR || '') ? env.VITE_NAME_REGISTRAR as Address : undefined
export const nameNamespace: NameNamespace = {
  chainId: Number(env.VITE_NAME_CHAIN_ID || 1),
  names: WNS_ADDRESS,
  parentId: childNameId(BigInt(WEI_NODE), parentLabel),
  parentLabel,
  registrar,
}
export const nameClient = createPublicClient({ transport: rpcTransport(env.VITE_NAME_RPC_URL || 'https://ethereum-rpc.publicnode.com') })
export const nameQueryKey = ['wei-name', nameNamespace.chainId, nameNamespace.names, nameNamespace.parentId.toString(), registrar ?? 'wns'] as const
