import { encodeFunctionData, decodeFunctionResult, type Address, type Abi } from 'viem'

const RPC = (import.meta.env.VITE_RPC_URL as string | undefined) || 'http://127.0.0.1:8545'

/// Plain JSON-RPC eth_call — bypasses a wagmi v2 query-idle quirk observed on
/// custom chains (reads sit `pending/idle` forever despite resolving fine raw).
export async function rpcCall(
  to: Address,
  abi: readonly unknown[],
  functionName: string,
  args: readonly unknown[] = [],
): Promise<unknown> {
  if (!to || /^0x0+$/.test(to)) throw new Error(`rpc ${functionName}: no target address`)
  const data = encodeFunctionData({ abi: abi as Abi, functionName, args: args as never })
  const res = await fetch(RPC, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_call', params: [{ to, data }, 'latest'] }),
  })
  const j = (await res.json()) as { result?: string; error?: { message: string } }
  if (j.error || !j.result) throw new Error(`rpc ${functionName}: ${j.error?.message ?? 'no result'}`)
  return decodeFunctionResult({ abi: abi as Abi, functionName, data: j.result as `0x${string}` })
}

export async function rpcLogs(
  fromBlock: bigint,
  toBlock: bigint,
  address: Address,
  topics: readonly (string | null)[],
): Promise<unknown> {
  const res = await fetch(RPC, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      jsonrpc: '2.0',
      id: 1,
      method: 'eth_getLogs',
      params: [{ fromBlock: `0x${fromBlock.toString(16)}`, toBlock: `0x${toBlock.toString(16)}`, address, topics: topics as never }],
    }),
  })
  const j = (await res.json()) as { result?: unknown; error?: { message: string } }
  if (j.error) throw new Error(`rpc logs: ${j.error.message}`)
  return j.result ?? []
}
