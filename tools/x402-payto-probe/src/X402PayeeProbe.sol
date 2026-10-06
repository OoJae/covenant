// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @title X402PayeeProbe
/// @notice A throwaway payee for ONE live check: does OKX's hosted x402 facilitator settle a payment whose
///         `payTo` is a plain contract (code that is not an EIP-7702 delegation)?
///         It is not a kernel, holds no chip, cannot buy or sell any token and calls nothing but USD₮0.
///         Its only exit sends its whole USD₮0 balance back to REFUND_TO, fixed at deployment (the wallet that
///         paid for the test), so the test payment makes a round trip and is never anyone's revenue.
///         No owner, no upgrade, no receive/fallback (plain OKB sent here reverts).
/// @dev    Limits, stated openly: Tether can freeze or destroy USD₮0 held here, as anywhere. Anything paid here
///         by someone else also ends up at REFUND_TO, so the test seller that points at this contract must not
///         be listed anywhere and must be deleted after the test.
contract X402PayeeProbe {
    IERC20Min public constant USDT0 = IERC20Min(0x779Ded0c9e1022225f8E0630b35a9b54bE713736);
    address public immutable REFUND_TO;

    event Swept(address indexed to, uint256 amount);

    error ZeroRefundTo();
    error SweepShort(uint256 expected, uint256 arrived);

    constructor(address refundTo) {
        if (refundTo == address(0) || refundTo == address(this)) revert ZeroRefundTo();
        REFUND_TO = refundTo;
    }

    /// @notice Anyone may call. Measured by balance delta; the token's return value is not trusted.
    function sweep() external returns (uint256 amount) {
        amount = USDT0.balanceOf(address(this));
        if (amount == 0) return 0;
        uint256 b0 = USDT0.balanceOf(REFUND_TO);
        USDT0.transfer(REFUND_TO, amount);
        uint256 arrived = USDT0.balanceOf(REFUND_TO) - b0;
        if (arrived != amount) revert SweepShort(amount, arrived);
        emit Swept(REFUND_TO, amount);
    }
}
