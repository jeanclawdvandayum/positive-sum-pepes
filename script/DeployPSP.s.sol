// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console} from "forge-std/Script.sol";
import {DeploymentSupport} from "./DeploymentSupport.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {PSPFactory} from "../src/PSPFactory.sol";
import {HookDeployer} from "../src/HookDeployer.sol";
import {ControllerDeployer} from "../src/ControllerDeployer.sol";

import {PepeExpandedDescriptor} from "../src/PepeExpandedDescriptor.sol";
import {PSPZapIn} from "../src/PSPZapIn.sol";
import {PSPZapOut} from "../src/PSPZapOut.sol";
import {SineV3Math} from "../src/SineV3Math.sol";
import {IMixETH} from "../src/interfaces/IMixETH.sol";
import {SepoliaMixETH} from "../src/testnet/SepoliaMixETH.sol";
import {MixETHFaucet} from "../src/testnet/MixETHFaucet.sol";

import {MockMixETH} from "../test/mocks/MockMixETH.sol";
import {MockPoolManager} from "../test/mocks/MockPoolManager.sol";
import {StakerDeployer} from "../src/StakerDeployer.sol";


/// @title DeployPSP
/// @notice Fresh staged deployment. PSP_TESTNET selects Base Sepolia 84532,
/// a new free-mint practice mixETH/faucet and a read-only embedded status page.
/// Testnet defaults: 24h predeposit, 1h vest, 4h20m clock, uncapped per-wallet
/// predeposit (global cap 1000 mixETH). PSP_* timing and sine overrides apply.
/// Run a local fork rehearsal first. Broadcast with --slow, then read the
/// actual round from the factory in the separate DeployReinvestor pass.
contract DeployPSP is DeploymentSupport {
    address constant PM_BASE = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    function run() external {
        bool anvil = vm.envOr("PSP_ANVIL", false);
        bool testnet = vm.envOr("PSP_TESTNET", false);
        _validateModes(anvil, testnet);
        // Parse and validate all configuration before spending deployment gas.
        uint128 sinePL = _sinePL();
        uint256 timings = (testnet || anvil) ? _testnetTimings() : 0;
        string memory htmlPath = _htmlPath(testnet);
        string memory htmlSource = vm.readFile(htmlPath);
        address deployerCut = vm.envOr("PSP_DEPLOYER_CUT_TO", msg.sender);
        require(deployerCut != address(0), "deployer fee recipient is zero");
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
            _validatePoolManager(pm, true);
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
            _validatePoolManager(pm, false);
            require(address(mix).code.length != 0, "mixETH has no code");
        }
        // Each deployment/call is a separate broadcast transaction. Genesis
        // uses three birthStep calls to stay within Base Sepolia's gas cap.
        vm.startBroadcast();
        // deployerCutTo (CLOCK-REDESIGN §3): the 1% rake on unattributed
        // fees, immutable on the factory and every hook it births — wired
        // from the BROADCASTER. Testnet/anvil: the throwaway deployer
        // (burnable, matches "nobody rakes the playtest"). MAINNET: scoopy
        // executes this script from his own address, so the broadcaster IS
        // the documented mainnet value — scoopy's wallet. (If a different
        // broadcaster ever runs mainnet, pass PSP_DEPLOYER_CUT_TO
        // explicitly or the rake lands on the wrong wallet.)
        vm.startBroadcast();
        // The v3 settlement helper — ONE shared read-only SineV3Math per
        // factory. Born before the factory so its address is pinned in the
        // factory constructor and every round's hook from genesis on.
        SineV3Math sineV3Table = new SineV3Math();
        vm.stopBroadcast();

        vm.startBroadcast();
        PSPFactory factory = new PSPFactory(
            IPoolManager(pm),
            mix,
            new HookDeployer(),
            new ControllerDeployer(),
            new StakerDeployer(),
            address(sineV3Table),
            timings,
            deployerCut
        );
        console.log("deployerCutTo (1% unattributed rake):", deployerCut);
        console.log("sineV3Table (shared settlement helper):", address(sineV3Table));

        // wire the on-chain pepe art FIRST — it's global on the factory and
        // every round's staker is born with it (rides deployController's
        // raw-calldata passthrough). Factory owner == this broadcaster.
        PepeExpandedDescriptor descriptor = new PepeExpandedDescriptor();
        factory.setDescriptor(address(descriptor));
        vm.stopBroadcast();

        vm.startBroadcast();
        // THE curve is sine rules v3 (2026-09-14): one continuous tilted
        // sine, softened cube-root growth, pot-priced tickets. Armed once on
        // the factory, EVERY round — genesis and every rebirth — settles on
        // it via the shared helper; the zone config below is creation-code
        // shape only. The zone-curve libraries stay stashed in src/curves/
        // (see CURVES-STASH.md) for possible future flavors.
        factory.configureSineV3(sinePL);
        // Staged genesis (2026-09-03): the post-clock-redesign composed
        // deployRound is ~18.6-21M — over Base Sepolia's ≈2^24 per-tx cap —
        // so the birth runs as THREE deterministic birthStep txs (token+
        // controller · registry+hook · wire+init), each comfortably under
        // every cap. Addresses stay entropy-salted: the sim's values differ
        // from the chain's — read real state from the RPC after broadcast.
        // Fixed budget: block entropy changes the hook-mining work after simulation.
        factory.reserveGenesis{gas: GENESIS_RESERVATION_GAS}(_roundParams(timings));
        vm.stopBroadcast();
        vm.startBroadcast();
        factory.birthStep(); // 1: token + controller (+ staker)
        vm.stopBroadcast();
        vm.startBroadcast();
        factory.birthStep(); // 2: registry + hook
        vm.stopBroadcast();
        vm.startBroadcast();
        factory.birthStep(); // 3: wiring + sine arm + pool init
        vm.stopBroadcast();

        // publish the walk-away UI (fetch factory.html() from any rpc)
        string memory h = htmlSource;
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

}
