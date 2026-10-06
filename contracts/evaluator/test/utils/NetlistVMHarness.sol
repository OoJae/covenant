// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {NetlistVM} from "tapeout/lib/NetlistVM.sol";

/// @notice Test oracle: TapeOut's own evaluator and tape-out check, compiled unmodified from the vendored
///         verified source (contracts/vendor/tapeout-xlayer/src/lib/NetlistVM.sol).
contract NetlistVMHarness {
    /// @dev What `Circuits.step` computes, for a netlist passed as bytes.
    function run(bytes memory nl, uint32 nIn, uint32 nOut, bytes memory state, bytes memory inputs)
        external
        view
        returns (bytes memory newState, bytes memory outputs)
    {
        return NetlistVM.run(nl, nIn, nOut, state, inputs);
    }

    /// @dev What `Circuits.tapeout` checks before it accepts a netlist. The registry is the zero address,
    ///      so every REF record is rejected.
    function analyze(bytes memory nl, uint32 nIn, uint32 nOut)
        external
        view
        returns (uint256 nNand, uint256 nLatch, uint32 nState, uint32 gateCount)
    {
        return NetlistVM.analyze(nl, nIn, nOut, address(0));
    }
}
