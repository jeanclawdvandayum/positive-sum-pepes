import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import { encodeFunctionResult, decodeFunctionResult } from 'viem'
import { controllerAbi, hookAbi } from '../src/lib/abi.ts'
import { predepositResult } from '../src/lib/chainResults.ts'

test('deployed getter bytes preserve deposit amount and genesis claim availability', () => {
  const abi = JSON.parse(fs.readFileSync(new URL('../../out/RoundController.sol/RoundController.json', import.meta.url))).abi
  for (const claimed of [false, true]) {
    const data = encodeFunctionResult({ abi, functionName: 'predeposits', result: [5_000_000_000_000_000n, claimed] })
    const raw = decodeFunctionResult({ abi: controllerAbi, functionName: 'predeposits', data })
    assert.deepEqual(predepositResult(raw), { mixETHAmount: 5_000_000_000_000_000n, claimed })
  }
  assert.throws(() => predepositResult(undefined))
})

test('curve config getter returns price and packed timings as two outputs', () => {
  const abi = JSON.parse(fs.readFileSync(new URL('../../out/CurveHook.sol/CurveHook.json', import.meta.url))).abi
  const data = encodeFunctionResult({ abi, functionName: 'curveConfig', result: [100_000_000_000_000n, 7200n] })
  const raw = decodeFunctionResult({ abi: hookAbi, functionName: 'curveConfig', data })
  assert.deepEqual(raw, [100_000_000_000_000n, 7200n])
})
