// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {NetlistVM} from "tapeout/lib/NetlistVM.sol";

/// @notice TapeOut's verified `NetlistVM.burnOf` (contracts/vendor/tapeout-xlayer, unmodified), exposed so the
///         tests can use it as an independent oracle for `NetlistScan.burnOf`.
contract NetlistOracle {
    function burnOf(bytes memory nl) external pure returns (uint256 nNand, uint256 nLatch) {
        return NetlistVM.burnOf(nl);
    }
}
