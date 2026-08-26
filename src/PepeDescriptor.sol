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

    /// @dev all 80 trait names, NUL-separated, axis order: expr(0-9),
    ///      eyes(10-19), hat(20-29), wear(30-39), item(40-49), skin(50-59),
    ///      iris(60-69), bg(70-79). Packed table keeps the runtime well
    ///      under the EIP-170 size limit (the branching tables blew past).
    bytes internal constant NAMES = hex"4E65757472616C00536D696C65004772696E004C61756768005361640053636172656400416E67727900536D69726B004372696E6765004D656800436C6173736963004665656C7300536C65657079004465727000576964650042616B656400537461727279004579726F6C6C00446561640043726F737365796564004E6F6E65004261636B7761726473204361700054696E666F696C0043726F776E004865616462616E64004E617275746F00546F7020486174004672656E63680057697A61726400486F6F646965004E6F6E6500536861646573004D6F6E6F636C6500476C6173736573004D6F6767656400457965706174636800486561727420476C617373657300334420476C61737365730043796265722053686164657300436F6F6C20536861646573004E6F6E6500436967617265747465005069706500436861696E005374697463686573004E6F6F736500436967617200426F6E67004A617268656164004C6F6C6C69706F7000436C617373696300476F6C64005A6F6D626965004469616D6F6E64004E69676874004C696D65004F72616E676500477265656E00546F6164005369636B00536C61746500536B7900416D62657200456D6572616C64004372696D736F6E004F6E79780042415345004D6167656E7461004E656F6E20477265656E004772657900536B79004D696E74005065616368004C6176656E6465720053756E736574004372696D736F6E004D69646E6967687400566F69640059656C6C6F77004D4147454E544100";
    /// @dev 81 big-endian uint16 start-offsets into NAMES (80 names + end)
    bytes internal constant NAME_OFFS = hex"00000008000E00130019001D0024002A00300037003B0043004900500055005A00600067006E0073007D008200900098009E00A700AE00B600BD00C400CB00D000D700DF00E700EE00F701050110011D0129012E0138013D0143014C01520158015D0165016E0176017B0182018A01900195019C01A201A701AC01B201B601BC01C401CC01D101D601DE01E901EE01F201F701FD0206020D0215021E0223022A0232";

    function _off(uint256 i) internal pure returns (uint256) {
        return (uint256(uint8(NAME_OFFS[i * 2])) << 8) | uint8(NAME_OFFS[i * 2 + 1]);
    }

    function _name(uint256 idx) internal pure returns (string memory s) {
        uint256 a = _off(idx);
        uint256 end = _off(idx + 1) - 1; // exclude the NUL
        s = new string(end - a);
        for (uint256 i; i < end - a; ++i) bytes(s)[i] = NAMES[a + i];
    }

    // ───────────────────────── metadata ─────────────────────────

    function exprName(uint8 id) public pure returns (string memory) { return _name(id); }
    function eyeName(uint8 id) public pure returns (string memory) { return _name(10 + id); }
    function hatName(uint8 id) public pure returns (string memory) { return _name(20 + id); }
    function wearName(uint8 id) public pure returns (string memory) { return _name(30 + id); }
    function itemName(uint8 id) public pure returns (string memory) { return _name(40 + id); }
    function skinName(uint8 id) public pure returns (string memory) { return _name(50 + id); }
    function irisName(uint8 id) public pure returns (string memory) { return _name(60 + id); }
    function bgName(uint8 id) public pure returns (string memory) { return _name(70 + id); }

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
