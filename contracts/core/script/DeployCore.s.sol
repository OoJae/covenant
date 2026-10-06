// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {KernelFactory} from "../src/KernelFactory.sol";
import {Lens} from "../src/Lens.sol";

interface IManagerLike {
    function V2_ROUTER02() external view returns (address);
    function V2_FACTORY() external view returns (address);
    function WRAPPED_NATIVE() external view returns (address);
}

interface IRouterLike {
    function WETH() external view returns (address);
    function factory() external view returns (address);
}

interface IProcessorLike {
    function transistors() external view returns (address);
    function nextId() external view returns (uint256);
}

interface IFabLike {
    function CIRCUITS() external view returns (address);
}

interface IBeaconLike {
    function implementation() external view returns (address);
}

/// @title DeployCore: deploys the KernelFactory (which deploys the Kernel implementation) and the Lens on X Layer
/// @notice Two creations, no initialisation, nothing to configure afterwards. The factory's nine addresses and
///         the pinned code hash are fixed in its bytecode from its first block; every kernel it creates
///         copies them.
///
///         Inputs (environment). The first three are this deployment's own contracts and have no default:
///
///           COVENANT_CIRCUITS    the Covenant processor's circuit contract (ERC-721, TapeOut's evaluator)
///           COVENANT_FAB         the Fab deployed for that processor (contracts/evaluator)
///           COVENANT_SEALED_VM   the sealed evaluator (contracts/evaluator)
///
///         The other six name contracts that already exist on X Layer. They default to the addresses the
///         fork tests of this package ran against (block 72,369,000) and can be overridden:
///
///           COVENANT_MANAGER     IgnixManager (proxy)
///           COVENANT_V2_ROUTER   Uniswap V2 Router02
///           COVENANT_WOKB        wrapped native OKB
///           COVENANT_BEACON      TapeOut's circuit beacon
///           COVENANT_IMPL0       the pinned TapeOut circuit implementation
///           COVENANT_IMPL0_HASH  its code hash
///
///         The pinned implementation and hash name the TapeOut code the differential tests ran against. They
///         are NOT read from the live beacon: if TapeOut has been upgraded since, the script says so, and
///         every kernel of this factory runs on the sealed evaluator from its first settle.
///
///         Simulate (sends nothing, needs no key):
///
///           COVENANT_CIRCUITS=0x... COVENANT_FAB=0x... COVENANT_SEALED_VM=0x... \
///             forge script script/DeployCore.s.sol --rpc-url https://rpc.xlayer.tech
///
///         The broadcast command, to be run by the wallet holder only, is in NOTES.md (section 2).
contract DeployCore is Script {
    uint256 internal constant XLAYER_CHAIN_ID = 196;

    // X Layer mainnet, as verified by the fork tests at block 72,369,000
    address internal constant DEFAULT_MANAGER = 0x96B51c57e5346D0C0198899243cf851D1E23C309;
    address internal constant DEFAULT_V2_ROUTER = 0x182a927119D56008d921126764bF884221b10f59;
    address internal constant DEFAULT_WOKB = 0xe538905cf8410324e03A5A23C1c177a474D59b2b;
    address internal constant DEFAULT_BEACON = 0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C;
    address internal constant DEFAULT_IMPL0 = 0x977f217887E085D298Cb3819cDAD5A0ee35F29B2;
    bytes32 internal constant DEFAULT_IMPL0_HASH = 0x7a15c353205e5245f40f5f5524542a982a4bb3b9a28476e4f10845163f941b30;

    /// The constructor arguments of the KernelFactory, in its order.
    struct Pins {
        address manager;
        address v2Router;
        address wokb;
        address circuits;
        address fab;
        address sealedVM;
        address beacon;
        address impl0;
        bytes32 impl0Hash;
    }

    function run() external returns (KernelFactory factory, Lens lens) {
        Pins memory p;
        p.circuits = vm.envAddress("COVENANT_CIRCUITS");
        p.fab = vm.envAddress("COVENANT_FAB");
        p.sealedVM = vm.envAddress("COVENANT_SEALED_VM");
        p.manager = vm.envOr("COVENANT_MANAGER", DEFAULT_MANAGER);
        p.v2Router = vm.envOr("COVENANT_V2_ROUTER", DEFAULT_V2_ROUTER);
        p.wokb = vm.envOr("COVENANT_WOKB", DEFAULT_WOKB);
        p.beacon = vm.envOr("COVENANT_BEACON", DEFAULT_BEACON);
        p.impl0 = vm.envOr("COVENANT_IMPL0", DEFAULT_IMPL0);
        p.impl0Hash = vm.envOr("COVENANT_IMPL0_HASH", DEFAULT_IMPL0_HASH);
        return deploy(p);
    }

    function deploy(Pins memory p) public returns (KernelFactory factory, Lens lens) {
        // ---- before: the nine inputs fit together, on X Layer
        require(block.chainid == XLAYER_CHAIN_ID, "DeployCore: not X Layer (chain 196)");
        _requireCode(p.manager, "DeployCore: manager has no code");
        _requireCode(p.v2Router, "DeployCore: router has no code");
        _requireCode(p.wokb, "DeployCore: WOKB has no code");
        _requireCode(p.circuits, "DeployCore: circuits has no code");
        _requireCode(p.fab, "DeployCore: Fab has no code");
        _requireCode(p.sealedVM, "DeployCore: SealedVM has no code");
        _requireCode(p.beacon, "DeployCore: beacon has no code");
        _requireCode(p.impl0, "DeployCore: pinned implementation has no code");
        require(p.impl0.codehash == p.impl0Hash, "DeployCore: pinned code hash is not the implementation's");
        // the kernel buys through this router, on the pair the Manager graduates a token into
        require(IManagerLike(p.manager).V2_ROUTER02() == p.v2Router, "DeployCore: not the Manager's router");
        require(IManagerLike(p.manager).WRAPPED_NATIVE() == p.wokb, "DeployCore: not the Manager's WOKB");
        require(IRouterLike(p.v2Router).WETH() == p.wokb, "DeployCore: not the router's WOKB");
        require(
            IRouterLike(p.v2Router).factory() == IManagerLike(p.manager).V2_FACTORY(),
            "DeployCore: router and Manager use different V2 factories"
        );
        // the Fab tapes out on this processor
        require(IFabLike(p.fab).CIRCUITS() == p.circuits, "DeployCore: the Fab is for another processor");
        address liveImpl = IBeaconLike(p.beacon).implementation();

        // ---- the two transactions
        vm.startBroadcast();
        factory = new KernelFactory(
            p.manager, p.v2Router, p.wokb, p.circuits, p.fab, p.sealedVM, p.beacon, p.impl0, p.impl0Hash
        );
        lens = new Lens(address(factory));
        vm.stopBroadcast();

        // ---- after: the factory holds exactly what it was given, and its Kernel implementation exists
        require(factory.manager() == p.manager, "KernelFactory: manager");
        require(factory.v2Router() == p.v2Router, "KernelFactory: router");
        require(factory.wokb() == p.wokb, "KernelFactory: WOKB");
        require(factory.circuits() == p.circuits, "KernelFactory: circuits");
        require(factory.fab() == p.fab, "KernelFactory: Fab");
        require(factory.sealedVM() == p.sealedVM, "KernelFactory: SealedVM");
        require(factory.beacon() == p.beacon, "KernelFactory: beacon");
        require(factory.impl0() == p.impl0, "KernelFactory: pinned implementation");
        require(factory.impl0Hash() == p.impl0Hash, "KernelFactory: pinned code hash");
        address kernelImpl = factory.kernelImpl();
        require(kernelImpl.code.length != 0, "KernelFactory: no Kernel implementation");
        require(kernelImpl.code.length < 24_576, "Kernel implementation over the code size limit");
        require(address(lens).code.length != 0, "Lens: not deployed");
        require(address(lens.FACTORY()) == address(factory), "Lens: factory");
        bool pinsLive = factory.pinsLive();
        require(pinsLive == (liveImpl == p.impl0), "KernelFactory: pinsLive disagrees with the beacon");

        _print(p, factory, lens, liveImpl, pinsLive);
    }

    function _requireCode(address a, string memory why) internal view {
        require(a.code.length != 0, why);
    }

    function _print(Pins memory p, KernelFactory factory, Lens lens, address liveImpl, bool pinsLive) internal view {
        console2.log("chain id                      ", block.chainid);
        console2.log("inputs");
        console2.log("  IgnixManager                ", p.manager);
        console2.log("  Uniswap V2 router           ", p.v2Router);
        console2.log("  WOKB                        ", p.wokb);
        console2.log("  processor: circuits         ", p.circuits);
        // informational: these two reads go through TapeOut's upgradeable logic and may not answer after an upgrade
        try IProcessorLike(p.circuits).transistors() returns (address transistors) {
            console2.log("  processor: transistors      ", transistors);
        } catch {
            console2.log("  processor: transistors       (the processor does not answer)");
        }
        try IProcessorLike(p.circuits).nextId() returns (uint256 taped) {
            console2.log("  processor: circuits taped   ", taped);
        } catch {}
        console2.log("  Fab                         ", p.fab);
        console2.log("  SealedVM                    ", p.sealedVM);
        console2.log("  TapeOut circuit beacon      ", p.beacon);
        console2.log("  pinned implementation       ", p.impl0);
        console2.log("  pinned code hash");
        console2.logBytes32(p.impl0Hash);
        console2.log("  beacon implementation now   ", liveImpl);
        console2.log("deployed");
        console2.log("  KernelFactory               ", address(factory));
        console2.log("    runtime bytes             ", address(factory).code.length);
        console2.log("  Kernel implementation       ", factory.kernelImpl());
        console2.log("    runtime bytes             ", factory.kernelImpl().code.length);
        console2.log("  Lens                        ", address(lens));
        console2.log("    runtime bytes             ", address(lens).code.length);
        console2.log("step gas a kernel gets (KernelFactory constants)");
        console2.log(
            "  TapeOut: base / per gate / per latch",
            factory.STEP_BASE(),
            factory.STEP_PER_GATE(),
            factory.STEP_PER_LATCH()
        );
        console2.log(
            "  sealed:  base / per NAND / per latch",
            factory.SEALED_BASE(),
            factory.SEALED_PER_NAND(),
            factory.SEALED_PER_LATCH()
        );
        if (pinsLive) {
            console2.log("pinsLive: true. Kernels ask TapeOut's evaluator first.");
        } else {
            console2.log("pinsLive: FALSE. TapeOut's circuit logic is not the pinned one:");
            console2.log("  every kernel of this factory will run on the sealed evaluator from its first settle.");
        }
    }
}
