// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base64} from "solady/src/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {PepeArtData} from "./PepeArtData.sol";

/// @title PepeDescriptor — fully on-chain 69x69 pixel pepe renderer (v5)
/// @notice Zero off-chain dependencies: art bytes live in PepeArtData
///         bytecode, this contract turns them into SVG + a base64 data-URI
///         tokenURI at view time. No IPFS, no HTTP pointers, no oracles.
///         Rendering is `pure` — free to read for marketplaces/viewers.
/// @dev DNA layout (29 bits, little-endian fields):
///         expr   bits 0-2   (8 values)
///         eyes   bits 3-6   (9)
///         hat    bits 7-10  (10)
///         wear   bits 11-14 (8)
///         item   bits 15-18 (8)
///         skin   bits 19-21 (8)
///         iris   bits 22-24 (7)
///         bg     bits 25-28 (10)
///      Combo space: 8*9*10*8*8*8*7*10 = 25,804,800 pepes.
///      Layer order: base, expression, eyes, eyewear, hat, item.
contract PepeDescriptor {
    using Strings for uint256;

    uint8 public constant SIZE = PepeArtData.SIZE;

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
    ///      Layout (v2, all axes 4 bits — 10 traits per axis max):
    ///      expr<<0 | eyes<<4 | hat<<8 | wear<<12 | item<<16 | skin<<20 |
    ///      iris<<24 | bg<<28. Old 3-bit expr/skin/iris fields aliased
    ///      ids 8/9 once the axes widened past 8 traits.
    function decode(uint256 dna) public pure returns (Traits memory t) {
        t.expr = uint8((dna & 15) % PepeArtData.EXPR_COUNT);
        t.eyes = uint8(((dna >> 4) & 15) % PepeArtData.EYE_COUNT);
        t.hat = uint8(((dna >> 8) & 15) % PepeArtData.HAT_COUNT);
        t.wear = uint8(((dna >> 12) & 15) % PepeArtData.WEAR_COUNT);
        t.item = uint8(((dna >> 16) & 15) % PepeArtData.ITEM_COUNT);
        t.skin = uint8(((dna >> 20) & 15) % PepeArtData.SKIN_COUNT);
        t.iris = uint8(((dna >> 24) & 15) % PepeArtData.IRIS_COUNT);
        t.bg = uint8(((dna >> 28) & 15) % PepeArtData.BG_COUNT);
    }

    function pack(Traits memory t) public pure returns (uint256 dna) {
        dna = uint256(t.expr)
            | (uint256(t.eyes) << 4)
            | (uint256(t.hat) << 8)
            | (uint256(t.wear) << 12)
            | (uint256(t.item) << 16)
            | (uint256(t.skin) << 20)
            | (uint256(t.iris) << 24)
            | (uint256(t.bg) << 28);
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
        if (id == 7) return "Smirk";
        if (id == 8) return "Cringe";
        return "Meh";
    }

    function eyeName(uint8 id) public pure returns (string memory) {
        if (id == 0) return "Classic";
        if (id == 1) return "Feels";
        if (id == 2) return "Sleepy";
        if (id == 3) return "Derp";
        if (id == 4) return "Wide";
        if (id == 5) return "Baked";
        if (id == 6) return "Starry";
        if (id == 7) return "Eyroll";
        if (id == 8) return "Dead";
        return "Crosseyed";
    }

    function hatName(uint8 id) public pure returns (string memory) {
        if (id == 0) return "None";
        if (id == 1) return "Backwards Cap";
        if (id == 2) return "Tinfoil";
        if (id == 3) return "Crown";
        if (id == 4) return "Headband";
        if (id == 5) return "Naruto";
        if (id == 6) return "Top Hat";
        if (id == 7) return "French";
        if (id == 8) return "Wizard";
        return "Hoodie";
    }

    function wearName(uint8 id) public pure returns (string memory) {
        if (id == 0) return "None";
        if (id == 1) return "Shades";
        if (id == 2) return "Monocle";
        if (id == 3) return "Glasses";
        if (id == 4) return "Mogged";
        if (id == 5) return "Eyepatch";
        if (id == 6) return "Heart Glasses";
        if (id == 7) return "3D Glasses";
        if (id == 8) return "Cyber Shades";
        return "Cool Shades";
    }

    function itemName(uint8 id) public pure returns (string memory) {
        if (id == 0) return "None";
        if (id == 1) return "Cigarette";
        if (id == 2) return "Pipe";
        if (id == 3) return "Chain";
        if (id == 4) return "Stitches";
        if (id == 5) return "Noose";
        if (id == 6) return "Cigar";
        if (id == 7) return "Bong";
        if (id == 8) return "Jarhead";
        return "Lollipop";
    }

    function skinName(uint8 id) public pure returns (string memory) {
        if (id == 0) return "Classic";
        if (id == 1) return "Gold";
        if (id == 2) return "Zombie";
        if (id == 3) return "Diamond";
        if (id == 4) return "Night";
        if (id == 5) return "Lime";
        if (id == 6) return "Orange";
        if (id == 7) return "Green";
        if (id == 8) return "Toad";
        return "Sick";
    }

    function irisName(uint8 id) public pure returns (string memory) {
        if (id == 0) return "Slate";
        if (id == 1) return "Sky";
        if (id == 2) return "Amber";
        if (id == 3) return "Emerald";
        if (id == 4) return "Crimson";
        if (id == 5) return "Onyx";
        if (id == 6) return "BASE";
        if (id == 7) return "Magenta";
        if (id == 8) return "Neon Green";
        return "Grey";
    }

    function bgName(uint8 id) public pure returns (string memory) {
        if (id == 0) return "Sky";
        if (id == 1) return "Mint";
        if (id == 2) return "Peach";
        if (id == 3) return "Lavender";
        if (id == 4) return "Sunset";
        if (id == 5) return "Crimson";
        if (id == 6) return "Midnight";
        if (id == 7) return "Void";
        if (id == 8) return "Yellow";
        return "MAGENTA";
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
        bytes3[24] memory pal = PepeArtData.palette(t.skin, t.iris, t.bg);
        string memory head = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" shapeRendering="crispEdges" viewBox="0 0 69 69">',
            // background (palette slot 15) — transparent cells show it
            '<rect x="0" y="0" width="69" height="69" fill="',
            _hex(pal[15]),
            '"/>'
        );
        return string.concat(head, _layers(t, pal), "</svg>");
    }

    /// @dev flat sequential concat keeps the via-ir stack shallow
    function _layers(Traits memory t, bytes3[24] memory pal)
        private
        pure
        returns (string memory s)
    {
        // memory array keeps every stamp pointer OFF the stack
        bytes[6] memory stamps;
        stamps[0] = PepeArtData.SPRITE_BASE;
        stamps[1] = PepeArtData.expr(t.expr);
        stamps[2] = PepeArtData.eye(t.eyes);
        stamps[3] = (t.wear == 0) ? bytes("") : PepeArtData.wear(t.wear);
        stamps[4] = (t.hat == 0) ? bytes("") : PepeArtData.hat(t.hat);
        stamps[5] = (t.item == 0) ? bytes("") : PepeArtData.item(t.item);
        s = _runs(stamps[0], 0, 0, SIZE, pal);
        for (uint256 i = 1; i < 6; ++i) {
            if (stamps[i].length != 0) {
                s = string.concat(s, _stamp(stamps[i], pal));
            }
        }
    }

    /// @dev decode a stamp (4-byte dx,dy,w,h header + RLE) into rects
    function _stamp(bytes memory stamp, bytes3[24] memory pal)
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

    /// @dev RLE layer -> one <rect> per run, at (ox+x, oy+y). Each run
    ///      is TWO bytes: [len-1][paletteIndex]; runs never cross row
    ///      boundaries. `off` skips a stamp header (0 for the base).
    function _runs(
        bytes memory data,
        uint256 ox,
        uint256 oy,
        uint256 w,
        bytes3[24] memory pal
    ) internal pure returns (string memory) {
        return _runs(data, ox, oy, w, pal, 0);
    }

    function _runs(
        bytes memory data,
        uint256 ox,
        uint256 oy,
        uint256 w,
        bytes3[24] memory pal,
        uint256 off
    ) internal pure returns (string memory) {
        string memory s = "";
        uint256 x;
        uint256 y;
        // v5 byte-pair RLE: [len-1][slot] per run (24 slots need 5 bits,
        // the old nibble packed 4)
        for (uint256 i = off; i + 1 < data.length; i += 2) {
            uint256 len = uint256(uint8(data[i])) + 1;
            uint8 idx = uint8(data[i + 1]);
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
