// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Native - sends OKB without ever copying the callee's return data.
library Native {
    /// @notice Sends `value` wei to `to`, offering it `gasLimit` gas (the EVM forwards at most 63/64 of what is left).
    /// @dev    No return data is copied, so a callee cannot make the caller pay for a large return buffer.
    ///         A call to an address without code succeeds.
    /// @return ok false if the callee reverted or ran out of gas
    function send(address to, uint256 value, uint256 gasLimit) internal returns (bool ok) {
        assembly ("memory-safe") {
            ok := call(gasLimit, to, value, 0x00, 0x00, 0x00, 0x00)
        }
    }
}
