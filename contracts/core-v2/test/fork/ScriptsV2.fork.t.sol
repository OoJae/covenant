// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ForkBaseV2.sol";
import {IFabLaunchV2} from "../../script/LaunchChipV2.s.sol";

contract StubManagerV2 {
    address public V2_ROUTER02;
    address public V2_FACTORY;

    constructor(address r, address f) {
        (V2_ROUTER02, V2_FACTORY) = (r, f);
    }
}

/// @notice DeployCoreV2 and LaunchChipV2 run inside the X Layer fork against the live processor, Fab, SealedVM,
///         IGNIX and USD₮0. Nothing is broadcast: the scripts' functions are called from the test.
contract ScriptsV2ForkTest is ForkBaseV2 {
    bool internal live;

    function setUp() public {
        live = _fork();
    }

    modifier onFork() {
        if (!live) {
            vm.skip(true);
            return;
        }
        _;
    }

    function test_fork_deploy_script_pins_everything_and_reads_the_shift_from_the_pool() public onFork {
        DeployCoreV2 s = new DeployCoreV2();
        (uint256 shift, uint256 rateMicro) = s.shiftFromPool(0xe3BE6A0137f1b0602Fc1a4841686f43B340a5082, address(USDT0));
        assertEq(shift, 33, "the live price is in the band of a 33-bit shift");
        assertApproxEqRel(rateMicro, 135_895_901, 1e15, "1 OKB = 135.9 USD0 at the pinned block");
        (KernelFactoryV2 f, LensV2 l) = s.deploy(s.defaults());
        assertEq(f.manager(), address(M));
        assertEq(f.v2Router(), address(ROUTER));
        assertEq(f.quote(), address(USDT0));
        assertEq(f.quoteShift(), 33);
        assertEq(f.circuits(), CIRCUITS);
        assertEq(f.fab(), FAB);
        assertEq(f.sealedVM(), SEALED_VM);
        assertEq(f.beacon(), CIRCUIT_BEACON);
        assertEq(f.impl0(), CIRCUIT_IMPL);
        assertTrue(f.pinsLive());
        assertEq(address(l.FACTORY()), address(f));
        assertLt(f.kernelImpl().code.length, 24_576);
    }

    function test_fork_deploy_script_refuses_inputs_that_do_not_fit_together() public onFork {
        DeployCoreV2 s = new DeployCoreV2();
        DeployCoreV2.Pins memory p = s.defaults();
        p.quoteShift = 32;
        vm.expectRevert(bytes("DeployCoreV2: the OKB/USDT0 price is outside the band of this shift (NOTES.md section 3)"));
        s.deploy(p);
        p = s.defaults();
        p.quote = 0xe538905cf8410324e03A5A23C1c177a474D59b2b; // WOKB: 18 decimals
        vm.expectRevert(bytes("DeployCoreV2: the quote does not have 6 decimals"));
        s.deploy(p);
        p = s.defaults();
        p.manager = address(new StubManagerV2(address(1), address(2)));
        vm.expectRevert(bytes("DeployCoreV2: not the Manager's router"));
        s.deploy(p);
        p = s.defaults();
        p.impl0Hash = bytes32(uint256(1));
        vm.expectRevert(bytes("DeployCoreV2: pinned code hash is not the implementation's"));
        s.deploy(p);
        p = s.defaults();
        p.circuits = address(USDT0);
        vm.expectRevert(bytes("DeployCoreV2: the Fab is for another processor"));
        s.deploy(p);
    }

    /// The chain guard and what REHEARSAL may switch off, in one test because REHEARSAL is a process-wide
    /// environment variable (vm.setEnv) and the other tests of this file must not see it set.
    ///   - Without REHEARSAL another chain is refused (both scripts).
    ///   - REHEARSAL=true on X Layer itself switches nothing off: the price-band check of the shift still applies
    ///     (review A-F5: a REHEARSAL left set in the shell after a rehearsal must not reach a chain-196 deploy).
    ///   - On another chain (a local fork with its own chain id) REHEARSAL=true lets a rehearsal through.
    function test_fork_scripts_chain_guard_and_what_rehearsal_may_switch_off() public onFork {
        DeployCoreV2 s = new DeployCoreV2();
        DeployCoreV2.Pins memory p = s.defaults();
        LaunchChipV2 ls = new LaunchChipV2();
        LaunchChipV2.Inputs memory in_;
        in_.payee = payee;

        vm.setEnv("REHEARSAL", "false");
        vm.chainId(1);
        vm.expectRevert(bytes("DeployCoreV2: not X Layer (196); REHEARSAL=true only"));
        s.deploy(p);
        vm.expectRevert(bytes("LaunchChipV2: not X Layer (196); REHEARSAL=true only"));
        ls.launch(in_);

        vm.setEnv("REHEARSAL", "true");
        vm.chainId(196);
        assertFalse(s.rehearsalAllowed(), "REHEARSAL has no effect on X Layer");
        p.quoteShift = 32; // outside the band of the pool's price
        vm.expectRevert(bytes("DeployCoreV2: the OKB/USDT0 price is outside the band of this shift (NOTES.md section 3)"));
        s.deploy(p);
        p.quoteShift = 40;
        vm.expectRevert(bytes("DeployCoreV2: the OKB/USDT0 price is outside the band of this shift (NOTES.md section 3)"));
        s.deploy(p);

        vm.chainId(31_337);
        assertTrue(s.rehearsalAllowed(), "a rehearsal on another chain id");
        p.quoteShift = 32;
        (KernelFactoryV2 f,) = s.deploy(p);
        assertEq(f.quoteShift(), 32, "a rehearsal may try another shift");
        vm.expectRevert(bytes("LaunchChipV2: the Fab has no code"));
        ls.launch(in_); // past the chain guard

        vm.setEnv("REHEARSAL", "false");
        vm.chainId(196);
    }

    /// The whole launch the user would sign, in the fork: deploy, tape out the Flow Governor through the live Fab,
    /// create the kernel with the reference envelope, hand it the chip; then (IGNIX's part) launch a Directed
    /// token quoted in USD₮0 against the kernel, bind, and settle with an x402 payment and a trade.
    function test_fork_launch_script_end_to_end() public onFork {
        _deployV2();
        LaunchChipV2 ls = new LaunchChipV2();
        LaunchChipV2.Inputs memory in_;
        in_.fab = IFabLaunchV2(FAB);
        in_.factory = factory;
        in_.lens = lens;
        in_.netlist = _fgNetlist();
        in_.manifestHash = FG_MANIFEST_HASH;
        in_.payee = payee;
        in_.salt = bytes32("launch");
        // the broadcaster pays the tape-out
        (, address sender,) = vm.readCallers();
        vm.deal(sender, 1 ether);
        address tankAsPayee = KEEPER_TANK;
        in_.payee = tankAsPayee;
        vm.expectRevert(bytes("LaunchChipV2: the KeeperTank cannot move USDT0; choose another payee"));
        ls.launch(in_);
        in_.payee = payee;
        (uint256 id, address k) = ls.launch(in_);
        kernel = KernelV2(k);
        chipId = id;
        assertEq(ICircuitsFork(CIRCUITS).ownerOf(id), k, "the kernel holds the chip");
        assertEq(kernel.envelope().allowancePayee, payee);
        assertEq(kernel.envelope().ceilMax, 440);
        assertEq(kernel.quoteShift(), 33);

        launcher = kernel.envelope().launcher;
        vm.deal(launcher, 1 ether);
        (token, vault) = _launchUsdt0(k, 300);
        vm.prank(bob);
        kernel.bind(address(token));
        _buy(alice, 100e6);
        _x402(500_000);
        _nextEpoch();
        (uint32 n,) = _settle();
        RecordV2 memory r = kernel.records(n);
        assertEq(r.inflow, 3e6 + 500_000, "the tax and one $0.50 call");
        assertTrue(lens.replay(k, n).ok);
    }
}
