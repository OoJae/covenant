// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {KernelV2} from "../../src/KernelV2.sol";

/// @notice Reads KernelV2's per-call gas constants out of the kernel itself (they are `internal`), so that the fork
///         measurements compare the live costs with the constants the kernel really uses, and a change of one of
///         them trips a measurement (review B-F8). Test tree only; never deployed.
contract KernelV2GasPins is KernelV2 {
    function gView() external pure returns (uint256) {
        return G_VIEW;
    }

    function gNetlist() external pure returns (uint256) {
        return G_NETLIST;
    }

    function gClaim() external pure returns (uint256) {
        return G_CLAIM;
    }

    function gApprove() external pure returns (uint256) {
        return G_APPROVE;
    }

    function gBuy() external pure returns (uint256) {
        return G_BUY;
    }

    function gTransfer() external pure returns (uint256) {
        return G_TRANSFER;
    }

    function gSwap() external pure returns (uint256) {
        return G_SWAP;
    }

    function gSelf() external pure returns (uint256) {
        return G_SELF;
    }

    function nViews() external pure returns (uint256) {
        return N_VIEWS;
    }

    function minSettleGasOf(uint256 stepFloor, uint256 sealedFloor) external pure returns (uint256) {
        return _minSettleGas(stepFloor, sealedFloor);
    }
}
