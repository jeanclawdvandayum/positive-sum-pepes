import test from 'node:test'
import assert from 'node:assert/strict'
import { encodeErrorResult, toFunctionSelector } from 'viem'
import { controllerAbi, hookAbi, zapInAbi, zapOutAbi, registryAbi, reinvestorAbi } from '../src/lib/abi.ts'
import { userFacingContractError } from '../src/lib/contractErrors.ts'
import { userFacingRpcError } from '../src/lib/rpcErrors.ts'
import { confirmTransaction } from '../src/lib/transactions.ts'
import { confirmAtomicTransaction } from '../src/lib/walletBatch.ts'

const swapTooLarge = encodeErrorResult({ abi: hookAbi, errorName: 'SwapTooLarge' })
const wrappedArgs = ['0x0000000000000000000000000000000000000001', '0x12345678', swapTooLarge, '0x']
const wrapped = encodeErrorResult({ abi: hookAbi, errorName: 'WrappedError', args: wrappedArgs })
const rpcFailure = data => Object.assign(new Error('Execution reverted'), { data })

test('oversized swaps decode across the hook, routers, and nested V4 errors', () => {
  for (const abi of [controllerAbi, hookAbi, zapInAbi, zapOutAbi, registryAbi, reinvestorAbi]) {
    assert.equal(encodeErrorResult({ abi, errorName: 'SwapTooLarge' }), swapTooLarge)
  }
  for (const error of [
    rpcFailure(swapTooLarge), rpcFailure(wrapped),
    rpcFailure({ errorName: 'WrappedError', args: wrappedArgs }),
    new Error('Contract call failed', { cause: rpcFailure(wrapped) }),
    new Error(`Unable to decode signature "${toFunctionSelector('SwapTooLarge()')}"`),
    new Error('The contract function reverted with SwapTooLarge().'),
  ]) {
    const readable = userFacingContractError(error)
    assert.match(readable.message, /maximum input or output/)
    assert.equal(readable.cause, error)
    assert.equal(userFacingContractError(readable), readable)
    assert.match(userFacingRpcError(error).message, /maximum input or output/)
  }
})

test('capacity and curve errors give useful feedback without changing unknown errors', () => {
  for (const errorName of ['FullMulDivFailed', 'MulWadFailed', 'DivWadFailed']) {
    assert.match(userFacingContractError(rpcFailure(encodeErrorResult({ abi: controllerAbi, errorName }))).message, /arithmetic capacity/)
  }
  assert.match(userFacingContractError(rpcFailure(encodeErrorResult({ abi: controllerAbi, errorName: 'PredepositCapacityExceeded' }))).message, /supported launch capacity/)
  assert.match(userFacingContractError(rpcFailure(encodeErrorResult({ abi: hookAbi, errorName: 'ExpPriceArg' }))).message, /supported price range/)
  assert.match(userFacingContractError(rpcFailure(encodeErrorResult({ abi: hookAbi, errorName: 'InvalidParams' }))).message, /valid curve/)
  for (const error of [new Error('User rejected request'), new Error('RPC timeout'), new Error('Unknown revert 0x12345678'), 'unknown']) {
    assert.equal(userFacingContractError(error), error)
  }
  const cyclic = new Error('Unknown failure')
  cyclic.cause = cyclic
  assert.equal(userFacingContractError(cyclic), cyclic)
})

test('v3 helper and round errors remain readable through V4 wrappers', () => {
  for (const [errorName, message] of [
    ['SineV3Domain', /supported reserve range/],
    ['SineV3InverseDidNotConverge', /complete sell quote/],
    ['InvalidRoundHook', /different round/],
  ]) {
    const reason = encodeErrorResult({ abi: hookAbi, errorName })
    const data = encodeErrorResult({ abi: hookAbi, errorName: 'WrappedError',
      args: ['0x0000000000000000000000000000000000000001', '0x12345678', reason, '0x'] })
    assert.match(userFacingContractError(rpcFailure(data)).message, message)
  }
})

test('capacity simulation failure never submits and shows a readable toast', async () => {
  const stages = []
  await assert.rejects(confirmTransaction({
    simulate: async () => { throw rpcFailure(wrapped) },
    submit: async () => assert.fail('must not submit'),
    wait: async () => assert.fail('must not wait'),
  }, {}, (...event) => stages.push(event)), /maximum input or output/)
  assert.equal(stages.at(-1)[0], 'failed')
  assert.equal(stages.at(-1)[1], undefined)
  assert.match(stages.at(-1)[2], /maximum input or output/)
})

test('atomic wallet failure shows a readable error without fabricating a hash', async () => {
  const stages = []
  await assert.rejects(confirmAtomicTransaction({
    send: async () => { throw rpcFailure(wrapped) },
    wait: async () => assert.fail('must not wait'),
    confirm: async () => assert.fail('must not confirm'),
    notify: (...event) => stages.push(event),
  }), /maximum input or output/)
  assert.equal(stages.at(-1)[0], 'failed')
  assert.equal(stages.at(-1)[1], undefined)
  assert.match(stages.at(-1)[2], /maximum input or output/)
})
