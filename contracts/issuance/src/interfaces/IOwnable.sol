// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice owner(). Only script/Ignite.s.sol uses it, to print who owns TapeOut's factory; no deployed
///         contract reads it.
interface IOwnable {
    function owner() external view returns (address);
}
