// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IKernelMin - the only two functions the KeeperTank ever calls on a kernel.
///
/// @notice FROZEN FOREVER.
///         The KeeperTank is immutable and has no owner. It calls exactly these two selectors:
///
///             chipId()  0x0351e494
///             settle()  0x11da60b4
///
///         Every kernel version, now and later, that wants its settlement gas refunded from the tank
///         must expose both with exactly these names, parameters and (for `chipId`) return type.
///         Do not rename them, do not add parameters, do not change `chipId` to a smaller ABI type
///         that is not a single 32-byte word. Nothing can be changed on the tank's side.
///
/// @dev    What the tank relies on, beyond the signatures:
///
///         1. `ICircuits(circuits).ownerOf(chipId()) == address(kernel)`: the kernel holds its chip NFT.
///            A kernel that does not hold the chip gets no refund and no top-up attribution.
///
///         2. `settle()` MUST REVERT when it does no work (for example when the epoch has not elapsed).
///            The tank refunds the caller of every `settle()` that returns, out of the chip's allowance.
///            A `settle()` that returns without working lets anyone burn the chip's allowance for nothing.
///
///         3. The tank ignores the value `settle()` returns. A revert is bubbled up unchanged.
///
///         4. A kernel that tops up its own allowance by sending OKB to the tank with a plain call
///            must forward at least `KeeperTank.RECEIVE_MIN_GAS` gas with it (the tank reverts otherwise,
///            so a top-up is never silently mis-attributed). `KeeperTank.topUp(chipId)` has no such floor.
interface IKernelMin {
    /// @notice Id, in the Covenant processor's Circuits contract, of the chip this kernel holds.
    function chipId() external view returns (uint256);

    /// @notice Run one settlement. Reverts when there is nothing to do.
    function settle() external returns (uint32);
}
