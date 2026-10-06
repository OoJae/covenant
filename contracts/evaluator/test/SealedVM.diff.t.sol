// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISealedVM} from "../src/interfaces/ISealedVM.sol";
import {NetlistBuilder} from "./utils/NetlistBuilder.sol";
import {INetlistVMHarness} from "./utils/Oracles.sol";
import {SealedVMBase} from "./utils/SealedVMBase.sol";

/// @notice Differential tests: SealedVM against TapeOut's own NetlistVM (vendored, unmodified).
contract SealedVMDiffTest is SealedVMBase {
    struct Shape {
        uint32 nIn;
        uint32 nOut;
        uint256 nLatch;
        uint256 nNand;
        bool latchesFirst;
    }

    /// @dev Mixed sizes: half the netlists have 1 to 64 records, one in twenty has 2,001 to 3,400.
    ///      0 to 300 LATCH records, 0 to 309 inputs, 1 output up to every record being an output.
    function _shape(uint256 seed) internal pure returns (Shape memory sh) {
        uint256 r = uint256(keccak256(abi.encode(seed, "shape")));

        uint256 c = r % 100;
        r >>= 8;
        uint256 gates;
        if (c < 50) gates = 1 + (r % 64);
        else if (c < 80) gates = 65 + (r % 536);
        else if (c < 95) gates = 601 + (r % 1400);
        else gates = 2001 + (r % 1400);
        r >>= 16;

        c = r % 100;
        r >>= 8;
        if (c < 15) sh.nLatch = 0;
        else if (c < 40) sh.nLatch = 1 + (r % 8);
        else if (c < 65) sh.nLatch = 9 + (r % 56);
        else if (c < 95) sh.nLatch = 65 + (r % 192);
        else sh.nLatch = 257 + (r % 44);
        if (sh.nLatch > gates) sh.nLatch = gates;
        sh.nNand = gates - sh.nLatch;
        r >>= 16;

        c = r % 100;
        r >>= 8;
        if (c < 12) sh.nIn = 0;
        else if (c < 24) sh.nIn = uint32([uint256(1), 7, 8, 9][r % 4]);
        else if (c < 60) sh.nIn = 96;
        else if (c < 95) sh.nIn = uint32(1 + (r % 200));
        else sh.nIn = uint32(250 + (r % 60));
        r >>= 16;

        c = r % 100;
        r >>= 8;
        if (c < 30) sh.nOut = uint32(gates < 112 ? gates : 112);
        else if (c < 40) sh.nOut = 1;
        else if (c < 50) sh.nOut = uint32(gates);
        else sh.nOut = uint32(1 + (r % (gates < 260 ? gates : 260)));
        r >>= 16;

        sh.latchesFirst = (r & 1) == 0;
    }

    /// @notice Thousands of random well-formed flat netlists, each run on both evaluators with four
    ///         (state, inputs) pairs of every length class and then a second beat from the state the
    ///         first beat produced. The raw return data must be identical every time.
    /// forge-config: default.fuzz.runs = 4096
    /// forge-config: deep.fuzz.runs = 20000
    function testFuzz_matchesTapeOut_onRandomFlatNetlists(uint256 seed) public {
        Shape memory sh = _shape(seed);
        bytes memory nl = NetlistBuilder.random(seed, sh.nIn, sh.nLatch, sh.nNand, sh.latchesFirst);
        _store(nl);

        bytes memory carried;
        for (uint256 v = 0; v < 4; v++) {
            uint256 vs = uint256(keccak256(abi.encode(seed, v)));
            bytes memory state = _vector(vs, sh.nLatch);
            bytes memory inputs = _vector(vs >> 16, sh.nIn);

            (bytes memory newState, bytes memory outputs) = _agree(nl, sh.nIn, sh.nOut, state, inputs);
            assertEq(newState.length, NetlistBuilder.bytesFor(sh.nLatch), "newState is not ceil(nState / 8) bytes");
            assertEq(outputs.length, NetlistBuilder.bytesFor(sh.nOut), "outputs are not ceil(nOut / 8) bytes");
            carried = newState;
        }

        // the next beat, from a state the circuit itself produced
        _agree(nl, sh.nIn, sh.nOut, carried, _vector(seed >> 24, sh.nIn));
    }

    /// @notice The chip shape the kernel uses: 96 inputs, 112 outputs, 1 to 256 leading LATCH records.
    ///         Eight beats in a row, the state carried as a 32-byte word the way the kernel stores it.
    /// forge-config: default.fuzz.runs = 512
    /// forge-config: deep.fuzz.runs = 2000
    function testFuzz_matchesTapeOut_onV1Chips(uint256 seed, uint16 latchSeed, uint16 nandSeed) public {
        uint256 nLatch = 1 + (uint256(latchSeed) % 256);
        uint256 nNand = 112 + (uint256(nandSeed) % (3400 - nLatch - 112 + 1));
        bytes memory nl = NetlistBuilder.randomV1(seed, nLatch, nNand);
        _store(nl);

        bytes32 word; // the kernel's stored state: the TAP-20 bytes right-padded with zeros
        for (uint256 beat = 0; beat < 8; beat++) {
            bytes memory inputs = NetlistBuilder.randomBytes(uint256(keccak256(abi.encode(seed, beat))), 12);
            (bytes memory newState, bytes memory outputs) = _agree(nl, 96, 112, abi.encodePacked(word), inputs);
            assertEq(outputs.length, 14);
            assertEq(newState.length, NetlistBuilder.bytesFor(nLatch));
            word = bytes32(newState);
        }
    }

    /// @notice SealedVM accepts exactly the flat netlists TapeOut's tape-out check accepts.
    /// @dev A well-formed netlist is damaged at random (a byte overwritten, bytes cut off the end, bytes
    ///      appended). `analyze` is the check `Circuits.tapeout` runs: if it passes, both evaluators must
    ///      return the same data; if it fails, SealedVM must revert.
    /// forge-config: default.fuzz.runs = 4096
    /// forge-config: deep.fuzz.runs = 50000
    function testFuzz_acceptsExactlyWhatTapeOutAccepts(uint256 seed) public {
        Mutant memory m = _mutant(seed);
        _store(m.nl);

        (bool wellFormed,) =
            address(oracle).staticcall(abi.encodeCall(INetlistVMHarness.analyze, (m.nl, m.nIn, m.nOut)));
        (bool okS, bytes memory retS) =
            address(sealedVM).staticcall(abi.encodeCall(ISealedVM.step, (POINTER, m.nIn, m.nOut, m.state, m.inputs)));
        assertEq(okS, wellFormed, "SealedVM and TapeOut's tape-out check disagree on whether the netlist is valid");

        if (wellFormed) {
            (bool okO, bytes memory retO) = address(oracle)
                .staticcall(abi.encodeCall(INetlistVMHarness.run, (m.nl, m.nIn, m.nOut, m.state, m.inputs)));
            assertTrue(okO, "TapeOut's evaluator reverted on a netlist its tape-out check accepts");
            assertEq(retS, retO, "SealedVM and TapeOut return different data");
        }
    }
}
