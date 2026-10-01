# 🔐 Security Review — positive-sum-pepes

---

## Scope

|  |  |
| --- | --- |
| **Mode** | default |
| **Files reviewed** | `./script/CompleteBaseDeploy.s.sol` · `./script/CompleteGenesis.s.sol` · `./script/DeployGraveZap.s.sol`<br>`./script/DeployNames.s.sol` · `./script/DeployPSP.s.sol` · `./script/DeployReinvestor.s.sol`<br>`./script/DeployRemoteNames.s.sol` · `./script/DeploymentSupport.sol` · `./script/DriveAnvil.s.sol`<br>`./script/RepairReinvestor.s.sol` · `./src/ControllerDeployer.sol` · `./src/CurveHook.sol`<br>`./src/HookDeployer.sol` · `./src/HookInitCode.sol` · `./src/PSPFactory.sol`<br>`./src/PSPGraveZap.sol` · `./src/PSPReferralRegistry.sol` · `./src/PSPReinvestor.sol`<br>`./src/PSPStaker.sol` · `./src/PSPToken.sol` · `./src/PSPZapIn.sol`<br>`./src/PSPZapOut.sol` · `./src/PepeArtData.sol` · `./src/PepeArtData8Bit.sol`<br>`./src/PepeDescriptor.sol` · `./src/PepeDescriptor420.sol` · `./src/PepeDescriptor8Bit.sol`<br>`./src/PepeExpandedDescriptor.sol` · `./src/ReferralRegistryInitCode.sol` · `./src/RoundController.sol`<br>`./src/SineV3Bernstein.sol` · `./src/SineV3Data.sol` · `./src/SineV3DataInfo.sol`<br>`./src/SineV3Math.sol` · `./src/SineV3Price.sol` · `./src/SineV3Primitive.sol`<br>`./src/StakerDeployer.sol` · `./src/VectorBaseArt.sol` · `./src/VectorPepeDescriptor.sol`<br>`./src/VectorTraitArt.sol` · `./src/VectorTraitArt2.sol` · `./src/art/ExpandedPepeArt.sol`<br>`./src/art/PepeArt420.sol` · `./src/curves/Curve1Zones.sol` · `./src/curves/Curve2Zones.sol`<br>`./src/curves/Curve3Zones.sol` · `./src/curves/LinearZones.sol` · `./src/curves/LinearZonesLean.sol`<br>`./src/libraries/CurveMath.sol` · `./src/libraries/GameRules.sol` · `./src/libraries/PepeDna.sol`<br>`./src/libraries/SineMath.sol` · `./src/names/PSPNameCustody.sol` · `./src/names/PSPNameRegistrar.sol`<br>`./src/names/PSPRemoteNameGate.sol` · `./src/names/PSPStakeNameGate.sol` · `./src/testnet/MixETHFaucet.sol`<br>`./src/testnet/SepoliaMixETH.sol` · `./src/utils/HookMiner.sol` · `./studio-420/art/PepeArtData.sol`<br>`./studio/expanded/PepeArtData.sol` · `./studio/spec/golden/PepeArtData.sol` · `./vesting-migration-pending/wave2/auditorA/AuditorBase.sol` |
| **Confidence threshold (1-100)** | 75 |
| **Passes** | 3 |
| **Memory** | 0 records before this scan · 47 after · `18419ead` |

---

## Findings

[95] **1. 2. Zero-value transfers inflate the holder count and shrink the next green cap**

`PSPToken._update` · Confidence: 95 · seen in 3/3 runs · NEW

**Description**
An attacker sends zero-value transfers to fresh addresses, so the frozen holder count grows and the next round gives each greenlisted wallet a dust cap.

**Fix**

```diff
- if (to != address(0) && !holder[to]) { holder[to] = true; holderCount++; }
+ if (to != address(0) && value > 0 && !holder[to]) { holder[to] = true; holderCount++; }
```

---

[90] **2. 8. Attacker mints chosen pepe ids during the staged-birth window**

`PSPStaker.lockWithPepe` · Confidence: 90 · seen in 3/3 runs · NEW

**Description**
An attacker who calls lockWithPepe between the staged birth transactions takes the chosen pepe id before any depositor can reserve it.

**Fix**

```diff
  function _requireAlive() internal view {
-   if (controller.flatTime() != 0) revert DeadRound();
-   address hook = controller.hookAddress();
+   address hook = controller.hookAddress();
+   if (hook == address(0)) revert RoundNotWired(); // no mints before birth tx 3
+   if (controller.flatTime() != 0) revert DeadRound();
```

---

[90] **3. 1. Zero-deposit round never launches and blocks every later round**

`RoundController.launchPooledBuy` · Confidence: 90 · seen in 3/3 runs · NEW

**Description**
Nobody deposits, so sineGenesisPSP reverts on zero boot, the round stays in Predeposit, and no successor round can spawn.

**Fix**

```diff
- uint256 initialPSP = hook.sineConfigured() ? hook.sineGenesisPSP(curveBoot) : CurveMath.computeBuyOutput(curveBoot, 0, curveConfig);
- if (initialPSP == 0) revert ZeroAmount();
+ if (totalBoot == 0) { predepositClosed = true; hook.setMode(CurveHook.Mode.Flat); }
+ else { uint256 initialPSP = ...; if (initialPSP == 0) revert ZeroAmount(); }
```

---

[85] **4. 6. A router takes the ladder seats of the traders it routes**

`CurveHook._handleBuy` · Confidence: 85 · seen in 3/3 runs · NEW

**Description**
A contract that executes a pool swap without trader hookData takes the ladder seats and pot payouts of the humans it routes.

**Fix**

```diff
- address buyer = refTrader != address(0) ? refTrader : sender;
+ address buyer = refTrader != address(0) && referralRegistry.isRegisteredForwarder(sender) ? refTrader : sender;
```

---

[80] **5. A direct pool caller forges the payout identity inside hookData and collects the referral leg**

`CurveHook._beforeSwap` · Confidence: 80 · seen in 1/3 runs · NEW

**Description**
A direct pool caller decodes any address as refTrader, so the hook pays the referral leg of the caller's own volume to that address.

**Description (family)**
Decode-site entry of the same unauthenticated-hookData family as the seat-credit and self-referral findings: one root cause, three money legs (seats, clock tape, referral leg).

**Fix**

```diff
- address refTrader = hookData.length == 32 ? abi.decode(hookData, (address)) : address(0);
+ address refTrader = hookData.length == 32 && registryRouter[sender]
+     ? abi.decode(hookData, (address)) : address(0); // attribute only authenticated forwarders
```

---

[80] **6. 7. Sell events name the PoolManager as the seller**

`CurveHook._handleSell` · Confidence: 80 · seen in 3/3 runs · NEW

**Description**
CurveHook records the PoolManager as the seller in every Sell event, so indexers attribute each sale to the wrong address.

**Fix**

```diff
- emit Sell(msg.sender, pspInputAmount, mixETHToUser, totalSupplyPSP, reserveMixETH);
+ emit Sell(resolvedSeller, pspInputAmount, mixETHToUser, totalSupplyPSP, reserveMixETH);
```

---

[80] **7. A staker attributes a second wallet to the staker's own NFT and collects 80 percent of each referral fee leg**

`PSPReferralRegistry.record` · Confidence: 80 · seen in 2/3 runs · NEW

**Description**
A staker records a second wallet against the staker's own pepe, then trades under that identity and takes 80 percent of every referral fee leg.

**Fix**

```diff
- // record() accepts any caller as refTrader for a qualified NFT
+ require(refTrader == msg.sender || registryRouter[msg.sender], UnauthenticatedReferrer());
+ // pay referral legs only when the hookData identity is authenticated against the funding account
```

---

[75] **8. 12. A griefer freezes an empty greenlist before the owner sets it**

`PSPFactory.reserveSpawn` · Confidence: 75 · seen in 3/3 runs · NEW

**Description**
Any caller reserves the next round before the owner sets the csv greenlist, so the round births with only previous-round holders greenlisted.

**Fix**

```diff
- function reserveSpawn(uint256 fromRoundId) external {
+ function reserveSpawn(uint256 fromRoundId) external {
+   if (nextGreenCount == 0 && nextGreenRoot == 0) revert GreenlistNotSet(); // or keep owner-gated until set
```

---

[75] **9. 11. GraveZap exit moves user PSP to an attacker-supplied hook**

`PSPGraveZap.exit` · Confidence: 75 · seen in 3/3 runs · NEW

**Description**
A phisher who supplies a fake hook and staker makes the user's signature move approved PSP to the fake hook for one wei of mixETH.

**Fix**

```diff
- GraveStaker(staker).claimAllTo(pepeIds, msg.sender);
+ require(staker == canonicalStaker && hookAddr == canonicalHook, BadTarget());
+ GraveStaker(staker).claimAllTo(pepeIds, msg.sender);
```

---

[75] **10. 3. Protocol custodians count as holders and shrink every green cap**

`PSPToken._update` · Confidence: 75 · seen in 3/3 runs · NEW

**Description**
The staker, the hook, and the controller hold PSP, so the frozen holder count includes them and the next green cap is divided by one too many.

**Fix**

```diff
- if (to != address(0) && value > 0 && !holder[to]) { holder[to] = true; holderCount++; }
+ if (to != address(0) && value > 0 && !holder[to] && !isCustodian[to]) { holder[to] = true; holderCount++; }
```

---

[75] **11. 9. Zap swaps accept an attacker-supplied pool key after phishing**

`PSPZapIn._buyWithMix` · Confidence: 75 · seen in 3/3 runs · NEW

**Description**
PSPZapIn checks only that one currency is mixETH, so a phished caller trades real mixETH into an attacker pool.

**Fix**

```diff
- require(currency0 == mixETH || currency1 == mixETH, BadPool());
+ require(key.hooks == roundHook && currency0 == psp && currency1 == mixETH && key.fee == 0x80000000 && key.tickSpacing == 60, BadPool());
```

---

[75] **12. Predeposit zap grants mixETH allowance to an attacker-supplied controller**

`PSPZapIn.zapInPredeposit` · Confidence: 75 · seen in 2/3 runs · NEW

**Description**
A phished caller signs the predeposit zap with an attacker controller, so the router approves that controller and the deposit is lost.

**Fix**

```diff
- IERC20(address(mixETH)).forceApprove(address(controller), shares);
- controller.predepositFor(msg.sender, shares);
+ require(controllerRegistry.isRoundController(controller), BadController());
+ IERC20(address(mixETH)).forceApprove(address(controller), shares);
+ controller.predepositFor(msg.sender, shares);
```

---

[75] **13. 10. ZapOut sells through an attacker-supplied pool key after phishing**

`PSPZapOut.sellToMix` · Confidence: 75 · seen in 3/3 runs · NEW

**Description**
PSPZapOut checks only that one currency is mixETH, so a phished caller sells PSP into an attacker pool.

**Fix**

```diff
- require(currency0 == mixETH || currency1 == mixETH, BadPool());
+ require(key.hooks == roundHook && currency0 == psp && currency1 == mixETH && key.fee == 0x80000000 && key.tickSpacing == 60, BadPool());
```

---

[75] **14. 4. Attacker splits PSP dust across wallets and shrinks the next green cap**

`RoundController.constructor` · Confidence: 75 · seen in 3/3 runs · NEW

**Description**
An attacker holds one wei of PSP in many wallets before detonation, so the green denominator grows and every honest holder's cap shrinks.

**Fix**

```diff
- uint256 n = _csvCount; if (address(_prevToken) != address(0)) n += _prevToken.holderCount();
+ uint256 n = _csvCount; if (address(_prevToken) != address(0)) n += _prevToken.eligibleHolderCount(MIN_GREEN_BALANCE);
```

---

[75] **15. 5. Factory carry buys predeposit shares that no code can claim**

`RoundController.seedCarry` · Confidence: 75 · seen in 3/3 runs · NEW

**Description**
seedCarry records the carry as a predeposit of the factory, no code path lets the factory claim, and the share stays locked in the genesis position forever.

**Fix**

```diff
- _recordPreDeposit(msg.sender, actualAmount, false);
+ _recordPreDeposit(carrySink, actualAmount, false); // designated claimable sink, not the factory
```

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [95] | 2. Zero-value transfers inflate the holder count and shrink the next green cap |
| 2 | [90] | 8. Attacker mints chosen pepe ids during the staged-birth window |
| 3 | [90] | 1. Zero-deposit round never launches and blocks every later round |
| 4 | [85] | 6. A router takes the ladder seats of the traders it routes |
| 5 | [80] | A direct pool caller forges the payout identity inside hookData and collects the referral leg |
| 6 | [80] | 7. Sell events name the PoolManager as the seller |
| 7 | [80] | A staker attributes a second wallet to the staker's own NFT and collects 80 percent of each referral fee leg |
| 8 | [75] | 12. A griefer freezes an empty greenlist before the owner sets it |
| 9 | [75] | 11. GraveZap exit moves user PSP to an attacker-supplied hook |
| 10 | [75] | 3. Protocol custodians count as holders and shrink every green cap |
| 11 | [75] | 9. Zap swaps accept an attacker-supplied pool key after phishing |
| 12 | [75] | Predeposit zap grants mixETH allowance to an attacker-supplied controller |
| 13 | [75] | 10. ZapOut sells through an attacker-supplied pool key after phishing |
| 14 | [75] | 4. Attacker splits PSP dust across wallets and shrinks the next green cap |
| 15 | [75] | 5. Factory carry buys predeposit shares that no code can claim |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **CurveHook._claimPotTo** — `Code smells: amount += fullMulDiv(potBalance, _ladderBps(i), denom) floors each seat — sub-wei mixETH per detonation.` · seen in 1/3 runs — NEW
- **CurveHook._splitFee** — `Code smells: paid==0 branch adds the deployer leg on a trade with a live referral chain — wei-scale only; no profitable sequence constructed.` · seen in 1/3 runs — NEW
- **CurveHook.redeemBacking** — `Code smells: fullMulDiv floors to zero for small pspAmount; the >0 guard skips payment but the burn still runs — smallest always-paying amount at production reserves uncomputed.` · seen in 1/3 runs — NEW
- **CurveHook.ticketPrice** — `Code smells: pot priced as 10,000 spots; seat granted at one spot; ladder pays up to 2500 bps; fewer than 10 seats renormalize to 100% — cost basis 1/1000 of pot vs full-pot payout; may be intended winner-take-most game design; designer must confirm intended capture cost.` · seen in 1/3 runs — NEW
- **CurveMath.computeBuyOutput** — `Code smells: eight Newton iterations, three-pass clamp, 32-pass divWad shave, 1-wei plus 1 bps haircut, 128-step bisection — sine-only deployments never execute this path; zone curves retired.` · seen in 1/3 runs — NEW
- **DeploymentSupport._validateZapIn** — `Code smells: AUD-14 probe staticcalls buyWithMixFor and matches the ZeroTrader revert shape, not source identity — the passing router is then wired into DeployReinvestor as the owner-attributing router.` · seen in 1/3 runs — NEW
- **GameRules.SPEC-CONSTANTS** — `Code smells: GameRules.SECONDS_PER_UNIT = 69 matches GATE-LOG and README; AGENTS.md amendment says 4m20s — stale docs vs unambiguous constant; reconcile so deploy expectations match on-chain behavior.` · seen in 1/3 runs — NEW
- **HookMiner.nextCandidateCapped** — `Code smells: mineHook passes (scanFrom, budget) but Yul loops scan [fromIndex, cap); fromIndex >= budget skips both loops — requires a squatted candidate with identical creation code; deploy-time only.` · seen in 1/3 runs — NEW
- **PSPFactory._birthWire** — `Code smells: seeds the factory's whole mixETH balance as carry; twin of the seedCarry finding from the factory side — sources: direct donations and RoundController.sweep; unclaimed backing thickens the reserve for all holders, so stranded-vs-intended needs scoopy's word.` · seen in 1/3 runs — NEW
- **PSPFactory._reserve** — `Code smells: contextHash covers config, descriptors, table, greenlist — not openWindowSec; _birthContracts reads it live — setOpenWindow between reserve and birth makes birthStep fail PredictMismatch instead of ReservationStale; owner-only drift, fails closed, recovery is voidReservation.` · seen in 1/3 runs — NEW
- **PSPGraveZap.exit** — `Code smells: leg 2 claimAllTo pays msg.sender while leg 3 pays the owner; leg 1 keyed to caller — violates the zap's own owner-payout contract; the staker's claimFeesTo already grants operators fee direction, so no new power.` · seen in 1/3 runs — NEW
- **PSPReferralRegistry.payoutFor** — `Code smells: payouts resolve to the CURRENT NFT owner; owner dedupe never compares payee to trader — contract comments state payouts follow current owners, so intent is unclear; transfer-based variant of the self-referral finding.` · seen in 1/3 runs — NEW
- **PSPReinvestor._requireRoundHook** — `Code smells: key.hooks checked against controller; currencies, fee, tick spacing caller-supplied, unlike PSPReferralRegistry's full check — full theft path not built.` · seen in 1/3 runs — NEW
- **PSPReinvestor.reinvest** — `Code smells: `if (left > pspBefore && left > 1e3) revert DustStranded` vs reinvestAll's `left != pspBefore` — no sweep exists; the two variants disagree on tolerance; no third-party growth path found.` · seen in 1/3 runs — NEW
- **PSPStaker._advance** — `Code smells: `p.weight = p.weight + biasAdd[e] - biasSub[e] - p.slope;` — biasSub has writers, biasAdd has none; upward corrections use direct point writes — dead read returns zero today; a future writer skipping checkpoint-first would silently corrupt global weight.` · seen in 1/3 runs — NEW
- **PSPStaker._transfer** — `Code smells: _transfer never settles accruedFees; claimFeesTo pays the whole accrual to an address the current owner or operator chooses — seller-claim-first convention unverified in the frontend.` · seen in 1/3 runs — NEW
- **PSPStaker.addFees** — `Code smells: _distribute returns on zero weight, parking into pendingFeesMixETH; next staker's weight credits the whole parked amount — reachable post-vest pre-detonation; profitability after the 10 percent fee unmeasured.` · seen in 1/3 runs — NEW
- **PSPStaker.claimGenesisShare** — `Code smells: shareFees = mulDiv(accruedFees[0], share, genesisAmount) floors each claim; residuals have no exit once genesis amount reaches zero — sub-wei dust; no payout path found.` · seen in 1/3 runs — NEW
- **PSPStaker.isPepeAvailable** — `Code smells: checks _ownerOf and _artToken but never reservedPepeOwner, while _mint reverts BadPepeId on reserved ids — misleads the art picker only; lockWithPepe reverts for that id; no fund path.` · seen in 1/3 runs — NEW
- **PSPToken._update** — `Code smells: holder map tracks ERC20 transfer endpoints; V4 buys settle PSP at the PoolManager; a user who buys and stakes holds zero PSP at freeze — undercount mirror of the custodian inflation finding; whether V4-claim balances should count is a design question.` · seen in 1/3 runs — NEW
- **RoundController._claimPredepositPSP** — `Code smells: _validateBootstrap runs only when hook.sineConfigured(); zone-round mulDiv floors to zero, ZeroShare reverts, snapshots keep it zero — sine rounds guarded.` · seen in 1/3 runs — NEW
- **RoundController._greenCarry** — `Code smells: _greenCarry returns carry whenever only green deposited; greenPSPSnapshot covers F(green+carry) but divides by green only; comment assigns carry to the open tranche — Whether the ~135% green over-allocation is intended "carry-only round" behavior is a design-intent question; no external victim when carry is donation dust.` · seen in 1/3 runs — NEW
- **RoundController._greenlisted** — `Code smells: one-address tree root is H(leaf,leaf), never the bare leaf; empty proof returns false — on-chain safe by construction; whether the off-chain builder ever emits an empty proof for single-entry trees is unverified.` · seen in 1/3 runs — NEW
- **RoundController.detonate** — `Code smells: gasleft() > 30_000_000 gates spawnNextRound; Base Sepolia caps at about 16.8 million — staged reserve+birth path is the designed fallback; which chains target the composed path is unverified.` · seen in 1/3 runs — NEW
- **RoundController.launchPooledBuy** — `Code smells: greenPSPSnapshot = sineGenesisPSP(greenCurveBoot) with lam(greenBoot), but post-launch trades settle on lam(totalBoot) — Concrete numbers (lam 854.8 vs 1282.5 mixETH) prove the split is not one-curve segmentation; sign and size of the green-vs-open redistribution at default pL remain unmodeled; no solvency effect.` · seen in 1/3 runs — NEW
- **RoundController.predepositFor** — `Code smells: _predepositFor never checks beneficiary against address(0) while every payout path does — the share joins the boot at launch; self-harm surface for caller error, no third-party harm path found.` · seen in 1/3 runs — NEW
- **RoundController.setHook** — `Code smells: no second-call lock; setFactoryRoundId freely re-callable; a wrong id makes detonate revert FactoryMarkFailed — PSPToken.setController shows the one-shot lock these lack; owner-only footgun that can block detonation until corrected.` · seen in 1/3 runs — NEW
- **RoundController.sweep** — `Code smells: onlyOwner with PSPFactory as owner; no factory function calls sweep/setHook/setFactoryRoundId post-birth — donations-only surface; extends the stranded-value family.` · seen in 1/3 runs — NEW
- **SepoliaMixETH.redeemETH** — `Code smells: mint() is public and unlimited; redeemETH pays from the shared balance holding depositors' ETH — unreachable in the Base-mainnet deploy path (canonical mixETH); drains testnet deposits only; fix by removing open mint before any valued testnet use.` · seen in 1/3 runs — NEW
- **SineV3Math.sellOut** — `Code smells: _reserveAtPrimitive reverts when the bracket upper bound already exceeds target — conservative (never overpays) but a valid late-domain sell can fail; first-plateau reserve unverified.` · seen in 1/3 runs — NEW
- **SineV3Price._firstQuarter** — `Code smells: ~120 Bernstein/Taylor/knot constants across four data shards; settlement verified conservative both directions; monotonicity structural; shard codehashes pinned — absolute correctness of the tables unverified; re-run scripts/sine_oracle.py differential against deployed tables.` · seen in 1/3 runs — NEW
- **SineV3Primitive._prepare** — `Code smells: negative-side cells at 1e36, positive at 1e54, trusting shared normalization cancels exactly; Bernstein bytes generator-produced — re-run scripts/sine_oracle.py differential.` · seen in 1/3 runs — NEW

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
