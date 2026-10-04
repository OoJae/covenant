// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @dev Minimal Uniswap V2 surface used by the probes. X Layer (chain 196) deployment, verified on OKLink:
///      Router02 0x182a927119D56008d921126764bF884221b10f59, Factory 0xDf38F24fE153761634Be942F9d859f3DBA857E95,
///      WOKB 0xe538905cf8410324e03A5A23C1c177a474D59b2b. Swap fee 0.3% (997/1000).

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function feeTo() external view returns (address);
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function factory() external view returns (address);
    function totalSupply() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;
}

interface IUniswapV2Router02 {
    function factory() external view returns (address);
    function WETH() external view returns (address);
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);

    /// @dev The only native-in variant that works with an IGNIX fee-on-transfer token. It checks
    ///      balanceOf(to) after - before >= amountOutMin, i.e. minOut is the amount NET of the token tax.
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    /// @dev Plain variant; kept only to show how it behaves with a taxed token.
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);
}

interface IWOKB {
    function deposit() external payable;
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}
