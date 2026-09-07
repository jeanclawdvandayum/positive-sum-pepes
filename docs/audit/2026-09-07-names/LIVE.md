# Live pepetesters.wei registry

Activated September 7, 2026 on Ethereum mainnet. The Base Sepolia game remains unchanged.

- Registrar: `0xde0f25e61767bc115bf67915469a1e16fd0087aa`
- Eligibility gate: `0xd09deaaa17528748a781024213249d5c89bb6b11`
- Admin of both: `0x1d52Ad18c074b8125fBCFDFcD01773c6BEdbd88A`
- Source PSP factory: `0xbbd703ebdab9f0dd4beaa9855d758028f115dacf`
- Parent: pepetesters.wei. Custody is with registrar; registration enabled.

## Recover the parent to your wallet

As the admin on Ethereum, call registrar:

```solidity
recoverParent(0x1d52Ad18c074b8125fBCFDFcD01773c6BEdbd88A)
```

This pauses registration and safely transfers pepetesters.wei back to your wallet.
A simulation of this exact call succeeded after the live custody transfer. It was not executed, so naming remains enabled. The method is owner-only. The registrar uses Ownable2Step and prevents renouncing admin ownership.

Other admin controls: setRegistrationEnabled(false), renewParent(), setParentText(), setParentAddress(), withdrawFees(to), setEligibilityGate(gate), transferOwnership(newAdmin)/acceptOwnership(). Gate signer rotation uses setSigner(address).

## Local testing

Open http://127.0.0.1:4173/#/stake and choose an alias. Switch your wallet to Ethereum for the two name transactions: reserve, wait 60 seconds, register. A finalized funded PSP NFT qualifies for free registration; Ethereum gas is still charged. Other wallets pay 0.0005 ETH plus gas. Newly staked/transferred NFTs may need source finality first.

The verifier is running on 127.0.0.1:8788, with a separate unfunded signing key. Restart it with:

```sh
bash scripts/names/start-local.sh
```

Its private environment is ~/.config/psp/names/pepetesters-current.env. The source factory and confirmed Ethereum addresses are installed there. Never publish that file or its signer key.

This verifier works for the local UI on this Mac. Other users require an always-on HTTPS service and exact allowed origins. The existing here.now build remains unchanged; do not publish a localhost verifier URL for public testers.

## Validation

All four Ethereum transactions confirmed successfully. Total transaction cost: 0.000127937699004926 ETH. Sourcify v2 confirmed creation/runtime matches for both contracts (verification.json). Deployed runtime bytes match build artifacts outside immutable slots, whose public configuration was independently checked. Confirmed owner, source chain/factory, signer, parent, fee, eligibility gate and activation state. Recovery simulated successfully. Local verifier starts with expected signer and rejects requests without a mature commitment. Local browser shows the enabled alias form. Production build passed. A user-selected name has not yet been minted.
