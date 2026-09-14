# Lane F — Fee Theft & Referral Escrow
Adversarial audit, deployment-spec pass (branch `testnet-final`, 2026-09-13).

Scope: `CurveHook._splitFee` / `_payReferrals` / `swapFeeBps` / genesis pot fee / `deployerCredit`,
`PSPReferralRegistry` escrow (`creditReferralRewards`, `claimReferralRewards`, `UnbackedRewards`),
`PSPStaker` fee accumulator, `ReferralRegistryInitCode` + `ControllerDeployer` initcode oracle.
No changes to `src/` or `test/` were made by this lane.

Severity scale: High / Medium / Low / Info. PoC sketches required for Medium+ (none found; the two
Low findings include exploit sketches anyway).

---

## Findings

### F-L1 (Low — centralization): `controller.hookAddress()` is owner-rewirable after launch; every hook-gated fee/mint authority follows it
- `RoundController.sol:225-230` (`setHook`, `onlyOwner`, no one-shot guard — only
  `predepositStartTime` is conditionally set), owner = factory (`ownerFactory` ctor arg), factory
  owner = deployer key.
- Everything Lane F relies on authenticates through this mutable pointer:
  - `PSPReferralRegistry.creditReferralRewards` (`PSPReferralRegistry.sol:132-134`, gate
    `msg.sender == ctl.hookAddress()`),
  - `RoundController.addFees` → `PSPStaker.addFees` (`RoundController.sol:279-282`, `onlyHook`),
  - `mintPSPForSwap` / `burnPSPForSwap` (`RoundController.sol:268-274`).
- Sketch: factory owner calls `controller.setHook(attacker)` mid-round → attacker contract is now
  the authorized "hook": it can `creditReferralRewards` itself (limited only by the registry's
  balance check — and it can transfer mixETH to the registry first from anywhere), `addFees` junk
  amounts, and `mintPSPForSwap` unbounded PSP to itself. This is full economic compromise — but it
  requires the factory owner key, i.e. it is a trust assumption, not a permissionless exploit.
  The codebase's "no governance" grep gate (`check-no-governance.sh`) covers vote functions, not
  this pointer.
- Recommendation for the spec: document that the factory owner key is trusted for the round's
  lifetime (or one-shot `setHook` after wiring), and that mainnet `deployerCutTo` + factory owner
  are the same trust domain.

### F-L2 (Low — integration): raw V4 swaps (any aggregator) silently degrade the referral leg to 4% pot / 1% deployer
- `CurveHook.sol:376-379`: only exactly-32-byte `hookData` decodes a `refTrader`; anything else
  trades unattributed. `_splitFee` (`CurveHook.sol:439-452`) then routes
  `deployerCredit += fee·100bps` and the rest of the leg to the pot.
- Not a theft (the split sums to the fee exactly; see invariant below), but any volume routed
  through routers that don't forward the trader address pays the deployer rake that attribution
  would have redirected to the referral chain. On a branch deployment where `deployerCutTo` is the
  throwaway testnet broadcaster (DeployPSP), that 1% accrues to a key that may be discarded.
- Sketch: attacker MEV-searches user swaps through a bare `PoolManager.swap` (stripping hookData)
  — users' referrers lose the 5%-of-fee leg for those trades; deployer/pot gain it. Zero attacker
  profit, pure attribution loss — hence Low/Info, but worth a UI/router note in the deployment
  spec ("trade via PSPZapIn/registry.buyWithMix to keep attribution").

### F-I1 (Info): mixETH donated to the registry is stranded forever; the `UnbackedRewards` check placement is nonetheless sound
- `PSPReferralRegistry.sol:144-147`: the balance check runs after `totalReferralOutstanding += total`.
  A donation raises `balanceOf(registry)` and can make a *hook-less* credit pass — but the only
  authorized creditor is the hook, and the hook **always transfers `paid == Σamounts` before
  crediting** (`CurveHook.sol:423-426`). So a donation buys no additional crediting power; it
  merely sits unclaimable (claims are bounded by `claimableReferral`, `PSPReferralRegistry.sol:152-160`).
  Donor-side grief only.

### F-I2 (Info): ladder-pot floor dust strands in escrow
- `claimPot` (`CurveHook.sol:787-808`): per-seat `floor(pot·bps/denom)`; the ≤ n-wei difference
  between Σ claims and `potBalance` is never payable (no sweep by design — "it waits"). Same for
  `ticketPrice` growth accounting. Economically nil; noted so the spec's invariant table includes
  `potPaid ≤ potBalance` with possible permanent slack.

### F-I3 (Info): `claimDeployerCredit` is permissionlessly triggerable and pays an immutable address
- `CurveHook.sol:812-822`: anyone can trigger the payout to `deployerCutTo`; no deadline, no
  recipient control. Harmless (pull-to-fixed-address). Ops note: on Base Sepolia, `deployerCutTo`
  is the throwaway deployer EOA per DeployPSP — if that key is discarded, unattributed 1% legs
  accrue unclaimed forever (matching the "abandoned value waits" doctrine, but on the rake side).

### F-I4 (Info): operators can redirect staker-fee payouts to any address
- `PSPStaker.claimFeesTo` (`PSPStaker.sol:757-763`) + `_requireAuthorized` (`:898-904`):
  an `approve`d account or `setApprovalForAll` operator claims to arbitrary `to`. Owner-granted
  trust, standard ERC-721 semantics; withdrawal/principal paths remain owner-only. Recorded for
  the threat model.

### F-I5 (Info): legacy nonce-CREATE endpoints remain permissionless on the shared vessel
- `ControllerDeployer.deployController` (`ControllerDeployer.sol:45-85`) and
  `deployRegistry` (`:161-170`) are unauthenticated and consume the vessel's CREATE nonce.
  Nothing nonce-predicts anymore (factory uses only `*At`/`predict*` CREATE2 paths,
  `PSPFactory.sol:367-381, 424-438, 458-460, 467-470`), so spam only inflates the nonce — no
  address shift, no grief on the staged-spawn flow. If a future script ever revives
  nonce-prediction off this vessel, re-audit.

---

## Hunt results (targeted questions)

**1. Fee destination closure.** For every fee-bearing path the split sums to the fee exactly, and
every wei lands in the intended set:
- **Buy (Active)** — `CurveHook.sol:478-479, 521, 528-531`: `F = floor(I·bps/1e4)`; hook takes
  full `I` from PM into custody (`:521`); `reserve += I−F`; `_splitFee`:
  `staker = floor(.6F)` (hook custody, "available", drained only via `sendFees` ← `PSPStaker._settleAndPay`),
  `pot += floor(.35F) + remainder-legs`, referral leg `refLeg = F − staker − pot` transferred to the
  registry (`:424`) and credited (`:425`), unattributed → `deployerCredit += floor(.01F)`,
  `pot += refLeg − deployerLeg`. Since each leg floors down, `refLeg − deployerLeg ≥
  F − (.6F+.35F+.01F) = .04F − {<3 wei}` ⇒ strictly non-negative; **no inversion, no negative
  pot delta, no wei leaks to a sixth destination**. PSP out settles to PM (`:534`) → trader.
- **Sell (Active)** — `CurveHook.sol:576-584, 595-601`: `F = floor(O·bps/1e4)` at the pre-trade
  reserve; reserve debited the **full** `O`; user settles `O−F`; the fee's physical cover is the
  reserve-debit delta itself (balance falls only `O−F`), physically present before `_splitFee`
  routes it. Same legs as buys.
- **Flat sell / redeemBacking** — fee-free by construction (`:629-635`, `:706-722`), so no fee can
  be minted in a dead round.
- **Genesis** — `RoundController.sol:460-481`: `potFee = boot·1000bps` transferred to the hook
  together with the curve boot; `initializeCurve` books `potBalance += potFee`,
  `genesisPotBalance = potBalance` (`CurveHook.sol:865-866`). Hook balance = reserve + pot
  exactly at launch; `sendFees.available` (`:676`) starts at 0. AUD-2 no-buyer fold
  (`:838-841`) moves the whole pot into backing — deterministic, pre-detonation only.
- **Invariant** `balanceOf(hook) = reserve + (pot−potPaid) + (deployerCredit−deployerCreditPaid)
  + stakerAvailable` holds at each step (donations only inflate `stakerAvailable` — a gift to
  stakers, and Solidity 0.8 makes the `available` subtraction revert rather than underflow).
  **Boundary bps**: `swapFeeBps` (`CurveHook.sol:85-94`) is monotone and *continuous* at both
  boundaries — at `r == boot` both branches give 1000; at `r == target` both give 250; the linear
  branch floors the decay term so bps rounds up (reserve-favoring). Buy and sell both read the
  pre-trade reserve, so the boundary cannot be arbitraged between the two.

**2. `creditReferralRewards` caller contexts (guardless by design).** Complete enumeration: the
hook calls it from exactly one site — `_payReferrals` (`CurveHook.sol:425`) ← `_splitFee`
(`:444`) ← `_handleBuy` (`:528`) / `_handleSell` (`:598`) ← `beforeSwap` ← `PM.swap` ← some
`unlock` caller. Three contexts exist: (a) `PSPReferralRegistry.buyWithMix`
(`PSPReferralRegistry.sol:179-207`) with the registry's own `nonReentrant` held — the documented
reason the credit path is hook-authenticated instead of guarded; (b) zap routers; (c) any raw
`PM.unlock` caller with forged hookData. In all three the function performs only additive writes
plus staticcalls (`staker.controller()`, `ctl.getMixETH()`, `balanceOf`) — reentrancy into it is
harmless by construction. Double-credit would require `_payReferrals` to run twice per fee: it
has exactly one call site per trade and amounts are always derived from the live `refLeg`
(≤ refLeg, floored per tier). Credit-unbacked would require the hook to credit without
transferring: the transfer at `:424` precedes and equals `Σamounts`. Crafted `hookData` selects
only a *payout hint* (`refTrader`): a forger can **donate** a trade's referral leg (and ticket
seat) to a victim's recorded chain — attribution itself cannot be created or poisoned (A-1,
binding is `record()`/`buyWithMix()` only). No inflation vector found.

**3. Donation / underflow.** See F-I1: donations strand, they never *enable*. `totalReferralOutstanding`
cannot underflow: `claimReferralRewards` zeroes `claimableReferral[msg.sender]` and decrements the
total **before** its (callback-free) transfer (`PSPReferralRegistry.sol:153-158`), the two
accounting vars are only ever mutated in tandem, and "claim-during-credit" interleaving is
impossible — credit performs no state-changing external call, and the only external call in claim
is a plain ERC20 transfer.

**4. Token-level reentrancy on the Base Sepolia path.** Verified: Base Sepolia deployments
(`PSP_TESTNET=1`, `DeployPSP.s.sol:17,26`) use `src/testnet/SepoliaMixETH.sol` — a plain OZ
`ERC20` (`:23-65`); its only `call` is `redeemETH`'s ETH payout to `msg.sender`, unreachable from
hook/registry/staker paths. Anvil uses `MockMixETH` (also plain). Mainnet mixETH is an Alchemix
vault share — plain ERC-20, no ERC-777 hooks. `claimReferralRewards`' transfer therefore opens no
cross-function window into `creditReferralRewards`; the claim is additionally `nonReentrant` and
the credit is hook-gated anyway. Refuted cleanly.

**5. FeeImmediacy accumulator.** No double-count across epochs and no over-claim vs fed fees:
- Each feed atomically does `delta = floor(pending·1e30/W_live)`, `distributed = ceil(delta·W/1e30)`
  (≤ pending by construction), `pending -= distributed`, one `feeEpochs` checkpoint per epoch
  storing `creditBefore` *before* the increment (`PSPStaker.sol:873-890`). The `feeEpochs` slices
  partition the accumulator domain disjointly (binary search `:502-511`), so a decaying position's
  per-epoch weights (`_earnedFees :523-541`) apply each C-increment exactly once.
- Per-position earning is exact because weight is constant between settles: non-withdrawing
  positions settle-then-mutate (`_stake :622-652` checkpoints via `_settleAndPay`; withdrawers
  epoch-align), and `_feeSlice`'s `mulDiv` floor + `mulmod` remainder carry (`:513-519`, always
  < 2·1e30 ⇒ one bump, remainder stays < 1e30) conserves fractional entitlement without ever
  releasing more than was distributed. `Σ paid ≤ Σ distributed ≤ Σ fees received` holds; the
  accepted JIT-stake front-run of a fee event is documented design (`:29-31`).
- Cross-checked the flat-mode `withdraw` path (`:701-729`): settle precedes weight removal and
  position delete; `accruedFees`/`feeRemainder` survive on the husk NFT as documented.

**6. Initcode oracle.** `predictRegistry` and `deployRegistryAt`
(`ControllerDeployer.sol:172-206`) build the initcode through the *same* shared
`registryInitOracle` instance with identical args ⇒ bit-identical program, same factory
(ControllerDeployer vessel), same salt ⇒ predicted == deployed. This is pinned by
`test/unit/ReferralRegistryInitCode.t.sol:26-43` (including creator-address identity and
permissionless-deployer equivalence). Salt chain: entropy root
`keccak(prevrandao, ts, number, roundId)` (`PSPFactory.sol:363`) → controller salt → controller
address → `keccak(controller, "psp-registry")` (`:377`, `:453`) — the registry salt is public
*after* reserve, but **squatting the predicted address with different code is a 160-bit create2
preimage break**: the vessel's `deployRegistryAt` only ever assembles the canonical
`PSPReferralRegistry` initcode from `(staker, minStake)`, and any other factory/salt/initcode
combination lands elsewhere. The factory's `registry.code.length == 0` skip
(`PSPFactory.sol:457-461`) therefore accepts only the canonical contract ("someone helped") —
consistent with the design note at `:210-214`. The staker salt derivation used at prediction
(`:373-376`) matches the controller's own constructor derivation
(`RoundController.sol:210-215`), and a wiring mismatch would fail closed at the hook's
`PredictMismatch` check (`PSPFactory.sol:467-470`) because the mined hook address commits the
registry constructor arg. No front-run grief specific to `deployRegistryAt` survives; residual
vessel-level spam is F-I5.

---

## Refuted hypotheses (recorded)
- **R1 — fee-boundary arb at `r == boot` / `r == target`**: `swapFeeBps` is continuous and
  monotone at both boundaries; buy/sell both price the fee off the same pre-trade reserve
  snapshot. No discontinuity to harvest.
- **R2 — `_splitFee` dust inversion** (`refLeg < deployerLeg` ⇒ negative pot delta): impossible;
  floors only round legs down, remainder arithmetic keeps every `potBalance +=` term ≥ 0.
- **R3 — donation to registry enables unbacked credit**: refuted (F-I1); crediting is
  hook-monogamous and the hook pre-funds every credit.
- **R4 — `totalReferralOutstanding` underflow via claim/credit interleaving**: refuted;
  effects-before-transfer + callback-free token + staticcall-only credit path.
- **R5 — cross-function reentrancy via ERC-20 callbacks during `claimReferralRewards`**: refuted
  on the actual deployment tokens (SepoliaMixETH / MockMixETH / Alchemix vault share — all plain
  ERC-20; verified `src/testnet/SepoliaMixETH.sol`).
- **R6 — crafted `hookData` steals referral fees or poisons attribution**: refuted; hookData is a
  payout hint only; worst case is donating a leg/seat to the hinted trader's chain.
- **R7 — staker double-claims across epoch boundaries / claims above weight share**: refuted;
  disjoint `feeEpochs` accumulator slices, settle-before-mutate weight discipline, and the
  ceiling-debit remainder rule (AUD-12) bound `Σpaid ≤ Σfed`.
- **R8 — initcode-oracle address mismatch / salt front-run**: refuted (Hunt 6 above); only
  canonical code can occupy the prediction, mismatched wiring fails closed.

## Verdict
Lane F found **no Medium-or-higher fee-theft or escrow-drain vulnerability** in the deployment-spec
state: the 60/35/5-then-1 split is closed under rounding (every fee wei is conserved into
{staker accumulator, pot escrow, deployerCredit, referral registry, trader}), the referral escrow
is credibly backed by construction (hook pre-transfers exactly what it credits, on a plain-ERC20
token with no callback surface on any deployment path), the guardless `creditReferralRewards` is
safe in all three of its caller contexts because it is additive and hook-authenticated, the
FeeImmediacy accumulator's mulDiv/Ceil discipline prevents both double-counting and over-claiming,
and the registry initcode oracle is prediction-exact with malicious squatting reduced to a 160-bit
preimage break and mismatched wiring failing closed. The residual risk concentrates in two Low
trust/integration items — the owner-rewirable `controller.hookAddress()` behind every fee and mint
gate (F-L1) and silent referral-leg degradation to the deployer rake on hookData-stripped router
volume (F-L2) — both spec-documentable rather than code-changing.
