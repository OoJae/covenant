// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { LiquidityAmounts } from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import { CurveMath } from "./CurveMath.sol";
import { PriceMath } from "./PriceMath.sol";
import { IIgnixToken, IPositionManager, IPermit2, IPoolGuard } from "../interfaces/IExternal.sol";

/// @title IGNIX Manager linked logic module
/// @notice Contains bytecode-heavy admission, curve calculations and V4 graduation. Pure
///         calculations never touch storage; the V4 adapter runs through DELEGATECALL so
///         `address(this)`, balances and downstream `onlyManager` checks remain the proxy's.
///         The Manager remains the sole owner of storage transitions and event emission.
library LaunchLogic {
    using SafeERC20 for IERC20;
    uint256 private constant BPS = 10_000;
    uint256 private constant PLATFORM_CURVE_FEE_BPS = 100;
    uint256 private constant MAX_PROJECT_TAX_BPS = 1_000;
    uint256 private constant MAX_FOUNDER_BPS = 2_000;
    uint256 private constant MAX_FOUNDER_SECS = 30 days;
    uint256 private constant MIN_SNIPE_BPS = 2_000;
    uint256 private constant MAX_SNIPE_BPS = 9_000;
    uint256 private constant MAX_TOTAL_BPS = 9_500;
    uint256 private constant MIN_PROTECTION_DURATION = 1 days;
    uint8 private constant VENUE_V4 = 0;
    uint8 private constant VENUE_V2 = 1;

    error BadValue();
    error FeeTooHigh();

    struct Validation {
        uint256 graduation;
        uint256 firstBuy;
        uint16 buyFeeBps;
        uint16 sellFeeBps;
        uint16 taxBuyBps;
        uint16 taxSellBps;
        uint16 snipeStartBps;
        uint16 snipeMins;
        uint16 founderBps;
        uint32 founderSecs;
        bytes32 founderRoot;
        uint8 venue;
        uint64 protectionSecs;
    }

    struct InitialCurve {
        uint128 vQuote;
        uint128 vToken;
        uint128 sellable;
        uint128 reserve;
    }

    struct V4Venue {
        IPoolManager poolManager;
        IPositionManager positionManager;
        IPermit2 permit2;
        address locker;
    }

    function validate(Validation calldata p) external pure {
        if (p.founderBps > 0) {
            if (p.founderBps > MAX_FOUNDER_BPS) revert FeeTooHigh();
            if (p.founderSecs == 0 || p.founderSecs > MAX_FOUNDER_SECS) revert BadValue();
            if (p.founderRoot == bytes32(0)) revert BadValue();
            uint256 founderCap = Math.mulDiv(p.graduation, p.founderBps, BPS);
            if (p.firstBuy > p.graduation - founderCap) revert BadValue();
        } else if (p.founderSecs != 0 || p.founderRoot != bytes32(0)) {
            revert BadValue();
        }

        if (p.buyFeeBps != PLATFORM_CURVE_FEE_BPS || p.sellFeeBps != PLATFORM_CURVE_FEE_BPS) {
            revert FeeTooHigh();
        }
        if (p.taxBuyBps > MAX_PROJECT_TAX_BPS || p.taxSellBps > MAX_PROJECT_TAX_BPS) {
            revert FeeTooHigh();
        }
        if (p.snipeStartBps != 0) {
            if (p.snipeStartBps < MIN_SNIPE_BPS || p.snipeStartBps > MAX_SNIPE_BPS) {
                revert FeeTooHigh();
            }
            if (p.snipeMins == 0) revert FeeTooHigh();
            if (uint256(p.snipeStartBps) + p.buyFeeBps + p.taxBuyBps > MAX_TOTAL_BPS) {
                revert FeeTooHigh();
            }
        }

        // Venue, tax and protection window are bound to each other (docs/56): a V4 token is
        // clean and graduates with no protection at all, a V2 token must tax and keeps its
        // window floor. This is the only home of the duration policy — the token layer
        // deliberately carries none, so a bypass of the signing service must fail here.
        if (p.venue == VENUE_V2) {
            if (p.taxBuyBps == 0 && p.taxSellBps == 0) revert BadValue();
            if (p.protectionSecs < MIN_PROTECTION_DURATION) revert BadValue();
        } else {
            if (p.venue != VENUE_V4 || p.taxBuyBps != 0 || p.taxSellBps != 0) {
                revert BadValue();
            }
            if (p.protectionSecs != 0) revert BadValue();
        }
    }

    function recoverSigner(bytes32 digest, bytes calldata signature)
        external
        pure
        returns (address)
    {
        return ECDSA.recover(digest, signature);
    }

    /// @notice Derives and bounds the packed curve state written by the Manager.
    /// @dev `terminalCollected` is the exact rounded-up amount needed to sell the curve, so
    ///      both the initial reserve and its maximum reachable value must fit uint128.
    function initialCurve(uint256 graduation) external pure returns (InitialCurve memory curve) {
        (uint256 sellable, uint256 reserve, uint256 vToken, uint256 vQuote) =
            CurveMath.params(graduation);
        uint256 terminalCollected = CurveMath.quoteInFor(vQuote, vToken, sellable);
        if (terminalCollected > type(uint128).max || vQuote > type(uint128).max - terminalCollected)
        {
            revert BadValue();
        }

        curve = InitialCurve({
            vQuote: SafeCast.toUint128(vQuote),
            vToken: SafeCast.toUint128(vToken),
            sellable: SafeCast.toUint128(sellable),
            reserve: SafeCast.toUint128(reserve)
        });
    }

    /// @notice Proves the V4 hook and permanent locker before the Manager latches them.
    function validateV4Configuration(address hook, address locker) external view {
        if (
            hook == address(0) || hook.code.length == 0
                || IPoolGuard(hook).PROTECTION_ROUTER() == address(0) || locker == address(0)
        ) revert BadValue();
    }

    function poolKey(address token, address quote, uint24 poolFee, int24 tickSpacing, address hook)
        internal
        pure
        returns (PoolKey memory key)
    {
        bool quoteIsZero = uint160(quote) < uint160(token);
        key = PoolKey({
            currency0: Currency.wrap(quoteIsZero ? quote : token),
            currency1: Currency.wrap(quoteIsZero ? token : quote),
            fee: poolFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hook)
        });
    }

    /// @notice Unlock the token, initialize its V4 pool and inject the complete curve raise.
    /// @dev The Manager stores the pool id as the graduated flag before entering. Approvals and
    ///      `nextTokenId` are completed before initialize; once the empty pool exists, mint is
    ///      the next external action so no callback window exposes an unfunded pool.
    function injectV4(
        PoolKey memory key,
        address token,
        address quote,
        uint128 lpQuote,
        uint128 lpToken,
        V4Venue memory venue
    ) external returns (uint256 tokenId) {
        bool quoteIsZero = uint160(quote) < uint160(token);
        IIgnixToken(token).unlock();

        uint128 amount0 = quoteIsZero ? lpQuote : lpToken;
        uint128 amount1 = quoteIsZero ? lpToken : lpQuote;
        _permit2(venue, token, lpToken);
        if (quote != address(0)) _permit2(venue, quote, lpQuote);
        tokenId = venue.positionManager.nextTokenId();

        uint160 sqrtPriceX96 = PriceMath.sqrtPriceX96(amount1, amount0);
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );

        venue.poolManager.initialize(key, sqrtPriceX96);
        _mintFullRange(
            key, tickLower, tickUpper, liquidity, amount0, amount1, venue, quote, lpQuote
        );
        IPoolGuard(address(key.hooks)).register(key, token);
    }

    function _mintFullRange(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1,
        V4Venue memory venue,
        address quote,
        uint256 lpQuote
    ) private {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key,
            tickLower,
            tickUpper,
            liquidity,
            SafeCast.toUint128(amount0),
            SafeCast.toUint128(amount1),
            venue.locker,
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(Currency.wrap(quote), address(this));
        venue.positionManager.modifyLiquidities{ value: quote == address(0) ? lpQuote : 0 }(
            abi.encode(actions, params), block.timestamp
        );
    }

    function _permit2(V4Venue memory venue, address token, uint256 amount) private {
        IERC20(token).forceApprove(address(venue.permit2), amount);
        venue.permit2
            .approve(
                token, address(venue.positionManager), uint160(amount), uint48(block.timestamp)
            );
    }
}
