// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {SealedVM} from "../../src/SealedVM.sol";
import {ISealedVM} from "../../src/interfaces/ISealedVM.sol";
import {NetlistBuilder} from "./NetlistBuilder.sol";
import {INetlistVMHarness} from "./Oracles.sol";

/// @notice Shared set-up for the SealedVM suites: the VM under test (production build), TapeOut's own
///         evaluator as the oracle, and one SSTORE2-style pointer whose code the tests replace.
abstract contract SealedVMBase is Test {
    SealedVM internal sealedVM;
    INetlistVMHarness internal oracle;

    /// @dev The snapshot pointer used by the hermetic suites. Its code is set with `vm.etch`.
    address internal constant POINTER = address(uint160(0x5ea1edc0de01));

    function setUp() public virtual {
        sealedVM = new SealedVM();
        oracle = INetlistVMHarness(deployCode("NetlistVMHarness.sol:NetlistVMHarness"));
    }

    /// @dev Makes POINTER an SSTORE2 pointer to `nl`: runtime code 0x00, then the netlist.
    function _store(bytes memory nl) internal {
        vm.etch(POINTER, abi.encodePacked(hex"00", nl));
    }

    /// @dev Runs one beat on both evaluators and requires the raw return data to be identical.
    function _agree(bytes memory nl, uint32 nIn, uint32 nOut, bytes memory state, bytes memory inputs)
        internal
        view
        returns (bytes memory newState, bytes memory outputs)
    {
        (bool okO, bytes memory retO) =
            address(oracle).staticcall(abi.encodeCall(INetlistVMHarness.run, (nl, nIn, nOut, state, inputs)));
        (bool okS, bytes memory retS) =
            address(sealedVM).staticcall(abi.encodeCall(ISealedVM.step, (POINTER, nIn, nOut, state, inputs)));
        assertTrue(okO, "TapeOut's evaluator reverted on a well-formed netlist");
        assertTrue(okS, "SealedVM reverted on a well-formed netlist");
        assertEq(retS, retO, "SealedVM and TapeOut return different data");
        (newState, outputs) = abi.decode(retS, (bytes, bytes));
    }

    /// @dev A byte string for an `n`-bit vector, in one of six forms chosen by the seed: exact length
    ///      with random padding bits, too short, too long, empty, all ones, all zeros.
    function _vector(uint256 seed, uint256 n) internal pure returns (bytes memory out) {
        uint256 exact = NetlistBuilder.bytesFor(n);
        uint256 mode = seed % 6;
        uint256 r = uint256(keccak256(abi.encode(seed, "vector")));
        if (mode == 0) return NetlistBuilder.randomBytes(r, exact);
        if (mode == 1) return NetlistBuilder.randomBytes(r, exact == 0 ? 0 : r % exact);
        if (mode == 2) return NetlistBuilder.randomBytes(r, exact + 1 + (r % 40));
        if (mode == 3) return "";
        out = new bytes(exact);
        if (mode == 4) {
            for (uint256 i = 0; i < exact; i++) {
                out[i] = 0xff;
            }
        }
    }

    /// @dev A small well-formed flat netlist that has then been edited 0 to 3 times.
    struct Mutant {
        bytes nl;
        uint32 nIn;
        uint32 nOut;
        bytes state;
        bytes inputs;
    }

    function _mutant(uint256 seed) internal pure returns (Mutant memory m) {
        uint256 r = uint256(keccak256(abi.encode(seed, "mutant")));
        m.nIn = uint32(r % 12);
        uint256 nLatch = (r >> 8) % 6;
        uint256 nNand = 1 + ((r >> 16) % 24);
        // one time in four every record is an output, so that losing a record leaves too few signals
        m.nOut = (r >> 24) % 4 == 0 ? uint32(nLatch + nNand) : uint32(1 + ((r >> 32) % (nLatch + nNand)));
        m.nl = NetlistBuilder.random(seed, m.nIn, nLatch, nNand, (r >> 64) & 1 == 0);

        // Zero edits is the control. Aimed edits come first: they need a netlist that still parses.
        uint256 edits = (r >> 72) % 4;
        for (uint256 e = 0; e < edits; e++) {
            uint256 x = uint256(keccak256(abi.encode(seed, e)));
            m.nl =
                (e == 0 && x & 1 == 0) ? NetlistBuilder.aim(m.nl, m.nIn, x >> 8) : NetlistBuilder.damage(m.nl, x >> 8);
        }
        m.state = _vector(r >> 96, nLatch);
        m.inputs = _vector(r >> 128, m.nIn);
    }
}
