// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base64} from "solady/src/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {PepeArtData8Bit} from "./PepeArtData8Bit.sol";

/// @title PepeDescriptor8Bit — fully on-chain 48x48 pixel pepe renderer (v4)
/// @notice Zero off-chain dependencies: art bytes live in PepeArtData
///         bytecode, this contract turns them into SVG + a base64 data-URI
///         tokenURI at view time. No IPFS, no HTTP pointers, no oracles.
///         Rendering is `pure` — free to read for marketplaces/viewers.
/// @dev DNA layout (27 bits, little-endian nibble-ish fields):
///         expr   bits 0-2   (8)
///         eyes   bits 3-5   (6)
///         hat    bits 6-9   (5)
///         wear   bits 10-13 (5)
///         item   bits 14-17 (5)
///         skin   bits 18-20 (5)
///         iris   bits 21-23 (6)
///         bg     bits 24-26 (8)
///      Combo space: 8*6*5*5*5*5*6*8 = 1,440,000 pepes.
///      Layer order: base, expression, eyes, eyewear, hat, item.
contract PepeDescriptor8Bit {
    using Strings for uint256;

    uint8 public constant SIZE = PepeArtData8Bit.SIZE;

    struct Traits {
        uint8 expr;
        uint8 eyes;
        uint8 hat;
        uint8 wear;
        uint8 item;
        uint8 skin;
        uint8 iris;
        uint8 bg;
    }

    // ───────────────────────── DNA codec ─────────────────────────

    /// @dev every axis is clamped (modulo) so ANY uint256 dna renders —
    ///      out-of-range field bits can never OOB the palette tables.
    function decode(uint256 dna) public pure returns (Traits memory t) {
        t.expr = uint8((dna & 7) % PepeArtData8Bit.EXPR_COUNT);
        t.eyes = uint8(((dna >> 3) & 15) % PepeArtData8Bit.EYE_COUNT);
        t.hat = uint8(((dna >> 7) & 15) % PepeArtData8Bit.HAT_COUNT);
        t.wear = uint8(((dna >> 11) & 15) % PepeArtData8Bit.WEAR_COUNT);
        t.item = uint8(((dna >> 15) & 15) % PepeArtData8Bit.ITEM_COUNT);
        t.skin = uint8(((dna >> 19) & 7) % PepeArtData8Bit.SKIN_COUNT);
        t.iris = uint8(((dna >> 22) & 7) % PepeArtData8Bit.IRIS_COUNT);
        t.bg = uint8(((dna >> 25) & 15) % PepeArtData8Bit.BG_COUNT);
    }

    function pack(Traits memory t) public pure returns (uint256 dna) {
        dna = uint256(t.expr)
            | (uint256(t.eyes) << 3)
            | (uint256(t.hat) << 7)
            | (uint256(t.wear) << 11)
            | (uint256(t.item) << 15)
            | (uint256(t.skin) << 19)
            | (uint256(t.iris) << 22)
            | (uint256(t.bg) << 25);
    }

    // ───────────────────────── metadata ─────────────────────────

    function exprName(uint8 id) public pure returns (string memory) {
        if (id == 0) return "Neutral";
        if (id == 1) return "Smile";
        if (id == 2) return "Grin";
        if (id == 3) return "Laugh";
        if (id == 4) return "Sad";
        if (id == 5) return "Scared";
        if (id == 6) return "Angry";
        return "Smirk";
    }

    function eyeName(uint8 id) public pure returns (string memory) {
        if (id == 0) return "Classic";
        if (id == 1) return "Feels";
        if (id == 2) return "Sleepy";
        if (id == 3) return "Derp";
        if (id == 4) return "Wide";
        return "Baked";
    }

    function hatName(uint8 id) public pure returns (string memory) {
        if (id == 0) return "None";
        if (id == 1) return "Backwards Cap";
        if (id == 2) return "Tinfoil";
        if (id == 3) return "Crown";
        return "Headband";
    }

    function wearName(uint8 id) public pure returns (string memory) {
        if (id == 0) return "None";
        if (id == 1) return "Shades";
        if (id == 2) return "Monocle";
        if (id == 3) return "Glasses";
        return "Visor";
    }

    function itemName(uint8 id) public pure returns (string memory) {
        if (id == 0) return "None";
        if (id == 1) return "Cigarette";
        if (id == 2) return "Snack";
        if (id == 3) return "Pipe";
        return "Chain";
    }

    function skinName(uint8 id) public pure returns (string memory) {
        if (id == 0) return "Classic";
        if (id == 1) return "Gold";
        if (id == 2) return "Zombie";
        if (id == 3) return "Diamond";
        return "Night";
    }

    function irisName(uint8 id) public pure returns (string memory) {
        if (id == 0) return "Slate";
        if (id == 1) return "Sky";
        if (id == 2) return "Amber";
        if (id == 3) return "Emerald";
        if (id == 4) return "Crimson";
        return "Onyx";
    }

    function bgName(uint8 id) public pure returns (string memory) {
        if (id == 0) return "Sky";
        if (id == 1) return "Mint";
        if (id == 2) return "Peach";
        if (id == 3) return "Lavender";
        if (id == 4) return "Sunset";
        if (id == 5) return "Crimson";
        if (id == 6) return "Midnight";
        return "Void";
    }

    // ───────────────────────── JSON + URI ─────────────────────────

    /// @notice full ERC-721-style metadata, base64 data URI, art inline
    function tokenURI(uint256 dna) public pure returns (string memory) {
        Traits memory t = decode(dna);
        string memory attrs = string.concat(
            _attr("Expression", exprName(t.expr)),
            ",",
            _attr("Eyes", eyeName(t.eyes)),
            ",",
            _attr("Hat", hatName(t.hat)),
            ",",
            _attr("Eyewear", wearName(t.wear))
        );
        attrs = string.concat(
            attrs,
            ",",
            _attr("Item", itemName(t.item)),
            ",",
            _attr("Skin", skinName(t.skin)),
            ",",
            _attr("Iris", irisName(t.iris)),
            ",",
            _attr("Background", bgName(t.bg))
        );
        string memory json = string.concat(
            '{"name":"Positive Sum Pepe #',
            dna.toString(),
            '","description":"A positive-sum pepe. 100% on-chain: 8-axis DNA (expression, eyes, hat, eyewear, item, skin, iris, background), rendered to SVG at view time. No IPFS, no servers.","attributes":[',
            attrs,
            '],"image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(renderSVG(dna))),
            '"}'
        );
        return string.concat(
            "data:application/json;base64,", Base64.encode(bytes(json))
        );
    }

    function _attr(string memory k, string memory v)
        private
        pure
        returns (string memory)
    {
        return string.concat('{"trait_type":"', k, '","value":"', v, '"}');
    }

    // ───────────────────────── SVG render ─────────────────────────

    /// @notice dna -> complete SVG (background, base head, expression,
    ///         eyes, eyewear, hat, item)
    function renderSVG(uint256 dna) public pure returns (string memory) {
        Traits memory t = decode(dna);
        bytes3[16] memory pal = PepeArtData8Bit.palette(t.skin, t.iris, t.bg);
        string memory head = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" shapeRendering="crispEdges" viewBox="0 0 48 48">',
            // background (palette slot 15) — transparent cells show it
            '<rect x="0" y="0" width="48" height="48" fill="',
            _hex(pal[15]),
            '"/>'
        );
        return string.concat(head, _layers(t, pal), "</svg>");
    }

    /// @dev flat sequential concat keeps the via-ir stack shallow
    function _layers(Traits memory t, bytes3[16] memory pal)
        private
        pure
        returns (string memory s)
    {
        // memory array keeps every stamp pointer OFF the stack
        bytes[6] memory stamps;
        stamps[0] = PepeArtData8Bit.SPRITE_BASE;
        stamps[1] = PepeArtData8Bit.expr(t.expr);
        stamps[2] = PepeArtData8Bit.eye(t.eyes);
        stamps[3] = (t.wear == 0) ? bytes("") : PepeArtData8Bit.wear(t.wear);
        stamps[4] = (t.hat == 0) ? bytes("") : PepeArtData8Bit.hat(t.hat);
        stamps[5] = (t.item == 0) ? bytes("") : PepeArtData8Bit.item(t.item);
        s = _runs(stamps[0], 0, 0, 48, pal);
        for (uint256 i = 1; i < 6; ++i) {
            if (stamps[i].length != 0) {
                s = string.concat(s, _stamp(stamps[i], pal));
            }
        }
    }

    /// @dev decode a stamp (4-byte dx,dy,w,h header + RLE) into rects
    function _stamp(bytes memory stamp, bytes3[16] memory pal)
        private
        pure
        returns (string memory)
    {
        if (stamp.length == 0) return "";
        return
            _runs(
                stamp,
                uint8(stamp[0]),
                uint8(stamp[1]),
                uint8(stamp[2]),
                pal,
                4
            );
    }

    /// @dev RLE layer -> one <rect> per run, at (ox+x, oy+y). RLE byte =
    ///      (len-1)<<4 | paletteIndex; runs never cross row boundaries.
    ///      `off` skips a stamp header (0 for the base layer).
    function _runs(
        bytes memory data,
        uint256 ox,
        uint256 oy,
        uint256 w,
        bytes3[16] memory pal
    ) internal pure returns (string memory) {
        return _runs(data, ox, oy, w, pal, 0);
    }

    function _runs(
        bytes memory data,
        uint256 ox,
        uint256 oy,
        uint256 w,
        bytes3[16] memory pal,
        uint256 off
    ) internal pure returns (string memory) {
        string memory s = "";
        uint256 x;
        uint256 y;
        for (uint256 i = off; i < data.length; ++i) {
            uint8 b = uint8(data[i]);
            uint256 len = (b >> 4) + 1;
            uint8 idx = b & 0x0F;
            if (idx != 0) {
                s = string.concat(s, _rect(ox + x, oy + y, len, pal[idx]));
            }
            x += len;
            if (x == w) {
                x = 0;
                ++y;
            }
        }
        return s;
    }

    /// @dev one crisp-edge rect row; own frame keeps _runs' stack flat
    function _rect(
        uint256 x,
        uint256 y,
        uint256 w,
        bytes3 c
    ) private pure returns (string memory) {
        return
            string.concat(
                '<rect x="',
                x.toString(),
                '" y="',
                y.toString(),
                '" width="',
                w.toString(),
                '" height="1" fill="',
                _hex(c),
                '"/>'
            );
    }

    function _hex(bytes3 c) private pure returns (string memory) {
        bytes16 HEX = "0123456789ABCDEF";
        bytes memory s = new bytes(7);
        s[0] = "#";
        for (uint256 i; i < 3; ++i) {
            uint8 b = uint8(uint24(c) >> ((2 - i) * 8)); // high byte first
            s[1 + i * 2] = HEX[b >> 4];
            s[2 + i * 2] = HEX[b & 0x0F];
        }
        return string(s);
    }
}
