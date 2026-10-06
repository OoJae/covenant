// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title TradeMath
/// @notice The arithmetic of the kernel's two buy legs: the exact quote of an IGNIX bonding-curve buy, the
///         largest buy that does not graduate the curve, the output of a Uniswap V2 buy of a taxed IGNIX
///         token, the impact cap that makes a single-transaction sandwich of a kernel buy unprofitable, and
///         the size of the curve buy that follows from them.
/// @dev    The curve formulas mirror `CurveTrading.buy` and `CurveMath` in IGNIX's verified MIT implementation
///         0x126f5088cf077944933f5741fb71a6cc40f2942a (contracts/vendor/ignix-xlayer). Pure. Every function
///         is total on the ranges the kernel validates before calling (128-bit reserves, fees below 10,000 bps).
library TradeMath {
    uint256 internal constant BPS = 10_000;

    /// The words of `IgnixManager.tokens(token)` the kernel reads (words 1, 2, 3, 4, 9, 10, 11, 13).
    struct Curve {
        uint256 buyFeeBps;
        uint256 sellFeeBps;
        uint256 taxBuyBps;
        uint256 taxSellBps;
        uint256 vQuote;
        uint256 vToken;
        uint256 sold;
        uint256 sellable;
    }

    /// @dev OpenZeppelin Math.ceilDiv semantics (0 for a == 0). `b` must be non-zero.
    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            return a == 0 ? 0 : (a - 1) / b + 1;
        }
    }

    /// @notice True if the curve words are in the ranges the formulas below rely on.
    /// @dev    Upstream stores the reserves as uint128 and the rates as uint16 with fees fixed at 100 bps and
    ///         tax at most 1,000 bps per side. A read outside these ranges is treated as a failed read.
    function sane(Curve memory c) internal pure returns (bool) {
        return c.vQuote != 0 && c.vQuote <= type(uint128).max && c.vToken != 0 && c.vToken <= type(uint128).max
            && c.sold <= type(uint128).max && c.sellable <= type(uint128).max && c.buyFeeBps <= BPS
            && c.sellFeeBps <= BPS && c.taxBuyBps <= BPS && c.taxSellBps <= BPS && c.buyFeeBps + c.taxBuyBps < BPS;
    }

    /// @notice Largest kernel buy, in quote, for a pool whose quote-side reserve is `quoteReserve`:
    ///
    ///             cap = quoteReserve * (roundTripFee + (taxBuy + taxSell) * (256 - capT) / 256) / 4 / 10000
    ///
    /// @dev    A sandwicher with position x gains about 2 * x * b / reserve from a kernel buy b and pays
    ///         x * (round-trip costs). Only costs the attacker cannot get back count. The tax flows to the
    ///         kernel, and at most capT / 256 of it can come back out as allowance (to the allowance payee, who
    ///         may be the attacker), so the tax counts at (256 - capT) / 256. `roundTripFeeBps` must likewise
    ///         be the part of the venue's buy + sell fee that no trader can recover. With b at a quarter of
    ///         the net round-trip cost times the reserve, the attack loses at least half of what it pays.
    ///         The bound holds for one transaction; multi-epoch releases are public and are not covered.
    ///         Evaluated with a single division (rounds down, never above the formula's real value).
    function impactCap(
        uint256 quoteReserve,
        uint256 roundTripFeeBps,
        uint256 taxBuyBps,
        uint256 taxSellBps,
        uint256 capT
    ) internal pure returns (uint256) {
        uint256 keep = capT >= 256 ? 0 : 256 - capT;
        // quoteReserve < 2^128 and the bracket is below 2^24: no overflow
        return (quoteReserve * (roundTripFeeBps * 256 + (taxBuyBps + taxSellBps) * keep)) / (256 * 4 * BPS);
    }

    /// @notice Net quote added to the curve by a gross buy of `quoteIn` when no anti-snipe surcharge applies.
    function netOf(Curve memory c, uint256 quoteIn) internal pure returns (uint256) {
        return quoteIn - (quoteIn * (c.buyFeeBps + c.taxBuyBps)) / BPS;
    }

    /// @notice Tokens a gross buy of `quoteIn` delivers when it does not cross the remaining curve supply and
    ///         no anti-snipe surcharge applies: vToken - ceil(vQuote * vToken / (vQuote + net)).
    function curveOut(Curve memory c, uint256 quoteIn) internal pure returns (uint256) {
        uint256 net = netOf(c, quoteIn);
        return c.vToken - ceilDiv(c.vQuote * c.vToken, c.vQuote + net);
    }

    /// @notice The largest gross `quoteIn` whose buy leaves at least 1 wei of token on the curve, i.e. does
    ///         not sell the curve out and does not graduate the token. 0 if there is no such buy.
    /// @dev    Let left = sellable - sold, R = vToken - left, K = vQuote * vToken.
    ///           out(net) < left  <=>  ceil(K / (vQuote + net)) > R  <=>  (vQuote + net) * R < K
    ///                            <=>  net <= ceil(K / R) - 1 - vQuote  =: netMax
    ///         and net(q) = q - floor(q * fee / BPS) = ceil(q * (BPS - fee) / BPS), so
    ///           net(q) <= netMax  <=>  q <= floor(netMax * BPS / (BPS - fee)).
    function maxNonGraduatingBuy(Curve memory c) internal pure returns (uint256) {
        if (c.sold >= c.sellable) return 0;
        uint256 left = c.sellable - c.sold;
        if (c.vToken <= left) return 0; // not a state the Manager can be in
        uint256 r = c.vToken - left;
        uint256 top = ceilDiv(c.vQuote * c.vToken, r);
        if (top <= c.vQuote + 1) return 0;
        uint256 netMax = top - 1 - c.vQuote;
        return (netMax * BPS) / (BPS - (c.buyFeeBps + c.taxBuyBps));
    }

    /// @notice Size of the kernel's curve buy (INTERFACE section 9.1, kernel_model.curve_buy):
    ///         amount = min(decided, impactCap, maxNonGraduatingBuy), with the exact quote as minimum output.
    /// @param  decided what routing decided to buy, in quote
    /// @param  capT    the envelope's maximum allowance share (it weights the tax in the impact cap)
    /// @return amount  gross quote to send; 0 when the buy must be skipped
    /// @return out     tokens the Manager delivers for `amount`, to be passed as minTokensOut; 0 when the buy
    ///                 must be skipped (an amount that buys zero tokens is never sent: the Manager reverts SoldOut)
    /// @return shrunk  a cap was below `decided`
    function curveBuy(Curve memory c, uint256 decided, uint256 capT)
        internal
        pure
        returns (uint256 amount, uint256 out, bool shrunk)
    {
        // cap 1: a sandwich of this buy must lose money, net of the allowance rebate
        uint256 cap = impactCap(c.vQuote, c.buyFeeBps + c.sellFeeBps, c.taxBuyBps, c.taxSellBps, capT);
        // cap 2: never sell the curve out (that buy would graduate the token inside the call)
        uint256 room = maxNonGraduatingBuy(c);
        if (room < cap) cap = room;
        amount = decided;
        if (amount > cap) {
            amount = cap;
            shrunk = true;
        }
        if (amount != 0) out = curveOut(c, amount);
        if (out == 0) amount = 0;
    }

    /// @notice Tokens the RECIPIENT of a Uniswap V2 buy of a taxed IGNIX token receives for `amountIn` of the
    ///         quote: standard 0.3% V2 output, less floor(out * taxBuyBps / 10000) diverted to the vault.
    function v2NetOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint256 taxBuyBps)
        internal
        pure
        returns (uint256)
    {
        if (amountIn == 0 || reserveIn == 0 || reserveOut == 0) return 0;
        uint256 inWithFee = amountIn * 997; // amountIn < 2^128
        uint256 grossOut = (inWithFee * reserveOut) / (reserveIn * 1000 + inWithFee); // reserves < 2^112
        if (taxBuyBps > BPS) taxBuyBps = BPS;
        return grossOut - (grossOut * taxBuyBps) / BPS;
    }
}
