// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title NetlistScan - how many transistors a TapeOut netlist burns when it is taped out.
///
/// @notice A netlist is a flat sequence of big-endian records:
///
///           NAND   0x00 a(u24) b(u24)                                          7 bytes   burns 1 NAND
///           LATCH  0x01 d(u24)                                                 4 bytes   burns 1 LATCH
///           REF    0x02 cpu(20 bytes) id(u64) nIns(u8) nOuts(u8) ins(u24)*nIns  31 + 3*nIns bytes, burns nothing
///
///         Only TOP-LEVEL NAND and LATCH records burn transistors. A REF points at a circuit that was
///         taped out (and paid for) earlier, so it is skipped and counts zero. This is deliberately not
///         TapeOut's `circuitInfo().gateCount`, which recurses through REF records.
///
/// @dev    Same record walk as TapeOut's verified `NetlistVM.burnOf` (the fuzz suite checks the two against
///         each other on well-formed netlists), but strict: an unknown opcode or a record that runs past the
///         end of the buffer reverts instead of being counted.
library NetlistScan {
    /// @notice The byte at `offset` is not a NAND, LATCH or REF opcode.
    error BadOpcode(uint256 offset, uint8 opcode);
    /// @notice The record starting at `offset` runs past the end of the netlist.
    error TruncatedRecord(uint256 offset);

    uint256 internal constant OP_NAND = 0x00;
    uint256 internal constant OP_LATCH = 0x01;
    uint256 internal constant OP_REF = 0x02;

    uint256 internal constant NAND_SIZE = 7;
    uint256 internal constant LATCH_SIZE = 4;
    /// @dev opcode(1) + cpu(20) + id(8) + nIns(1) + nOuts(1)
    uint256 internal constant REF_HEADER_SIZE = 31;
    /// @dev offset of the nIns byte from the start of a REF record
    uint256 internal constant REF_NINS_OFFSET = 29;

    /// @notice Counts the top-level NAND and LATCH records of `nl`.
    /// @return nNand  NAND transistors burned by a tape-out of `nl`
    /// @return nLatch LATCH transistors burned by a tape-out of `nl`
    function burnOf(bytes memory nl) internal pure returns (uint256 nNand, uint256 nLatch) {
        uint256 len = nl.length;
        uint256 p = 0;
        // Arithmetic cannot overflow: `p < len`, `len` is a memory length and every size is at most 796.
        // Reverting inside the loop is the point of a strict parser: one bad record rejects the whole netlist.
        // forge-lint: disable-start(require-revert-in-loop)
        unchecked {
            while (p < len) {
                uint256 op = uint8(nl[p]);
                uint256 size;
                if (op == OP_NAND) {
                    size = NAND_SIZE;
                    ++nNand;
                } else if (op == OP_LATCH) {
                    size = LATCH_SIZE;
                    ++nLatch;
                } else if (op == OP_REF) {
                    if (len - p < REF_HEADER_SIZE) revert TruncatedRecord(p);
                    size = REF_HEADER_SIZE + 3 * uint256(uint8(nl[p + REF_NINS_OFFSET]));
                } else {
                    // `op` was read from a single byte.
                    // forge-lint: disable-next-line(unsafe-typecast)
                    revert BadOpcode(p, uint8(op));
                }
                if (len - p < size) revert TruncatedRecord(p);
                p += size;
            }
        }
        // forge-lint: disable-end(require-revert-in-loop)
    }
}
