// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Curve parameter derivation
/// @notice The graduation threshold is the only input; everything else is derived. Full derivation in
///         docs/20 (curve parameter derivation spec)
///
/// Two constraints fix everything:
///   ① selling out == graduating   G = E·C/(T−C)
///   ② price continuity at graduation   G/D = E·T/(T−C)²   ← the LP opening price must equal
///      the curve's terminal price
/// Eliminating E gives T = C²/(C−D), and ① then solves for E.
library CurveMath {
    uint256 internal constant BPS = 10_000;

    /// Total supply: 1 billion tokens (18 decimals)
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000e18;
    /// Curve sale : DEX reserve = 4, so the graduation multiple = RATIO² = 16x.
    ///
    /// **The split and the multiple are one choice, not two.** Price continuity at graduation
    /// forces `multiple = (C/D)²` (see the two constraints above), so pinning one pins the
    /// other. A ratio of 4 gives the round 80% / 20% split; the earlier 38_730
    /// (= √15) gave a 15x multiple and an unavoidably irrational 79.48% / 20.52%.
    /// Product picked the round split, 2026-08-16 — see docs/47.
    uint256 internal constant RATIO_BPS = 40_000;
    /// @dev Lower bound on the virtual quote reserve. Chosen by measuring, not by feel:
    ///      every production and dev threshold clears it by orders of magnitude
    ///      (the smallest, dev USD₮0 at 10 USD, lands at 3.48e6), while both audit PoC
    ///      cases (E = 29 and E = 0) fall far below.
    uint256 internal constant MIN_VIRTUAL_QUOTE = 1e6;

    error BadGraduation();

    /// @param graduation Graduation threshold, denominated in the **quote's smallest unit**.
    ///        It cannot be a constant — OKB has 18 decimals and USD₮0 has 6, so a hardcoded
    ///        85e18 becomes 85 trillion under USD₮0.
    ///        Note that graduation is judged by "the curve sold out", not by "the raise hit a
    ///        target", so the threshold only shapes the initial E and need not be stored: the
    ///        curve state's vQuote already encodes it.
    /// @return C curve sale supply
    /// @return D DEX reserve
    /// @return T virtual token reserve
    /// @return E virtual quote reserve
    function params(uint256 graduation)
        internal
        pure
        returns (uint256 C, uint256 D, uint256 T, uint256 E)
    {
        if (graduation == 0) revert BadGraduation();

        uint256 cBps = (BPS * RATIO_BPS) / (RATIO_BPS + BPS);
        // Must be a subtraction: rounding both sides independently makes C+D < BPS, losing
        // supply out of thin air. With RATIO_BPS = 40_000 this is a fixed 8_000 / 2_000
        // (80% / 20%) split, computed rather than hardcoded so RATIO_BPS stays the only knob.
        uint256 dBps = BPS - cBps;

        C = (TOTAL_SUPPLY * cBps) / BPS;
        D = (TOTAL_SUPPLY * dBps) / BPS;
        // C is at most ~8e26, so C² is ~6.4e53, far below the uint256 ceiling of 1.16e77
        T = (C * C) / (C - D);
        E = (graduation * (T - C)) / C;
        // **A floor, not just "non-zero".** (T−C)/C is about 0.3483, so a graduation of 2
        // yields E = 0 and the whole curve collapses: with the virtual quote reserve at
        // dust level, a handful of wei buys nearly the entire supply. Measured: a
        // six-decimal quote whose threshold was passed as whole dollars (85 instead of
        // 85e6) gives E = 29 — one millionth of the intended reserve — and 81 wei then
        // takes 99.3% of the curve (audit H-2, docs/31).
        //
        // The threshold itself comes from the server's `resolveQuote()` and cannot be
        // supplied by a caller, so this guards **platform misconfiguration**, not an
        // external attack. It cannot catch a decimals-level mistake either (85e8 instead
        // of 85e18 still clears this bar) — that layer is the quote whitelist's job.
        if (E < MIN_VIRTUAL_QUOTE) revert BadGraduation();
    }

    /// @notice Constant product: how many tokens `quoteIn` buys
    /// @dev **The new reserve must round up.** Rounding down makes the new reserve too small →
    ///      too many tokens paid out to the user → K shrinks, so every trade leaks a little
    ///      from the curve and the total is a real loss of funds. The rounding remainder stays
    ///      in the curve, guaranteeing K' ≥ K — this is the constant-product safety floor, not
    ///      a precision preference.
    function tokensOut(uint256 vQuote, uint256 vToken, uint256 quoteIn)
        internal
        pure
        returns (uint256)
    {
        return vToken - Math.ceilDiv(vQuote * vToken, vQuote + quoteIn);
    }

    /// @notice Constant product: how much quote selling `tokenIn` returns
    /// @dev Rounds up as well — the new quote reserve is slightly larger, the user is paid
    ///      slightly less, and K does not shrink
    function quoteOut(uint256 vQuote, uint256 vToken, uint256 tokenIn)
        internal
        pure
        returns (uint256)
    {
        return vQuote - Math.ceilDiv(vQuote * vToken, vToken + tokenIn);
    }

    /// @notice Inverse of tokensOut: the minimum quote needed to buy `tokenOut` tokens
    /// @dev Used only for the "final overshooting buy" — 100 tokens left on the curve and
    ///      someone sends in 1000 OKB. Without a cap the whole 1000 would count towards the
    ///      raise: the buyer takes a heavy loss and the LP opening price is blown off target.
    ///      Rounds up; collecting even one wei less would shrink K.
    function quoteInFor(uint256 vQuote, uint256 vToken, uint256 tokenOut)
        internal
        pure
        returns (uint256)
    {
        return Math.ceilDiv(vQuote * tokenOut, vToken - tokenOut);
    }
}
