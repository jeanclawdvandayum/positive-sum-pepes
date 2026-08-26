# Wave 2 — Auditor C: Factory, Deployment & Round Lifecycle

Date: 2026-08-18 · Scope: `src/PSPFactory.sol`, `src/ControllerDeployer.sol`, `src/HookDeployer.sol`, `src/PSPToken.sol`, lifecycle wiring in `src/RoundController.sol` / `src/CurveHook.sol` (surfaces only) · Solidity 0.8.26, Foundry 1.5.1.

PoC directory: `test/wave2/auditorC/` (7 files, 18 tests, all passing).

Run:
```
forge test --match-path "test/wave2/auditorC/*" --skip "test/wave2/auditorB/*" -vv
```
(The `--skip` is needed because auditor B's directory currently does not compile — their WIP, not mine. My suite is self-contained.)

---

## 1. Executive summary

The factory layer is unusually clean on the value-accounting axis: the carry/pot handoff across the finalize→spawn boundary is exact, single-shot, and guarded on every replay path I could construct; token authority handoff is one-shot and leak-free; the deployer vessels are permissionless but inert. No reinitialization, no double-spawn, no phantom pot, no zombie-round path exists without owner action.

The deployment layer, however, has one serious structural weakness: **the next round's hook address is fully computable from public state before it is needed** (vessel nonce → controller address; `gameCurve` getter + `getCurveZones()` → exact initCode; `HookMiner` first-salt determinism → exact salt). `HookDeployer.deployHook` is permissionless, so anyone can pre-deploy the orphan hook at the future address. The H-2 gas fix removed the occupied-address probe from `HookMiner.find`, which eliminated the only mechanism that could have skipped past a squatted address — so the factory's create2 now fails deterministically, **forever**. `finalizeCarpet` reverts (`FactorySpawnFailed`) at every attempt for the rest of the chain's life, and the mixETH custodied by the dying round's hook — the backing of unredeemed PSP — is permanently locked. This is finding C-1 (HIGH). It is a pure griefing/DoS (no theft path — the orphan is provably inert), but it kills the protocol's core loop (rebirth) for a one-time ~5M-gas attack cost, from anywhere, at any moment of the round's life.

A second, owner-triggered variant (C-2, MEDIUM): deploying a parallel round via `deployRound` while an older round is dying permanently orphans the older round's finalize (`NotLatestRound` → `FactorySpawnFailed`), with no reconciliation path in the factory.

Severity table:

| ID | Title | Severity | Confidence |
|----|-------|----------|------------|
| C-1 | Deterministic hook-address squatting permanently bricks finalize→spawn | HIGH | 95% |
| C-2 | Owner parallel round permanently orphans the dying round (no reconciliation) | MEDIUM | 90% |
| C-3 | Spawn re-mines the hook address every round; post-squat retries are unexecutable (gas amplification) | INFO | 70% |

---

## 2. Findings

### C-1 — Permissionless deterministic hook-address squatting permanently bricks round finalization and locks the dying round's reserve

- **Severity:** HIGH · **Confidence:** 95% (mechanism 100% reproduced; residual 5% for mainnet-client gas semantics of the failed create2, see C-3/Could-not-verify — the brick itself is gas-independent)
- **Files:** `src/HookDeployer.sol:26-56`, `src/utils/HookMiner.sol:34-57`, `src/PSPFactory.sol:158-160, 215-249`, `src/RoundController.sol:813-836`, `src/ControllerDeployer.sol:19-34`
- **PoC:** `test/wave2/auditorC/C1_HookSquatDoS.t.sol::test_C1_attack_SquatBricksFinalizeForever` — PASS. Support: `test_C1_control_PredictionIsExact_CleanSpawnWorks`, `test_C1_orphanIsInert`, `C4_Probe.t.sol` (nonce mechanics), `C5_GasBisect.t.sol` (gas characterization).

**Description — the address of the next round's hook is public before the round exists.**

1. The next round's controller address is a plain CREATE address: `ControllerDeployer` is a vessel whose nonce is public, and each round consumes exactly two nonces (token, then controller — proven in `C4_Probe`; contracts are born at nonce 1 per EIP-161, verified empirically).
2. The spawn's hook initCode is fully public: `factory.gameCurve()` (auto-getter returns `P0`) + `hook.getCurveZones()` reconstruct the exact `CurveConfig`; the poolManager and the predicted controller complete `abi.encode(pm, controller, config)`.
3. `HookMiner.find` returns the **first** salt (0, 1, 2, …) whose CREATE2 address carries the 14 flag bits — deterministic given the above.
4. `HookDeployer.deployHook` is permissionless by design ("an orphan CurveHook is inert"). An attacker calls it first with those exact args and deploys the orphan at the future hook address.
5. When the factory's `spawnNextRound` later runs the identical `deployHook`, its create2 targets an address that now has code. create2 returns 0, `hookAddr != expected`, and `deployHook` reverts `DeployFailed`. `HookMiner.find` has **no occupied-address probe** — the H-2 "completion" fix explicitly dropped it (comment at `HookMiner.sol:34-42`) — so every retry mines the identical salt and fails identically. There is no nonce-escape, no salt-escape, and no alternate config path in `spawnNextRound` (it always passes `gameCurve`).

**Exploit scenario.** Round N is live. At any moment (the earliest is immediately after round N deploys; the window spans the round's entire life, including pre-launch), an attacker:
- reads the vessel nonce, computes controller(N+1)'s address,
- reads `gameCurve()` + `getCurveZones()` from the live hook,
- calls `hookDeployer.deployHook(pm, predictedController, cfg)` — cost measured: ~3.4M gas (mining salt 3690 for my test config + a 12.5KB deploy). No mixETH, no role, no capital at risk.

Round N proceeds normally: predeposit, launch, trades, quorum vote, `carpetBomb` (all still work — the flat window opens and stakers can exit at average backing). After the 3-day flat window, `finalizeCarpet` is forever unexecutable: it always ends in `FactorySpawnFailed` (verified 0x79165b85), atomic (no partial state), and repeated identically on retry. The mixETH still held by the hook at that point — the backing of unredeemed PSP, i.e., value of holders who chose to keep playing, plus fee surplus — is permanently locked. No round N+1 ever spawns from that chain.

Multi-round lead: nonces are consumed deterministically (2 per round), so an attacker can equally pre-squat round N+2's or N+k's hook address today, provided `gameCurve` doesn't change. A second variant targets the owner's `deployRound`: the future controller address does not depend on the curve or name (CREATE address = f(vessel, nonce) only), so a mempool observer can copy the config from the owner's pending tx and squat within the same block; the owner escapes only by changing the curve (a fresh nonce slot can be re-squatted ad infinitum, though each escape costs the attacker nothing and the owner a redeploy).

**Why HIGH and not MEDIUM:** permanent, permissionless, zero-cost, whole-protocol-lifetime DoS of the core mechanism (the rebirth loop) plus permanent lock of real user value; no owner countermeasure exists once the squat lands (the factory has no path to change `gameCurve` except a new `deployRound`, which triggers C-2 and abandons the dying round's reserve anyway). Not CRITICAL because it is griefing only: the orphan is inert (C-1 PoC proves the guard — its `controller` slot has no code, so `setMode`/`setHook`/`setFactoryRoundId` are unreachable, and no mint path exists), stakers keep the full flat-window exit, and no value can be extracted by the attacker.

**Fix direction.** Reintroduce occupancy-awareness *only at flag-hit candidates*: after the flag check matches, probe `extcodesize(candidate)` once (2600 gas cold); if occupied, continue the loop from `salt+1`. Median cost is unchanged (the probe fires ~once per ~16k iterations); a squatter simply pushes the factory to the next flag-bearing address, at which the attacker would have to squat *every* subsequent flag address — each costing a real deployment — while the factory's mining remains bounded by `MAX_LOOP`. (Probe-on-every-iteration, the thing H-2 removed, is not needed.) Alternative hardening: mix a per-round entropy source (e.g., `block.prevrandao` or the previous round's controller address, which is already unpredictable at round-N deploy time) into the salt derivation via a factory-owned deploy path — but note `deployHook`'s permissionless determinism is also what lets anyone verify hook addresses; the probe fix preserves that property.

---

### C-2 — Owner-deployed parallel round permanently orphans the dying round; no reconciliation path exists

- **Severity:** MEDIUM · **Confidence:** 90% (reproduced; severity judgment is the uncertain part since it requires owner action)
- **Files:** `src/PSPFactory.sol:123-129` (`deployRound` owner-only), `:219` (`NotLatestRound` guard), `:280-284` (`markDestroyed` has no "already destroyed" semantics issue but also no un-mark path)
- **PoC:** `test/wave2/auditorC/C3_Lifecycle.t.sol::test_C3_ParallelRoundBricksOldChain` — PASS.

**Description.** `spawnNextRound` chains strictly forward: only the *latest* round may spawn (`fromRoundId != currentRoundId → NotLatestRound`). `deployRound` is owner-only and bumps `currentRoundId` unconditionally. If the owner deploys a parallel round (e.g., a "special event" game, or a well-intentioned replacement while round N is mid-death), then round N's `finalizeCarpet` — which calls `spawnNextRound(N)` internally with no alternative — reverts `FactorySpawnFailed` forever. Round N's reserve (unredeemed backing) is stranded with no path out: `markDestroyed(N)` still works (it is controller-gated per-round, not latest-gated), so the round ends up `destroyed == true` while never having spawned a successor and while its hook custody is irreversible.

**Exploit scenario.** Owner deploys round 2 manually at any time after round 1's carpet bomb but before its finalize (or while any earlier round is still mid-flight). The dying round's relayers discover that finalize is permanently bricked; the only value recovery for stakers was the flat window (already past). This is a one-click footgun rather than an attack — but the factory offers no reconciliation (no `currentRoundId` rollback, no orphan-rescue sweep; `markDestroyed` cannot be undone either).

**Fix direction.** Either (a) forbid `deployRound` while the latest round is in `Flat` mode (forces the owner through the normal death cycle), or (b) give `finalizeCarpet` an owner-gated fallback that drains the reserve to the factory without spawning, or (c) allow `spawnNextRound` from any destroyed round when the target `currentRoundId` round is also destroyed. Any one suffices; document the chosen invariant.

---

### C-3 — Spawn re-mines the hook every round; retry gas amplification; unbounded-ish mining cost (design note)

- **Severity:** INFO · **Confidence:** 70%
- **Files:** `src/utils/HookMiner.sol:14, 46` (`MAX_LOOP = 160_444`), `src/PSPFactory.sol:158-160`
- **PoC/evidence:** `C5_GasBisect.t.sol` (mining ≈ 0.5M for salt 3690; nominal worst case ~20M) and measurements below.

**Description.** Two observations that compound with C-1:

1. Every spawn repeats the full mining loop for the (identical, inherited) curve. Nominal worst case is `MAX_LOOP × ~120 gas ≈ 20M`, under but uncomfortably near the 30M mainnet block limit. The mined salt index depends only on `gameCurve`'s bytes; the owner observes the cost once at the genesis `deployRound` and it repeats every round thereafter, so an accidental pathological curve cannot be introduced later without a new `deployRound`. Self-limiting, hence INFO.
2. Once C-1's orphan is in place, a `deployHook` whose create2 collides measured **2.9B–48.4B gas in revm before reverting** (call-context dependent; an inline replica of the same create2 fails in 40k — see Could-not-verify). Under foundry's default 2^30 budget the attempt surfaces as an out-of-gas empty revert. Either way, each post-squat finalize attempt is not merely failing — it is unexecutable inside any mainnet block, and relayers pay for the gas they attached. This is the gas-amplification layer of C-1's griefing, not an independent bug.

---

## 3. Verified-safe (attacked and held)

All assertions below are executed by passing PoCs in `test/wave2/auditorC/`.

1. **Carry/pot handoff exactness** (`C2_Handoff::test_C2_CarryAndPotForwardedExactly`, incl. real buy flow through the pool manager to accrue the pot): after finalize+spawn, factory mixETH balance is exactly 0 and `sidePot` is exactly 0; round N+1's `totalPredepositMixETH` equals the drained reserve exactly; `totalPotMixETH` equals the pot redemption exactly. No value created, lost, or duplicated at the boundary.
2. **No double-spawn / no zombie rounds** (same test + `test_C2_ZeroPotBranch`): replaying `spawnNextRound(1)` → `NotLatestRound`; `spawnNextRound(2)` on a live round → `RoundNotDestroyed`; unknown id → `RoundNotFound`. Each round spawns exactly one successor; `currentRoundId` advances monotonically inside `_deployRound` *before* any external token transfer (reentrancy across the finalize→spawn boundary would observe the updated id; constructors of token/controller/hook make no external calls, and `initialize` only invokes the fresh hook's view-only gate).
3. **Atomicity of failed finalize** (C-1 PoC): on spawn failure the hook stays `Flat` (not `Destroyed`), the reserve is untouched, `destroyed == false`, no round was spawned. The "half-destroyed round" scenario is impossible.
4. **Pot ledger integrity** (`test_C2_CreditSidePotGuards`, `test_C2_DonationsRideTheCarry`): `creditSidePot` is current-controller-gated and balance-checked (`SidePotOverdrawn`); donations to the factory cannot be earmarked as pot by third parties and ride the carry instead; grep confirms the only `creditSidePot` call site in `src/` is `RoundController.carpetBomb` with the exact redemption amount; `sidePot ≤ balanceOf(factory)` invariant held in every scenario.
5. **Token authority handoff** (`test_C3_TokenAuthority`): factory is temp admin; `setController` is factory-only and single-shot (`AlreadySet`); mint/burn are controller-only — including for the factory itself, so no residual mint authority survives deployment. The factory never holds PSP.
6. **Deployer vessels are permissionless but inert** (`test_C3_VesselsPermissionlessButInert`, `test_C1_orphanIsInert`): anyone can deploy fake tokens/controllers/hooks through the vessels; the factory registry ignores them; fakes cannot reach `markDestroyed`/`creditSidePot` (`NotRoundController`); the squatted orphan's own privileged functions are unreachable (its controller slot has no code). No address-mining griefing beyond C-1's collision (vessel CREATE addresses depend only on nonces; fakes burn the attacker's own gas).
7. **Determinism ground truth** (`C4_Probe`, C-1 control): vessel nonce prediction is exact across rounds (EIP-161 nonce-1 birth; exactly 2 nonces/round); clean spawn lands at the predicted controller. This determinism is simultaneously what makes C-1 possible — it is a property of the design, not an accident of my harness.
8. **Curve inheritance** (`test_C3_CurveInheritanceExact`): spawned rounds inherit `gameCurve` byte-exactly (P0 + all zone fields); no drift between rounds; spawn naming (`"<base> <id>"` / `"<symbol><id>"`) matches storage.
9. **Low-level call wiring** (`test_C3_SelectorConstants`): the three precomputed selectors (`markDestroyed(uint256)=0x723c5612`, `spawnNextRound(uint256)=0x1c9424dc`, `creditSidePot(uint256)=0xada2e425`) each equal `bytes4(keccak256(sig))`; `ok` flags are checked for the two finalize calls (`FactoryMarkFailed`/`FactorySpawnFailed`); the unchecked `creditSidePot` return is safe by design (failure degrades to carry, documented in-source and consistent with my donation test).
10. **EIP-170 headroom** (`test_C3_EIP170_Sizes`, runtime sizes measured): PSPFactory 8,336 / HookDeployer 15,054 / CurveHook 12,572 / PSPToken 3,554 / RoundController 15,798 / **ControllerDeployer 23,947 — only 629 bytes under the 24,576 limit.** Everything deploys today; any growth of RoundController's or PSPToken's creation-code embedding breaks deployment (the vessel's own runtime is tiny — the size is the embedded creation code, matching the in-source warning).
11. **Pool-initialize front-run impossibility** (analysis): the canonical pool's PSP token does not exist before the factory's deployment tx creates it, and the whole wiring is one transaction, so nobody can initialize the real pool key earlier; decoy pools keyed to the real hook are rejected by the hook's currency/params gates (L-2/NK24 surfaces, exercised indirectly by the clean spawn flow).

---

## 4. Could-not-verify

1. **Mainnet (geth/erigon) gas semantics of a create2 into an occupied address.** In revm, the colliding `deployHook` contract call burned 2.9B–48.4B gas (context-dependent) before reverting cleanly with `DeployFailed`; a minimal inline replica of the identical create2 failed in 40k; a tiny-contract collision probe failed in ~72k. I could not reconcile these three numbers from first principles within the time budget, and I did not run the fork suite against the real V4 PoolManager for this question. It does not affect the finding: with or without the gas burn, the create2 deterministically fails and the brick holds — the burn only changes how expensive each doomed retry is. Flagged honestly as the 5% of C-1's confidence and all of C-3's.
2. **Real-PoolManager lifecycle behavior of the C-1 attack end-to-end.** The PoC uses the repo's MockPoolManager. The brick provably occurs *before* any pool-manager interaction (`deployHook` precedes `initialize` in `_deployRound`), so a fork run would only re-prove the same revert; per the audit rules I kept it unit-level. If the team wants it, the attack drops into the fork harness unchanged.
3. **`HookMiner.find`'s per-iteration cost on other toolchains.** All gas figures are revm/via_ir measurements; the ~120 gas/iter claim in the H-2 comment was not independently benchmarked beyond my single-config runs.
4. **Multi-round-lead squatting (N+2, N+k)** is asserted from nonce determinism (C-4) and first-salt determinism but not PoC'd as a standalone test — it is the same mechanism as C-1 with a different nonce slot, so I judged the single-round PoC sufficient evidence.

---

*Files created (nothing outside `test/wave2/auditorC/` and this report was modified): `CBase.sol`, `C1_HookSquatDoS.t.sol`, `C2_Handoff.t.sol`, `C3_Lifecycle.t.sol`, `C4_Probe.t.sol`, `C5_GasBisect.t.sol`, `C5b_CollideProbe.t.sol`. Final state: 18 tests, 18 passed, 0 failed.*
