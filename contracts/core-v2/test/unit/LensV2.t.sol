// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseV2.t.sol";

/// @notice LensV2: replay, counterfactual, shadow runs, stateMatters and preflight on v2 kernels, with the shifted
///         codes on the curve and unshifted ones after graduation.
contract LensV2Test is BaseV2 {
    function setUp() public override {
        super.setUp();
        _fixtureWith(ChipModel.hashChip(64, bytes32("lens")), _env());
    }

    /// @dev A history across graduation: curve trading, revenue, a fallback record, graduation, V2 trading.
    function _history() internal {
        for (uint256 i = 0; i < 6; i++) {
            _buy(alice, 30e6 + i * 7e6);
            if (i % 2 == 0) _revenue(500_000 * (i + 1));
            _nextEpoch();
            _settle();
        }
        circuits.setStepMode(1); // one record answered by the sealed evaluator
        _nextEpoch();
        _settle();
        circuits.setStepMode(0);
        _graduate();
        for (uint256 i = 0; i < 5; i++) {
            _v2Buy(bob, 20e6);
            _revenue(1e6);
            _nextEpoch();
            _settle();
        }
    }

    function test_replay_every_record_on_both_evaluators() public {
        _history();
        uint32 n = kernel.count();
        assertEq(n, 12);
        for (uint32 i = 1; i <= n; i++) {
            LensV2.Replay memory a = lens.replayOn(address(kernel), i, false);
            LensV2.Replay memory b = lens.replayOn(address(kernel), i, true);
            assertTrue(a.ok, string.concat("TapeOut replay ", vm.toString(i)));
            assertTrue(b.ok, string.concat("sealed replay ", vm.toString(i)));
            assertTrue(lens.replay(address(kernel), i).ok);
        }
        (uint32 next, uint32 bad) = lens.replayRange(address(kernel), 1, n, true);
        assertEq(next, n + 1);
        assertEq(bad, 0);
    }

    function test_replay_checks_the_shifted_input_codes() public {
        _history();
        // record 1: curve, shifted; record 12: graduated, unshifted
        RecordV2 memory r1 = kernel.records(1);
        KernelMath.InputFields memory f1 = KernelMath.unpackInput(KernelMath.inputWord(r1.inputs));
        assertEq(f1.tax, KernelMathV2.lg8s(r1.inflow, 33));
        RecordV2 memory r12 = kernel.records(12);
        KernelMath.InputFields memory f12 = KernelMath.unpackInput(KernelMath.inputWord(r12.inputs));
        assertEq(f12.tax, KernelMath.lg8(r12.inflow));
        assertTrue(lens.replay(address(kernel), 1).inputsMatch);
        assertTrue(lens.replay(address(kernel), 12).inputsMatch);
    }

    function test_replay_has_teeth() public {
        _history();
        // tamper with record 3's stored inflow (slot 1 of the record: outputs | inflow << 112)
        uint256 base = uint256(keccak256(abi.encode(uint256(3), uint256(10)))); // _rec at slot 10
        uint256 slot1 = uint256(vm.load(address(kernel), bytes32(base + 1)));
        uint256 inflow = slot1 >> 112;
        assertEq(inflow, kernel.records(3).inflow, "slot layout");
        uint256 tampered = (slot1 & ((uint256(1) << 112) - 1)) | ((inflow * 2 + 7) << 112);
        vm.store(address(kernel), bytes32(base + 1), bytes32(tampered));
        LensV2.Replay memory p = lens.replay(address(kernel), 3);
        assertFalse(p.ok, "a changed inflow no longer replays");
        assertFalse(p.inputsMatch && p.amountsMatch);
    }

    function test_counterfactual_totals_by_regime() public {
        _history();
        (LensV2.Counterfactual memory curve, LensV2.Counterfactual memory grad,) =
            lens.counterfactual(address(kernel), 1, kernel.count());
        uint256 inCurve;
        uint256 inGrad;
        for (uint32 i = 1; i <= kernel.count(); i++) {
            RecordV2 memory r = kernel.records(i);
            if (r.flags & RecordFlags.GRADUATED != 0) inGrad += r.inflow;
            else inCurve += r.inflow;
        }
        assertEq(curve.chip.inflow, inCurve);
        assertEq(grad.chip.inflow, inGrad);
        assertEq(grad.chip.allow, 0);
        assertEq(grad.fixedSplit.allow, 0, "the baseline pays no allowance after graduation either");
        assertEq(curve.alwaysBuy.buy, inCurve);
    }

    function test_shadow_of_the_same_chip_reproduces_the_decisions() public {
        _history();
        LensV2.ShadowCursor memory cur;
        (LensV2.ShadowStep[] memory steps,,) = lens.shadowChip(address(kernel), chipId, 1, 6, cur);
        assertEq(steps.length, 6);
        for (uint256 i = 0; i < 6; i++) {
            RecordV2 memory r = kernel.records(uint32(i + 1));
            assertEq(steps[i].allow, r.allow, "same chip, same reserve path, same allowance");
            assertEq(steps[i].buyDecided, r.buyDecided);
        }
    }

    function test_shadow_sees_its_own_reserve_through_the_shift() public {
        _history();
        // a hoarding chip shadowed over the same inflows: its RES is lg8(its own reserve << 33)
        vm.prank(launcher);
        uint256 hoarder = fab.tapeoutChip(ChipModel.fixedChip(8, _word(0, 0, 0, 256, 0, 1023)), 2200);
        LensV2.ShadowCursor memory cur;
        (LensV2.ShadowStep[] memory steps, LensV2.ShadowCursor memory next,) =
            lens.shadowChip(address(kernel), hoarder, 1, 6, cur);
        uint256 reserve;
        for (uint256 i = 0; i < 6; i++) {
            KernelMath.InputFields memory f = KernelMath.unpackInput(KernelMath.inputWord(steps[i].inputs));
            assertEq(f.res, KernelMathV2.lg8s(reserve, 33), "the shadow's own reserve, shifted");
            reserve = steps[i].reserveAfter;
        }
        assertEq(next.reserve, reserve);
    }

    function test_shadow_of_any_netlist_through_the_sealed_evaluator() public {
        _history();
        bytes memory nl = ChipModel.fixedChip(8, _word(256, 0, 0, 0, 0, 1023));
        (address ptr,,,,,) = fab.chipInfo(chipId); // any SSTORE2 pointer will do; make one for `nl`
        ptr = _pointer(nl);
        LensV2.ShadowCursor memory cur;
        (LensV2.ShadowStep[] memory steps,,) = lens.shadowSnapshot(address(kernel), ptr, 1, 3, cur);
        assertEq(steps.length, 3);
        assertTrue(steps[0].ran);
        assertEq(steps[0].buyDecided, kernel.records(1).inflow, "a chip that buys everything");
    }

    function _pointer(bytes memory nl) internal returns (address ptr) {
        bytes memory creation = abi.encodePacked(hex"600B5981380380925939F3", abi.encodePacked(hex"00", nl));
        assembly {
            ptr := create(0, add(creation, 0x20), mload(creation))
        }
    }

    function test_stateMatters_and_preflight() public {
        _history();
        (bool matters,,) = lens.stateMatters(address(kernel), 3);
        matters; // a hash chip: whether the state matters depends on the hash; the call itself must work
        LensV2.Preflight memory p = lens.preflight(address(kernel));
        assertTrue(p.tapeoutRan && p.sealedRan && p.agree);
        assertEq(p.minSettleGas, kernel.minSettleGas());
    }

    function test_every_entry_point_refuses_a_kernel_the_factory_did_not_make() public {
        LensV2.ShadowCursor memory cur;
        LensV2.CfCursor memory cf;
        address fake = address(0xBEEF);
        vm.expectRevert(LensV2.NotKernel.selector);
        lens.replay(fake, 1);
        vm.expectRevert(LensV2.NotKernel.selector);
        lens.replayOn(fake, 1, true);
        vm.expectRevert(LensV2.NotKernel.selector);
        lens.replayRange(fake, 1, 1, true);
        vm.expectRevert(LensV2.NotKernel.selector);
        lens.counterfactualFrom(fake, 1, 1, cf);
        vm.expectRevert(LensV2.NotKernel.selector);
        lens.shadowChip(fake, 1, 1, 1, cur);
        vm.expectRevert(LensV2.NotKernel.selector);
        lens.shadowSnapshot(fake, address(1), 1, 1, cur);
        vm.expectRevert(LensV2.NotKernel.selector);
        lens.stateMattersVs(fake, 1, bytes32(0));
        vm.expectRevert(LensV2.NotKernel.selector);
        lens.preflight(fake);
    }

    function test_a_malformed_answer_is_reported_and_never_reverts() public {
        _history();
        circuits.setStepMode(5); // return bomb
        LensV2.Replay memory p = lens.replayOn(address(kernel), 1, false);
        assertFalse(p.ran);
        assertFalse(p.ok);
        sealedVM.setStepMode(6);
        p = lens.replayOn(address(kernel), 1, true);
        assertFalse(p.ran);
        LensV2.Preflight memory pf = lens.preflight(address(kernel));
        assertFalse(pf.agree);
    }

    function test_range_checks() public {
        _history();
        vm.expectRevert(LensV2.BadRange.selector);
        lens.replay(address(kernel), 0);
        vm.expectRevert(LensV2.BadRange.selector);
        lens.replay(address(kernel), 99);
        vm.expectRevert(LensV2.BadRange.selector);
        lens.counterfactual(address(kernel), 3, 2);
    }
}
