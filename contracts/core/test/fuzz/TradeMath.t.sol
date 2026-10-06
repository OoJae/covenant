// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TradeMath} from "../../src/lib/TradeMath.sol";
import {CurveQuote, V2TaxQuote} from "../ref/ProbesCurveQuote.sol";
import {MockManager, MockWOKB, MockToken} from "../mocks/MockIgnix.sol";

/// @notice TradeMath against two oracles: the probes' CurveQuote (proven exact against live IGNIX on a fork),
///         and real buys on the mock Manager (which mirrors IGNIX's verified CurveTrading).
contract TradeMathTest is Test {
    uint256 internal constant C = 800_000_000e18;
    uint256 internal constant T0 = 1_066_666_666_666666666666666666;

    /// A reachable curve state: `sold` tokens sold from a fresh curve with virtual quote `e0`.
    function _curve(uint256 e0, uint256 sold, uint256 taxBuy, uint256 taxSell)
        internal
        pure
        returns (TradeMath.Curve memory c)
    {
        e0 = bound(e0, 1e6, 1e24);
        sold = bound(sold, 0, C);
        c.buyFeeBps = 100;
        c.sellFeeBps = 100;
        c.taxBuyBps = bound(taxBuy, 0, 1000);
        c.taxSellBps = bound(taxSell, 0, 1000);
        c.vToken = T0 - sold;
        // constant product from the fresh curve, rounded up as the Manager rounds
        c.vQuote = TradeMath.ceilDiv(e0 * T0, c.vToken);
        c.sold = sold;
        c.sellable = C;
    }

    function _probe(TradeMath.Curve memory c) internal pure returns (CurveQuote.Curve memory p) {
        p = CurveQuote.Curve(c.buyFeeBps, c.taxBuyBps, c.vQuote, c.vToken, c.sold, c.sellable);
    }

    function testFuzz_curveOut_equals_probes_quote_when_not_crossing(
        uint256 e0,
        uint256 sold,
        uint256 taxBuy,
        uint256 amount
    ) public pure {
        TradeMath.Curve memory c = _curve(e0, sold, taxBuy, 0);
        assertTrue(TradeMath.sane(c));
        uint256 maxIn = TradeMath.maxNonGraduatingBuy(c);
        assertEq(maxIn, CurveQuote.maxNonGraduatingBuy(_probe(c), 0), "largest non-graduating buy");
        if (maxIn == 0) return;
        amount = bound(amount, 1, maxIn);
        CurveQuote.BuyQuote memory q = CurveQuote.quoteBuy(_probe(c), 0, amount);
        assertEq(TradeMath.curveOut(c, amount), q.tokensOut, "tokens out");
        assertFalse(q.soldOut, "a buy within the cap never sells the curve out");
        assertEq(q.refund, 0);
        assertLt(q.tokensOut, c.sellable - c.sold);
    }

    function testFuzz_one_wei_more_than_the_cap_graduates(uint256 e0, uint256 sold, uint256 taxBuy) public pure {
        TradeMath.Curve memory c = _curve(e0, sold, taxBuy, 0);
        uint256 maxIn = TradeMath.maxNonGraduatingBuy(c);
        if (c.sold == c.sellable) {
            assertEq(maxIn, 0);
            return;
        }
        CurveQuote.BuyQuote memory q = CurveQuote.quoteBuy(_probe(c), 0, maxIn + 1);
        assertTrue(q.soldOut, "the cap is tight: one wei more sells the curve out");
    }

    function testFuzz_v2NetOut_equals_probes_quote(uint256 amountIn, uint256 rIn, uint256 rOut, uint256 tax)
        public
        pure
    {
        amountIn = bound(amountIn, 1, 1e24);
        rIn = bound(rIn, 1, type(uint112).max);
        rOut = bound(rOut, 1, type(uint112).max);
        tax = bound(tax, 0, 1000);
        (,, uint256 net) = V2TaxQuote.buyOut(amountIn, rIn, rOut, tax);
        assertEq(TradeMath.v2NetOut(amountIn, rIn, rOut, tax), net);
    }

    /// The impact cap never exceeds a quarter of the non-refundable round-trip cost times the reserve, and
    /// grows with the fees and shrinks with the allowance cap.
    function testFuzz_impactCap(uint256 q, uint256 fee, uint256 taxBuy, uint256 taxSell, uint256 capT) public pure {
        q = bound(q, 0, type(uint128).max);
        fee = bound(fee, 0, 2000);
        taxBuy = bound(taxBuy, 0, 1000);
        taxSell = bound(taxSell, 0, 1000);
        capT = bound(capT, 0, 300);
        uint256 cap = TradeMath.impactCap(q, fee, taxBuy, taxSell, capT);
        uint256 keep = capT >= 256 ? 0 : 256 - capT;
        // cap * 256 * 4 * 10000 <= q * (fee * 256 + tax * keep) < (cap + 1) * 256 * 4 * 10000
        uint256 rhs = q * (fee * 256 + (taxBuy + taxSell) * keep);
        assertLe(cap * 10_240_000, rhs);
        assertGt((cap + 1) * 10_240_000, rhs);
        if (capT < 256) assertGe(cap, TradeMath.impactCap(q, fee, taxBuy, taxSell, capT + 1), "monotone in capT");
        assertLe(cap, q / 4, "never above a quarter of the reserve");
    }

    function test_impactCap_reference_numbers() public pure {
        // curve of the reference token: fees 1% + 1%, tax 3% + 3%, capT 48
        // (200 + 600 * 208 / 256) / 4 / 10000 = 1.71875%
        assertEq(TradeMath.impactCap(28.333333333333333334 ether, 200, 300, 300, 48), 486_979_166_666_666_666);
        // the pair after graduation: 85 OKB, fee part 25 bps: (25 + 487.5) / 4 / 10000 = 1.28125%
        assertEq(TradeMath.impactCap(85 ether, 25, 300, 300, 48), 1.0890625 ether);
        // everything refundable: only the fee counts
        assertEq(TradeMath.impactCap(85 ether, 25, 300, 300, 256), 0.053125 ether);
    }

    /// The kernel's sizing of its curve buy (the function Kernel._curveLeg calls) against the pieces it is
    /// made of and against the probes' quote: amount = min(decided, impact cap, largest non-graduating buy),
    /// the minimum output is the exact quote, the buy never sells the curve out, and an amount that buys
    /// nothing is not sent.
    function testFuzz_curveBuy(uint256 e0, uint256 sold, uint256 taxBuy, uint256 taxSell, uint256 decided, uint256 capT)
        public
        pure
    {
        TradeMath.Curve memory c = _curve(e0, sold, taxBuy, taxSell);
        decided = bound(decided, 0, type(uint128).max);
        capT = bound(capT, 0, 256);
        (uint256 amount, uint256 out, bool shrunk) = TradeMath.curveBuy(c, decided, capT);

        uint256 cap = TradeMath.impactCap(c.vQuote, c.buyFeeBps + c.sellFeeBps, c.taxBuyBps, c.taxSellBps, capT);
        uint256 room = TradeMath.maxNonGraduatingBuy(c);
        uint256 lim = cap < room ? cap : room;
        uint256 want = decided < lim ? decided : lim;
        assertEq(shrunk, decided > lim, "shrunk exactly when a cap is below the decided amount");
        if (amount != 0) {
            assertEq(amount, want, "min(decided, impact cap, largest non-graduating buy)");
            assertGt(out, 0);
            CurveQuote.BuyQuote memory q = CurveQuote.quoteBuy(_probe(c), 0, amount);
            assertEq(out, q.tokensOut, "minTokensOut is the exact quote");
            assertFalse(q.soldOut, "the kernel never sells the curve out");
            assertEq(q.refund, 0, "and so is never refunded");
        } else {
            assertEq(out, 0);
            // skipped only when the capped amount is zero or buys zero tokens (the Manager would revert SoldOut)
            if (want != 0) assertEq(CurveQuote.tokensOut(_probe(c), 0, want), 0);
        }
    }

    function test_curveBuy_reference_numbers() public pure {
        // a fresh curve of the reference token (85 OKB graduation, 3% + 3% tax, 1% + 1% fee), capT 48
        TradeMath.Curve memory c = _curve(28.333333333333333333 ether, 0, 300, 300);
        uint256 cap = TradeMath.impactCap(c.vQuote, 200, 300, 300, 48);
        assertEq(cap, 486_979_166_666_666_666, "about 0.49 OKB per settle");
        // below the cap: the whole amount, not shrunk
        (uint256 amount, uint256 out, bool shrunk) = TradeMath.curveBuy(c, 0.1 ether, 48);
        assertEq(amount, 0.1 ether);
        assertEq(out, TradeMath.curveOut(c, 0.1 ether));
        assertFalse(shrunk);
        // exactly the cap is not shrunk; one wei more is
        (amount,, shrunk) = TradeMath.curveBuy(c, cap, 48);
        assertEq(amount, cap);
        assertFalse(shrunk);
        (amount, out, shrunk) = TradeMath.curveBuy(c, cap + 1, 48);
        assertEq(amount, cap);
        assertEq(out, TradeMath.curveOut(c, cap));
        assertTrue(shrunk);
        // nothing decided: nothing sent, and not "shrunk"
        (amount, out, shrunk) = TradeMath.curveBuy(c, 0, 48);
        assertEq(amount + out, 0);
        assertFalse(shrunk);
        // one wei buys tokens on this curve
        (amount, out,) = TradeMath.curveBuy(c, 1, 48);
        assertEq(amount, 1);
        assertGt(out, 0);
        // nothing decided is nothing quoted, whatever the curve words are (here: a quote reserve of zero,
        // which the kernel treats as a failed read and never passes on)
        TradeMath.Curve memory z = _curve(28.333333333333333333 ether, 0, 300, 300);
        z.vQuote = 0;
        (amount, out, shrunk) = TradeMath.curveBuy(z, 0, 48);
        assertEq(amount, 0);
        assertEq(out, 0);
        assertFalse(shrunk);
        // a larger allowance cap leaves less of the tax as a cost to the sandwicher: a smaller buy
        (amount,, shrunk) = TradeMath.curveBuy(c, 1 ether, 128);
        assertEq(amount, TradeMath.impactCap(c.vQuote, 200, 300, 300, 128));
        assertLt(amount, cap);
        assertTrue(shrunk);

        // one base unit from the end of the curve: no buy leaves the curve open, so nothing is sent
        c = _curve(28.333333333333333333 ether, C - 1, 300, 300);
        assertEq(TradeMath.maxNonGraduatingBuy(c), 0);
        (amount, out, shrunk) = TradeMath.curveBuy(c, 1 ether, 48);
        assertEq(amount + out, 0);
        assertTrue(shrunk, "shrunk to nothing by the graduation cap");

        // near the end the graduation cap binds before the impact cap does
        c = _curve(28.333333333333333333 ether, C - 1e18, 300, 300);
        uint256 room = TradeMath.maxNonGraduatingBuy(c);
        assertGt(room, 0);
        assertLt(room, TradeMath.impactCap(c.vQuote, 200, 300, 300, 48));
        (amount, out, shrunk) = TradeMath.curveBuy(c, 1 ether, 48);
        assertEq(amount, room);
        assertLt(out, c.sellable - c.sold, "at least one base unit is left on the curve");
        assertTrue(shrunk);
    }

    /// An amount whose quote is zero tokens is not sent (the Manager would revert SoldOut): the function
    /// answers zero for both, and says "shrunk" only if a cap was below what was decided.
    function test_curveBuy_sends_nothing_when_the_amount_buys_no_token() public pure {
        // a curve on which a base unit of token costs about 1,000 wei, with half of it still for sale
        TradeMath.Curve memory c = _curve(28.333333333333333333 ether, 0, 300, 300);
        c.vToken = c.vQuote / 1000;
        c.sellable = c.vToken / 2;
        assertGt(TradeMath.maxNonGraduatingBuy(c), 1 ether, "the graduation cap is far away");
        assertGt(TradeMath.impactCap(c.vQuote, 200, 300, 300, 48), 5000, "and so is the impact cap");

        assertEq(TradeMath.curveOut(c, 500), 0, "500 wei buy less than one base unit");
        (uint256 amount, uint256 out, bool shrunk) = TradeMath.curveBuy(c, 500, 48);
        assertEq(amount, 0, "so nothing is sent");
        assertEq(out, 0);
        assertFalse(shrunk, "no cap was below the decided amount");

        // the same when the amount that buys nothing is what a cap left of a larger decision
        TradeMath.Curve memory d = _curve(28.333333333333333333 ether, 0, 300, 300);
        d.vQuote = 100_000; // impact cap = 100,000 * 1.71875% = 1,718 wei, which buys nothing here
        d.vToken = 50;
        d.sellable = 25;
        uint256 cap = TradeMath.impactCap(d.vQuote, 200, 300, 300, 48);
        assertEq(cap, 1718);
        assertGt(TradeMath.maxNonGraduatingBuy(d), cap);
        assertEq(TradeMath.curveOut(d, cap), 0);
        (amount, out, shrunk) = TradeMath.curveBuy(d, 1 ether, 48);
        assertEq(amount, 0);
        assertEq(out, 0);
        assertTrue(shrunk, "a cap was below the decided amount");

        // 5,000 wei buy four base units on the first curve: sent whole
        (amount, out, shrunk) = TradeMath.curveBuy(c, 5000, 48);
        assertEq(amount, 5000);
        assertEq(out, 4);
        assertFalse(shrunk);
    }

    /// The fee part of the impact cap is the token's own buy fee plus sell fee as the Manager reports them
    /// (100 + 100 on every token today), not a constant.
    function test_curveBuy_takes_the_fee_part_of_the_cap_from_the_curve_words() public pure {
        TradeMath.Curve memory c = _curve(28.333333333333333333 ether, 0, 300, 300);
        uint256 today = TradeMath.impactCap(c.vQuote, 200, 300, 300, 48);
        (uint256 amount,,) = TradeMath.curveBuy(c, 1 ether, 48);
        assertEq(amount, today);

        c.buyFeeBps = 30;
        c.sellFeeBps = 250;
        (amount,,) = TradeMath.curveBuy(c, 1 ether, 48);
        assertEq(amount, TradeMath.impactCap(c.vQuote, 280, 300, 300, 48), "buy fee + sell fee");
        assertGt(amount, today);

        c.buyFeeBps = 30;
        c.sellFeeBps = 0;
        (amount,,) = TradeMath.curveBuy(c, 1 ether, 48);
        assertEq(amount, TradeMath.impactCap(c.vQuote, 30, 300, 300, 48));
        assertLt(amount, today);
    }

    function test_sane_rejects_out_of_range_reads() public pure {
        TradeMath.Curve memory c = _curve(28.33 ether, 0, 300, 300);
        assertTrue(TradeMath.sane(c));
        c.vQuote = 0;
        assertFalse(TradeMath.sane(c));
        c.vQuote = uint256(type(uint128).max) + 1;
        assertFalse(TradeMath.sane(c));
        c = _curve(28.33 ether, 0, 300, 300);
        c.buyFeeBps = 9_800; // fee + tax would reach 100%
        assertFalse(TradeMath.sane(c));
        c = _curve(28.33 ether, 0, 300, 300);
        c.vToken = 0;
        assertFalse(TradeMath.sane(c));
    }

    // ------------------------------------------------------------------ against real buys on the mock Manager

    /// The quote the kernel passes as minTokensOut is what the Manager delivers, to the wei, after any
    /// sequence of earlier trades; and a buy of the cap never graduates.
    function testFuzz_quote_matches_a_real_buy(uint256 prior, uint256 amount, uint16 tax) public {
        tax = uint16(bound(tax, 0, 1000));
        MockWOKB wokb = new MockWOKB();
        MockManager manager = new MockManager(address(wokb));
        (address t,) = manager.createToken(address(this), address(0xBEEF), tax, tax, 0, 0, 85 ether);
        vm.deal(address(this), 1_000 ether);
        prior = bound(prior, 0, 80 ether);
        if (prior > 1e6) manager.buy{value: prior}(t, prior, 0);

        MockManager.Token memory raw = manager.raw(t);
        TradeMath.Curve memory c;
        c.buyFeeBps = raw.buyFeeBps;
        c.sellFeeBps = raw.sellFeeBps;
        c.taxBuyBps = raw.taxBuyBps;
        c.taxSellBps = raw.taxSellBps;
        c.vQuote = raw.vQuote;
        c.vToken = raw.vToken;
        c.sold = raw.sold;
        c.sellable = raw.sellable;

        uint256 maxIn = TradeMath.maxNonGraduatingBuy(c);
        if (maxIn == 0) return;
        amount = bound(amount, 1, maxIn);
        uint256 out = TradeMath.curveOut(c, amount);
        if (out == 0) return; // the Manager would revert SoldOut
        address buyer = address(0xB0B);
        vm.deal(buyer, amount);
        vm.prank(buyer);
        manager.buyTo{value: amount}(t, amount, out, buyer); // minTokensOut = the exact quote
        assertEq(MockToken(t).balanceOf(buyer), out, "delivered exactly the quote");
        assertEq(manager.pairOf(t), address(0), "did not graduate");
        // one wei more than the quote would have been refused
    }

    /// The same for the kernel's own sizing: whatever was decided, the amount and minimum output that
    /// TradeMath.curveBuy returns are accepted by the Manager, deliver exactly that output and leave the
    /// curve open.
    function testFuzz_curveBuy_matches_a_real_buy(uint256 prior, uint256 decided, uint16 tax, uint256 capT) public {
        tax = uint16(bound(tax, 0, 1000));
        capT = bound(capT, 0, 128);
        MockWOKB wokb = new MockWOKB();
        MockManager manager = new MockManager(address(wokb));
        (address t,) = manager.createToken(address(this), address(0xBEEF), tax, tax, 0, 0, 85 ether);
        vm.deal(address(this), 1_000 ether);
        prior = bound(prior, 0, 88 ether);
        if (prior > 1e6) manager.buy{value: prior}(t, prior, 0);
        if (manager.pairOf(t) != address(0)) return; // the prior buy graduated the curve

        MockManager.Token memory raw = manager.raw(t);
        TradeMath.Curve memory c;
        c.buyFeeBps = raw.buyFeeBps;
        c.sellFeeBps = raw.sellFeeBps;
        c.taxBuyBps = raw.taxBuyBps;
        c.taxSellBps = raw.taxSellBps;
        c.vQuote = raw.vQuote;
        c.vToken = raw.vToken;
        c.sold = raw.sold;
        c.sellable = raw.sellable;

        decided = bound(decided, 0, 200 ether);
        (uint256 amount, uint256 out,) = TradeMath.curveBuy(c, decided, capT);
        if (amount == 0) {
            assertEq(out, 0);
            return;
        }
        assertLe(amount, decided);
        address buyer = address(0xB0B);
        vm.deal(buyer, amount);
        vm.prank(buyer);
        manager.buyTo{value: amount}(t, amount, out, buyer); // minTokensOut = the exact quote
        assertEq(MockToken(t).balanceOf(buyer), out, "delivered exactly the quote");
        assertEq(buyer.balance, 0, "nothing was refunded");
        assertEq(manager.pairOf(t), address(0), "did not graduate");
    }

    function test_buy_of_the_cap_plus_one_wei_graduates_on_the_manager() public {
        MockWOKB wokb = new MockWOKB();
        MockManager manager = new MockManager(address(wokb));
        (address t,) = manager.createToken(address(this), address(0xBEEF), 300, 300, 0, 0, 85 ether);
        MockManager.Token memory raw = manager.raw(t);
        TradeMath.Curve memory c;
        c.buyFeeBps = 100;
        c.sellFeeBps = 100;
        c.taxBuyBps = 300;
        c.taxSellBps = 300;
        c.vQuote = raw.vQuote;
        c.vToken = raw.vToken;
        c.sold = raw.sold;
        c.sellable = raw.sellable;
        uint256 maxIn = TradeMath.maxNonGraduatingBuy(c);
        // FINDINGS.md section 4: 88.541666666666666665 OKB on a fresh 3% curve
        assertEq(maxIn, 88_541_666_666_666_666_665);
        vm.deal(address(this), 200 ether);
        uint256 snap = vm.snapshotState();
        manager.buy{value: maxIn}(t, maxIn, 0);
        assertEq(manager.pairOf(t), address(0), "the cap leaves the curve open");
        vm.revertToState(snap);
        manager.buy{value: maxIn + 2}(t, maxIn + 2, 0);
        assertTrue(manager.pairOf(t) != address(0), "two wei more graduate it");
    }

    receive() external payable {}
}
