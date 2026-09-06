# PSP hardening review — 2026-09-06

Baseline: `926e4b46`. Binding scope: `../READINESS.md`. Source-only testnet
hardening; no deployed contracts, frontend deployment configuration, wallet
approvals or transactions were changed.

Six issues were reproduced and corrected. Working severity assessment: five
Medium (payout correctness or availability), one Low (withdrawal view).
No new critical fund-theft finding is claimed. This is a targeted review and
regression packet, not a completed human audit or mainnet approval.

## Confirmed findings

| ID | Severity | Root cause and effect | Correction | Regression |
| --- | --- | --- | --- | --- |
| AUD-16 | Medium | Registry owner deduplication leaves zero entries inside a five-tier referral result. Hook stopped at the first zero, depriving later distinct owners of their cuts on buys and sells. | Skip empty entries while retaining each surviving owner's original tier. Unpaid duplicate weight still goes to pot. | SkillCallbackReview buy/sell pins and five-owner transfer fuzz model |
| AUD-17 | Medium | StakerDeployer's public CREATE2 entry can deploy the exact predicted staker before the controller. Controller construction then attempted the same CREATE2 and reverted, preventing phase one. | Reuse the canonical staker at the address committed by vessel, salt, creation code and all constructor arguments. | SkillLifecycleReview early canonical staker then three successful birth steps on real V4 |
| AUD-18 | Medium | Between PERIPHERY and WIRE, any caller could initialize the reserved canonical V4 pool. Factory's subsequent initialization would fail. | Hook permits canonical pool initialization by its controller's factory only. Public birthStep remains permissionless. | SkillLifecycleReview rejects a non-factory initialization and completes phase three on real V4 |
| AUD-19 | Medium | Fresh NFT allocation scanned every occupied sequential ID. Free chosen-ID hatches could grow work required by every predeposit claim. The reverting claim cannot save scan progress. | Maintain contiguous minted-run boundaries and the first free sequential ID with bounded reads/writes. IDs, selected art, zero-principal hatching and ownership rules are preserved. | 2,048-ID crowded genesis claim fits 300,000 gas; independent occupied-set fuzz; uint256-edge IDs |
| AUD-20 | Low | withdrawableAt treated requestEpoch zero as no request despite the explicit isWithdrawing flag. | Use that flag, consistent with executable withdrawals. | Epoch-zero request returns six days in the fixture and principal exits at that timestamp |
| AUD-21 | Medium | stakedTotalOf enumerated every owned NFT. Strangers can transfer empty Pepes to a referrer and increase the gas required for referral eligibility checks. | Maintain per-owner principal through stake, genesis claims, transfers and withdrawal; preserve the same return value. | Lookup after 1,024 unsolicited NFTs fits 30,000 gas; multi-owner stateful invariant recomputes amounts independently |

The gas tests establish removal of input-dependent scans. They reproduce
failures under explicit per-call budgets, not measured exhaustion of Base
Sepolia's complete block budget. The setup may span many user transactions;
its total gas is deliberately separate from the victim call's gas allowance.

The first four focused cases failed on baseline code, and the epoch-zero and
crowded-genesis cases failed in a separate baseline run. The qualification
case failed before the owner-principal cache was added. All eleven final focused
tests pass, including 256 cases for each of the two new fuzz properties and
a partial-genesis/top-up/transfer/withdrawal owner-accounting sequence.
Final full-gate and static-analysis results are recorded in VALIDATION.md.

## Behavior boundary

No changes to minimum buys, ticket allocation, timer increments/caps, fee
percentages, referral binding, vesting, redemption or the UI were introduced.
The initializer restriction protects the existing factory-only creation flow;
users still complete the same public birth steps. Fresh allocation still picks
the smallest unused sequential ID. The nextTokenId getter now consistently
identifies that free ID, including after chosen-ID mints.

The NFT interface advertises ERC-721 while omitting safe transfers and
individual-NFT approvals. Completing that interface changes the public
permission/transfer surface, so it was submitted to the user separately in
NFT-INTERFACE-PROPOSAL.md. It is not silently bundled into these fixes.

These contracts are not upgradeable. A fresh deployment is required to use
the changes. A legacy factory continues using its original deployers and
creation code. Old NFTs, referral payments and round state are unchanged.

## Review methods and coverage

The installed skills were used together:

- **0xsimao-ai:** money map and ledger-writer inventory; compare principal,
  fee liabilities, historical weight and complete exits. See MONEY-MAP.md.
- **solidity-auditor:** staged initialization, public periphery, callback
  boundaries, beneficiary identity and payout delivery. Local real V4 tests
  verify the deployment and referral findings.
- **property-based-testing:** independent occupied-ID set and first-owner
  referral-tier model; extend the existing multi-owner invariant to recompute
  owner principal from positions, rather than trusting its new cache.
- **differential-review:** reviewed the recent `6401d134` atomic-referral diff,
  its guards/tests/callers, and every production change in this pass. Historical
  blame dates the payout gap to `4eb3fdbea`, fresh-ID scanning to `acb512c09`,
  and constructor CREATE2 dependency to `dcea9a09e`; these predate AUD-15.
- **variant-analysis:** generalized sparse-zero termination, epoch sentinels,
  occupied CREATE2 dependencies and user-grown loops. See VARIANTS.md.
- **token-integration-analyzer:** examined PSP mint/burn ownership, mixETH
  settlement assumptions, transfers/allowances/callbacks and the position NFT
  interface. See TOKEN-INTEGRATION.md and the fresh static inventory.

Focused manual scope: Hook, Staker, Registry, Controller, Factory, deployment
vessels, ZapIn/ZapOut, Reinvestor, PSPToken, SineMath, their immediate interfaces,
the numerical/stateful tests, and frontend transaction/referral preflight.
Legacy configurable zone math was sampled against its existing tests, not
re-audited in full. Art generation, all frontend presentation code, dependencies
and deployed bytecode were not independently audited in this pass.

Three domain subagents supplied initial leads, then their turns were interrupted
by service safety checks. Their reviews did not complete. The primary agent
independently inspected and reproduced the leads, implemented corrections and
performed the follow-up review. This packet does not claim either skill's full
default twelve-agent campaign or independent completed agent sign-offs.

## Change impact and tests

| Changed function/path | Production call sites / reach | Meaningful verification |
| --- | --- | --- |
| Hook._payReferrals | One caller, _splitFee; active buys and sells | Actual balances, pot conservation, owner dedupe across transfers |
| Hook._beforeInitialize | V4 callback; one canonical factory initialization site | Real PoolManager and existing canonical/decoy pool tests |
| StakerDeployer.deployStakerAt | One production call in Controller constructor | Early canonical object, immutable args, completed staged round |
| Staker._mint | Two callers, lockWithPepe and _mintFresh; fresh path serves lock and claimGenesisShare | Unordered chosen IDs, bridges, fresh IDs, top uint boundary, bounded claim gas |
| Staker owner-principal cache | Four mutators: _stake, transferFrom, withdraw, claimGenesisShare | Independent position sums after stateful actions and complete exits |
| Staker.withdrawableAt | Public view; currently not called by rendered frontend logic | Epoch-zero request, maturity, actual exit and post-exit sentinel |

No line/branch coverage percentage is claimed. These tests assert financial
results and liveness properties, rather than merely checking implementation
details. The full deterministic gate includes the existing independent
Decimal/Simpson numerical oracle and real-V4 accounting campaigns.

## Remaining audit focus

The existing human-review items in READINESS.md still apply: custom numerical
domains and asymptotic precision, immediate-stake/JIT economics, majority fee
recapture, transferable referral ancestry, privileged future configuration,
production mixETH behavior, and legacy zone configurations. Large NFT lists can
still cost substantial browser/RPC work even though on-chain allocation and
referral qualification are now bounded. Human review should specifically
confirm the two added staking indexes and their assumptions: all principal
writers update the owner cache, and NFTs never burn. Adding burn in the future
requires redesigning minted-run maintenance.
