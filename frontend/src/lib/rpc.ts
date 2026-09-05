import { createRpcReader } from './rpcReader'
import { RPC_URL, RPC_FALLBACK_URL, targetChain } from './config'

const reader = createRpcReader(RPC_URL, { chain: targetChain, fallbackUrl: RPC_FALLBACK_URL })
export const rpcCall = reader.call
export const rpcLogs = reader.logs
