// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Template shelf as seen by the platform
/// @notice The platform asks it exactly one thing: which factory serves this template id.
/// @dev `VaultRegistry` implements this explicitly. An interface and its implementation
///      sitting in two files with nothing binding them is how signatures drift without
///      the compiler ever noticing.
interface IVaultRegistry {
    function factoryOf(uint16 id) external view returns (address);
}
