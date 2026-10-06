// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The ERC-20 surface of the quote asset (USD₮0 on X Layer, 0x779Ded0c9e1022225f8E0630b35a9b54bE713736)
///         that a v2 kernel touches. As in kernel v1, these declarations are for selectors, tests and readers:
///         the kernel calls the quote asset only through gas-capped low-level calls (core/lib/SafeCall.sol) and
///         measures every amount by balance, never by a return value.
interface IQuoteToken {
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Uniswap V2 Router02 on X Layer (0x182a927119D56008d921126764bF884221b10f59): the ERC-20 to ERC-20
///         variant that works with IGNIX's fee-on-transfer token. It pulls `amountIn` of path[0] from the
///         caller with transferFrom and checks balanceOf(to) after - before >= amountOutMin.
interface IUniswapV2RouterTT {
    function factory() external view returns (address);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}
