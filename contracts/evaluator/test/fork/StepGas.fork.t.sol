// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";

import {Fab} from "../../src/Fab.sol";
import {SealedVM} from "../../src/SealedVM.sol";
import {ISealedVM} from "../../src/interfaces/ISealedVM.sol";
import {NetlistBuilder} from "../utils/NetlistBuilder.sol";
import {ICircuitsView, ITapeOutFactory} from "../utils/Oracles.sol";
import {XLayerFork} from "../utils/XLayerFork.sol";

interface IBeaconLike {
    function implementation() external view returns (address);
}

/// @dev Stands where a kernel stands: one call that first makes the four comparisons of INTERFACE.md
///      section 12 (they touch the beacon, the implementation, the processor and its stored netlist),
///      then gives the evaluator a fixed amount of gas.
contract SettleProbe {
    function attempt(
        bool compareFirst,
        address beacon,
        address circuits,
        uint256 id,
        address target,
        bytes calldata data,
        uint256 gasGiven
    ) external view returns (bool ok, bytes32 answer, uint256 spent) {
        if (compareFirst) {
            address impl = IBeaconLike(beacon).implementation();
            bytes32 codeHash = impl.codehash;
            ICircuitsView(circuits).circuitInfo(id);
            bytes32 netlistHash = keccak256(ICircuitsView(circuits).netlist(id));
            (codeHash, netlistHash);
        }
        uint256 g = gasleft();
        bytes memory ret;
        (ok, ret) = target.staticcall{gas: gasGiven}(data);
        spent = g - gasleft();
        answer = keccak256(ret);
    }
}

/// @notice The numbers a kernel's step gas is set from: for a chip, a state and an input word, the least gas
///         each evaluator must be GIVEN for its `step` to succeed, found by bisection, against the two
///         amounts a kernel gives (chips/INTERFACE.md section 2):
///
///           TapeOut's evaluator   200,000 + 2,600 * gateCount + 800 * nState
///           the sealed evaluator   40,000 +   200 * nNand     + 400 * nLatch
///
///         What must be given is more than the gas the call uses: TapeOut's processor is a beacon proxy, and
///         the proxy can hand its implementation only 63/64 of what it has.
///
///         - `Circuits.step` is measured as a settle reaches it, after the four comparisons have touched
///           every account and slot it reads, and also from a cold start.
///         - `SealedVM.step` is measured from a cold start, which is how a settle reaches it: the kernel
///           has touched neither the evaluator nor the snapshot pointer.
///
///         The flagship chip measured here is the fixed copy test/fixtures/fg.hex (the chip as built on
///         2026-10-04). Exactly one test, `test_fork_liveChip_...`, reads the chip tools' current output
///         chips/out/fg.hex, and it asserts only what must hold for any build of it.
///
///         Run with -vv.
contract StepGasForkTest is XLayerFork {
    ICircuitsView internal circuits;
    Fab internal fab;
    SealedVM internal sealedVM;
    SettleProbe internal probe;

    address internal alice = makeAddr("alice");
    bytes internal constant ZERO_STATE = hex"0000000000000000000000000000000000000000000000000000000000000000";
    bytes internal constant ONES_STATE = hex"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
    bytes internal constant ZERO_INPUTS = hex"000000000000000000000000";
    bytes internal constant ONES_INPUTS = hex"ffffffffffffffffffffffff";

    struct Floor {
        uint256 tapeOutSettle; // least gas for Circuits.step after the kernel's comparisons
        uint256 tapeOutCold; // least gas for Circuits.step from a cold start
        uint256 sealedCold; // least gas for SealedVM.step from a cold start
    }

    function setUp() public {
        _selectFork();
        ITapeOutFactory factory = ITapeOutFactory(TAPEOUT_FACTORY);
        address creator = makeAddr("splitter");
        vm.deal(creator, 1 ether);
        vm.deal(alice, 100 ether);
        vm.prank(creator);
        (address t, address c) =
            factory.createCPU{value: factory.deployFee()}("Covenant", "CVNT", "step gas", 67_108_864, 0.00002 ether);
        circuits = ICircuitsView(c);
        fab = new Fab(c, t);
        sealedVM = new SealedVM();
        probe = new SettleProbe();
    }

    function _tape(bytes memory nl) internal returns (uint256 id, address pointer) {
        (,, uint256 cost) = fab.quote(nl);
        vm.prank(alice);
        id = fab.tapeoutChip{value: cost}(nl, bytes32(0));
        (pointer,,,,,) = fab.chipInfo(id);
    }

    /// @dev Least `gasGiven` for which the call succeeds with the right answer. Every attempt starts from
    ///      the same warmth: Foundry runs each top-level call as its own transaction, and the two accounts
    ///      a settle would find cold are cooled explicitly as well.
    function _least(bool compareFirst, uint256 id, address target, bytes memory data, address pointer)
        internal
        returns (uint256 hi)
    {
        (bool ok, bytes32 want,) = probe.attempt(false, CIRCUIT_BEACON, address(circuits), id, target, data, 30_000_000);
        assertTrue(ok, "evaluator failed with ample gas");

        uint256 lo = 0;
        hi = 30_000_000;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            vm.cool(address(sealedVM));
            vm.cool(pointer);
            (bool fine, bytes32 answer,) =
                probe.attempt(compareFirst, CIRCUIT_BEACON, address(circuits), id, target, data, mid);
            if (fine && answer == want) hi = mid;
            else lo = mid;
        }
    }

    function _floors(uint256 id, address pointer, bytes memory state, bytes memory inputs)
        internal
        returns (Floor memory f)
    {
        bytes memory tapeOut = abi.encodeCall(ICircuitsView.step, (id, state, inputs));
        bytes memory sealedCall = abi.encodeCall(ISealedVM.step, (pointer, 96, 112, state, inputs));

        // the two evaluators agree on this vector
        (, bytes32 a,) =
            probe.attempt(false, CIRCUIT_BEACON, address(circuits), id, address(circuits), tapeOut, 30_000_000);
        (, bytes32 b,) =
            probe.attempt(false, CIRCUIT_BEACON, address(circuits), id, address(sealedVM), sealedCall, 30_000_000);
        assertEq(a, b, "evaluators disagree");

        f.tapeOutSettle = _least(true, id, address(circuits), tapeOut, pointer);
        f.tapeOutCold = _least(false, id, address(circuits), tapeOut, pointer);
        f.sealedCold = _least(false, id, address(sealedVM), sealedCall, pointer);
    }

    function _print(string memory label, Floor memory f) internal pure {
        console2.log(label);
        console2.log("    Circuits.step, in a settle:", f.tapeOutSettle, " cold:", f.tapeOutCold);
        console2.log("    SealedVM.step, cold:       ", f.sealedCold);
    }

    /// @dev What a kernel gives each evaluator for one beat (chips/INTERFACE.md section 2; the kernel factory
    ///      in contracts/core computes the same two numbers).
    function _tapeOutGas(uint256 nNand, uint256 nLatch) internal pure returns (uint256) {
        return 200_000 + 2_600 * (nNand + nLatch) + 800 * nLatch;
    }

    function _sealedGas(uint256 nNand, uint256 nLatch) internal pure returns (uint256) {
        return 40_000 + 200 * nNand + 400 * nLatch;
    }

    /// @dev Every measured need must leave margin under what the kernel gives: 10% for TapeOut's evaluator,
    ///      20% for the sealed one. SealedVM must also stay inside its own published budget.
    function _assertFits(Floor memory f, uint256 nNand, uint256 nLatch) internal pure {
        assertLe(f.tapeOutSettle * 100, _tapeOutGas(nNand, nLatch) * 90, "TapeOut's step: less than 10% to spare");
        assertLe(f.sealedCold * 100, _sealedGas(nNand, nLatch) * 80, "the sealed step: less than 20% to spare");
        assertLe(f.sealedCold, 20_000 + 160 * nNand + 280 * nLatch, "SealedVM over its budget");
    }

    function _readHex(string memory path) internal view returns (bytes memory) {
        return vm.parseBytes(vm.trim(vm.readFile(path)));
    }

    /// @notice The flagship chip (the fixed copy of the 2026-10-04 build), at the zero state and
    ///         at the all-ones state, with zero and with all-ones inputs, and the worst of 8 random pairs.
    function test_fork_stepGas_flagship() public {
        bytes memory nl = _readHex("test/fixtures/fg.hex");
        assertEq(nl.length, 13_479, "the fixture is the 2026-10-04 build");
        assertEq(keccak256(nl), 0x2fd0e007398296a5845c8a7e3b99d5149d6c02ae670afe373abd191fb2591a89);
        (uint256 nNand, uint256 nLatch,) = fab.quote(nl);
        assertEq(nNand, 1889);
        assertEq(nLatch, 64);
        console2.log("flagship chip, fixture copy: bytes", nl.length);
        console2.log("  NAND:", nNand, " LATCH:", nLatch);
        (uint256 id, address pointer) = _tape(nl);

        Floor memory worst;
        Floor memory f = _floors(id, pointer, ZERO_STATE, ZERO_INPUTS);
        _print("  zero state, zero inputs", f);
        worst = _max(worst, f);
        f = _floors(id, pointer, ZERO_STATE, ONES_INPUTS);
        _print("  zero state, all-ones inputs", f);
        worst = _max(worst, f);
        f = _floors(id, pointer, ONES_STATE, ZERO_INPUTS);
        _print("  all-ones state, zero inputs", f);
        worst = _max(worst, f);
        f = _floors(id, pointer, ONES_STATE, ONES_INPUTS);
        _print("  all-ones state, all-ones inputs", f);
        worst = _max(worst, f);

        // eight random pairs, on the two paths a settle can take
        for (uint256 i = 0; i < 8; i++) {
            bytes memory state = NetlistBuilder.randomBytes(i, 32);
            bytes memory inputs = NetlistBuilder.randomBytes(i + 1000, 12);
            f.tapeOutSettle =
                _least(true, id, address(circuits), abi.encodeCall(ICircuitsView.step, (id, state, inputs)), pointer);
            f.sealedCold = _least(
                false, id, address(sealedVM), abi.encodeCall(ISealedVM.step, (pointer, 96, 112, state, inputs)), pointer
            );
            worst = _max(worst, f);
        }
        _print("  worst of the four above and 8 random pairs", worst);
        console2.log("  a kernel gives TapeOut's step:", _tapeOutGas(nNand, nLatch));
        console2.log("  a kernel gives the sealed step:", _sealedGas(nNand, nLatch));
        _assertFits(worst, nNand, nLatch);
    }

    /// @notice THE ONE TEST THAT READS THE LIVE CHIP. chips/out/fg.hex is rebuilt by the chip tools, so nothing
    ///         here depends on its size, its hash or what it computes. It asserts what any build of it must
    ///         satisfy: the Fab accepts it as an interface-v1 chip, the deployed `Circuits.step` and SealedVM
    ///         agree on it, and each evaluator runs it inside the gas a kernel gives it.
    function test_fork_liveChip_isAV1Chip_evaluatorsAgree_andFitsTheStepGas() public {
        string memory path = "../../chips/out/fg.hex";
        if (!vm.exists(path)) {
            console2.log("chips/out/fg.hex not found: skipped");
            vm.skip(true);
        }
        bytes memory nl = _readHex(path);

        // 1. shape: the Fab's own check of section 2 (it reverts with the reason otherwise)
        (uint256 nNand, uint256 nLatch,) = fab.quote(nl);
        console2.log("live chip chips/out/fg.hex: bytes", nl.length);
        console2.log("  NAND:", nNand, " LATCH:", nLatch);
        console2.logBytes32(keccak256(nl));
        assertTrue(nLatch >= 1 && nLatch <= 256, "1..256 state bits");
        assertTrue(nNand + nLatch >= 112 && nNand + nLatch <= 3400, "112..3400 records");
        assertLe(nl.length, 24_000);

        // 2. taped out through the Fab on the deployed TapeOut
        (uint256 id, address pointer) = _tape(nl);
        assertTrue(fab.isChip(id));
        assertEq(fab.snapshot(id), nl);
        _assertTapedAs(id, nNand, nLatch);

        // 3. both evaluators agree (checked inside _floors on every vector) and fit the gas a kernel gives
        Floor memory worst = _floors(id, pointer, ZERO_STATE, ZERO_INPUTS);
        worst = _max(worst, _floors(id, pointer, ONES_STATE, ONES_INPUTS));
        worst = _max(worst, _floors(id, pointer, NetlistBuilder.randomBytes(7, 32), NetlistBuilder.randomBytes(8, 12)));
        _print("  worst of the zero state, the all-ones state and one random pair", worst);
        console2.log("  a kernel gives TapeOut's step:", _tapeOutGas(nNand, nLatch));
        console2.log("  a kernel gives the sealed step:", _sealedGas(nNand, nLatch));
        _assertFits(worst, nNand, nLatch);
        _assertChainedBeatsAgree(id, pointer);
    }

    function _assertTapedAs(uint256 id, uint256 nNand, uint256 nLatch) internal view {
        (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount) = circuits.circuitInfo(id);
        assertEq(nIn, 96);
        assertEq(nOut, 112);
        assertEq(nState, nLatch);
        assertEq(gateCount, nNand + nLatch);
    }

    /// @dev Sixteen chained beats from the zero state: identical raw answers from the two evaluators.
    function _assertChainedBeatsAgree(uint256 id, address pointer) internal view {
        bytes memory state = ZERO_STATE;
        for (uint256 beat = 0; beat < 16; beat++) {
            bytes memory inputs = NetlistBuilder.randomBytes(beat + 50, 12);
            (bool okT, bytes memory retT) =
                address(circuits).staticcall(abi.encodeCall(ICircuitsView.step, (id, state, inputs)));
            (bool okS, bytes memory retS) =
                address(sealedVM).staticcall(abi.encodeCall(ISealedVM.step, (pointer, 96, 112, state, inputs)));
            assertTrue(okT && okS);
            assertEq(retS, retT, "SealedVM and Circuits.step return different data");
            (bytes memory next,) = abi.decode(retS, (bytes, bytes));
            state = abi.encodePacked(bytes32(next));
        }
    }

    /// @notice The corners of section 2, built so that every data-dependent cost is at its highest: every
    ///         LATCH takes constant 1, the 112 outputs are all 1, state and inputs are all ones. The same
    ///         chips at the zero state with zero inputs show how much the data matters.
    function test_fork_stepGas_cornersOfSectionTwo() public {
        uint256[2][4] memory shapes = [[uint256(256), 0], [uint256(256), 3144], [uint256(1), 3399], [uint256(1), 111]];
        string[4] memory names = [
            "most LATCH, fewest gates: 256 LATCH, 0 NAND",
            "largest, most LATCH: 256 LATCH, 3,144 NAND",
            "largest, most bytes: 1 LATCH, 3,399 NAND",
            "smallest: 1 LATCH, 111 NAND"
        ];
        for (uint256 i = 0; i < 4; i++) {
            (uint256 k, uint256 n) = (shapes[i][0], shapes[i][1]);
            bytes memory nl = _worstCaseChip(0xC0FFEE + i, k, n);
            (uint256 id, address pointer) = _tape(nl);

            console2.log(names[i]);
            Floor memory f = _floors(id, pointer, ONES_STATE, ONES_INPUTS);
            _print("  all-ones state, all-ones inputs", f);
            console2.log("    a kernel gives: TapeOut", _tapeOutGas(n, k), " sealed", _sealedGas(n, k));
            _assertFits(f, n, k);
            f = _floors(id, pointer, ZERO_STATE, ZERO_INPUTS);
            _print("  zero state, zero inputs", f);
            _assertFits(f, n, k);
        }
    }

    /// @dev A random v1 chip in which every LATCH takes constant 1 and, if it has that many NAND records,
    ///      the last 112 are NAND(0, 0) = 1, so every next-state bit and every output bit is 1.
    function _worstCaseChip(uint256 seed, uint256 k, uint256 n) internal pure returns (bytes memory nl) {
        nl = NetlistBuilder.randomV1(seed, k, n);
        for (uint256 j = 0; j < k; j++) {
            nl[4 * j + 1] = 0;
            nl[4 * j + 2] = 0;
            nl[4 * j + 3] = 0x01;
        }
        if (n >= 112) {
            for (uint256 j = n - 112; j < n; j++) {
                uint256 at = 4 * k + 7 * j;
                for (uint256 b = 1; b < 7; b++) {
                    nl[at + b] = 0;
                }
            }
        }
    }

    function _max(Floor memory a, Floor memory b) internal pure returns (Floor memory m) {
        m.tapeOutSettle = a.tapeOutSettle > b.tapeOutSettle ? a.tapeOutSettle : b.tapeOutSettle;
        m.tapeOutCold = a.tapeOutCold > b.tapeOutCold ? a.tapeOutCold : b.tapeOutCold;
        m.sealedCold = a.sealedCold > b.sealedCold ? a.sealedCold : b.sealedCold;
    }
}
