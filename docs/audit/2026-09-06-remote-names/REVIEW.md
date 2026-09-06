# Remote naming verifier — September 6, 2026

Baseline `35c53afd`. Implements the user's approval of an owner-run cross-chain
eligibility verifier. The positive-principal rule remains unchanged; there are
no new free-claim caps. See [NAMES.md](../NAMES.md) for the architecture, operational
limits, custody powers and exact deployment preparation.

## Scope and trust

New remote gate, registrar monotonic nonce/version, Node verifier, EIP-712 schema,
frontend permit/chain separation, deployment scripts and operator key creation.
The registrar and parent custody code retain their original security controls.
No PSP game, staking, fee or reserve contract is changed by this revision.

The service's signer grants **fee waivers**, not custody or arbitrary execution.
Its compromise can give unauthorized users free names; repeated free claims
already remain permitted under the user's original rule. Source RPCs and service
operator are trusted. Latest ownership can change during the short permit window;
there is no atomic cross-chain position proof. New stakes/transfers must appear
in finalized state as well as latest state. A service outage blocks free permits.
Paid registration uses the explicit empty-proof path and exact 0.0005 ETH.

## Controls reviewed

- Signature binds both chains, gate, immutable source factory, registrar, account,
  secret name commitment, monotonic nonce, parent/gate/signer epochs, round/NFT,
  finalized source block/hash and issue/expiry. Parent ID and label are bound
  through the commitment. EIP-712 digest/encoding was exercised across viem and
  the actual deployed Solidity gate in the local fork rehearsal.
- Nonce increments on every commit, including identical hashes within one block.
  Successful mint consumes the commitment before WNS callback; callback revert
  restores it atomically. Swapped accounts, chains, gates, signatures and fields,
  consumed/replaced commitments, signer revocation and stale epochs are tested.
- Invalid nonempty proofs revert instead of becoming paid quotes. Exact fee and
  frontend quote review prevent an automatic free-to-paid upgrade.
- Source contract addresses derive only from the configured factory round and
  its controller. Actual ownership and positive principal are checked at both
  finalized and latest source blocks; operators and withdrawn husks fail.
  Source/destination chains, freshness and canonical block hashes are checked.
- A caller can request a permit for another wallet's public commitment, but can
  neither use it nor change its purpose. Only the signed wallet can reveal its
  secret and receive the name. Requests cannot supply RPCs or target contracts.
- Body/header/time/concurrency/rate/bucket limits bound untrusted HTTP work.
  CORS has exact origins, with no credential cookies. Proxy headers are untrusted.
  RPC errors are sanitized; key files must be private, owned, regular files.
  The generated dedicated key is unfunded and lives outside the repository.
- UI source reads are independent of the connected wallet's Ethereum network.
  Game public clients explicitly remain on `CHAIN_ID`; name transactions explicitly
  use the namespace chain. Wallet/account checks run again before simulation and
  submission. The UI requests a fresh permit only for an existing reveal.
- Existing custody recovery, expiry/epoch checks, pause, two-step ownership,
  WNS availability, recipient checks, exact native payments and fee withdrawals
  remain in the full gate and canonical WNS fork tests.

## Static review

Focused Slither 0.11.6 run: **28 contracts, 102 detectors, 13 flags** (8 Medium,
4 Low, 1 Informational). See [inventory](static-inventory.csv). This is the naming
closure, not a fresh whole-game static analysis; the unchanged game findings
remain in the prior review. The initial reuse of normal Foundry artifacts failed
because the build-info output was absent; an isolated `forge build` with
`--build-info --out /tmp/psp-names-static-out --cache-path /tmp/psp-names-static-cache`
followed by Slither `--ignore-compile` succeeded without cleaning game artifacts.

Nine flags are the existing tuple projections, guarded post-mint mapping write,
commit age and owner-only ETH withdrawal discussed in the prior naming review.
Four new flags were checked:

- Ignored commitment creation timestamp: registrar `register` independently
  enforces its age; the gate binds nonce/hash/epoch/config and permit lifetime.
- Ignored ECDSA diagnostic argument: recovery error enum **and** recovered signer
  are checked. The unused argument is only a diagnostic payload.
- Missing zero check on `setSigner`: zero is the intentional free-permit kill
  switch; registration/custody admin remain available. Revocation tests cover it.
- Timestamp comparisons: intentional three-minute permit expiry, with future and
  oversized lifetimes rejected. Timestamp is not used for randomness.

No unresolved exploit was identified in this bounded review. This is not a human
audit, a security certification or a proof of the external WNS/RPC infrastructure.

## Validation

- `bash scripts/check-audit.sh`: **482 Solidity tests / 65 suites**, **98 frontend
  tests**, **11 verifier tests**, **151 ABI declarations**, **35 production size
  checks**, independent Decimal/Simpson oracle, governance gate, TypeScript/Vite.
- Four additional canonical WNS fork tests passed at Ethereum block 25,915,356.
- Full [HTTP + two-fork rehearsal](rehearsal.json): actual existing Base Sepolia
  factory/staker storage from block 46,417,019 and canonical WNS code from Ethereum
  block 25,915,356. Anvil mines fresh local blocks over the fixed source storage;
  its finalized label is simulated, not live L1 finality. A funded NFT qualifies,
  viem-signed permit verifies in Solidity, free/paid mints resolve and display,
  consumed permit rejects replay, fees equal 0.0005 ETH, parent recovers to admin.
  Measured registration gas: free **258,923**, paid **247,073**.
- An initial live-source attempt correctly found no funded NFT for the test
  wallet and returned the paid quote. Rehearsal switched to the funded historical
  source snapshot rather than changing production eligibility or balances.
- Runtime/initcode bytes: registrar **8,588 / 9,527**, remote gate **3,977 / 4,789**.
- Mainnet deployment **simulation only**: 3,922,741 estimated gas, sampled cost
  0.000657854574842721 ETH; no broadcast, key use or domain transfer. Additional
  activation transactions are excluded. See [preparation](deployment-preparation.json).
- Existing Vite dependency annotations and large-bundle warnings remain.
  Browser-injected wallet registration has not been exercised; the transaction
  lifecycle was rehearsed through actual fork transactions and verifier HTTP.

Source SHA-256, sorted `src/**/*.sol` path + NUL + contents:
`77848d96cb74f958c49d803e00a1852557c7b804a28d5d9aeaff4ffc0afe9e42`.

## Release boundary

The verifier key and deployment inputs are prepared. The local frontend still
has no live registrar or verifier URL configured. Ethereum deployment, receipt
verification, service startup, parent safe transfer and explicit activation must
precede that configuration. Both real parent NFTs remain with the user. The
current testnet PSP factory and all balances remain unchanged.
