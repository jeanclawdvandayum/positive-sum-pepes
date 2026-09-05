import { createRpcReader } from './rpcReader'

const RPC = (import.meta.env.VITE_RPC_URL as string | undefined) || 'http://127.0.0.1:8545'
const reader = createRpcReader(RPC)
export const rpcCall = reader.call
export const rpcLogs = reader.logs
