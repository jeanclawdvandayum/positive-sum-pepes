# WNS token integration review — September 6, 2026

Scope: `PSPNameCustody`, `PSPNameRegistrar`, `PSPStakeNameGate`, verified name
resolution and the registration UI. This is a source review and test record,
not a human audit or a claim that the real hybrid deployment is operational.
Implementation, custody powers, network separation and pending decisions are in
[the name integration guide](../NAMES.md).

## Money and custody

The registrar owns only its configured parent WNS NFT and collected registration
ETH. Users own child WNS NFTs immediately. PSP tokens, positions, fees, backing
and pot balances remain in their existing contracts. The gate reads ownership
and principal; it receives no NFT approvals. Name registration cannot withdraw
or transfer a PSP position. Registration fees go to the domain admin, separately
from game accounting. Neither external token prices nor the mixETH exchange
rate participate in registration pricing.

## Specific integration findings and controls

| Risk | Control and evidence |
|---|---|
| Parent approval mistaken for registration permission | Canonical WNS requires actual parent ownership; fork test rejects approval-only registration |
| Public registrant inherits WNS parent's overwrite power | Explicit availability check before mint; occupied-name regression |
| Revealed label sniped through a copied transaction | Wallet/chain/registrar/parent/label/salt-bound commit/reveal; copied-commit pin and domain-separation fuzz |
| Recipient callback reenters or forwards the minted name | NonReentrant, commitment consumed before mint, final owner/resolve checks; malicious receiver and atomic-rollback tests |
| Transferred NFT, empty husk or operator used for free registration | Gate binds actual factory round/controller/staker, checks owner and positive amount; production PSP lifecycle test |
| Eligibility changes after quote/commit | Execution-time recheck; exact ETH fee; frontend requires review when free becomes paid |
| Parent expires, changes custody or is re-registered | Owner/activity/epoch checks; explicit pause/recovery; fork expiry/renewal test |
| Stale commitments survive gate changes | Gate version changes, registration pauses; commitment/gate-epoch regression |
| Renewal silently spends registration revenue | Admin supplies exact fresh ETH; balance-isolation test |
| Spoofed reverse mapping or name follows an old owner | Same-block owner/resolve/direct-parent/namehash verification and address fallback |
| Incomplete position reads charge a qualifying holder | Full-round bounded-concurrency search; errors block submission, never default to paid |
| Reload loses the private commitment salt | Persist before commit; malformed storage rejected; success remains successful if cleanup fails |
| UI reports success on broadcast rather than receipt | Shared confirmed transaction helper, with existing revert/replacement/cancellation tests |
| Wrong network or unexpected gate charges users | Same-block registrar constants/custody/gate-factory validation; cross-chain writer disabled |

## ERC-721 and external-token checklist

- Receiver accepts only canonical WNS, the configured parent, from the current
  administrator, and verifies actual custody. Unexpected NFTs/callbacks revert.
- WNS safe mint checks receivers; rejection/forwarding/reentry is covered. The
  registrar never represents itself as an ERC-721 collection.
- WNS identifiers are namehashes and can be re-registered: parent and child epochs
  invalidate old records. Active-transfer checks also block recovery during grace
  until renewal. These are material deviations from a timeless ERC-721 identity.
- A child may transfer and independently redirect its forward address. Neither
  ownership alone nor an unverified reverse string is enough for wallet display.
- WNS resolver metadata is untrusted. ASCII registration/display rules, React text
  rendering and length constraints cover markup, bidi and confusable inputs.
- Composition is non-upgradeable PSP custody/registrar plus immutable canonical WNS
  address. Ownable2Step controls custody, parent records, fee withdrawals and gate
  replacement; renounce is disabled. Gate replacement is an explicit trust power.
- No arbitrary low-level execution, ERC-20 allowance, mixed currency settlement or
  game-controller access exists in this module. Only fee withdrawal uses a native
  ETH call, guarded with checked success and reentrancy protection.

The ERC-20 weird-token families are outside the accepted-asset surface here:
missing/false return values; transfer fees; rebasing; ERC-777 callbacks; upgrades;
flash minting; blocklists; pausing; approval races; zero-value/zero-address token
restrictions; low/high decimals; self-transfer allowance differences; non-string
metadata; injected metadata; nonstandard permits; high-approval restrictions;
partial transfers; native-token sentinel addresses; mint/burn hooks; reflection;
and balance-dependent transfers. None is assumed safe for PSP's separate mixETH
integration. Names take native ETH and only read PSP NFT principal. On the naming
surface, analogous callback, expiry, metadata, custody and native-transfer risks
are covered above. Scarcity/exchange-listing/ERC-20 supply checks are not applicable
to this namespace registrar; public name allocation is not Sybil-resistant.

## Static analysis

Slither 0.11.6: 104 contracts / 102 detectors / 252 reported entries. Nine entries
touch the new naming contracts; see [inventory](static-inventory.csv):

- Six medium `unused-return` entries are deliberate tuple projections. Ignored
  fields are labels/timing/round metadata unrelated to each operation; parent
  activity and current epoch are checked through the canonical interfaces.
- One low `reentrancy-benign` entry reports the primary-name write after safe mint.
  The operation is guarded, consumes the commitment first and checks final NFT
  ownership/resolution before recording identity. The adversarial receiver tests
  cover attempted reentry and mint-time transfer.
- One low timestamp entry is the intentional commit age window. This is not a
  randomness source. Ordering and block-proposer censorship remain possible.
- One informational low-level-call entry is the owner-only native ETH withdrawal,
  with nonzero recipient, nonReentrant and checked success.

No new unresolved exploit was identified in this bounded review. That does not
certify the WNS dependency, future permit verifier, or unrestricted name economics.

## Verification and limits

The deterministic gate covers unit tests, fee/domain-separation fuzz, the actual
PSP position lifecycle, frontend failure/identity/preflight tests, ABIs, bytecode
sizes and the existing complete game suite. See the latest GATE-LOG entry for
final counts. Four additional tests passed against canonical WNS at Ethereum block
25,915,356 and pinned runtime hash, including free/paid registration and recovery.
The first public provider later denied archive requests; the pinned run completed
using `https://eth.drpc.org`. Earlier RPC failures are not counted as passes.

The local app shows the new card with registration correctly disabled for its
unconfigured cross-chain deployment. A temporary transaction-disabled visual
fixture verified long names in the account button, tape and ladder, plus the
registration form at desktop width and 390px phone width. At 390px the content
width was exactly 390px and the account button was 174px; no horizontal overflow.
The fixture was removed, its server stopped and the viewport reset. This was not
an injected-wallet transaction playtest. All Ethereum mutations occurred on a
local fork; real parent custody is unchanged.

Live deployment still requires the user's cross-chain and free-claim policy
choices, implementation/review of the chosen eligibility adapter, and a concrete
registrar deployment/custody handoff. A registrar replacement preserves WNS child
NFTs but needs a display-mapping migration or user `selectPrimaryName` calls.
