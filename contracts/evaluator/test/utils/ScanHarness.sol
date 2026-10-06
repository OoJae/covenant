// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {NetlistScan} from "../../src/lib/NetlistScan.sol";
import {SSTORE2} from "../../src/lib/SSTORE2.sol";

/// @notice Exposes the internal libraries to tests (they take calldata).
contract ScanHarness {
    function scan(bytes calldata nl) external pure returns (uint256 nNand, uint256 nLatch) {
        return NetlistScan.scan(nl);
    }

    function write(bytes calldata data) external returns (address pointer) {
        return SSTORE2.write(data);
    }

    function read(address pointer) external view returns (bytes memory) {
        return SSTORE2.read(pointer);
    }
}
