// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IKernelMin} from "../../src/interfaces/IKernelMin.sol";

/// @notice A well-behaved stand-in for a kernel: it holds a chip, counts settlements and can be told to burn
///         a given amount of gas per settlement or to revert.
contract MockKernel is IKernelMin {
    error NothingToSettle(uint256 epoch);

    uint256 internal immutable CHIP_ID;

    uint256 public settles;
    uint256 public burnGas;
    /// @dev 0 = succeed, 1 = revert with a string, 2 = revert with a custom error, 3 = revert with no data
    uint8 public revertMode;

    constructor(uint256 chipId_) {
        CHIP_ID = chipId_;
    }

    function chipId() external view returns (uint256) {
        return CHIP_ID;
    }

    function settle() external virtual returns (uint32) {
        if (revertMode == 1) revert("kernel: epoch not elapsed");
        if (revertMode == 2) revert NothingToSettle(42);
        if (revertMode == 3) {
            assembly {
                revert(0, 0)
            }
        }
        _burn(burnGas);
        return uint32(++settles);
    }

    function setBurnGas(uint256 gas_) external {
        burnGas = gas_;
    }

    function setRevertMode(uint8 mode) external {
        revertMode = mode;
    }

    /// @notice Sends OKB with a plain call, the way a kernel would pay its allowance route to a payee.
    function pay(address to, uint256 value, uint256 gasLimit) external returns (bool ok) {
        (ok,) = to.call{value: value, gas: gasLimit}("");
    }

    receive() external payable {}

    function _burn(uint256 amount) internal view {
        uint256 start = gasleft();
        while (start - gasleft() < amount) {}
    }
}
