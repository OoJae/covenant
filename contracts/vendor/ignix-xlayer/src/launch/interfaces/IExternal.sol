// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @dev The official IPositionManager drags in the permit2 repo (not on npm, needs a
///      remapping), and we only use these few methods — declaring them here beats pulling in
///      a submodule for a handful of functions
interface IPositionManager {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory, uint256);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);
}

/// @dev The PositionManager pulls ERC20s through Permit2; approve is the only method we use
interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @dev At graduation, registers the pool with the V4 guard so it knows which token's
///      settlement gate to open during the protection window. **No tax is involved** — V4
///      tokens are zero-tax by construction (`createToken` binds venue to tax one-to-one).
interface IPoolGuard {
    function PROTECTION_ROUTER() external view returns (address);
    function register(PoolKey calldata key, address token) external;
}

/// Deployer for the launch token. **It is external for one reason: the bytecode budget** —
/// every `new` in the Manager embeds the deployed contract's full creation code into the
/// Manager itself (IgnixToken alone is several kilobytes). See IgnixLaunchFactory's comment
interface ILaunchFactory {
    function deployToken(
        string calldata name,
        string calldata symbol,
        address manager,
        bytes32 salt
    ) external returns (address token);
}

// The three vault-family interfaces (IVaultRegistry / IVaultFactory / IVault) are
// **deliberately not redeclared here** — the Manager imports the authoritative definitions
// from `src/vault/interfaces/` directly.
//
// Duplicating them is a real hazard: **return types are not part of the selector**. A
// signature drifting between the two copies (say `validate` changing from `(bool, string)` to
// `bool`) compiles without a word, and the Manager would still make the call and then fail to
// decode the result — showing up as **every single token creation reverting at runtime**.
// An interface emits no bytecode, so there is no reason whatsoever to keep a copy.

/// The launch token. The Manager needs only this narrow interface and **does not import the
/// concrete contract type** — that would pull the token's multi-kilobyte creation code back
/// into the Manager, which is exactly what we are avoiding
interface IIgnixToken {
    function initProtection(
        uint64 duration,
        address poolManager,
        address hook,
        address protectionRouter,
        address lpLocker,
        address quoteErc
    ) external;
    function unlock() external;
    function initTracker(address tracker) external;
    /// @dev V2 venue only. Written back inside `createToken` — the tax sink is the token's own
    ///      vault, which is deployed *from* the token address and so cannot be a constructor
    ///      argument. `locker` is exempted so LP-fee harvests are not taxed on the way out
    function initTaxConfig(
        address sink,
        uint16 buyBps,
        uint16 sellBps,
        address locker,
        address liquidityHelper
    ) external;
    /// @dev V2 venue only, and **after** the liquidity injection
    function setPair(address pair) external;
    function addDetectedPools(address[] calldata pools) external;
    function setTaxExempt(address account, bool exempt) external;
}

interface ISwapGateToken {
    function openSwapGate() external;
    function protectionActive() external view returns (bool);
}

interface ILiquidityHelperConfig {
    function MANAGER() external view returns (address);
    function FACTORY() external view returns (address);
    function ROUTER() external view returns (address);
    function WRAPPED_NATIVE() external view returns (address);
}
