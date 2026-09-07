# pepetesters.wei activation preparation — September 7, 2026

Historical preparation record. Activation completed with user approval later September 7, 2026. See LIVE.md and live.json for confirmed addresses, custody and transactions.

## Confirmed configuration

- Name chain: Ethereum mainnet (1).
- Eligibility chain: Base Sepolia (84532).
- Current PSP factory: `0xbbd703ebdab9f0dd4beaa9855d758028f115dacf`.
- WNS: `0x0000000000696760E15f265e828DB644A0c242EB`.
- Parent ID: `6361740363536127648378182158538670061512393038427336338828631921647240523046`.
- Parent: `pepetesters.wei`, epoch 1, expires September 5, 2027.
- Owner/admin: `0x1d52Ad18c074b8125fBCFDFcD01773c6BEdbd88A`.
- Dedicated fee-waiver signer: `0x1016bA06d17774AD34085cdDe38Ec3540C7F34f8`.
- Signer file checked: expected public address and private filesystem permissions.
- Registration fee: zero for qualifying funded PSP NFTs; otherwise 0.0005 ETH. Ethereum gas applies to both paths.

Fresh parent ownership, expiry and WNS code hash are pinned in `parent.json`.
DeployRemoteNames simulation passed against current Ethereum and this factory.
Estimated deployment gas: 3,922,741. Script fee estimate: 0.000349831654626551 ETH, excluding custody/activation and subject to gas-price changes.
Owner wallet balance sampled during preparation: 0.087016129228362159 ETH.
Verifier/server tests: 11 passed.

## Activation sequence

1. Broadcast `script/DeployRemoteNames.s.sol` on Ethereum with the configuration above, using the owner's signer. This deploys PSPRemoteNameGate and PSPNameRegistrar, still paused. No parent transfer is performed by the script.
2. Read confirmed addresses from successful deployment receipts. Verify runtime, admin, gate signer, immutable source factory/chain, parent ID and paused status. Simulation addresses must not be installed as deployed addresses.
3. Fill confirmed registrar/gate addresses into the private verifier environment template prepared at `~/.config/psp/names/pepetesters-current.env.template`. Start the service on 127.0.0.1:8788 and check its configuration.
4. Owner signs WNS `safeTransferFrom(owner, confirmedRegistrar, parentId)` on Ethereum. This transfers the parent NFT to the registrar, with the owner retaining contract admin recovery power.
5. Owner signs registrar `setRegistrationEnabled(true)` on Ethereum.
6. Verify custody, parent epoch, configuration and enabled status. Configure frontend name registrar/chain/RPC and localhost verifier URL. Rebuild and test a commit + registration flow after the 60-second wait.

The admin can pause, rotate the fee-waiver signer, withdraw registration revenue, renew the parent, or call `recoverParent(owner)` to return the parent NFT. Recovery pauses registration. `pepe.wei` remains untouched.

For public testing, run the verifier behind an always-on HTTPS endpoint and configure exact frontend origins. A here.now static upload does not run the verifier process. The local service is sufficient for this Mac's local UI.

Before live activation, confirm authorization for real Ethereum deployment gas and custody transfer. The earlier testnet-only instruction does not itself authorize those mainnet actions.
