// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title SafeCall
/// @notice Gas-capped low-level calls that can never make the caller revert and never copy more return data
///         than the caller asked for. The kernel uses them for every external dependency, so that
///           - a reverting, lying or gas-burning dependency becomes a flag, not a stuck settle;
///           - a huge return blob cannot be used to exhaust the kernel's gas (return-data bomb);
///           - the ABI decoder (which reverts in the caller on malformed data) is never on a value path.
library SafeCall {
    /// @notice staticcall with a gas cap that returns the first word of the return data.
    /// @return ok   the call succeeded and returned at least 32 bytes (false for an address without code)
    /// @return word the first 32 bytes returned; meaningless when `ok` is false
    function staticWord(address target, uint256 gasCap, bytes memory data)
        internal
        view
        returns (bool ok, uint256 word)
    {
        assembly ("memory-safe") {
            ok := staticcall(gasCap, target, add(data, 0x20), mload(data), 0x00, 0x20)
            ok := and(ok, gt(returndatasize(), 0x1f))
            word := mload(0x00)
        }
    }

    /// @notice staticcall with a gas cap that copies at most `max` bytes of return data.
    /// @return ok      the call itself succeeded
    /// @return retSize the full size of the return data (may exceed `max`)
    /// @return ret     the first min(retSize, max) bytes
    function staticRead(address target, uint256 gasCap, bytes memory data, uint256 max)
        internal
        view
        returns (bool ok, uint256 retSize, bytes memory ret)
    {
        assembly ("memory-safe") {
            ok := staticcall(gasCap, target, add(data, 0x20), mload(data), 0x00, 0x00)
            retSize := returndatasize()
            let n := retSize
            if gt(n, max) { n := max }
            ret := mload(0x40)
            mstore(ret, n)
            returndatacopy(add(ret, 0x20), 0x00, n)
            mstore(0x40, and(add(add(ret, 0x3f), n), not(0x1f)))
        }
    }

    /// @notice call with a gas cap and a value. Return data is not copied, except the first 4 bytes on failure.
    /// @return ok  the call succeeded (true for an address without code: callers only use this on addresses
    ///             that were verified to be contracts)
    /// @return err the first 4 bytes of the revert data when the call failed (zero if there were fewer)
    function exec(address target, uint256 gasCap, uint256 value, bytes memory data)
        internal
        returns (bool ok, bytes4 err)
    {
        assembly ("memory-safe") {
            ok := call(gasCap, target, value, add(data, 0x20), mload(data), 0x00, 0x00)
            if iszero(ok) {
                if gt(returndatasize(), 0x03) {
                    returndatacopy(0x00, 0x00, 0x04)
                    err := and(mload(0x00), 0xffffffff00000000000000000000000000000000000000000000000000000000)
                }
            }
        }
    }

    /// @notice call with a gas cap and a value that, when the call fails, copies at most `max` bytes of its
    ///         revert data. Nothing is copied when the call succeeds.
    /// @return ok  the call succeeded (true for an address without code, as for `exec`)
    /// @return err the first min(size, max) bytes of the revert data when the call failed; empty otherwise
    function execCatch(address target, uint256 gasCap, uint256 value, bytes memory data, uint256 max)
        internal
        returns (bool ok, bytes memory err)
    {
        assembly ("memory-safe") {
            ok := call(gasCap, target, value, add(data, 0x20), mload(data), 0x00, 0x00)
            let n := 0
            if iszero(ok) {
                n := returndatasize()
                if gt(n, max) { n := max }
            }
            err := mload(0x40)
            mstore(err, n)
            returndatacopy(add(err, 0x20), 0x00, n)
            mstore(0x40, and(add(add(err, 0x3f), n), not(0x1f)))
        }
    }
}
