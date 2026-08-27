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
///                profile (24h predeposit offer, 2d stake lock, +1d
///                relock extend, 1d relock window, 1d bomb vote;
///                flat exit 3d)
///   PSP_FORK     =1 to vm.deal the broadcaster 5 ETH first — lets you
///                dry-run the FULL testnet path (PSP_TESTNET + PSP_PM +
///                --fork-url $SEPOLIA_RPC_URL) with any throwaway key and
///                zero gas. Never set this for a real deployment.
///   PSP_CURVE    1|2|3 rolling curves (glide/longswell/switchback,
///                default 1); 0 = legacy anchor-ladder staircase
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
    ///      profile"): 24h predeposit offer · 6h vest (compressed decay for
    ///      playtest visibility; mainnet default is 42 days) · 1d bomb vote.
    ///      Flat exit: constant 3d. Packs via CurveMath.packTimings.
    function _testnetTimings() internal pure returns (uint256) {
        return CurveMath.packTimings(1 days, 6 hours, 1 days);
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

        vm.startBroadcast();
        PSPFactory factory = new PSPFactory(
            IPoolManager(pm), mix, new HookDeployer(), new ControllerDeployer(), new StakerDeployer(), testnet ? _testnetTimings() : 0
        );

        // wire the on-chain pepe art FIRST — it's global on the factory and
        // every round's staker is born with it (rides deployController's
        // raw-calldata passthrough). Factory owner == this broadcaster.
        PepeDescriptor descriptor = new PepeDescriptor();
        factory.setDescriptor(address(descriptor));

        (uint256 roundId, address hookAddr) = factory.deployRound(_roundParams(testnet));

        // publish the walk-away UI (fetch factory.html() from any rpc)
        string memory h = vm.readFile(htmlPath);
        h = vm.replace(h, "__FACTORY__", vm.toString(address(factory)));
        factory.setHtml(h);

        // quality-of-life routers: ETH <-> PSP round trip
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
        uint256 curveSel = vm.envOr("PSP_CURVE", uint256(1));
        CurveMath.CurveConfig memory cc = curveSel == 0
            ? LinearZones.config()
            : curveSel == 2 ? Curve2Zones.config()
            : curveSel == 3 ? Curve3Zones.config()
            : Curve1Zones.config();
        cc.timings = testnet ? _testnetTimings() : 0; // anvil/mainnet: mainnet defaults
        return PSPFactory.RoundParams({
            name: "Positive Sum Pepes",
            symbol: "PSP",
            curveConfig: cc
        });
    }
}
