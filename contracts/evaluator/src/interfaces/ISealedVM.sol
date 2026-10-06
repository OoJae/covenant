// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ISealedVM
/// @notice Covenant interface v1, section 12 (chips/INTERFACE.md). Copied verbatim from that document.
interface ISealedVM {
    /// One TAP-20 beat over a flat netlist (NAND and LATCH records only) stored at an SSTORE2 pointer.
    /// Must return exactly what Circuits.step returns for the same netlist, state and inputs.
    function step(address snapshot, uint32 nIn, uint32 nOut, bytes calldata state, bytes calldata inputs)
        external
        view
        returns (bytes memory newState, bytes memory outputs);
}
