// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "../Base.t.sol";
import {Kernel} from "../../src/Kernel.sol";
import {Record, Envelope, RecordFlags, IKernelMin} from "../../src/interfaces/IKernelV1.sol";
import {ChipModel, MockImplV2} from "../mocks/MockTapeOut.sol";
import {MockPair} from "../mocks/MockIgnix.sol";

/// @notice Every combination of external failures, in both regimes. The claim under test: for every
///         external-failure pattern, a sufficiently funded settle either succeeds or, when no evaluator
///         answers inside the grace period, reverts with StepFailed and applies the fallback word once the
///         grace period is over. One dead evaluator is never enough to fail a beat while the other answers.
///         No pattern can stop settlements for good, and no pattern can make the kernel hold less than it owes.
contract FailureMatrixTest is Base {
    // half to buy-and-lock, an allowance, a release every epoch
    bytes14 internal W = _word(128, 64, 48, 16, 64, 1023);
    MockPair internal pair;

    function setUp() public override {
        super.setUp();
        _fixture(W);
    }

    function _trySettle() internal returns (bool ok, bytes4 err) {
        vm.prank(keeper);
        bytes memory ret;
        (ok, ret) = address(kernel).call{gas: 40_000_000}(abi.encodeCall(IKernelMin.settle, ()));
        if (!ok && ret.length >= 4) err = bytes4(ret);
    }

    function _solvent() internal view {
        bool grad = kernel.graduated();
        assertGe(address(kernel).balance, kernel.totalCredits(NATIVE) + (grad ? 0 : kernel.reserve()), "native");
        if (!token.balanceOfReverts()) {
            assertGe(
                token.balanceOf(address(kernel)),
                kernel.totalCredits(address(token)) + kernel.lockedTokens() + (grad ? kernel.reserve() : 0),
                "tokens"
            );
        }
    }

    /// @dev evaluator failure modes worth distinguishing: fine, reverts, burns its gas, return bomb, wrong size
    function _evalMode(uint256 i) internal pure returns (uint8) {
        uint8[5] memory m = [0, 1, 2, 5, 3];
        return m[i];
    }

    // ------------------------------------------------------------------ curve regime

    /// What the evaluators do in one combination: whether the pins hold, and how each evaluator fails (0 = fine).
    struct Eval {
        bool pinsHold;
        uint8 tapeOut;
        uint8 sealedOne;
    }

    /// @dev Fifteen evaluator situations: with the pins holding, each of TapeOut's five modes against a
    ///      working and against a dead sealed evaluator (the dead one in the same mode, or reverting when
    ///      TapeOut is fine); with the pins not holding, each of the sealed evaluator's five modes, TapeOut
    ///      dead (it must not be asked).
    function _eval(uint256 i) internal pure returns (Eval memory e) {
        if (i < 5) return Eval(true, _evalMode(i), 0);
        if (i < 10) return Eval(true, _evalMode(i - 5), i == 5 ? 1 : _evalMode(i - 5));
        return Eval(false, 1, _evalMode(i - 10));
    }

    function _applyEval(Eval memory e, address v2) internal {
        if (!e.pinsHold) beacon.upgradeTo(v2);
        circuits.setStepMode(e.tapeOut);
        sealedVM.setStepMode(e.sealedOne);
    }

    /// @dev The flags the evaluators alone decide, for a settle that returned.
    function _checkEvalOutcome(Eval memory e, bool pastGrace) internal view returns (bool usedFallback) {
        uint8 flags = _rec(kernel.count()).flags;
        bool tapeOutAnswers = e.pinsHold && e.tapeOut == 0;
        bool sealedAnswers = !tapeOutAnswers && e.sealedOne == 0;
        assertEq(_has(flags, RecordFlags.SEALED), sealedAnswers, "flag 2 exactly when the sealed answer was used");
        usedFallback = !tapeOutAnswers && !sealedAnswers;
        assertEq(_has(flags, RecordFlags.FALLBACK), usedFallback, "flag 1 exactly when nobody answered");
        if (usedFallback) assertTrue(pastGrace, "the fallback word is never applied inside the grace period");
    }

    /// vault (4 modes) x Manager.tokens (6) x Manager.buyTo (4) x pause/founder (3) x evaluators (15)
    function test_matrix_curve_regime() public {
        _buy(alice, 5 ether);
        _nextEpoch();
        _settle(); // a reserve, a credit and locked tokens exist
        _buy(alice, 5 ether);
        address v2 = address(new MockImplV2());
        uint256 combos;
        uint256 fallbacks;
        for (uint256 a = 0; a < 4; a++) {
            for (uint256 b = 0; b < 6; b++) {
                for (uint256 c = 0; c < 4; c++) {
                    for (uint256 g = 0; g < 3; g++) {
                        for (uint256 d = 0; d < 15; d++) {
                            uint256 snap = vm.snapshotState();
                            vault.setMode(uint8(a));
                            manager.setTokensMode(uint8(b));
                            manager.setBuyMode(uint8(c));
                            if (g == 1) manager.setPaused(1, type(uint64).max);
                            if (g == 2) manager.setFounderRound(address(token), type(uint64).max);
                            Eval memory e = _eval(d);
                            _applyEval(e, v2);
                            bool somebodyAnswers = (e.pinsHold && e.tapeOut == 0) || e.sealedOne == 0;

                            // inside the grace period (fallbackEpochs = 4, last step at epoch 1)
                            vm.warp(block.timestamp + EPOCH);
                            (bool ok, bytes4 err) = _trySettle();
                            if (somebodyAnswers) {
                                assertTrue(ok, "an evaluator answers: the settle succeeds whatever else is broken");
                                _checkEvalOutcome(e, false);
                            } else {
                                assertFalse(ok);
                                assertEq(
                                    err, Kernel.StepFailed.selector, "no evaluator answers inside the grace period"
                                );
                                // past the grace period the same call applies the fallback
                                vm.warp(block.timestamp + 4 * EPOCH);
                                (ok,) = _trySettle();
                                assertTrue(ok, "past the grace period the fallback applies");
                                assertTrue(_checkEvalOutcome(e, true));
                                fallbacks++;
                            }
                            assertEq(kernel.count(), 2);
                            _solvent();
                            vm.revertToState(snap);
                            combos++;
                        }
                    }
                }
            }
        }
        assertEq(combos, 4 * 6 * 4 * 3 * 15);
        // nobody answers in 4 of the 5 "both dead" situations and in 4 of the 5 sealed-only ones
        assertEq(fallbacks, 4 * 6 * 4 * 3 * 8);
    }

    // ------------------------------------------------------------------ graduated regime

    /// vault (4) x router (3) x token (5) x pair reads (2) x Manager.tokens (3) x evaluators (15)
    function test_matrix_graduated_regime() public {
        _buy(alice, 10 ether);
        _nextEpoch();
        _settle();
        pair = _graduate();
        _nextEpoch();
        _settle(); // latched: a token reserve and a native pot exist
        _v2Buy(alice, 3 ether);
        address v2 = address(new MockImplV2());
        uint256 combos;
        for (uint256 a = 0; a < 4; a++) {
            for (uint256 b = 0; b < 3; b++) {
                for (uint256 c = 0; c < 5; c++) {
                    for (uint256 p = 0; p < 2; p++) {
                        for (uint256 m = 0; m < 3; m++) {
                            for (uint256 d = 0; d < 15; d++) {
                                uint256 snap = vm.snapshotState();
                                vault.setMode(uint8(a));
                                router.setMode(uint8(b));
                                token.setFailure(c == 1, c == 2, c == 3, c == 4 ? DEAD : address(0));
                                pair.setReservesRevert(p == 1);
                                manager.setTokensMode(m == 0 ? 0 : (m == 1 ? 1 : 5));
                                Eval memory e = _eval(d);
                                _applyEval(e, v2);
                                bool somebodyAnswers = (e.pinsHold && e.tapeOut == 0) || e.sealedOne == 0;

                                vm.warp(block.timestamp + EPOCH);
                                (bool ok, bytes4 err) = _trySettle();
                                if (somebodyAnswers) {
                                    assertTrue(ok, "an evaluator answers: the settle succeeds whatever else is broken");
                                    _checkEvalOutcome(e, false);
                                } else {
                                    assertFalse(ok);
                                    assertEq(err, Kernel.StepFailed.selector);
                                    vm.warp(block.timestamp + 4 * EPOCH);
                                    (ok,) = _trySettle();
                                    assertTrue(ok, "past the grace period the fallback applies");
                                    assertTrue(_checkEvalOutcome(e, true));
                                }
                                assertEq(kernel.count(), 3);
                                assertEq(_rec(3).allow, 0, "no allowance after graduation in any combination");
                                // with every dependency restored, the books are what the balances are
                                token.setFailure(false, false, false, address(0));
                                assertEq(kernel.totalCredits(address(token)), 0, "and no token credit");
                                _solvent();
                                vm.revertToState(snap);
                                combos++;
                            }
                        }
                    }
                }
            }
        }
        assertEq(combos, 4 * 3 * 5 * 2 * 3 * 15);
    }

    /// Everything dead at once, for many epochs, then everything back: nothing was lost meanwhile.
    function test_everything_dead_then_back() public {
        _buy(alice, 5 ether);
        _nextEpoch();
        _settle();
        _buy(alice, 5 ether);
        uint256 inVault = address(vault).balance;
        uint256 held = address(kernel).balance;

        vault.setMode(2);
        manager.setTokensMode(5);
        manager.setBuyMode(2);
        manager.setPairOfReverts(true);
        manager.setSnipeReverts(true);
        token.setPairMode(3); // the graduation read burns its gas
        circuits.setStepMode(2);
        beacon.setReverts(true); // the pins cannot be checked: straight to the sealed evaluator
        sealedVM.setStepMode(2);

        vm.warp(block.timestamp + 4 * EPOCH);
        for (uint256 i = 0; i < 10; i++) {
            _settle(); // never reverts: the fallback applies
            _nextEpoch();
            Record memory r = _rec(kernel.count());
            assertTrue(_has(r.flags, RecordFlags.FALLBACK));
            assertFalse(_has(r.flags, RecordFlags.SEALED), "no evaluator's answer was used");
            assertTrue(_has(r.flags, RecordFlags.CLAIM_FAILED));
            assertTrue(_has(r.flags, RecordFlags.CURVE_READ_FAILED));
            assertEq(r.buyExecuted, 0);
        }
        assertEq(address(vault).balance, inVault, "the tax waited in the vault");
        assertEq(address(kernel).balance, held, "nothing left the kernel");
        assertEq(kernel.count(), 11);

        // everything comes back
        vault.setMode(0);
        manager.setTokensMode(0);
        manager.setBuyMode(0);
        manager.setPairOfReverts(false);
        manager.setSnipeReverts(false);
        token.setPairMode(0);
        circuits.setStepMode(0);
        beacon.setReverts(false);
        sealedVM.setStepMode(0);
        _settle();
        Record memory last = _rec(kernel.count());
        assertEq(last.flags & ~RecordFlags.BUY_SHRUNK, 0, "a normal settle again");
        assertEq(last.inflow, inVault, "the waiting tax was claimed and routed");
        assertGt(last.buyExecuted, 0);
        _solvent();
    }

    // ------------------------------------------------------------------ edges

    /// A balance above 2^128 - 1 is treated as 2^128 - 1; nothing reverts.
    function test_huge_balance_is_saturated_not_reverted() public {
        vm.deal(address(kernel), type(uint256).max / 4); // forced in, far beyond any real amount
        _nextEpoch();
        _settle();
        Record memory r = _rec(1);
        assertEq(r.inflow, type(uint128).max, "inflow saturates at 128 bits");
        assertTrue(_has(r.flags, RecordFlags.BUY_SHRUNK), "the buy is still capped by the curve");
        assertGt(r.buyExecuted, 0);
        _nextEpoch();
        _settle();
        _nextEpoch();
        _settle();
        assertEq(kernel.count(), 3, "and the kernel keeps settling");
        assertEq(kernel.cumInflow(), type(uint128).max, "cumulative inflow saturates too");
    }

    /// If the kernel ever held less than its books say (it cannot happen by any route the code has), the
    /// reserve is cut to what is there: credits are honoured first and nothing reverts.
    function test_reserve_is_cut_to_what_is_there() public {
        _buy(alice, 10 ether);
        _nextEpoch();
        _settle();
        uint256 credits = kernel.totalCredits(NATIVE);
        uint256 reserve = kernel.reserve();
        assertGt(reserve, 0);
        vm.prank(address(kernel));
        (bool ok,) = address(0xdead).call{value: reserve / 2 + address(vault).balance}(""); // value vanishes
        assertTrue(ok);
        vm.deal(address(vault), 0);
        _nextEpoch();
        _settle();
        Record memory r = _rec(2);
        assertLe(r.reserveBefore, reserve - reserve / 2, "the reserve was cut to what the kernel holds");
        assertEq(r.inflow, 0);
        assertGe(address(kernel).balance, kernel.totalCredits(NATIVE) + kernel.reserve());
        assertEq(kernel.creditOf(payee, NATIVE), credits + r.allow, "credits are untouched");
        kernel.withdrawCredit(payee, NATIVE);
    }

    /// The epoch counter saturates instead of overflowing (about 40,000 years at the shortest epoch).
    function test_epoch_counter_saturates() public {
        vm.warp(block.timestamp + uint256(EPOCH) * (uint256(type(uint32).max) + 10));
        assertEq(kernel.epochNow(), type(uint32).max);
        _settle();
        assertEq(_rec(1).epoch, type(uint32).max);
        assertEq(_in(1).dt, 15);
        vm.warp(block.timestamp + EPOCH);
        vm.expectRevert(Kernel.EpochNotElapsed.selector);
        kernel.settle();
    }

    /// A native pot too small to buy a single base unit of token is skipped, not failed.
    function test_native_dust_after_graduation_is_skipped() public {
        _buy(alice, 10 ether);
        _nextEpoch();
        _settle();
        pair = _graduate();
        for (uint256 i = 0; i < 12; i++) {
            _nextEpoch();
            _settle();
        }
        uint256 credits = kernel.totalCredits(NATIVE);
        assertEq(address(kernel).balance, credits, "the pot is empty");
        vm.deal(address(kernel), credits + 1); // one wei arrives
        // make the token expensive enough that one wei of OKB buys nothing
        vm.deal(whale, 1_000_000 ether);
        _v2Buy(whale, 900_000 ether);
        _nextEpoch();
        uint256 dead0 = token.balanceOf(DEAD);
        _settle();
        Record memory r = _rec(kernel.count());
        assertEq(token.balanceOf(DEAD), dead0 + r.buyExecuted, "only the burn leg reached 0xdEaD");
        assertTrue(_has(r.flags, RecordFlags.BUY_SKIPPED), "a swap that would deliver nothing is skipped");
        assertFalse(_has(r.flags, RecordFlags.BUY_FAILED));
        assertEq(address(kernel).balance, credits + 1, "the wei waits");
    }

    /// The only token credit kernel v1 can make is the sink's, on a kernel with buys disabled.
    function test_token_credit_withdrawal_fails_cleanly_when_the_token_refuses() public {
        Envelope memory e = _env();
        e.buyEnabled = false;
        e.sink = sinkAddr;
        Built memory b = _build(ChipModel.fixedChip(8, W), 2200, e, 300, bytes32("sink"));
        kernel = b.kernel;
        token = b.token;
        vault = b.vault;
        pair = _graduate();
        _v2Buy(alice, 2 ether);
        _nextEpoch();
        _settle();
        uint256 credit = kernel.creditOf(sinkAddr, address(token));
        assertGt(credit, 0);
        token.setFailure(false, false, true, address(0)); // transfer returns false
        vm.expectRevert(Kernel.PayFailed.selector);
        kernel.withdrawCredit(sinkAddr, address(token));
        token.setFailure(false, true, false, address(0)); // transfer reverts
        vm.expectRevert(Kernel.PayFailed.selector);
        kernel.withdrawCredit(sinkAddr, address(token));
        assertEq(kernel.creditOf(sinkAddr, address(token)), credit, "the credit is intact");
        token.setFailure(false, false, false, address(0));
        assertEq(kernel.withdrawCredit(sinkAddr, address(token)), credit);
    }

    // ------------------------------------------------------------------ what the KeeperTank relies on

    function test_chipId_is_cheap_and_never_reverts() public {
        uint256 g0 = gasleft();
        uint256 id = kernel.chipId{gas: 50_000}();
        assertLt(g0 - gasleft(), 50_000);
        assertEq(id, chipId);
        // also before bind
        vm.prank(launcher);
        uint256 other = fab.tapeoutChip(ChipModel.fixedChip(8, W), 200);
        Kernel k = Kernel(payable(factory.create(_env(), other, "unbound")));
        assertEq(k.chipId{gas: 50_000}(), other);
    }

    function test_settle_reverts_whenever_it_writes_no_record() public {
        vm.prank(launcher);
        uint256 other = fab.tapeoutChip(ChipModel.fixedChip(8, W), 200);
        Kernel k = Kernel(payable(factory.create(_env(), other, "unbound")));
        vm.expectRevert(Kernel.NotBound.selector);
        k.settle();

        vm.expectRevert(Kernel.EpochNotElapsed.selector);
        kernel.settle();

        _nextEpoch();
        (bool ok, bytes memory ret) = address(kernel).call{gas: 1_000_000}(abi.encodeCall(IKernelMin.settle, ()));
        assertFalse(ok);
        assertEq(bytes4(ret), Kernel.InsufficientGas.selector);

        _killBoth(1);
        vm.expectRevert(Kernel.StepFailed.selector);
        kernel.settle();
        assertEq(kernel.count(), 0);
    }

    function test_views_before_and_beyond() public view {
        assertEq(kernel.count(), 0);
        assertEq(kernel.epochNow(), 0);
        Record memory z = kernel.records(0);
        assertEq(abi.encode(z), abi.encode(kernel.records(5)), "records out of range are all zero");
        assertEq(z.epoch, 0);
        assertEq(z.stateAfter, bytes32(0));
        (uint128 a, uint128 b) = kernel.cums(3);
        assertEq(a + b, 0);
        assertEq(kernel.state(), bytes32(0));
        assertEq(kernel.reserve(), 0);
        assertEq(kernel.lockedTokens(), 0);
        assertFalse(kernel.graduated());
        assertEq(kernel.pair(), address(0));
        assertEq(kernel.creditOf(payee, NATIVE), 0);
        assertEq(z.nativeIn, 0);
        assertEq(abi.encode(z).length, 14 * 32, "a record is fourteen words: nativeIn is the last");
    }
}
