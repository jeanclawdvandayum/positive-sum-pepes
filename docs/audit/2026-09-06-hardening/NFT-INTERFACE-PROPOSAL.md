# Pepe NFT interface change — awaiting user decision

PSPStaker advertises ERC-721 interface 0x80ac58cd, but omits both
safeTransferFrom overloads, approve and getApproved. Its balanceOf(0) also
returns zero where the standard requires rejection. This is observable in
the current source and ABI. The official [ERC-721 specification](https://eips.ethereum.org/EIPS/eip-721)
requires those methods for that advertised interface.

Proposed change: implement the complete ERC-721 transfer/approval surface,
retain the existing NFT IDs and art, and advertise the supported metadata
interface. Safe transfers would check contract recipients via
onERC721Received. Owners could approve an operator for one Pepe as well as
continue using existing approval-for-all. Per-token approvals would clear on
transfer. Staking, fee entitlement and vesting would continue to travel with
the position. Existing transferFrom would remain available.

This changes the public permission and transfer interface, so it is separate
from the authorized security-only fixes. No implementation is included until
the user approves it. A follow-up would need recipient callback/reentrancy,
approval revocation, transfer-state and deployed-size tests. This does not
propose an NFT burn path: the new minted-run index assumes NFTs never burn.
