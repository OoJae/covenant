// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseV2.t.sol";

/// @notice The evaluator path of kernel v2 is kernel v1's, unchanged: TapeOut while its pins hold, the sealed
///         evaluator otherwise or when TapeOut's step fails, the fallback word after `fallbackEpochs` with no
///         persisted step. These tests repeat v1's on the v2 kernel; the fallback word goes through the shifted
///         routing like any other word.
contract EvaluatorV2Test is BaseV2 {
    bytes14 internal W = _word(128, 64, 48, 16, 64, 1023);

    function setUp() public override {
        super.setUp();
        _fixture(W);
        _revenue(10e6);
    }

    function _settleExpecting(uint256 tapeOutAsked, uint256 sealedAsked) internal {
        (bool ok,, uint256 t, uint256 s) = _settleAsked();
        assertTrue(ok, "the settle returns");
        assertEq(t, tapeOutAsked, "times TapeOut's step was asked");
        assertEq(s, sealedAsked, "times the sealed evaluator was asked");
    }

    function _expectStepFailed() internal {
        vm.expectRevert(KernelV2.StepFailed.selector);
        vm.prank(keeper);
        kernel.settle();
    }

    function test_tapeout_is_used_while_the_pins_hold() public {
        _nextEpoch();
        (bool ok,, uint256 t, uint256 s) = _settleAsked();
        assertTrue(ok);
        assertEq(t, 1);
        assertEq(s, 0);
        assertFalse(_has(_rec(1).flags, RecordFlags.SEALED));
        (address vmAddr, bool sealedMode) = kernel.evaluator();
        assertEq(vmAddr, address(circuits));
        assertFalse(sealedMode);
    }

    function test_sealed_when_the_beacon_points_elsewhere_and_back_when_restored() public {
        beacon.upgradeTo(address(new MockImplV2()));
        _nextEpoch();
        (bool ok,, uint256 t, uint256 s) = _settleAsked();
        assertTrue(ok);
        assertEq(t, 0, "TapeOut is not asked");
        assertEq(s, 1);
        assertTrue(_has(_rec(1).flags, RecordFlags.SEALED));
        beacon.upgradeTo(address(impl));
        _nextEpoch();
        (ok,, t, s) = _settleAsked();
        assertEq(t, 1);
        assertEq(s, 0);
    }

    function test_sealed_when_the_netlist_is_rewritten() public {
        circuits.rewriteNetlist(chipId, ChipModel.fixedChip(64, _word(0, 0, 256, 0, 0, 1023)));
        _nextEpoch();
        (,, uint256 t, uint256 s) = _settleAsked();
        assertEq(t, 0);
        assertEq(s, 1);
        assertEq(_rec(1).outputs, W, "the pinned netlist decided");
    }

    function test_sealed_answers_when_tapeouts_step_fails_for_any_reason() public {
        uint8[6] memory modes = [1, 2, 3, 4, 5, 6];
        for (uint256 i = 0; i < 6; i++) {
            circuits.setStepMode(modes[i]);
            _nextEpoch();
            (bool ok,, uint256 t, uint256 s) = _settleAsked();
            assertTrue(ok);
            assertEq(t, 1);
            assertEq(s, 1);
            RecordV2 memory r = _rec(kernel.count());
            assertTrue(_has(r.flags, RecordFlags.SEALED));
            assertFalse(_has(r.flags, RecordFlags.FALLBACK));
            assertEq(r.outputs, W);
        }
    }

    function test_no_evaluator_answering_inside_grace_reverts_and_moves_nothing() public {
        _killBoth(1);
        _nextEpoch();
        uint256 q0 = _qbal(address(kernel));
        vm.expectRevert(KernelV2.StepFailed.selector);
        _settle();
        assertEq(_qbal(address(kernel)), q0);
        assertEq(kernel.count(), 0);
    }

    function test_fallback_applies_after_fallbackEpochs_without_a_step() public {
        _killBoth(1);
        vm.warp(block.timestamp + 4 * EPOCH); // fallbackEpochs = 4
        _settle();
        RecordV2 memory r = _rec(1);
        assertTrue(_has(r.flags, RecordFlags.FALLBACK));
        assertEq(uint112(r.outputs), uint112(KernelMath.outputBytes(KernelMath.fallbackWord(32, 128))));
        assertEq(kernel.state(), bytes32(0), "state unchanged");
        assertEq(kernel.lastStepEpoch(), 0);
        assertEq(r.allow, (10e6 * 32) / 256, "fbAllow of the USD0 inflow");
        // every epoch until an evaluator answers again
        _nextEpoch();
        _settle();
        assertTrue(_has(_rec(2).flags, RecordFlags.FALLBACK));
        _killBoth(0);
        _nextEpoch();
        _settle();
        assertFalse(_has(_rec(3).flags, RecordFlags.FALLBACK));
        assertEq(kernel.lastStepEpoch(), kernel.lastEpoch());
    }

    function test_fallback_is_clipped_by_the_envelope_through_the_shift() public {
        Envelope memory e = _env();
        e.ceilMax = 440; // 3.932160 USD0 per settle
        e.fbAllow = 64;
        _fixtureWith(ChipModel.fixedChip(8, W), e);
        _revenue(100e6);
        _killBoth(1);
        vm.warp(block.timestamp + 4 * EPOCH);
        _settle();
        RecordV2 memory r = _rec(1);
        assertEq(r.allow, 3_932_160);
        assertEq(r.clampBits & KernelMath.K2C, KernelMath.K2C);
    }

    function test_state_is_stored_right_padded_and_passed_back() public {
        _fixtureWith(ChipModel.fixedChip(12, W), _env());
        _nextEpoch();
        _settle();
        assertEq(kernel.state(), bytes32(bytes2(0x0100)), "counter 1 in 2 TAP-20 bytes, right-padded");
        _nextEpoch();
        _settle();
        assertEq(kernel.state(), bytes32(bytes2(0x0200)));
    }

    function test_every_malformed_answer_is_a_failure() public {
        uint8[7] memory modes = [1, 2, 3, 4, 5, 6, 10];
        for (uint256 i = 0; i < 7; i++) {
            _killBoth(modes[i]);
            _nextEpoch();
            vm.prank(keeper);
            (bool ok, bytes memory ret) = address(kernel).call{gas: 40_000_000}(abi.encodeCall(IKernelMin.settle, ()));
            if (ok) {
                assertTrue(_has(_rec(kernel.count()).flags, RecordFlags.FALLBACK), "only past the grace period");
            } else {
                assertEq(bytes4(ret), KernelV2.StepFailed.selector);
            }
        }
    }

    // ------------------------------------------------------------------ kernel v1's evaluator tests, ported (review B-F3)
    // _sealedMode and _step are kernel v1's code, copied into KernelV2; these pin each of its checks in v2 too.

    function test_sealed_when_the_beacon_cannot_be_read() public {
        beacon.setReverts(true);
        (, bool sealedMode) = kernel.evaluator();
        assertTrue(sealedMode);
        _nextEpoch();
        _settleExpecting(0, 1);
        assertEq(_rec(1).flags & RecordFlags.SEALED, RecordFlags.SEALED);
    }

    function test_sealed_when_the_implementation_code_changes() public {
        (, bool sealedMode) = kernel.evaluator();
        assertFalse(sealedMode);
        vm.etch(address(impl), hex"6001600055"); // same address, different code
        (, sealedMode) = kernel.evaluator();
        assertTrue(sealedMode, "the code hash pin");
        _nextEpoch();
        _settleExpecting(0, 1);
    }

    function test_sealed_when_the_netlist_length_changes() public {
        circuits.rewriteNetlist(chipId, bytes.concat(ChipModel.fixedChip(64, W), hex"00"));
        (, bool sealedMode) = kernel.evaluator();
        assertTrue(sealedMode);
    }

    /// `step` interprets the netlist through the stored pin counts, so all four are pinned.
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
        _nextEpoch();
        _settleExpecting(0, 1);
        circuits.rewriteInfo(chipId, 96, 112, 64, 2200);
        (, sealedMode) = kernel.evaluator();
        assertFalse(sealedMode, "restored");
    }

    /// TapeOut's answer with the right shape for some other chip (wrong state length, wrong output width) is a
    /// failure of TapeOut's step, not an answer.
    function test_wrong_width_from_tapeout_is_a_failure_and_the_sealed_evaluator_answers() public {
        _nextEpoch();
        circuits.setOverride(new bytes(8), new bytes(13)); // 13 output bytes instead of 14
        uint256 snap = vm.snapshotState();
        _settle();
        assertTrue(_has(_rec(1).flags, RecordFlags.SEALED));
        assertEq(_rec(1).outputs, W);
        vm.revertToState(snap);

        circuits.setOverride(new bytes(7), new bytes(14)); // 7 state bytes instead of 8
        _settle();
        assertTrue(_has(_rec(1).flags, RecordFlags.SEALED));
        vm.revertToState(snap);

        circuits.setOverride(new bytes(8), new bytes(14)); // right lengths: TapeOut's answer is accepted
        _settleExpecting(1, 0);
        assertFalse(_has(_rec(1).flags, RecordFlags.SEALED));
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
        _nextEpoch();
        _settleExpecting(0, 1);
        assertEq(_rec(1).outputs, W);
        assertTrue(_has(_rec(1).flags, RecordFlags.SEALED));
    }

    /// TapeOut's step gets `stepFloor`, the sealed one `sealedFloor`: each succeeds just inside its own amount and
    /// fails just outside it, whatever gas the caller sent.
    function test_each_evaluator_gets_its_own_fixed_gas() public {
        GlobalsV2 memory g = kernel.globals();
        assertEq(g.stepFloor, 200_000 + 2_600 * 2200 + 800 * 64);
        assertEq(g.sealedFloor, 40_000 + 200 * 2136 + 400 * 64);
        _nextEpoch();
        uint256 snap = vm.snapshotState();

        circuits.setStepBurn(g.stepFloor - 40_000); // TapeOut needs nearly all of its allowance: it answers
        _settle();
        assertFalse(_has(_rec(1).flags, RecordFlags.SEALED));
        vm.revertToState(snap);

        circuits.setStepBurn(g.stepFloor + 1); // more than its allowance: it fails, the sealed one answers
        _settle();
        assertTrue(_has(_rec(1).flags, RecordFlags.SEALED));
        vm.revertToState(snap);

        circuits.setStepMode(1);
        sealedVM.setStepBurn(g.sealedFloor - 40_000); // the sealed one inside its (smaller) allowance
        _settle();
        assertTrue(_has(_rec(1).flags, RecordFlags.SEALED));
        vm.revertToState(snap);

        circuits.setStepMode(1);
        sealedVM.setStepBurn(g.sealedFloor + 1); // more than its own allowance, far less than TapeOut's: fails
        _expectStepFailed();
        vm.revertToState(snap);

        beacon.upgradeTo(address(new MockImplV2())); // the same when it is asked directly
        sealedVM.setStepBurn(g.sealedFloor + 1);
        _expectStepFailed();
        sealedVM.setStepBurn(g.sealedFloor - 40_000);
        _settle();
        assertTrue(_has(_rec(1).flags, RecordFlags.SEALED));
    }

    /// 1 MB of return data costs the callee about 2.2M gas of its own allowance; the kernel reads at most 256 bytes
    /// and does not pay for it a second time.
    function test_return_bomb_is_not_copied() public {
        _nextEpoch();
        uint256 snap = vm.snapshotState();
        uint256 g0 = gasleft();
        _settle();
        uint256 plain = g0 - gasleft();
        vm.revertToState(snap);
        circuits.setStepMode(5);
        g0 = gasleft();
        _settle();
        uint256 bombed = g0 - gasleft();
        assertGt(bombed - plain, 2_100_000, "the callee paid for its bomb");
        assertLt(bombed - plain, 3_000_000, "the kernel did not pay for it a second time");
        assertTrue(_has(_rec(1).flags, RecordFlags.SEALED), "and the sealed evaluator answered instead");
    }

    function test_256_latch_state_uses_the_whole_slot() public {
        Built memory b = _build(ChipModel.hashChip(256, bytes32("seed")), 3400, _env(), 300, bytes32("wide"));
        kernel = b.kernel;
        token = b.token;
        vault = b.vault;
        _revenue(1e6);
        _nextEpoch();
        _settle();
        _nextEpoch();
        _settle();
        assertTrue(kernel.state() != bytes32(0));
        assertEq(kernel.count(), 2);
    }

    /// An answer whose state is padded with non-zero bytes inside its 32-byte word: only the chip's own state bytes
    /// are kept (`newState &= mask`), from either evaluator. Without the mask the dirty bytes would become state.
    function test_bytes_after_the_state_are_masked_off_from_either_evaluator() public {
        bytes32 dirtyState = bytes32(hex"0102030405060708ffffffffffffffffffffffffffffffffffffffffffffffff");
        bytes32 dirtyOut = bytes32(bytes.concat(bytes14(W), bytes18(type(uint144).max)));
        // the ABI form of (bytes state, bytes outputs), with dirt in both paddings
        bytes memory answer =
            abi.encodePacked(uint256(0x40), uint256(0x80), uint256(8), dirtyState, uint256(14), dirtyOut);
        assertEq(answer.length, 192);

        vm.mockCall(address(circuits), abi.encodeWithSelector(ICircuits.step.selector), answer);
        _nextEpoch();
        _settle();
        assertFalse(_has(_rec(1).flags, RecordFlags.SEALED), "TapeOut's answer was used");
        assertEq(kernel.state(), bytes32(bytes8(0x0102030405060708)), "state bytes only");
        assertEq(_rec(1).stateAfter, bytes32(bytes8(0x0102030405060708)));
        assertEq(_rec(1).outputs, W);
        vm.clearMockedCalls();

        beacon.upgradeTo(address(new MockImplV2()));
        bytes32 dirty2 = bytes32(hex"a1a2a3a4a5a6a7a8eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee");
        vm.mockCall(
            address(sealedVM),
            abi.encodeWithSelector(ISealedVM.step.selector),
            abi.encodePacked(uint256(0x40), uint256(0x80), uint256(8), dirty2, uint256(14), dirtyOut)
        );
        _nextEpoch();
        _settle();
        assertTrue(_has(_rec(2).flags, RecordFlags.SEALED), "the sealed evaluator's answer was used");
        assertEq(kernel.state(), bytes32(bytes8(0xa1a2a3a4a5a6a7a8)), "state bytes only");
    }

    /// The fallback is not a step: no flag 2, the chip state and lastStepEpoch stay as they were.
    function test_a_fallback_record_is_not_a_step() public {
        _nextEpoch();
        _settle();
        bytes32 st = kernel.state();
        assertEq(kernel.lastStepEpoch(), 1);
        _killBoth(1);
        vm.warp(block.timestamp + 4 * EPOCH);
        _settle();
        RecordV2 memory r = _rec(2);
        assertTrue(_has(r.flags, RecordFlags.FALLBACK));
        assertFalse(_has(r.flags, RecordFlags.SEALED), "flag 2 on a record no evaluator answered");
        assertEq(kernel.lastStepEpoch(), 1, "the fallback counted as a persisted step");
        assertEq(kernel.state(), st);
        assertEq(r.stateAfter, st);
    }
}
