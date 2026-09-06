# Token integration review

This is source review of the configured design, not proof about an arbitrary
replacement token or the production Alchemix vault.

PSPToken inherits OpenZeppelin ERC20/ERC20Permit. Its immutable factory sets
the controller once; only that controller mints/burns. It introduces no transfer
tax, rebase or transfer callback. Tests reconcile PSP total supply with hook
accounting and locked principal with the staker's balance.

The hook settles in mixETH shares and never uses the vault exchange rate to
calculate backing payouts. Share-value changes are external asset exposure.
An [ERC-4626 vault](https://eips.ethereum.org/EIPS/eip-4626) has separate assets
and shares; that standard alone does not establish yield, solvency, withdrawal
availability or compatibility of this project's custom depositETH/redeemETH
interface. The public-mint test token proves none of those production claims.

SafeERC20 is used for custody transfers and forceApprove for approvals requiring
zero-reset handling. This accommodates missing ERC20 boolean returns, not every
token behavior. Fee-on-transfer, arbitrary rebasing, blocking/pausing recipients,
malicious callbacks and an upgradeable replacement mixETH remain outside the
claimed integration guarantee. Such token changes need a real-token review.
The testnet dapp stays mixETH-only; ETH zap legs are not exposed in its trade UI.

The atomic referral registry commits the buyer, exact purchase data and active
PoolManager before unlock, consumes that commitment before token calls, and
rejects callbacks outside an active purchase. It pulls only the signing caller's
funds. Its real-V4 tests cover standing allowance misuse, invalid keys, a decoy
registry, token reentry and complete rollback on failed purchase. Zap callbacks
authenticate the immutable PoolManager; the real V4 implementation invokes the
unlock caller's callback. They are not certified for a substituted malicious
manager. Reinvestor owner/operator checks, a single-owner duplicate-free batch,
nonReentrant and balance-delta accounting were preserved.

Hook beneficiary hints are not authorization. A direct trader may assign their
own paid-for seats or referral lookup to another beneficiary; that does not let
them bind the beneficiary's referral or spend their allowance. No new victim
theft was confirmed from the mere existence of that hint.

PSPStaker's position interface is an intentionally reduced NFT implementation,
despite advertising the [ERC-721 interface](https://eips.ethereum.org/EIPS/eip-721).
It lacks safeTransferFrom overloads, approve/getApproved and the corresponding
per-token approval event/state. balanceOf(0) returns zero instead of reverting.
It also does not advertise metadata support, despite name/symbol/tokenURI.
Standard wallet/marketplace interoperability is therefore incomplete; existing
transferFrom callers must check that recipients can control the position.
Full interface work is awaiting the user's decision because it adds transfer
callbacks and individual-NFT permission behavior. See NFT-INTERFACE-PROPOSAL.md.

Free transferable empty NFTs exposed two gas-growth paths, corrected by AUD-19
and AUD-21. The owner principal cache is checked against positions after transfers,
stakes, compounding, withdrawal and exits. It does not alter fee eligibility,
principal ownership or the min-stake amount.

The existing wallet-stack dependency advisory in ../DEPENDENCIES.md was not
silently resolved or rescanned as part of these contract changes. Mainnet token
fork checks remain deferred under the user's testnet-only direction.
