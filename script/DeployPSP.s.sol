// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {PSPFactory} from "../src/PSPFactory.sol";
import {HookDeployer} from "../src/HookDeployer.sol";
import {ControllerDeployer} from "../src/ControllerDeployer.sol";
import {CurveMath} from "../src/libraries/CurveMath.sol";
import {Curve1Zones} from "../src/curves/Curve1Zones.sol";
import {SineMath} from "../src/libraries/SineMath.sol";
import {PepeDescriptor} from "../src/PepeDescriptor.sol";
import {PSPZapIn} from "../src/PSPZapIn.sol";
import {PSPZapOut} from "../src/PSPZapOut.sol";
import {IMixETH} from "../src/interfaces/IMixETH.sol";
import {SepoliaMixETH} from "../src/testnet/SepoliaMixETH.sol";
import {MixETHFaucet} from "../src/testnet/MixETHFaucet.sol";

import {MockMixETH} from "../test/mocks/MockMixETH.sol";
import {MockPoolManager} from "../test/mocks/MockPoolManager.sol";
import {StakerDeployer} from "../src/StakerDeployer.sol";


/// @title DeployPSP — genesis deployment with the tilted-sine curve
/// @notice Deploys the factory, round 1 ("Positive Sum Pepes" / PSP), and
///         publishes the walk-away UI via factory.setHtml(). The UI source is
///         script/app.html with __FACTORY__ substituted for the real address.
///
///         THE CURVE is the tilted sine (scoopy 2026-08-30 — sine-only, for
///         genesis AND every rebirth): parametric price wave over the mixETH
///         reserve, p0·e^(preK·R) pre-wave, then a 3-wave monotone climb
///         (45°-tilt cap = flat treads, never a dip), then a linear tail.
///         Params env-tunable (PSP_SINE_*); defaults reproduce the dial-lab
///         verified shape (p0 1e-5 → B 1e-4 at boot 500, top reserve 21×
///         boot, top price 0.06). The swap fee SLIDES with reserve depth:
///         10% pre-wave, linear decay to 2.5% by the wave top, 2.5% above.
///
///         The zone-curve family (anchor-ladder staircase & friends) is
///         RETIRED from deployment but stashed — src/curves/CURVES-STASH.md.
///
/// Env:
///   PSP_PM       pool manager (default: Base mainnet v4; REQUIRED with PSP_TESTNET)
///   PSP_MIXETH   mixETH token (required unless PSP_ANVIL/PSP_TESTNET)
///   PSP_HTML     ui file (default: script/app.html)
///   PSP_ANVIL    =1 to deploy MockMixETH+MockPoolManager first (local e2e)
///   PSP_TESTNET  =1 to deploy SepoliaMixETH (dumb 1:1, no yield, public
///                free mint) + MixETHFaucet (free unlimited drip, no ETH)
///                against a canonical v4 testnet PoolManager + playtest
///                profile (2h predeposit offer, 1h unstake vest decaying
///                in 6 × 10m epochs, and a 10-mixETH per-wallet predeposit
///                cap — all tunable: PSP_PREDEPOSIT_SEC / PSP_VEST_SEC /
///                PSP_WALLET_CAP_MIX; vest % 6 == 0)
///   PSP_DEPLOYER_CUT_TO  deployerCutTo override (default: the broadcaster;
///                mainnet value = scoopy's address — see the factory
///                constructor call below)
///   PSP_FORK     =1 to vm.deal the broadcaster 5 ETH first — lets you
///                dry-run the FULL testnet path (PSP_TESTNET + PSP_PM +
///                --fork-url $SEPOLIA_RPC_URL) with any throwaway key and
///                zero gas. Never set this for a real deployment.
///   PSP_SINE_*   sine shape overrides (see _sineParams)
contract DeployPSP is Script {
    // Base mainnet Uniswap v4 PoolManager (canonical v4 deployment; code
    // verified on-chain 2026-08-28 — the previous constant 0x498581fF… had
    // no code on mainnet and broke the mainnet path with
    // "call to non-contract address")
    address constant PM_BASE = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    // Official v4 testnet PoolManagers (Uniswap deployments feed, verified
    // on-chain 2026-08-18 via eth_getCode — 24009 bytes each)
    address constant PM_SEPOLIA = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;      // 11155111
    address constant PM_BASE_SEPOLIA = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408; // 84532
    address constant PM_ARB_SEPOLIA = 0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317;  // 421614
    address constant PM_UNICHAIN_SEPOLIA = 0x9cB26A7183B2F4515945Dc52CB4195B0d2D06C95; // 1301

    // Base Sepolia (84532) v4 periphery — scoopy's table, code-verified
    // 2026-08-28 via publicnode + sepolia.base.org + drpc:
    //   Universal Router  0x492e6456d9528771018deb9e87ef7750ef184104 (19,540 B)
    //   PositionManager   0x4b2c77d209d3405f41a037ec6c77f7f5b8e2ca80 (23,877 B)
    //   StateView         0x571291b572ed32ce6751a2cb2486ebee8defb9b4  (3,531 B)
    //   Quoter            0x4a6513c898fe1b2d0e78d3b0e0a4a151589b1cba  (5,820 B)
    //   PoolSwapTest      0x8b5bcc363dde2614281ad875bad385e0a785d3b9  (6,950 B)
    //   PoolModifyLiqTest 0x37429cd17cb1454c34e7f50b09725202fd533039  (6,050 B)
    //   Permit2           0x000000000022D473030F116dDEE9F6B43aC78BA3  (9,152 B)
    //   ReservesLens      0x0000001b173C3bbF3984D417d8614E3eed34865B — NOT
    //   DEPLOYED on 84532 (0 bytes on three RPCs; unused by PSP anyway)

    /// @dev Packed playtest timing profile (see RoundController "Timing
    ///      profile"): predeposit window · unstake vest · per-wallet
    ///      predeposit cap (whole mixETH, 0 = uncapped), all env-tunable
    ///      (PSP_PREDEPOSIT_SEC / PSP_VEST_SEC / PSP_WALLET_CAP_MIX;
    ///      defaults 2h / 1h / 10 — scoopy's fast-playtest profiles; the
    ///      vote + flat-exit slots died with governance, CLOCK-REDESIGN
    ///      §4). VEST must be divisible by 6 — six decay epochs
    ///      (packTimings guards).
    function _testnetTimings() internal view returns (uint256) {
        return CurveMath.packTimingsCapped(
            vm.envOr("PSP_PREDEPOSIT_SEC", uint256(2 hours)),
            vm.envOr("PSP_VEST_SEC", uint256(1 hours)),
            vm.envOr("PSP_WALLET_CAP_MIX", uint256(10))
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
            // Dumb 1:1 wrapper (no yield, no admin) + free faucet: mixETH is
            // playtest scrip — the token itself mints freely (public mint),
            // so the faucet is a stateless pass-through. No ETH needed, no
            // inventory to drain; the constructor SUPPLY just lands on the
            // broadcaster (harmless leftovers).
            SepoliaMixETH mixT = new SepoliaMixETH();
            MixETHFaucet faucet = new MixETHFaucet(IERC20(address(mixT)));
            vm.stopBroadcast();
            mix = IERC20(address(mixT));
            console.log("TESTNET PoolManager:", pm);
            console.log("TESTNET mixETH (1:1, free mint):", address(mixT));
            console.log("TESTNET faucet (free unlimited):", address(faucet));
        } else {
            pm = vm.envOr("PSP_PM", PM_BASE);
            mix = IERC20(vm.envAddress("PSP_MIXETH"));
        }
        string memory htmlPath = vm.envOr("PSP_HTML", string("script/app.html"));

        // Sepolia blocks cap at 60M gas and providers cap per-tx lower still
        // (alchemy ~15M, publicnode 2^24). Under the staged spawn the round
        // legs are small and split naturally (reserve ~1.3M, birth ~11.1M at
        // the 2-zone default); per-broadcast segments keep every tx under
        // even the strictest cap (forge sends one tx per startBroadcast).
        vm.startBroadcast();
        // deployerCutTo (CLOCK-REDESIGN §3): the 1% rake on unattributed
        // fees, immutable on the factory and every hook it births — wired
        // from the BROADCASTER. Testnet/anvil: the throwaway deployer
        // (burnable, matches "nobody rakes the playtest"). MAINNET: scoopy
        // executes this script from his own address, so the broadcaster IS
        // the documented mainnet value — scoopy's wallet. (If a different
        // broadcaster ever runs mainnet, pass PSP_DEPLOYER_CUT_TO
        // explicitly or the rake lands on the wrong wallet.)
        address deployerCut = vm.envOr("PSP_DEPLOYER_CUT_TO", msg.sender);
        PSPFactory factory = new PSPFactory(
            IPoolManager(pm),
            mix,
            new HookDeployer(),
            new ControllerDeployer(),
            new StakerDeployer(),
            (testnet || anvil) ? _testnetTimings() : 0, // anvil e2e: fast, env-tunable profile
            deployerCut
        );
        console.log("deployerCutTo (1% unattributed rake):", deployerCut);

        // wire the on-chain pepe art FIRST — it's global on the factory and
        // every round's staker is born with it (rides deployController's
        // raw-calldata passthrough). Factory owner == this broadcaster.
        PepeDescriptor descriptor = new PepeDescriptor();
        factory.setDescriptor(address(descriptor));
        vm.stopBroadcast();

        vm.startBroadcast();
        // THE curve is the tilted sine (scoopy 2026-08-30: "just for
        // simplicity have the rebirth just be the sine curve"). Armed once
        // on the factory, EVERY round — genesis and every rebirth — prices
        // off the parametric wave; the zone config below is creation-code
        // shape only. The zone-curve libraries stay stashed in src/curves/
        // (see CURVES-STASH.md) for possible future flavors.
        factory.configureSine(_sineParams());
        // roundId/hookAddr discarded on purpose: staged addresses are
        // entropy-salted, so the sim's values differ from the chain's —
        // read real state from the RPC after broadcast instead
        factory.deployRound(_roundParams(testnet));
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
        vm.stopBroadcast();

        // NOTE (staging, 2026-08-30): the reinvestor ctor needs the round's
        // staker + PSP token, but staged addresses are salted from BLOCK
        // ENTROPY — forge's local sim mines different salts than the
        // broadcast, so in-script reads of round state DO NOT match the
        // chain. It now deploys in a second pass (script/DeployReinvestor)
        // that reads the REAL post-broadcast round from the RPC. Same reason
        // the hook/round addresses are not consoled here anymore.
        console.log("factory:", address(factory));
        console.log("zapIn:", address(zapIn));
        console.log("zapOut:", address(zapOut));
        console.log("ui bytes:", bytes(h).length);
    }

    function _roundParams(bool testnet) internal view returns (PSPFactory.RoundParams memory) {
        // Sine-only (scoopy 2026-08-30): the zone config is creation-code
        // SHAPE — the armed sine overrides all zone pricing at launch. The
        // 1-zone shape is the smallest legal config, keeping the staged
        // create2 initcodes (and birth gas) lean.
        CurveMath.CurveConfig memory cc = Curve1Zones.config();
        cc.timings = testnet ? _testnetTimings() : 0; // anvil/mainnet: mainnet defaults
        return PSPFactory.RoundParams({
            name: "Positive Sum Pepes",
            symbol: "PSP",
            curveConfig: cc
        });
    }

    /// @dev PSP_CURVE=6 — tilted-sine params. Defaults reproduce the dial-lab
    ///      verified shape (p0 1e-5 → B 1e-4 at boot 500 via preK=ln(10)/500,
    ///      magM 20 → top reserve = 21×boot, lnTop = ln(600) → top price 0.06,
    ///      ampBps 10000 = the 45° tilt: flat treads, monotone). Env overrides:
    ///      PSP_SINE_P0 / PSP_SINE_PREK / PSP_SINE_MAGM / PSP_SINE_LNTOP /
    ///      PSP_SINE_AMPBPS.
    function _sineParams() internal view returns (SineMath.Params memory) {
        return SineMath.Params({
            p0: vm.envOr("PSP_SINE_P0", uint256(1e13)),
            preK: vm.envOr("PSP_SINE_PREK", uint256(4_605_170_185_988_092)),
            magM: vm.envOr("PSP_SINE_MAGM", uint256(20e18)),
            lnTop: vm.envOr("PSP_SINE_LNTOP", uint256(6_396_929_655_216_146_432)),
            ampBps: uint24(vm.envOr("PSP_SINE_AMPBPS", uint256(10_000)))
        });
    }
}
