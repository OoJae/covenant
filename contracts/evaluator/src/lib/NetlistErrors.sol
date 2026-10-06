// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// The reasons a flat TAP-20 netlist is ill-formed (TAP-20 section 3). SealedVM and NetlistScan revert
// with the same errors, so one ABI entry decodes a rejection from either.

/// @notice The last record is cut short.
error TruncatedRecord();

/// @notice The record at byte `offset` of the netlist has an opcode that is not allowed there.
error BadOpcode(uint256 offset, uint8 opcode);

/// @notice The NAND at byte `offset` reads a signal that is not earlier than the one it produces.
error FutureSignal(uint256 offset);

/// @notice A LATCH takes its next value from signal `d`, but the circuit has only `nSignals` signals.
error LatchOutOfRange(uint256 d, uint256 nSignals);

/// @notice The netlist has `records` records, fewer than the number of outputs, so an output would be an
///         input or a constant.
error TooFewSignals(uint256 records);
