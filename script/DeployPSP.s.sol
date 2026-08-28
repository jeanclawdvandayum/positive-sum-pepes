// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {PSPFactory} from "../src/PSPFactory.sol";
import {HookDeployer} from "../src/HookDeployer.sol";
import {ControllerDeployer} from "../src/ControllerDeployer.sol";
import {CurveMath} from "../src/libraries/CurveMath.sol";
import {LinearZones} from "../src/curves/LinearZones.sol";
import {LinearZonesLean} from "../src/curves/LinearZonesLean.sol";
import {Curve1Zones} from "../src/curves/Curve1Zones.sol";
import {Curve2Zones} from "../src/curves/Curve2Zones.sol";
import {Curve3Zones} from "../src/curves/Curve3Zones.sol";
import {PepeDescriptor} from "../src/PepeDescriptor.sol";
import {PSPZapIn} from "../src/PSPZapIn.sol";
import {PSPZapOut} from "../src/PSPZapOut.sol";
import {PSPReinvestor} from "../src/PSPReinvestor.sol";
import {IPSPStaker} from "../src/interfaces/IPSPStaker.sol";
import {IPSPZapIn} from "../src/interfaces/IPSPZapIn.sol";
import {IMixETH} from "../src/interfaces/IMixETH.sol";
import {SepoliaMixETH} from "../src/testnet/SepoliaMixETH.sol";
import {MixETHFaucet} from "../src/testnet/MixETHFaucet.sol";

import {MockMixETH} from "../test/mocks/MockMixETH.sol";
import {MockPoolManager} from "../test/mocks/MockPoolManager.sol";
import {StakerDeployer} from "../src/StakerDeployer.sol";


/// @title DeployPSP — genesis deployment with the anchor-ladder curve
/// @notice Deploys the factory, round 1 ("Positive Sum Pepes" / PSP), and
///         publishes the walk-away UI via factory.setHtml(). The UI source is
///         script/app.html with __FACTORY__ substituted for the real address.
///
///         The curve is the anchor-ladder solve (scoopy anchors 2026-08-19):
///         one price decade per x4 reserve — 2k/8k/32k/128k mixETH at
///         0.001/0.01/0.1/1, P0=0.0001. 16 S-legs (4+4x3), uniform lift
///         Q=10^(1/4)=1.778 per leg, cliffs 1.40→1.77, islands 35% of every
///         span, 34 zones. Zone ints are GENERATED into
///         src/curves/LinearZones.sol by ~/clawd/psp-linear.py (which also
///         forge-verifies them against CurveMath) — regenerate there, don't
///         hand-edit.
///
/// Env:
///   PSP_PM       pool manager (default: Base mainnet v4; REQUIRED with PSP_TESTNET)
///   PSP_MIXETH   mixETH token (required unless PSP_ANVIL/PSP_TESTNET)
///   PSP_HTML     ui file (default: script/app.html)
///   PSP_ANVIL    =1 to deploy MockMixETH+MockPoolManager first (local e2e)
///   PSP_TESTNET  =1 to deploy SepoliaMixETH (dumb 1:1, no yield) +
///                MixETHFaucet (0.0001 ETH -> 100 mixETH) against a
///                canonical v4 testnet PoolManager + playtest timing
///                profile (24h predeposit offer, 2d unstake vest decaying
///                in 6 × 8h epochs, 1d bomb vote; flat exit 3d — all
///                three tunable in seconds: PSP_PREDEPOSIT_SEC /
///                PSP_VEST_SEC / PSP_VOTE_SEC, vest % 6 == 0)
///   PSP_FORK     =1 to vm.deal the broadcaster 5 ETH first — lets you
///                dry-run the FULL testnet path (PSP_TESTNET + PSP_PM +
///                --fork-url $SEPOLIA_RPC_URL) with any throwaway key and
///                zero gas. Never set this for a real deployment.
///   PSP_CURVE    0|1|2|3 rolling curves (staircase/glide/longswell/switchback)
///                4 = minimal 2-zone S-curve (the ONLY one that fits Ethereum
///                Sepolia's 2^24 = 16.7M per-tx cap: deployRound floor is
///                ~12.6M fixed + ~600k/zone + on-chain mining luck)
///                5 = LEAN anchor-ladder staircase (10 zones, ~17.5M floor —
///                fits OP-stack testnets like Base Sepolia's 1.2B block limit
///                but NOT Ethereum Sepolia; kept for mid-cap chains)
///                0 = the canonical 34-zone anchor-ladder staircase (27.5M —
///                mainnet or OP-stack testnets only; rebirth spawnNextRound
///                is single-tx so over-cap curves can never be reborn)
///   testnet default: 4 (safe everywhere). For Base Sepolia round 2 set
///   PSP_CURVE=0 explicitly for the full staircase.
contract DeployPSP is Script {
    // Base mainnet Uniswap v4 PoolManager
    address constant PM_BASE = 0x498581fF718922c3f8e6A244956aF099B2652b2b;

    // Official v4 testnet PoolManagers (Uniswap deployments feed, verified
    // on-chain 2026-08-18 via eth_getCode — 24009 bytes each)
    address constant PM_SEPOLIA = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;      // 11155111
    address constant PM_BASE_SEPOLIA = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408; // 84532
    address constant PM_ARB_SEPOLIA = 0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317;  // 421614
    address constant PM_UNICHAIN_SEPOLIA = 0x9cB26A7183B2F4515945Dc52CB4195B0d2D06C95; // 1301

    /// @dev Packed playtest timing profile (see RoundController "Timing
    ///      profile"): predeposit window · unstake vest · bomb vote, all
    ///      env-tunable IN SECONDS for granularity (PSP_PREDEPOSIT_SEC /
    ///      PSP_VEST_SEC / PSP_VOTE_SEC; defaults 1d / 2d / 1d). VEST must
    ///      be divisible by 6 — six decay epochs (packTimings guards).
    ///      Flat exit: constant 3d.
    function _testnetTimings() internal view returns (uint256) {
        return CurveMath.packTimings(
            vm.envOr("PSP_PREDEPOSIT_SEC", uint256(1 days)),
            vm.envOr("PSP_VEST_SEC", uint256(2 days)),
            vm.envOr("PSP_VOTE_SEC", uint256(1 days))
        );
    }

    function run() external {
        bool anvil = vm.envOr("PSP_ANVIL", false);
        bool testnet = vm.envOr("PSP_TESTNET", false);
        if (vm.envOr("PSP_FORK", false)) {
            vm.deal(msg.sender, 5 ether); // fork dry-run gas (see env docs)
        }
        address pm;
        IERC20 mix;
        if (anvil) {
            vm.startBroadcast();
            MockPoolManager mockPM = new MockPoolManager();
            MockMixETH mockMix = new MockMixETH();
            vm.stopBroadcast();
            pm = address(mockPM);
            mix = IERC20(address(mockMix));
            console.log("ANVIL mock mixETH:", address(mockMix));
        } else if (testnet) {
            // Canonical v4 PoolManager of the target testnet — no default:
            // pass PSP_PM explicitly (constants above for copy-paste).
            pm = vm.envAddress("PSP_PM");
            vm.startBroadcast();
            // Dumb 1:1 wrapper (no yield, no admin) + subsidized faucet:
            // the constructor mints 10M mixETH to the broadcaster, which
            // seeds the faucet in full — testers pay 0.0001 ETH per 100.
            SepoliaMixETH mixT = new SepoliaMixETH();
            MixETHFaucet faucet = new MixETHFaucet(IERC20(address(mixT)));
            mixT.transfer(address(faucet), mixT.balanceOf(msg.sender));
            vm.stopBroadcast();
            mix = IERC20(address(mixT));
            console.log("TESTNET PoolManager:", pm);
            console.log("TESTNET mixETH (1:1, no yield):", address(mixT));
            console.log("TESTNET faucet (0.0001 ETH -> 100 mix):", address(faucet));
        } else {
            pm = vm.envOr("PSP_PM", PM_BASE);
            mix = IERC20(vm.envAddress("PSP_MIXETH"));
        }
        string memory htmlPath = vm.envOr("PSP_HTML", string("script/app.html"));

        // Sepolia blocks cap at 60M gas and providers cap per-tx lower still
        // (alchemy ~15M, publicnode 2^24) — the deploy as ONE tx measured
        // 19.6M on this branch and is unsendable. Split into per-broadcast
        // segments so forge sends separate txs (owner stays the broadcaster).
        vm.startBroadcast();
        PSPFactory factory = new PSPFactory(
            IPoolManager(pm), mix, new HookDeployer(), new ControllerDeployer(), new StakerDeployer(), testnet ? _testnetTimings() : 0
        );

        // wire the on-chain pepe art FIRST — it's global on the factory and
        // every round's staker is born with it (rides deployController's
        // raw-calldata passthrough). Factory owner == this broadcaster.
        PepeDescriptor descriptor = new PepeDescriptor();
        factory.setDescriptor(address(descriptor));
        vm.stopBroadcast();

        vm.startBroadcast();
        (uint256 roundId, address hookAddr) = factory.deployRound(_roundParams(testnet));
        vm.stopBroadcast();

        // publish the walk-away UI (fetch factory.html() from any rpc)
        string memory h = vm.readFile(htmlPath);
        h = vm.replace(h, "__FACTORY__", vm.toString(address(factory)));
        vm.startBroadcast();
        factory.setHtml(h);
        vm.stopBroadcast();

        // quality-of-life routers: ETH <-> PSP round trip
        vm.startBroadcast();
        PSPZapIn zapIn = new PSPZapIn(IMixETH(address(mix)), IPoolManager(pm));
        PSPZapOut zapOut = new PSPZapOut(IMixETH(address(mix)), IPoolManager(pm));
        // claim-and-compound router: fees -> curve buy -> back into the stake
        PSPFactory.Round memory r = factory.getRound(roundId);
        PSPReinvestor reinvestor =
            new PSPReinvestor(IPSPStaker(r.controller.stakerAddress()), IPSPZapIn(address(zapIn)), IERC20(address(mix)), IERC20(address(r.token)));
        vm.stopBroadcast();

        console.log("factory:", address(factory));
        console.log("round 1 id:", roundId);
        console.log("hook:", hookAddr);
        console.log("zapIn:", address(zapIn));
        console.log("zapOut:", address(zapOut));
        console.log("reinvestor:", address(reinvestor));
        console.log("ui bytes:", bytes(h).length);
    }

    function _roundParams(bool testnet) internal view returns (PSPFactory.RoundParams memory) {
        uint256 curveSel = vm.envOr("PSP_CURVE", testnet ? uint256(4) : uint256(1));
        CurveMath.CurveConfig memory cc = curveSel == 0
            ? LinearZones.config()
            : curveSel == 2 ? Curve2Zones.config()
            : curveSel == 3 ? Curve3Zones.config()
            : curveSel == 4 ? _playtestCurve()
            : curveSel == 5 ? LinearZonesLean.config()
            : Curve1Zones.config();
        cc.timings = testnet ? _testnetTimings() : 0; // anvil/mainnet: mainnet defaults
        return PSPFactory.RoundParams({
            name: "Positive Sum Pepes",
            symbol: "PSP",
            curveConfig: cc
        });
    }

    /// @dev PSP_CURVE=4 — minimal 2-zone S-curve for gas-capped testnets.
    ///      Sepolia enforces a network-wide per-tx cap of 2^24 = 16,777,216
    ///      gas (every major EL client); the full curves' deployRound runs
    ///      17.4M+ and is unmineable there. Two zones fit with headroom.
    ///      Shape: e^7 (≈1096x price run) across the first 3.5M PSP — the
    ///      widest legal exp leg (k·width = 7 WAD, the NK24 bound) — then a
    ///      gentle log tail. Mechanics (vest, votes, referrals, bombs) are
    ///      identical; only the curve shape is simpler.
    function _playtestCurve() internal pure returns (CurveMath.CurveConfig memory) {
        uint256[] memory b = new uint256[](2);
        b[0] = 0;
        b[1] = 3_500_000e18;
        uint256[] memory r = new uint256[](2);
        r[0] = 2_000_000_000_000; // k = 2e-6 → k·width = 7e18 exactly
        r[1] = 250_000_000_000_000_000; // log tail, same rate as longswell's islands
        bool[] memory e = new bool[](2);
        e[0] = true;
        e[1] = false;
        return CurveMath.multiCurve(100000000000000, b, r, e); // P0 = 1e-4, matches the real curves
    }
}
