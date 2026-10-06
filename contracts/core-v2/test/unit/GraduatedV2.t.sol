// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseV2.t.sol";

/// @dev Settles a kernel from inside a flash swap on its token/USD₮0 pair (the pair's lock is held), repaying the
///      loan with its fee in the callback.
contract FlashSettler {
    address internal kernel;
    address internal q;
    bool public ok;
    bytes public ret;

    function run(MockPair pair, address quote_, uint256 quoteOut, address kernel_) external {
        (kernel, q) = (kernel_, quote_);
        bool quoteIs0 = pair.token0() == quote_;
        pair.swap(quoteIs0 ? quoteOut : 0, quoteIs0 ? 0 : quoteOut, address(this), hex"01");
    }

    function uniswapV2Call(address, uint256 amount0, uint256 amount1, bytes calldata) external {
        (ok, ret) = kernel.call(abi.encodeCall(IKernelMin.settle, ()));
        uint256 borrowed = amount0 + amount1;
        MockUSDT0(q).transfer(msg.sender, borrowed + (borrowed * 3) / 997 + 1);
    }
}

/// @notice Kernel v2 after graduation: the token regime (kernel v1's), the USD₮0 pot bought and burned on the
///         token/USD₮0 pair through an exact router allowance, the latch, and the locked tokens.
contract GraduatedV2Test is BaseV2 {
    bytes14 internal W = _word(128, 64, 48, 16, 64, 1023);

    function setUp() public override {
        super.setUp();
        _fixture(W);
    }

    /// @dev Curve trading, two settles, then graduation by a whale.
    function _toGraduation() internal returns (MockPair pair) {
        _buy(alice, 200e6);
        _nextEpoch();
        _settle();
        _buy(bob, 100e6);
        _nextEpoch();
        _settle();
        pair = _graduate();
    }

    function test_graduation_is_latched_by_the_first_settle_that_sees_the_pair() public {
        MockPair pair = _toGraduation();
        assertFalse(kernel.graduated());
        uint256 reserveBefore = kernel.reserve();
        _nextEpoch();
        vm.expectEmit(true, false, false, true, address(kernel));
        emit KernelV2.GraduationSeen(address(pair), reserveBefore);
        _settle();
        assertTrue(kernel.graduated());
        assertEq(kernel.pair(), address(pair));
        assertTrue(_has(_rec(3).flags, RecordFlags.GRADUATED));
    }

    function test_first_graduated_settle_numbers() public {
        _toGraduation();
        _nextEpoch();
        _settle();
        RecordV2 memory r = _rec(3);
        KernelMath.InputFields memory f = _in(3);
        assertEq(f.grad, 1);
        assertEq(f.prog, 255);
        assertEq(f.res, 0, "the token reserve starts at zero");
        assertEq(f.tax, f.taxCum, "TAXCUM restarts");
        assertEq(f.tax, KernelMath.lg8(r.inflow), "no shift in the token regime");
        assertEq(r.allow, 0, "no allowance after graduation");
        assertEq(kernel.allowPaidCum(), 0);
        assertEq(kernel.creditOf(payee, address(token)), 0);
    }

    function test_quote_pot_buys_on_the_pair_with_an_exact_allowance_and_burns() public {
        MockPair pair = _toGraduation();
        uint256 pot = _qbal(address(kernel)) + _qbal(address(vault)) - kernel.totalCredits(address(usdt));
        assertGt(pot, 0, "the USDT0 reserve and the residual USDT0 tax");
        _nextEpoch();
        (uint256 rT, uint256 rQ) = _pairReserves(pair);
        uint256 cap = TradeMath.impactCap(rQ, 25, 300, 300, 64);
        uint256 amt = pot < cap ? pot : cap;
        uint256 minOut = (TradeMath.v2NetOut(amt, rQ, rT, 300) * 9900) / 10_000;
        vm.expectCall(address(usdt), abi.encodeCall(MockUSDT0.approve, (address(router), amt)), 1);
        vm.expectCall(
            address(router),
            abi.encodeCall(
                MockRouterV2.swapExactTokensForTokensSupportingFeeOnTransferTokens,
                (amt, minOut, _path(address(usdt), address(token)), DEAD, block.timestamp)
            ),
            1
        );
        uint256 d0 = token.balanceOf(DEAD);
        _settle();
        RecordV2 memory r = _rec(3);
        assertEq(r.quoteIn, amt, "USDT0 spent, measured by balance");
        assertEq(token.balanceOf(DEAD) - d0, r.tokensOut);
        assertEq(r.tokensOut, r.buyExecuted + TradeMath.v2NetOut(amt, rQ, rT, 300), "burn leg plus the exact quote");
        assertEq(usdt.allowance(address(kernel), address(router)), 0, "router allowance reset");
        assertEq(kernel.burnedTokens(), r.tokensOut);
    }

    function test_quote_pot_is_drained_to_zero_over_time() public {
        _toGraduation();
        _revenue(300e6); // a large pot
        for (uint256 i = 0; i < 60; i++) {
            _nextEpoch();
            _settle();
            if (_qbal(address(kernel)) <= kernel.totalCredits(address(usdt))) break;
        }
        assertEq(_qbal(address(kernel)), kernel.totalCredits(address(usdt)), "only credits are left in USDT0");
    }

    function test_revenue_after_graduation_is_bought_and_burned_never_allowance() public {
        _toGraduation();
        while (_qbal(address(kernel)) > kernel.totalCredits(address(usdt))) {
            _nextEpoch();
            _settle(); // the pot left at graduation drains first
        }
        uint256 credit0 = kernel.creditOf(payee, address(usdt));
        _revenue(2e6);
        _nextEpoch();
        uint256 d0 = token.balanceOf(DEAD);
        _settle();
        RecordV2 memory r = _rec(kernel.count());
        assertEq(r.quoteIn, 2e6, "the whole payment went to the pair");
        assertGt(token.balanceOf(DEAD), d0);
        assertEq(kernel.creditOf(payee, address(usdt)), credit0, "no allowance from revenue after graduation");
    }

    function test_curve_allowance_credits_stay_withdrawable_after_graduation() public {
        _toGraduation();
        uint256 credit = kernel.creditOf(payee, address(usdt));
        assertGt(credit, 0);
        for (uint256 i = 0; i < 5; i++) {
            _nextEpoch();
            _settle();
        }
        assertEq(kernel.creditOf(payee, address(usdt)), credit, "the pot never spends a credit");
        assertEq(kernel.withdrawCredit(payee, address(usdt)), credit);
        assertEq(_qbal(payee), credit);
    }

    function test_swap_failure_is_flagged_and_the_pot_stays() public {
        _toGraduation();
        router.setMode(1);
        _nextEpoch();
        _settle();
        RecordV2 memory r = _rec(3);
        assertTrue(_has(r.flags, RecordFlags.BUY_FAILED));
        assertEq(r.quoteIn, 0);
        assertGt(_qbal(address(kernel)), kernel.totalCredits(address(usdt)), "the pot waits");
        assertEq(usdt.allowance(address(kernel), address(router)), 0, "reset after a failed swap");
    }

    function test_swap_that_spends_less_than_it_was_approved_is_flagged() public {
        _toGraduation();
        router.setPullLess(1000);
        _nextEpoch();
        _settle();
        RecordV2 memory r = _rec(3);
        assertTrue(_has(r.flags, RecordFlags.BUY_FAILED), "less moved than decided");
        assertGt(r.quoteIn, 0);
        assertEq(usdt.allowance(address(kernel), address(router)), 0, "the unspent allowance was cleared");
    }

    function test_approve_failure_skips_the_swap_without_moving_anything() public {
        _toGraduation();
        usdt.setFailure(false, false, true, false);
        uint256 q0 = _qbal(address(kernel));
        _nextEpoch();
        _settle();
        assertTrue(_has(_rec(3).flags, RecordFlags.BUY_FAILED));
        assertGe(_qbal(address(kernel)), q0, "nothing left");
    }

    function test_swap_skipped_when_the_pair_cannot_be_read() public {
        MockPair pair = _toGraduation();
        pair.setReservesRevert(true);
        _nextEpoch();
        _settle();
        RecordV2 memory r = _rec(3);
        assertTrue(_has(r.flags, RecordFlags.BUY_SKIPPED));
        assertEq(r.quoteIn, 0);
    }

    function test_unreadable_manager_after_graduation_shrinks_the_cap_but_does_not_stop_the_exit() public {
        _toGraduation();
        manager.setTokensMode(1);
        _nextEpoch();
        _settle();
        RecordV2 memory r = _rec(3);
        assertTrue(_has(r.flags, RecordFlags.CURVE_READ_FAILED));
        assertGt(r.quoteIn, 0, "the pot is still spent, with tax assumed zero for the cap");
    }

    function test_swap_revert_with_the_pair_lock_string_reverts_the_settle() public {
        _toGraduation();
        router.setRevertData(abi.encodeWithSignature("Error(string)", "UniswapV2: LOCKED"));
        _nextEpoch();
        vm.prank(keeper);
        vm.expectRevert(KernelV2.LockHeld.selector);
        kernel.settle();
        router.setRevertData(abi.encodeWithSignature("Error(string)", "UniswapV2: K"));
        _settle();
        assertTrue(_has(_rec(3).flags, RecordFlags.BUY_FAILED), "any other string is a failure every caller sees");
    }

    function test_settle_from_inside_a_flash_swap_reverts_and_keeps_the_epoch() public {
        MockPair pair = _toGraduation();
        _nextEpoch();
        FlashSettler fs = new FlashSettler();
        _fund(address(fs), 100e6);
        (, uint256 rQ) = _pairReserves(pair);
        fs.run(pair, address(usdt), rQ / 4, address(kernel));
        assertFalse(fs.ok());
        assertEq(bytes4(fs.ret()), KernelV2.LockHeld.selector);
        assertEq(kernel.count(), 2, "nothing recorded");
        _settle();
        assertEq(kernel.count(), 3);
    }

    function test_tokens_sent_straight_to_the_kernel_are_inflow() public {
        _toGraduation();
        _v2Buy(alice, 10e6);
        uint256 gift = token.balanceOf(alice) / 2;
        vm.prank(alice);
        token.transfer(address(kernel), gift);
        _nextEpoch();
        _settle();
        assertGe(_rec(3).inflow, gift);
    }

    function test_token_claim_failure_is_a_flag_and_arrived_tokens_are_routed() public {
        _toGraduation();
        _v2Buy(alice, 10e6); // token tax into the vault
        vault.setMode(1);
        _nextEpoch();
        _settle();
        assertTrue(_has(_rec(3).flags, RecordFlags.CLAIM_FAILED));
    }

    function test_burn_failure_is_flagged_and_tokens_stay_in_reserve() public {
        _toGraduation();
        _nextEpoch();
        _settle();
        _v2Buy(alice, 50e6);
        token.setFailure(false, false, false, DEAD); // transfers to 0xdEaD revert
        _nextEpoch();
        _settle();
        RecordV2 memory r = _rec(4);
        assertTrue(_has(r.flags, RecordFlags.BUY_FAILED));
        assertEq(r.buyExecuted, 0);
        assertEq(kernel.reserve(), uint256(r.reserveBefore) + r.inflow);
    }

    function test_burnLocked_sends_curve_tokens_to_dead() public {
        _toGraduation();
        uint256 locked = kernel.lockedTokens();
        assertGt(locked, 0);
        vm.expectRevert(KernelV2.NotGraduated.selector);
        kernel.burnLocked();
        _nextEpoch();
        _settle();
        uint256 d0 = token.balanceOf(DEAD);
        assertEq(kernel.burnLocked(), locked);
        assertEq(token.balanceOf(DEAD) - d0, locked);
        assertEq(kernel.lockedTokens(), 0);
        assertEq(kernel.burnLocked(), 0, "nothing left");
    }

    function test_latch_reads_the_token_and_is_never_cleared() public {
        _toGraduation();
        token.setPairMode(1); // the token's pair() reverts
        _nextEpoch();
        _settle();
        assertFalse(kernel.graduated(), "an unreadable pair neither sets nor clears the latch");
        token.setPairMode(0);
        _nextEpoch();
        _settle();
        assertTrue(kernel.graduated());
        token.setPairMode(1);
        _nextEpoch();
        _settle();
        assertTrue(kernel.graduated(), "never cleared");
    }

    function test_no_token_allowance_ever_accrues() public {
        _fixtureWith(ChipModel.fixedChip(8, _word(0, 0, 128, 128, 0, 1023)), _env());
        _toGraduation();
        for (uint256 i = 0; i < 4; i++) {
            _v2Buy(alice, 20e6);
            _nextEpoch();
            _settle();
        }
        assertEq(kernel.creditOf(payee, address(token)), 0);
        assertEq(kernel.totalCredits(address(token)), 0);
        assertEq(kernel.allowPaidCum(), 0);
    }

    function test_buy_disabled_after_graduation_credits_sink_in_both_assets() public {
        Envelope memory e = _env();
        e.buyEnabled = false;
        e.sink = sinkAddr;
        _fixtureWith(ChipModel.fixedChip(8, _word(128, 0, 64, 64, 0, 1023)), e);
        _toGraduation();
        _v2Buy(alice, 20e6);
        _nextEpoch();
        _settle();
        _nextEpoch();
        _settle();
        assertGt(kernel.creditOf(sinkAddr, address(usdt)), 0, "the pot");
        assertGt(kernel.creditOf(sinkAddr, address(token)), 0, "the decided token buys");
        uint256 t = kernel.creditOf(sinkAddr, address(token));
        assertEq(kernel.withdrawCredit(sinkAddr, address(token)), t);
        assertEq(token.balanceOf(sinkAddr), t);
    }

    /// A trader who buys before the kernel's capped router buy and sells right after it loses money.
    function testFuzz_v2_sandwich_of_the_quote_leg_is_unprofitable(uint256 size) public {
        MockPair pair = _toGraduation();
        _revenue(500e6); // enough to hit the cap
        (, uint256 rQ) = _pairReserves(pair);
        size = bound(size, 1e6, rQ / 2);
        address mev = makeAddr("sandwicher");
        uint256 spent = size;
        _v2Buy(mev, size);
        _nextEpoch();
        _settle();
        _v2Sell(mev, token.balanceOf(mev));
        assertLt(_qbal(mev), spent, "the sandwich lost money");
    }
}
