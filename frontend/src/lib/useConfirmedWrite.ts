import { encodeFunctionData } from 'viem'
import { getWalletClient } from 'wagmi/actions'
import { getCapabilities, sendCalls, waitForCallsStatus } from 'viem/actions'
import { supportsAtomicBatch, confirmAtomicTransaction } from './walletBatch'
import { startTransactionToast, transactionLabel } from './transactionToasts'
import { useAccount, usePublicClient, useWriteContract } from 'wagmi'
import { ensureWalletChain } from './ensureWalletChain'
import { CHAIN_ID, ADDRESSES, wagmiConfig } from './config'
import { factoryAbi, hookAbi, controllerAbi, reinvestorAbi, registryAbi, stakerAbi } from './abi'
import { assertNftManagement } from './nftPermissions'
import { assertGameRules } from './gameRules'
import { verifyRoundExit } from './exitRules'
import { confirmTransaction } from './transactions'
import { userFacingRpcError } from './rpcErrors'
import { assertReferralPurchase } from './referrals'
import { assertReinvestor } from './reinvestRules'

/** AUD-4: every UI write simulates, waits for mining, and checks receipt status. */
export function useConfirmedWrite(options?: { exitRoundId: bigint | undefined } | { nftRoundId: bigint | undefined } | { referralPurchase: { roundId: bigint; registry?: `0x${string}` } }) {
  const { address } = useAccount()
  const client = usePublicClient({ chainId: CHAIN_ID })
  const { writeContractAsync } = useWriteContract()
  type Write = Parameters<typeof writeContractAsync>[0]
  const confirmed = async (parameters: Write, validateOnly = false) => {
    if (!client || !address) throw new Error('Connect a wallet first.')
    const toast = validateOnly ? undefined : startTransactionToast(transactionLabel(parameters.functionName), CHAIN_ID, address)
    try {
      await ensureWalletChain(address, CHAIN_ID)
      // Immutable legacy deployments do not acquire the new purchase rules.
      const factory = ADDRESSES.factory as `0x${string}`
      const blockNumber = await client.getBlockNumber().catch(error => { throw userFacingRpcError(error) })
      if (options && 'nftRoundId' in options) {
        if (!options.nftRoundId) throw new Error('Wait for the selected round to load.')
        const round = await client.readContract({ address: factory, abi: factoryAbi, functionName: 'rounds', args: [options.nftRoundId], blockNumber })
        const staker = await client.readContract({ address: round[1], abi: controllerAbi, functionName: 'staker', blockNumber })
        assertNftManagement(staker, address, ADDRESSES.reinvestor, parameters)
        if (parameters.functionName !== 'setApprovalForAll') {
          const version = await client.readContract({ address: staker, abi: stakerAbi, functionName: 'NFT_INTERFACE_VERSION', blockNumber })
          if (version !== 1n) throw new Error('This round does not support safe NFT management.')
        }
      } else if (options && 'exitRoundId' in options) {
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
        if (options && 'referralPurchase' in options) {
          const intent = options.referralPurchase
          const atomicBuy = parameters.functionName === 'buyWithMix' && parameters.args?.length === 5
          const registryApproval = parameters.functionName === 'approve' && intent.registry &&
            String(parameters.args?.[0]).toLowerCase() === intent.registry.toLowerCase()
          if (atomicBuy || registryApproval) {
            if (intent.roundId !== id) throw new Error('The round changed. Refresh before purchasing.')
            const registry = await client.readContract({ address: factory, abi: factoryAbi, functionName: 'referralRegistryOf', args: [id], blockNumber })
            const version = await client.readContract({ address: registry, abi: registryAbi, functionName: 'PURCHASE_REFERRAL_VERSION', blockNumber })
            const key = parameters.args?.[0] as { hooks?: string } | undefined
            assertReferralPurchase({ registry, version, hook: round[2] },
              atomicBuy ? parameters.address : String(parameters.args?.[0]), atomicBuy ? key?.hooks ?? '' : round[2])
          }
        }
        const approvesRouter = (parameters.functionName === 'setApprovalForAll' || parameters.functionName === 'approve') &&
          String(parameters.args?.[0]).toLowerCase() === ADDRESSES.reinvestor.toLowerCase()
        if (approvesRouter || parameters.address.toLowerCase() === ADDRESSES.reinvestor.toLowerCase()) {
          const [expected, actual, attributionVersion] = await Promise.all([
            client.readContract({ address: round[1], abi: controllerAbi, functionName: 'staker', blockNumber }),
            client.readContract({ address: ADDRESSES.reinvestor, abi: reinvestorAbi, functionName: 'staker', blockNumber }),
            client.readContract({ address: ADDRESSES.reinvestor, abi: reinvestorAbi, functionName: 'ATTRIBUTION_VERSION', blockNumber }),
          ])
          assertReinvestor(expected, actual, attributionVersion)
          if (approvesRouter && parameters.address.toLowerCase() !== expected.toLowerCase()) {
            throw new Error('The approval target changed. Refresh the current round.')
          }
        }
      } catch (error) {
        throw userFacingRpcError(error)
      }
      if (validateOnly) return undefined
      return await confirmTransaction({
        simulate: p => client.simulateContract({ ...p, account: address } as never)
          .catch(error => { throw userFacingRpcError(error) }),
        submit: async p => {
          await ensureWalletChain(address, CHAIN_ID)
          return writeContractAsync(p)
        },
        wait: async hash => {
          let replacementReason: string | undefined
          const receipt = await client.waitForTransactionReceipt({
            hash, timeout: 180_000,
            onReplaced: replacement => { if (replacement.reason !== 'repriced') replacementReason = replacement.reason },
          })
          return { ...receipt, replacementReason }
        },
      }, { ...parameters, account: address, chainId: CHAIN_ID } as typeof parameters, toast?.update)
    } catch (error) { toast?.fail(error); throw error }
  }
  // Capabilities belong to the selected account AND chain. Never cache by brand.
  const atomicWallet = async () => {
    if (!address) throw new Error('Connect a wallet first.')
    await ensureWalletChain(address, CHAIN_ID)
    const wallet = await getWalletClient(wagmiConfig, { chainId: CHAIN_ID })
    if (wallet.account.address.toLowerCase() !== address.toLowerCase()) throw new Error('Wallet account changed.')
    const capabilities = await getCapabilities(wallet, { account: address, chainId: CHAIN_ID }).catch(() => undefined)
    return supportsAtomicBatch(capabilities) ? wallet : undefined
  }
  const writeWithApprovals = async (action: Write, approvals: Write[] = []) => {
    if (!approvals.length) return confirmed(action)
    const wallet = await atomicWallet()
    if (!wallet) {
      for (const approval of approvals) await confirmed(approval)
      return confirmed(action)
    }
    const toast = startTransactionToast(`approve & ${transactionLabel(action.functionName)}`, CHAIN_ID, address!)
    try {
      const calls = [...approvals, action]
      // Apply the same round, target, referral and reinvestor guards to EVERY call.
      for (const call of calls) await confirmed(call, true)
      return await confirmAtomicTransaction({
        send: async () => {
          await ensureWalletChain(address!, CHAIN_ID)
          // The wallet simulates dependent calls together. An isolated action
          // eth_call would fail before its approval exists.
          return sendCalls(wallet, {
            account: address!, chain: wallet.chain, forceAtomic: true,
            calls: calls.map(call => ({ to: call.address, value: call.value,
              data: encodeFunctionData(call as never) })),
          })
        },
        wait: id => waitForCallsStatus(wallet, { id, timeout: 180_000, retryCount: 0 }),
        confirm: hash => client!.waitForTransactionReceipt({ hash, timeout: 180_000 }),
        notify: toast.update,
      })
    } catch (error) { toast.fail(error); throw error }
  }

  return { writeContractAsync: confirmed as typeof writeContractAsync, writeWithApprovals, atomicWallet }
}
