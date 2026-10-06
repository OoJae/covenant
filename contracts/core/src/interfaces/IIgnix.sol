// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// The IGNIX and Uniswap V2 surface the kernel touches, and nothing else.
//
// Source: contracts/probes/src/interfaces/{IIgnix,IDirectedVault,IIgnixToken,IUniswapV2}.sol (our own fork
// probes), which were recovered from IGNIX's verified MIT implementation
// 0x126f5088cf077944933f5741fb71a6cc40f2942a (vendored in contracts/vendor/ignix-xlayer) and, for the vault
// and the token, whose sources are not verified, from runtime bytecode plus fork tests.
// The kernel never uses these interfaces for high-level calls on its value paths: every call is a gas-capped
// low-level call (lib/SafeCall.sol). They are here for selectors, tests and readers.

/// @notice IgnixManager (UUPS proxy 0x96b51c57e5346d0c0198899243cf851d1e23c309 on X Layer).
interface IIgnixManager {
    /// @notice Per-token curve state: 16 static words = 512 bytes. The struct is append-only upstream, so a
    ///         later version may return more than 512 bytes, never fewer.
    function tokens(address token)
        external
        view
        returns (
            address creator, // word 0
            uint16 buyFeeBps, // 1
            uint16 sellFeeBps, // 2
            uint16 taxBuyBps, // 3
            uint16 taxSellBps, // 4
            address quote, // 5
            uint16 snipeStartBps, // 6
            uint16 snipeMins, // 7
            uint64 createdAt, // 8
            uint128 vQuote, // 9
            uint128 vToken, // 10
            uint128 sold, // 11
            uint128 collected, // 12
            uint128 sellable, // 13
            uint128 reserve, // 14
            bytes32 poolId // 15
        );

    /// @notice The Uniswap V2 pair a taxed token graduated into. Non-zero means graduated.
    function pairOf(address token) external view returns (address);

    /// @notice The token's tax vault. Non-zero for every token this Manager created.
    function vaultOf(address token) external view returns (address);

    /// @notice Anti-snipe surcharge in bps right now. 0 when disabled or after the window.
    function snipeBpsNow(address token) external view returns (uint256);

    /// @notice Path `kind` is closed while block.timestamp < pausedUntil(kind). 1 = BUY, 6 = DIVIDEND (claims).
    function pausedUntil(uint256 kind) external view returns (uint64);

    function founderRound(address token)
        external
        view
        returns (bytes32 root, uint64 endsAt, uint128 capTotal, uint128 spentTotal);

    /// @notice Curve buy; tokens AND any overbuy refund go to `recipient`. Native quote: msg.value == amountIn.
    function buyTo(address token, uint256 amountIn, uint256 minTokensOut, address recipient) external payable;

    function buy(address token, uint256 amountIn, uint256 minTokensOut) external payable;
    function sell(address token, uint256 tokenIn, uint256 minQuoteOut) external;

    error Slippage(); // 0x7dd37f70
    error SoldOut(); // 0x52df9fe5
    error BadValue(); // 0x0bba69fb
    error FounderOnly(); // 0x2c353d89
    error Paused(); // 0x9e87fac8
    error Graduated_(); // 0x735c0da7
    /// OpenZeppelin's reentrancy guard: buy, buyTo and sell share one lock. A call made from inside any of
    /// them (the Manager pays sellers and refunds buyers by a native call) reverts with this.
    error ReentrancyGuardReentrantCall(); // 0x3ee5aeb5
}

/// @notice IGNIX "Directed" vault (template 3): 100% of the trading tax to one immutable RECIPIENT.
interface IDirectedVault {
    function RECIPIENT() external view returns (address);
    function TOKEN() external view returns (address);
    /// @notice address(0) = native OKB.
    function QUOTE() external view returns (address);
    function sync() external;
    /// @notice Only RECIPIENT may call. Pays the vault's whole balance of `asset` (QUOTE or TOKEN) to RECIPIENT.
    ///         Reverts NothingToClaim() on a zero balance and Paused() during an IGNIX DIVIDEND pause.
    function claim(address asset) external returns (uint256 amount);
    /// @notice Permissionless push to RECIPIENT.
    function claimFor(address recipient, address asset) external returns (uint256 amount);
    function claimableNow(address recipient, address asset) external view returns (uint256);
}

/// @notice The surface of an IGNIX launch token that the kernel uses. The token is not upgradeable.
interface IIgnixToken {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    /// @notice The Uniswap V2 pair the token graduated into; zero while it is on the curve. The Directed vault
    ///         uses the same test to decide which asset is claimable.
    function pair() external view returns (address);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    /// @dev Guarded by the pair's reentrancy lock: reverts "UniswapV2: LOCKED" inside a swap callback. The
    ///      kernel only ever makes a static call to it, to learn whether the lock is held.
    function sync() external;
}

/// @notice Uniswap V2 Router02 on X Layer (0x182a927119D56008d921126764bF884221b10f59).
interface IUniswapV2Router02 {
    function factory() external view returns (address);
    function WETH() external view returns (address);
    /// @dev The native-in variant that works with a fee-on-transfer token: it checks
    ///      balanceOf(to) after - before >= amountOutMin, so amountOutMin is net of the token's transfer tax.
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;
}
