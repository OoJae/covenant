// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "../Base.t.sol";
import {Kernel} from "../../src/Kernel.sol";
import {Lens} from "../../src/Lens.sol";
import {KernelMath} from "../../src/KernelMath.sol";
import {Record, Envelope, RecordFlags} from "../../src/interfaces/IKernelV1.sol";
import {ChipModel, MockImplV2} from "../mocks/MockTapeOut.sol";

/// @notice The Lens: replay, counterfactual totals, shadow runs, state-matters and preflight.
contract LensTest is Base {
    bytes14 internal A = _word(256, 0, 0, 0, 0, 1023); // everything to buy-and-lock
    bytes14 internal B = _word(0, 0, 48, 208, 64, 1023); // allowance and reserve, release a quarter
    bytes14 internal GLUTTON = _word(0, 0, 256, 0, 256, 1023); // demands everything

    function setUp() public override {
        super.setUp();
        // a chip whose route depends on its state: word A from even states, word B from odd ones
        _fixtureWith(ChipModel.toggleChip(1, A, B), _env());
    }

    /// @dev Six settles on the curve with trades in between, one of them with a failing buy.
    function _history() internal {
        for (uint256 i = 0; i < 6; i++) {
            _buy(i % 2 == 0 ? alice : bob, (i + 1) * 1 ether);
            if (i == 3) manager.setBuyMode(1);
            _nextEpoch();
            _settle();
            manager.setBuyMode(0);
        }
    }

    // ------------------------------------------------------------------ replay

    function test_replay_every_record_on_both_evaluators() public {
        _history();
        for (uint32 n = 1; n <= kernel.count(); n++) {
            Lens.Replay memory p = lens.replay(address(kernel), n);
            assertTrue(p.ok, "replay on the recorded evaluator");
            assertFalse(p.sealedUsed);
            Lens.Replay memory t = lens.replayOn(address(kernel), n, false);
            Lens.Replay memory s = lens.replayOn(address(kernel), n, true);
            assertTrue(t.ok && s.ok, "both evaluators reproduce the record");
            assertEq(t.outputs, s.outputs);
            assertEq(t.stateAfter, s.stateAfter);
            assertEq(t.outputs, _rec(n).outputs);
            assertTrue(t.ran && t.outputsMatch && t.stateMatch && t.amountsMatch && t.inputsMatch);
        }
        (uint32 next, uint32 firstBad) = lens.replayRange(address(kernel), 1, kernel.count(), true);
        assertEq(next, kernel.count() + 1);
        assertEq(firstBad, 0);
    }

    function test_replay_a_sealed_record_and_a_fallback_record() public {
        _buy(alice, 3 ether);
        beacon.upgradeTo(address(new MockImplV2()));
        _nextEpoch();
        _settle(); // record 1: sealed
        sealedVM.setStepMode(1);
        _buy(alice, 3 ether);
        vm.warp(block.timestamp + 4 * EPOCH);
        _settle(); // record 2: fallback
        sealedVM.setStepMode(0);
        _nextEpoch();
        _settle(); // record 3: sealed again, state continues from record 1

        Lens.Replay memory p = lens.replay(address(kernel), 1);
        assertTrue(p.ok && p.sealedUsed);
        p = lens.replay(address(kernel), 2);
        assertTrue(p.ok, "a fallback record replays as the fallback word with the state unchanged");
        assertEq(p.outputs, _word(224, 0, 32, 0, 128, 1023));
        assertEq(p.stateAfter, _rec(1).stateAfter);
        p = lens.replay(address(kernel), 3);
        assertTrue(p.ok);
    }

    /// A record written from the sealed evaluator's answer because TapeOut's step failed (the pins held):
    /// `replay` goes to the evaluator the record names, and TapeOut, once it answers again, agrees.
    function test_replay_a_record_the_sealed_evaluator_answered_after_tapeout_failed() public {
        _buy(alice, 3 ether);
        _nextEpoch();
        _settle(); // record 1: TapeOut
        circuits.setStepMode(1);
        _buy(alice, 3 ether);
        _nextEpoch();
        _settle(); // record 2: TapeOut failed, the sealed evaluator answered
        assertTrue(_has(_rec(2).flags, RecordFlags.SEALED));
        assertFalse(_has(_rec(2).flags, RecordFlags.FALLBACK));

        Lens.Replay memory p = lens.replay(address(kernel), 2);
        assertTrue(p.ok && p.sealedUsed, "replayed on the sealed evaluator, as recorded");
        assertFalse(lens.replayOn(address(kernel), 2, false).ran, "TapeOut still does not answer");
        circuits.setStepMode(0);
        p = lens.replayOn(address(kernel), 2, false);
        assertTrue(p.ok, "and when it does, it computes the same record");
        assertEq(p.outputs, _rec(2).outputs);
        assertEq(p.stateAfter, _rec(2).stateAfter);
        // the toggle chip's state ran through both evaluators: A, then B
        assertEq(_rec(1).outputs, A);
        assertEq(_rec(2).outputs, B);
    }

    function test_replay_has_teeth() public {
        _history();
        // the stored state of record 3 is tampered with: record 3 no longer matches the evaluator, and
        // record 4 no longer follows from it
        bytes32 slot = keccak256(abi.encode(uint256(3), _recSlot()));
        vm.store(address(kernel), bytes32(uint256(slot) + 2), bytes32(uint256(0xbad)));
        Lens.Replay memory p = lens.replay(address(kernel), 3);
        assertFalse(p.ok);
        assertFalse(p.stateMatch);
        assertTrue(p.outputsMatch && p.amountsMatch, "only the state was changed");
        assertFalse(lens.replay(address(kernel), 4).ok);
        (, uint32 firstBad) = lens.replayRange(address(kernel), 1, 6, false);
        assertEq(firstBad, 3);

        // a tampered amount is caught by the routing check alone
        bytes32 slot5 = keccak256(abi.encode(uint256(5), _recSlot()));
        bytes32 w3 = vm.load(address(kernel), bytes32(uint256(slot5) + 3));
        vm.store(address(kernel), bytes32(uint256(slot5) + 3), bytes32(uint256(w3) + (uint256(1) << 128)));
        p = lens.replay(address(kernel), 5);
        assertFalse(p.amountsMatch, "allow is one wei more than the envelope routing gives");
    }

    /// @dev storage slot of the kernel's record mapping, found by probing rather than assumed
    function _recSlot() internal view returns (uint256 s) {
        bytes32 stateAfter = _rec(1).stateAfter;
        for (s = 0; s < 30; s++) {
            bytes32 slot = keccak256(abi.encode(uint256(1), s));
            if (vm.load(address(kernel), bytes32(uint256(slot) + 2)) == stateAfter && stateAfter != bytes32(0)) {
                return s;
            }
        }
        revert("record mapping slot not found");
    }

    function test_replayRange_pages_when_gas_is_short() public {
        _history();
        circuits.setStepBurn(5_000_000); // a real 2,200-gate step costs about this much
        // room for a few steps only
        (uint32 next, uint32 firstBad) = lens.replayRange{gas: 25_000_000}(address(kernel), 1, 6, false);
        assertEq(firstBad, 0);
        assertGt(next, 1);
        assertLt(next, 7, "stopped early instead of running out of gas");
        (uint32 next2,) = lens.replayRange(address(kernel), next, 6, false);
        assertEq(next2, 7);
    }

    function test_range_checks() public {
        _history();
        vm.expectRevert(Lens.BadRange.selector);
        lens.replay(address(kernel), 0);
        vm.expectRevert(Lens.BadRange.selector);
        lens.replay(address(kernel), 7);
        vm.expectRevert(Lens.BadRange.selector);
        lens.replayRange(address(kernel), 3, 2, false);
        vm.expectRevert(Lens.BadRange.selector);
        lens.counterfactual(address(kernel), 1, 7);
    }

    // ------------------------------------------------------------------ counterfactual

    function test_counterfactual_totals() public {
        _history();
        (Lens.Counterfactual memory c, Lens.Counterfactual memory g, Lens.CfCursor memory next) =
            lens.counterfactual(address(kernel), 1, 6);
        assertEq(g.chip.inflow, 0, "nothing after graduation");

        uint256 inflow;
        uint256 allow;
        uint256 buy;
        uint256 exec;
        for (uint32 n = 1; n <= 6; n++) {
            Record memory r = _rec(n);
            inflow += r.inflow;
            allow += r.allow;
            buy += r.buyDecided;
            exec += r.buyExecuted;
        }
        assertEq(c.chip.inflow, inflow);
        assertEq(c.chip.allow, allow);
        assertEq(c.chip.buy, buy);
        assertEq(c.chipBuyExecuted, exec);
        assertEq(c.chip.reserveEnd, kernel.reserve(), "the chip's reserve after record 6");
        assertEq(c.chip.allow, kernel.creditOf(payee, NATIVE));

        // always-buy: every inflow bought at once
        assertEq(c.alwaysBuy.inflow, inflow);
        assertEq(c.alwaysBuy.buy, inflow);
        assertEq(c.alwaysBuy.allow, 0);

        // fixed split = the envelope's fallback word (224 buy, 32 allowance, release 128/256) on every epoch
        assertEq(c.fixedSplit.inflow, inflow);
        uint256 reserve;
        uint256 fAllow;
        uint256 fBuy;
        for (uint32 n = 1; n <= 6; n++) {
            uint256 x = _rec(n).inflow;
            uint256 a = (x * 32) / 256;
            uint256 b = (x * 224) / 256;
            uint256 rel = (reserve * 128) / 256;
            reserve = reserve - rel + (x - a - b);
            fAllow += a;
            fBuy += b + rel;
        }
        assertEq(c.fixedSplit.allow, fAllow);
        assertEq(c.fixedSplit.buy, fBuy);
        assertEq(c.fixedSplit.reserveEnd, reserve);
        assertEq(next.reserve, reserve);
        // conservation in each baseline
        assertEq(c.fixedSplit.allow + c.fixedSplit.buy + c.fixedSplit.reserveEnd, inflow);
    }

    function test_counterfactual_pages_add_up() public {
        _history();
        (Lens.Counterfactual memory whole,,) = lens.counterfactual(address(kernel), 1, 6);
        (Lens.Counterfactual memory p1,, Lens.CfCursor memory cur) = lens.counterfactual(address(kernel), 1, 3);
        (Lens.Counterfactual memory p2,,) = lens.counterfactualFrom(address(kernel), 4, 6, cur);
        assertEq(p1.fixedSplit.allow + p2.fixedSplit.allow, whole.fixedSplit.allow);
        assertEq(p1.fixedSplit.buy + p2.fixedSplit.buy, whole.fixedSplit.buy);
        assertEq(p2.fixedSplit.reserveEnd, whole.fixedSplit.reserveEnd);
        assertEq(p1.chip.buy + p2.chip.buy, whole.chip.buy);
    }

    // ------------------------------------------------------------------ shadow run

    function test_shadow_of_the_same_chip_reproduces_the_decisions() public {
        // no failing buy here: a shadow run assumes decided buys execute
        for (uint256 i = 0; i < 5; i++) {
            _buy(alice, 1 ether);
            _nextEpoch();
            _settle();
        }
        Lens.ShadowCursor memory cur;
        (Lens.ShadowStep[] memory steps, Lens.ShadowCursor memory next, uint32 nextN) =
            lens.shadowChip(address(kernel), chipId, 1, 5, cur);
        assertEq(steps.length, 5);
        assertEq(nextN, 6);
        for (uint32 n = 1; n <= 5; n++) {
            Record memory r = _rec(n);
            Lens.ShadowStep memory s = steps[n - 1];
            assertTrue(s.ran);
            assertEq(s.n, n);
            assertEq(s.outputs, r.outputs, "same chip, same decisions");
            assertEq(s.inputs, r.inputs, "and it saw the same inputs, RES included");
            assertEq(s.allow, r.allow);
            assertEq(s.buyDecided, r.buyDecided);
            assertEq(s.clampBits, r.clampBits);
        }
        assertEq(next.state, kernel.state());
        assertEq(next.reserve, kernel.reserve());
    }

    /// The hostile-chip demonstration: a chip that demands everything, run for free over a real token's
    /// recorded inflows, is clipped to the envelope on every epoch.
    function test_shadow_of_a_glutton_chip_is_clipped_by_the_envelope() public {
        _history();
        vm.prank(bob);
        uint256 glutton = fab.tapeoutChip(ChipModel.fixedChip(1, GLUTTON), 115);
        Lens.ShadowCursor memory cur;
        (Lens.ShadowStep[] memory steps,,) = lens.shadowChip(address(kernel), glutton, 1, 6, cur);
        uint256 allowTotal;
        uint256 inflowTotal;
        for (uint32 n = 1; n <= 6; n++) {
            Lens.ShadowStep memory s = steps[n - 1];
            assertEq(s.outputs, GLUTTON);
            assertEq(s.clampBits & KernelMath.K2, KernelMath.K2, "K2: allowance share clipped to capT");
            if (n > 1) assertEq(s.clampBits & KernelMath.K3, KernelMath.K3, "K3: release clipped to relMax");
            assertLe(s.allow, (uint256(_rec(n).inflow) * 64) / 256, "never above capT of the inflow");
            allowTotal += s.allow;
            inflowTotal += _rec(n).inflow;
        }
        assertLe(allowTotal, (inflowTotal * 2500) / 10_000, "never above the lifetime cap");
    }

    function test_shadow_of_any_netlist_through_the_sealed_evaluator() public {
        _history();
        // a netlist that was never taped out: stored at an SSTORE2 pointer, evaluated for free
        bytes memory nl = ChipModel.fixedChip(1, GLUTTON);
        address ptr = makeAddr("pointer");
        vm.etch(ptr, bytes.concat(hex"00", nl));
        Lens.ShadowCursor memory cur;
        (Lens.ShadowStep[] memory steps,, uint32 nextN) = lens.shadowSnapshot(address(kernel), ptr, 1, 6, cur);
        assertEq(nextN, 7);
        assertEq(steps.length, 6);
        assertEq(steps[5].outputs, GLUTTON);
        assertTrue(steps[0].ran);
    }

    /// A shadow chip may be as large as the factory allows, so it is stepped with the gas the factory gives
    /// TapeOut's evaluator for the largest chip: 200,000 + 2,600 * 3,400 + 800 * 256.
    function test_shadow_chip_gets_the_gas_of_the_largest_chip() public {
        _history();
        vm.prank(bob);
        uint256 big = fab.tapeoutChip(ChipModel.fixedChip(256, GLUTTON), 3400);
        uint256 shadowGas = 200_000 + 2_600 * 3_400 + 800 * 256;
        Lens.ShadowCursor memory cur;
        circuits.setStepBurn(shadowGas - 40_000);
        (Lens.ShadowStep[] memory steps,,) = lens.shadowChip(address(kernel), big, 1, 1, cur);
        assertTrue(steps[0].ran, "just inside");
        assertEq(steps[0].outputs, GLUTTON);
        circuits.setStepBurn(shadowGas + 1);
        (steps,,) = lens.shadowChip(address(kernel), big, 1, 1, cur);
        assertFalse(steps[0].ran, "just outside: the fallback word is applied, as a kernel would");
        assertEq(steps[0].outputs, _word(224, 0, 32, 0, 128, 1023));
    }

    function test_shadow_sees_its_own_reserve() public {
        _history();
        // a hoarding chip: its reserve grows while the real chip's does not, and RES in its inputs says so
        vm.prank(bob);
        uint256 hoarder = fab.tapeoutChip(ChipModel.fixedChip(1, _word(0, 0, 0, 256, 0, 1023)), 115);
        Lens.ShadowCursor memory cur;
        (Lens.ShadowStep[] memory steps, Lens.ShadowCursor memory next,) =
            lens.shadowChip(address(kernel), hoarder, 1, 6, cur);
        uint256 res6 = (KernelMath.inputWord(steps[5].inputs) >> 40) & 0x3ff;
        assertGt(res6, _in(6).res, "the shadow's RES is its own, larger, reserve");
        assertGt(next.reserve, kernel.reserve());
        // the floor still forces a release once the hoard passes floorMin
        assertEq(steps[5].clampBits & KernelMath.K5, KernelMath.K5);
        assertGt(steps[5].buyDecided, 0);
    }

    function test_shadow_pages_with_a_cursor() public {
        _history();
        Lens.ShadowCursor memory cur;
        (Lens.ShadowStep[] memory all, Lens.ShadowCursor memory endAll,) =
            lens.shadowChip(address(kernel), chipId, 1, 6, cur);
        (Lens.ShadowStep[] memory p1, Lens.ShadowCursor memory mid, uint32 nextN) =
            lens.shadowChip(address(kernel), chipId, 1, 2, cur);
        assertEq(nextN, 3);
        (Lens.ShadowStep[] memory p2, Lens.ShadowCursor memory endPaged,) =
            lens.shadowChip(address(kernel), chipId, 3, 6, mid);
        assertEq(p1.length + p2.length, all.length);
        assertEq(p2[3].outputs, all[5].outputs);
        assertEq(endPaged.state, endAll.state);
        assertEq(endPaged.reserve, endAll.reserve);
        assertEq(endPaged.allowPaid, endAll.allowPaid);
    }

    function test_shadow_of_a_broken_chip_applies_the_fallback() public {
        _history();
        address ptr = makeAddr("empty pointer"); // no code: the sealed evaluator rejects it
        Lens.ShadowCursor memory cur;
        (Lens.ShadowStep[] memory steps,,) = lens.shadowSnapshot(address(kernel), ptr, 1, 2, cur);
        assertFalse(steps[0].ran);
        assertEq(steps[0].outputs, _word(224, 0, 32, 0, 128, 1023));
    }

    // ------------------------------------------------------------------ across graduation

    /// Replay, counterfactual and shadow run over a history that crosses graduation: totals restart with
    /// the regime, and the two regimes are reported in their own units.
    function test_lens_across_graduation() public {
        for (uint256 i = 0; i < 3; i++) {
            _buy(alice, 2 ether);
            _nextEpoch();
            _settle();
        }
        _graduate();
        for (uint256 i = 0; i < 4; i++) {
            _v2Buy(bob, 1 ether);
            _nextEpoch();
            _settle();
        }
        assertEq(kernel.count(), 7);
        for (uint32 n = 1; n <= 7; n++) {
            assertTrue(lens.replayOn(address(kernel), n, false).ok, "replay on TapeOut");
            assertTrue(lens.replayOn(address(kernel), n, true).ok, "replay on the sealed evaluator");
            assertEq(_has(_rec(n).flags, RecordFlags.GRADUATED), n > 3);
        }

        (Lens.Counterfactual memory c, Lens.Counterfactual memory g,) = lens.counterfactual(address(kernel), 1, 7);
        uint256 curveInflow;
        uint256 gradInflow;
        uint256 gradAllow;
        for (uint32 n = 1; n <= 7; n++) {
            Record memory r = _rec(n);
            if (n <= 3) curveInflow += r.inflow;
            else (gradInflow, gradAllow) = (gradInflow + r.inflow, gradAllow + r.allow);
        }
        assertEq(c.chip.inflow, curveInflow, "curve totals are native OKB");
        assertEq(g.chip.inflow, gradInflow, "graduated totals are project tokens");
        assertEq(g.chip.allow, gradAllow);
        assertEq(gradAllow, 0, "no allowance after graduation, although the chip's word B asks for 48/256");
        assertGt(c.chip.allow, 0, "it was paid on the curve");
        assertGt(gradInflow, 0);
        assertEq(g.alwaysBuy.buy, gradInflow);
        // the fixed-split baseline restarts its reserve at graduation, and its fallback word (32/256 to the
        // allowance) pays no allowance there either
        assertEq(g.fixedSplit.allow, 0, "the fixed split pays no allowance after graduation");
        assertGt(c.fixedSplit.allow, 0);
        assertEq(g.fixedSplit.buy + g.fixedSplit.reserveEnd, gradInflow);
        assertEq(g.chip.reserveEnd, kernel.reserve());

        // a shadow run of the same chip reproduces the token-regime decisions too
        Lens.ShadowCursor memory cur;
        (Lens.ShadowStep[] memory steps, Lens.ShadowCursor memory next,) =
            lens.shadowChip(address(kernel), chipId, 1, 7, cur);
        bool sawB;
        for (uint32 n = 4; n <= 7; n++) {
            assertEq(steps[n - 1].outputs, _rec(n).outputs);
            assertEq(steps[n - 1].allow, _rec(n).allow);
            assertEq(steps[n - 1].allow, 0, "the shadow run pays no allowance after graduation either");
            assertEq(steps[n - 1].buyDecided, _rec(n).buyDecided);
            assertEq(steps[n - 1].clampBits, _rec(n).clampBits);
            if (_rec(n).outputs == B && _rec(n).inflow != 0) sawB = true;
        }
        assertTrue(sawB, "a graduated record whose word asked for an allowance was among them");
        assertTrue(next.grad);
        assertEq(next.reserve, kernel.reserve());
        assertEq(next.allowPaid, 0);

        // a glutton chip shadowed over the same history: clipped by K2 on the curve, and simply unpaid after
        // graduation, where no allowance clamp is evaluated
        vm.prank(bob);
        uint256 glutton = fab.tapeoutChip(ChipModel.fixedChip(1, GLUTTON), 115);
        (steps,,) = lens.shadowChip(address(kernel), glutton, 1, 7, cur);
        for (uint32 n = 1; n <= 7; n++) {
            Lens.ShadowStep memory st = steps[n - 1];
            if (n <= 3) {
                assertEq(st.clampBits & KernelMath.K2, KernelMath.K2);
                if (_rec(n).inflow != 0) assertGt(st.allow, 0);
            } else {
                assertEq(st.clampBits & (KernelMath.K2 | KernelMath.K2C | KernelMath.K2L), 0);
                assertEq(st.allow, 0);
            }
        }
    }

    function test_replay_reports_an_evaluator_that_does_not_answer() public {
        _history();
        circuits.setStepMode(1);
        Lens.Replay memory p = lens.replayOn(address(kernel), 2, false);
        assertFalse(p.ran);
        assertFalse(p.ok);
        assertTrue(p.amountsMatch && p.inputsMatch, "the checks that need no evaluator still pass");
        assertTrue(lens.replayOn(address(kernel), 2, true).ok, "the sealed evaluator still reproduces it");
        circuits.setStepMode(4); // an answer of the wrong size
        assertFalse(lens.replayOn(address(kernel), 2, false).ran);
    }

    // ------------------------------------------------------------------ state matters

    function test_stateMatters_same_inputs_two_states_two_routes() public {
        // two zero-inflow settles: identical inputs except the state
        _nextEpoch();
        _settle();
        _nextEpoch();
        _settle();
        assertEq(_rec(1).inputs, _rec(2).inputs, "identical input words");
        assertTrue(_rec(1).outputs != _rec(2).outputs, "different routes: only the state differs");

        (bool matters, bytes14 withState, bytes14 withZero) = lens.stateMatters(address(kernel), 2);
        assertTrue(matters, "the stored state changed the route of settle 2");
        assertEq(withState, B);
        assertEq(withZero, A);
        (matters,,) = lens.stateMatters(address(kernel), 1);
        assertFalse(matters, "settle 1 started from the zero state");
        // against the state before record 2 (which is the state after record 1)
        (matters,,) = lens.stateMattersVs(address(kernel), 3 - 1, _rec(1).stateAfter);
        assertFalse(matters, "same state, same route");
    }

    function test_stateMatters_false_for_a_stateless_route() public {
        Built memory b = _build(ChipModel.fixedChip(8, A), 200, _env(), 300, bytes32("fixed"));
        vm.warp(block.timestamp + EPOCH);
        b.kernel.settle();
        vm.warp(block.timestamp + EPOCH);
        b.kernel.settle();
        (bool matters,,) = lens.stateMatters(address(b.kernel), 2);
        assertFalse(matters, "a constant chip's counter state does not change its route");
    }

    // ------------------------------------------------------------------ preflight

    function test_preflight() public {
        Lens.Preflight memory p = lens.preflight(address(kernel));
        assertTrue(p.tapeoutRan && p.sealedRan && p.agree);
        assertFalse(p.sealedModeNow);
        // the toggle chip of this fixture: 2,200 records, 1 latch
        assertEq(p.stepFloor, 200_000 + 2_600 * 2200 + 800 * 1);
        assertEq(p.sealedFloor, 40_000 + 200 * 2199 + 400 * 1);
        assertEq(p.minSettleGas, kernel.minSettleGas());
        assertLt(p.tapeoutGas, p.stepFloor);
        assertLt(p.sealedGas, p.sealedFloor);

        // an evaluator that cannot run the chip inside the gas the kernel gives it is found before launch.
        // Each is stepped with its own amount: the sealed evaluator fails just above sealedFloor, although
        // that is far below what TapeOut's evaluator is given
        sealedVM.setStepBurn(p.sealedFloor + 1);
        p = lens.preflight(address(kernel));
        assertTrue(p.tapeoutRan);
        assertFalse(p.sealedRan);
        assertFalse(p.agree);
        sealedVM.setStepBurn(p.sealedFloor - 40_000);
        assertTrue(lens.preflight(address(kernel)).sealedRan, "just inside its own allowance");
        // and TapeOut's is given stepFloor, not the sealed evaluator's smaller amount
        sealedVM.setStepBurn(0);
        circuits.setStepBurn(p.stepFloor - 40_000);
        p = lens.preflight(address(kernel));
        assertTrue(p.tapeoutRan && p.sealedRan && p.agree);
        circuits.setStepBurn(p.stepFloor + 1);
        assertFalse(lens.preflight(address(kernel)).tapeoutRan);
    }

    /// Replay steps each evaluator with the gas a settle gives it: a record replays on the sealed evaluator
    /// only if the sealed evaluator fits sealedFloor.
    function test_replay_gives_each_evaluator_its_own_gas() public {
        _buy(alice, 1 ether);
        _nextEpoch();
        _settle();
        uint256 sealedFloor = kernel.globals().sealedFloor;
        sealedVM.setStepBurn(sealedFloor - 40_000);
        assertTrue(lens.replayOn(address(kernel), 1, true).ok);
        sealedVM.setStepBurn(sealedFloor + 1);
        assertFalse(lens.replayOn(address(kernel), 1, true).ran);
        assertTrue(lens.replayOn(address(kernel), 1, false).ok, "TapeOut is not affected");
    }
}
