// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Greenlist — test-side twin of the deploy tooling's CSV → merkle
///        root builder (greenlist-IBCO rules v3).
/// @notice The format is pinned by RoundController._greenlisted and the
///         DeployPSP CSV path — all three must stay byte-identical:
///           leaf   = keccak256(abi.encodePacked(account))
///           parent = keccak256(left < right ? (left, right) : (right, left))
///         Odd levels are duplicate-padded (the last leaf pairs with
///         itself); a single-entry csv pads to [a, a] and proves with its
///         own leaf as the sibling, so proofs are never empty for members.
library Greenlist {
    function leafOf(address a) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(a));
    }

    /// @dev Root over the csv entries. Order-insensitive (levels sort).
    function rootOf(address[] memory accounts) internal pure returns (bytes32 root) {
        bytes32[] memory level = _leaves(accounts);
        do {
            level = _up(level);
        } while (level.length > 1);
        root = level[0];
    }

    /// @dev Inclusion proof for `who` (must be a csv entry).
    function proofOf(address[] memory accounts, address who)
        internal
        pure
        returns (bytes32[] memory proof)
    {
        bytes32[] memory level = _leaves(accounts);
        uint256 idx = type(uint256).max;
        for (uint256 i; i < accounts.length; ++i) {
            if (accounts[i] == who) {
                idx = i;
                break;
            }
        }
        require(idx != type(uint256).max, "Greenlist: not a member");
        proof = new bytes32[](_depth(accounts.length));
        uint256 d;
        do {
            uint256 n = _padded(level.length);
            proof[d] = (idx % 2 == 0) ? _at(level, _sib(n, idx)) : level[idx - 1];
            level = _up(level);
            idx /= 2;
            ++d;
        } while (level.length > 1);
        assert(d == proof.length);
    }

    // ─────────────── internals ───────────────

    function _leaves(address[] memory accounts) private pure returns (bytes32[] memory level) {
        require(accounts.length > 0, "Greenlist: empty csv");
        level = new bytes32[](accounts.length);
        for (uint256 i; i < accounts.length; ++i) level[i] = leafOf(accounts[i]);
    }

    function _up(bytes32[] memory level) private pure returns (bytes32[] memory next) {
        uint256 n = _padded(level.length);
        next = new bytes32[](n / 2);
        for (uint256 i; i < n; i += 2) {
            next[i / 2] = _pair(_at(level, i), _at(level, i + 1));
        }
    }

    function _pair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// @dev Virtual read — the duplicate-pad tail reuses the last leaf.
    function _at(bytes32[] memory level, uint256 i) private pure returns (bytes32) {
        return i < level.length ? level[i] : level[level.length - 1];
    }

    /// @dev Sibling index for an even `idx` inside a padded level of size n.
    function _sib(uint256 n, uint256 idx) private pure returns (uint256) {
        return idx + 1 < n ? idx + 1 : idx;
    }

    function _padded(uint256 n) private pure returns (uint256) {
        if (n == 1) return 2; // single leaf: [a, a]
        return n % 2 == 1 ? n + 1 : n;
    }

    /// @dev Pairings from leaf level to root, padding included.
    function _depth(uint256 n) private pure returns (uint256 d) {
        if (n == 1) return 1;
        while (n > 1) {
            n = _padded(n) / 2;
            ++d;
        }
    }
}
