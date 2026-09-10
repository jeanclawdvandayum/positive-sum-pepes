// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ExpandedPepeArt} from "../art/ExpandedPepeArt.sol";
import {PepeArtData} from "../PepeArtData.sol";

/// @title PepeDna
/// @notice Canonical identity for the production renderer's eight v2 traits.
/// @dev Ignore unused high bits and normalize modulo aliases, exactly as the
/// renderer does. One-based mixed-radix keys leave zero as an empty sentinel.
library PepeDna {
    uint256 internal constant COMBINATIONS = uint256(PepeArtData.EXPR_COUNT) * PepeArtData.EYE_COUNT
        * PepeArtData.HAT_COUNT * PepeArtData.WEAR_COUNT * PepeArtData.ITEM_COUNT
        * PepeArtData.SKIN_COUNT * PepeArtData.IRIS_COUNT * PepeArtData.BG_COUNT;

    function combinations(uint256 version) internal pure returns (uint256 result) {
        uint256[8] memory c = counts(version);
        result = 1;
        for (uint256 i; i < 8; ++i) result *= c[i];
    }

    function counts(uint256 version) private pure returns (uint256[8] memory) {
        if (version == 2) return [uint256(ExpandedPepeArt.EXPR_COUNT), ExpandedPepeArt.EYE_COUNT,
            ExpandedPepeArt.HAT_COUNT, ExpandedPepeArt.WEAR_COUNT, ExpandedPepeArt.ITEM_COUNT,
            ExpandedPepeArt.SKIN_COUNT, ExpandedPepeArt.IRIS_COUNT, ExpandedPepeArt.BG_COUNT];
        assert(version == 1);
        return [uint256(PepeArtData.EXPR_COUNT), PepeArtData.EYE_COUNT, PepeArtData.HAT_COUNT,
            PepeArtData.WEAR_COUNT, PepeArtData.ITEM_COUNT, PepeArtData.SKIN_COUNT,
            PepeArtData.IRIS_COUNT, PepeArtData.BG_COUNT];
    }

    function key(uint256 dna) internal pure returns (uint256) { return key(dna, 1); }

    function key(uint256 dna, uint256 version) internal pure returns (uint256 result) {
        uint256[8] memory c = counts(version);
        uint256 place = 1;
        for (uint256 i; i < 8; ++i) {
            result += ((dna >> (4 * i)) & 15) % c[i] * place;
            place *= c[i];
        }
        return result + 1;
    }

    /// @dev Caller supplies a valid key in [1, COMBINATIONS].
    function fromKey(uint256 index) internal pure returns (uint256) { return fromKey(index, 1); }

    function fromKey(uint256 index, uint256 version) internal pure returns (uint256 dna) {
        uint256[8] memory c = counts(version);
        --index;
        for (uint256 i; i < 8; ++i) {
            dna |= (index % c[i]) << (4 * i);
            index /= c[i];
        }
    }
}
