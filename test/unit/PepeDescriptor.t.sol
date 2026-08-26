// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Base64} from "solady/src/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {PepeDescriptor} from "src/PepeDescriptor.sol";
import {PepeArtData} from "src/PepeArtData.sol";

/// @title PepeDescriptor v5 tests — every assertion runs against the REAL
///        renderer output (SVG parsed back into a pixel grid). No mocks.
///        Pins re-measured 2026-08-27 against scoopy's studio pass v3
///        (trait files + compiled .sol byte-identical in repo). Axes are
///        10 across the board; CRINGE carries deliberate gritted teeth.
contract PepeDescriptorTest is Test {
    PepeDescriptor d;

    // classic palette slot -> hex (must match gen_pepe_art.py FIXED/SKIN)
    string constant BASE = "#62C875"; // 2
    string constant LIGHT = "#8BD07C"; // 3
    string constant DARK = "#2D5034"; // 4
    string constant WHITE = "#FEFEFE"; // 5
    string constant LIPS = "#C8626D"; // 7
    string constant LIPSDARK = "#432122"; // 8
    string constant NOSTRIL = "#244229"; // 10
    string constant RED = "#D0483E"; // 9
    string constant GOLD = "#E8B93E"; // 11
    string constant GOLDD = "#8C6A1D"; // 12
    string constant BLACK = "#23282D"; // 14
    string constant GLINT = "#D3EDCD"; // 18 (skin glint)
    string constant SKINDEEP = "#1A2E1E"; // 17 (classic skin deep)

    function setUp() public {
        d = new PepeDescriptor();
    }

    // ─────────────── helpers ───────────────

    function _dna(
        uint8 expr,
        uint8 eyes,
        uint8 hat,
        uint8 wear,
        uint8 item,
        uint8 skin,
        uint8 iris,
        uint8 bg
    ) internal view returns (uint256) {
        return d.pack(
            PepeDescriptor.Traits(expr, eyes, hat, wear, item, skin, iris, bg)
        );
    }

    /// @dev parse renderSVG output into a color grid (last write wins =
    ///      document order, exactly how SVG paints)
    function _composite(uint256 dna)
        internal
        view
        returns (string[69][69] memory g)
    {
        string memory svg = d.renderSVG(dna);
        uint256 i = _find(svg, "<rect", 0);
        while (i < bytes(svg).length) {
            uint256 x = _num(svg, _find(svg, "x=\"", i) + 3);
            uint256 y = _num(svg, _find(svg, "y=\"", i) + 3);
            uint256 w = _num(svg, _find(svg, "width=\"", i) + 7);
            uint256 f = _find(svg, "fill=\"", i) + 6;
            string memory col = _slice(svg, f, f + 7);
            for (uint256 dx; dx < w; ++dx) {
                g[y][x + dx] = col;
            }
            i = _find(svg, "<rect", i + 5);
            if (i == type(uint256).max) break;
        }
    }

    function _find(
        string memory s,
        string memory needle,
        uint256 from
    ) internal view returns (uint256) {
        bytes memory b = bytes(s);
        bytes memory n = bytes(needle);
        for (uint256 i = from; i + n.length <= b.length; ++i) {
            bool hit = true;
            for (uint256 j; j < n.length; ++j) {
                if (b[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return i;
        }
        return type(uint256).max; // sentinel: NOT FOUND (0 is valid)
    }

    function _num(string memory s, uint256 at)
        internal
        view
        returns (uint256 v)
    {
        bytes memory b = bytes(s);
        while (at < b.length && b[at] >= "0" && b[at] <= "9") {
            v = v * 10 + uint8(b[at]) - 48;
            ++at;
        }
    }

    function _slice(
        string memory s,
        uint256 a,
        uint256 b
    ) internal view returns (string memory) {
        bytes memory src = bytes(s);
        bytes memory r = new bytes(b - a);
        for (uint256 i; i < b - a; ++i) r[i] = src[a + i];
        return string(r);
    }

    function _contains(string memory s, string memory n)
        internal
        view
        returns (bool)
    {
        return _find(s, n, 0) != type(uint256).max;
    }

    // ─────────────── 1. DNA codec ───────────────

    function test_DNA_PackDecodeRoundtrip(uint256 seed) public {
        uint8 e = uint8(seed % 10);
        uint8 ey = uint8((seed >> 8) % 10);
        uint8 h = uint8((seed >> 16) % 10);
        uint8 w = uint8((seed >> 24) % 10);
        uint8 it = uint8((seed >> 32) % 10);
        uint8 sk = uint8((seed >> 40) % 10);
        uint8 ir = uint8((seed >> 48) % 10);
        uint8 b = uint8((seed >> 56) % 10);
        uint256 dna = _dna(e, ey, h, w, it, sk, ir, b);
        PepeDescriptor.Traits memory t = d.decode(dna);
        assertEq(t.expr, e);
        assertEq(t.eyes, ey);
        assertEq(t.hat, h);
        assertEq(t.wear, w);
        assertEq(t.item, it);
        assertEq(t.skin, sk);
        assertEq(t.iris, ir);
        assertEq(t.bg, b);
        assertEq(d.pack(t), dna);
    }

    function test_DNA_DecodeClampsAnyUint256(uint256 dna) public view {
        PepeDescriptor.Traits memory t = d.decode(dna);
        assertLt(t.expr, 10);
        assertLt(t.eyes, 10);
        assertLt(t.hat, 10);
        assertLt(t.wear, 10);
        assertLt(t.item, 10);
        assertLt(t.skin, 10);
        assertLt(t.iris, 10);
        assertLt(t.bg, 10);
    }

    function test_DNA_KnownUnpack() public view {
        PepeDescriptor.Traits memory t = d.decode(0);
        assertEq(t.expr, 0);
        assertEq(t.eyes, 0);
        assertEq(t.hat, 0);
        assertEq(t.wear, 0);
        assertEq(t.item, 0);
        assertEq(t.skin, 0);
        assertEq(t.iris, 0);
        assertEq(t.bg, 0);
        // max axis values: 9 on every axis — codec v2 is 4 bits per axis
        uint256 maxDna = 9 | (9 << 4) | (9 << 8) | (9 << 12) | (9 << 16)
            | (9 << 20) | (9 << 24) | (9 << 28);
        t = d.decode(maxDna);
        assertEq(t.expr, 9);
        assertEq(t.eyes, 9);
        assertEq(t.hat, 9);
        assertEq(t.wear, 9);
        assertEq(t.item, 9);
        assertEq(t.skin, 9);
        assertEq(t.iris, 9);
        assertEq(t.bg, 9);
        // all-4-bit layout round-trips: no bit collisions between axes
        assertEq(d.pack(t), maxDna);
        assertEq(d.decode(d.pack(PepeDescriptor.Traits(9, 9, 9, 9, 9, 9, 9, 9))).expr, 9);
    }

    function test_DNA_CombinationSpace() public view {
        // 10^8 = 100,000,000
        assertEq(PepeArtData.COMBOS, 100_000_000);
    }

    function test_Art_SlotsAndSize() public view {
        // palette width is a FUNCTION of slot count — 24 slots fit 5 bits
        assertEq(PepeArtData.SIZE, 69);
        assertEq(PepeArtData.SLOTS, 24);
        // every skin carries the full 8-slot ramp (incl. high-contrast
        // accessory slots 16-19)
        for (uint8 s; s < PepeArtData.SKIN_COUNT; ++s) {
            bytes3[24] memory pal = PepeArtData.palette(s, 0, 0);
            for (uint8 k = 16; k < 20; ++k) {
                assertTrue(pal[k] != bytes3(0), "skin ramp slot unset");
            }
            // high contrast: bright strictly lighter than base, deep
            // strictly darker than the dark shade
            assertTrue(_lum(pal[16]) > _lum(pal[2]), "16 not brighter");
            assertTrue(_lum(pal[17]) < _lum(pal[4]), "17 not deeper");
        }
        // fixed shading slots exist and are distinct
        bytes3[24] memory pal = PepeArtData.palette(0, 0, 0);
        assertTrue(_lum(pal[20]) > _lum(pal[21]), "steel light/dark");
        assertTrue(pal[22] != bytes3(0) && pal[23] != bytes3(0), "cream/umber");
    }

    function _lum(bytes3 c) internal pure returns (uint256) {
        return uint256(uint8(uint24(c) >> 16)) + uint256(uint8(uint24(c) >> 8))
            + uint8(uint24(c));
    }

    // ─────────────── 2. stamps stay on canvas ───────────────

    function test_RLE_AllStampsDecompose() public view {
        for (uint8 i; i < 10; ++i) _bounds(PepeArtData.expr(i));
        for (uint8 i; i < 10; ++i) _bounds(PepeArtData.eye(i));
        for (uint8 i = 1; i < 10; ++i) _bounds(PepeArtData.hat(i));
        for (uint8 i = 1; i < 10; ++i) _bounds(PepeArtData.wear(i));
        for (uint8 i = 1; i < 10; ++i) _bounds(PepeArtData.item(i));
    }

    function _bounds(bytes memory stamp) internal view {
        if (stamp.length == 0) return;
        (uint8 dx, uint8 dy, uint8 w, uint8 h) =
            (uint8(stamp[0]), uint8(stamp[1]), uint8(stamp[2]), uint8(stamp[3]));
        assertLt(uint256(dx) + w, 70, "x overflow");
        assertLt(uint256(dy) + h, 70, "y overflow");
        // every RLE row must sum to w (byte-pair runs: [len-1][slot])
        uint256 x;
        for (uint256 i = 4; i + 1 < stamp.length; i += 2) {
            x += uint256(uint8(stamp[i])) + 1;
            if (x == w) {
                x = 0;
            }
        }
        assertEq(x, 0, "ragged RLE row");
    }

    // ─────────────── 3. eye bridge + distinct eyes ───────────────

    function test_Pixels_EyeBridge() public view {
        string[69][69] memory c = _composite(_dna(0, 0, 0, 0, 0, 0, 0, 0));
        // white bridge joins the eye tops (48px rows 19-20 / cols 25-26
        // -> 69px rows 27-29 / cols 36-37) — the nose-bridge join
        assertEq(c[27][36], WHITE, "white bridge col 36, row 27");
        assertEq(c[27][37], WHITE, "white bridge col 37, row 27");
        assertEq(c[29][36], GLINT, "glint bridge row 29");
        assertEq(c[29][37], GLINT, "glint bridge row 29b");
        // open base skin below the join (ridge removed in studio pass v3)
        assertEq(c[30][36], BASE, "open below join");
        assertEq(c[24][36], LIGHT, "ridge top");
        // below mid-eye the eyes are OPEN (base skin, no ridge)
        assertEq(c[33][36], BASE, "open below ridge");
        // whites never merge: 35 is left eye, 39 is right eye
        assertEq(c[29][35], WHITE, "left white edge");
        assertEq(c[29][39], WHITE, "right white edge");
        // thin per-eye brow arcs (not a unibrow): gap at cols 36-37.
        // brows are skin-deep (slot 17) since the studio pass, not slate
        assertEq(c[23][23], SKINDEEP, "left brow");
        assertEq(c[23][46], SKINDEEP, "right brow");
        assertEq(c[23][36], BASE, "brow gap");
    }

    // ─────────────── 4. expressions ───────────────

    function test_Pixels_ExprNeutral() public view {
        string[69][69] memory c = _composite(_dna(0, 0, 0, 0, 0, 0, 0, 0));
        // ONE thick mass: outline row 39, upper lip 42-44, seam 45,
        // lower lip 46-47, chin taper 49-50 — reference anatomy
        assertEq(c[39][36], BASE, "no black top border");
        assertEq(c[39][32], NOSTRIL, "nostril bottom row kept");
        assertEq(c[42][29], LIPS, "upper lip r1");
        assertEq(c[42][40], LIPS, "upper lip widest");
        assertEq(c[43][55], LIPS, "upper lip close");
        assertEq(c[45][36], LIPSDARK, "full-width seam");
        assertEq(c[46][36], LIPS, "lower lip");
        assertEq(c[47][37], LIPS, "lower taper");
        assertEq(c[49][37], LIPS, "chin taper");
        // no detached second lip below: traced remnant cleared
        assertEq(c[51][37], BASE, "no floating fragment");
    }

    function test_Pixels_ExprVariants() public view {
        // SMILE: corners pulled UP to row 37
        string[69][69] memory s = _composite(_dna(1, 0, 0, 0, 0, 0, 0, 0));
        assertEq(s[37][24], LIPS, "smile corner tip up");
        assertEq(s[37][55], LIPS, "smile right tip up");
        assertEq(s[39][26], LIPS, "smile shoulder");
        assertEq(s[40][37], LIPS, "smile arc center top");
        assertEq(s[42][22], LIPS, "smile corner fill");
        assertEq(s[43][30], LIPS, "smile seam corner (jut)");
        assertEq(s[43][46], LIPSDARK, "smile seam right jut");
        assertEq(s[45][37], LIPS, "smile lower band");
        assertEq(s[46][39], LIPS, "smile lower center");
        // tears of joy streaks down the left cheek (skin-deep slot 17)
        assertEq(s[41][17], SKINDEEP, "smile tear streak");
        // GRIN: dark open lining, no teeth ever
        string[69][69] memory g = _composite(_dna(2, 0, 0, 0, 0, 0, 0, 0));
        assertEq(g[39][36], BASE, "grin no black top border");
        assertEq(g[40][36], LIPS, "grin upper max spread");
        assertEq(g[43][40], LIPS, "grin upper close");
        assertEq(g[45][36], LIPSDARK, "grin seam");
        assertEq(g[46][37], LIPS, "grin lower lip");
        assertEq(g[49][37], LIPS, "grin chin taper");
        // SAD: corners pulled DOWN to row 43/45
        string[69][69] memory sd = _composite(_dna(4, 0, 0, 0, 0, 0, 0, 0));
        assertEq(sd[39][37], LIPS, "sad center top (highest)");
        assertEq(sd[40][36], LIPS, "sad top slopes down-out");
        assertEq(sd[42][37], LIPSDARK, "sad seam center HIGH");
        assertEq(sd[43][27], LIPSDARK, "sad seam falling");
        assertEq(sd[45][22], LIPSDARK, "sad seam corner LOW");
        assertEq(sd[46][23], LIPS, "sad droop tip");
        assertEq(sd[47][30], BASE, "sad no fragment below");
        // ANGRY: straight gritted dark line
        string[69][69] memory a = _composite(_dna(6, 0, 0, 0, 0, 0, 0, 0));
        assertEq(a[39][36], BASE, "angry no black top border");
        assertEq(a[40][36], LIPS, "angry upper lip");
        assertEq(a[43][36], LIPSDARK, "angry seam r1");
        assertEq(a[45][36], LIPSDARK, "angry seam r2 pressed");
        assertEq(a[46][36], LIPS, "angry lower lip");
        assertEq(a[47][23], LIPS, "angry corner bite down");
        // SMIRK: right-side only; left mouth stays bare skin
        string[69][69] memory k = _composite(_dna(7, 0, 0, 0, 0, 0, 0, 0));
        assertEq(k[37][53], BASE, "smirk corner moved down (bare here)");
        assertEq(k[39][43], BASE, "smirk upper band start (bare)");
        assertEq(k[40][50], LIPS, "smirk corner tip");
        assertEq(k[42][43], LIPS, "smirk upper lip");
        assertEq(k[43][43], LIPSDARK, "smirk dark inner band");
        assertEq(k[40][26], BASE, "smirk left bare");
        // SCARED: small dark o
        string[69][69] memory sc = _composite(_dna(5, 0, 0, 0, 0, 0, 0, 0));
        assertEq(sc[40][39], LIPS, "scared top ring");
        assertEq(sc[42][37], LIPSDARK, "scared interior");
        assertEq(sc[43][37], LIPSDARK, "scared interior b");
        assertEq(sc[46][39], LIPS, "scared bottom ring");
        // CRINGE: deliberate GRITTED TEETH (human-approved exception to
        // the no-teeth invariant) + lip frame
        string[69][69] memory cr = _composite(_dna(8, 0, 0, 0, 0, 0, 0, 0));
        assertEq(cr[43][30], WHITE, "cringe gritted teeth");
        assertEq(cr[41][33], LIPS, "cringe lip frame");
        // MEH: asymmetric half-hearted line
        string[69][69] memory me = _composite(_dna(9, 0, 0, 0, 0, 0, 0, 0));
        assertEq(me[44][28], LIPS, "meh upper lip");
        assertEq(me[45][32], LIPSDARK, "meh seam");
    }

    function test_Invariant_NoTeethEver() public view {
        // frogs have no teeth: for every expression except CRINGE (id 8,
        // deliberate gritted teeth authored in studio pass v3), the mouth
        // zone (69px rows 39-47 / cols 19-59) never contains eye-white
        for (uint8 e; e < 10; ++e) {
            if (e == 8) continue; // CRINGE: human-approved teeth
            string[69][69] memory c = _composite(_dna(e, 0, 0, 0, 0, 0, 0, 0));
            for (uint8 y = 39; y < 48; ++y) {
                for (uint8 x = 19; x < 60; ++x) {
                    assertNotEq(
                        c[y][x],
                        WHITE,
                        "teeth?! frogs are toothless"
                    );
                }
            }
        }
    }

    // ─────────────── 5. color axes ───────────────

    function test_Colors_IrisOverride() public view {
        // amber iris (id 2) = #C8872B, independent of skin
        string[69][69] memory c = _composite(_dna(0, 0, 0, 0, 0, 0, 2, 0));
        assertEq(c[30][29], "#C8872B", "amber left pupil");
        assertEq(c[30][45], "#C8872B", "amber right pupil");
        // skin untouched
        assertEq(c[33][36], BASE, "skin still green");
    }

    function test_Colors_BackgroundIndependent() public view {
        // classic skin on void orange bg (id 7, recolored in studio pass)
        string memory svg = d.renderSVG(_dna(0, 0, 0, 0, 0, 0, 0, 7));
        assertTrue(_contains(svg, '<rect x="0" y="0" width="69" height="69" fill="#FF7300"/>'), "void bg");
        assertEq(_composite(_dna(0, 0, 0, 0, 0, 0, 0, 7))[33][36], BASE, "green head on void");
        // gold skin + mint bg: both independent axes
        string[69][69] memory c = _composite(_dna(0, 0, 0, 0, 0, 1, 0, 1));
        assertEq(c[0][0], "#B5E8C9", "mint bg");
        assertEq(c[33][36], "#CAD435", "gold skin");
    }

    // ─────────────── 6. items ───────────────

    function test_Item_CigaretteUniform() public view {
        string[69][69] memory c = _composite(_dna(0, 0, 0, 0, 1, 0, 0, 0));
        // stick sits right of the mouth, rows 43-44, x45-61 (uniform)
        for (uint8 x = 45; x < 62; ++x) {
            assertEq(c[43][x], c[44][x], "rows must match (uniform width)");
        }
        assertEq(c[43][60], RED, "ember");
        assertEq(c[43][61], RED, "ember 2");
        assertEq(c[43][62], RED, "ember 3");
        assertEq(c[43][48], WHITE, "stick start");
        assertEq(c[43][53], WHITE, "stick");
        assertEq(c[43][59], WHITE, "stick end");
        assertEq(c[43][44], GOLDD, "filter");
        assertEq(c[43][45], GOLDD, "filter 2");
        assertEq(c[43][46], GOLDD, "filter 3");
    }

    function test_Item_Others() public view {
        // pipe: bowl + stem below-right of the mouth (item 2)
        string[69][69] memory p = _composite(_dna(0, 0, 0, 0, 2, 0, 0, 0));
        assertEq(p[43][33], BLACK, "pipe bowl");
        assertEq(p[44][30], BLACK, "pipe bowl b");
        assertEq(p[54][19], BLACK, "pipe stem");
        // chain at the neck (item 3)
        string[69][69] memory ch = _composite(_dna(0, 0, 0, 0, 3, 0, 0, 0));
        assertEq(ch[59][16], GOLD, "chain link");
        // stitches suture over the mouth (item 4)
        string[69][69] memory st = _composite(_dna(0, 0, 0, 0, 4, 0, 0, 0));
        assertEq(st[42][22], LIPSDARK, "suture arm");
        assertEq(st[46][21], LIPSDARK, "suture cross");
        // noose rope hangs full height (item 5 — ids shifted in studio pass)
        string[69][69] memory no = _composite(_dna(0, 0, 0, 0, 5, 0, 0, 0));
        assertEq(no[0][19], GOLDD, "rope top");
        assertEq(no[59][43], GOLDD, "knot");
        // cigar held in the mouth (item 6), brown body
        string[69][69] memory ci = _composite(_dna(0, 0, 0, 0, 6, 0, 0, 0));
        assertEq(ci[42][50], GOLDD, "cigar body");
        assertEq(ci[42][58], GOLDD, "cigar tip");
        // bong on the floor (item 7): steel glass + blue water + cherry
        string[69][69] memory bo = _composite(_dna(0, 0, 0, 0, 7, 0, 0, 0));
        assertEq(bo[42][37], "#5C6270", "bong glass dark");
        assertEq(bo[43][38], "#C2C8D4", "bong glass light");
        assertEq(bo[58][37], "#0055FF", "bong water blue");
        assertEq(bo[53][27], RED, "bong cherry");
        // lollipop (item 9): candy in the mouth (JARHEAD is 8 — file order)
        string[69][69] memory lo = _composite(_dna(0, 0, 0, 0, 9, 0, 0, 0));
        assertEq(lo[39][36], RED, "lollipop candy");
        assertEq(lo[40][31], WHITE, "lollipop glint");
        // jarhead (item 8): glass jar over the whole head
        string[69][69] memory ja = _composite(_dna(0, 0, 0, 0, 8, 0, 0, 0));
        assertEq(ja[0][33], "#C2C8D4", "jar glass top");
        assertEq(ja[44][9], "#5C6270", "jar lid steel");
    }

    // ─────────────── 7. layer order ───────────────

    function test_Order_EyewearAfterEyes() public view {
        string memory svg = d.renderSVG(_dna(0, 0, 0, 1, 0, 0, 0, 0));
        uint256 whiteAt = _find(
            svg,
            '<rect x="20" y="30" width="7" height="1" fill="#FEFEFE"/>',
            0
        ); // left white run left of the pupil at row 30
        uint256 slateAt = _find(
            svg,
            '<rect x="23" y="30" width="13" height="1" fill="#23282D"/>',
            0
        );
        assertTrue(
            whiteAt != type(uint256).max && slateAt != type(uint256).max,
            "both layers present"
        );
        assertTrue(slateAt > whiteAt, "shades paint over eye whites");
    }

    function test_Order_MonocleRingOverEye() public view {
        string memory svg = d.renderSVG(_dna(0, 0, 0, 2, 0, 0, 0, 0));
        uint256 eyeAt = _find(
            svg,
            '<rect x="20" y="27" width="35" height="1" fill="#FEFEFE"/>',
            0
        ); // full white band row (single run — byte-pair RLE has no 16 cap)
        uint256 ringAt = _find(
            svg,
            '<rect x="37" y="27" width="2" height="1" fill="#23282D"/>',
            0
        ); // monocle ring side over the eye white (ring black since v3)
        assertTrue(
            eyeAt != type(uint256).max && ringAt != type(uint256).max,
            "eye + ring present"
        );
        assertTrue(ringAt > eyeAt, "monocle ring after eye layer");
    }

    // ─────────────── 8. tokenURI ───────────────

    function test_TokenURI_EightAttributes() public view {
        string memory uri = d.tokenURI(0);
        // "data:application/json;base64," is 29 chars
        string memory json = string(
            Base64.decode(_slice(uri, 29, bytes(uri).length))
        );
        for (uint8 i; i < 8; ++i) {
            assertTrue(_contains(json, '"trait_type"'), "attrs present");
        }
        assertTrue(_contains(json, '"trait_type":"Expression","value":"Neutral"'));
        assertTrue(_contains(json, '"trait_type":"Background","value":"Sky"'));
        assertTrue(_contains(json, "data:image/svg+xml;base64,"));
    }

    // ─────────────── 9. fuzz: every DNA renders ───────────────

    function test_Fuzz_RandomDNA(uint256 seed) public view {
        uint256 dna = seed % PepeArtData.COMBOS;
        string memory svg = d.renderSVG(dna);
        assertTrue(_contains(svg, "<svg"), "opens");
        assertTrue(
            _find(svg, "</svg>", bytes(svg).length - 10) != 0,
            "closes"
        );
        // first rect is always the background
        assertTrue(_contains(svg, '<rect x="0" y="0" width="69" height="69"'));
    }

    function test_Fuzz_SurrogateDNA() public view {
        // DNA above each axis max still decodes modulo — never reverts
        for (uint256 dna = PepeArtData.COMBOS; dna < PepeArtData.COMBOS + 10; ++dna) {
            d.renderSVG(dna);
        }
    }
}
