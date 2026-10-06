// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SSTORE2: bytes stored as the runtime code of a data contract (write once, read many)
/// @notice Adapted for Covenant from TapeOut's `lib/SSTORE2.sol` (MIT; verified source of the circuit
///         implementation 0x977f217887E085D298Cb3819cDAD5A0ee35F29B2 on X Layer, vendored unmodified in
///         contracts/vendor/tapeout-xlayer), which follows solmate's SSTORE2.
///
///         The pointer format is TapeOut's, byte for byte: the runtime code is 0x00 (STOP) followed by
///         the data, so the data contract can never be executed, and the creation code is the same
///         eleven-byte prefix.
///
///         Changes from TapeOut's library: `write` takes calldata and builds the creation code in place
///         (one copy instead of two), failures are custom errors, comments are in English.
library SSTORE2 {
    /// @dev Number of bytes before the data in the runtime code: the leading STOP.
    uint256 internal constant DATA_OFFSET = 1;

    /// @notice The data contract could not be created.
    error WriteFailed();

    /// @notice Deploys `data` as a data contract and returns its address.
    /// @dev Creation code: 0x600B5981380380925939F3, then the runtime code (0x00, then `data`).
    ///
    ///        PUSH1 0x0B   length of this prefix
    ///        MSIZE        0
    ///        DUP2         0x0B
    ///        CODESIZE
    ///        SUB          runtime length
    ///        DUP1
    ///        SWAP3
    ///        MSIZE        0
    ///        CODECOPY     memory[0 ..) = code[0x0B ..)
    ///        RETURN       memory[0 .. runtime length)
    function write(bytes calldata data) internal returns (address pointer) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            // 11 bytes of creation code and the leading STOP of the runtime code, left-aligned
            mstore(ptr, 0x600B5981380380925939F3000000000000000000000000000000000000000000)
            calldatacopy(add(ptr, 12), data.offset, data.length)
            pointer := create(0, ptr, add(data.length, 12))
        }
        if (pointer == address(0)) revert WriteFailed();
    }

    /// @notice Returns the data stored at `pointer`: its runtime code without the leading STOP.
    function read(address pointer) internal view returns (bytes memory data) {
        uint256 size = pointer.code.length;
        if (size <= DATA_OFFSET) return "";
        unchecked {
            size -= DATA_OFFSET;
        }
        data = new bytes(size);
        assembly ("memory-safe") {
            extcodecopy(pointer, add(data, 0x20), DATA_OFFSET, size)
        }
    }
}
