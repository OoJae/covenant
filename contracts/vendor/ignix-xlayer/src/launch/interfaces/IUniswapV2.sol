// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @dev The official Uniswap V2 deployment on X Layer. Both addresses were read on-chain
///      rather than copied from another chain's deployment table — the canonical mainnet
///      addresses (`0x5C69bEe7…` / `0x7a250d56…`) are empty bytecode here (docs/34 §1.1).
///
///      Only the handful of methods we actually call are declared. Importing the upstream
///      interfaces would pull in a whole dependency for six selectors.
interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function feeTo() external view returns (address);
}

interface IUniswapV2Pair {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function totalSupply() external view returns (uint256);
    /// @dev `reserve0 * reserve1` as of the last liquidity event. Zero while the protocol fee
    ///      is off. `IgnixV2Locker` needs it to replay `_mintFee` before sizing a burn.
    function kLast() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
    function mint(address to) external returns (uint256 liquidity);
    function burn(address to) external returns (uint256 amount0, uint256 amount1);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    /// @dev Forces the balances to match the reserves by paying the excess to `to`. This is
    ///      how a pre-send to the (predictable, CREATE2) pair address is neutralised before
    ///      the first mint — see `V2Graduation.inject`.
    ///
    ///      **It only moves `balance - reserve`.** Anything already folded into the reserves
    ///      by `sync` is out of its reach, which is exactly why graduation must tolerate a
    ///      non-empty pair rather than assert one.
    function skim(address to) external;
    /// @dev The mirror of `skim`: folds the current balances *into* the reserves. Permissionless
    ///      on the official pair, and the reason `inject` cannot demand an empty pool.
    function sync() external;
}

/// @dev The official UniswapV2Router02 on X Layer, `0x182a9271…`. Its `factory()` returns the
///      factory above — two independent leads that cross-check (docs/34 §1.1).
///
///      **Only the fee-on-transfer exact-in variants are declared, and that is deliberate.**
///      A taxed IGNIX token charges inside `transfer`, so the plain `swapExactTokensForTokens`
///      fails the pair's K check; this family reads the pair's balance delta instead and
///      verifies the recipient's real net receipt. There is no fee-on-transfer exact-out
///      variant anywhere in Router02, because exact-out sizes the input off theoretical
///      reserves and therefore cannot promise what the recipient actually gets (docs/34 §1.3).
interface IUniswapV2Router02 {
    function factory() external view returns (address);
    function WETH() external view returns (address);
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;
    /// @dev The one `TaxConversionBase.convertTax` uses when the quote is native: `receive()`
    ///      takes the OKB, and its balance-delta assertion measures it the same either way.
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

/// @dev Wrapped native (WOKB on X Layer). A V2 pair needs an ERC20 on both sides, so a
///      natively quoted launch wraps its raise at graduation.
interface IWrappedNative {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// @dev What the Manager tells the V2 LP lock at graduation. One call, one shot.
interface IV2Locker {
    function MANAGER() external view returns (address);
    function lock(address pair) external;
}
