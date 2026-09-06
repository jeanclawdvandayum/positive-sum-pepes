# PSP names — WNS integration

Status: **source implementation and local-fork rehearsal; real-domain deployment pending**.
Neither `pepe.wei` nor `pepetesters.wei` has been transferred, and no mainnet
transaction has been signed or broadcast by this work. The existing PSP game
contracts and balances are unchanged. Live name registration remains disabled.

## Registration and display

`PSPNameRegistrar` holds one parent WNS NFT. A wallet owning a PSP NFT with positive
principal in any recognized factory round qualifies for free registration.
An empty NFT or an operator approval does not qualify. A withdrawing position
qualifies while it still contains PSP. Everyone else pays exactly **0.0005 native
ETH** to the name registrar. Network gas is separate, including for free names.
Registration revenue is withdrawable by the domain admin; it does not enter the
PSP pot or staking accumulator.

A user chooses a 1–32 character lowercase ASCII label (letters, numbers, internal
hyphens). The UI commits a salted hash, waits 60 seconds, then reveals and mints
the WNS child to that wallet. Commitments expire after 24 hours; the secret is
saved locally before the first transaction so a reload can resume it. A commit
hides the label but does not reserve availability. Both transactions are simulated
and receipt-checked, including cancellation/replacement handling. Eligibility is
checked again at the registration transaction's execution.

The latest registered or selected name becomes the wallet's PSP display name.
`selectPrimaryName(id)` selects an existing owned child; zero clears the app
mapping. This is separate from WNS's global `primaryName`: WNS provides no
`setPrimaryNameFor`, so automatically changing a user's global reverse record
is impossible for a registrar. PSP's mapping removes that extra transaction from
the normal registration flow.

The header account button, trade tape and ladder resolve the app mapping first,
then WNS's global mapping when the app mapping is empty. Every displayed name
is checked against WNS's current owner, forward resolution, direct parent and
namehash at one block. Expired, transferred, redirected, malformed and Unicode
confusable names fall back to the wallet address. React renders names as text;
long names truncate inside their existing layout. Addresses remain in tooltips
and transaction recipients never derive from display names. Queries deduplicate
wallets across all three components, refresh every minute, and fail independently
of the PSP RPC. Registration invalidates display queries immediately.

A name remains with its WNS wallet owner across PSP rounds and PSP position
transfers. Transferring the WNS NFT moves the name separately. WNS parent renewal
is required for child resolution; parent expiry/re-registration can invalidate
all descendants. These are WNS's own semantics, not guarantees supplied by PSP.

## Network boundary and pending decisions

Both parent domains are **Ethereum mainnet** NFTs in canonical NameNFT
`0x0000000000696760E15f265e828DB644A0c242EB`, owned at the pinned inspection block by
`0x1d52Ad18c074b8125fBCFDFcD01773c6BEdbd88A`.
See [test parent inspection](2026-09-06-names/pepetesters-mainnet.json) and
[production parent inspection](2026-09-06-names/pepe-mainnet.json).
`pepetesters.wei` expires September 5, 2027; `pepe.wei` expires September 1, 2027.
These observations are pinned to block 25,915,356, not a current custody guarantee.

PSP currently runs on **Base Sepolia** and its planned Base production network is
also separate from Ethereum. `PSPStakeNameGate` reads an actual local factory,
controller and staker. It deliberately supports **same-chain eligibility only**.
Copying a Base factory address into Ethereum config cannot make that work.
The frontend verifies the gate's factory and keeps writes disabled when game
and naming chains differ. Name display reads can still use Ethereum independently.

Two questions were sent to the user and remain pending:

1. For real hybrid testing, approve an owner-run verifier that reads funded PSP
   positions on Base Sepolia and issues short-lived, signed eligibility permits,
   while users register names and pay gas on Ethereum; alternatively keep tests
   entirely on a local fork. **No verifier, trusted permit path or real mainnet
   deployment has been activated.**
2. Decide whether to add one-name-per-wallet / one-free-claim-per-NFT limits.
   The rehearsal implements the original positive-principal eligibility rule,
   without extra claim limits. A funded NFT can currently qualify its owner for
   multiple names and can be transferred to qualify another wallet. One wei of
   principal qualifies. This is not a Sybil-resistant allocation policy.

A hybrid permit adapter requires a separate review before it replaces the local
gate: bind the recipient, label/commitment, source chain/factory/round/staker/NFT,
source finalized observation, destination chain/registrar, expiry, nonce and
signer/configuration epoch. Define eligibility at the observation block, consider
transfers after observation, enforce any approved NFT claim limits, authenticate
requests and rate-limit the service. Signer compromise would grant unauthorized
free names; it must not confer parent custody or access to PSP funds. Rotating
`eligibilityGate` is an admin power, so an admin can already change qualification.

## Domain custody and administrator functions

The canonical WNS contract requires the **parent owner** to create children.
ERC-721 approval alone is insufficient. `PSPNameCustody` accepts only its configured
parent through a safe transfer from its current admin and leaves registration
paused until explicitly enabled. The admin uses Ownable2Step, including a multisig
if desired. Renouncing ownership is disabled to preserve recovery.

| Function | Purpose |
|---|---|
| WNS `safeTransferFrom(admin, registrar, parentId)` | Give the registrar custody; use the exact deployed registrar address |
| `setRegistrationEnabled(bool)` | Activate or pause public registration; activation validates custody, activity and parent epoch |
| `recoverParent(to)` | Pause and safely return the parent NFT to the chosen address |
| `renewParent()` payable | Forward the current exact WNS renewal fee supplied by the admin |
| `setParentAddress(account)` | Change the parent ETH resolution record |
| `setParentCoinAddress(coinType, account)` | Change another address record |
| `setParentText(key, value)` | Manage parent text records |
| `setParentContenthash(value)` | Manage the parent content pointer |
| `setEligibilityGate(gate)` | Repair/replace qualification; pauses registration and invalidates pending commitments |
| `withdrawFees(to)` | Withdraw registration ETH and incidental ETH |
| `transferOwnership(newAdmin)` / `acceptOwnership()` | Rotate admin in two steps |

Recovery retains the underlying WNS power to reclaim/reassign child labels.
To repair a child, recover the parent, call WNS `registerSubdomainFor` as parent
owner, then return custody and re-enable registration. This power is disclosed in
the registration card. The public registrar's availability check blocks ordinary
registrants from using that same WNS overwrite capability. Recovery does not
transfer existing child NFTs by itself.

During WNS's expiry grace period, safe transfer of the parent fails until renewal.
`renewParent` supplies fresh admin ETH, using `getFee(bytes(parentLabel).length)`;
it never consumes registration revenue implicitly. Renewal remains available
directly through WNS as well. Parent expiry beyond grace may permit another owner
to register it; contract admin functions cannot override WNS ownership rules.

## Reproduce and deploy the rehearsal

Read-only custody inspection:

```sh
node --experimental-strip-types frontend/scripts/inspect-wei-domain.mjs pepetesters
```

Deterministic unit, integration-with-local-PSP, frontend, ABI and size gates:

```sh
bash scripts/check-audit.sh
```

Canonical Ethereum WNS fork test (local mutations only):

```sh
WNS_FORK_RPC_URL=https://eth.drpc.org forge test --match-contract WeiNamesForkTest -vv
```

The fork pins block 25,915,356 and the WNS runtime code hash. A public RPC may require
an archive-capable replacement. Free/paid minting uses a test-only eligibility
stub on this fork; the separate `NameStakeGateTest` exercises actual PSP factory,
principal, operator, NFT transfer and withdrawal behavior. Together they validate
the interfaces, not a cross-chain proof system.

`script/DeployNames.s.sol` prepares a **31337-only** deployment against canonical
WNS code on a local Ethereum fork and an actual PSP factory deployed on that same
fork. Set `PSP_NAME_ADMIN`, `PSP_NAME_FACTORY` and optionally `PSP_NAME_PARENT_ID`.
It leaves the parent with the admin and registration paused. Mainnet deployment
is intentionally excluded until the hybrid model is settled and reviewed.

For that local deployment, point both game and name RPC at the same local fork,
set `VITE_CHAIN_ID=31337`, `VITE_NAME_CHAIN_ID=31337`,
`VITE_NAME_PARENT_LABEL=pepetesters`, and set `VITE_NAME_REGISTRAR` from the confirmed
receipt. Rebuild the frontend. The configured game factory must match the gate.
Do not use the existing Base Sepolia factory address as a local Ethereum factory.

## Resources reviewed

- [WNS source and integrations](https://github.com/src-company/wei-names), commit
  `8eb07215182bacbfa5ca624f9a147998b57ba90e`: NameNFT, SubdomainRegistrar and dapp.
- [wei.domains](https://wei.domains/#pepetesters): deployed network and namespace.
- [@1001-digital/ethereum-names](https://www.npmjs.com/package/@1001-digital/ethereum-names)
  0.6.0: useful viem-compatible resolution, but it does not implement PSP
  qualification or our automatic app mapping.
- [wns-utils](https://www.npmjs.com/package/wns-utils) 0.2.1: useful reference ABI;
  its depth/default-fee constants differ from the current WNS repository, so they
  are not used as live policy. Its Base portal is an ETH bridge, not WNS on Base.

The implementation uses the existing viem dependency and a reviewed minimal WNS
ABI rather than installing both overlapping SDKs. The ABI is included in the gate.
The source API review plus pinned deployed-code fork test is not a claim that WNS
was independently audited or its bytecode reproduced from source.
