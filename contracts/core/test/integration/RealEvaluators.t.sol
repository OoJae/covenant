// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";

import {Kernel} from "../../src/Kernel.sol";
import {KernelFactory} from "../../src/KernelFactory.sol";
import {Lens} from "../../src/Lens.sol";
import {KernelMath} from "../../src/KernelMath.sol";
import {Record, Envelope, RecordFlags, IKernelMin} from "../../src/interfaces/IKernelV1.sol";
import {Globals} from "../../src/interfaces/IKernelExt.sol";

import {SealedVM} from "evaluator/SealedVM.sol";
import {NetlistScan} from "evaluator/lib/NetlistScan.sol";
import {ITapeCircuits, ITapeFab, Netlists} from "./Netlists.sol";
import {MockToken, MockVault, MockWOKB, MockRouter, MockManager} from "../mocks/MockIgnix.sol";
import {MockImpl, MockImplV2, MockBeacon} from "../mocks/MockTapeOut.sol";

/// @dev Section 2 of the interface as the real Fab checks it (contracts/evaluator, NetlistScan), for a
///      netlist passed as calldata.
contract ScanProbe {
    function scan(bytes calldata nl) external pure returns (uint256 nNand, uint256 nLatch) {
        return NetlistScan.scan(nl);
    }
}

/// @notice The kernel on the real evaluators: TapeOut's own NetlistVM (vendored, unmodified) and the real
///         SealedVM from contracts/evaluator, over real TAP-20 netlists, including the taped Flow Governor.
///         IGNIX is still the mock here; the fork suite uses the live one.
///
///         The Flow Governor used by these tests is the fixed copy test/fixtures/fg.hex (the chip as it was
///         built on 2026-10-04: 1,889 NAND + 64 LATCH, 13,479 bytes), so that a rebuild of the chip does not
///         move any number here. Exactly one test, `test_live_chip_...`, reads the chip tools' current
///         output chips/out/fg.hex, and it asserts only what must hold for any build of it.
contract RealEvaluatorsTest is Test {
    address internal constant NATIVE = address(0);
    uint32 internal constant EPOCH = 900;

    address internal launcher = makeAddr("launcher");
    address internal payee = makeAddr("allowance payee");
    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");

    MockWOKB internal wokb;
    MockManager internal manager;
    MockRouter internal router;
    MockImpl internal impl;
    MockBeacon internal beacon;
    ITapeCircuits internal circuits;
    ITapeFab internal fab;
    SealedVM internal sealedVM;
    KernelFactory internal factory;
    Lens internal lens;

    // 50% buy, 25% hold, 18.75% allowance, 6.25% reserve, release a quarter, no ceiling
    uint256 internal WORD;

    function setUp() public {
        vm.warp(1_791_000_000);
        wokb = new MockWOKB();
        manager = new MockManager(address(wokb));
        router = new MockRouter(address(wokb), address(manager));
        impl = new MockImpl();
        beacon = new MockBeacon(address(impl));
        // built with via-IR from TapeOut's vendored sources; deployed from the artifact, never imported
        circuits = ITapeCircuits(deployCode("TapeHarness.sol:TapeCircuits"));
        fab = ITapeFab(deployCode("TapeHarness.sol:TapeFab", abi.encode(address(circuits))));
        sealedVM = new SealedVM();
        factory = new KernelFactory(
            address(manager),
            address(router),
            address(wokb),
            address(circuits),
            address(fab),
            address(sealedVM),
            address(beacon),
            address(impl),
            address(impl).codehash
        );
        lens = new Lens(address(factory));
        vm.deal(alice, 10_000 ether);
        KernelMath.OutputFields memory o;
        o.tBuy = 128;
        o.tHold = 64;
        o.tAllow = 48;
        o.tRes = 16;
        o.rel = 64;
        o.ceil = 1023;
        WORD = KernelMath.packOutput(o);
    }

    function _env() internal view returns (Envelope memory e) {
        e.launcher = launcher;
        e.epochLen = EPOCH;
        e.allowancePayee = payee;
        e.capT = 48;
        e.capV = 0;
        e.allowCumBps = 1875;
        e.ceilMax = 440;
        e.relMax = 128;
        e.floorRel = 2;
        e.floorMin = 1;
        e.fallbackEpochs = 16;
        e.fbAllow = 8;
        e.buyEnabled = true;
    }

    struct Built {
        Kernel kernel;
        MockToken token;
        MockVault vault;
        uint256 chipId;
    }

    function _build(bytes memory netlist, Envelope memory e, bytes32 salt) internal returns (Built memory b) {
        vm.prank(launcher);
        b.chipId = fab.tapeoutChip(netlist);
        b.kernel = Kernel(payable(factory.create(e, b.chipId, salt)));
        (address t, address v) = manager.createToken(launcher, address(b.kernel), 300, 300, 0, 0, 85 ether);
        b.token = MockToken(t);
        b.vault = MockVault(payable(v));
        vm.prank(launcher);
        circuits.transferFrom(launcher, address(b.kernel), b.chipId);
        b.kernel.bind(t);
    }

    function _buy(Built memory b, uint256 amount) internal {
        vm.prank(alice);
        manager.buy{value: amount}(address(b.token), amount, 0);
    }

    function _settleGas(Built memory b) internal returns (uint256 used) {
        vm.prank(keeper);
        uint256 g0 = gasleft();
        b.kernel.settle();
        used = g0 - gasleft();
    }

    // ------------------------------------------------------------------ a 2,200-gate chip

    /// What one settle of a 2,200-gate chip costs on each evaluator, with a claim, the step, an allowance
    /// credit, a release and a curve buy.
    function test_settle_gas_2200_gates() public {
        bytes memory nl = Netlists.synthetic(2200, 64, WORD, 1);
        assertEq(nl.length, 64 * 4 + 2136 * 7, "64 latches and 2,136 NANDs");
        Built memory b = _build(nl, _env(), "g2200");
        Globals memory g = b.kernel.globals();
        assertEq(g.gateCount, 2200);
        assertEq(g.nState, 64);
        assertEq(g.stepFloor, 200_000 + 2_600 * 2200 + 800 * 64);
        assertEq(g.sealedFloor, 40_000 + 200 * 2136 + 400 * 64);

        Lens.Preflight memory p = lens.preflight(address(b.kernel));
        assertTrue(p.tapeoutRan && p.sealedRan && p.agree, "both evaluators run the chip inside their gas and agree");
        console2.log("2,200 gates: step gas, TapeOut NetlistVM   ", p.tapeoutGas);
        console2.log("2,200 gates: step gas, SealedVM            ", p.sealedGas);
        console2.log("2,200 gates: gas given to TapeOut's step   ", p.stepFloor);
        console2.log("2,200 gates: gas given to the sealed step  ", p.sealedFloor);
        console2.log("2,200 gates: minSettleGas (gas limit)      ", p.minSettleGas);
        assertLt(p.tapeoutGas, (p.stepFloor * 95) / 100, "TapeOut's step leaves at least 5% of its gas unused");
        assertLt(p.sealedGas, (p.sealedFloor * 95) / 100, "and so does the sealed evaluator's");
        assertLt(p.sealedGas, p.tapeoutGas, "the sealed evaluator is cheaper than TapeOut's");

        // first settle: cold storage, first record
        _buy(b, 5 ether);
        vm.warp(block.timestamp + EPOCH);
        uint256 g1 = _settleGas(b);
        // second settle: the steady state
        _buy(b, 5 ether);
        vm.warp(block.timestamp + EPOCH);
        uint256 g2 = _settleGas(b);
        Record memory r = b.kernel.records(2);
        assertEq(r.flags, 0);
        assertEq(r.clampBits, 0);
        assertGt(r.buyExecuted, 0);
        assertGt(r.allow, 0);
        assertEq(KernelMath.outputWord(r.outputs), WORD);
        console2.log("2,200 gates: settle gas, TapeOut, first    ", g1);
        console2.log("2,200 gates: settle gas, TapeOut, steady   ", g2);

        beacon.upgradeTo(address(new MockImplV2())); // the kernel switches to the sealed evaluator
        _buy(b, 5 ether);
        vm.warp(block.timestamp + EPOCH);
        uint256 g3 = _settleGas(b);
        r = b.kernel.records(3);
        assertEq(r.flags, RecordFlags.SEALED);
        assertEq(KernelMath.outputWord(r.outputs), WORD);
        console2.log("2,200 gates: settle gas, SealedVM, steady  ", g3);
        assertLt(g2, b.kernel.minSettleGas());
        assertLt(g3, g2);
    }

    function test_largest_chip_fits() public {
        bytes memory nl = Netlists.synthetic(3400, 256, WORD, 2);
        assertLe(nl.length, 24_000);
        Built memory b = _build(nl, _env(), "g3400");
        Lens.Preflight memory p = lens.preflight(address(b.kernel));
        assertTrue(p.tapeoutRan && p.sealedRan && p.agree);
        console2.log("3,400 gates: step gas, TapeOut NetlistVM   ", p.tapeoutGas);
        console2.log("3,400 gates: step gas, SealedVM            ", p.sealedGas);
        console2.log("3,400 gates: gas given to TapeOut's step   ", p.stepFloor);
        console2.log("3,400 gates: gas given to the sealed step  ", p.sealedFloor);
        console2.log("3,400 gates: minSettleGas                  ", p.minSettleGas);
        assertEq(p.stepFloor, 200_000 + 2_600 * 3400 + 800 * 256);
        assertEq(p.sealedFloor, 40_000 + 200 * 3144 + 400 * 256);
        assertLt(p.minSettleGas, 15_500_000, "the largest chip settles 1.2M below a 16,777,216 transaction cap");
        _buy(b, 5 ether);
        vm.warp(block.timestamp + EPOCH);
        uint256 used = _settleGas(b);
        console2.log("3,400 gates: settle gas, TapeOut, first    ", used);
        assertEq(b.kernel.count(), 1);
        // with exactly minSettleGas
        _buy(b, 5 ether);
        vm.warp(block.timestamp + EPOCH);
        vm.prank(keeper);
        (bool ok,) = address(b.kernel).call{gas: p.minSettleGas}(abi.encodeCall(IKernelMin.settle, ()));
        assertTrue(ok);
        assertEq(b.kernel.records(2).flags, 0);
    }

    // ------------------------------------------------------------------ both evaluators, one history

    /// The same token history settled twice, once on each evaluator, gives identical records (apart from
    /// the evaluator flag). Both replay on both evaluators.
    function test_two_evaluators_one_history() public {
        // a state-dependent chip: all to buy-and-lock from even states, allowance and reserve from odd ones
        KernelMath.OutputFields memory o;
        o.tAllow = 48;
        o.tRes = 208;
        o.rel = 32;
        o.ceil = 1023;
        uint256 wordB = KernelMath.packOutput(o);
        bytes memory nl = Netlists.toggle(256 | (uint256(1023) << 81), wordB);
        Built memory b = _build(nl, _env(), "toggle");
        assertEq(b.kernel.globals().nState, 1);
        assertEq(b.kernel.globals().gateCount, 114);

        uint256 snap = vm.snapshotState();
        bytes32[6] memory onTapeOut = _run(b, 6);
        vm.revertToState(snap);
        beacon.upgradeTo(address(new MockImplV2()));
        bytes32[6] memory onSealed = _run(b, 6);
        for (uint256 i = 0; i < 6; i++) {
            assertEq(onTapeOut[i], onSealed[i], "identical records on both evaluators");
        }
        // every record of the sealed history replays on TapeOut's evaluator too, and the other way round
        for (uint32 n = 1; n <= 6; n++) {
            assertTrue(lens.replayOn(address(b.kernel), n, false).ok, "replay on TapeOut");
            assertTrue(lens.replayOn(address(b.kernel), n, true).ok, "replay on the sealed evaluator");
        }
        // the state decides: odd and even settles route differently
        assertTrue(b.kernel.records(1).outputs != b.kernel.records(2).outputs);
        (bool matters,,) = lens.stateMatters(address(b.kernel), 2);
        assertTrue(matters);
    }

    function _run(Built memory b, uint256 n) internal returns (bytes32[6] memory digests) {
        for (uint256 i = 0; i < n; i++) {
            _buy(b, (i + 1) * 1 ether);
            vm.warp(block.timestamp + EPOCH);
            vm.prank(keeper);
            b.kernel.settle();
            Record memory r = b.kernel.records(uint32(i + 1));
            r.flags &= ~RecordFlags.SEALED;
            digests[i] = keccak256(abi.encode(r, b.kernel.state(), b.kernel.reserve(), address(b.kernel).balance));
        }
    }

    // ------------------------------------------------------------------ the taped Flow Governor

    /// @dev The fixed copy of the Flow Governor netlist (see the contract comment).
    function _flowGovernor() internal view returns (bytes memory nl) {
        nl = vm.parseBytes(vm.trim(vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/fg.hex"))));
        assertEq(nl.length, 13_479, "the fixture is the 2026-10-04 build");
        assertEq(keccak256(nl), 0x2fd0e007398296a5845c8a7e3b99d5149d6c02ae670afe373abd191fb2591a89);
    }

    /// The flagship chip, byte for byte as the chip tools emitted it, on the kernel with its own envelope
    /// (chips/rtl/fg_params.json). A proven chip never sets a clamp bit.
    function test_flow_governor_on_the_kernel() public {
        Built memory b = _build(_flowGovernor(), _env(), "fg");
        Globals memory g = b.kernel.globals();
        console2.log("Flow Governor: gates                        ", g.gateCount);
        console2.log("Flow Governor: latches                      ", g.nState);
        console2.log("Flow Governor: netlist bytes                ", g.netlistLen);
        assertEq(g.nState, 64);
        assertEq(g.gateCount, 1953);
        assertEq(g.stepFloor, 200_000 + 2_600 * 1953 + 800 * 64);
        assertEq(g.sealedFloor, 40_000 + 200 * 1889 + 400 * 64);

        Lens.Preflight memory p = lens.preflight(address(b.kernel));
        assertTrue(p.tapeoutRan && p.sealedRan && p.agree);
        console2.log("Flow Governor: step gas, TapeOut NetlistVM  ", p.tapeoutGas);
        console2.log("Flow Governor: step gas, SealedVM           ", p.sealedGas);
        console2.log("Flow Governor: gas given to TapeOut's step  ", p.stepFloor);
        console2.log("Flow Governor: gas given to the sealed step ", p.sealedFloor);
        console2.log("Flow Governor: minSettleGas                 ", p.minSettleGas);

        // forty epochs of uneven flow: TapeOut for twenty, then (after a TapeOut upgrade) the sealed evaluator
        // for ten, then TapeOut's step failing under unchanged pins for ten, so the sealed one answers again
        MockImplV2 v2 = new MockImplV2();
        uint256 gasMax;
        for (uint256 i = 0; i < 40; i++) {
            uint256 size = (uint256(keccak256(abi.encode("flow", i))) % 6 ether);
            if (i % 5 != 4 && size > 0.01 ether) _buy(b, size);
            if (i == 20) beacon.upgradeTo(address(v2));
            if (i == 30) {
                beacon.upgradeTo(address(impl));
                // TapeOut's step reverts from here on, with the beacon, the code hash, the pin counts and
                // the netlist bytes all as pinned
                vm.mockCallRevert(address(circuits), abi.encodeWithSelector(ITapeCircuits.step.selector), "down");
            }
            vm.warp(block.timestamp + EPOCH * (i % 7 == 6 ? 3 : 1));
            uint256 used = _settleGas(b);
            if (used > gasMax) gasMax = used;
        }
        vm.clearMockedCalls();
        console2.log("Flow Governor: largest settle gas in 40     ", gasMax);
        assertEq(b.kernel.count(), 40);
        uint256 modes;
        for (uint32 n = 1; n <= 40; n++) {
            Record memory r = b.kernel.records(n);
            assertEq(r.clampBits, 0, "the chip decides: no clamp on any epoch");
            assertEq(r.flags & (RecordFlags.FALLBACK | RecordFlags.CLAIM_FAILED | RecordFlags.BUY_FAILED), 0);
            assertEq(r.flags & RecordFlags.SEALED != 0, n > 20, "TapeOut's answer for 20 epochs, the sealed one for 20");
            KernelMath.OutputFields memory o = KernelMath.unpackOutput(KernelMath.outputWord(r.outputs));
            assertEq(o.tBuy + o.tHold + o.tAllow + o.tRes, 256, "share group sums to 256");
            modes |= 1 << o.mode;
            assertTrue(lens.replayOn(address(b.kernel), n, false).ok, "replay on TapeOut");
            assertTrue(lens.replayOn(address(b.kernel), n, true).ok, "replay on the sealed evaluator");
        }
        assertGt(modes & (modes - 1), 0, "the chip was seen in more than one mode");
        assertGe(address(b.kernel).balance, b.kernel.totalCredits(NATIVE) + b.kernel.reserve());
    }

    /// The same history on the real chip with TapeOut's step dead from the start and the pins unchanged: every
    /// record is the one TapeOut would have produced, because the sealed evaluator answers in its place.
    function test_flow_governor_same_records_when_tapeouts_step_fails() public {
        Built memory b = _build(_flowGovernor(), _env(), "fg2");
        uint256 snap = vm.snapshotState();
        bytes32[6] memory onTapeOut = _run(b, 6);
        vm.revertToState(snap);
        vm.mockCallRevert(address(circuits), abi.encodeWithSelector(ITapeCircuits.step.selector), "down");
        (, bool sealedMode) = b.kernel.evaluator();
        assertFalse(sealedMode, "the pins hold: TapeOut is asked first");
        bytes32[6] memory onSealed = _run(b, 6);
        for (uint256 i = 0; i < 6; i++) {
            assertEq(onTapeOut[i], onSealed[i], "identical records, whoever answered");
            assertTrue(b.kernel.records(uint32(i + 1)).flags & RecordFlags.SEALED != 0);
        }
    }

    /// THE ONE TEST THAT READS THE LIVE CHIP. chips/out/fg.hex is rebuilt by the chip tools, so nothing here
    /// depends on its size, its hash or what it decides. It asserts what any build of it must satisfy to be
    /// used with this kernel: it is an interface-v1 chip (section 2, as the Fab checks it), the factory accepts
    /// it, both evaluators agree on it, and each evaluator runs it inside the gas the kernel gives it.
    /// (TapeOut's evaluator is the vendored source in a test build here; its gas on the deployed
    /// implementation is measured by the fork suites.)
    function test_live_chip_is_a_v1_chip_both_evaluators_agree_and_it_fits_the_step_gas() public {
        string memory path = string.concat(vm.projectRoot(), "/../../chips/out/fg.hex");
        if (!vm.exists(path)) {
            console2.log("chips/out/fg.hex not found: skipped");
            vm.skip(true);
        }
        bytes memory nl = vm.parseBytes(vm.trim(vm.readFile(path)));

        // 1. shape: section 2 of the interface
        (uint256 nNand, uint256 nLatch) = new ScanProbe().scan(nl);
        console2.log("live chip: bytes ", nl.length);
        console2.log("live chip: NAND  ", nNand);
        console2.log("live chip: LATCH ", nLatch);
        console2.logBytes32(keccak256(nl));
        assertTrue(nLatch >= 1 && nLatch <= 256, "1..256 state bits");
        assertTrue(nNand + nLatch >= 112 && nNand + nLatch <= 3400, "112..3400 records");
        assertLe(nl.length, 24_000, "one SSTORE2 chunk");
        assertEq(nl.length, 7 * nNand + 4 * nLatch, "NAND and LATCH records only");

        // 2. TapeOut's own tape-out check accepts it with 96 inputs and 112 outputs, and the factory takes it
        Built memory b = _build(nl, _env(), "live");
        Globals memory g = b.kernel.globals();
        assertEq(g.nState, nLatch);
        assertEq(g.gateCount, nNand + nLatch);
        assertEq(g.netlistLen, nl.length);
        assertEq(g.netlistHash, keccak256(nl));

        // 3. each evaluator answers inside the gas the kernel gives it, and they agree
        Lens.Preflight memory p = lens.preflight(address(b.kernel));
        assertTrue(p.tapeoutRan, "TapeOut's evaluator fits stepFloor");
        assertTrue(p.sealedRan, "the sealed evaluator fits sealedFloor");
        assertTrue(p.agree, "and they agree at the zero state");
        console2.log("live chip: step gas, TapeOut NetlistVM / given", p.tapeoutGas, p.stepFloor);
        console2.log("live chip: step gas, SealedVM / given         ", p.sealedGas, p.sealedFloor);
        assertLt(p.tapeoutGas, (p.stepFloor * 95) / 100, "at least 5% of TapeOut's gas unused");
        assertLt(p.sealedGas, (p.sealedFloor * 95) / 100, "at least 5% of the sealed evaluator's gas unused");

        // the all-ones state with all-ones inputs (the costliest beat), then eight chained beats on random inputs
        bytes memory state = abi.encodePacked(bytes32(type(uint256).max));
        bytes memory inputs = abi.encodePacked(bytes12(type(uint96).max));
        for (uint256 i = 0; i < 9; i++) {
            state = _liveBeat(b.chipId, g, state, inputs);
            inputs = abi.encodePacked(bytes12(keccak256(abi.encode("beat", i))));
        }

        // 4. and one settle of it on the kernel, on each evaluator
        _liveSettles(b);
    }

    /// @dev One beat of the live chip on both evaluators, each with the gas the kernel gives it: same answer,
    ///      right lengths, gas to spare. Returns the next state as the kernel would pass it on (32 bytes).
    function _liveBeat(uint256 chipId, Globals memory g, bytes memory state, bytes memory inputs)
        internal
        view
        returns (bytes memory)
    {
        uint256 g0 = gasleft();
        (bytes memory nsT, bytes memory outT) = circuits.step{gas: g.stepFloor}(chipId, state, inputs);
        uint256 gasT = g0 - gasleft();
        g0 = gasleft();
        (bytes memory nsS, bytes memory outS) = sealedVM.step{gas: g.sealedFloor}(g.snapshot, 96, 112, state, inputs);
        uint256 gasS = g0 - gasleft();
        assertEq(nsS, nsT, "same next state from both evaluators");
        assertEq(outS, outT, "same outputs from both evaluators");
        assertEq(nsT.length, (uint256(g.nState) + 7) / 8, "ceil(nState / 8) state bytes");
        assertEq(outT.length, 14, "14 output bytes");
        assertLt(gasT, (g.stepFloor * 95) / 100);
        assertLt(gasS, (g.sealedFloor * 95) / 100);
        return abi.encodePacked(bytes32(nsT));
    }

    function _liveSettles(Built memory b) internal {
        vm.warp(block.timestamp + EPOCH);
        vm.prank(keeper);
        b.kernel.settle();
        beacon.upgradeTo(address(new MockImplV2()));
        vm.warp(block.timestamp + EPOCH);
        vm.prank(keeper);
        b.kernel.settle();
        assertEq(b.kernel.records(1).flags & (RecordFlags.FALLBACK | RecordFlags.SEALED), 0);
        assertEq(b.kernel.records(2).flags & (RecordFlags.FALLBACK | RecordFlags.SEALED), RecordFlags.SEALED);
        assertTrue(lens.replayOn(address(b.kernel), 1, true).ok);
        assertTrue(lens.replayOn(address(b.kernel), 2, false).ok);
    }

    /// Gas-limit sweep on the real evaluator: the step really costs millions here, so the sweep crosses the
    /// point where a starved step would have run out of gas.
    function test_gas_sweep_with_a_real_step() public {
        bytes memory nl = Netlists.synthetic(2200, 64, WORD, 3);
        Built memory b = _build(nl, _env(), "sweep");
        _buy(b, 5 ether);
        vm.warp(block.timestamp + EPOCH);
        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        b.kernel.settle();
        bytes32 ref = keccak256(abi.encode(b.kernel.records(1), b.kernel.state(), address(b.kernel).balance));
        vm.revertToState(snap);

        uint256 m = b.kernel.minSettleGas();
        uint256 minOk;
        for (uint256 gasLimit = 4_000_000; gasLimit <= m + 100_000; gasLimit += 60_000) {
            snap = vm.snapshotState();
            vm.prank(keeper);
            (bool ok, bytes memory ret) = address(b.kernel).call{gas: gasLimit}(abi.encodeCall(IKernelMin.settle, ()));
            if (ok) {
                bytes32 d = keccak256(abi.encode(b.kernel.records(1), b.kernel.state(), address(b.kernel).balance));
                assertEq(d, ref, "same record at every gas limit that returns");
                if (minOk == 0) minOk = gasLimit;
            } else {
                assertEq(bytes4(ret), Kernel.InsufficientGas.selector, "under-funding is refused up front");
            }
            vm.revertToState(snap);
        }
        assertGt(minOk, 0);
        assertLe(minOk, m);
    }
}
