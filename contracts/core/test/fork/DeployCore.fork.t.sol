// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";

import "./ForkBase.sol";
import {DeployCore} from "../../script/DeployCore.s.sol";
import {OtherCircuitsImpl} from "./KernelFork.t.sol";

/// @dev Stand-ins that answer the three getters the script reads from the Manager and the two it reads from the
///      router, so that each consistency check can be made to fail on its own.
contract StubManager {
    address public V2_ROUTER02;
    address public V2_FACTORY;
    address public WRAPPED_NATIVE;

    constructor(address router, address v2Factory, address wokb) {
        (V2_ROUTER02, V2_FACTORY, WRAPPED_NATIVE) = (router, v2Factory, wokb);
    }
}

contract StubRouter {
    address public WETH;
    address public factory;

    constructor(address wokb, address v2Factory) {
        (WETH, factory) = (wokb, v2Factory);
    }
}

interface IV2FactoryOf {
    function V2_FACTORY() external view returns (address);
}

/// @notice The deploy script, run inside the X Layer fork against a processor created through TapeOut's real
///         factory and a real Fab and SealedVM. Nothing is broadcast.
contract DeployCoreForkTest is ForkBase {
    bool internal live;
    DeployCore internal script;

    function setUp() public {
        live = _fork();
        if (!live) return;
        _deployCovenant(); // the processor, the Fab and the SealedVM (its factory and Lens are replaced below)
        script = new DeployCore();
    }

    modifier onFork() {
        if (!live) {
            vm.skip(true);
            return;
        }
        _;
    }

    /// @dev The script's inputs: this fork's processor, Fab and SealedVM, and X Layer's own contracts.
    function _pins() internal view returns (DeployCore.Pins memory p) {
        p.manager = address(M);
        p.v2Router = address(ROUTER);
        p.wokb = WOKB;
        p.circuits = circuits;
        p.fab = address(fab);
        p.sealedVM = address(sealedVM);
        p.beacon = CIRCUIT_BEACON;
        p.impl0 = CIRCUIT_IMPL;
        p.impl0Hash = CIRCUIT_IMPL_HASH;
    }

    function test_fork_script_deploys_the_factory_and_the_lens_and_they_work() public onFork {
        (KernelFactory f, Lens l) = script.deploy(_pins());
        assertEq(f.manager(), address(M));
        assertEq(f.v2Router(), address(ROUTER));
        assertEq(f.wokb(), WOKB);
        assertEq(f.circuits(), circuits);
        assertEq(f.fab(), address(fab));
        assertEq(f.sealedVM(), address(sealedVM));
        assertEq(f.beacon(), CIRCUIT_BEACON);
        assertEq(f.impl0(), CIRCUIT_IMPL);
        assertEq(f.impl0Hash(), CIRCUIT_IMPL_HASH);
        assertTrue(f.pinsLive());
        assertGt(f.kernelImpl().code.length, 0);
        assertLt(f.kernelImpl().code.length, 24_576);

        // the deployed pair creates a kernel, binds it to a token launched on live IGNIX and settles
        factory = f;
        lens = l;
        _fixture(_netlist(), _env(), 300);
        assertTrue(f.isKernel(address(kernel)));
        assertEq(f.kernelOf(address(token)), address(kernel));
        Lens.Preflight memory p = l.preflight(address(kernel));
        assertTrue(p.tapeoutRan && p.sealedRan && p.agree);
        _buy(alice, 1 ether);
        _nextEpoch();
        (uint32 n,) = _settle();
        assertEq(kernel.records(n).inflow, 0.03 ether);
        assertTrue(l.replay(address(kernel), n).ok);
    }

    function test_fork_script_refuses_another_chain() public onFork {
        DeployCore.Pins memory p = _pins();
        vm.chainId(1);
        vm.expectRevert(bytes("DeployCore: not X Layer (chain 196)"));
        script.deploy(p);
    }

    function test_fork_script_refuses_inputs_that_do_not_fit_together() public onFork {
        DeployCore.Pins memory p;
        address nobody = makeAddr("nobody");

        p = _pins();
        p.manager = nobody;
        vm.expectRevert(bytes("DeployCore: manager has no code"));
        script.deploy(p);
        p = _pins();
        p.fab = nobody;
        vm.expectRevert(bytes("DeployCore: Fab has no code"));
        script.deploy(p);
        p = _pins();
        p.sealedVM = nobody;
        vm.expectRevert(bytes("DeployCore: SealedVM has no code"));
        script.deploy(p);
        p = _pins();
        p.impl0 = nobody;
        vm.expectRevert(bytes("DeployCore: pinned implementation has no code"));
        script.deploy(p);
        p = _pins();
        p.v2Router = nobody;
        vm.expectRevert(bytes("DeployCore: router has no code"));
        script.deploy(p);
        p = _pins();
        p.wokb = nobody;
        vm.expectRevert(bytes("DeployCore: WOKB has no code"));
        script.deploy(p);
        p = _pins();
        p.circuits = nobody;
        vm.expectRevert(bytes("DeployCore: circuits has no code"));
        script.deploy(p);
        p = _pins();
        p.beacon = nobody;
        vm.expectRevert(bytes("DeployCore: beacon has no code"));
        script.deploy(p);

        // a code hash that is not the pinned implementation's (a typo would make every kernel sealed for good)
        p = _pins();
        p.impl0Hash = bytes32(uint256(CIRCUIT_IMPL_HASH) ^ 1);
        vm.expectRevert(bytes("DeployCore: pinned code hash is not the implementation's"));
        script.deploy(p);

        // a router that is not the Manager's
        p = _pins();
        p.v2Router = address(sealedVM);
        vm.expectRevert(bytes("DeployCore: not the Manager's router"));
        script.deploy(p);
        p = _pins();
        p.wokb = address(sealedVM);
        vm.expectRevert(bytes("DeployCore: not the Manager's WOKB"));
        script.deploy(p);

        // a Manager whose router wraps another token, and one whose router works on another V2 factory
        address v2Factory = IV2FactoryOf(address(M)).V2_FACTORY();
        p = _pins();
        p.v2Router = address(new StubRouter(address(sealedVM), v2Factory));
        p.manager = address(new StubManager(p.v2Router, v2Factory, WOKB));
        vm.expectRevert(bytes("DeployCore: not the router's WOKB"));
        script.deploy(p);
        p = _pins();
        p.v2Router = address(new StubRouter(WOKB, address(sealedVM)));
        p.manager = address(new StubManager(p.v2Router, v2Factory, WOKB));
        vm.expectRevert(bytes("DeployCore: router and Manager use different V2 factories"));
        script.deploy(p);
        // (with a stand-in Manager and router that agree with each other, the script goes on)
        p = _pins();
        p.v2Router = address(new StubRouter(WOKB, v2Factory));
        p.manager = address(new StubManager(p.v2Router, v2Factory, WOKB));
        (KernelFactory f,) = script.deploy(p);
        assertEq(f.manager(), p.manager);

        // a Fab deployed for another processor
        vm.prank(launcher);
        (address t2, address c2) = ITapeOutFactory(TAPEOUT_FACTORY).createCPU{value: 0.0066 ether}(
            "Other", "OTH", "another processor", 1000, 1
        );
        p = _pins();
        p.fab = address(new Fab(c2, t2));
        vm.expectRevert(bytes("DeployCore: the Fab is for another processor"));
        script.deploy(p);
    }

    /// The pins are constants given to the script, not a reading of the live beacon. If TapeOut has been
    /// upgraded since they were taken, the script still deploys and says so, and every kernel of that factory
    /// runs on the sealed evaluator from its first settle.
    function test_fork_script_deploys_with_pins_that_are_no_longer_live() public onFork {
        uint256 id = _tapeout(_netlist()); // a chip taped out while TapeOut was still the pinned code
        OtherCircuitsImpl other = new OtherCircuitsImpl();
        vm.prank(ITapeOutFactory(TAPEOUT_FACTORY).owner());
        ITapeOutFactory(TAPEOUT_FACTORY).upgradeCircuits(address(other));

        (KernelFactory f, Lens l) = script.deploy(_pins());
        assertFalse(f.pinsLive(), "the script deployed, and the factory knows its pins are not live");
        assertEq(f.impl0(), CIRCUIT_IMPL, "the pins are the ones given, not a reading of the beacon");

        Kernel k = Kernel(payable(f.create(_env(), id, bytes32("sealed"))));
        (address vm_, bool sealedMode) = k.evaluator();
        assertEq(vm_, address(sealedVM));
        assertTrue(sealedMode);
        Lens.Preflight memory p = l.preflight(address(k));
        assertTrue(p.sealedModeNow && p.sealedRan);
        assertFalse(p.tapeoutRan);
    }
}
