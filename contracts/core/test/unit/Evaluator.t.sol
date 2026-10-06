// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "../Base.t.sol";
import {Kernel} from "../../src/Kernel.sol";
import {KernelMath} from "../../src/KernelMath.sol";
import {Globals} from "../../src/interfaces/IKernelExt.sol";
import {Record, Envelope, RecordFlags} from "../../src/interfaces/IKernelV1.sol";
import {ChipModel, MockImplV2} from "../mocks/MockTapeOut.sol";

/// @notice The evaluator call: which evaluator is asked and in which order, what counts as a failure, the
///         grace period and the fallback word.
contract EvaluatorTest is Base {
    bytes14 internal W = _word(128, 64, 48, 16, 0, 1023);

    function setUp() public override {
        super.setUp();
        _fixture(W);
    }

    /// @dev A settle that must succeed, with the number of times each evaluator must have been asked.
    function _settleExpecting(uint256 tapeOutAsked, uint256 sealedAsked) internal {
        (bool ok,, uint256 t, uint256 s) = _settleAsked();
        assertTrue(ok, "the settle returns");
        assertEq(t, tapeOutAsked, "times TapeOut's step was asked");
        assertEq(s, sealedAsked, "times the sealed evaluator was asked");
    }

    // ------------------------------------------------------------------ evaluator choice

    function test_tapeout_is_used_while_the_pins_hold() public {
        (address vm_, bool sealedMode) = kernel.evaluator();
        assertEq(vm_, address(circuits));
        assertFalse(sealedMode);
        _nextEpoch();
        _settleExpecting(1, 0); // TapeOut answered: the sealed evaluator is not asked at all
        assertFalse(_has(_rec(1).flags, RecordFlags.SEALED));
    }

    function test_sealed_when_beacon_points_elsewhere_and_back_when_restored() public {
        address v2 = address(new MockImplV2());
        beacon.upgradeTo(v2);
        (address vm_, bool sealedMode) = kernel.evaluator();
        assertEq(vm_, address(sealedVM));
        assertTrue(sealedMode);
        _nextEpoch();
        _settleExpecting(0, 1); // the pins do not hold: the sealed evaluator is asked directly
        Record memory r = _rec(1);
        assertTrue(_has(r.flags, RecordFlags.SEALED), "flag 2");
        assertEq(r.outputs, W, "the sealed evaluator runs the same chip");
        assertEq(KernelMath.stateBits(kernel.state()), 1);

        // the check runs on every settle: there is no switch to flip and none to forget
        beacon.upgradeTo(address(impl));
        _nextEpoch();
        _settleExpecting(1, 0);
        assertFalse(_has(_rec(2).flags, RecordFlags.SEALED));
        assertEq(KernelMath.stateBits(kernel.state()), 2, "state continues across evaluators");
    }

    function test_sealed_when_beacon_cannot_be_read() public {
        beacon.setReverts(true);
        (, bool sealedMode) = kernel.evaluator();
        assertTrue(sealedMode);
    }

    function test_sealed_when_implementation_code_changes() public {
        vm.etch(address(impl), hex"6001600055"); // same address, different code
        (, bool sealedMode) = kernel.evaluator();
        assertTrue(sealedMode);
    }

    /// An upgrade that rewrites a chip's netlist and then restores the old implementation leaves the beacon
    /// and the code hash exactly as pinned. The netlist hash check still sees it.
    function test_sealed_when_netlist_is_rewritten_under_an_unchanged_implementation() public {
        bytes14 evil = _word(0, 0, 256, 0, 256, 1023);
        circuits.rewriteNetlist(chipId, ChipModel.fixedChip(64, evil));
        (, bool sealedMode) = kernel.evaluator();
        assertTrue(sealedMode);
        _buy(alice, 1 ether);
        _nextEpoch();
        _settleExpecting(0, 1); // the rewritten netlist is never run
        Record memory r = _rec(1);
        assertTrue(_has(r.flags, RecordFlags.SEALED));
        assertEq(r.outputs, W, "the kernel ran the netlist that was taped out, not the rewritten one");
        assertEq(r.clampBits, 0);
    }

    function test_sealed_when_netlist_length_changes() public {
        circuits.rewriteNetlist(chipId, bytes.concat(ChipModel.fixedChip(64, W), hex"00"));
        (, bool sealedMode) = kernel.evaluator();
        assertTrue(sealedMode);
    }

    /// `step` interprets the netlist through the stored pin counts, so they are pinned too.
    function test_sealed_when_pin_counts_are_rewritten() public {
        circuits.rewriteInfo(chipId, 95, 112, 64, 2200);
        (, bool sealedMode) = kernel.evaluator();
        assertTrue(sealedMode, "nIn");
        circuits.rewriteInfo(chipId, 96, 111, 64, 2200);
        (, sealedMode) = kernel.evaluator();
        assertTrue(sealedMode, "nOut");
        circuits.rewriteInfo(chipId, 96, 112, 63, 2200);
        (, sealedMode) = kernel.evaluator();
        assertTrue(sealedMode, "nState");
        circuits.rewriteInfo(chipId, 96, 112, 64, 2201);
        (, sealedMode) = kernel.evaluator();
        assertTrue(sealedMode, "gateCount");
        circuits.rewriteInfo(chipId, 96, 112, 64, 2200);
        (, sealedMode) = kernel.evaluator();
        assertFalse(sealedMode, "restored");
    }

    // ------------------------------------------------------------------ TapeOut's step fails: the sealed one is asked

    /// INTERFACE sections 8.4 and 12: if TapeOut's step is asked and fails for any reason, the sealed
    /// evaluator is asked before the beat counts as failed. Every way TapeOut's step can fail, one by one.
    function test_sealed_evaluator_answers_when_tapeouts_step_fails_for_any_reason() public {
        _buy(alice, 1 ether);
        // 1 revert, 2 burn all gas, 3 state short, 4 outputs long, 5 return bomb, 6 bad offsets, 7 empty,
        // 8 state long, 10 right lengths but cut-off data
        uint8[9] memory modes = [1, 2, 3, 4, 5, 6, 7, 8, 10];
        for (uint256 i = 0; i < modes.length; i++) {
            uint256 snap = vm.snapshotState();
            circuits.setStepMode(modes[i]);
            (, bool sealedMode) = kernel.evaluator();
            assertFalse(sealedMode, "the pins hold: TapeOut is asked first");
            _nextEpoch();
            _settleExpecting(1, 1);
            Record memory r = _rec(1);
            assertEq(r.flags, RecordFlags.SEALED, "flag 2 and nothing else: a normal settle on the sealed answer");
            assertEq(r.outputs, W, "the same chip, the same answer");
            assertEq(KernelMath.stateBits(kernel.state()), 1, "the step is persisted");
            assertEq(kernel.lastStepEpoch(), 1);
            assertEq(r.inflow, 0.03 ether);
            assertGt(r.buyExecuted, 0, "and the money is routed by the chip, not by the fallback word");
            vm.revertToState(snap);
        }
    }

    /// The same when TapeOut's answer has the right shape for some other chip: a wrong state length or a
    /// wrong output width is a failure of TapeOut's step, not an answer.
    function test_wrong_width_from_tapeout_is_a_failure_and_the_sealed_evaluator_answers() public {
        _nextEpoch();
        circuits.setOverride(new bytes(8), new bytes(13)); // 13 output bytes instead of 14
        uint256 snap = vm.snapshotState();
        _settle();
        assertEq(_rec(1).flags, RecordFlags.SEALED);
        assertEq(_rec(1).outputs, W);
        vm.revertToState(snap);

        circuits.setOverride(new bytes(7), new bytes(14)); // 7 state bytes instead of 8
        _settle();
        assertEq(_rec(1).flags, RecordFlags.SEALED);
        vm.revertToState(snap);

        circuits.setOverride(new bytes(8), new bytes(14)); // right lengths: TapeOut's answer is accepted
        _settleExpecting(1, 0);
        assertEq(_rec(1).flags, 0);
        assertEq(_rec(1).outputs, bytes14(0));
    }

    /// Flag 2 says whose answer was used, settle by settle; the state runs through both evaluators.
    function test_flag_2_is_set_exactly_when_the_sealed_answer_was_used() public {
        _nextEpoch();
        _settle(); // 1: TapeOut
        circuits.setStepMode(1);
        _nextEpoch();
        _settle(); // 2: TapeOut fails, sealed answers
        circuits.setStepMode(0);
        _nextEpoch();
        _settle(); // 3: TapeOut again
        beacon.upgradeTo(address(new MockImplV2()));
        _nextEpoch();
        _settle(); // 4: pins do not hold, sealed directly
        assertFalse(_has(_rec(1).flags, RecordFlags.SEALED));
        assertTrue(_has(_rec(2).flags, RecordFlags.SEALED));
        assertFalse(_has(_rec(3).flags, RecordFlags.SEALED));
        assertTrue(_has(_rec(4).flags, RecordFlags.SEALED));
        assertEq(KernelMath.stateBits(kernel.state()), 4, "four beats, one state");
        assertEq(kernel.lastStepEpoch(), 4);
        for (uint32 n = 1; n <= 4; n++) {
            assertEq(_in(n).dt, 1, "every one of them is a persisted step");
            assertFalse(_has(_rec(n).flags, RecordFlags.FALLBACK));
        }
    }

    /// When the pins do not hold, TapeOut is not asked, whatever it would have answered.
    function test_tapeout_is_not_asked_when_the_pins_do_not_hold() public {
        beacon.upgradeTo(address(new MockImplV2()));
        circuits.setOverride(new bytes(8), abi.encodePacked(_word(0, 0, 256, 0, 256, 1023))); // a hostile answer
        _buy(alice, 1 ether);
        _nextEpoch();
        _settleExpecting(0, 1);
        assertEq(_rec(1).outputs, W);
        assertEq(_rec(1).flags, RecordFlags.SEALED);
    }

    // ------------------------------------------------------------------ each evaluator has its own gas

    /// TapeOut's step gets `stepFloor`, the sealed one gets `sealedFloor`: each succeeds just inside its own
    /// amount and fails just outside it, whatever gas the caller sent.
    function test_each_evaluator_gets_its_own_fixed_gas() public {
        Globals memory g = kernel.globals();
        assertEq(g.stepFloor, 200_000 + 2_600 * 2200 + 800 * 64);
        assertEq(g.sealedFloor, 40_000 + 200 * 2136 + 400 * 64);
        _nextEpoch();
        uint256 snap = vm.snapshotState();

        // TapeOut needs nearly all of its allowance: it answers
        circuits.setStepBurn(g.stepFloor - 40_000);
        _settle();
        assertEq(_rec(1).flags, 0);
        vm.revertToState(snap);

        // TapeOut needs more than its allowance: it fails, and the sealed evaluator answers
        circuits.setStepBurn(g.stepFloor + 1);
        _settle();
        assertEq(_rec(1).flags, RecordFlags.SEALED);
        vm.revertToState(snap);

        // the sealed evaluator needs nearly all of its (much smaller) allowance: it answers
        circuits.setStepMode(1);
        sealedVM.setStepBurn(g.sealedFloor - 40_000);
        _settle();
        assertEq(_rec(1).flags, RecordFlags.SEALED);
        vm.revertToState(snap);

        // the sealed evaluator needs more than its own allowance, though far less than TapeOut's: it fails
        circuits.setStepMode(1);
        sealedVM.setStepBurn(g.sealedFloor + 1);
        _expectStepFailed();
        vm.revertToState(snap);

        // the same when it is asked directly
        beacon.upgradeTo(address(new MockImplV2()));
        sealedVM.setStepBurn(g.sealedFloor + 1);
        _expectStepFailed();
        sealedVM.setStepBurn(g.sealedFloor - 40_000);
        _settle();
        assertEq(_rec(1).flags, RecordFlags.SEALED);
    }

    // ------------------------------------------------------------------ failures inside the grace period

    function _expectStepFailed() internal {
        vm.expectRevert(Kernel.StepFailed.selector);
        vm.prank(keeper);
        kernel.settle();
    }

    function test_no_evaluator_answering_inside_grace_reverts_and_moves_nothing() public {
        _buy(alice, 1 ether);
        _killBoth(1);
        _nextEpoch();
        bytes32 stateBefore = kernel.state();
        (bool ok, bytes4 err, uint256 tapeOutAsked, uint256 sealedAsked) = _settleAsked();
        assertFalse(ok);
        assertEq(err, Kernel.StepFailed.selector);
        assertEq(tapeOutAsked, 1, "TapeOut was asked");
        assertEq(sealedAsked, 1, "and then the sealed evaluator, before the beat counted as failed");
        assertEq(kernel.count(), 0);
        assertEq(kernel.lastEpoch(), 0);
        assertEq(kernel.state(), stateBefore);
        assertEq(address(vault).balance, 0.03 ether, "the claim was rolled back too");
        assertEq(address(kernel).balance, 0);
    }

    /// Every malformed answer is a failure, from either evaluator. With the other one dead the beat fails.
    function test_every_malformed_answer_is_a_failure() public {
        _nextEpoch();
        // 1 revert, 2 burn all gas, 3 state short, 4 outputs long, 5 return bomb, 6 bad offsets, 7 empty,
        // 8 state long, 10 lengths are right but the bytes are cut off
        uint8[9] memory modes = [1, 2, 3, 4, 5, 6, 7, 8, 10];
        for (uint256 i = 0; i < modes.length; i++) {
            // from TapeOut, with the sealed evaluator dead
            circuits.setStepMode(modes[i]);
            sealedVM.setStepMode(1);
            _expectStepFailed();
            // from the sealed evaluator, with TapeOut dead
            circuits.setStepMode(1);
            sealedVM.setStepMode(modes[i]);
            _expectStepFailed();
        }
        // from the sealed evaluator when it is asked directly
        beacon.upgradeTo(address(new MockImplV2()));
        circuits.setStepMode(0);
        for (uint256 i = 0; i < modes.length; i++) {
            sealedVM.setStepMode(modes[i]);
            _expectStepFailed();
        }
        sealedVM.setStepMode(0);
        _settle();
        assertEq(kernel.count(), 1);
    }

    function test_return_bomb_is_not_copied() public {
        // 1 MB of return data. Producing it costs the callee about 2.2M gas of its own allowance (memory
        // expansion). Copying it would cost the kernel the same again; the kernel reads at most 256 bytes.
        _nextEpoch();
        circuits.setStepMode(5);
        uint256 g0 = gasleft();
        _settle();
        uint256 used = g0 - gasleft();
        assertGt(used, 2_100_000, "the callee paid for its bomb");
        assertLt(used, 3_000_000, "the kernel did not pay for it a second time");
        assertEq(_rec(1).flags, RecordFlags.SEALED, "and the sealed evaluator answered instead");
    }

    function test_wrong_output_word_width_is_a_failure_of_the_beat_when_nobody_else_answers() public {
        _nextEpoch();
        sealedVM.setStepMode(1);
        circuits.setOverride(new bytes(8), new bytes(13));
        _expectStepFailed();
        circuits.setOverride(new bytes(8), new bytes(14));
        _settle(); // right lengths: accepted
        assertEq(_rec(1).outputs, bytes14(0));
        assertEq(_rec(1).flags, 0);
    }

    // ------------------------------------------------------------------ fallback after the grace period

    function test_fallback_applies_after_fallbackEpochs_without_a_step() public {
        _buy(alice, 1 ether);
        _killBoth(1);
        // fallbackEpochs = 4: epochs 1, 2 and 3 revert
        for (uint256 i = 0; i < 3; i++) {
            _nextEpoch();
            _expectStepFailed();
        }
        _nextEpoch(); // epoch 4
        bytes32 stateBefore = kernel.state();
        _settleExpecting(1, 1); // both were asked before the fallback word was applied
        Record memory r = _rec(1);
        assertEq(r.epoch, 4);
        assertEq(r.flags, RecordFlags.FALLBACK, "flag 1, and not flag 2: no evaluator's answer was used");
        // fallback word: T_BUY = 256 - fbAllow, T_ALLOW = fbAllow, REL = relMax, CEIL = 1023
        assertEq(r.outputs, _word(224, 0, 32, 0, 128, 1023));
        assertEq(kernel.state(), stateBefore, "state unchanged");
        assertEq(r.stateAfter, stateBefore);
        assertEq(kernel.lastStepEpoch(), 0, "no step was persisted");
        assertEq(kernel.lastEpoch(), 4, "but the epoch is consumed");
        assertEq(r.inflow, 0.03 ether);
        assertEq(r.allow, (0.03 ether * 32) / 256);
        assertEq(r.buyDecided, (0.03 ether * 224) / 256);
        assertEq(r.buyExecuted, r.buyDecided, "the fallback routes the money");
        assertEq(_in(1).dt, 4, "DT counts from the last persisted step");
    }

    /// The fallback is for a beat that nobody answers. One dead evaluator is not enough, at any epoch.
    function test_no_fallback_while_one_evaluator_answers() public {
        _buy(alice, 1 ether);
        circuits.setStepMode(1);
        vm.warp(block.timestamp + 10 * EPOCH); // far past the grace period
        _settle();
        Record memory r = _rec(1);
        assertEq(r.flags, RecordFlags.SEALED, "the sealed answer, not the fallback word");
        assertEq(r.outputs, W);
        assertEq(kernel.lastStepEpoch(), 10);

        // and the other way round: a dead sealed evaluator does not matter while TapeOut answers
        circuits.setStepMode(0);
        sealedVM.setStepMode(2);
        vm.warp(block.timestamp + 10 * EPOCH);
        _settle();
        assertEq(_rec(2).flags & (RecordFlags.FALLBACK | RecordFlags.SEALED), 0);
    }

    function test_fallback_every_epoch_until_an_evaluator_recovers() public {
        _killBoth(1);
        vm.warp(block.timestamp + 4 * EPOCH);
        _settle();
        _nextEpoch();
        _settle();
        _nextEpoch();
        _settle();
        assertTrue(_has(_rec(3).flags, RecordFlags.FALLBACK));
        assertEq(_in(3).dt, 6);
        assertEq(kernel.state(), bytes32(0));

        // the sealed evaluator alone comes back: the next settle is a normal one
        sealedVM.setStepMode(0);
        _nextEpoch();
        _settle();
        Record memory r = _rec(4);
        assertFalse(_has(r.flags, RecordFlags.FALLBACK));
        assertTrue(_has(r.flags, RecordFlags.SEALED));
        assertEq(_in(4).dt, 7, "seven epochs since bind without a persisted step");
        assertEq(kernel.lastStepEpoch(), 7);
        assertEq(KernelMath.stateBits(kernel.state()), 1);

        // a failure right after a persisted step is inside a fresh grace period
        _killBoth(1);
        _nextEpoch();
        _expectStepFailed();
    }

    function test_fallback_works_when_both_evaluators_are_dead() public {
        beacon.upgradeTo(address(new MockImplV2())); // the pins do not hold
        sealedVM.setStepMode(2); // and the sealed evaluator burns its gas
        _buy(alice, 1 ether);
        vm.warp(block.timestamp + 4 * EPOCH);
        _settleExpecting(0, 1);
        Record memory r = _rec(1);
        assertEq(r.flags, RecordFlags.FALLBACK, "the sealed evaluator was asked, but its answer was not used");
        assertGt(r.buyExecuted, 0, "no evaluator can freeze the tax");
    }

    function test_fallback_is_also_clipped_by_the_envelope() public {
        // a lifetime cap of zero: even the fallback pays no allowance
        Envelope memory e = _env();
        e.allowCumBps = 0;
        Built memory b = _build(ChipModel.fixedChip(8, W), 2200, e, 300, bytes32("fb"));
        kernel = b.kernel;
        token = b.token;
        vault = b.vault;
        _killBoth(1);
        _buy(alice, 1 ether);
        vm.warp(block.timestamp + 4 * EPOCH);
        _settle();
        Record memory r = _rec(1);
        assertTrue(_has(r.flags, RecordFlags.FALLBACK));
        assertEq(r.allow, 0);
        assertEq(r.clampBits & KernelMath.K2L, KernelMath.K2L);
    }

    // ------------------------------------------------------------------ state

    function test_state_is_stored_right_padded_and_passed_back() public {
        // a toggle chip with one latch: the state byte alternates 01, 00, 01
        Built memory b = _build(
            ChipModel.toggleChip(1, _word(256, 0, 0, 0, 0, 1023), _word(0, 0, 0, 256, 0, 1023)),
            200,
            _env(),
            300,
            bytes32("toggle")
        );
        kernel = b.kernel;
        token = b.token;
        vault = b.vault;
        _nextEpoch();
        _settle();
        assertEq(kernel.state(), bytes32(bytes1(0x01)), "one state byte, left-aligned, zero padded");
        assertEq(_rec(1).outputs, _word(256, 0, 0, 0, 0, 1023), "word A from state 0");
        _nextEpoch();
        _settle();
        assertEq(kernel.state(), bytes32(0));
        assertEq(_rec(2).outputs, _word(0, 0, 0, 256, 0, 1023), "word B from state 1: the state decides");
        assertEq(_in(1).tax, _in(2).tax, "with identical TAX");
    }

    function test_256_latch_state_uses_the_whole_slot() public {
        Built memory b = _build(ChipModel.hashChip(256, bytes32("seed")), 3400, _env(), 300, bytes32("wide"));
        kernel = b.kernel;
        token = b.token;
        vault = b.vault;
        _nextEpoch();
        _settle();
        _nextEpoch();
        _settle();
        assertTrue(kernel.state() != bytes32(0));
        assertEq(kernel.count(), 2);
    }
}
