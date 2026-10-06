// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseV2.t.sol";

/// @notice Combinations of external failures in both regimes, now including USD₮0's own (balanceOf, transfer and
///         approve reverting, approve returning false, a fee on transfer, Tether blocking the kernel). The claim:
///         for every pattern and every output word, a sufficiently funded settle either succeeds, or reverts with
///         StepFailed because no evaluator answers inside the grace period, in which case the fallback word
///         applies once the grace period is over. No pattern leaves an allowance behind, and none makes the
///         kernel hold less than it owes (Tether destroying the kernel's balance aside, a stated limit).
contract FailureMatrixV2Test is BaseV2 {
    bytes14 internal W = _word(128, 64, 48, 16, 64, 1023);

    function setUp() public override {
        super.setUp();
    }

    function _trySettle() internal returns (bool ok, bytes4 err) {
        vm.prank(keeper);
        bytes memory ret;
        (ok, ret) = address(kernel).call{gas: 40_000_000}(abi.encodeCall(IKernelMin.settle, ()));
        if (!ok && ret.length >= 4) err = bytes4(ret);
    }

    function _solvent() internal view {
        if (usdt.balanceOfReverts() || token.balanceOfReverts()) return;
        bool grad = kernel.graduated();
        assertGe(
            _qbal(address(kernel)), kernel.totalCredits(address(usdt)) + (grad ? 0 : kernel.reserve()), "USD0 books"
        );
        assertGe(
            token.balanceOf(address(kernel)),
            kernel.totalCredits(address(token)) + kernel.lockedTokens() + (grad ? kernel.reserve() : 0),
            "token books"
        );
    }

    function _noAllowanceLeft() internal view {
        assertEq(usdt.allowance(address(kernel), address(manager)), 0, "Manager allowance");
        assertEq(usdt.allowance(address(kernel), address(router)), 0, "router allowance");
    }

    struct Faults {
        uint8 vault; // 0..3
        uint8 tokensMode; // 0, 1, 2, 4, 5
        uint8 buyMode; // 0..4
        uint8 quote; // 0 fine, 1 balanceOf reverts, 2 transfer reverts, 3 approve reverts, 4 approve false, 5 fee
        uint8 tapeOut; // step mode
        uint8 sealedOne; // step mode
        bool pinsHold;
        bool snipeReverts;
        uint8 router; // 0..2 (graduated)
        bool pairReverts; // graduated
        uint8 tokenFault; // 0 fine, 1 balanceOf reverts, 2 transfer reverts, 3 transfer returns false, 4 DEAD blocked
    }

    function _faults(uint256 seed) internal pure returns (Faults memory f) {
        uint8[5] memory tm = [0, 1, 2, 4, 5];
        uint8[5] memory em = [0, 1, 2, 5, 3];
        f.vault = uint8(seed % 4);
        f.tokensMode = tm[(seed >> 8) % 5];
        f.buyMode = uint8((seed >> 16) % 5);
        f.quote = uint8((seed >> 24) % 6);
        f.tapeOut = em[(seed >> 32) % 5];
        f.sealedOne = (seed >> 40) % 3 == 0 ? em[(seed >> 44) % 5] : 0;
        f.pinsHold = (seed >> 48) % 4 != 0;
        f.snipeReverts = (seed >> 52) % 2 == 0;
        f.router = uint8((seed >> 56) % 3);
        f.pairReverts = (seed >> 60) % 3 == 0;
        f.tokenFault = uint8((seed >> 64) % 5);
    }

    function _apply(Faults memory f, bool grad) internal {
        vault.setMode(f.vault);
        manager.setTokensMode(f.tokensMode);
        manager.setBuyMode(f.buyMode == 4 ? 1 : f.buyMode);
        if (f.buyMode == 4) manager.setBuyRevertData(abi.encodeWithSignature("Error(string)", "anything"));
        manager.setSnipeReverts(f.snipeReverts);
        usdt.setFailure(f.quote == 1, f.quote == 2, f.quote == 3, f.quote == 4);
        if (f.quote == 5) usdt.setFeeBps(25);
        circuits.setStepMode(f.tapeOut);
        sealedVM.setStepMode(f.sealedOne);
        if (!f.pinsHold) beacon.upgradeTo(address(new MockImplV2()));
        if (grad) {
            router.setMode(f.router);
            MockPair(manager.pairOf(address(token))).setReservesRevert(f.pairReverts);
            token.setFailure(f.tokenFault == 1, f.tokenFault == 2, f.tokenFault == 3, f.tokenFault == 4 ? DEAD : address(0));
        }
    }

    function _clear() internal {
        vault.setMode(0);
        manager.setTokensMode(0);
        manager.setBuyMode(0);
        manager.setSnipeReverts(false);
        usdt.setFailure(false, false, false, false);
        usdt.setFeeBps(0);
        circuits.setStepMode(0);
        sealedVM.setStepMode(0);
        beacon.upgradeTo(address(impl));
        router.setMode(0);
        token.setFailure(false, false, false, address(0));
        address p = manager.pairOf(address(token));
        if (p != address(0)) MockPair(p).setReservesRevert(false);
    }

    /// @dev Whether some evaluator answers under these faults.
    function _answers(Faults memory f) internal pure returns (bool) {
        bool tapeOut = f.pinsHold && f.tapeOut == 0;
        return tapeOut || f.sealedOne == 0;
    }

    function _one(Faults memory f, bool grad) internal {
        _apply(f, grad);
        uint32 c0 = kernel.count();
        (bool ok, bytes4 err) = _trySettle();
        if (ok) {
            RecordV2 memory r = _rec(kernel.count());
            assertEq(kernel.count(), c0 + 1);
            assertEq(_has(r.flags, RecordFlags.FALLBACK), !_answers(f), "fallback exactly when nobody answers");
            assertEq(_has(r.flags, RecordFlags.GRADUATED), grad);
            if (grad) assertEq(r.allow, 0);
        } else {
            assertEq(err, KernelV2.StepFailed.selector, "a funded settle only reverts for a dead beat in the grace period");
            assertFalse(_answers(f));
            assertEq(kernel.count(), c0);
            // past the grace period the same faults give the fallback word
            vm.warp(block.timestamp + uint256(kernel.envelope().fallbackEpochs) * EPOCH);
            (ok,) = _trySettle();
            assertTrue(ok, "the fallback becomes callable");
            assertTrue(_has(_rec(kernel.count()).flags, RecordFlags.FALLBACK));
        }
        _noAllowanceLeft();
        _clear();
        _solvent();
    }

    function test_matrix_curve_regime() public {
        _fixture(W);
        for (uint256 i = 0; i < 160; i++) {
            uint256 seed = uint256(keccak256(abi.encode("curve", i)));
            _buy(alice, 1e6 + (seed % 2e7)); // small enough that the curve never graduates in this test
            if (i % 3 == 0) _revenue(500_000 * (1 + (seed >> 100) % 9));
            vm.warp(block.timestamp + EPOCH * (1 + (seed >> 200) % 3));
            _one(_faults(seed), false);
        }
        assertGt(kernel.count(), 100);
    }

    function test_matrix_graduated_regime() public {
        _fixture(W);
        _buy(alice, 500e6);
        _nextEpoch();
        _settle();
        _graduate();
        _nextEpoch();
        _settle();
        for (uint256 i = 0; i < 160; i++) {
            uint256 seed = uint256(keccak256(abi.encode("graduated", i)));
            _v2Buy(alice, 1e6 + (seed % 3e7));
            if (i % 3 == 0) _revenue(500_000 * (1 + (seed >> 100) % 9));
            vm.warp(block.timestamp + EPOCH * (1 + (seed >> 200) % 3));
            _one(_faults(seed), true);
        }
    }

    /// Any output word whatsoever, with any external fault: settle never reverts outside the grace rule.
    function testFuzz_any_output_word_and_any_fault_settles(uint256 word, uint256 seed, bool grad) public {
        word &= (uint256(1) << 112) - 1;
        _fixtureWith(ChipModel.fixedChip(8, KernelMath.outputBytes(word)), _refEnv());
        _buy(alice, 300e6);
        _revenue(7e6);
        if (grad) {
            _nextEpoch();
            _settle();
            _graduate();
            _v2Buy(bob, 10e6);
        }
        _nextEpoch();
        _one(_faults(seed), grad);
    }

    /// Kernel v1's rule for a reserve larger than what is there (a balance destroyed by Tether's owner): routing
    /// uses what is there, and nothing reverts.
    function test_reserve_is_cut_to_what_is_there() public {
        _fixture(_word(0, 0, 0, 256, 0, 1023));
        _revenue(50e6);
        _nextEpoch();
        _settle();
        assertEq(kernel.reserve(), 50e6);
        usdt.addToBlockedList(address(kernel));
        usdt.destroyBlockedFunds(address(kernel));
        usdt.removeFromBlockedList(address(kernel));
        _revenue(1e6);
        _nextEpoch();
        _settle();
        RecordV2 memory r = _rec(2);
        assertEq(r.reserveBefore, 1e6, "the reserve is cut to the balance");
        assertEq(r.inflow, 0);
    }

    /// INTERFACE-V2 8.1: an unreadable USD₮0 balance on the curve is "exactly what the books say: nothing new,
    /// nothing lost". This branch is new in v2 (v1 read its own native balance, which cannot fail). If the reserve
    /// were dropped, the next readable settle would count USD₮0 already routed as fresh inflow and pay allowance on
    /// it a second time (review B-F2; the mutant `owed + reserve` -> `owed` passed the whole suite before this test).
    function test_unreadable_usdt0_balance_on_the_curve_loses_no_reserve() public {
        _fixture(_word(0, 0, 64, 192, 0, 1023)); // 25% allowance, 75% reserve, no release asked
        _buy(alice, 100e6); // 3 USD0 of tax into the vault
        _nextEpoch();
        _settle();
        uint256 arrived = 3e6;
        uint256 reserve1 = kernel.reserve();
        uint256 cum1 = kernel.cumInflow();
        uint256 paid1 = kernel.allowPaidCum();
        assertGt(reserve1, 0);
        assertEq(paid1, arrived / 4);

        // the USD0 balance cannot be read for one settle
        usdt.setFailure(true, false, false, false);
        _nextEpoch();
        uint32 n2 = _settle();
        RecordV2 memory r2 = _rec(n2);
        assertEq(r2.inflow, 0, "nothing new while unreadable");
        assertEq(r2.reserveBefore, reserve1, "nothing lost while unreadable");
        assertEq(r2.allow, 0);
        assertEq(kernel.cumInflow(), cum1);
        assertEq(kernel.allowPaidCum(), paid1);
        assertEq(kernel.reserve(), reserve1 - r2.buyExecuted, "only a buy can move the reserve");
        usdt.setFailure(false, false, false, false);

        // readable again, nothing arrived in between
        _nextEpoch();
        uint32 n3 = _settle();
        RecordV2 memory r3 = _rec(n3);
        assertEq(r3.inflow, 0, "the reserve came back as fresh inflow");
        assertEq(r3.allow, 0, "allowance paid twice on the same USD0");
        assertEq(kernel.cumInflow(), arrived, "cumInflow counts what arrived, once");
        assertLe(uint256(kernel.allowPaidCum()) * 10_000, arrived * 2500, "more than allowCumBps of what arrived");
        assertEq(_qbal(address(kernel)), kernel.reserve() + kernel.totalCredits(address(usdt)), "books = balance");
    }

    /// The same after graduation, for the regime asset of that regime (the project token).
    function test_unreadable_token_balance_after_graduation_loses_no_reserve() public {
        _fixture(_word(0, 0, 0, 256, 0, 1023)); // everything to the reserve, no release asked
        _buy(alice, 300e6);
        _nextEpoch();
        _settle();
        _graduate();
        _nextEpoch();
        _settle(); // the latch; the token tax of the graduation buy arrives
        _v2Buy(bob, 50e6);
        // settle until the USD0 pot is spent: its buys on the pair pay token tax into the vault, which the next
        // settle claims; with the pot empty the vault ends up empty too
        for (uint256 i = 0; i < 60; i++) {
            _nextEpoch();
            _settle();
            if (_qbal(address(kernel)) == kernel.totalCredits(address(usdt)) && token.balanceOf(address(vault)) == 0) {
                break;
            }
        }
        uint256 reserve1 = kernel.reserve();
        uint256 cum1 = kernel.cumInflow();
        assertGt(reserve1, 0, "a token reserve");
        assertEq(token.balanceOf(address(vault)), 0, "nothing left to claim");

        token.setFailure(true, false, false, address(0));
        _nextEpoch();
        uint32 n2 = _settle();
        RecordV2 memory r2 = _rec(n2);
        assertTrue(_has(r2.flags, RecordFlags.GRADUATED));
        assertEq(r2.inflow, 0, "nothing new while unreadable");
        assertEq(r2.reserveBefore, reserve1, "nothing lost while unreadable");
        assertEq(kernel.cumInflow(), cum1);
        token.setFailure(false, false, false, address(0));

        _nextEpoch();
        uint32 n3 = _settle();
        assertEq(_rec(n3).inflow, 0, "the token reserve came back as fresh inflow");
        assertEq(kernel.cumInflow(), cum1);
        assertEq(
            token.balanceOf(address(kernel)),
            kernel.reserve() + kernel.lockedTokens() + kernel.totalCredits(address(token)),
            "books = balance"
        );
    }

    function test_huge_balance_is_saturated_not_reverted() public {
        _fixture(W);
        usdt.mint(address(kernel), type(uint128).max);
        usdt.mint(address(kernel), 1e30);
        _nextEpoch();
        _settle();
        assertEq(_rec(1).inflow, type(uint128).max, "saturated at 2^128 - 1");
        assertEq(_in(1).tax, 1023);
    }

    function test_epoch_counter_saturates() public {
        _fixture(W);
        vm.warp(block.timestamp + uint256(type(uint32).max) * EPOCH + 5 * EPOCH);
        _settle();
        assertEq(kernel.lastEpoch(), type(uint32).max);
        vm.expectRevert(KernelV2.EpochNotElapsed.selector);
        _settle();
    }

    function test_chipId_is_cheap_and_never_reverts() public {
        _fixture(W);
        uint256 g = gasleft();
        assertEq(kernel.chipId(), chipId);
        assertLt(g - gasleft(), 50_000, "KeeperTank's bound");
    }

    function test_settle_reverts_whenever_it_writes_no_record() public {
        _fixture(W);
        vm.expectRevert(KernelV2.EpochNotElapsed.selector);
        _settle();
        _nextEpoch();
        _killBoth(1);
        vm.expectRevert(KernelV2.StepFailed.selector);
        _settle();
        assertEq(kernel.count(), 0);
    }

    function test_views_before_and_beyond() public {
        _fixture(W);
        RecordV2 memory r = kernel.records(0);
        assertEq(r.epoch, 0);
        r = kernel.records(99);
        assertEq(r.inflow, 0);
        assertEq(kernel.quote(), address(usdt));
        assertEq(kernel.quoteShift(), 33);
        assertEq(kernel.globals().quoteShift, 33);
        assertEq(kernel.globals().quote, address(usdt));
    }
}
