// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseV2.t.sol";

/// @dev Calls settle from inside the IgnixManager's reentrancy lock (MockManagerV2.withLock models the native
///      payout of another token's sell, which is how a contract holds the shared lock on the real Manager).
contract LockedSettler {
    function run(MockManagerV2 m, address k) external returns (bool ok, bytes memory ret) {
        (bool outer, bytes memory r) = address(m).call(
            abi.encodeCall(MockManagerV2.withLock, (k, abi.encodeCall(IKernelMin.settle, ())))
        );
        require(outer, "withLock");
        (ok, ret) = abi.decode(r, (bool, bytes));
    }
}

/// @notice Kernel v2 on the curve: USD₮0 books, revenue by plain transfer, shifted codes, exact approvals.
contract SettleCurveV2Test is BaseV2 {
    // 50% buy, 25% hold, 18.75% allowance, 6.25% reserve; release 1/4; no chip ceiling
    bytes14 internal W = _word(128, 64, 48, 16, 64, 1023);

    function setUp() public override {
        super.setUp();
        _fixture(W);
    }

    // ------------------------------------------------------------------ epochs

    function test_settle_reverts_in_the_bind_epoch() public {
        vm.expectRevert(KernelV2.EpochNotElapsed.selector);
        _settle();
    }

    function test_at_most_one_settle_per_epoch() public {
        _nextEpoch();
        _settle();
        vm.expectRevert(KernelV2.EpochNotElapsed.selector);
        _settle();
        _nextEpoch();
        assertEq(_settle(), 2);
    }

    function test_zero_inflow_settle_still_steps_and_records() public {
        _nextEpoch();
        assertEq(_settle(), 1);
        RecordV2 memory r = _rec(1);
        assertEq(r.inflow, 0);
        assertEq(r.allow, 0);
        assertEq(r.buyDecided, 0);
        assertTrue(kernel.state() != bytes32(0), "the chip state advanced");
        assertEq(kernel.lastStepEpoch(), 1);
    }

    // ------------------------------------------------------------------ books in USD₮0

    function test_first_funded_settle_numbers() public {
        _buy(alice, 100e6); // 3 USD₮0 of tax into the vault
        assertEq(_qbal(address(vault)), 3e6);
        _nextEpoch();
        TradeMath.Curve memory c = _curve();
        _settle();
        RecordV2 memory r = _rec(1);
        assertEq(r.inflow, 3e6, "inflow is the USDT0 tax");
        assertEq(r.reserveBefore, 0);
        assertEq(r.allow, (3e6 * 48) / 256, "allowance in USDT0");
        uint256 decided = (3e6 * 128) / 256;
        assertEq(r.buyDecided, decided);
        (uint256 amt, uint256 out,) = TradeMath.curveBuy(c, decided, 64);
        assertEq(r.buyExecuted, amt, "the whole decided buy executed");
        assertEq(r.tokensOut, out, "exact quote");
        assertEq(r.quoteIn, 0);
        assertEq(kernel.creditOf(payee, address(usdt)), r.allow);
        assertEq(kernel.totalCredits(address(usdt)), r.allow);
        assertEq(kernel.lockedTokens(), out);
        assertEq(kernel.reserve(), 3e6 - r.allow - amt);
        assertEq(_qbal(address(kernel)), kernel.reserve() + kernel.totalCredits(address(usdt)), "books equal balance");
        assertEq(usdt.allowance(address(kernel), address(manager)), 0, "no allowance left behind");
        assertEq(_qbal(address(vault)), (amt * 300) / 10_000, "the kernel's own buy paid tax into its vault");
    }

    function test_input_codes_are_lg8_of_the_amount_shifted_by_33_bits() public {
        _buy(alice, 100e6);
        _nextEpoch();
        _settle();
        KernelMath.InputFields memory f = _in(1);
        assertEq(f.tax, KernelMath.lg8(3e6) + 264, "TAX is 264 codes above the USDT0 code");
        assertEq(f.tax, KernelMath.lg8(uint256(3e6) << 33));
        assertEq(f.taxCum, f.tax);
        assertEq(f.res, 0, "zero stays zero");
        assertEq(f.rev, 0, "revenue is not a separate field in kernel v2 (c')");
        assertEq(f.revCum, 0);
        assertEq(f.esc, 0);
        assertEq(f.grad, 0);
        assertEq(f.dt, 1);
        // 3 USD₮0 reads as 3e6 * 2^33 wei = 0.0258 OKB of the chip's calibration: code 436
        assertEq(f.tax, 436);

        uint256 reserve1 = kernel.reserve();
        _nextEpoch();
        _settle();
        f = _in(2);
        assertEq(f.res, KernelMathV2.lg8s(reserve1, 33), "RES is shifted too");
        assertEq(f.res, KernelMath.lg8(reserve1) + 264);
        assertEq(f.dt, 1);
    }

    function test_revenue_sent_to_the_kernel_is_inflow_like_tax() public {
        _revenue(500_000); // one $0.50 call
        _nextEpoch();
        _settle();
        RecordV2 memory r = _rec(1);
        assertEq(r.inflow, 500_000, "revenue counted by balance");
        assertEq(_in(1).tax, KernelMath.lg8(500_000) + 264);
        assertEq(_in(1).tax, 416, "$0.50 reads as code 416 (152 + 264)");
        assertEq(r.allow, (500_000 * 48) / 256);
        // tax and revenue in the same epoch add up
        _buy(alice, 10e6);
        _revenue(1_000_000);
        _nextEpoch();
        uint256 expectFresh = 300_000 + 1_000_000 + (_rec(1).buyExecuted * 300) / 10_000;
        _settle();
        assertEq(_rec(2).inflow, expectFresh, "the claimed tax, the echo of the kernel's own buy, and revenue");
    }

    function test_inflow_is_balance_not_the_claim_amount() public {
        _buy(alice, 100e6);
        vm.prank(bob);
        vault.claimFor(address(kernel), address(usdt)); // a third party pushes the tax early: no callback
        assertEq(_qbal(address(kernel)), 3e6);
        _nextEpoch();
        _settle();
        assertEq(_rec(1).inflow, 3e6);
        assertFalse(_has(_rec(1).flags, RecordFlags.CLAIM_FAILED), "nothing left to claim is not a failure");
    }

    function test_claim_paused_is_a_flag_and_revenue_still_routes() public {
        _buy(alice, 100e6);
        _revenue(2e6);
        vault.setMode(3); // IGNIX's DIVIDEND pause
        _nextEpoch();
        _settle();
        RecordV2 memory r = _rec(1);
        assertTrue(_has(r.flags, RecordFlags.CLAIM_FAILED));
        assertEq(r.inflow, 2e6, "revenue paid to the kernel does not wait for the vault");
        assertGe(_qbal(address(vault)), 3e6, "the tax waits in the vault (with the echo of the kernel's own buy)");
        vault.setMode(0);
        _nextEpoch();
        _settle();
        assertGe(_rec(2).inflow, 3e6, "and arrives at the next settle");
    }

    function test_claim_that_burns_all_its_gas_is_a_flag() public {
        _buy(alice, 100e6);
        vault.setMode(2);
        _nextEpoch();
        _settle();
        assertTrue(_has(_rec(1).flags, RecordFlags.CLAIM_FAILED));
        assertEq(_rec(1).inflow, 0);
    }

    // ------------------------------------------------------------------ approvals

    function test_curve_buy_approves_exactly_its_amount_and_resets_to_zero() public {
        _buy(alice, 100e6);
        _nextEpoch();
        TradeMath.Curve memory c = _curve();
        uint256 decided = (3e6 * 128) / 256;
        (uint256 amt, uint256 out,) = TradeMath.curveBuy(c, decided, 64);
        vm.expectCall(address(usdt), abi.encodeCall(MockUSDT0.approve, (address(manager), amt)), 1);
        vm.expectCall(
            address(manager), abi.encodeCall(MockManagerV2.buyTo, (address(token), amt, out, address(kernel))), 1
        );
        _settle();
        assertEq(usdt.allowance(address(kernel), address(manager)), 0);
    }

    function test_failed_buy_leaves_no_allowance_and_the_amount_stays() public {
        _buy(alice, 100e6);
        manager.setBuyMode(1);
        _nextEpoch();
        vm.expectCall(address(usdt), abi.encodeCall(MockUSDT0.approve, (address(manager), 0)), 1);
        _settle();
        RecordV2 memory r = _rec(1);
        assertTrue(_has(r.flags, RecordFlags.BUY_FAILED));
        assertEq(r.buyExecuted, 0);
        assertEq(usdt.allowance(address(kernel), address(manager)), 0, "reset after a failed buy");
        assertEq(kernel.reserve(), 3e6 - r.allow, "the decided buy stays in the reserve");
        assertEq(_qbal(address(kernel)), kernel.reserve() + kernel.totalCredits(address(usdt)));
    }

    function test_approve_that_reverts_is_a_failed_buy_and_nothing_moves() public {
        _buy(alice, 100e6);
        usdt.setFailure(false, false, true, false);
        _nextEpoch();
        _settle();
        RecordV2 memory r = _rec(1);
        assertTrue(_has(r.flags, RecordFlags.BUY_FAILED));
        assertEq(r.buyExecuted, 0);
        assertEq(kernel.lockedTokens(), 0);
    }

    function test_approve_that_returns_false_is_a_failed_buy() public {
        _buy(alice, 100e6);
        usdt.setFailure(false, false, false, true);
        _nextEpoch();
        _settle();
        assertTrue(_has(_rec(1).flags, RecordFlags.BUY_FAILED), "the Manager could not pull");
        assertEq(_rec(1).buyExecuted, 0);
    }

    function test_a_manager_that_pulls_more_than_approved_gets_nothing() public {
        _buy(alice, 100e6);
        manager.setPullMore(true);
        _nextEpoch();
        _settle();
        assertTrue(_has(_rec(1).flags, RecordFlags.BUY_FAILED), "the exact allowance refused the extra unit");
        assertEq(_rec(1).buyExecuted, 0);
        assertEq(usdt.allowance(address(kernel), address(manager)), 0);
    }

    function test_quote_that_comes_back_is_measured_and_flagged() public {
        _buy(alice, 100e6);
        _fund(address(manager), 1e6);
        manager.setRefundQuote(1000);
        _nextEpoch();
        _settle();
        RecordV2 memory r = _rec(1);
        assertTrue(_has(r.flags, RecordFlags.BUY_FAILED), "less moved than decided");
        uint256 decided = (3e6 * 128) / 256;
        assertEq(r.buyExecuted, decided - 1000, "measured by balance");
        assertEq(kernel.reserve(), 3e6 - r.allow - r.buyExecuted);
        assertEq(_qbal(address(kernel)), kernel.reserve() + kernel.totalCredits(address(usdt)));
    }

    // ------------------------------------------------------------------ native OKB

    function test_plain_okb_transfers_are_refused() public {
        address[4] memory senders = [alice, launcher, payee, address(vault)];
        for (uint256 i = 0; i < 4; i++) {
            vm.deal(senders[i], 1 ether);
            vm.prank(senders[i]);
            (bool ok,) = address(kernel).call{value: 1 ether}("");
            assertFalse(ok, "no receive()");
        }
        assertEq(address(kernel).balance, 0);
    }

    function test_forced_okb_is_never_counted_or_routed() public {
        vm.deal(address(kernel), 5 ether); // SELFDESTRUCT or a block reward cannot be refused
        _buy(alice, 100e6);
        _nextEpoch();
        _settle();
        assertEq(_rec(1).inflow, 3e6, "only USDT0 is inflow on the curve");
        assertEq(address(kernel).balance, 5 ether, "forced OKB stays, unroutable");
    }

    function test_kernel_has_no_fallback_and_answers_no_pool_probe() public {
        (bool ok,) = address(kernel).call(abi.encodeWithSignature("token0()"));
        assertFalse(ok);
        (ok,) = address(kernel).call(abi.encodeWithSignature("token1()"));
        assertFalse(ok);
        (ok,) = address(kernel).call(abi.encodeWithSignature("fee()"));
        assertFalse(ok);
        (ok,) = address(kernel).call("");
        assertFalse(ok);
    }

    function test_bought_tokens_cannot_leave_before_graduation() public {
        _buy(alice, 100e6);
        _nextEpoch();
        _settle();
        uint256 locked = kernel.lockedTokens();
        assertGt(locked, 0);
        vm.prank(address(kernel));
        vm.expectRevert(MockToken.CurveOnly.selector);
        token.transfer(alice, 1);
        vm.expectRevert(KernelV2.NotGraduated.selector);
        kernel.burnLocked();
    }

    // ------------------------------------------------------------------ clamps with the shift

    function test_K2_allowance_share_above_capT_is_clipped_and_excess_stays() public {
        Envelope memory e = _env();
        _fixtureWith(ChipModel.fixedChip(8, _word(96, 0, 160, 0, 0, 1023)), e);
        _buy(alice, 100e6);
        _nextEpoch();
        _settle();
        RecordV2 memory r = _rec(1);
        assertEq(r.clampBits & KernelMath.K2, KernelMath.K2);
        assertEq(r.allow, (3e6 * 64) / 256);
    }

    function test_chip_ceiling_is_decoded_through_the_shift_and_is_not_a_clamp() public {
        // CEIL 440: exp8(440) = 15 * 2^51 wei-equivalent, which is 15 * 2^18 = 3,932,160 USD₮0 base units
        _fixtureWith(ChipModel.fixedChip(8, _word(128, 0, 64, 64, 0, 440)), _env());
        _buy(alice, 1_000e6); // 30 USD₮0 of tax: a quarter would be 7.5 USD₮0
        _nextEpoch();
        _settle();
        RecordV2 memory r = _rec(1);
        assertEq(KernelMathV2.exp8s(440, 33), 3_932_160);
        assertEq(r.allow, 3_932_160, "cut at the shifted chip ceiling");
        assertEq(r.clampBits, 0, "the chip's own ceiling is not a clamp");
    }

    function test_K2C_envelope_ceiling_is_in_the_chips_code_space() public {
        Envelope memory e = _env();
        e.ceilMax = 440;
        _fixtureWith(ChipModel.fixedChip(8, _word(128, 0, 64, 64, 0, 1023)), e);
        _buy(alice, 1_000e6);
        _nextEpoch();
        _settle();
        RecordV2 memory r = _rec(1);
        assertEq(r.allow, 3_932_160);
        assertEq(r.clampBits & KernelMath.K2C, KernelMath.K2C);
    }

    function test_K5_floor_threshold_is_in_the_chips_code_space() public {
        // A chip that hoards. floorMin 425 (0.009 OKB on kernel v1) is reached at 2^20 = 1.048576 USD₮0 here.
        Envelope memory e = _env();
        e.floorMin = 425;
        _fixtureWith(ChipModel.fixedChip(8, _word(0, 0, 0, 256, 0, 1023)), e);
        _revenue(1_048_575); // one unit below the threshold
        _nextEpoch();
        _settle();
        _nextEpoch();
        _settle();
        assertEq(_rec(2).reserveBefore, 1_048_575);
        assertEq(_rec(2).clampBits & KernelMath.K5, 0, "below the threshold: no floor");
        _revenue(1);
        _nextEpoch();
        _settle();
        _nextEpoch();
        _settle();
        assertEq(_rec(4).reserveBefore, 1_048_576);
        assertEq(_rec(4).clampBits & KernelMath.K5, KernelMath.K5, "at the threshold: the floor releases");
        assertEq(_rec(4).buyDecided, (uint256(1_048_576) * 2) / 256);
    }

    function test_K3_release_above_relMax_is_clipped() public {
        _fixtureWith(ChipModel.fixedChip(8, _word(0, 0, 0, 256, 300, 1023)), _env());
        _revenue(10e6);
        _nextEpoch();
        _settle();
        _nextEpoch();
        _settle();
        assertEq(_rec(2).clampBits & KernelMath.K3, KernelMath.K3);
        assertEq(_rec(2).buyDecided, (10e6 * 128) / 256);
    }

    function test_K1T_malformed_group_becomes_reserve_and_state_still_advances() public {
        _fixtureWith(ChipModel.fixedChip(8, _word(200, 0, 100, 0, 0, 1023)), _env());
        _revenue(10e6);
        _nextEpoch();
        _settle();
        RecordV2 memory r = _rec(1);
        assertEq(r.clampBits & KernelMath.K1T, KernelMath.K1T);
        assertEq(r.allow, 0);
        assertEq(r.buyDecided, 0);
        assertEq(kernel.reserve(), 10e6);
        assertEq(kernel.lastStepEpoch(), 1);
    }

    function test_K2L_lifetime_cap() public {
        Envelope memory e = _env();
        e.allowCumBps = 100; // 1%
        _fixtureWith(ChipModel.fixedChip(8, _word(128, 0, 64, 64, 0, 1023)), e);
        _revenue(10e6);
        _nextEpoch();
        _settle();
        RecordV2 memory r = _rec(1);
        assertEq(r.allow, 100_000, "1% of 10 USDT0");
        assertEq(r.clampBits & KernelMath.K2L, KernelMath.K2L);
    }

    // ------------------------------------------------------------------ the buy

    function test_buy_is_capped_by_the_impact_cap_in_usdt0() public {
        _fixtureWith(ChipModel.fixedChip(8, _word(256, 0, 0, 0, 0, 1023)), _env());
        _revenue(500e6);
        _nextEpoch();
        TradeMath.Curve memory c = _curve();
        uint256 cap = TradeMath.impactCap(c.vQuote, 200, 300, 300, 64);
        _settle();
        RecordV2 memory r = _rec(1);
        assertTrue(_has(r.flags, RecordFlags.BUY_SHRUNK));
        assertEq(r.buyExecuted, cap, "a quarter of the round-trip cost times vQuote");
        // on a fresh 8,000 USD₮0 curve with capT 64 the cap is 43.33 USD₮0
        assertEq(cap, 43_333_333);
    }

    function test_buy_never_graduates_the_curve() public {
        _fixtureWith(ChipModel.fixedChip(8, _word(256, 0, 0, 0, 0, 1023)), _env());
        // leave the curve close to the end
        TradeMath.Curve memory c = _curve();
        uint256 room = TradeMath.maxNonGraduatingBuy(c);
        _buy(alice, room - 5e6);
        _revenue(100e6);
        _nextEpoch();
        _settle();
        assertEq(manager.pairOf(address(token)), address(0), "still on the curve");
        assertTrue(_has(_rec(1).flags, RecordFlags.BUY_SHRUNK));
    }

    function test_buy_skipped_during_buy_pause() public {
        _buy(alice, 100e6);
        manager.setPaused(1, uint64(block.timestamp + 10 * EPOCH));
        _nextEpoch();
        _settle();
        assertTrue(_has(_rec(1).flags, RecordFlags.BUY_SKIPPED), "Paused is a guard, not a failure");
        assertEq(_rec(1).buyExecuted, 0);
        assertEq(usdt.allowance(address(kernel), address(manager)), 0);
    }

    /// The kernel's own founder-round guard skips the buy before any approve or buyTo: the Manager's FounderOnly
    /// revert would set the same flag, so the calls themselves are counted (review B-F4).
    function test_buy_skipped_during_founder_round_without_calling_the_manager() public {
        _buy(alice, 100e6);
        manager.setFounderRound(address(token), uint64(block.timestamp + 10 * EPOCH));
        _nextEpoch();
        vm.expectCall(address(manager), abi.encodeWithSelector(MockManagerV2.buyTo.selector), 0);
        vm.expectCall(address(usdt), abi.encodeWithSelector(MockUSDT0.approve.selector), 0);
        _settle();
        RecordV2 memory r = _rec(1);
        assertTrue(_has(r.flags, RecordFlags.BUY_SKIPPED));
        assertFalse(_has(r.flags, RecordFlags.BUY_FAILED));
        assertGt(r.buyDecided, 0, "a buy was decided");
        assertEq(r.buyExecuted, 0);
    }

    function test_curve_read_failure_is_a_flag_and_the_buy_is_skipped() public {
        _buy(alice, 100e6);
        manager.setTokensMode(1);
        _nextEpoch();
        _settle();
        RecordV2 memory r = _rec(1);
        assertTrue(_has(r.flags, RecordFlags.CURVE_READ_FAILED));
        assertTrue(_has(r.flags, RecordFlags.BUY_SKIPPED));
        assertEq(_in(1).prog, 0);
    }

    function test_buy_that_misses_the_exact_quote_is_flagged() public {
        _buy(alice, 100e6);
        manager.setBuyMode(3);
        _nextEpoch();
        _settle();
        assertTrue(_has(_rec(1).flags, RecordFlags.BUY_FAILED));
        assertEq(_rec(1).buyExecuted, 0);
    }

    function test_settle_from_inside_the_managers_lock_reverts_and_keeps_the_epoch() public {
        _buy(alice, 100e6);
        _nextEpoch();
        LockedSettler ls = new LockedSettler();
        (bool ok, bytes memory ret) = ls.run(manager, address(kernel));
        assertFalse(ok);
        assertEq(bytes4(ret), KernelV2.LockHeld.selector);
        assertEq(kernel.count(), 0, "nothing recorded");
        assertEq(usdt.allowance(address(kernel), address(manager)), 0);
        _settle(); // the epoch is still open for everyone else
        assertEq(kernel.count(), 1);
    }

    function test_manager_cannot_reenter_settle_during_buy() public {
        _buy(alice, 100e6);
        manager.setReenter(address(kernel), abi.encodeCall(IKernelMin.settle, ()));
        _nextEpoch();
        _settle();
        assertTrue(_has(_rec(1).flags, RecordFlags.BUY_FAILED), "the reentry was refused, so the buy failed");
        assertEq(kernel.count(), 1);
    }

    // ------------------------------------------------------------------ Tether's powers

    function test_blocked_kernel_keeps_settling_and_its_money_waits() public {
        _buy(alice, 100e6);
        _nextEpoch();
        _settle();
        uint256 credit = kernel.creditOf(payee, address(usdt));
        assertGt(credit, 0);
        usdt.addToBlockedList(address(kernel));
        _buy(alice, 100e6);
        _nextEpoch();
        _settle();
        RecordV2 memory r = _rec(2);
        assertGe(r.inflow, 3e6, "a blocked address still receives its claim");
        assertTrue(_has(r.flags, RecordFlags.BUY_FAILED), "but cannot be pulled from");
        assertEq(r.buyExecuted, 0);
        vm.expectRevert(KernelV2.PayFailed.selector);
        kernel.withdrawCredit(payee, address(usdt));
        assertGt(kernel.creditOf(payee, address(usdt)), credit, "the credit stays");
    }

    function test_destroyed_balance_never_makes_settle_revert() public {
        _buy(alice, 100e6);
        _nextEpoch();
        _settle();
        usdt.addToBlockedList(address(kernel));
        usdt.destroyBlockedFunds(address(kernel));
        assertEq(_qbal(address(kernel)), 0);
        _nextEpoch();
        _settle();
        RecordV2 memory r = _rec(2);
        assertEq(r.reserveBefore, 0, "the reserve is cut to what is there");
        assertEq(r.inflow, 0);
    }

    function test_fee_on_transfer_quote_stops_buys_and_never_breaks_the_books() public {
        _buy(alice, 100e6);
        usdt.setFeeBps(10); // a hypothetical upgrade of USD₮0 that charges 0.1% per transfer
        _nextEpoch();
        _settle();
        RecordV2 memory r = _rec(1);
        assertEq(r.inflow, 3e6 - 3_000, "the claim arrived less the fee: counted by balance");
        assertTrue(_has(r.flags, RecordFlags.BUY_FAILED), "the Manager received less than the exact quote needs");
        assertEq(_qbal(address(kernel)), kernel.reserve() + kernel.totalCredits(address(usdt)));
    }

    // ------------------------------------------------------------------ buys disabled (outside the factory)

    function test_buy_disabled_credits_sink_in_usdt0() public {
        Envelope memory e = _env();
        e.buyEnabled = false;
        e.sink = sinkAddr;
        _fixtureWith(ChipModel.fixedChip(8, _word(128, 0, 64, 64, 0, 1023)), e);
        _revenue(10e6);
        _nextEpoch();
        _settle();
        RecordV2 memory r = _rec(1);
        assertEq(kernel.creditOf(sinkAddr, address(usdt)), r.buyDecided);
        assertEq(r.buyExecuted, r.buyDecided);
        assertEq(kernel.withdrawCredit(sinkAddr, address(usdt)), r.buyDecided);
        assertEq(_qbal(sinkAddr), r.buyDecided);
    }

    function test_settle_emits_Settled() public {
        _revenue(1e6);
        _nextEpoch();
        vm.recordLogs();
        _settle();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(kernel) && logs[i].topics[0] == IKernelV2.Settled.selector) seen = true;
        }
        assertTrue(seen);
    }
}
