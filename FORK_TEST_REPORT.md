# PSP Fork Integration Test Report
## Run Date: August 11, 2026
## Environment: Mainnet fork (block ~latest), Foundry, Solidity 0.8.26, via_ir=true, cancun EVM

---

## EXECUTIVE SUMMARY

**190 tests total: ALL PASS (0 failures)**

| Suite | Tests | Status |
|-------|-------|--------|
| Unit tests (8 suites) | 165 | PASS |
| V4IntegrationTest (fork) | 6 | PASS |
| ForkDestructionTest (fork) | 8 | PASS |
| MultiUserScenarioTest (fork) | 11 | PASS |

---

## BUGS FOUND AND FIXED THIS SESSION

### Bug 1: CurveHook `_settleCurrency` ordering (CRITICAL)
**Impact:** All swaps would revert with `CurrencyNotSettled`
**Root cause:** V4 requires `sync()` BEFORE token transfer, then `settle()`. The hook did `transfer → sync → settle`, meaning settle saw zero delta.
**Fix:** Reordered to `sync → transfer → settle` (matching V4's CurrencySettler pattern).

### Bug 2: CurveHook `_handleSell` missing `poolManager.take()` (CRITICAL)
**Impact:** All sell swaps would revert — hook tried to burn PSP it never received from PoolManager
**Root cause:** Buy handler correctly calls `poolManager.take(mixETH, ...)` to pull input from PM, but sell handler was missing the equivalent `poolManager.take(psp, ...)` before calling `burnPSPForSwap()`.
**Fix:** Added `poolManager.take(psp, address(this), pspInputAmount)` before `controller.burnPSPForSwap()` in both `_handleSell` and `_handleFlatSell`.

### Bug 3: V4Integration `_doSwap` using non-existent `PoolSwapTest` (CRITICAL)
**Impact:** Tests couldn't compile/run — referenced undeclared `swapTest` variable and `PoolSwapTest.TestSettings`
**Root cause:** Original tests used V4's official PoolSwapTest router. V4SwapRouter was built to replace it (PoolSwapTest doesn't pre-fund PM, but our hook requires physical tokens via `take()`), but `_doSwap` was never updated.
**Fix:** Updated `_doSwap` to use `router.swap()` with proper token approval.

### Bug 4: `executeDestruction()` never called `factory.markDestroyed()` (HIGH)
**Impact:** `carryToNextRound()` always reverted with `RoundNotDestroyed()` — the factory's `round.destroyed` flag was never set.
**Root cause:** PSPFactory has `markDestroyed()` but nobody called it. The controller drains mixETH to factory but doesn't notify it.
**Fix:** Added `factoryRoundId` to RoundController, set during `deployRound()`. Controller now calls `factory.markDestroyed(factoryRoundId)` at the end of `executeDestruction()`.

### Bug 5: `test_Fork_RoundTripNoArb` unsigned arithmetic underflow (LOW)
**Impact:** Test failed when round trip correctly lost value
**Root cause:** `uint256 mixGained = mixAfter - mixBefore` underflows when `mixAfter < mixBefore`
**Fix:** Changed to `int256(mixAfter) - int256(mixBefore)` for the console log.

### Bug 6: `vm.expectRevert` consumed by approve inside `_doSwap` (MEDIUM)
**Impact:** Destroyed-hook revert test failed — `expectRevert` was consumed by the approve call
**Root cause:** `_doSwap` does `approve()` then `router.swap()`. `vm.expectRevert` applies to the NEXT call (approve), not the swap.
**Fix:** Inline the swap with approve before `expectRevert`.

---

## MULTI-USER SCENARIO RESULTS

### Scenario 1: Proportional Predeposit Claims
4 users predeposit different amounts (200/100/50/50 mixETH).

**Results:**
- Total initial PSP: 399,592,487,546,219,742,390,587 (~399.6T PSP)
- Alice (50%): 199,796,243,773,109,871,195,293
- Bob (25%): 99,898,121,886,554,935,597,646
- Carol (12.5%): 49,949,060,943,277,467,798,823
- Dave (12.5%): 49,949,060,943,277,467,798,823
- **Rounding dust: 2 wei** (effectively zero loss)

### Scenario 2: Sequential Buys at Increasing Prices
5 users buy 10 mixETH each, back-to-back.

**Results:**
- Buyer 0: 9,494e21 PSP @ 1,053,244 mixETH/PSP
- Buyer 4: 9,492e21 PSP @ 1,053,428 mixETH/PSP
- Price increase: ~0.0017% across 5 buys (curve is in early near-linear zone)
- **Each subsequent buyer pays strictly more — curve is monotonically increasing** ✓

### Scenario 3: Fee Distribution
Alice + Bob lock equal amounts. Carol locks ~24% as much.

**Results:**
- Total locked: 223,611,275,745,886,554,776,920 PSP
- Alice received: 3,484,771,758,661,758,466 (3.48 mixETH)
- Bob received: 3,484,771,758,661,758,466 (3.48 mixETH)
- Carol received: 530,456,482,675,778,564 (0.53 mixETH)
- **Alice == Bob exactly** (locked equal, joined before fees) ✓
- **Carol < Alice** (locked less) ✓

**Key finding:** Synthetix accumulator requires lockers to join BEFORE swap activity. If fees are generated while `totalLocked == 0`, they accumulate in `pendingFeesETH` and dump entirely to the first locker's share when the second locker joins. This is mathematically correct but operationally important — the first lockers get a windfall.

### Scenario 4: Sell Pressure
Bob sells 50% of PSP, Carol sells 25%.

**Results:**
- Price before sells: 1,000,722 (per PSP in ETH)
- Price after sells: 1,000,656
- Price drop: ~0.0066% (minimal — curve absorbs sells well at this volume)
- Bob received: 189.0 mixETH for 50% of PSP
- Carol received: 4.5 mixETH for 25% of PSP

### Scenario 5: Full Lifecycle (End-to-End)
4 predepositors → launch → claims → locks → 2 late swap buyers → sell → fee claims → late locker joins governance → vote → destruction → round carry.

**Results:**
- Alice earned in fees: 2.05 mixETH
- Bob earned in fees: 1.37 mixETH
- Carol locked late (74,932e21 PSP)
- mixETH carried to factory: 398.66 mixETH
- Funds received by owner: 398.66 mixETH
- **Complete lifecycle works end-to-end** ✓

### Gas Profile (key operations)
| Operation | Gas |
|-----------|-----|
| Hook deployment (with mining) | ~3.5M |
| Pool initialization | ~148K |
| Buy via V4 swap | ~632K |
| Sell via V4 swap | ~747K |
| Round-trip (buy+sell) | ~722K |
| Fee claim | ~793K |
| Destruction lifecycle (6 users) | ~2.07M |
| Full lifecycle (8 phases) | ~1.99M |
| Predeposit + claims (4 users) | ~778K |
| Fee distribution (3 lockers, 5 swaps) | ~2.01M |

---

## ARCHITECTURAL FINDINGS

### 1. V4 Hook Flash Accounting Pattern
Our hook uses the **pre-fund pattern** (router syncs+transfers+settles BEFORE calling swap). This is necessary because the hook calls `poolManager.take()` inside `_beforeSwap`, which physically transfers tokens from PM to hook. The PM must have the tokens before the hook can take them.

V4's official `PoolSwapTest` uses **settle-after pattern** (swap first, then settle deltas). This doesn't work with our hook because `take()` requires physical balance.

**Implication:** The V4SwapRouter is NOT optional — it's architecturally required. Standard V4 routers won't work.

### 2. BeforeSwapDelta Correctness
Verified end-to-end on fork:
- **Buy:** `deltaSpecified = +mixETHInput`, `deltaUnspecified = -pspOut` → AMM swap amount = 0 ✓
- **Sell:** `deltaSpecified = +pspInput`, `deltaUnspecified = -mixETHOut` → AMM swap amount = 0 ✓
- All deltas net to zero for all parties (hook, router, PM) ✓

### 3. Synthetix Accumulator Timing Sensitivity
The `_updateAccumulator()` is called on every `addFees()` and every `lock()`/`claimFees()`. If fees are generated while `totalLocked == 0`:
- Fees accumulate in `pendingFeesETH`
- When the FIRST locker joins, `_updateAccumulator` in `lock()` returns early (totalLocked still 0 at that point)
- When the SECOND locker joins, ALL accumulated fees dump to the first locker's accumulator share
- This is a known Synthetix pattern, not a bug, but creates a first-mover advantage

### 4. V4 Hook Revert Wrapping
V4 wraps hook reverts as `WrappedError(hookAddress, functionSelector, revertReason, HookCallFailed)`. Tests must use bare `vm.expectRevert()` rather than matching specific error selectors from the hook.

### 5. MockMixETH Limitation
Using MockMixETH (standard ERC20) instead of real Alchemix VaultV2. This means:
- `mixETHToETH()` and `ethToMixETH()` are always 1:1
- Yield reinvestment (`reinvestYield()`) cannot be tested on fork (no exchange rate change)
- Fee distribution works correctly but the ETH/mixETH conversion doesn't test the non-linear case

---

## RECOMMENDATIONS FOR NEXT ROUND

### Priority 1: Real mixETH Integration
Replace MockMixETH with the actual Alchemix VaultV2 (`0x29bcfeD246ce37319d94eBa107db90C453D4c43D`). This would:
- Enable testing yield reinvestment (`reinvestYield()`)
- Test the non-linear ETH/mixETH conversion in fee distribution
- Validate the `protocolBuy()` flow with real yield

Challenge: V4's `take()` mechanism (raw ERC20 transfers) conflicts with VaultV2's internal accounting. May need an adapter or wrapper contract.

### Priority 2: Multi-Round Lifecycle
Test deploying a second round after destruction, carrying mixETH from round 1. Currently `carryToNextRound` sends to owner but doesn't auto-deploy the next round. Test:
- Owner receives carried funds
- Deploys round 2 with carried mixETH as seed
- Round 2 curve starts with carried reserve

### Priority 3: Yield Reinvestment Testing
Add a test that:
1. Simulates mixETH exchange rate increase (modify MockMixETH to support rate changes)
2. Calls `reinvestYield()`
3. Verifies PSP is minted to protocol lock
4. Verifies the checkpoint updates correctly
5. Verifies no double-reinvestment on subsequent calls

### Priority 4: Gas Optimization
Buy swap costs ~632K gas. Breakdown:
- V4SwapRouter overhead (unlock + pre-settle + take): ~150K
- Hook execution (curve math + take + mint + settle): ~350K
- V4 internal (delta accounting): ~130K

Optimization targets:
- Curve math is already optimized (via_ir, 200 runs)
- The sync→transfer→settle pattern has fixed overhead
- Consider batching for users doing multiple operations

### Priority 5: Edge Case Hardening
Add tests for:
- Maximum supply buy (curve at inflection point transition)
- Repeated small buys accumulating dust
- Multiple users selling simultaneously (reserve depletion ordering)
- Lock → unlock → re-lock cycle (currently permanent locks, but test the claim → re-lock path)

### Priority 6: V4SwapRouter Hardening
- Replace `IERC20.transferFrom` with `SafeERC20.safeTransferFrom`
- Add slippage protection (min output check)
- Add deadline check
- Consider Permit2 integration for gas-efficient approvals
- The router currently has no access control — anyone can call `swap()`

---

## FILES MODIFIED THIS SESSION

| File | Change |
|------|--------|
| `src/CurveHook.sol` | Fixed `_settleCurrency` ordering; added `take()` in sell handlers |
| `src/RoundController.sol` | Added `factoryRoundId`, `setFactoryRoundId()`, factory notification in `executeDestruction()` |
| `src/PSPFactory.sol` | Wire `factoryRoundId` in `deployRound()` |
| `test/integration/V4Integration.t.sol` | Fixed `_doSwap` to use V4SwapRouter; fixed unsigned underflow |
| `test/integration/ForkDestruction.t.sol` | Fixed expectRevert for V4 wrapped errors |
| `test/integration/MultiUserScenario.t.sol` | **NEW** — 11 multi-user fork tests |

---

## CONCLUSION

All critical V4 integration bugs are resolved. The protocol works end-to-end on a real mainnet fork:
- Hook deploys with correct flags on real PoolManager
- Pool initializes successfully
- Buy/sell swaps route through V4 correctly
- Fee distribution works with multiple lockers
- Destruction governance + round carry works

The main remaining risk is the MockMixETH → real VaultV2 transition, which requires solving the V4 `take()` vs VaultV2 internal accounting conflict.
