// SPDX-License-Identifier: MIT
// Copied from contracts/probes/src/CurveQuote.sol (our own fork probes, MIT) on 2026-10-05; only the line
// wrapping differs. It is the
// library the probes proved exact against the live IgnixManager and the live Uniswap V2 router on an X Layer
// fork at block 72,369,000 (contracts/probes/FINDINGS.md sections 4 and 7). Here it is a test oracle only:
// test/fuzz/TradeMath.t.sol checks that src/lib/TradeMath.sol computes the same numbers.
pragma solidity ^0.8.22;

/// @title CurveQuote: exact on-chain quote of an IGNIX bonding-curve buy
/// @notice Bit-for-bit mirror of `CurveTrading.buy` + `CurveMath` in the verified IgnixManager implementation
///         0x126f5088cf077944933f5741fb71a6cc40f2942a. Proven exact against live `buy` / `buyTo` on an X Layer
///         fork by test/Q4_CurveQuote.t.sol (fuzzed amounts, anti-snipe window, the curve-crossing buy) and
///         against a real mainnet trade by test/Q10_Replay.t.sol.
///
///         Inputs come from `IgnixManager.tokens(token)` and `IgnixManager.snipeBpsNow(token)` only.
///         Everything is pure and cannot revert for any state the Manager can be in (see the notes on each
///         subtraction), so a kernel can call it outside try/catch. Precondition, guaranteed by
///         LaunchLogic.validate for real inputs: buyFeeBps + taxBuyBps + snipeBps <= 9500 (< 10000).
///         Fields are uint128 / uint16 on-chain, so no product here can overflow uint256.
library CurveQuote {
    uint256 internal constant BPS = 10_000;

    /// @dev The six `tokens(token)` words the buy path reads (words 1, 3, 9, 10, 11, 13).
    struct Curve {
        uint256 buyFeeBps;
        uint256 taxBuyBps;
        uint256 vQuote;
        uint256 vToken;
        uint256 sold;
        uint256 sellable;
    }

    struct BuyQuote {
        uint256 tokensOut; // tokens transferred to the buy recipient; 0 means the Manager reverts SoldOut()
        uint256 quoteSpent; // gross quote consumed = amountIn - refund
        uint256 refund; // overbuy refund, paid to the buy RECIPIENT (not msg.sender) in the same tx
        uint256 net; // added to vQuote and to `collected`
        uint256 tax; // pushed to vaultOf(token) in quote, in the same tx
        uint256 platformFee; // accrued to platformAccrued[quote] (curve fee + all anti-snipe + dust)
        bool soldOut; // true: this buy sells the curve out and graduation runs inside the same tx
    }

    /// @notice What `manager.buy{,To}(token, quoteIn, minOut, ...)` does right now.
    /// @param snipeBps `manager.snipeBpsNow(token)`; pass 0 only for the creator's atomic firstBuy.
    function quoteBuy(Curve memory c, uint256 snipeBps, uint256 quoteIn) internal pure returns (BuyQuote memory q) {
        uint256 feeBps = c.buyFeeBps + c.taxBuyBps + snipeBps;
        // net = ceil(quoteIn * (BPS - feeBps) / BPS)
        uint256 net = quoteIn - (quoteIn * feeBps) / BPS;

        uint256 left = c.sellable - c.sold;
        uint256 out = c.vToken - ceilDiv(c.vQuote * c.vToken, c.vQuote + net);
        if (out >= left) {
            out = left;
            net = ceilDiv(c.vQuote * left, c.vToken - left); // CurveMath.quoteInFor
            uint256 grossNeeded = ceilDiv(net * BPS, BPS - feeBps); // Math.mulDiv(net, BPS, BPS - feeBps, Ceil)
            if (grossNeeded < quoteIn) {
                q.refund = quoteIn - grossNeeded;
                quoteIn = grossNeeded;
            }
        }

        q.tokensOut = out;
        q.quoteSpent = quoteIn;
        q.net = net;
        q.tax = (quoteIn * c.taxBuyBps) / BPS;
        q.platformFee = quoteIn - net - q.tax;
        q.soldOut = (c.sold + out == c.sellable);
    }

    /// @notice Tokens a buy of `quoteIn` delivers (0 if the Manager would revert SoldOut()).
    function tokensOut(Curve memory c, uint256 snipeBps, uint256 quoteIn) internal pure returns (uint256) {
        return quoteBuy(c, snipeBps, quoteIn).tokensOut;
    }

    /// @notice The largest gross `quoteIn` whose buy does NOT sell the curve out (does not graduate).
    /// @dev    Exact: buying `maxIn` leaves at least 1 wei of token on the curve; buying `maxIn + 1`
    ///         graduates. Returns 0 when the curve is already sold out or when even the smallest
    ///         meaningful buy would finish it.
    ///
    ///         Derivation. Let left = sellable - sold, R = vToken - left, K = vQuote * vToken.
    ///         tokensOut(net) < left  <=>  ceil(K / (vQuote + net)) > R  <=>  (vQuote + net) * R < K
    ///                                <=>  net <= ceil(K / R) - 1 - vQuote            =: netMax
    ///         and net(q) = q - floor(q * fee / BPS) = ceil(q * (BPS - fee) / BPS), so
    ///         net(q) <= netMax       <=>  q <= floor(netMax * BPS / (BPS - fee)).
    function maxNonGraduatingBuy(Curve memory c, uint256 snipeBps) internal pure returns (uint256 maxIn) {
        uint256 left = c.sellable - c.sold;
        if (left == 0) return 0;
        uint256 feeBps = c.buyFeeBps + c.taxBuyBps + snipeBps;
        uint256 r = c.vToken - left; // > 0: vToken starts at C^2/(C-D) > C and falls only by tokens sold
        uint256 netMax = ceilDiv(c.vQuote * c.vToken, r) - 1 - c.vQuote; // ceil(K/R) >= vQuote + 1 since left > 0
        maxIn = (netMax * BPS) / (BPS - feeBps);
    }

    /// @notice Gross quote that buys the whole remaining curve (the graduating buy's true cost).
    function costToGraduate(Curve memory c, uint256 snipeBps) internal pure returns (uint256 gross) {
        uint256 left = c.sellable - c.sold;
        if (left == 0) return 0;
        uint256 feeBps = c.buyFeeBps + c.taxBuyBps + snipeBps;
        uint256 net = ceilDiv(c.vQuote * left, c.vToken - left);
        gross = ceilDiv(net * BPS, BPS - feeBps);
    }

    /// @dev OpenZeppelin Math.ceilDiv semantics (0 for a == 0).
    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}

/// @title V2TaxQuote: output of a Uniswap V2 buy of a graduated IGNIX token, net of its transfer tax
/// @notice The pair pays `grossOut` (standard 0.3% V2 math); the token then diverts
///         floor(grossOut * taxBuyBps / 10000) to the vault, so the swap recipient gets `netOut`.
///         Proven exact against the live router on a fork by test/Q7_V2BuyBurn.t.sol (fuzzed).
library V2TaxQuote {
    uint256 internal constant BPS = 10_000;

    /// @param amountIn   WOKB (wei) entering the pair
    /// @param reserveIn  pair reserve of WOKB (non-zero for a graduated pair; 0 with amountIn 0 would divide by 0)
    /// @param reserveOut pair reserve of the project token
    function buyOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint256 taxBuyBps)
        internal
        pure
        returns (uint256 grossOut, uint256 tax, uint256 netOut)
    {
        uint256 amountInWithFee = amountIn * 997;
        grossOut = (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
        tax = (grossOut * taxBuyBps) / BPS;
        netOut = grossOut - tax;
    }
}
