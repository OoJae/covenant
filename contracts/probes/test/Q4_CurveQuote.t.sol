// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ProbeBase.sol";

/// @notice Q4. CurveQuote predicts a live curve buy EXACTLY (tokens out, tax, platform fee, refund, and
///         whether the buy graduates), from `tokens(token)` + `snipeBpsNow(token)` only.
contract Q4_CurveQuote is ProbeBase {
    RecipientProbe internal probe;
    IIgnixToken internal token;
    IDirectedVault internal vault;

    function setUp() public {
        _fork();
        probe = new RecipientProbe();
        vm.label(address(probe), "probe (recipient)");
        (token, vault) = _launch(_defaultCfg(address(probe)));
        probe.setMode(RecipientProbe.Mode.Record);
        vm.deal(address(probe), 1_000 ether);
    }

    struct Snap {
        uint256 recipientTokens;
        uint256 recipientNative;
        uint256 payerNative;
        uint256 vaultNative;
        uint256 platform;
    }

    function _snap(address tok, address payer, address recipient) internal view returns (Snap memory s) {
        s.recipientTokens = IIgnixToken(tok).balanceOf(recipient);
        s.recipientNative = recipient.balance;
        s.payerNative = payer.balance;
        s.vaultNative = M.vaultOf(tok).balance;
        s.platform = M.platformAccrued(address(0));
    }

    /// @dev Executes one buy and asserts every number the quote predicted. `recipient == payer` uses buy().
    function _buyAndCheck(address tok, address payer, address recipient, uint256 amt)
        internal
        returns (CurveQuote.BuyQuote memory q)
    {
        CurveQuote.Curve memory c = _curve(tok);
        q = CurveQuote.quoteBuy(c, M.snipeBpsNow(tok), amt);
        Snap memory a = _snap(tok, payer, recipient);

        vm.deal(payer, payer.balance + amt);
        a.payerNative += amt;
        if (recipient == payer) a.recipientNative += amt;

        if (q.tokensOut == 0) {
            vm.prank(payer);
            vm.expectRevert(IIgnixManager.SoldOut.selector);
            M.buy{value: amt}(tok, amt, 0);
            return q;
        }

        vm.prank(payer);
        if (recipient == payer) {
            M.buy{value: amt}(tok, amt, q.tokensOut); // minOut = the quote: must not revert Slippage
        } else {
            M.buyTo{value: amt}(tok, amt, q.tokensOut, recipient);
        }
        Snap memory b = _snap(tok, payer, recipient);

        assertEq(b.recipientTokens - a.recipientTokens, q.tokensOut, "tokens out");
        assertEq(b.vaultNative - a.vaultNative, q.tax, "tax to vault");
        assertEq(b.platform - a.platform, q.platformFee, "platform fee");
        assertEq(q.quoteSpent + q.refund, amt, "spent + refund");
        assertEq(q.net + q.tax + q.platformFee, q.quoteSpent, "fee split");
        if (recipient == payer) {
            assertEq(a.payerNative - b.payerNative, q.quoteSpent, "net native spent");
        } else {
            assertEq(a.payerNative - b.payerNative, amt, "payer pays the full amountIn");
            assertEq(b.recipientNative - a.recipientNative, q.refund, "refund goes to the RECIPIENT");
        }

        CurveToken memory t = _tok(tok);
        assertEq(t.vQuote, c.vQuote + q.net, "vQuote");
        assertEq(t.vToken, c.vToken - q.tokensOut, "vToken");
        assertEq(t.sold, c.sold + q.tokensOut, "sold");
        assertEq(M.pairOf(tok) != address(0), q.soldOut, "graduated <=> quote.soldOut");
        if (q.soldOut) assertEq(t.sold, t.sellable);
    }

    // ───────────────────────── fuzz against the live Manager ─────────────────────────

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_Q4_quote_is_exact_on_live_OB_including_crossing_buys(uint256 seed) public {
        // 1 wei .. 200 OKB; the remaining OB curve costs ~86 OKB, so about half the cases cross it
        uint256 amt = bound(seed, 1, 200 ether);
        _buyAndCheck(OB_TOKEN, alice, alice, amt);
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_Q4_quote_is_exact_on_log_scale_amounts(uint8 exp, uint8 mant, bool viaBuyTo) public {
        uint256 amt = (10 ** bound(exp, 0, 20)) * bound(mant, 1, 9); // 1 wei .. 900 OKB
        _buyAndCheck(address(token), alice, viaBuyTo ? bob : alice, amt);
    }

    /// forge-config: default.fuzz.runs = 48
    function testFuzz_Q4_quote_is_exact_for_contract_buyTo_after_a_random_prior_trade(uint256 s1, uint256 s2)
        public
    {
        _buy(alice, address(token), bound(s1, 1e12, 60 ether)); // move the curve first
        uint256 amt = bound(s2, 1e9, 120 ether);
        CurveQuote.BuyQuote memory q =
            CurveQuote.quoteBuy(_curve(address(token)), M.snipeBpsNow(address(token)), amt);
        uint256 v0 = address(vault).balance;
        (uint256 got, uint256 spent,) = probe.buyTo(M, address(token), amt, q.tokensOut, address(probe));
        assertEq(got, q.tokensOut, "tokens out");
        assertEq(spent, q.quoteSpent, "native spent net of the refund");
        assertEq(address(vault).balance - v0, q.tax, "tax");
        assertEq(M.pairOf(address(token)) != address(0), q.soldOut);
    }

    /// forge-config: default.fuzz.runs = 48
    function testFuzz_Q4_quote_is_exact_inside_the_anti_snipe_window(uint256 s1, uint256 dt) public {
        LaunchCfg memory cfg = _defaultCfg(address(probe));
        cfg.snipeStartBps = 5_000;
        cfg.snipeMins = 30;
        (IIgnixToken t,) = _launch(cfg);
        dt = bound(dt, 0, 40 minutes);
        vm.warp(block.timestamp + dt);
        uint256 snipe = M.snipeBpsNow(address(t));
        if (dt < 30 minutes) assertEq(snipe, (5_000 * (30 minutes - dt)) / 30 minutes);
        else assertEq(snipe, 0);
        CurveQuote.BuyQuote memory q = _buyAndCheck(address(t), alice, bob, bound(s1, 1e9, 150 ether));
        // the anti-snipe surcharge goes to the platform, not to the vault
        assertEq(q.tax, (q.quoteSpent * 300) / 10_000);
    }

    // ───────────────────────── the curve-crossing buy ─────────────────────────

    function test_Q4_crossing_buy_is_capped_refunded_and_graduates_in_the_same_tx() public {
        CurveQuote.Curve memory c = _curve(address(token));
        uint256 cost = CurveQuote.costToGraduate(c, 0);
        uint256 amt = cost + 10 ether;
        CurveQuote.BuyQuote memory q = CurveQuote.quoteBuy(c, 0, amt);
        assertTrue(q.soldOut);
        assertEq(q.tokensOut, c.sellable - c.sold, "capped at the remaining curve supply");
        assertEq(q.refund, 10 ether, "everything above the exact cost comes back");
        console2.log("gross cost to buy the whole fresh curve (wei)", cost);

        uint256 rc0 = probe.receiveCount();
        vm.recordLogs();
        (uint256 got, uint256 spent, uint256 gasUsed) = probe.buyTo(M, address(token), amt, 0, address(probe));
        console2.log("graduating buyTo gas", gasUsed);

        assertEq(got, 800_000_000 ether, "the whole curve");
        assertEq(spent, cost, "net of the refund");
        // the refund arrived as a native call from the MANAGER to the recipient
        assertEq(probe.receiveCount(), rc0 + 1);
        assertEq(probe.lastSender(), address(M));
        // graduated inside this very call
        address pair = M.pairOf(address(token));
        assertTrue(pair != address(0), "pairOf set");
        assertTrue(token.unlocked());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawGraduated;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(M) && logs[i].topics[0] == IIgnixManager.GraduatedV2.selector) {
                sawGraduated = true;
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(pair))));
            }
        }
        assertTrue(sawGraduated, "GraduatedV2 emitted in the buy");
    }

    function test_Q4_crossing_buyTo_refund_goes_to_recipient_not_to_payer() public {
        uint256 cost = CurveQuote.costToGraduate(_curve(address(token)), 0);
        uint256 amt = cost + 7 ether;
        vm.deal(alice, amt);
        uint256 bob0 = bob.balance;
        vm.prank(alice);
        M.buyTo{value: amt}(address(token), amt, 0, bob);
        assertEq(alice.balance, 0, "payer paid the full amountIn and got nothing back");
        assertEq(bob.balance - bob0, 7 ether, "recipient got the refund");
        assertEq(token.balanceOf(bob), 800_000_000 ether);
    }

    function test_Q4_crossing_buyTo_reverts_if_recipient_refuses_the_refund() public {
        uint256 cost = CurveQuote.costToGraduate(_curve(address(token)), 0);
        probe.setMode(RecipientProbe.Mode.Refuse);
        (bool ok, bytes memory err,,) = probe.tryBuyTo(M, address(token), cost + 1 ether, 0, address(probe));
        assertFalse(ok);
        assertEq(_sel(err), bytes4(0x90b8ec18), "QuoteLib.TransferFailed");
        assertEq(M.pairOf(address(token)), address(0), "nothing happened");
        // with the exact cost there is no refund, so the same recipient can graduate
        (ok,,,) = probe.tryBuyTo(M, address(token), cost, 0, address(probe));
        assertTrue(ok);
        assertTrue(M.pairOf(address(token)) != address(0));
    }

    // ───────────────────────── largest buy that does NOT graduate ─────────────────────────

    function test_Q4_maxNonGraduatingBuy_is_exact_on_fresh_curve() public {
        _maxBuyIsExact(address(token));
    }

    function test_Q4_maxNonGraduatingBuy_is_exact_on_live_OB() public {
        _maxBuyIsExact(OB_TOKEN);
    }

    /// forge-config: default.fuzz.runs = 32
    function testFuzz_Q4_maxNonGraduatingBuy_is_exact_after_random_trades(uint256 s1, uint16 dtSecs) public {
        LaunchCfg memory cfg = _defaultCfg(address(probe));
        cfg.snipeStartBps = 9_000;
        cfg.snipeMins = 60;
        (IIgnixToken t,) = _launch(cfg);
        vm.warp(block.timestamp + bound(dtSecs, 0, 4_000));
        _buy(
            alice,
            address(t),
            bound(s1, 1e12, 300 ether)
                % CurveQuote.maxNonGraduatingBuy(_curve(address(t)), M.snipeBpsNow(address(t))) + 1
        );
        _maxBuyIsExact(address(t));
    }

    function test_Q4_with_one_wei_left_the_helper_returns_zero_and_a_one_wei_buy_graduates() public {
        _buy(alice, address(token), CurveQuote.maxNonGraduatingBuy(_curve(address(token)), 0));
        CurveQuote.Curve memory c = _curve(address(token));
        assertEq(c.sellable - c.sold, 1, "exactly one wei of token left on the curve");
        assertEq(CurveQuote.maxNonGraduatingBuy(c, 0), 0, "nothing can be bought without graduating");
        assertEq(CurveQuote.tokensOut(c, 0, 0), 0, "and a zero buy is skipped");
        CurveQuote.BuyQuote memory q = CurveQuote.quoteBuy(c, 0, 1);
        assertTrue(q.soldOut, "even 1 wei of OKB finishes the curve");
        _buyAndCheck(address(token), bob, bob, 1);
        assertTrue(M.pairOf(address(token)) != address(0), "graduated by a 1 wei buy");
    }

    function _maxBuyIsExact(address tok) internal {
        CurveQuote.Curve memory c = _curve(tok);
        uint256 snipe = M.snipeBpsNow(tok);
        uint256 maxIn = CurveQuote.maxNonGraduatingBuy(c, snipe);
        assertGt(maxIn, 0);
        console2.log("largest non-graduating buy (wei)", maxIn);
        console2.log("cost to graduate (wei)        ", CurveQuote.costToGraduate(c, snipe));

        uint256 snap = vm.snapshotState();
        // maxIn + 1 wei graduates
        CurveQuote.BuyQuote memory q1 = _buyAndCheck(tok, alice, alice, maxIn + 1);
        assertTrue(q1.soldOut, "maxIn + 1 should graduate");
        assertTrue(M.pairOf(tok) != address(0));
        vm.revertToState(snap);

        // maxIn does not
        CurveQuote.BuyQuote memory q0 = _buyAndCheck(tok, alice, alice, maxIn);
        assertFalse(q0.soldOut, "maxIn must not graduate");
        assertEq(M.pairOf(tok), address(0));
        CurveToken memory t = _tok(tok);
        assertLt(t.sold, t.sellable);
        assertEq(q0.refund, 0);
        console2.log("tokens left on the curve after the max buy (wei)", uint256(t.sellable - t.sold));
    }

    // ───────────────────────── pure properties (no chain state needed) ─────────────────────────

    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_Q4_pure_quote_never_reverts_and_conserves(
        uint128 sold,
        uint128 raised,
        uint256 amt,
        uint16 tax,
        uint16 snipe
    ) public pure {
        // any reachable curve state: start from the 85 OKB curve and move it by a valid buy of `raised` net
        CurveQuote.Curve memory c = _fresh(bound(tax, 0, 1_000));
        sold; // silence
        uint256 net0 = bound(raised, 0, 84 ether);
        uint256 out0 = c.vToken - CurveQuote.ceilDiv(c.vQuote * c.vToken, c.vQuote + net0);
        c.vQuote += net0;
        c.vToken -= out0;
        c.sold += out0;

        uint256 s = bound(snipe, 0, 9_500 - 100 - c.taxBuyBps);
        amt = bound(amt, 0, 1e30);
        CurveQuote.BuyQuote memory q = CurveQuote.quoteBuy(c, s, amt);
        assertEq(q.quoteSpent + q.refund, amt);
        assertEq(q.net + q.tax + q.platformFee, q.quoteSpent);
        assertLe(q.tokensOut, c.sellable - c.sold);
        assertEq(q.soldOut, q.tokensOut == c.sellable - c.sold);

        uint256 maxIn = CurveQuote.maxNonGraduatingBuy(c, s);
        assertFalse(CurveQuote.quoteBuy(c, s, maxIn).soldOut, "maxIn must not graduate");
        assertTrue(CurveQuote.quoteBuy(c, s, maxIn + 1).soldOut, "maxIn + 1 must graduate");
        assertLe(maxIn, CurveQuote.costToGraduate(c, s));
    }

    /// @dev The initial curve IGNIX derives for graduation = 85 OKB (CurveMath.params).
    function _fresh(uint256 taxBuyBps) internal pure returns (CurveQuote.Curve memory c) {
        uint256 C = 800_000_000 ether;
        uint256 D = 200_000_000 ether;
        uint256 T = (C * C) / (C - D);
        uint256 E = (85 ether * (T - C)) / C;
        c = CurveQuote.Curve({
            buyFeeBps: 100, taxBuyBps: taxBuyBps, vQuote: E, vToken: T, sold: 0, sellable: C
        });
    }

    function test_Q4_fresh_curve_matches_CurveMath_params() public view {
        CurveQuote.Curve memory live = _curve(address(token));
        CurveQuote.Curve memory calc = _fresh(300);
        assertEq(live.vQuote, calc.vQuote, "E");
        assertEq(live.vToken, calc.vToken, "T");
        assertEq(live.sellable, calc.sellable, "C");
        assertEq(live.sold, 0);
        console2.log("initial vQuote E (wei)", live.vQuote);
        console2.log("initial vToken T (wei)", live.vToken);
    }
}
