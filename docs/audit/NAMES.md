# PSP names — WNS integration

Status: **pepetesters.wei is live on Ethereum, with Base Sepolia eligibility** (September 7, 2026).

Registrar: `0xde0f25e61767bc115bf67915469a1e16fd0087aa`. Gate:
`0xd09deaaa17528748a781024213249d5c89bb6b11`. Both are administered by
`0x1d52Ad18c074b8125fBCFDFcD01773c6BEdbd88A`. Parent custody was transferred
and registration enabled with explicit user approval. `pepe.wei` is unchanged.
The local UI and loopback verifier are configured for current factory
`0xbbd703ebdab9f0dd4beaa9855d758028f115dacf`. See the
[live receipts and checks](2026-09-07-names/live.json) and
[admin instructions](2026-09-07-names/LIVE.md).

Historical rehearsal details below describe the earlier preparation, not current activation status.

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
checked at execution by the local gate, or authorized by a fresh signed source
snapshot in the remote gate. The remote trust window is described below.

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

## Approved hybrid integration

The user approved an owner-run verifier for Base Sepolia eligibility and Ethereum
name registration. The original positive-principal rule remains: **no added
per-wallet or per-NFT free-claim limit**. One wei of PSP principal qualifies;
a funded NFT can support repeated names and can qualify a new wallet after a
transfer settles. This allocation is intentionally not Sybil-resistant.

Both parent domains are Ethereum mainnet NFTs in canonical NameNFT
`0x0000000000696760E15f265e828DB644A0c242EB`. The pinned parent manifests record
owner `0x1d52Ad18c074b8125fBCFDFcD01773c6BEdbd88A` at block 25,915,356:
[test parent](2026-09-06-names/pepetesters-mainnet.json),
[production parent](2026-09-06-names/pepe-mainnet.json). The actual owner is rechecked
before deployment and activation. `pepetesters.wei` is the test namespace;
`pepe.wei` remains the production namespace.

`PSPRemoteNameGate` checks EIP-712 fee-waiver permits. Its immutable source chain
and factory are included in the signed message; the domain binds destination
chain and gate. Every permit additionally binds registrar, wallet, chosen-name
commitment, monotonic commitment nonce, parent epoch, gate version, signer epoch,
round, NFT, source finalized block/hash, issue time and expiry. The commitment
already binds parent ID, label and salt. Maximum validity is **180 seconds**.
Replacing even an identical commitment in the same block increments its nonce;
consuming it or rotating signer/gate invalidates the old permit. Invalid nonempty
proofs revert; only an explicit empty proof selects the paid path.

The signer is a dedicated, unfunded key. It can authorize free registration fees;
it cannot transfer the parent, mint outside the registrar, bypass commitment age
or occupied-name checks, select someone else's name, or move PSP assets. The gate
admin can rotate/revoke the signer through `setSigner(address)`. Zero disables
free permits; each rotation increments `signerEpoch`, including rotating back to
an earlier key. Ownable2Step preserves recovery control.

The verifier checks a recognized factory round's staker and actual owner/positive
principal at **both finalized and latest source blocks**. It checks those block
hashes again, validates destination custody/configuration and the wallet's mature
commitment, signs, then calls the actual registrar's price verifier before
returning proof bytes. Source/destination latest timestamps may be at most 60
seconds old or 15 seconds ahead of the service clock; source finalized state may
be at most one hour old. RPC failure, stale state, changed ownership, empty
principal, wrong network or wrong signer prevents a free permit.

Finalized state follows L1 finality and batch inclusion, so a new stake or transfer
can take several minutes to qualify. See Base's [derivation and finality spec](https://docs.base.org/base-chain/specs/protocol/consensus/derivation)
and [block-tag API](https://docs.base.org/base-chain/api-reference/ethereum-json-rpc-api/eth_getBlockByNumber).
This is a trusted service, not a cryptographic bridge: ownership can change after
issuance, a compromised signer/RPC can grant unauthorized fee waivers, and service
outages delay free registration. The 180-second permit window bounds honest
post-observation staleness; it does not make cross-chain ownership atomic.
A public/malicious registrar outside the configured deployment cannot obtain
permits from this service. The contract verifies signed permit context rather
than independently proving the source block.

The browser keeps game reads/writes pinned to the game network while enabling
Ethereum in the wallet for names. A latest source scan quotes the fee; a funded
NFT hint is exchanged for a permit only during reveal. The UI verifies that permit
on Ethereum before simulation/submission and requires review if the fee changes.
It never silently converts a failed free permit into a paid transaction. A stale
source RPC also blocks the quote. No extra wallet authentication signature is
needed: the wallet's on-chain commitment already binds the permit's purpose.
Two name transactions remain: commit, then register after 60 seconds. Gas is paid
on Ethereum, including for free registration. Permits that expire while a wallet
prompt is open must be refreshed by retrying; no fee is auto-upgraded.

`PSPStakeNameGate` remains available for same-chain deployments/local testing.
`PSPNameRegistrar.REGISTRAR_VERSION` is now 2 to expose the monotonic nonce.
No old registrar was deployed; existing PSP contracts remain untouched.

## Verifier operation

Run on Node 22.18+ with the existing root dependencies. Configuration template:
[scripts/names/example.env](../../scripts/names/example.env). Start from the repo
root with environment variables loaded into the service account:

```sh
node --experimental-strip-types scripts/names/server.mjs
```

`PSP_NAME_SIGNER_FILE` must be a regular, non-symlink file owned by that account,
with no group/other permissions (`chmod 600`). Generate a dedicated key using
`scripts/names/create-signer.mjs /absolute/private/path/outside/repo.key`; creation
is exclusive and prints only the public address. Never use a deployer key or a
`VITE_` variable. This preparation generated an unfunded signer at
`~/.config/psp/names/pepetesters-permit.key`, public address
`0x1016bA06d17774AD34085cdDe38Ec3540C7F34f8`. Its key stays outside the repository.

The server binds **127.0.0.1:8788**. For a remote UI, put an HTTPS reverse proxy
in front and configure exact allowed origins in `PSP_NAME_ORIGINS`; for this local
UI use `http://127.0.0.1:4173` and verifier URL `http://127.0.0.1:8788`.
`POST /permit` accepts only `{account, roundId, pepeId}`; requesters cannot choose
RPC URLs, source contracts, signer, registrar or destination chain. No free-claim
counter is introduced. Repeated permit requests for the same commitment are safe.

The endpoint limits JSON bodies to 2 KiB, headers to 8 KiB, body reads to five
seconds, work to 20 seconds, concurrent verification to four jobs, and each peer
IP to ten requests/minute. Rate buckets are bounded at 4,096 entries. It does not
trust `X-Forwarded-For`; an HTTPS proxy should enforce its own per-client limits,
otherwise all proxied clients share one service bucket. CORS is a browser boundary,
not caller authentication; non-browser callers can spoof Origin but cannot use
another wallet's permit. Only confirmed wallet commitments authorize issuance.
Responses disable caching and sanitize RPC errors; logs never include keys,
signatures, request bodies or credential-bearing provider URLs.

Monitor service process health, signer mismatch, source/destination RPC freshness,
parent expiry and pending admin rotations. No monitoring job was automatically
scheduled by this implementation. Rotate the on-chain signer first to invalidate
old permits, update the private service key/config, then restart it. To temporarily
stop all naming, pause the registrar; to stop only free permits, set gate signer
to zero. The configured factory is fixed per gate; a new PSP factory needs a new
gate and the registrar's explicit, pausing gate replacement.

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

The four WNS fork tests pin block 25,915,356 and its runtime hash. The full HTTP
rehearsal additionally exercises the actual remote gate and existing deployed PSP
contracts from a Base Sepolia snapshot. Start two fresh, loopback-only Anvil forks:

```sh
anvil --host 127.0.0.1 --port 8548 --chain-id 31337 --fork-url https://eth.drpc.org --fork-block-number 25915356
anvil --host 127.0.0.1 --port 8549 --chain-id 84532 --fork-url https://sepolia.base.org --fork-block-number 46417019
NAMES_REHEARSAL_SOURCE_RPC=http://127.0.0.1:8549 node --experimental-strip-types scripts/names/rehearse.mjs
```

The rehearsal checks Anvil identity/loopback/chain before every mutation client,
impersonates only on the local destination, and mines local source blocks over
real PSP storage to exercise fresh/finalized reads. Its finality labels are local
Anvil semantics, not an assertion that new live transactions finalized. Both free
and 0.0005-ETH registrations, actual WNS ownership/resolution, app display,
consumed-permit rejection and parent recovery passed. A live read first confirmed
that the test wallet currently has no positive-principal position; that correctly
quoted paid registration. The older source snapshot contains funded NFT #1.

`script/DeployNames.s.sol` is the 31337-only **same-chain** alternative.
`script/DeployRemoteNames.s.sol` deploys the remote gate and registrar on Ethereum
or its local fork. It verifies canonical WNS runtime, current parent ownership,
dedicated signer, and supported source chain; Base Sepolia qualification can only
be configured for `pepetesters.wei`. It never transfers the parent or activates
registration. Set `PSP_NAME_ADMIN`, `PSP_NAME_SIGNER`, `PSP_NAME_FACTORY`,
`PSP_NAME_SOURCE_CHAIN_ID` and optionally `PSP_NAME_PARENT_ID`.

A mainnet **simulation only** passed with the prepared signer and current Base
Sepolia factory: estimated deployment gas 3,922,741 at the sampled gas price
(0.000657854574842721 ETH). That estimate excludes custody transfer/activation
and changes with gas prices. The reviewable parameters and status are in
[remote deployment preparation](2026-09-06-remote-names/deployment-preparation.json).
Predicted simulation addresses are not installed in the UI; confirmed receipts
must supply the live addresses.

Live activation remains a separate consequential step: deploy the two Ethereum
contracts, verify their runtime/admin/source/signer/parent, configure/start the
verifier, safe-transfer **pepetesters.wei** to the confirmed registrar, then call
`setRegistrationEnabled(true)` as admin. Recheck owner/resolve/epoch before
publishing `VITE_NAME_REGISTRAR`, `VITE_NAME_CHAIN_ID=1`,
`VITE_NAME_PARENT_LABEL=pepetesters`, `VITE_NAME_RPC_URL` and
`VITE_NAME_VERIFIER_URL`. Public verifier hosting needs HTTPS; the local playtest
can use the loopback service. Real Ethereum gas is required. Neither real parent
was moved, no Ethereum transaction was broadcast, and the current UI remains
unconfigured for live registration pending that custody/deployment step.

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
