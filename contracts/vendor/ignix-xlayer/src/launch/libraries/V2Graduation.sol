// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IIgnixToken, ILiquidityHelperConfig } from "../interfaces/IExternal.sol";
import {
    IUniswapV2Factory,
    IUniswapV2Pair,
    IUniswapV2Router02,
    IWrappedNative,
    IV2Locker
} from "../interfaces/IUniswapV2.sol";

/**
 * @title Graduation onto Uniswap V2
 *
 * ## Why this is a linked library rather than a method on the Manager
 *
 * Purely the bytecode budget, and it is not close: measured on its own, this sequence costs
 * the Manager **2,687 bytes** — a dozen external calls, each carrying its own ABI encode and
 * decode — against 2,544 bytes of headroom under EIP-170. Written inline the Manager does not
 * deploy at all (CLAUDE.md §9.2; docs/34 §6 anticipated this and named the remedy).
 *
 * **`external` is what makes it work.** An `internal` library is inlined into the caller and
 * saves nothing; an `external` one is deployed separately and reached by `DELEGATECALL`. That
 * distinction is the whole point, and it is also what makes the move free of new trust:
 *
 *   · `address(this)` is still the Manager, so the raise never leaves it until it reaches the
 *     pair. No intermediary ever holds the funds — which is exactly what a plain helper
 *     contract taking custody for one call would have introduced;
 *   · `msg.sender` at the token is still the Manager, so `unlock` and `setPair` stay
 *     `onlyManager` and no address gains a new privilege;
 *   · storage writes land in the Manager's slots, so `pairOf` can be written **before** the
 *     first external call and CEI is preserved.
 *
 * The cost is a deployment step: the Manager implementation carries this library's address in
 * its bytecode, so **an upgrade must re-link it** and the address belongs in the deployment
 * table alongside the others. Verify it the same way as everything else — `cast code` on the
 * implementation and look for the linked address (docs/25).
 *
 * ## The step order is the design
 *
 * Each of these is here because of a specific way it goes wrong otherwise:
 *
 *   1. `getPair ?: createPair` — `createPair` is permissionless on the official factory, so
 *      anyone may front-run it. An empty pair is harmless; calling `createPair` on one that
 *      already exists reverts, which would strand the graduation for good.
 *   2. **`skim`, then neutralise any quote already folded into reserves.** A pair address is
 *      a CREATE2 address and therefore predictable, and quote is not subject to the curve-phase
 *      transfer restriction, so anyone can pre-send quote to a pair that does not exist yet.
 *      `skim` removes an un-synced pre-send. If the attacker called permissionless `sync`, the
 *      quote is already a reserve and cannot be skimmed. Leaving it there would move the
 *      opening price to `(lpQuote + donation) / lpToken`.
 *
 *      The synced case therefore mints with a fee-aware token seed, transfers the remaining
 *      token as swap input, and swaps the old quote reserve to a fixed burn address. The seed
 *      is the largest integer satisfying Uniswap V2's 0.3% invariant. The final assertion pins
 *      reserves to exactly `(lpToken, lpQuote)`: neither a 1 wei liveness attack nor a large
 *      price donation is accepted.
 *   3. `unlock` **before** the skim, not merely before the injection: `skim` transfers on both
 *      sides unconditionally, and a zero-value transfer of a still-restricted token reverts.
 *   4. `setPair` **after** the injection, so "the injection cannot be taxed" is a property of
 *      the ordering rather than of the exemption list happening to contain the Manager. The
 *      exemption list still exists — the LP locker genuinely needs it.
 *   5. `lock` last, so the locker's permanent baseline is recorded against the pool exactly as
 *      it was funded.
 */
library V2Graduation {
    using SafeERC20 for IERC20;

    /// The V2 venue is a chain-level dependency, not a creator-selectable market. Pinning the
    /// X Layer addresses prevents a one-shot configuration typo from silently graduating every
    /// taxed launch into an unrelated factory or wrapped asset. Enforced in
    /// `validateConfiguration`, which is the single gate `IgnixManager.configure2` runs.
    address private constant XLAYER_V2_FACTORY = 0xDf38F24fE153761634Be942F9d859f3DBA857E95;
    address private constant XLAYER_V2_ROUTER02 = 0x182a927119D56008d921126764bF884221b10f59;
    address private constant XLAYER_WRAPPED_NATIVE = 0xe538905cf8410324e03A5A23C1c177a474D59b2b;
    /// @dev Canonical Uniswap V2 pair creation-code hash on X Layer. `pair = CREATE2(factory,
    ///      keccak(token0, token1), this)`. Same value the router bakes in (deployments.mjs).
    bytes32 private constant PAIR_INIT_CODE_HASH =
        0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

    /// Where a pre-send to the not-yet-created pair is swept. See step 2 above.
    address private constant SAFE_SINK = 0x000000000000000000000000000000000000dEaD;
    /// @dev Smallest `tokenAmount * quoteAmount` that canonical V2 actually mints on, i.e.
    ///      `(MINIMUM_LIQUIDITY + 1) ** 2` — **not** `MINIMUM_LIQUIDITY ** 2`. See
    ///      `initialMintPossible` for why the intuitive square is off by one band.
    uint256 private constant MIN_INITIAL_MINT_PRODUCT = 1_002_001;

    error ActivePair();
    error DonationTooLarge();
    error InsufficientInitialLiquidity();
    error OpeningReservesWrong();
    error BadValue();

    /// @dev Bundled into a struct because they arrive as separate Manager storage reads
    ///      and a multi-argument tail is one transposition away from a silent mis-wiring.
    struct Venue {
        address factory; // official Uniswap V2 factory on X Layer
        address locker; // IgnixV2Locker — the LP goes straight there
        address wrappedNative; // WOKB; a V2 pair needs an ERC20 on both sides
    }

    /// @notice The deterministic V2 pair address for a launch, whether or not the pair has been
    ///         created yet.
    /// @dev Curve-phase tokens are transfer-locked, so the only way a token balance reaches this
    ///      address before graduation is a Manager-mediated transfer — which `buyTo` would allow
    ///      by naming the pair as recipient. A pre-seeded, then permissionlessly `sync`-ed token
    ///      reserve makes `inject`'s `ActivePair` guard revert forever (a graduation DoS), so the
    ///      Manager rejects it. Because the pair is a CREATE2 address, this predicts it before it
    ///      exists too — checking the live `getPair` would miss a send that precedes `createPair`.
    /// @param quote the launch quote; `address(0)` means the pair counter-asset is `wrappedNative`
    function pairFor(address factory, address token, address quote, address wrappedNative)
        internal
        pure
        returns (address)
    {
        address wq = quote == address(0) ? wrappedNative : quote;
        (address token0, address token1) = token < wq ? (token, wq) : (wq, token);
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        return address(
            uint160(uint256(keccak256(abi.encodePacked(hex"ff", factory, salt, PAIR_INIT_CODE_HASH))))
        );
    }

    /// @notice Proves the complete V2 venue wiring before the Manager latches it into storage.
    /// @dev This external library method runs with DELEGATECALL, so `address(this)` is the
    ///      Manager proxy expected by the locker and helper reverse bindings.
    function validateConfiguration(
        address factory,
        address router02,
        address locker,
        address wrappedNative,
        address liquidityHelper
    ) external view {
        if (
            factory.code.length == 0 || router02.code.length == 0 || locker.code.length == 0
                || wrappedNative.code.length == 0 || liquidityHelper.code.length == 0
        ) revert BadValue();
        if (IV2Locker(locker).MANAGER() != address(this)) revert BadValue();
        if (
            IUniswapV2Router02(router02).factory() != factory
                || IUniswapV2Router02(router02).WETH() != wrappedNative
        ) revert BadValue();
        ILiquidityHelperConfig helper = ILiquidityHelperConfig(liquidityHelper);
        if (
            helper.MANAGER() != address(this) || helper.FACTORY() != factory
                || helper.ROUTER() != router02 || helper.WRAPPED_NATIVE() != wrappedNative
        ) revert BadValue();
        if (
            block.chainid == 196
                && (factory != XLAYER_V2_FACTORY
                    || router02 != XLAYER_V2_ROUTER02
                    || wrappedNative != XLAYER_WRAPPED_NATIVE)
        ) revert BadValue();
    }

    /// @dev Largest token seed for which the remaining token can buy out the entire synced
    ///      quote reserve under Uniswap V2's 0.3% fee invariant:
    ///      `997 * lpQuote * (lpToken - seed) >= 1000 * syncedQuote * seed`.
    function neutralizingSeed(uint256 lpToken, uint256 lpQuote, uint256 syncedQuote)
        internal
        pure
        returns (uint256)
    {
        uint256 quoteWithFee = lpQuote * 997;
        return Math.mulDiv(lpToken, quoteWithFee, syncedQuote * 1000 + quoteWithFee);
    }

    /**
     * @dev Canonical V2 burns 1,000 LP units on the first mint, so it needs
     *      `Math.sqrt(tokenAmount * quoteAmount) - 1000 > 0`. Keep that dependency local
     *      instead of relying on CurveMath's unrelated graduation floor to make it true by
     *      accident.
     *
     *      **The intuitive threshold is off by one band.** Over the reals
     *      `sqrt(k) > 1000` is `k > 1000**2`, but V2's `Math.sqrt` floors, so what it really
     *      requires is `floor(sqrt(k)) >= 1001`, i.e. `k >= 1001**2 = 1_002_001`. Testing
     *      `k > 1_000_000` therefore passes the whole band `[1_000_001, 1_002_000]`, where
     *      `floor(sqrt(k))` is still exactly 1000 and the mint reverts with
     *      `INSUFFICIENT_LIQUIDITY_MINTED` (2026-08-16 external audit).
     *
     *      Unreachable at any real graduation size — the smallest legal `seed` is 1 and
     *      `lpQuote` is at least ~1e8 even for a 6-decimal quote, so `k` clears the band by
     *      two orders of magnitude at minimum. Corrected anyway: this function exists solely
     *      to fail early with a legible error, and a guard that is wrong exactly at its own
     *      boundary hands the revert back to Uniswap with the curve already sold out.
     */
    function initialMintPossible(uint256 tokenAmount, uint256 quoteAmount)
        internal
        pure
        returns (bool)
    {
        return tokenAmount * quoteAmount >= MIN_INITIAL_MINT_PRODUCT;
    }

    function _orderedReserves(address pair, address token)
        private
        view
        returns (uint256 tokenReserve, uint256 quoteReserve, bool tokenIsZero)
    {
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        tokenIsZero = IUniswapV2Pair(pair).token0() == token;
        (tokenReserve, quoteReserve) =
            tokenIsZero ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    /**
     * @param pairOf the Manager's own mapping, passed by storage pointer so the graduated flag
     *        is set before any external call rather than after it
     * @return pair the Uniswap V2 pool this token now trades on
     */
    function inject(
        mapping(address => address) storage pairOf,
        address token,
        address quote,
        uint128 lpQuote,
        uint128 lpToken,
        Venue memory v
    ) external returns (address pair) {
        address wq = quote == address(0) ? v.wrappedNative : quote;

        pair = IUniswapV2Factory(v.factory).getPair(token, wq);
        if (pair == address(0)) pair = IUniswapV2Factory(v.factory).createPair(token, wq);
        // Doubles as the graduated flag (`IgnixManager._live`), written before anything
        // external runs
        pairOf[token] = pair;

        IIgnixToken(token).unlock();
        if (quote == address(0)) IWrappedNative(wq).deposit{ value: lpQuote }();

        IUniswapV2Pair(pair).skim(SAFE_SINK);

        (uint256 tokenReserve, uint256 syncedQuote, bool tokenIsZero) =
            _orderedReserves(pair, token);
        if (IUniswapV2Pair(pair).totalSupply() != 0 || tokenReserve != 0) revert ActivePair();

        if (syncedQuote == 0) {
            if (!initialMintPossible(lpToken, lpQuote)) revert InsufficientInitialLiquidity();
            IERC20(token).safeTransfer(pair, lpToken);
            IERC20(wq).safeTransfer(pair, lpQuote);
            IUniswapV2Pair(pair).mint(v.locker);
        } else {
            uint256 seed = neutralizingSeed(lpToken, lpQuote, syncedQuote);
            if (seed == 0 || seed >= lpToken) revert DonationTooLarge();
            if (!initialMintPossible(seed, lpQuote)) revert InsufficientInitialLiquidity();

            // Establish real liquidity first. The old quote reserve is part of the pair's
            // balance but not part of the amount credited by this mint.
            IERC20(token).safeTransfer(pair, seed);
            IERC20(wq).safeTransfer(pair, lpQuote);
            IUniswapV2Pair(pair).mint(v.locker);

            // The remaining token is exact swap input. Taking precisely the old reserve out
            // leaves the intended opening balances; the seed formula makes the K check hold.
            IERC20(token).safeTransfer(pair, lpToken - seed);
            if (tokenIsZero) {
                IUniswapV2Pair(pair).swap(0, syncedQuote, SAFE_SINK, "");
            } else {
                IUniswapV2Pair(pair).swap(syncedQuote, 0, SAFE_SINK, "");
            }
        }

        (tokenReserve, syncedQuote,) = _orderedReserves(pair, token);
        if (tokenReserve != lpToken || syncedQuote != lpQuote) revert OpeningReservesWrong();

        // Names the taxed pool and, in the same call, excludes it from dividends — the pool
        // holds the whole DEX reserve and would otherwise accrue a share nobody can ever claim
        IIgnixToken(token).setPair(pair);
        IV2Locker(v.locker).lock(pair);
    }
}
