# Pepe NFT interface change — approved and implemented

At the initial review, PSPStaker advertised ERC-721 interface 0x80ac58cd,
but omitted both safeTransferFrom overloads, approve and getApproved. Its
balanceOf(0) returned zero where the standard requires rejection. These were
confirmed in that source revision and ABI. The official [ERC-721 specification](https://eips.ethereum.org/EIPS/eip-721)
requires those methods for that advertised interface.

Proposed change: implement the complete ERC-721 transfer/approval surface,
retain the existing NFT IDs and art, and advertise the supported metadata
interface. Safe transfers would check contract recipients via
onERC721Received. Owners could approve an operator for one Pepe as well as
continue using existing approval-for-all. Per-token approvals would clear on
transfer. Staking, fee entitlement and vesting would continue to travel with
the position. Existing transferFrom would remain available.

The user approved this interface change on September 6. It is implemented with
recipient callback/reentrancy, revocation, transfer-state and deployed-size checks.
See the [implementation and validation](../2026-09-06-nft-interface/REVIEW.md).
Existing deployments remain unchanged until redeployment. There is no NFT burn
path: the minted-run index continues to assume NFTs never burn.
