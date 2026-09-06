// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title IWeiNames
/// @notice WNS surface verified against src-company/wei-names (8eb0721).
interface IWeiNames is IERC721 {
    function records(uint256 id) external view returns (string memory label, uint256 parent,
        uint64 expiresAt, uint64 epoch, uint64 parentEpoch);
    function registerSubdomainFor(string calldata label, uint256 parentId, address to) external returns (uint256);
    function isAvailable(string calldata label, uint256 parentId) external view returns (bool);
    function resolve(uint256 id) external view returns (address);
    function getFullName(uint256 id) external view returns (string memory);
    function primaryName(address account) external view returns (uint256);
    function getFee(uint256 length) external view returns (uint256);
    function renew(uint256 id) external payable;
    function setAddr(uint256 id, address account) external;
    function setAddrForCoin(uint256 id, uint256 coinType, bytes calldata account) external;
    function setText(uint256 id, string calldata key, string calldata value) external;
    function setContenthash(uint256 id, bytes calldata contenthash) external;
}
