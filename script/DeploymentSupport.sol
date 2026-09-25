// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {PSPFactory} from "../src/PSPFactory.sol";
import {PSPToken} from "../src/PSPToken.sol";
import {PSPStaker} from "../src/PSPStaker.sol";
import {PSPReferralRegistry} from "../src/PSPReferralRegistry.sol";
import {PSPZapIn} from "../src/PSPZapIn.sol";
import {PSPZapOut} from "../src/PSPZapOut.sol";
import {CurveHook} from "../src/CurveHook.sol";
import {CurveMath} from "../src/libraries/CurveMath.sol";

import {Greenlist} from "../test/helpers/Greenlist.sol";
import {Curve1Zones} from "../src/curves/Curve1Zones.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title DeploymentSupport
/// @notice Shared release configuration and read-only checks before broadcasts.
abstract contract DeploymentSupport is Script {
    address internal constant BASE_SEPOLIA_PM = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    // Reservation mining uses fresh block entropy, so a successful simulation's
    // gas usage is not a bound for the actual transaction. Leave room for the
    // factory's 131,072-candidate scan while staying below Base Sepolia's cap.
    uint256 internal constant GENESIS_RESERVATION_GAS = 15_000_000;

    function _validateModes(bool anvil, bool testnet) internal view {
        require(!(anvil && testnet), "PSP_ANVIL conflicts with PSP_TESTNET");
        if (anvil) require(block.chainid == 31337, "mock deployment requires local chain 31337");
    }

    function _validatePoolManager(address pm, bool testnet) internal view {
        if (testnet) {
            require(block.chainid == 84532, "testnet deployment requires Base Sepolia 84532");
            require(pm == BASE_SEPOLIA_PM, "wrong Base Sepolia PoolManager");
        }
        require(pm.code.length != 0, "PoolManager has no code");
    }

    /// @dev Greenlist-IBCO (rules v3): packed slot [0] is the GREEN window
    ///      (PSP_GREEN_SEC, default 1 day); the open window rides the
    ///      factory's openWindowSec (PSP_OPEN_SEC, wired by DeployPSP).
    ///      The old PSP_PREDEPOSIT_SEC knob is RETIRED — setting it fails
    ///      loudly instead of silently shaping a different window.
    function _testnetTimings() internal view returns (uint256) {
        require(
            bytes(vm.envOr("PSP_PREDEPOSIT_SEC", string(""))).length == 0,
            "PSP_PREDEPOSIT_SEC is retired under predeposit rules v3 (use PSP_GREEN_SEC)"
        );
        return CurveMath.packTimingsCapped(
            vm.envOr("PSP_GREEN_SEC", uint256(1 days)),
            vm.envOr("PSP_VEST_SEC", uint256(28 days)),
            vm.envOr("PSP_DET_SEC", uint256(69 hours + 4 minutes + 20 seconds)),
            vm.envOr("PSP_WALLET_CAP_MIX", uint256(0))
        );
    }

    /// @dev The csv greenlist env (rules v3): one address per line, blank
    ///      lines skipped. Returns (0, 0) when PSP_GREEN_CSV is unset —
    ///      the csv is the OPTIONAL half of the next round's greenlist;
    ///      previous-round PSP holders are the trustless other half.
    ///      The tree format is pinned by RoundController._greenlisted and
    ///      mirrored byte-for-byte by test/helpers/Greenlist.sol:
    ///        leaf   = keccak256(abi.encodePacked(account))
    ///        parent = keccak256(left < right ? (left,right) : (right,left))
    ///      with odd levels duplicate-padded (a lone entry pads to [a,a]).
    function _greenCsv() internal view returns (bytes32 root, uint256 count) {
        string memory path = vm.envOr("PSP_GREEN_CSV", string(""));
        if (bytes(path).length == 0) return (0, 0);
        string[] memory lines = vm.split(vm.readFile(path), "\n");
        address[] memory found = new address[](lines.length);
        for (uint256 i; i < lines.length; ++i) {
            string memory line = _trimLine(lines[i]);
            if (bytes(line).length == 0) continue;
            found[count++] = vm.parseAddress(line);
        }
        if (count == 0) return (0, 0);
        address[] memory csv = new address[](count);
        for (uint256 i; i < count; ++i) csv[i] = found[i];
        root = Greenlist.rootOf(csv);
    }

    /// @dev Strip the whitespace a hand-edited csv line can carry (\r\n
    ///      line endings, stray spaces/tabs) so parseAddress sees the hex.
    function _trimLine(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 start;
        uint256 end = b.length;
        while (start < end && _ws(b[start])) ++start;
        while (end > start && _ws(b[end - 1])) --end;
        bytes memory t = new bytes(end - start);
        for (uint256 i; i < t.length; ++i) t[i] = b[start + i];
        return string(t);
    }

    function _ws(bytes1 c) private pure returns (bool) {
        return c == " " || c == "\t" || c == "\r" || c == "\n";
    }

    function _htmlPath(bool testnet) internal view returns (string memory) {
        return vm.envOr("PSP_HTML", testnet ? string("script/testnet-status.html") : string("script/app.html"));
    }

    function _validateFactory(PSPFactory factory, bool testnet) internal view {
        require(address(factory).code.length != 0, "factory has no code");
        _validatePoolManager(address(factory.poolManager()), testnet);
        require(address(factory.mixETH()).code.length != 0, "mixETH has no code");
        require(factory.descriptor().code.length != 0, "factory descriptor missing");
        require(factory.useSine(), "factory sine configuration missing");
    }

    /// @dev Resume from the deployed factory's timing profile and current phase.
    /// Never re-reserve a partially completed genesis or repeat a finished step.
    function _completeGenesis(PSPFactory factory) internal {
        if (factory.currentRoundId() != 0) return;
        if (!factory.reservationActive()) {
            require(factory.owner() == msg.sender, "genesis reservation requires factory owner");
            CurveMath.CurveConfig memory config = Curve1Zones.config();
            config.timings = factory.roundTimings();
            vm.startBroadcast(msg.sender);
            factory.reserveGenesis{gas: GENESIS_RESERVATION_GAS}(PSPFactory.RoundParams({
                name: "Positive Sum Pepes", symbol: "PSP", curveConfig: config
            }));
            vm.stopBroadcast();
        }
        for (uint256 i; i < 3 && factory.currentRoundId() == 0; ++i) {
            vm.startBroadcast(msg.sender);
            factory.birthStep();
            vm.stopBroadcast();
        }
        require(factory.currentRoundId() == 1 && !factory.reservationActive(), "genesis birth incomplete");
    }

    function _validateZapIn(address zap, PSPFactory factory) internal view {
        require(zap.code.length != 0, "ZapIn has no code");
        require(address(PSPZapIn(zap).mixETH()) == address(factory.mixETH()), "ZapIn mixETH mismatch");
        require(address(PSPZapIn(zap).poolManager()) == address(factory.poolManager()), "ZapIn PoolManager mismatch");
        // AUD-14 compatibility probe. A zero trader reverts before token access.
        // This checks the owner-attribution API, not executable source identity.
        PoolKey memory key;
        (bool ok, bytes memory result) = zap.staticcall(abi.encodeCall(
            PSPZapIn.buyWithMixFor, (key, 0, 0, 0, address(0))
        ));
        require(!ok && keccak256(result) == keccak256(abi.encodeWithSelector(PSPZapIn.ZeroTrader.selector)),
            "ZapIn owner attribution unavailable");
    }

    function _validateZapOut(address zap, PSPFactory factory) internal view {
        require(zap.code.length != 0, "ZapOut has no code");
        require(address(PSPZapOut(payable(zap)).mixETH()) == address(factory.mixETH()), "ZapOut mixETH mismatch");
        require(address(PSPZapOut(payable(zap)).poolManager()) == address(factory.poolManager()), "ZapOut PoolManager mismatch");
    }

    function _validateCurrentRound(PSPFactory factory, uint256 roundId) internal view returns (PSPFactory.Round memory r) {
        require(roundId != 0 && roundId == factory.currentRoundId(), "select the completed current round");
        require(!factory.reservationActive(), "finish reserved birth first");
        r = factory.getRound(roundId);
        require(address(r.controller).code.length != 0 && address(r.hook).code.length != 0
            && address(r.token).code.length != 0, "round code missing");
        require(!r.destroyed && uint8(r.hook.mode()) < uint8(CurveHook.Mode.Flat), "round already settled");
        require(r.controller.factory() == address(factory) && r.controller.factoryRoundId() == roundId,
            "controller factory mismatch");
        require(r.controller.getPSP() == address(r.token) && address(r.controller.mixETH()) == address(factory.mixETH()),
            "controller token mismatch");
        require(r.controller.hookAddress() == address(r.hook) && address(r.hook.controller()) == address(r.controller)
            && r.token.controller() == address(r.controller), "round wiring mismatch");
        require(address(r.hook.poolManager()) == address(factory.poolManager()), "hook PoolManager mismatch");
        // v3 game rules: the minimum IS the live ticket price (both read the
        // same pot), tickets are pot-priced, and the round's hook is pinned
        // to the factory's exact settlement helper.
        require(r.hook.TICKET_RULES_VERSION() == 3 && r.hook.SINE_RULES_VERSION() == 3
            && r.hook.MIN_BUY_INPUT() == r.hook.ticketPrice() && r.hook.TIME_PER_UNIT() == 69,
            "game rules mismatch");
        require(r.hook.sineV3Table() == factory.sineV3Table() && r.hook.sinePL() == factory.gameSinePL(),
            "sine v3 helper or launch price mismatch");
        // Greenlist-IBCO rules v3: version, both windows, and the greenlist
        // sizing must match the deploy env exactly (GREEN_DURATION rides
        // packed slot [0] = PSP_GREEN_SEC on the testnet profile; the
        // mainnet timings==0 default is 1 day = the env default, so a
        // mainnet deploy that sets PSP_GREEN_SEC fails loudly here —
        // the knob is testnet-profile-only).
        require(r.controller.PREDEPOSIT_RULES_VERSION() == 3 && r.controller.PREDEPOSIT_CAP() == 1000 ether,
            "predeposit rules mismatch");
        require(
            r.controller.GREEN_DURATION() == vm.envOr("PSP_GREEN_SEC", uint256(1 days))
                && r.controller.OPEN_DURATION() == vm.envOr("PSP_OPEN_SEC", uint256(1 days)),
            "green/open window mismatch"
        );
        // Greenlist sizing: N = csv entries + previous-round holders (0 on
        // genesis). N == 0 disables the green phase; otherwise the cap is
        // 500 mixETH / N exactly as the controller computes it at birth.
        (, uint256 csvCount) = _greenCsv();
        PSPToken prevToken = r.controller.PREV_TOKEN();
        uint256 n = csvCount + (address(prevToken) == address(0) ? 0 : prevToken.holderCount());
        require(r.controller.GREEN_PER_WALLET() == (n == 0 ? 0 : 500 ether / n), "greenlist sizing mismatch");
        require(r.controller.OPEN_PER_WALLET() == 10 ether, "open per-wallet cap mismatch");
        PSPStaker staker = r.controller.staker();
        require(address(staker).code.length != 0 && address(staker.controller()) == address(r.controller)
            && address(staker.psp()) == address(r.token), "staker wiring mismatch");
        // Fresh deploys carry ON-CHAIN ART RELEASE 3 (420 edition): the
        // staker freezes its descriptor's ART_VERSION, so PEPE_DNA_VERSION 3
        // proves both the v3 descriptor and the matching collision codec.
        require(staker.NFT_INTERFACE_VERSION() == 1 && staker.PEPE_DNA_VERSION() == 3
            && staker.supportsInterface(0x80ac58cd), "NFT capabilities missing");
        require(staker.descriptor() == factory.descriptor(), "staker descriptor mismatch");
        PSPReferralRegistry registry = PSPReferralRegistry(factory.referralRegistryOf(roundId));
        require(address(registry).code.length != 0 && address(registry) == address(r.hook.referralRegistry())
            && address(registry.staker()) == address(staker), "referral wiring mismatch");
        require(registry.PURCHASE_REFERRAL_VERSION() == 1, "atomic referral purchases missing");
    }

    function _roundParams(uint256 timings) internal pure returns (PSPFactory.RoundParams memory) {
        // Sine-only (scoopy 2026-08-30): the zone config is creation-code
        // SHAPE — the armed sine overrides all zone pricing at launch. The
        // 1-zone shape is the smallest legal config, keeping the staged
        // create2 initcodes (and birth gas) lean.
        CurveMath.CurveConfig memory cc = Curve1Zones.config();
        cc.timings = timings;
        return PSPFactory.RoundParams({
            name: "Positive Sum Pepes",
            symbol: "PSP",
            curveConfig: cc
        });
    }

    /// @dev Sine rules v3 (2026-09-14): one continuous curve; the only
    ///      deployment knob left is the launch spot price P_L (default
    ///      0.000075 mixETH/PSP). The v2 overrides are RETIRED — setting
    ///      any of them fails loudly instead of being silently ignored.
    function _sinePL() internal view returns (uint128) {
        string[5] memory retired = [
            "PSP_SINE_P0",
            "PSP_SINE_PREK",
            "PSP_SINE_PTARGET",
            "PSP_SINE_TARGET_RESERVE",
            "PSP_SINE_AMPBPS"
        ];
        for (uint256 i; i < retired.length; ++i) {
            require(bytes(vm.envOr(retired[i], string(""))).length == 0,
                string.concat(retired[i], " is retired under sine rules v3"));
        }
        uint256 pL = vm.envOr("PSP_SINE_PL", uint256(75_000_000_000_000)); // 0.000075
        require(pL >= 1e9 && pL <= 1e18, "PSP_SINE_PL out of bounds");
        return uint128(pL);
    }
}
