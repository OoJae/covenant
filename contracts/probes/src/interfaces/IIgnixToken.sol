// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title IGNIX launch token (V2 venue, fee-on-transfer after graduation).
/// @notice The token source is NOT verified on OKLink. Selectors were enumerated from the runtime bytecode
///         (9,419 bytes) and matched by name; behaviour is measured by the fork tests (test/Q3_BuyTo, Q6_Graduation, Q7_V2BuyBurn).
///
/// Behaviour, in one place:
///   - Supply is fixed at 1,000,000,000e18, minted to the Manager at creation. There is NO burn function and
///     no mint. transfer(address(0)) reverts ERC20InvalidReceiver. Sending tokens to 0x...dEaD leaves
///     totalSupply unchanged.
///   - On the curve (unlocked() == false): a transfer is allowed only when `from` or `to` is the Manager.
///     Anything else reverts CurveOnly() (0x9dabc49b): to 0xdEaD, to an EOA, to the vault, to itself, a
///     zero-value transfer, transferFrom by an approved spender. approve() works. So tokens bought with
///     buyTo cannot leave the recipient except through the Manager: selling them back to the curve
///     (approve + sell), or a plain transfer TO the Manager, which is a gift the curve does not account for.
///   - After graduation (unlocked() == true, pair() != 0): a transfer FROM the pair is a buy and loses
///     floor(amount * taxBuyBps / 1e4) to taxSink(); a transfer TO the pair is a sell and loses
///     floor(amount * taxSellBps / 1e4); every other transfer (wallet to wallet, contract to 0xdEaD) is
///     untaxed. Tax is paid in the project token, straight into the vault, inside the same transfer.
///   - taxExempt(): Manager, the vault (taxSink), the V2 LP locker and the liquidity helper. A vault's
///     RECIPIENT is NOT exempt, 0xdEaD is not exempt (irrelevant: plain transfers are untaxed anyway).
///   - Protection window: protectionEndsAt() = graduation time + protectionDuration() (8,640,000 s = 100
///     days on live launches, minimum 1 day). While it is open, every transfer whose counterparty is a
///     contract makes the token probe it with token0() / token1() / fee() (staticcall, 10,000 gas each) and
///     look the result up in the official Uniswap V2 / V3 factories; a GENUINE pool of this token is
///     auto-registered in pools() and taxed like the official pair. A contract that does not answer those
///     calls with a factory-registered pool is not affected. After the window only the official pair() is
///     taxed. The window blocks nothing a recipient contract does (router buys, transfers to 0xdEaD,
///     claims); it only makes those transfers a few thousand gas dearer.
interface IIgnixToken {
    // ── ERC-20 ──
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    // ── IGNIX views ──
    function MANAGER() external view returns (address); // 0x1b2df850
    /// @notice false on the curve, true from the graduating transaction onwards.
    function unlocked() external view returns (bool); // 0x6a5e2650
    /// @notice The taxed Uniswap V2 pair; zero before graduation.
    function pair() external view returns (address); // 0xa8aa1b31
    /// @notice Where the transfer tax goes: the token's vault.
    function taxSink() external view returns (address); // 0x655e764a
    function taxBuyBps() external view returns (uint256); // 0x44e1ba46
    function taxSellBps() external view returns (uint256); // 0xca5b0bee
    function taxExempt(address account) external view returns (bool); // 0xd1ecfc68
    /// @notice Extra pools registered by the platform (addDetectedPools). Taxed/blocked during protection.
    function pools(address account) external view returns (bool); // 0xa4063dbc
    /// @notice Dividend tracker, zero for a Directed vault.
    function tracker() external view returns (address); // 0xf52bccad

    // ── graduation protection window ──
    function protectionDuration() external view returns (uint256); // 0x33eb06c4 (8,640,000 s on live launches)
    /// @notice 0 before graduation; graduation timestamp + protectionDuration afterwards.
    function protectionEndsAt() external view returns (uint256); // 0xa929442c
    function protectionActive() external view returns (bool); // 0xc294e9a6
    function protectionRouter() external view returns (address); // 0xe383058e
    function protectionHook() external view returns (address); // 0x30e466b3
    function protectionQuote() external view returns (address); // 0xbd4ee19f (WOKB for a native quote)
    function poolManager() external view returns (address); // 0xdc4c90d3
    function lpLocker() external view returns (address); // 0x03fc2013

    // Manager-only (listed for completeness, never callable by a kernel):
    // initProtection 0x45c12cad, initTracker 0x3a6de101, initTaxConfig 0x3498f69c, unlock 0xa69df4b5,
    // setPair 0x8187f516, addDetectedPools 0x7a0d571c, setTaxExempt 0x1dc61040,
    // openSwapGate 0xe02a5e78 / closeSwapGate 0x774dd5ea (protection router only).

    // ── errors (selectors measured on the fork) ──
    error CurveOnly(); // 0x9dabc49b  any non-Manager transfer before graduation
    error ERC20InvalidReceiver(address receiver); // 0xec442f05  transfer to address(0)
}
