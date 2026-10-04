// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Quote-currency receive and pay
/// @notice The quote currency may be native OKB (address 0) or an ERC20 such as USD₮0, and
///         balance, receive and pay are written differently for each. Keeping one copy here
///         stops the same logic, spread across several call sites, from drifting apart.
///
/// @dev Everything is `internal` and is **inlined** into the caller at compile time: no
///      separate deployment and no bytecode saved. It solves drift, not size.
library QuoteLib {
    using SafeERC20 for IERC20;

    error TransferFailed();

    /// @dev How much quote this contract currently holds
    function selfBalance(address quote) internal view returns (uint256) {
        return quote == address(0) ? address(this).balance : IERC20(quote).balanceOf(address(this));
    }

    /// @notice Pulls quote from `from` and **returns the amount actually received, not the
    ///         amount requested**.
    /// @dev If the quote currency takes a cut on transfer (fee-on-transfer), accounting the
    ///      requested amount would permanently desync the books from the real holdings, and
    ///      graduation injection would then fail on insufficient balance. USD₮0 is a LayerZero
    ///      OFT and could in principle be upgraded to charge a fee, so this is not a
    ///      hypothetical threat.
    ///      A native quote does not go through here — msg.value is already the amount received.
    function pullExact(address quote, address from, uint256 amount) internal returns (uint256) {
        uint256 before = IERC20(quote).balanceOf(address(this));
        IERC20(quote).safeTransferFrom(from, address(this), amount);
        return IERC20(quote).balanceOf(address(this)) - before;
    }

    /// @notice Pays quote out. Native goes through `call` and must succeed; ERC20 goes through
    ///         safeTransfer
    /// @dev A failed payment must revert the whole transaction rather than be swallowed —
    ///      otherwise the books say "paid" while the money is still sitting in the contract
    function pay(address quote, address to, uint256 amount) internal {
        if (quote == address(0)) {
            (bool ok,) = to.call{ value: amount }("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(quote).safeTransfer(to, amount);
        }
    }
}
