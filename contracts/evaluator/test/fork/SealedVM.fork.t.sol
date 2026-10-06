// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";

import {Fab} from "../../src/Fab.sol";
import {SealedVM} from "../../src/SealedVM.sol";
import {IFabV1} from "../../src/interfaces/IFabV1.sol";
import {ISealedVM} from "../../src/interfaces/ISealedVM.sol";
import {NetlistBuilder} from "../utils/NetlistBuilder.sol";
import {ICircuitsView, ITapeOutFactory} from "../utils/Oracles.sol";
import {ScanHarness} from "../utils/ScanHarness.sol";
import {XLayerFork} from "../utils/XLayerFork.sol";

/// @notice SealedVM against two large circuits that other teams taped out on X Layer, read from the
///         chain at the pinned block. They are flat (no REF) but larger than a v1 chip and with other pin
///         counts, so they test the evaluator only, not the Fab.
contract SealedVMLiveCircuitsForkTest is XLayerFork {
    SealedVM internal sealedVM;
    ScanHarness internal store;

    /// @dev Circuit 3: 133 inputs, 199 outputs, 243 state bits, 4,863 gates, 33,312 bytes of netlist.
    address internal constant LIVE_A = 0xAa13ae45b0B2D52f210Ad7Ef12997113a0ebAF21;
    /// @dev Circuit 1: 161 inputs, 1 output, 288 state bits, 3,035 gates, 20,381 bytes of netlist.
    address internal constant LIVE_B = 0x933FC3AA0c387CB8B6B1D22a2Ec3E2B5eeCfDb5a;

    function setUp() public {
        _selectFork();
        sealedVM = new SealedVM();
        store = new ScanHarness();
    }

    function _same(
        ICircuitsView c,
        uint256 id,
        address pointer,
        uint32 nIn,
        uint32 nOut,
        bytes memory s,
        bytes memory x
    ) internal view returns (bytes memory newState) {
        (bool okT, bytes memory retT) = address(c).staticcall(abi.encodeCall(ICircuitsView.step, (id, s, x)));
        (bool okS, bytes memory retS) =
            address(sealedVM).staticcall(abi.encodeCall(ISealedVM.step, (pointer, nIn, nOut, s, x)));
        assertTrue(okT, "Circuits.step reverted");
        assertTrue(okS, "SealedVM.step reverted");
        assertEq(retS, retT, "SealedVM and the live circuit return different data");
        (newState,) = abi.decode(retS, (bytes, bytes));
    }

    function _vector(uint256 seed, uint256 n) internal pure returns (bytes memory) {
        uint256 exact = NetlistBuilder.bytesFor(n);
        uint256 mode = seed % 4;
        uint256 r = uint256(keccak256(abi.encode(seed, "vector")));
        if (mode == 0) return NetlistBuilder.randomBytes(r, exact);
        if (mode == 1) return NetlistBuilder.randomBytes(r, r % exact);
        if (mode == 2) return NetlistBuilder.randomBytes(r, exact + 1 + (r % 40));
        return "";
    }

    function _check(ICircuitsView c, uint256 id, address pointer, uint32 nIn, uint32 nOut, uint32 nState)
        internal
        view
    {
        // random state and inputs, exact, short, over-long and empty
        for (uint256 i = 0; i < 40; i++) {
            uint256 r = uint256(keccak256(abi.encode(address(c), i)));
            _same(c, id, pointer, nIn, nOut, _vector(r, nState), _vector(r >> 64, nIn));
        }
        // sixteen beats in a row from the zero state
        bytes memory state = new bytes(NetlistBuilder.bytesFor(nState));
        for (uint256 beat = 0; beat < 16; beat++) {
            bytes memory inputs = NetlistBuilder.randomBytes(beat, NetlistBuilder.bytesFor(nIn));
            state = _same(c, id, pointer, nIn, nOut, state, inputs);
        }
    }

    function test_fork_liveCircuit_4863gates_133in_199out_243state() public {
        ICircuitsView c = ICircuitsView(LIVE_A);
        (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount) = c.circuitInfo(3);
        assertEq(nIn, 133);
        assertEq(nOut, 199);
        assertEq(nState, 243);
        assertEq(gateCount, 4863);

        // 33,312 bytes do not fit one deployed pointer (TapeOut stores them in two chunks), so the
        // pointer's code is set directly.
        bytes memory nl = c.netlist(3);
        assertEq(nl.length, 33312);
        address pointer = address(uint160(0x5ea1edc0de02));
        vm.etch(pointer, abi.encodePacked(hex"00", nl));

        _check(c, 3, pointer, nIn, nOut, nState);
    }

    function test_fork_liveCircuit_3035gates_161in_1out_288state() public {
        ICircuitsView c = ICircuitsView(LIVE_B);
        (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount) = c.circuitInfo(1);
        assertEq(nIn, 161);
        assertEq(nOut, 1);
        assertEq(nState, 288);
        assertEq(gateCount, 3035);

        // 20,381 bytes: a real SSTORE2 pointer, written by the library the Fab uses
        bytes memory nl = c.netlist(1);
        assertEq(nl.length, 20381);
        address pointer = store.write(nl);
        assertEq(pointer.code, abi.encodePacked(hex"00", nl));

        _check(c, 1, pointer, nIn, nOut, nState);
    }
}

/// @notice Gas of one beat on the deployed `Circuits.step` and on `SealedVM.step`, for the same v1 chips,
///         and of `Fab.tapeoutChip`. Run with -vv to see the numbers.
/// @dev Chips are taped out in setUp, so each test starts with every account cold, as a transaction would.
contract EvaluatorGasForkTest is XLayerFork {
    ICircuitsView internal circuits;
    Fab internal fab;
    SealedVM internal sealedVM;

    uint256 internal constant N_STATE = 64;
    uint256[3] internal gates = [uint256(500), 2000, 3400];
    uint256[3] internal chip;

    address internal alice = makeAddr("alice");

    function setUp() public {
        _selectFork();
        ITapeOutFactory factory = ITapeOutFactory(TAPEOUT_FACTORY);
        address creator = makeAddr("splitter");
        vm.deal(creator, 1 ether);
        vm.deal(alice, 100 ether);
        vm.prank(creator);
        (address t, address c) =
            factory.createCPU{value: factory.deployFee()}("Covenant", "CVNT", "gas report", 67_108_864, 0.00002 ether);
        circuits = ICircuitsView(c);
        fab = new Fab(c, t);
        sealedVM = new SealedVM();

        for (uint256 i = 0; i < 3; i++) {
            bytes memory nl = _netlist(i);
            (,, uint256 cost) = fab.quote(nl);
            vm.prank(alice);
            chip[i] = fab.tapeoutChip{value: cost}(nl, bytes32(0));
        }
    }

    function _netlist(uint256 i) internal view returns (bytes memory) {
        return NetlistBuilder.randomV1(0xC0DE + i, N_STATE, gates[i] - N_STATE);
    }

    /// @dev Gas of the two evaluators for chip `i`, each measured from a cold start, results compared.
    function _measure(uint256 i) internal view returns (uint256 gasTapeOut, uint256 gasSealed) {
        (address pointer,,,,,) = fab.chipInfo(chip[i]);
        bytes memory state = NetlistBuilder.randomBytes(i, 32);
        bytes memory inputs = NetlistBuilder.randomBytes(i + 99, 12);

        uint256 g = gasleft();
        (bytes memory nsS, bytes memory outS) = sealedVM.step(pointer, 96, 112, state, inputs);
        gasSealed = g - gasleft();

        g = gasleft();
        (bytes memory nsT, bytes memory outT) = circuits.step(chip[i], state, inputs);
        gasTapeOut = g - gasleft();

        assertEq(nsS, nsT);
        assertEq(outS, outT);
    }

    function _report(uint256 i) internal view {
        (uint256 gasTapeOut, uint256 gasSealed) = _measure(i);
        console2.log("gates:", gates[i], " state bits:", N_STATE);
        console2.log("  Circuits.step gas:", gasTapeOut, " per gate:", gasTapeOut / gates[i]);
        console2.log("  SealedVM.step gas:", gasSealed, " per gate:", gasSealed / gates[i]);
        console2.log("  TapeOut / SealedVM, x100:", gasTapeOut * 100 / gasSealed);
        assertLt(gasSealed * 8, gasTapeOut, "SealedVM should be at least eight times cheaper than TapeOut");
        assertLt(gasSealed, 250 * gates[i], "SealedVM should stay under 250 gas per gate, overhead included");
    }

    function test_fork_gas_step_500gates() public view {
        _report(0);
    }

    function test_fork_gas_step_2000gates() public view {
        _report(1);
    }

    function test_fork_gas_step_3400gates() public view {
        _report(2);
    }

    /// @notice Cost of one more gate: the difference between the 3,400-gate and the 500-gate chip.
    function test_fork_gas_step_perExtraGate() public view {
        (uint256 t0, uint256 s0) = _measure(0);
        (uint256 t2, uint256 s2) = _measure(2);
        console2.log("gas per extra gate, Circuits.step:", (t2 - t0) / 2900);
        console2.log("gas per extra gate, SealedVM.step:", (s2 - s0) / 2900);
        assertLt((s2 - s0) / 2900, 200);
    }

    /// @notice Gas of taping out a 2,000-gate chip through the Fab: execution, plus the intrinsic cost
    ///         of its 13.8 KB of calldata.
    function test_fork_gas_tapeoutChip_2000gates() public {
        bytes memory nl = NetlistBuilder.randomV1(0xFAB, N_STATE, 2000 - N_STATE);
        (,, uint256 cost) = fab.quote(nl);
        bytes memory data = abi.encodeCall(IFabV1.tapeoutChip, (nl, bytes32(0)));

        uint256 intrinsic = _intrinsic(data);

        vm.prank(alice);
        uint256 g = gasleft();
        (bool ok,) = address(fab).call{value: cost}(data);
        uint256 execution = g - gasleft();
        assertTrue(ok);

        console2.log("Fab.tapeoutChip, 2,000 gates (64 LATCH + 1,936 NAND), netlist bytes:", nl.length);
        console2.log("  execution gas:", execution);
        console2.log("  intrinsic gas (21000 + calldata):", intrinsic);
        console2.log("  total:", execution + intrinsic);
        console2.log("  cost in wei (transistors + TapeOut fees):", cost);
        assertLt(execution + intrinsic, 12_000_000);
    }

    /// @notice The same for the two extreme chips the Fab accepts: the most bytes (1 LATCH, 3,399 NAND:
    ///         23,797 bytes) and the most state (256 LATCH, 3,144 NAND). Both must fit a 16,777,216-gas
    ///         transaction, the cap Ethereum adopted with Osaka, should X Layer ever apply it.
    function test_fork_gas_tapeoutChip_largestChips() public {
        uint256[2][2] memory shapes = [[uint256(1), 3399], [uint256(256), 3144]];
        for (uint256 i = 0; i < 2; i++) {
            bytes memory nl = NetlistBuilder.randomV1(0xFAB + i, shapes[i][0], shapes[i][1]);
            (,, uint256 cost) = fab.quote(nl);
            bytes memory data = abi.encodeCall(IFabV1.tapeoutChip, (nl, bytes32(0)));
            uint256 intrinsic = _intrinsic(data);

            vm.prank(alice);
            uint256 g = gasleft();
            (bool ok,) = address(fab).call{value: cost}(data);
            uint256 execution = g - gasleft();
            assertTrue(ok);

            console2.log("Fab.tapeoutChip, 3,400 gates, LATCH records:", shapes[i][0], " netlist bytes:", nl.length);
            console2.log("  execution gas:", execution, " intrinsic gas:", intrinsic);
            console2.log("  total:", execution + intrinsic);
            assertLt(execution + intrinsic, 16_777_216);
        }
    }

    /// @dev 21,000 plus 4 gas per zero byte and 16 per non-zero byte of calldata.
    function _intrinsic(bytes memory data) internal pure returns (uint256) {
        uint256 zeros;
        for (uint256 i = 0; i < data.length; i++) {
            if (data[i] == 0) zeros++;
        }
        return 21000 + 4 * zeros + 16 * (data.length - zeros);
    }
}
