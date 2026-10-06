// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";

import {SealedVM} from "../src/SealedVM.sol";
import {ISealedVM} from "../src/interfaces/ISealedVM.sol";
import {BadOpcode, FutureSignal, LatchOutOfRange, TooFewSignals, TruncatedRecord} from "../src/lib/NetlistErrors.sol";
import {NetlistBuilder} from "./utils/NetlistBuilder.sol";
import {INetlistVMHarness} from "./utils/Oracles.sol";
import {SealedVMBase} from "./utils/SealedVMBase.sol";

/// @notice Unit tests of SealedVM: hand-built circuits, every rejection, the packing rules, and the
///         TAP-20 test vectors (test/fixtures/tap20-vectors.json, from TapeOutProtocol/TAPs, CC0).
contract SealedVMTest is SealedVMBase {
    // ------------------------------------------------------------------ helpers

    function _step(uint32 nIn, uint32 nOut, bytes memory state, bytes memory inputs)
        internal
        view
        returns (bytes memory, bytes memory)
    {
        return sealedVM.step(POINTER, nIn, nOut, state, inputs);
    }

    function _hex(string memory s) internal pure returns (bytes memory) {
        return vm.parseBytes(string.concat("0x", s));
    }

    // ------------------------------------------------------------------ semantics, by hand

    function test_nand_truthTable() public {
        _store(NetlistBuilder.nand(2, 3));
        bytes1[4] memory want = [bytes1(0x01), 0x01, 0x01, 0x00];
        for (uint256 v = 0; v < 4; v++) {
            (bytes memory ns, bytes memory out) = _step(2, 1, "", abi.encodePacked(uint8(v)));
            assertEq(ns.length, 0, "a circuit without LATCH has an empty state");
            assertEq(out, abi.encodePacked(want[v]));
        }
    }

    function test_constants() public {
        // NAND(0, 0) = 1, NAND(1, 1) = 0, NAND(0, 1) = 1
        _store(bytes.concat(NetlistBuilder.nand(0, 0), NetlistBuilder.nand(1, 1), NetlistBuilder.nand(0, 1)));
        (, bytes memory out) = _step(0, 3, "", "");
        assertEq(out, hex"05");
    }

    function test_latch_outputsStoredBit_thenTakesD() public {
        // LATCH d = input 0; output = NAND(latch, latch) = NOT latch
        _store(bytes.concat(NetlistBuilder.latch(2), NetlistBuilder.nand(3, 3)));

        // stored 0, input 1: the output shows the stored bit, not this beat's input
        (bytes memory ns, bytes memory out) = _step(1, 1, hex"00", hex"01");
        assertEq(out, hex"01");
        assertEq(ns, hex"01");

        // stored 1, input 0
        (ns, out) = _step(1, 1, hex"01", hex"00");
        assertEq(out, hex"00");
        assertEq(ns, hex"00");
    }

    function test_latch_forwardReference_toggles() public {
        // TAP-20's toggle: q' = q XOR en. The LATCH takes signal 7, which the last NAND produces.
        _store(hex"0100000700000003000002000000030000040000000200000400000005000006");
        bytes memory state = hex"00";
        bytes1[4] memory want = [bytes1(0x01), 0x00, 0x01, 0x00];
        for (uint256 beat = 0; beat < 4; beat++) {
            (state,) = _step(1, 1, state, hex"01");
            assertEq(state, abi.encodePacked(want[beat]));
        }
    }

    function test_latch_selfReference_holds() public {
        // LATCH d = its own signal: the bit never changes. One NAND so that there is an output.
        _store(bytes.concat(NetlistBuilder.latch(2), NetlistBuilder.nand(2, 2)));
        (bytes memory ns,) = _step(0, 1, hex"01", "");
        assertEq(ns, hex"01");
        (ns,) = _step(0, 1, hex"00", "");
        assertEq(ns, hex"00");
    }

    function test_latch_takesConstantOrInput() public {
        // three LATCH records: d = constant 1, d = constant 0, d = input 1; then a NAND for the output
        _store(
            bytes.concat(
                NetlistBuilder.latch(1), NetlistBuilder.latch(0), NetlistBuilder.latch(3), NetlistBuilder.nand(4, 5)
            )
        );
        (bytes memory ns,) = _step(2, 1, hex"02", hex"02");
        assertEq(ns, hex"05"); // bit 0 = 1, bit 1 = 0, bit 2 = input 1 = 1
    }

    function test_outputs_areTheLastSignals_andMayBeLatchOutputs() public {
        // records: NAND(in0, in0), LATCH(d = 0), LATCH(d = 1). Outputs = the two LATCH outputs.
        _store(bytes.concat(NetlistBuilder.nand(2, 2), NetlistBuilder.latch(0), NetlistBuilder.latch(1)));
        (bytes memory ns, bytes memory out) = _step(1, 2, hex"01", hex"00");
        assertEq(out, hex"01"); // stored bits: latch 0 = 1, latch 1 = 0
        assertEq(ns, hex"02"); // next: latch 0 = 0, latch 1 = 1
    }

    function test_interleavedLatches_ownStateBitsInRecordOrder() public {
        // LATCH A (bit 0), NAND, LATCH B (bit 1), NAND. Outputs: the two NAND gates, each NOT of a latch.
        _store(
            bytes.concat(
                NetlistBuilder.latch(0), // signal 2, state bit 0
                NetlistBuilder.nand(2, 2), // signal 3 = NOT A
                NetlistBuilder.latch(1), // signal 4, state bit 1
                NetlistBuilder.nand(4, 4) // signal 5 = NOT B
            )
        );
        // nOut = 2 takes signals 4 and 5: B and NOT B
        (bytes memory ns, bytes memory out) = _step(0, 2, hex"02", "");
        assertEq(out, hex"01"); // B = 1, NOT B = 0
        assertEq(ns, hex"02"); // A <- 0, B <- 1
    }

    // ------------------------------------------------------------------ packing and lenient reads

    function test_results_areExactlyCeilBytes_withZeroPadding() public {
        // nine LATCH records that all take constant 1, nine NAND gates that output 1
        bytes memory nl;
        for (uint256 i = 0; i < 9; i++) {
            nl = bytes.concat(nl, NetlistBuilder.latch(1));
        }
        for (uint256 i = 0; i < 9; i++) {
            nl = bytes.concat(nl, NetlistBuilder.nand(0, 0));
        }
        _store(nl);
        (bytes memory ns, bytes memory out) = _step(0, 9, "", "");
        assertEq(ns, hex"ff01");
        assertEq(out, hex"ff01");
    }

    function test_inputs_readLeniently() public {
        // output i = NOT input i, for 10 inputs
        bytes memory nl;
        for (uint256 i = 0; i < 10; i++) {
            nl = bytes.concat(nl, NetlistBuilder.nand(2 + i, 2 + i));
        }
        _store(nl);

        (, bytes memory out) = _step(10, 10, "", hex"ffff");
        assertEq(out, hex"0000", "padding bits of the last byte are ignored");
        (, out) = _step(10, 10, "", hex"ff");
        assertEq(out, hex"0003", "a missing byte reads as zero");
        (, out) = _step(10, 10, "", "");
        assertEq(out, hex"ff03", "an empty string reads as all zeros");
        (, out) = _step(10, 10, "", hex"00ffaabbccddeeff00112233445566778899aabbccddeeff0011223344556677889900");
        assertEq(out, hex"ff00", "bytes beyond the vector are ignored");
    }

    function test_state_readLeniently() public {
        // ten LATCH records holding their value; output i = latch i
        bytes memory nl;
        for (uint256 i = 0; i < 10; i++) {
            nl = bytes.concat(nl, NetlistBuilder.latch(2 + i));
        }
        _store(nl);

        (bytes memory ns, bytes memory out) = _step(0, 10, hex"ffff", "");
        assertEq(out, hex"ff03", "padding bits of the last state byte are ignored");
        assertEq(ns, hex"ff03");
        (ns, out) = _step(0, 10, hex"ff", "");
        assertEq(out, hex"ff00", "a missing state byte reads as zero");
        (ns, out) = _step(0, 10, "", "");
        assertEq(out, hex"0000");
        (ns, out) = _step(0, 10, abi.encodePacked(bytes32(hex"a501ff")), "");
        assertEq(out, hex"a501", "a 32-byte state word is read like the kernel passes it");
        assertEq(ns, hex"a501");
    }

    // ------------------------------------------------------------------ rejections

    function test_revert_badPins() public {
        _store(NetlistBuilder.nand(0, 0));
        vm.expectRevert(SealedVM.BadPins.selector);
        sealedVM.step(POINTER, 0, 0, "", "");
        vm.expectRevert(SealedVM.BadPins.selector);
        sealedVM.step(POINTER, 0, 65537, "", "");
        vm.expectRevert(SealedVM.BadPins.selector);
        sealedVM.step(POINTER, 65537, 1, "", "");
    }

    function test_maxPins_accepted() public {
        // 65,536 inputs: the single NAND reads the last one
        _store(NetlistBuilder.nand(2 + 65535, 1));
        bytes memory inputs = new bytes(8192);
        (, bytes memory out) = sealedVM.step(POINTER, 65536, 1, "", inputs);
        assertEq(out, hex"01");
        inputs[8191] = 0x80;
        (, out) = sealedVM.step(POINTER, 65536, 1, "", inputs);
        assertEq(out, hex"00");
        _agree(NetlistBuilder.nand(2 + 65535, 1), 65536, 1, "", inputs);
    }

    function test_revert_badSnapshot() public {
        vm.expectRevert(SealedVM.BadSnapshot.selector);
        sealedVM.step(address(0xdead), 1, 1, "", ""); // no code

        vm.etch(POINTER, bytes.concat(hex"01", NetlistBuilder.nand(0, 0))); // code does not start with STOP
        vm.expectRevert(SealedVM.BadSnapshot.selector);
        sealedVM.step(POINTER, 1, 1, "", "");

        vm.expectRevert(SealedVM.BadSnapshot.selector);
        sealedVM.step(address(sealedVM), 1, 1, "", ""); // a real contract is not a pointer
    }

    function test_revert_emptyNetlist() public {
        _store("");
        vm.expectRevert(abi.encodeWithSelector(TooFewSignals.selector, 0));
        sealedVM.step(POINTER, 4, 1, "", hex"0f");
    }

    function test_revert_tooFewSignals() public {
        _store(bytes.concat(NetlistBuilder.nand(2, 3), NetlistBuilder.latch(0)));
        vm.expectRevert(abi.encodeWithSelector(TooFewSignals.selector, 2));
        sealedVM.step(POINTER, 2, 3, "", ""); // two records cannot give three outputs
        sealedVM.step(POINTER, 2, 2, "", ""); // two can
    }

    function test_revert_badOpcode() public {
        // a REF record (opcode 0x02) after one NAND
        bytes memory ref = abi.encodePacked(uint8(0x02), address(0xaa), uint64(1), uint8(1), uint8(1), uint24(2));
        _store(bytes.concat(NetlistBuilder.nand(2, 2), ref));
        vm.expectRevert(abi.encodeWithSelector(BadOpcode.selector, 7, 2));
        sealedVM.step(POINTER, 1, 1, "", "");

        _store(hex"03000002000003");
        vm.expectRevert(abi.encodeWithSelector(BadOpcode.selector, 0, 3));
        sealedVM.step(POINTER, 2, 1, "", "");

        // 0xff is also the byte SealedVM writes after the netlist; inside the netlist it is a bad opcode
        _store(bytes.concat(NetlistBuilder.nand(2, 2), hex"ff", NetlistBuilder.nand(2, 2)));
        vm.expectRevert(abi.encodeWithSelector(BadOpcode.selector, 7, 255));
        sealedVM.step(POINTER, 1, 1, "", "");

        _store(bytes.concat(NetlistBuilder.nand(2, 2), hex"ff"));
        vm.expectRevert(abi.encodeWithSelector(BadOpcode.selector, 7, 255));
        sealedVM.step(POINTER, 1, 1, "", "");
    }

    function test_revert_futureSignal() public {
        // one input: the first gate produces signal 3. Reading signal 3 (itself) or later is rejected.
        _store(NetlistBuilder.nand(3, 2));
        vm.expectRevert(abi.encodeWithSelector(FutureSignal.selector, 0));
        sealedVM.step(POINTER, 1, 1, "", "");

        _store(NetlistBuilder.nand(2, 3));
        vm.expectRevert(abi.encodeWithSelector(FutureSignal.selector, 0));
        sealedVM.step(POINTER, 1, 1, "", "");

        _store(bytes.concat(NetlistBuilder.nand(2, 2), NetlistBuilder.nand(3, 5)));
        vm.expectRevert(abi.encodeWithSelector(FutureSignal.selector, 7));
        sealedVM.step(POINTER, 1, 1, "", "");

        _store(NetlistBuilder.nand(2, 0xffffff));
        vm.expectRevert(abi.encodeWithSelector(FutureSignal.selector, 0));
        sealedVM.step(POINTER, 1, 1, "", "");

        // the largest legal index is the signal just before the gate
        _store(bytes.concat(NetlistBuilder.nand(2, 2), NetlistBuilder.nand(3, 3)));
        sealedVM.step(POINTER, 1, 1, "", "");
    }

    function test_revert_latchOutOfRange() public {
        // signals: 0, 1, in0, latch(3), nand(4): five signals. d = 5 does not exist; d = 4 does.
        _store(bytes.concat(NetlistBuilder.latch(5), NetlistBuilder.nand(2, 3)));
        vm.expectRevert(abi.encodeWithSelector(LatchOutOfRange.selector, 5, 5));
        sealedVM.step(POINTER, 1, 1, "", "");

        _store(bytes.concat(NetlistBuilder.latch(4), NetlistBuilder.nand(2, 3)));
        sealedVM.step(POINTER, 1, 1, "", "");

        // the second LATCH is the bad one
        _store(bytes.concat(NetlistBuilder.latch(4), NetlistBuilder.nand(2, 3), NetlistBuilder.latch(0xffffff)));
        vm.expectRevert(abi.encodeWithSelector(LatchOutOfRange.selector, 0xffffff, 6));
        sealedVM.step(POINTER, 1, 1, "", "");
    }

    function test_revert_truncatedRecord_everyCut() public {
        // A valid netlist cut 1 to 6 bytes short of a NAND, and 1 to 3 bytes short of a LATCH.
        bytes memory good = bytes.concat(NetlistBuilder.nand(2, 2), NetlistBuilder.nand(0, 0));
        for (uint256 cut = 1; cut <= 6; cut++) {
            _store(NetlistBuilder.head(good, good.length - cut));
            vm.expectRevert(TruncatedRecord.selector);
            sealedVM.step(POINTER, 1, 1, "", "");
        }
        good = bytes.concat(NetlistBuilder.nand(2, 2), NetlistBuilder.latch(0));
        for (uint256 cut = 1; cut <= 3; cut++) {
            _store(NetlistBuilder.head(good, good.length - cut));
            vm.expectRevert(TruncatedRecord.selector);
            sealedVM.step(POINTER, 1, 1, "", "");
        }
        // TAP-20's own example
        _store(hex"0000000200");
        vm.expectRevert(TruncatedRecord.selector);
        sealedVM.step(POINTER, 2, 1, "", "");
    }

    /// @notice The random damage used by the differential suite reaches every rejection, and leaves
    ///         enough netlists valid.
    /// @dev Guards that suite against being vacuous: counts SealedVM's answers over 4,000 of its netlists.
    function test_census_ofDamagedNetlists() public {
        uint256 accepted;
        uint256[5] memory rejected; // BadOpcode, TruncatedRecord, FutureSignal, LatchOutOfRange, TooFewSignals
        for (uint256 seed = 0; seed < 4000; seed++) {
            Mutant memory m = _mutant(seed);
            _store(m.nl);
            (bool wellFormed,) =
                address(oracle).staticcall(abi.encodeCall(INetlistVMHarness.analyze, (m.nl, m.nIn, m.nOut)));
            (bool ok, bytes memory ret) = address(sealedVM)
                .staticcall(abi.encodeCall(ISealedVM.step, (POINTER, m.nIn, m.nOut, m.state, m.inputs)));
            assertEq(ok, wellFormed);
            if (ok) {
                accepted++;
                continue;
            }
            bytes4 sel = bytes4(ret);
            if (sel == BadOpcode.selector) rejected[0]++;
            else if (sel == TruncatedRecord.selector) rejected[1]++;
            else if (sel == FutureSignal.selector) rejected[2]++;
            else if (sel == LatchOutOfRange.selector) rejected[3]++;
            else if (sel == TooFewSignals.selector) rejected[4]++;
            else fail("unexpected revert");
        }
        console2.log("damaged netlists accepted by both:", accepted);
        console2.log("rejected BadOpcode:", rejected[0]);
        console2.log("rejected TruncatedRecord:", rejected[1]);
        console2.log("rejected FutureSignal:", rejected[2]);
        console2.log("rejected LatchOutOfRange:", rejected[3]);
        console2.log("rejected TooFewSignals:", rejected[4]);
        assertGt(accepted, 1000);
        for (uint256 i = 0; i < 5; i++) {
            assertGt(rejected[i], 20);
        }
    }

    // ------------------------------------------------------------------ sizes

    function test_largestV1Chip_matchesTapeOut() public {
        bytes memory nl = NetlistBuilder.randomV1(0xC0FFEE, 256, 3144); // 3,400 gates, 23,032 bytes
        _store(nl);
        bytes32 word;
        for (uint256 beat = 0; beat < 4; beat++) {
            (bytes memory ns,) = _agree(nl, 96, 112, abi.encodePacked(word), NetlistBuilder.randomBytes(beat, 12));
            word = bytes32(ns);
        }
    }

    function test_netlistOfLatchesOnly_matchesTapeOut() public {
        // 6,000 LATCH records: 24,000 bytes, the densest a single pointer can hold. 750 state bytes.
        bytes memory nl = NetlistBuilder.random(7, 16, 6000, 0, true);
        _store(nl);
        (bytes memory ns, bytes memory out) =
            _agree(nl, 16, 6000, NetlistBuilder.randomBytes(1, 750), NetlistBuilder.randomBytes(2, 2));
        assertEq(ns.length, 750);
        assertEq(out.length, 750);
        _agree(nl, 16, 1, ns, hex"ffff");
    }

    function test_netlistLargerThanOnePointer_matchesTapeOut() public {
        // 9,000 gates, 61 KB: more than a deployed pointer can hold, but vm.etch can. The VM has no size limit
        // of its own below 2^24 signals.
        bytes memory nl = NetlistBuilder.random(11, 133, 300, 8700, false);
        _store(nl);
        _agree(nl, 133, 199, NetlistBuilder.randomBytes(3, 38), NetlistBuilder.randomBytes(4, 17));
    }

    // ------------------------------------------------------------------ TAP-20 vectors

    function _fixture() internal view returns (string memory) {
        return vm.readFile("test/fixtures/tap20-vectors.json");
    }

    function test_tap20_validVectors() public {
        string memory json = _fixture();
        string[] memory names = abi.decode(vm.parseJson(json, ".valid[*].name"), (string[]));
        uint256 flat;
        uint256 checks;
        for (uint256 i = 0; i < names.length; i++) {
            string memory at = string.concat(".valid[", vm.toString(i), "]");
            uint32 nIn = uint32(vm.parseJsonUint(json, string.concat(at, ".nIn")));
            uint32 nOut = uint32(vm.parseJsonUint(json, string.concat(at, ".nOut")));
            _store(vm.parseJsonBytes(json, string.concat(at, ".netlist")));

            if (keccak256(bytes(names[i])) == keccak256("ref_with_state")) {
                // the one vector with a REF record: SealedVM is flat-only and must refuse it
                vm.expectRevert(abi.encodeWithSelector(BadOpcode.selector, 4, 2));
                sealedVM.step(POINTER, nIn, nOut, hex"00", hex"01");
                continue;
            }
            flat++;
            if (vm.keyExistsJson(json, string.concat(at, ".truthTable"))) {
                checks += _checkTruthTable(json, at, nIn, nOut);
            } else {
                checks += _checkBeats(json, at, nIn, nOut);
            }
        }
        assertEq(flat, 4, "nand, constants, popcount8_3151, toggle");
        assertEq(checks, 4 + 2 + 256 + 8);
    }

    function _column(string memory json, string memory at, string memory field)
        internal
        pure
        returns (string[] memory)
    {
        return abi.decode(vm.parseJson(json, string.concat(at, field)), (string[]));
    }

    function _checkTruthTable(string memory json, string memory at, uint32 nIn, uint32 nOut)
        internal
        view
        returns (uint256 rows)
    {
        string[] memory ins = _column(json, at, ".truthTable[*].inputs");
        string[] memory outs = _column(json, at, ".truthTable[*].outputs");
        rows = ins.length;
        for (uint256 k = 0; k < rows; k++) {
            (bytes memory ns, bytes memory out) = _step(nIn, nOut, "", _hex(ins[k]));
            assertEq(out, _hex(outs[k]), at);
            assertEq(ns.length, 0, at);
        }
    }

    function _checkBeats(string memory json, string memory at, uint32 nIn, uint32 nOut)
        internal
        view
        returns (uint256 rows)
    {
        string[] memory st = _column(json, at, ".beats[*].state");
        string[] memory ins = _column(json, at, ".beats[*].inputs");
        string[] memory nst = _column(json, at, ".beats[*].newState");
        string[] memory outs = _column(json, at, ".beats[*].outputs");
        rows = st.length;
        for (uint256 k = 0; k < rows; k++) {
            (bytes memory ns, bytes memory out) = _step(nIn, nOut, _hex(st[k]), _hex(ins[k]));
            assertEq(out, _hex(outs[k]), at);
            assertEq(ns, _hex(nst[k]), at);
        }
    }

    function test_tap20_illFormedVectors_allRevert() public {
        string memory json = _fixture();
        string[] memory names = abi.decode(vm.parseJson(json, ".illFormed[*].name"), (string[]));
        assertEq(names.length, 8);
        for (uint256 i = 0; i < names.length; i++) {
            string memory at = string.concat(".illFormed[", vm.toString(i), "]");
            _store(vm.parseJsonBytes(json, string.concat(at, ".netlist")));
            uint32 nIn = uint32(vm.parseJsonUint(json, string.concat(at, ".nIn")));
            uint32 nOut = uint32(vm.parseJsonUint(json, string.concat(at, ".nOut")));
            (bool ok,) = address(sealedVM).staticcall(abi.encodeCall(ISealedVM.step, (POINTER, nIn, nOut, "", "")));
            assertFalse(ok, names[i]);
        }
    }

    function test_tap20_packingEdgeCases() public {
        string memory json = _fixture();
        assertEq(vm.parseJsonString(json, ".packingEdgeCases.circuit"), "nand");
        _store(vm.parseJsonBytes(json, ".valid[0].netlist"));
        string[] memory ins = abi.decode(vm.parseJson(json, ".packingEdgeCases.cases[*].inputs"), (string[]));
        string[] memory outs = abi.decode(vm.parseJson(json, ".packingEdgeCases.cases[*].outputs"), (string[]));
        assertEq(ins.length, 5);
        for (uint256 k = 0; k < ins.length; k++) {
            (, bytes memory out) = _step(2, 1, "", _hex(ins[k]));
            assertEq(out, _hex(outs[k]));
        }
    }

    // ------------------------------------------------------------------ gas

    /// @notice A budget a caller can rely on: one beat of a v1 chip, started cold, costs at most
    ///         20,000 gas plus 160 per NAND plus 280 per LATCH (the kernel's 32-byte state, 12-byte inputs).
    /// @dev The cost depends on the data in one place only: a LATCH whose next bit is 1 costs more than one
    ///      whose next bit is 0. So every LATCH here takes constant 1, and state and inputs are full length.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_gasBudget_onV1Chips(uint256 seed, uint16 latchSeed, uint16 nandSeed) public {
        uint256 k = 1 + (uint256(latchSeed) % 256);
        uint256 lo = k >= 112 ? 0 : 112 - k;
        uint256 n = lo + (uint256(nandSeed) % (3400 - k - lo + 1));
        bytes memory nl = NetlistBuilder.randomV1(seed, k, n);
        for (uint256 i = 0; i < k; i++) {
            nl[4 * i + 1] = 0;
            nl[4 * i + 2] = 0;
            nl[4 * i + 3] = 0x01;
        }
        _store(nl);
        bytes memory state = abi.encodePacked(bytes32(type(uint256).max));
        bytes memory inputs = hex"ffffffffffffffffffffffff";

        vm.cool(address(sealedVM));
        vm.cool(POINTER);
        uint256 g = gasleft();
        (bytes memory ns,) = sealedVM.step(POINTER, 96, 112, state, inputs);
        uint256 used = g - gasleft();

        assertLe(used, 20_000 + 160 * n + 280 * k, "over budget");
        for (uint256 i = 0; i < k; i++) {
            assertEq(uint8(ns[i / 8]) >> (i % 8) & 1, 1, "every LATCH took constant 1");
        }
        _agree(nl, 96, 112, state, inputs);
    }

    /// @notice Gas of one beat on SealedVM and on TapeOut's evaluator (the vendored library, compiled
    ///         locally) for v1 chips of 500, 2,000 and 3,400 gates. The fork suite repeats this against
    ///         the deployed `Circuits.step`.
    function test_gasReport_hermetic() public {
        uint256[3] memory sizes = [uint256(500), 2000, 3400];
        console2.log("gates | SealedVM.step gas | NetlistVM.run gas (local build) | ratio");
        for (uint256 i = 0; i < 3; i++) {
            bytes memory nl = NetlistBuilder.randomV1(i, 64, sizes[i] - 64);
            _store(nl);
            bytes memory state = NetlistBuilder.randomBytes(i, 32);
            bytes memory inputs = NetlistBuilder.randomBytes(i + 99, 12);

            uint256 g = gasleft();
            sealedVM.step(POINTER, 96, 112, state, inputs);
            uint256 gasSealed = g - gasleft();

            g = gasleft();
            oracle.run(nl, 96, 112, state, inputs);
            uint256 gasOracle = g - gasleft();

            console2.log(sizes[i], gasSealed, gasOracle, gasOracle / gasSealed);
            assertLt(gasSealed * 5, gasOracle, "SealedVM should be at least five times cheaper");
            assertLt(gasSealed, 300 * sizes[i], "SealedVM should cost under 300 gas per gate, overhead included");
        }
    }
}
