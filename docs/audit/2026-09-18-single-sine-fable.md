# Single-sine v3 audit pass — September 18, 2026

**Target:** `single-sine-spec` @ `e9a70d44` (remote tip, clean tree at start).
**Reviewer:** Claude Fable 5.1, fresh-eyes pass after the Codex Astra (Sept 15/16) and GLM 5.3 (Sept 16) reviews.
**Scope:** every contract in `src/` on the live deployment path (factory, controller, hook, staker, referral registry, both zaps, grave zap, reinvestor, deployer vessels, `SineV3Math`/`Price`/`Primitive`, testnet mixETH and faucet, name gates), the deployment scripts and driver, and the pre-launch window that the Sept-16 report flagged as outside its attack surface.
**Method:** full line-by-line read of the contracts above; invariant reasoning on hook custody, the staker weight engine and the genesis share pool; selector and timing-packing checks; six new integration PoCs through the real local V4 `PoolManager` (`test/FableAuditPoC.t.sol`, 6/6 pass, one fuzz at 256 runs).

## Verdict

**No Critical, High or Medium findings. The branch is safe to deploy as specified.** Nothing in `src/` required a change. Everything below is either a design property that deserves a documented line, or an operator-trust note. Each is pinned by a passing test so the behaviour is evidence, not speculation.

## Confirmed invariants

- **Hook custody.** `balance(hook) == reserveMixETH + (potBalance − potPaid) + (deployerCredit − deployerCreditPaid) + unclaimed staker fees` holds through buys, sells, referral transfers, genesis, flat sells, redemption and pot/credit claims. Referral mixETH leaves the hook at trade time and is backed 1:1 in the registry (`UnbackedRewards` check).
- **Supply never exceeds the curve integral.** `totalSupplyPSP ≤ Q(reserveMixETH)` after genesis, every buy (one-wei + 1 bp haircut) and every sell (smallest reserve whose rounded supply reaches the target). This makes `sellOut`'s whole-supply early return unreachable from execution. Re-asserted after every fuzzed trade in F6.
- **Fee split.** `stakerLeg + potΔ + deployerCreditΔ + referralPaid == fee` in both the attributed and unattributed branches; sell fees come out of the reserve debit, never out of user output twice.
- **Clock.** Halt check precedes time-add; `detonationAt` can only move forward and never past `now + detWindow`; `detonate()` is idempotent via the mode transition guard, tolerates a failed spawn, and never runs the spawn with under 30M gas.
- **Staker weight engine.** Every schedule writer checkpoints first, so all decay deltas land within seven transitions of the last stored point (the `_advance` cap is safe). Request, cancel, withdraw-in-vest, withdraw-after-vest and withdraw-at-flat all leave the global point equal to the sum of live position weights, including the divisible-by-six dust path. Genesis claims split accrued fees pro-rata against the remaining genesis principal, which is time-correct because the claimed share leaves the pool.
- **Bootstrap admission.** `_validateBootstrap` runs the exact launch calculation (`totalBoot − 10%`) on every deposit and carry, so `launchPooledBuy` cannot fail on a domain error after deposits were accepted.
- **Selectors.** `markDestroyed(uint256)` = `0x723c5612`, `spawnNextRound(uint256)` = `0x1c9424dc` (verified with `cast sig`). Timing slots: controller reads [0], [1], [3]; hook reads [2]; widths 64 bits.
- **Staged birth.** All vessel deploy functions are permissionless but address-committed (identical initcode + salt + vessel), pool init is factory-only, and the context hash covers curve, descriptor, name, symbol, `useSine`, `gameSinePL` and the table.

## Residual notes (no source change)

| ID | Severity | Behaviour | Evidence |
|----|----------|-----------|----------|
| F-1 | Low | **Generic routers strand pot seats.** A swap with empty `hookData` seats `sender` (the router contract). After detonation that pot share is claimable only by the router, which normally cannot call `claimPot`, so the mixETH stays in escrow forever. This is the correct consequence of untrusted `hookData` (a seat can only ever credit the named address), and the canonical zaps and registry always pass the trader. Recommend a one-line integrator warning in `CLOCK-REDESIGN.md` / README: "only route through `PSPZapIn` or `PSPReferralRegistry.buyWithMix`, or pass `abi.encode(trader)` as hookData." | `test_F1_EmptyHookDataSeatsTheRouterAndStrandsThePot` |
| F-2 | Info | **Referral self-rebate by NFT custody.** Record against a friend's qualifying NFT, then take custody of it: the trader collects the tier-1 cut (80 % of the 5 %-of-fee leg) on their own trades. Equivalent to the existing two-wallet sybil; the leg otherwise goes 4 % pot / 1 % deployer, so the bound on leakage is 4 % of the fee. Accepted design; noted so nobody later mistakes it for a bypass of `SelfReferral`. | `test_F2_ReferralSelfRebateViaNftTransfer` |
| F-3 | Info (owner trust) | **`reserveGenesis` / `deployRound` have no "current round is dead" guard.** The owner can birth round N+1 while round N is Active; round N still flattens and pays out on `detonate()`, but its in-tx spawn fails (`NotLatestRound`, tolerated) and the UI follows `currentRoundId`. This is also the only escape hatch for a round that never launches (zero deposits leave it in Predeposit with no kill path), so it should stay. Treat the factory owner key as a game-loop admin. | `test_F3_OwnerCanBirthGenesisOverALiveRound` |
| F-4 | Info | **Pre-launch minimum after rebirth is 0.005 mixETH** (471b0443) and flips to `ceil(pot/10 000)` at launch. Predeposit costs ~0.77–0.87 M gas because each deposit re-runs the genesis integral through the Bernstein primitive; acceptable on Base, worth knowing for the UI's gas estimate. | `test_F4_RebirthPreLaunchMinimumAndPredepositGas` |
| F-5 | Info | **Third-party `stakeFor` is harmless.** A stranger topping up someone's pepe by 1 wei forces the owner's accrued fees to settle *to the owner*, adds principal, and cannot start or reset a decay. | `test_F5_StrangerStakeForOnlyBenefitsOwner` |
| F-6 | Info | **Dust-size buys (v3 exemption from `MIN_SWAP_INPUT`).** On a 0.05 mixETH round the ladder spot is ~5e11 wei, below the 1e12 dust guard. Fuzzed multi-leg buy-then-sell round trips from the spot up to 1e14 wei always lose, and both custody invariants hold after every run. | `testFuzz_F6_TinyRoundDustRoundTripNeverWins` (256 runs) |
| F-7 | Info | **Degenerate launches.** The spec supports one-wei launches. A boot below ~1e6 wei gives a reserve capacity (`boot + 4096·λ`) of well under 1e-3 mixETH and a 1-wei ticket, so a round launched from dust is unplayable until it detonates. Since any real depositor makes the boot real, this only bites when nobody else deposited during the window, in which case the round had no audience anyway. No change recommended; mention in the operator runbook. | analytical (`lamAt`, `POST_WAVES`) |

## Things checked and found clean

- Reentrancy: hook swap paths are CEI with plain ERC-20s on both sides; `redeemBacking`, `claimPot*`, `claimDeployerCredit` update books before transfer; staker, controller, registry, reinvestor use `nonReentrant`; ERC-721 receiver callbacks run after all effects with the guard held.
- Access: `setMode`/`initializeCurve`/`mintPSPForSwap`/`burnPSPForSwap`/`addFees` are controller- or hook-only; `configureSineV3` is factory-only and pre-init; `sendFees` is controller/staker-only; `creditReferralRewards` is hook-only and balance-backed; `reserveGenesisPepe`, `lockGenesis`, `claimGenesisShare*` are controller-only; `markDestroyed` is the round's own controller only; `withdrawFor` pays the owner regardless of caller; grave zap checks `ownerOf` per id.
- Quote/execution parity, ticket guard, pre-fee sampling, binding minimum: unchanged since the Sept-16 PoCs (re-run green in the same suite run).
- Deployment: `DeployPSP` deploys the four data shards and `SineV3Math` in their own broadcast, pins the table in the factory constructor, sets the descriptor before genesis, arms sine before `reserveGenesis`, and births in three steps; `base-sepolia.mjs` rejects retired v2 knobs, zero windows, sub-six or non-divisible vests, and the public Anvil key. `_validateCurrentRound` cross-checks every wiring edge post-birth.
- Tracked env files carry only public RPC URLs; `.env` and `frontend/.env.local` are git-ignored.

## Gates at this commit

- `forge test` (full, incl. integration): **721 pass / 0 fail** on the tree as pushed, plus **6/6** new PoCs → 727. The two `test/integration` fork suites (`WeiNamesForkTest`, `ZapSwapsTest`) fail only on missing `WNS_FORK_RPC_URL` / Alchemy credentials in this environment, as recorded in earlier entries.
- `scripts/check-no-governance.sh`: clean.
- `scripts/check-sizes.py`: 50 production artifacts pass; `CurveHook` runtime unchanged, `SineV3Math` 14,182 B, shards 21,993 / 22,001 / 22,001 / 18,705 B.
- Slither: not installed on this machine; no new static-analysis result claimed. The only `src/` diff since the Sept-16 slither run is the one-line `ticketPrice()` gate in 471b0443.
- No public deployment, publication, or live-address change forms part of this pass.
