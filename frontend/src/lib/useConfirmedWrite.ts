import { encodeFunctionData, type Hash, type TransactionReceipt } from 'viem'
import { getWalletClient } from 'wagmi/actions'
import { getCapabilities, sendCalls, waitForCallsStatus } from 'viem/actions'
import { supportsAtomicBatch, confirmAtomicTransaction } from './walletBatch'
import { startTransactionToast, transactionLabel } from './transactionToasts'
import { useAccount, usePublicClient, useWriteContract } from 'wagmi'
import { ensureWalletChain } from './ensureWalletChain'
import { CHAIN_ID, ADDRESSES, wagmiConfig } from './config'
import { factoryAbi, hookAbi, controllerAbi, reinvestorAbi, registryAbi, stakerAbi } from './abi'
import { assertNftManagement } from './nftPermissions'
import { assertGameRules, assertTicketGuard } from './gameRules'
import { verifyRoundExit } from './exitRules'
import { confirmTransaction } from './transactions'
import { userFacingRpcError } from './rpcErrors'
import { assertReferralPurchase } from './referrals'
import { assertReinvestor } from './reinvestRules'
import { verifyReferralClaim } from './referralRewards'
import { buyFxDetail } from './buyFxDetail'
import { hatchFxPepeId } from './hatchFxPepe'
import { captureAnchor, fireFx, isUserRejection, fxKindFor, type FxKind, type FxPepe } from './actionFx'

function fire(kind: FxKind | undefined, anchor: Element | undefined, detail?: string, pepe?: FxPepe): void {
  if (kind) fireFx(kind, { anchor, detail, pepe })
}

/** FX-only hints for one write. `mute` silences helper writes (approvals inside
 *  writeWithApprovals); `anchor` carries the batch entry press through long
 *  confirmation flows — present-but-undefined means "use nothing", absent means
 *  self-capture; `hatch` names the staker (and its DNA version) whose mint a
 *  confirmed predeposit claim reveals. */
type ConfirmedFx = { mute?: boolean; anchor?: Element; hatch?: { staker: `0x${string}`; dnaVersion: bigint } }

/** AUD-4: every UI write simulates, waits for mining, and checks receipt status. */
export function useConfirmedWrite(options?: { exitRoundId: bigint | undefined } | { nftRoundId: bigint | undefined } | { referralClaimRoundId: bigint | undefined } | { referralPurchase: { roundId: bigint; registry?: `0x${string}` } }) {
  const { address } = useAccount()
  const client = usePublicClient({ chainId: CHAIN_ID })
  const { writeContractAsync } = useWriteContract()
  type Write = Parameters<typeof writeContractAsync>[0]
  const confirmed = async (parameters: Write, validateOnly = false, fx?: ConfirmedFx) => {
    if (!client || !address) throw new Error('Connect a wallet first.')
    const toast = validateOnly ? undefined : startTransactionToast(transactionLabel(parameters.functionName), CHAIN_ID, address)
    const kind = validateOnly || fx?.mute ? undefined : fxKindFor(parameters.functionName)
    let anchor: Element | undefined
    if (validateOnly || fx?.mute) anchor = undefined
    else if (fx && 'anchor' in fx) anchor = fx.anchor
    else anchor = captureAnchor()
    try {
      await ensureWalletChain(address, CHAIN_ID)
      // Immutable legacy deployments do not acquire the new purchase rules.
      const factory = ADDRESSES.factory as `0x${string}`
      const blockNumber = await client.getBlockNumber().catch(error => { throw userFacingRpcError(error) })
      if (options && 'referralClaimRoundId' in options) {
        await verifyReferralClaim({
          registry: id => client.readContract({ address: factory, abi: factoryAbi, functionName: 'referralRegistryOf', args: [id], blockNumber }),
          version: registry => client.readContract({ address: registry, abi: registryAbi, functionName: 'REFERRAL_REWARDS_VERSION', blockNumber }),
        }, options.referralClaimRoundId, parameters)
      } else if (options && 'nftRoundId' in options) {
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
        const [minimum, seconds, ticketRules] = await Promise.all([
          client.readContract({ address: round[2], abi: hookAbi, functionName: 'MIN_BUY_INPUT', blockNumber }),
          client.readContract({ address: round[2], abi: hookAbi, functionName: 'TIME_PER_UNIT', blockNumber }),
          client.readContract({ address: round[2], abi: hookAbi, functionName: 'TICKET_RULES_VERSION', blockNumber }),
        ])
        assertGameRules(minimum, seconds, ticketRules)
        // v3 ticket-intent guard: a guarded purchase carries its quoted
        // maxTicketPrice; it must still cover the live price at THIS pinned
        // block, or the wallet never opens and the caller refreshes.
        const guardedArgs = parameters.args as readonly unknown[] | undefined
        if (parameters.functionName === 'buyWithMixGuarded' && guardedArgs?.length) {
          assertTicketGuard(guardedArgs[guardedArgs.length - 1] as bigint | undefined,
            await client.readContract({ address: round[2], abi: hookAbi, functionName: 'ticketPrice', blockNumber }))
        }
        if (options && 'referralPurchase' in options) {
          const intent = options.referralPurchase
          const atomicBuy = (parameters.functionName === 'buyWithMix' && parameters.args?.length === 5) ||
            (parameters.functionName === 'buyWithMixGuarded' && parameters.args?.length === 6)
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
      // The wait step already fetches the receipt; keep it so the buy chip
      // decodes mined facts instead of reading the chain a second time.
      let receipt: TransactionReceipt | undefined
      const hash = await confirmTransaction({
        simulate: p => client.simulateContract({ ...p, account: address } as never)
          .catch(error => { throw userFacingRpcError(error) }),
        submit: async p => {
          await ensureWalletChain(address, CHAIN_ID)
          return writeContractAsync(p)
        },
        wait: async hash => {
          let replacementReason: string | undefined
          const mined = await client.waitForTransactionReceipt({
            hash, timeout: 180_000,
            onReplaced: replacement => { if (replacement.reason !== 'repriced') replacementReason = replacement.reason },
          })
          receipt = mined
          return { ...mined, replacementReason }
        },
      }, { ...parameters, account: address, chainId: CHAIN_ID } as typeof parameters, toast?.update)
      // Only buys emit TimeAdded; the chip is the confirmed seconds, never the
      // pre-sign estimate. A claim's hatched pepe comes from its args/receipt.
      if (!fx?.mute) {
        const hatch = kind === 'claimPredeposit' ? fx?.hatch : undefined
        const pepeId = hatch && hatchFxPepeId(parameters.functionName, parameters.args, receipt?.logs, address, hatch.staker)
        fire(kind, anchor, kind === 'buy' ? buyFxDetail(receipt?.logs) : undefined,
          hatch && pepeId !== undefined ? { id: pepeId, dnaVersion: hatch.dnaVersion, staker: hatch.staker } : undefined)
      }
      return hash
    } catch (error) {
      toast?.fail(error)
      if (!validateOnly && !fx?.mute && !isUserRejection(error)) fireFx('fail', { anchor })
      throw error
    }
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
    // One press, one animation: the anchor snapshot at entry rides through
    // approvals and the batch itself. The buy chip detail, if any, comes from
    // the mined receipt at fire time.
    const anchor = captureAnchor()
    const kind = fxKindFor(action.functionName)
    if (!approvals.length) return confirmed(action, false, { anchor })
    // The batch reports exactly ONE fail for a non-rejection, zero for a user
    // rejection, wherever it fails — wallet guard, an approval leg, the atomic
    // batch or the action leg.
    let failReported = false
    try {
      const wallet = await atomicWallet()
      if (!wallet) {
        for (const approval of approvals) {
          try {
            await confirmed(approval, false, { mute: true })
          } catch (error) {
            if (!isUserRejection(error)) { fireFx('fail', { anchor }); failReported = true }
            throw error
          }
        }
        // The action leg owns its own failure FX from here.
        failReported = true
        return await confirmed(action, false, { anchor })
      }
      const toast = startTransactionToast(`approve & ${transactionLabel(action.functionName)}`, CHAIN_ID, address!)
      try {
        const calls = [...approvals, action]
        // Apply the same round, target, referral and reinvestor guards to EVERY call.
        for (const call of calls) await confirmed(call, true)
        // The canonical mined receipt is the one the confirm step already
        // fetches; keep it so the buy chip decodes it with no second read. Its
        // logs are the whole truth — empty means no confirmed TimeAdded, never
        // a reason to mine some other source for events.
        let txReceipt: TransactionReceipt | undefined
        const hash = await confirmAtomicTransaction({
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
          confirm: async hash => {
            const mined = await client!.waitForTransactionReceipt({ hash, timeout: 180_000 })
            txReceipt = mined
            return mined
          },
          notify: toast.update,
        })
        fire(kind, anchor, kind === 'buy' ? buyFxDetail(txReceipt?.logs) : undefined)
        return hash
      } catch (error) {
        toast.fail(error)
        if (!isUserRejection(error)) { fireFx('fail', { anchor }); failReported = true }
        throw error
      }
    } catch (error) {
      if (!failReported && !isUserRejection(error)) fireFx('fail', { anchor })
      throw error
    }
  }

  // The third argument carries FX-only hints (see ConfirmedFx); wagmi-shaped
  // calls keep their full abi inference through the first signature.
  return {
    writeContractAsync: confirmed as typeof writeContractAsync & ((parameters: Write, validateOnly: boolean, fx: ConfirmedFx) => Promise<Hash | undefined>),
    writeWithApprovals, atomicWallet,
  }
}
