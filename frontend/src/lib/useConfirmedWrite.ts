import { useAccount, usePublicClient, useWriteContract } from 'wagmi'
import { CHAIN_ID, ADDRESSES } from './config'
import { factoryAbi, hookAbi, controllerAbi, reinvestorAbi } from './abi'
import { assertGameRules } from './gameRules'
import { verifyRoundExit } from './exitRules'
import { confirmTransaction } from './transactions'
import { userFacingRpcError } from './rpcErrors'

/** AUD-4: every UI write simulates, waits for mining, and checks receipt status. */
export function useConfirmedWrite(options?: { exitRoundId: bigint | undefined }) {
  const { address, chainId } = useAccount()
  const client = usePublicClient()
  const { writeContractAsync } = useWriteContract()
  const confirmed = async (parameters: Parameters<typeof writeContractAsync>[0]) => {
    if (!client || !address) throw new Error('Connect a wallet first.')
    if (chainId !== CHAIN_ID) throw new Error('Switch your wallet to the configured network.')
    // Immutable legacy deployments do not acquire the new purchase rules.
    const factory = ADDRESSES.factory as `0x${string}`
    const blockNumber = await client.getBlockNumber().catch(error => { throw userFacingRpcError(error) })
    if (options) {
      // Read this immutable registry entry only. The latest round's rules or
      // availability cannot disable an older round's asset exits.
      await verifyRoundExit({
        round: id => client.readContract({ address: factory, abi: factoryAbi, functionName: 'rounds', args: [id], blockNumber }),
        staker: controller => client.readContract({ address: controller, abi: controllerAbi, functionName: 'staker', blockNumber }),
      }, options.exitRoundId, parameters)
    } else try {
      const id = await client.readContract({ address: factory, abi: factoryAbi, functionName: 'currentRoundId', blockNumber })
      const round = await client.readContract({ address: factory, abi: factoryAbi, functionName: 'rounds', args: [id], blockNumber })
      const [minimum, seconds] = await Promise.all([
        client.readContract({ address: round[2], abi: hookAbi, functionName: 'MIN_BUY_INPUT', blockNumber }),
        client.readContract({ address: round[2], abi: hookAbi, functionName: 'TIME_PER_UNIT', blockNumber }),
      ])
      assertGameRules(minimum, seconds)
      const approvesRouter = parameters.functionName === 'setApprovalForAll' &&
        String(parameters.args?.[0]).toLowerCase() === ADDRESSES.reinvestor.toLowerCase()
      if (approvesRouter || parameters.address.toLowerCase() === ADDRESSES.reinvestor.toLowerCase()) {
        const [expected, actual] = await Promise.all([
          client.readContract({ address: round[1], abi: controllerAbi, functionName: 'staker', blockNumber }),
          client.readContract({ address: ADDRESSES.reinvestor, abi: reinvestorAbi, functionName: 'staker', blockNumber }),
        ])
        if (expected.toLowerCase() !== actual.toLowerCase()) throw new Error('Compounding is unavailable for this round.')
      }
    } catch (error) {
      throw userFacingRpcError(error)
    }
    return confirmTransaction({
      simulate: p => client.simulateContract({ ...p, account: address } as never)
        .catch(error => { throw userFacingRpcError(error) }),
      submit: p => writeContractAsync(p),
      wait: async hash => {
        let replacementReason: string | undefined
        const receipt = await client.waitForTransactionReceipt({
          hash, timeout: 180_000,
          onReplaced: replacement => { if (replacement.reason !== 'repriced') replacementReason = replacement.reason },
        })
        return { ...receipt, replacementReason }
      },
    }, { ...parameters, account: address, chainId: CHAIN_ID } as typeof parameters)
  }
  return { writeContractAsync: confirmed as typeof writeContractAsync }
}
