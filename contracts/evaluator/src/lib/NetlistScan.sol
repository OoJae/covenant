// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BadOpcode, FutureSignal, LatchOutOfRange, TooFewSignals, TruncatedRecord} from "./NetlistErrors.sol";

/// @title NetlistScan: the chip shape of Covenant interface v1 (chips/INTERFACE.md, section 2)
/// @notice Checks that a TAP-20 netlist is a v1 chip and counts its transistors. Pure: it reads
///         only the bytes it is given.
///
///         A v1 chip has 96 inputs and 112 outputs and satisfies all of the following.
///
///         1. The netlist is at most 24,000 bytes (one SSTORE2 chunk).
///         2. Every record is complete and is a NAND (0x00 a:u24 b:u24) or a LATCH (0x01 d:u24).
///            A REF (0x02) is rejected.
///         3. The first nState records are LATCH records and no LATCH follows a NAND, with
///            1 <= nState <= 256. State bit i is LATCH record i.
///         4. nNand + nLatch <= 3,400.
///         5. The records produce at least 112 signals, so every output is produced by a record
///            (TAP-20 section 3, condition 3).
///         6. Each NAND input is a signal earlier than the one the NAND produces (condition 4).
///         7. Each LATCH d is a signal of the circuit: d < 2 + 96 + nNand + nLatch (condition 5).
///
///         Conditions 2, 5, 6 and 7 are what TapeOut's own `tapeout` enforces for a flat netlist;
///         the others are the v1 restrictions.
library NetlistScan {
    // Also reverts with the errors of NetlistErrors.sol: TruncatedRecord, BadOpcode (an opcode TAP-20
    // does not define), FutureSignal, LatchOutOfRange (the largest d of any LATCH) and TooFewSignals.

    uint256 internal constant N_IN = 96;
    uint256 internal constant N_OUT = 112;
    uint256 internal constant MAX_STATE = 256;
    uint256 internal constant MAX_GATES = 3400;
    uint256 internal constant MAX_BYTES = 24000;

    /// @dev Index of the signal the first record produces: two constants, then the inputs.
    uint256 private constant FIRST_SIGNAL = 2 + N_IN;

    /// @notice The netlist is longer than 24,000 bytes.
    error NetlistTooLong(uint256 length);
    /// @notice The record at byte `offset` is a REF. v1 chips are flat.
    error RefNotAllowed(uint256 offset);
    /// @notice The record at byte `offset` is a LATCH that comes after a NAND.
    error LatchAfterNand(uint256 offset);
    /// @notice The netlist has `nLatch` LATCH records; a v1 chip has 1 to 256.
    error StateCountOutOfRange(uint256 nLatch);
    /// @notice The netlist has `gates` records; a v1 chip has at most 3,400.
    error TooManyGates(uint256 gates);

    /// @notice Reverts unless `nl` is a v1 chip, and returns its transistor counts.
    /// @return nNand  number of NAND records
    /// @return nLatch number of LATCH records, which is nState
    function scan(bytes calldata nl) internal pure returns (uint256 nNand, uint256 nLatch) {
        uint256 len = nl.length;
        if (len > MAX_BYTES) revert NetlistTooLong(len);

        uint256 p = 0; // byte offset of the record being read
        uint256 maxD = 0; // largest d of any LATCH
        uint256 firstSignal = FIRST_SIGNAL;
        assembly ("memory-safe") {
            let at := nl.offset

            // The leading LATCH records.
            for {} lt(p, len) {} {
                let w := calldataload(add(at, p))
                if iszero(eq(shr(248, w), 1)) { break }
                let d := and(shr(224, w), 0xffffff)
                if gt(d, maxD) { maxD := d }
                nLatch := add(nLatch, 1)
                p := add(p, 4)
            }

            // Every later record must be a NAND whose inputs are earlier signals. The top four bytes
            // of w are the opcode and a; read as one number they are below `o` (never above 2^24)
            // only when the opcode is 0x00 and a is an earlier signal.
            let o := add(firstSignal, nLatch) // index of the signal the next record produces
            for {} lt(p, len) {} {
                let w := calldataload(add(at, p))
                if iszero(and(lt(shr(224, w), o), lt(and(shr(200, w), 0xffffff), o))) { break }
                o := add(o, 1)
                p := add(p, 7)
            }
            nNand := sub(sub(o, firstSignal), nLatch)
        }

        // A record that runs past the end was decoded with bytes that are not part of the netlist.
        // Whether it then passed or failed the checks above, the scan cannot stop exactly at `len`.
        if (p > len) revert TruncatedRecord();
        if (p < len) {
            uint8 opcode = uint8(nl[p]);
            if (opcode == 0x01) revert LatchAfterNand(p);
            if (opcode == 0x02) revert RefNotAllowed(p);
            if (opcode != 0x00) revert BadOpcode(p, opcode);
            if (p + 7 > len) revert TruncatedRecord();
            revert FutureSignal(p);
        }

        uint256 gates = nNand + nLatch;
        if (nLatch == 0 || nLatch > MAX_STATE) revert StateCountOutOfRange(nLatch);
        if (gates > MAX_GATES) revert TooManyGates(gates);
        if (gates < N_OUT) revert TooFewSignals(gates);
        if (maxD >= FIRST_SIGNAL + gates) revert LatchOutOfRange(maxD, FIRST_SIGNAL + gates);
    }
}
