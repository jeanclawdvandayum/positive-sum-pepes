# Audit preparation — September 2026

## September 15 — single-sine review blocks release

The `single-sine-spec` review found price and supply decreases at adjacent
reserve values. Three regression tests expose these open defects. The fixed
sixteen-wave prelaunch and sixty-four-wave active limits also lack the
arithmetic justification required by the handoff. The branch is not approved
for deployment. See [the review](2026-09-15-single-sine-review.md).

Local fixes address graveyard-zap ownership, an incomplete sell inverse,
quote limits, reinvestment hook identity, deployment tooling, and chart loading.
The rolling paper and explainers now use the intended v3 formula and exact
pot-based ticket examples. Existing deployments remain unchanged. Test counts
and open failures belong to the latest GATE-LOG entry.

## September 14 — sine rules v3 (source only, branch `single-sine-spec`)

Fresh deployments use ONE continuous tilted-sine curve through the IBCO and
the active market (softened cube-root growth to 1,000x launch price at wave
ten, square-root wavelength scaling), genesis supply from the same cumulative
integral, and pot-priced ladder tickets: `ceil(pot/10,000)` floored at one
wei, with the active gross-buy minimum equal to exactly one current spot.
Interface purchase routes carry opt-in ticket-intent guards. Settlement runs
on a shared read-only `SineV3Math` helper (canonical knot table in code)
pinned to each factory. `MIN_BUY_INPUT()` is dynamic on new rounds. v1/v2
rounds and their exits are unaffected. See
[single-sine-v3](2026-09-14-single-sine-v3.md); the binding rules live in
`docs/FINAL-SPEC.md`. No public deployment is part of this change.

## September 13 — claimable referral rewards (source only)

Fresh registries expose `REFERRAL_REWARDS_VERSION() == 1`. Eligible referral
mixETH accumulates in the per-round registry and is claimed with
`claimReferralRewards()`. Credits belong to the wallet at trade time and
survive NFT transfer, detonation, and successor rounds. The fee split and
referral graph rules stay the same. Existing deployments keep their direct
payout behavior. A fresh deployment is required for this source change.

## September 13 — alternative UI deployment

Factory `0x6126f0a736c4d137bf3b99d0f79807b6faf19f8f` on Base Sepolia uses the
final spec with 600-second predeposit and countdown overrides. The live alt UI
is served locally on port 4180. See [release](2026-09-13-alt-ui.md).


## September 13 final spec — source update, not deployed

Fresh deployments use a three-day uncapped IBCO, a 69:04:20 maximum clock,
69 seconds per ticket and a 28-day withdrawal horizon. Constructor timing
profiles remain available for short playtests. Locked earning PSP is called
lePSP. The six-step withdrawal engine stays the same.

The third-wave reserve target scales with the actual net IBCO backing. The
opening price rises 7.5 times, then reaches approximately 800 times the launch
price at the third wave. Sine rules version 2 uses dimensionless coefficients.
Predeposit rules version 2 uses a zero global cap to mean unlimited.

See [the final spec](../FINAL-SPEC.md) for formulas, examples and compatibility.
Existing deployments retain their deployed rules. Earlier entries below are historical.


## September 11 source update — linear ladder tickets (not deployed)

Each whole ticket adds 69 seconds, subject to the round’s maximum clock.
The active gross-buy minimum remains 0.005 mixETH. Ticket price starts at
0.005 mixETH after genesis and rises linearly by 0.42% of that base per
additional mixETH in the pot. Fractional pot growth counts proportionally.

`ticketPrice = 0.005 ether + floor((potBalance - genesisPotBalance) * 21 / 1_000_000)`

The baseline includes all genesis pot funding. Each buy uses the price before
its own fees enter the pot. Smaller valid buys receive PSP but earn zero tickets
and add zero time. Only the newest ten seats need storage writes. This change
requires a fresh deployment. Existing rounds retain their original rules.


## September 10 deployment — expanded art

Fresh testnet profile: 24-hour predeposit, 1,000 mixETH global cap and
04:20:00 maximum active clock (15,600 seconds). Wallets remain uncapped.

The seven-trait Studio expansion is integrated as art version 2 with separate
immutable bytecode storage. There are 191,664,000 canonical combinations.
Existing deployed art and its renderer are preserved. New deployment scripts
select `PepeExpandedDescriptor`; a fresh factory is required so the staker’s
collision codec matches. Deployed factory:
`0xe4bf7a7450b580fef3a5965e4f3896e736e06dd2`. All 17 deployment
receipts succeeded and both deployed lifecycle fork tests passed. See
[manifest](deployments/base-sepolia-2026-09-10.json) and
[expanded art integration](../art/EXPANDED.md).


## September 9 release preparation

Fresh testnet profile: 24-hour predeposit (86,400 seconds), 1,000 mixETH global
cap, uncapped wallets, and 69:04:20 maximum active clock (248,660 seconds).
Withdrawal vest remains one hour. Deposit-time art reservation version 2 is
included. Factory `0x182307cfd9d1fac0b2e69cb862e993314332d2cb` is deployed on Base Sepolia.
All 17 PSP deployment transactions succeeded, both deployed lifecycle tests
passed, and Sourcify matched all 17 creation/runtime sources. See
[manifest](deployments/base-sepolia-2026-09-09.json).


## September 8 source update — reserved predeposit art (not deployed)

Version 2 adds `predepositWithPepe`: select and reserve the exact art in the
funded deposit transaction. Top-ups keep the choice. Both claim routes honor
it automatically, including after detonation in the Graveyard. Reservations
block both duplicate IDs and canonical rendered trait combinations in other
mints. Version 1 claim-time selection remains a legacy UI path. Existing
deployed addresses are unchanged. See [design and checks](2026-09-08-reserved-predeposit-art.md).

## September 8 deployment update

The active local UI uses factory `0xa3958145ab9a87e01a10ca3f3c404f5898f41a2f` on Base Sepolia.
Predeposit starts at final wiring, verified against the RoundDeployed block.
The deterministic gate passed 514 Solidity tests / 68 suites, 154 frontend
tests and 11 name-verifier tests. Both deployed release lifecycle tests passed
on a local fork; all 17 deployment transactions succeeded and 17/17 sources
matched on Sourcify. See [manifest](deployments/base-sepolia-2026-09-08.json)
and [window correction](2026-09-08-predeposit-window.md).

The existing Ethereum registrar retains pepetesters.wei custody and existing
names. Its new eligibility gate is `0xcb349dced4f6d4f4950a2b51d907e307be9f9fa4`,
configured for the fresh factory. The local verifier was updated and restarted.
Pending name commitments from the previous gate must be reserved again.
Earlier release details below are historical.


This is a review packet for the current source tree, not a security certification.
Final local gates: **513 Solidity tests / 68 suites**, including 64 invariant runs
and 2,048 calls per real-V4 handler with zero reverts; the previous hardening
revision also passed a 256-run / 32,768-call three-wallet campaign and complete exits; **139 frontend tests**, **11 verifier tests**; TypeScript/Vite;
155 ABI declarations; 36 production size checks; independent oracle and governance
gates. Static-analysis flags remain triaged separately. See GATE-LOG.md.
The fresh Base Sepolia release is deployed from **`c724d124`**. The local UI uses
factory **`0xbbd703ebdab9f0dd4beaa9855d758028f115dacf`**, with matching new routers,
faucet, mixETH and reinvestor. All **17 deployment receipts** succeeded; the
manifest verified deployed bytecode, immutable wiring and current feature
versions. Both release lifecycle tests passed on a local fork, and Sourcify
reported **17/17 creation/runtime matches**. See [TESTNET-PLAYTEST.md](TESTNET-PLAYTEST.md),
the [manifest](deployments/base-sepolia-2026-09-07.json) and
[verification record](deployments/base-sepolia-2026-09-07-verification.json).

This release includes atomic purchase referrals, owner-attributed reinvestment,
AUD-16 through AUD-21 hardening, ERC-721 safe transfers and individual approvals,
any-positive predeposits, and round-seeded collision-safe genesis art. The local
UI's history starts at the confirmed factory creation block **46,490,865**.
Earlier deployments and their assets remain at their original addresses. Their
old misattributed events/seats are immutable and remain historical records.
See [REFERRALS.md](REFERRALS.md), the
[hardening review](2026-09-06-hardening/REVIEW.md) and
[NFT interface review](2026-09-06-nft-interface/REVIEW.md) for implementation details.
The [deployment runbook](BASE-SEPOLIA-DEPLOY.md) covers future releases/recovery.

WNS naming now has a registrar, same-chain PSP eligibility gate, parent custody
and recovery controls, plus verified name display and a registration UI. This is
a source implementation and local-fork rehearsal, **not a live hybrid release**.
Both real parent domains remain in the user's wallet. The user approved the
owner-run cross-chain verifier. Its EIP-712 gate, bounded HTTP service, dedicated
permit key and hybrid registration UI are implemented and rehearsed against local
forks of actual WNS and deployed PSP contracts. No additional free-claim caps were
introduced. Mainnet deployment/custody activation remain pending; see the
[remote naming review](2026-09-06-remote-names/REVIEW.md). See [NAMES.md](NAMES.md) and the
[naming integration review](2026-09-06-names/REVIEW.md). Names have their own admin
and fee balance; this work does not add admin powers to the PSP game contracts.

## Binding game rules (September 5 approval, September 6 predeposit amendment)

- Minimum active gross purchase: **0.005 mixETH**. Sell/redemption
  rules remain independent; accrued fees below the threshold cannot compound yet.
- Public predeposits accept **any positive amount**, including one wei, within the
  global and per-wallet caps. Overshoots revert without partial acceptance. Both
  frontend forms show exact cap amounts and use integer MAX calculations. This
  rule is active in the fresh release; legacy rounds retain their deployed minimum.
  See [predeposit review](2026-09-06-predeposit.md) for deployment detection and the
  distinction between a tiny individual deposit and a representable pooled launch.
- Predeposit claims use cosmetic pseudorandom DNA from a block hash captured at
  staker creation, mixed with the chain, staker and wallet. The seed stays fixed
  within the round, and the address remains the preferred NFT ID. Every mint
  reserves a unique canonical v2 trait combination in that round.
  Chosen duplicate art reverts; automatic/genesis mints resolve collisions to the
  first available combination without scanning. Transfers and withdrawals retain
  the reservation. See [block-hash art review](2026-09-06-blockhash-pepes.md). Active in the fresh
  release; earlier deployments retain their existing art.
- Every `floor(gross mixETH / 0.005 mixETH)` purchase unit earns one ladder ticket.
  Only the latest ten remain in storage; absolute ticket numbers include evicted
  units. Fractional remainders do not earn tickets or time. No per-wallet dedup.
- Each unit adds **260 seconds (4:20)** while the clock is alive, subject to the
  immutable round window. A 0.05 mixETH buy takes ten seats and adds at most 43:20.
- Fees are included in the entry budget. Entry stays constant in mixETH, not USD.
- The `TimeAdded` second field now reports **actual seconds added after the cap**;
  its ABI selector is unchanged, so do not decode old deployments as the new rules.
- An eligible referral can bind in the buyer’s signed purchase transaction. The
  wallet’s recorded NFT referral remains fixed for that round, including across
  primary-NFT changes. Fresh registries reset the graph. See [REFERRALS.md](REFERRALS.md)
  for the deployment boundary, optional zero/invalid-link handling and NFT ownership.
- Selling does not remove tickets. Buy/sell/buy cycles deliberately pay fees on
  all three legs. This is an economic design choice, not proof that cycling is
  unprofitable when the trader also owns staking/referral rewards and pot seats.
- If no buy earned a ticket, detonation moves the otherwise unclaimable pot into
  redemption backing. No claimant receives a special payout.
- Redemption uses floor(amount × remaining backing / remaining supply). Rounding
  dust stays with remaining holders; no withdrawal deadline or owner sweep exists.
- Under capped gas, detonation settles the round; reserveSpawn + three birthStep
  calls create its successor. Birth is resumable from chain state.

Before new-exposure wallet writes, the frontend verifies the current deployment’s
minimum and clock constants at one block. Old-round exits instead verify the
selected registry entry, contract target and exit selector; redemption approvals
are restricted to that round’s token and hook. Unclaimed genesis positions and
fee-bearing withdrawn husks remain visible in the graveyard. Incompatible or unreadable deployments are
blocked; matching constants is compatibility checking, not source verification.

## Findings addressed in this work

| ID | Finding / change | Regression evidence |
|---|---|---|
| AUD-1 | PSP-priced eligibility became prohibitively expensive or trivial with curve depth; hook now enforces gross mixETH minimum, tickets and time | ClockDetonation, RealV4Lifecycle, frontend game-rules |
| AUD-2 | Genesis pot could be stranded forever on an empty ladder | RealV4Lifecycle empty-board case |
| AUD-3 | Capped detonation could consume almost all gas on an impossible composed birth | Low-gas detonation + split rebirth on real V4 |
| AUD-4 | UI called a submitted transaction successful before checking its receipt | Shared confirmed-write helper; failure, repricing, cancellation/replacement and timeout tests |
| AUD-5 | UI subtracted sell fees twice, used floating-point minOut, and allowed stale/zero protection | Fresh post-fee quotes; exact integer slippage; nonzero deadline |
| AUD-6 | Sine oracle was stale/broken; inverse rounding could overpay, and quadrature/geometric rounding created inaccurate integrals and downward wave seams | 90 Decimal/Simpson vectors; inverse, roundtrip, wave/cell seam and shallow-trend properties |
| AUD-7 | Legacy bounded Newton shaving could return over-mint after exhausting its iterations | Final bracket fallback, existing B4 deterministic pins/fuzz |
| AUD-8 | Factory donations could exceed launchable sine boot; reservation hash omitted sine settings | Carry bounded by predeposit cap, launch-range validation, context includes sine settings |
| AUD-9 | Reinvestor had phantom position field; strangers could choose another user's trade timing or mix owners in a batch | Correct interface, owner/operator authorization, single-owner duplicate-free batches, reentrancy guard |
| AUD-10 | Hook creation-code oracle exhausted runtime headroom | Immutable STOP-prefixed data shards; byte identity/deployment/size gates |
| AUD-11 | Old-round positions after the first eight were hidden; old pot claims lacked graveyard action | Bounded-concurrency full enumeration, stale read error, pot claim controls |
| AUD-12 | Staker distribution floored the budget debit while retaining fractional credits, allowing repeated allocation of the same dust | Ceiling debit; 20-feed asymmetric-weight pin; stateful reserve + pot + deployer + staker-liability invariant |
| RS-1 | Preserve earning-time fee entitlements through vesting; partial genesis claims retain remaining owners’ fees; payout failures defer credit on the NFT | FeeImmediacy, Vesting, callback guard and multi-owner complete-exit campaign |
| RS-2 | Reject unrepresentable custom sine configurations before deposits; guard derived slope/growth/supply | SineMath rejected-zero-slope pin and accepted-domain fuzz |
| RS-4 | Correct mature cancellation and early-flat withdrawal schedules; bound epoch catch-up; handle epoch-zero requests | FeeImmediacy edge cases; MultiOwnerStateful 32,768 calls |
| RS-5 | Old-round exits verify their own targets; unclaimed genesis and deferred husk fees remain accessible | 3 exit-preflight tests; typed frontend build |
| AUD-13 | Permissionless top-ups paid a victim NFT’s accrued fees to the donor and could erase them on a shortfall | Settle to NFT owner; third-party top-ups revert on shortfall; fee-theft and forced-forfeit pins |
| AUD-15 | Separate referral bind added a wallet transaction; acquiring a primary NFT could override a recorded payout entry | Atomic caller-authenticated registry purchase; immutable wallet entry and NFT ancestry; 22 real-V4 referral tests, 10 frontend referral tests |
| AUD-14 | Reinvestment credited the wrapper with ladder seats, Buy/TimeAdded events and referral lookup, stranding any resulting pot entitlement on the wrapper | Owner forwarded via buyWithMixFor; single/batch owner/operator tests verify events, referrals and owner pot claims; live-round fork; legacy-wrapper UI guard |
| AUD-16 | A duplicate NFT owner left a zero tier that incorrectly truncated later referral payouts | Real-V4 buy/sell pins; randomized five-tier ownership and pot conservation |
| AUD-17 | An early canonical staker deployment blocked the controller's CREATE2 dependency | Idempotent staker deployment; real-V4 staged birth completes with the early object |
| AUD-18 | A stranger could initialize the reserved pool between birth phases and prevent final wiring | Factory-only pool initialization; public birthStep remains permissionless |
| AUD-19 | Chosen NFT IDs made fresh minting and genesis claims scan an unbounded occupied range | Bounded minted-run index; 2,048-ID claim gas check, occupied-set fuzz and uint256 boundary pins |
| AUD-20 | Epoch-zero withdrawal view returned the indefinite-lock sentinel despite an active request | Explicit flag in view; timestamp and actual withdrawal agree |
| AUD-21 | Unsolicited empty NFTs increased on-chain referral qualification cost | Cached owner principal; 1,024-NFT gas test, partial genesis/top-up/transfer/exit pin and stateful position-sum invariant |

The PoolKey object/tuple explanation in the earlier handoff was not reproduced:
installed viem produces identical bytes and the correct uint24 0x800000 flag.
The ABI gate pins this behavior and checks declared functions/events against artifacts.

Latest static detector inventory and manual triage:
[NFT interface static review](2026-09-06-nft-interface/REVIEW.md).
The [earlier September 6 static review](2026-09-06-hardening/STATIC-ANALYSIS.md)
contains the unchanged detector-family triage.
Earlier inventories remain in [STATIC-ANALYSIS.md](STATIC-ANALYSIS.md).
Dependency review: [DEPENDENCIES.md](DEPENDENCIES.md), including the remaining
moderate decoder advisory in the wallet stack. Compounding controls also verify
that the configured wrapper belongs to the current round before operator approval.

## Scope and reproduction

`bash scripts/check-audit.sh` runs non-fork Solidity tests (including a locally
created real Uniswap V4 PoolManager), stateful invariants, the governance grep,
production artifact sizes, independent oracle reproducibility, frontend ABI tests,
transaction tests, TypeScript and Vite. Node 22, Python 3.11+ and pinned solc 0.8.26
are required. See GATE-LOG.md for the actual latest results; no result is implied
by the presence of this script.

Per the user’s direction, current work stays on testnet. No mainnet transactions
were sent; the authenticated mainnet fork check is deferred.

The deterministic gate excludes `test/integration/*`. Mainnet game/mixETH integration tests
remain deferred until a valid MAINNET_RPC_URL is available and that work is
authorized. The separately requested WNS integration passed four tests against a
pinned Ethereum fork using WNS_FORK_RPC_URL; all mutations stayed on the local fork. Separately, `BaseSepoliaReleaseTest` attaches the actual new deployment
on a local Base Sepolia fork and passes two rounds, reinvestment, staged rebirth,
and old-round exits. Real deployment receipts and browser checks are recorded in
GATE-LOG.md; no wallet-signed browser playtest is claimed.

The size gate explicitly excludes `VectorPepeDescriptor`, an existing experimental
renderer with roughly 181 KB of runtime. It cannot be deployed under EIP-170 and
is not referenced by `DeployPSP`. This exclusion is printed by the gate; it is not
an exception for the production descriptor or any game contract.

The numerical implementation now uses four fixed GL8 cells per canonical wave.
A rounded geometric sum defines both endpoints of each wave; partial integrals
are normalized between those endpoints. This prevents boundary drops and keeps
shallow-trend calculation bounded through exponentiation by squaring. Post-boot
inversion maintains a bracket and returns the upper reserve endpoint. The oracle
is independently implemented with Decimal/Simpson integration, with tested
relative tolerances of 1e-11 for price and 1e-9 for cumulative supply. These are
tested parameter ranges, not a proof for every accepted custom configuration.

Fee allocation now debits the ceiling of newly assigned fractional entitlement.
This can leave sub-wei attribution dust in hook surplus; it cannot also remain
in the pending pool and be allocated a second time. The stateful invariant
includes the virtual genesis position's unpaid fees and pending staker fees in
addition to backing, pot and deployer liabilities. The additional MultiOwnerStateful handler tracks every position’s principal,
weight and fee entitlement across three wallets and transfers, then withdraws
all stakes and redeems all supply at each campaign’s end.

## Required human-audit focus

1. Sine cumulative-integral monotonicity, approximation error, inverse bounds,
   boot extremes, asymptotic precision, and gas. The mathematical wave is infinite;
   uint256/WAD arithmetic is not. Oversized/unrepresentable quotes can revert;
   an unsuccessful dust buy does not prove a larger buy cannot reach that region.
2. Staker epoch transitions, immediate stake weight (including JIT fee capture),
   virtual genesis position, fee rounding, operator
   approvals, NFT transfers, and conservation across simultaneous obligations.
3. Hook-data trader identity is an untrusted beneficiary hint, not authentication.
   Referral binding must remain authenticated by the buyer’s own call to the
   registry (atomic purchase or optional direct record); direct routers can assign
   their seats to another beneficiary at their own expense. Review the new
   registry purchase callback, immutable wallet entry and token ancestry rules.
4. Adversarial trading economics: majority stakers recapture fees, referrals recapture
   fees, a buyer can own all ten seats, and transaction ordering determines the last
   buyer. No claim of Sybil resistance or MEV immunity is made.
5. Factory owner powers: descriptor, future curve configuration, HTML and reservation
   cancellation remain privileged. Clock death authority has no governance voting,
   but that does not mean the whole deployment has no admin surface.
6. Reinvestor approval can cover an individual NFT or the whole collection. The
   upgraded UI uses individual approvals; legacy rounds use collection approval.
   Only owners or explicitly approved callers may invoke the wrapper, with every
   batch entry checked. Both approval types permit transfers and fee claims.
   Legacy third-party automation must change;
   the root Keeper.ts now fails immediately with migration instructions; archived
   code also fails closed. The current release has no autonomous yield keeper.
7. Canonical mixETH behavior and backing must be assessed on the actual production
   token. The public-mint test token does not demonstrate external yield or solvency.
8. Legacy zone configurations include retired numerical scenarios. Passing default
   sine tests does not certify all configurable zone shapes; keep them in audit scope
   while their code remains reachable through the factory.
9. Genesis principal splits are independently floored per depositor. Up to N−1
   wei of PSP can remain in the virtual genesis position after N claims, along
   with its tiny share of fees/backing. The deployed two-wallet fork left one
   wei of PSP after all owned positions exited. This bounded rounding residue
   is documented, rather than counted as redeemed user-owned supply.

## Release checklist

- Completed September 7: deploy clean revision `c724d124` from an isolated checkout,
  preserving unrelated working files. Deterministic gates passed, followed by a
  staged live deployment with `--slow`, second-pass reinvestor, source verification
  and deployed-code lifecycle tests. Earlier static-analysis triage remains linked above.
- Completed: capture factory-derived addresses, bytecode hashes and parameters,
  wire the frontend, and check all five routes plus the mobile predeposit view.
- User playtest: browser-test wallet rejection, receipt
  revert, account/chain switch, partial spawn resume, two rounds, claims and redemption.
- Commission human review and resolve findings before any mainnet funds are accepted.

## Deployment manifest

After reviewing and committing a release revision, run the read-only inspector:

```sh
PSP_RPC_URL=... node --experimental-strip-types frontend/scripts/deployment-manifest.mjs FACTORY OUTPUT.json
```

It pins reads to one block and records chain ID, round addresses, code hashes,
sine parameters, source revision, and the approved purchase/clock constants.
Explorer source verification remains a separate required check. Never supply
private keys to this inspector.

## Follow-up numerical configuration domain

Supported custom inputs: p0 1e9–1e18 wei mixETH/PSP, preK 1e12–1e16 WAD,
targetReserve 451–1,000,000 mixETH, pTarget at most 10,000,000 × p0,
ampBps 0–10,000. The existing minimum target/maximum-boot-price ratio still
applies. Materialization rejects zero slope, growth at or below one, and zero
wave/genesis supply. Default parameters are unchanged. Accepted-domain fuzz
covers launch/buy/sell/seams; the 90-vector independent oracle covers its
recorded default-shape domain, not all configurable shapes.

Detailed fee rules: [FEE-ACCOUNTING.md](FEE-ACCOUNTING.md). Economic evidence and
manual test steps: [TESTNET-PLAYTEST.md](TESTNET-PLAYTEST.md).
