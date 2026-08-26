// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VectorBaseArt} from './VectorBaseArt.sol';
import {VectorTraitArt} from './VectorTraitArt.sol';
import {VectorTraitArt2} from './VectorTraitArt2.sol';

/// @title VectorPepeDescriptor - high-quality traced-vector pepes
///        (experiment, 2026-08-24). Same 29-bit DNA codec as the pixel
///        descriptor; renders smooth SVG paths traced from the original
///        reference + studio trait stamps.
/// @dev Everything lives in contract bytecode - no IPFS, no external
///      storage. Library size audit: base 4.5KB + traits 11.3KB + 19.3KB,
///      all under the 24,576-byte EIP-170 limit.
contract VectorPepeDescriptor {
    // ── DNA codec (identical layout to PepeDescriptor) ─────────────────
    struct Traits {
        uint8 expr;   // 3 bits, 8 options
        uint8 eyes;   // 4 bits, 9 options
        uint8 hat;    // 4 bits, NONE + 8
        uint8 wear;   // 4 bits, NONE + 6
        uint8 item;   // 4 bits, NONE + 6
        uint8 skin;   // 3 bits, 8 options
        uint8 iris;   // 3 bits, 7 options
        uint8 bg;     // 4 bits, 10 options
    }

    function decode(uint256 dna) public pure returns (Traits memory t) {
        t.expr = uint8(dna & 7);
        t.eyes = uint8((dna >> 3) & 15);
        t.hat = uint8((dna >> 7) & 15);
        t.wear = uint8((dna >> 11) & 15);
        t.item = uint8((dna >> 15) & 15);
        t.skin = uint8((dna >> 19) & 7);
        t.iris = uint8((dna >> 22) & 7);
        t.bg = uint8((dna >> 25) & 15);
    }

    // ── rendering ──────────────────────────────────────────────────────

    function renderSVG(uint256 dna) public pure returns (string memory) {
        Traits memory t = decode(dna);
        bytes3[16] memory pal = VectorBaseArt.palette(t.skin, t.iris, t.bg);

        string memory svg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 480 480">',
            '<rect width="480" height="480" fill="',
            _hex(pal[15]),
            '"/>'
        );
        // rim under fill: dark outline first, flat green over it
        // (reference is flat-fill: no BASE_LIGHT region exists)
        svg = string.concat(svg, _path(VectorBaseArt.BASE_DARK, pal[4]));
        svg = string.concat(svg, _path(VectorBaseArt.BASE_SKIN, pal[2]));

        // nostrils (authored) + studio nudge
        svg = string.concat(
            svg,
            '<g transform="translate(',
            _itoa10(VectorBaseArt.NOSTRIL_OFF_X),
            ' ',
            _itoa10(VectorBaseArt.NOSTRIL_OFF_Y),
            ')"><ellipse cx="230" cy="270" rx="9" ry="10" fill="',
            _hex(pal[10]),
            '"/><ellipse cx="280" cy="270" rx="9" ry="10" fill="',
            _hex(pal[10]),
            '"/></g>'
        );

        (int16 ex, int16 ey) = VectorTraitArt.exprOff(t.expr);
        svg = _stampAt(svg, VectorTraitArt.exprPaths(t.expr), pal, ex, ey);
        (int16 vx, int16 vy) = VectorTraitArt.eyeOff(t.eyes);
        svg = _stampAt(svg, VectorTraitArt.eyePaths(t.eyes), pal, vx, vy);

        // hats / eyewear / items are offset stamps; 0 = NONE
        if (t.hat != 0) {
            (int16 dx, int16 dy) = VectorTraitArt2.hatOff(t.hat);
            svg = _stampAt(svg, VectorTraitArt2.hatPaths(t.hat), pal, dx, dy);
        }
        if (t.wear != 0) {
            (int16 dx, int16 dy) = VectorTraitArt2.wearOff(t.wear);
            svg = _stampAt(svg, VectorTraitArt2.wearPaths(t.wear), pal, dx, dy);
        }
        if (t.item != 0) {
            (int16 dx, int16 dy) = VectorTraitArt2.itemOff(t.item);
            svg = _stampAt(svg, VectorTraitArt2.itemPaths(t.item), pal, dx, dy);
        }

        return string.concat(svg, '</svg>');
    }

    function _path(string memory d, bytes3 c) internal pure returns (string memory) {
        return string.concat('<path d="', d, '" fill="', _hex(c), '"/>');
    }

    function _stamp(string memory svg, string memory packed, bytes3[16] memory pal)
        internal
        pure
        returns (string memory)
    {
        bytes memory b = bytes(packed);
        uint256 i;
        while (i < b.length) {
            uint8 c = uint8(b[i]);
            uint8 slot;
            if (c >= 48 && c <= 57) {
                slot = c - 48; // '0'-'9'
            } else if (c >= 65 && c <= 70) {
                slot = c - 55; // 'A'-'F'
            } else {
                revert('bad slot');
            }
            i += 2; // skip slot digit + '|'
            uint256 start = i;
            while (i < b.length && b[i] != ';') ++i;
            svg = string.concat(svg, _path(_substr(b, start, i), pal[slot]));
            if (i < b.length) ++i; // skip ';'
        }
        return svg;
    }

    function _stampAt(
        string memory svg,
        string memory packed,
        bytes3[16] memory pal,
        int16 dx,
        int16 dy
    ) internal pure returns (string memory) {
        // 48-grid cell -> 480 canvas: x10 (sign-aware)
        svg = string.concat(
            svg, '<g transform="translate(', _itoa10(dx), ' ', _itoa10(dy), ')">'
        );
        svg = _stamp(svg, packed, pal);
        return string.concat(svg, '</g>');
    }

    function _itoa10(int16 v) internal pure returns (string memory) {
        if (v < 0) return string.concat('-', _utoa(uint256(uint16(-v)) * 10));
        return _utoa(uint256(uint16(v)) * 10);
    }

    function _substr(bytes memory b, uint256 start, uint256 end)
        internal
        pure
        returns (string memory)
    {
        bytes memory out = new bytes(end - start);
        for (uint256 k; k < out.length; ++k) out[k] = b[start + k];
        return string(out);
    }

    function _hex(bytes3 c) internal pure returns (string memory) {
        bytes memory h = '0123456789abcdef';
        bytes memory out = new bytes(7);
        out[0] = '#';
        for (uint256 i; i < 3; ++i) {
            out[1 + i * 2] = h[uint8(c[i]) >> 4];
            out[2 + i * 2] = h[uint8(c[i]) & 15];
        }
        return string(out);
    }

    function _utoa(uint256 v) internal pure returns (string memory) {
        if (v == 0) return '0';
        bytes memory buf = new bytes(78);
        uint256 i = 78;
        while (v > 0) {
            buf[--i] = bytes1(uint8(48 + (v % 10)));
            v /= 10;
        }
        return _substr(buf, i, 78);
    }

    // ── metadata ───────────────────────────────────────────────────────

    function tokenURI(uint256 tokenId, uint256 dna)
        external
        pure
        returns (string memory)
    {
        Traits memory t = decode(dna);
        string memory json = string.concat(
            '{"name":"PSP Pepe #',
            _utoa(tokenId),
            '","description":"Positive Sum Pepes - vector edition. Fully on-chain.',
            '","image":"data:image/svg+xml;base64,',
            _b64(bytes(renderSVG(dna))),
            '","attributes":[',
            _attr('expression', VectorTraitArt.exprName(t.expr)), ',',
            _attr('eyes', VectorTraitArt.eyeName(t.eyes)), ',',
            _attr('hat', VectorTraitArt2.hatName(t.hat)), ',',
            _attr('eyewear', VectorTraitArt2.wearName(t.wear)), ',',
            _attr('item', VectorTraitArt2.itemName(t.item)), ',',
            _attr('skin', _skinName(t.skin)), ',',
            _attr('iris', _irisName(t.iris)), ',',
            _attr('background', _bgName(t.bg)),
            ']}'
        );
        return string.concat('data:application/json;base64,', _b64(bytes(json)));
    }

    function _attr(string memory k, string memory v)
        internal
        pure
        returns (string memory)
    {
        return string.concat('{"trait_type":"', k, '","value":"', v, '"}');
    }

    function _skinName(uint8 id) internal pure returns (string memory) {
        if (id == 0) return 'Classic';
        if (id == 1) return 'Gold';
        if (id == 2) return 'Zombie';
        if (id == 3) return 'Diamond';
        if (id == 4) return 'Grey';
        if (id == 5) return 'Orange';
        if (id == 6) return 'Green';
        return 'Alien';
    }

    function _irisName(uint8 id) internal pure returns (string memory) {
        if (id == 0) return 'Base';
        if (id == 1) return 'Blue';
        if (id == 2) return 'Green';
        if (id == 3) return 'Amber';
        if (id == 4) return 'Red';
        if (id == 5) return 'Violet';
        return 'Obsidian';
    }

    function _bgName(uint8 id) internal pure returns (string memory) {
        if (id == 0) return 'Sky';
        if (id == 1) return 'Mint';
        if (id == 2) return 'Peach';
        if (id == 3) return 'Night';
        if (id == 4) return 'Ocean';
        if (id == 5) return 'Sunset';
        if (id == 6) return 'Forest';
        if (id == 7) return 'Void';
        if (id == 8) return 'Yellow';
        return 'Magenta';
    }

    // ── base64 ─────────────────────────────────────────────────────────

    function _b64(bytes memory data) internal pure returns (string memory) {
        string memory tbl =
            'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
        return _b64run(data, tbl);
    }

    function _b64run(bytes memory data, string memory tbl)
        internal
        pure
        returns (string memory)
    {
        bytes memory T = bytes(tbl);
        uint256 len = data.length;
        uint256 encodedLen = 4 * ((len + 2) / 3);
        bytes memory out = new bytes(encodedLen);
        uint256 i;
        uint256 j;
        for (; i + 2 < len; i += 3) {
            uint256 n = (uint256(uint8(data[i])) << 16)
                | (uint256(uint8(data[i + 1])) << 8) | uint256(uint8(data[i + 2]));
            out[j++] = T[(n >> 18) & 63];
            out[j++] = T[(n >> 12) & 63];
            out[j++] = T[(n >> 6) & 63];
            out[j++] = T[n & 63];
        }
        uint256 rem = len - i;
        if (rem == 1) {
            uint256 n = uint256(uint8(data[i])) << 16;
            out[j++] = T[(n >> 18) & 63];
            out[j++] = T[(n >> 12) & 63];
            out[j++] = '=';
            out[j] = '=';
        } else if (rem == 2) {
            uint256 n = (uint256(uint8(data[i])) << 16) | (uint256(uint8(data[i + 1])) << 8);
            out[j++] = T[(n >> 18) & 63];
            out[j++] = T[(n >> 12) & 63];
            out[j++] = T[(n >> 6) & 63];
            out[j] = '=';
        }
        return string(out);
    }
}
