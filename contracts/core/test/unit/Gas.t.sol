// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "../Base.t.sol";
import {Kernel} from "../../src/Kernel.sol";
import {Record, Envelope, RecordFlags, IKernelMin} from "../../src/interfaces/IKernelV1.sol";
import {ChipModel, MockImplV2} from "../mocks/MockTapeOut.sol";
import {MockPair} from "../mocks/MockIgnix.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev The kernel without its first, whole-settle gas check. What is left is one guard in front of every
///      external call, so a sweep of the gas limit crosses each of those guards on its own.
contract KernelNoFloor is Kernel {
    function _minSettleGas(uint256, uint256) internal pure override returns (uint256) {
        return 0;
    }
}

/// @notice The caller's gas limit must never decide an outcome. For every gas limit a settle either reverts as
///         a whole or produces exactly the record it produces with unlimited gas: never a step, claim or buy
///         that "failed" only because the caller starved it.
contract GasTest is Base {
    bytes14 internal W = _word(128, 64, 48, 16, 64, 1023);

    // the kernel's allowances (Kernel.sol constants), repeated here on purpose: a change there must be a
    // conscious change here
    uint256 internal constant G_VIEW = 100_000;
    uint256 internal constant G_NETLIST = 500_000;
    uint256 internal constant G_CLAIM = 200_000;
    uint256 internal constant G_BUY = 500_000;
    uint256 internal constant G_TRANSFER = 200_000;
    uint256 internal constant G_SWAP = 700_000;
    // the fixture chip: 2,200 records, 64 of them latches (KernelFactory's two formulas)
    uint256 internal constant STEP_FLOOR = 200_000 + 2_600 * 2200 + 800 * 64;
    uint256 internal constant SEALED_FLOOR = 40_000 + 200 * (2200 - 64) + 400 * 64;

    MockPair internal pair;

    function setUp() public override {
        super.setUp();
    }

    function _useNoFloorKernel() internal {
        vm.etch(factory.kernelImpl(), address(new KernelNoFloor()).code);
    }

    // ------------------------------------------------------------------ outcome of one attempt

    function _digest() internal view returns (bytes32) {
        uint32 n = kernel.count();
        (uint128 cum, uint128 paid) = kernel.cums(n);
        bytes32 a = keccak256(abi.encode(n, kernel.records(n), cum, paid, kernel.state(), kernel.reserve()));
        bytes32 b = keccak256(
            abi.encode(
                kernel.lockedTokens(),
                kernel.burnedTokens(),
                kernel.graduated(),
                address(kernel).balance,
                token.balanceOf(address(kernel)),
                address(vault).balance,
                token.balanceOf(address(vault))
            )
        );
        bytes32 c = keccak256(
            abi.encode(token.balanceOf(DEAD), kernel.creditOf(payee, NATIVE), kernel.creditOf(payee, address(token)))
        );
        return keccak256(abi.encode(a, b, c));
    }

    /// @return ok      the settle returned
    /// @return digest  everything the settle wrote, when it returned
    /// @return err     the revert selector, when it did not
    function _attempt(uint256 gasLimit) internal returns (bool ok, bytes32 digest, bytes4 err) {
        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        bytes memory ret;
        (ok, ret) = address(kernel).call{gas: gasLimit}(abi.encodeCall(IKernelMin.settle, ()));
        if (ok) digest = _digest();
        else if (ret.length >= 4) err = bytes4(ret);
        vm.revertToState(snap);
    }

    /// @dev Sweeps the gas limit and checks "revert or full success" at every point.
    /// @return minOk the smallest gas limit of the sweep with which the settle returned
    function _sweep(uint256 from, uint256 to, uint256 step_) internal returns (uint256 minOk) {
        (bool okRef, bytes32 ref,) = _attempt(30_000_000);
        assertTrue(okRef, "the reference settle succeeds with ample gas");
        uint32 before = kernel.count();
        for (uint256 g = from; g <= to; g += step_) {
            (bool ok, bytes32 d, bytes4 err) = _attempt(g);
            if (ok) {
                assertEq(d, ref, "a settle that returned wrote exactly what the unlimited one writes");
                if (minOk == 0) minOk = g;
            } else {
                // under-funding may only ever show as a lack of gas: the kernel's own guard, or a plain
                // out-of-gas (empty revert data). Never as "the step failed".
                assertTrue(err == Kernel.InsufficientGas.selector || err == bytes4(0), "reverted for lack of gas only");
                assertEq(kernel.count(), before);
            }
        }
        assertGt(minOk, 0, "the sweep reached a successful settle");
    }

    // ------------------------------------------------------------------ fixtures

    function _curveScenario() internal {
        _fixture(W);
        vm.deal(address(vault), 3 ether);
        _nextEpoch();
        _settle();
        _buy(alice, 5 ether);
        _nextEpoch();
        // the next settle claims, steps, credits, releases a quarter of the reserve and buys
    }

    function _graduatedScenario() internal {
        _fixture(W);
        _buy(alice, 10 ether);
        _nextEpoch();
        _settle();
        pair = _graduate();
        _nextEpoch();
        _settle();
        _v2Buy(alice, 3 ether);
        _nextEpoch();
        // the next settle claims both assets, steps, credits, burns and swaps
    }

    // ------------------------------------------------------------------ sweeps across each guard

    function test_gasSweep_curve_each_guard_alone() public {
        _useNoFloorKernel();
        _curveScenario();
        uint256 minOk = _sweep(20_000, 7_000_000, 3_000);
        (bool ok, bytes32 d,) = _attempt(30_000_000);
        assertTrue(ok && d != bytes32(0));
        // the binding guard is the step's: 64/63 of its allowance must be in hand when it is called
        assertGt(minOk, STEP_FLOOR + STEP_FLOOR / 63, "no settle with less than the step needs");
        Record memory r = _settleAndGet();
        assertGt(r.buyExecuted, 0, "the scenario really bought");
        assertEq(r.flags, RecordFlags.BUY_SHRUNK, "bought at the impact cap; nothing failed");
    }

    function test_gasSweep_graduated_each_guard_alone() public {
        _useNoFloorKernel();
        _graduatedScenario();
        uint256 minOk = _sweep(20_000, 7_000_000, 3_000);
        assertGt(minOk, STEP_FLOOR + STEP_FLOOR / 63);
        Record memory r = _settleAndGet();
        assertGt(r.buyExecuted, 0, "the scenario really burned");
        assertGt(r.tokensOut, r.buyExecuted, "and really swapped");
        assertEq(r.flags & (RecordFlags.BUY_FAILED | RecordFlags.CLAIM_FAILED), 0);
    }

    /// The dangerous case: past the grace period a failed step becomes the fallback split. If a caller could
    /// starve the step, it could choose the fallback over the chip. The guard makes that impossible.
    function test_gasSweep_caller_cannot_force_the_fallback() public {
        _useNoFloorKernel();
        _fixture(W);
        vm.deal(address(vault), 3 ether);
        circuits.setStepBurn(STEP_FLOOR - 60_000); // a chip that needs almost all of its allowance
        vm.warp(block.timestamp + 10 * EPOCH); // far past the grace period
        _sweep(20_000, 7_500_000, 3_000);
        Record memory r = _settleAndGet();
        assertFalse(_has(r.flags, RecordFlags.FALLBACK), "the chip decided, at every gas limit that returned");
        assertFalse(_has(r.flags, RecordFlags.SEALED), "and TapeOut answered, at every gas limit that returned");
        assertEq(r.outputs, W);
    }

    /// A caller must not be able to choose the evaluator either: TapeOut's step is never starved into
    /// "failing" so that the sealed one answers, and when TapeOut's step genuinely fails (here it burns its
    /// whole allowance) the sealed evaluator, which needs almost all of its own, is never starved into the
    /// fallback word. Every gas limit that returns writes the same record: sealed answer, no fallback.
    function test_gasSweep_tapeout_dead_sealed_answers_each_guard_alone() public {
        _useNoFloorKernel();
        _fixture(W);
        vm.deal(address(vault), 3 ether);
        circuits.setStepMode(2); // burns its whole allowance and fails
        sealedVM.setStepBurn(SEALED_FLOOR - 40_000); // needs almost all of its own
        vm.warp(block.timestamp + 10 * EPOCH); // past the grace period: a starved sealed step would be a fallback
        uint256 minOk = _sweep(20_000, 9_000_000, 3_000);
        assertGt(minOk, STEP_FLOOR + SEALED_FLOOR, "no settle with less than the two steps need");
        Record memory r = _settleAndGet();
        assertTrue(_has(r.flags, RecordFlags.SEALED), "the sealed answer, at every gas limit that returned");
        assertFalse(_has(r.flags, RecordFlags.FALLBACK));
        assertEq(r.outputs, W);
        assertGt(r.buyExecuted, 0);
    }

    /// The same inside the grace period, where a starved sealed step would show as StepFailed.
    function test_gasSweep_tapeout_dead_caller_cannot_fake_a_failed_beat() public {
        _useNoFloorKernel();
        _fixture(W);
        circuits.setStepMode(2);
        sealedVM.setStepBurn(SEALED_FLOOR - 40_000);
        _nextEpoch();
        _sweep(20_000, 9_000_000, 3_000);
    }

    /// With the pins not holding, the sealed evaluator is asked directly and gets its own allowance.
    function test_gasSweep_sealed_asked_directly_each_guard_alone() public {
        _useNoFloorKernel();
        _fixture(W);
        vm.deal(address(vault), 3 ether);
        beacon.upgradeTo(address(new MockImplV2()));
        sealedVM.setStepBurn(SEALED_FLOOR - 40_000);
        vm.warp(block.timestamp + 10 * EPOCH);
        uint256 minOk = _sweep(20_000, 3_000_000, 2_000);
        assertGt(minOk, SEALED_FLOOR + SEALED_FLOOR / 63);
        assertLt(minOk, STEP_FLOOR, "TapeOut's allowance is not needed when TapeOut is not asked");
        Record memory r = _settleAndGet();
        assertTrue(_has(r.flags, RecordFlags.SEALED));
        assertFalse(_has(r.flags, RecordFlags.FALLBACK));
    }

    /// Inside the grace period a starved step would revert the settle with StepFailed, which a keeper could
    /// mistake for a broken chip. Under-funding must show as a lack of gas instead (checked in _sweep).
    function test_gasSweep_caller_cannot_fake_a_step_failure() public {
        _useNoFloorKernel();
        _fixture(W);
        circuits.setStepBurn(STEP_FLOOR - 60_000);
        _nextEpoch();
        _sweep(20_000, 7_500_000, 3_000);
    }

    /// When both evaluators really are dead, the fallback is what every funded caller gets.
    function test_gasSweep_genuine_fallback() public {
        _useNoFloorKernel();
        _fixture(W);
        vm.deal(address(vault), 3 ether);
        _killBoth(2); // each burns its whole allowance and fails
        vm.warp(block.timestamp + 10 * EPOCH);
        _sweep(20_000, 9_000_000, 3_000);
        Record memory r = _settleAndGet();
        assertTrue(_has(r.flags, RecordFlags.FALLBACK));
        assertGt(r.buyExecuted, 0);
    }

    function test_gasSweep_expensive_legs_each_guard_alone() public {
        _useNoFloorKernel();
        _curveScenario();
        vault.setBurnGas(140_000); // claim needs most of G_CLAIM
        manager.setBurnGas(340_000); // buyTo needs most of G_BUY
        circuits.setStepBurn(STEP_FLOOR - 60_000);
        _sweep(100_000, 9_000_000, 4_000);
        Record memory r = _settleAndGet();
        assertEq(r.flags, RecordFlags.BUY_SHRUNK, "expensive but working legs are not failures");
        assertGt(r.buyExecuted, 0);
    }

    function testFuzz_any_gas_limit_reverts_or_fully_succeeds(uint256 gasLimit, bool grad) public {
        _useNoFloorKernel();
        if (grad) _graduatedScenario();
        else _curveScenario();
        gasLimit = bound(gasLimit, 0, 8_000_000);
        (, bytes32 ref,) = _attempt(30_000_000);
        (bool ok, bytes32 d, bytes4 err) = _attempt(gasLimit);
        if (ok) assertEq(d, ref);
        else assertTrue(err == Kernel.InsufficientGas.selector || err == bytes4(0));
    }

    // ------------------------------------------------------------------ the real kernel: minSettleGas

    function test_minSettleGas_formula() public {
        _fixture(W);
        // both evaluators are budgeted: TapeOut's step may use up its gas and fail before the sealed one answers.
        // 15 view-sized calls: 14 on the longest path (the pair-lock probe after a failed swap is one), plus one
        uint256 m = 600_000 + 2 * _wm(G_CLAIM) + 15 * _wm(G_VIEW) + _wm(G_NETLIST) + _wm(STEP_FLOOR) + _wm(SEALED_FLOOR)
            + _wm(G_TRANSFER) + _wm(G_SWAP) + 40_000;
        m = m + m / 63 + 5_000;
        m = m + m / 63 + 5_000;
        assertEq(kernel.minSettleGas(), m + 30_000);
        assertEq(kernel.minSettleGas(), 11_390_999, "the number itself, for the 2,200-gate fixture chip");
        assertLt(kernel.minSettleGas(), 12_000_000, "a 2,200-gate chip settles within 12M gas of limit");
    }

    function _wm(uint256 g) internal pure returns (uint256) {
        return g + g / 63 + 20_000;
    }

    function test_below_minSettleGas_reverts_before_anything_moves() public {
        _curveScenario();
        uint256 m = kernel.minSettleGas();
        // well below: the kernel's first check stops it
        (bool ok,, bytes4 err) = _attempt(m - 500_000);
        assertFalse(ok);
        assertEq(err, Kernel.InsufficientGas.selector);
        (ok,,) = _attempt(m);
        assertTrue(ok, "minSettleGas is enough");
    }

    function test_real_kernel_sweep_is_revert_or_full_success() public {
        _curveScenario();
        uint256 m = kernel.minSettleGas();
        uint256 minOk = _sweep(m - 1_000_000, m + 200_000, 2_000);
        assertLe(minOk, m, "minSettleGas is sufficient");
    }

    /// Every dependency consumes almost all the gas the kernel hands it, and still works. A settle sent with
    /// exactly minSettleGas must complete with no failed leg: the budget is a true upper bound.
    function test_minSettleGas_is_enough_when_every_leg_is_expensive_curve() public {
        _curveScenario();
        vault.setBurnGas(150_000);
        manager.setBurnGas(360_000);
        circuits.setStepBurn(STEP_FLOOR - 40_000);
        uint256 m = kernel.minSettleGas();
        vm.prank(keeper);
        (bool ok,) = address(kernel).call{gas: m}(abi.encodeCall(IKernelMin.settle, ()));
        assertTrue(ok, "funded with minSettleGas");
        Record memory r = _rec(kernel.count());
        assertEq(r.flags, RecordFlags.BUY_SHRUNK, "no leg failed for lack of gas");
        assertGt(r.buyExecuted, 0);
    }

    /// The costliest settle there is: TapeOut's step uses up its whole allowance and fails, the sealed
    /// evaluator then needs almost all of its own, and every other leg is expensive too. minSettleGas covers it.
    function test_minSettleGas_is_enough_when_tapeout_burns_its_gas_and_the_sealed_evaluator_answers() public {
        _curveScenario();
        vault.setBurnGas(150_000);
        manager.setBurnGas(360_000);
        circuits.setStepMode(2); // all of STEP_FLOOR, then failure
        sealedVM.setStepBurn(SEALED_FLOOR - 40_000);
        uint256 m = kernel.minSettleGas();
        vm.prank(keeper);
        (bool ok,) = address(kernel).call{gas: m}(abi.encodeCall(IKernelMin.settle, ()));
        assertTrue(ok, "funded with minSettleGas");
        Record memory r = _rec(kernel.count());
        assertEq(r.flags, RecordFlags.BUY_SHRUNK | RecordFlags.SEALED, "sealed answer; no leg failed for lack of gas");
        assertGt(r.buyExecuted, 0);
    }

    function test_minSettleGas_is_enough_in_the_costliest_graduated_settle() public {
        _graduatedScenario();
        vault.setBurnGas(60_000);
        token.setBurnGas(70_000);
        router.setBurnGas(350_000);
        circuits.setStepMode(2);
        sealedVM.setStepBurn(SEALED_FLOOR - 40_000);
        uint256 m = kernel.minSettleGas();
        vm.prank(keeper);
        (bool ok,) = address(kernel).call{gas: m}(abi.encodeCall(IKernelMin.settle, ()));
        assertTrue(ok, "funded with minSettleGas");
        Record memory r = _rec(kernel.count());
        assertEq(
            r.flags,
            RecordFlags.GRADUATED | RecordFlags.BUY_SHRUNK | RecordFlags.SEALED,
            "sealed answer; no leg failed for lack of gas"
        );
        assertGt(r.buyExecuted, 0);
        assertGt(r.tokensOut, r.buyExecuted);
        assertGt(r.nativeIn, 0);
    }

    /// The costliest settle of all: both claims expensive, TapeOut's step burning its gas and failing, the
    /// sealed evaluator needing nearly all of its own, an expensive burn, and a swap that burns its whole
    /// allowance and fails, after which the pair's lock is probed (and, not being held, the probe burns its
    /// allowance too). Sent with exactly minSettleGas it completes; the failed swap is flag 32.
    function test_minSettleGas_is_enough_when_the_swap_burns_its_gas_and_the_lock_is_probed() public {
        _graduatedScenario();
        vault.setBurnGas(60_000);
        token.setBurnGas(70_000);
        router.setMode(2); // burns all of G_SWAP, then fails with no revert data
        circuits.setStepMode(2);
        sealedVM.setStepBurn(SEALED_FLOOR - 40_000);
        uint256 m = kernel.minSettleGas();
        vm.prank(keeper);
        (bool ok,) = address(kernel).call{gas: m}(abi.encodeCall(IKernelMin.settle, ()));
        assertTrue(ok, "funded with minSettleGas");
        Record memory r = _rec(kernel.count());
        assertEq(
            r.flags,
            RecordFlags.GRADUATED | RecordFlags.BUY_SHRUNK | RecordFlags.SEALED | RecordFlags.BUY_FAILED,
            "the swap failed for every caller: flag 32, not a revert"
        );
        assertGt(r.buyExecuted, 0, "the burn leg ran");
        assertEq(r.nativeIn, 0);
    }

    /// A graduated settle whose swap fails, at every gas limit: the pair-lock probe that follows a failed swap
    /// gets its allowance or the settle reverts as a whole, like every other call.
    function test_gasSweep_graduated_failing_swap_each_guard_alone() public {
        _useNoFloorKernel();
        _graduatedScenario();
        router.setMode(1);
        _sweep(20_000, 8_000_000, 4_000);
        Record memory r = _settleAndGet();
        assertTrue(_has(r.flags, RecordFlags.BUY_FAILED));
        assertGt(r.buyExecuted, 0);
    }

    /// The probe's own guard, seen from outside. TapeOut's step and the swap each use up nearly everything
    /// they are given, and the swap then fails, so the kernel reaches the probe with only what its swap guard
    /// kept back. The pair is asked only once the question can be given its whole allowance: the smallest gas
    /// limit at which sync() is called lies well above the smallest at which the router is called.
    function test_gasSweep_the_lock_probe_gets_its_whole_allowance_or_is_not_made() public {
        _useNoFloorKernel();
        _graduatedScenario();
        circuits.setStepBurn(STEP_FLOOR - 60_000);
        router.setMode(2); // burns all of G_SWAP, then fails with no revert data
        uint256 gSwap;
        uint256 gProbe;
        for (uint256 g = 6_700_000; g <= 7_400_000 && gProbe == 0; g += 2_000) {
            (bool swapped, bool probed) = _swapAndProbeAt(g);
            assertTrue(swapped || !probed, "the pair is asked only after a swap");
            if (swapped && gSwap == 0) gSwap = g;
            if (probed) gProbe = g;
        }
        assertGt(gSwap, 6_700_000, "the sweep started below the swap and reached it");
        assertGt(gProbe, 0, "and the probe");
        emit log_named_uint("smallest gas limit at which the router is called", gSwap);
        emit log_named_uint("smallest gas limit at which the pair is asked", gProbe);
        // after the swap the kernel holds about G_SWAP / 63 + 20,000 (what its swap guard kept back) less the
        // 11,600 the value-carrying call to a cold router costs the caller; the probe needs
        // G_VIEW + G_VIEW / 63 + 20,000 in hand: about 102,000 more, a little more still at the caller
        assertGt(gProbe - gSwap, 95_000, "not asked with less than its whole allowance in hand");
        assertLt(gProbe - gSwap, 115_000);
        (bool ok, bytes32 d,) = _attempt(30_000_000);
        assertTrue(ok && d != bytes32(0), "and with ample gas the same settle returns, the failed swap a flag");
    }

    /// @dev One settle attempt with a gas limit: was the router called, and was the pair's sync() called.
    function _swapAndProbeAt(uint256 gasLimit) internal returns (bool swapped, bool probed) {
        uint256 snap = vm.snapshotState();
        vm.startStateDiffRecording();
        vm.prank(keeper);
        (bool ok,) = address(kernel).call{gas: gasLimit}(abi.encodeCall(IKernelMin.settle, ()));
        ok;
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        for (uint256 i = 0; i < acc.length; i++) {
            if (acc[i].data.length < 4) continue;
            if (acc[i].account == address(router)) swapped = true;
            if (acc[i].account == address(pair) && bytes4(acc[i].data) == MockPair.sync.selector) probed = true;
        }
        vm.revertToState(snap);
    }

    /// The whole budget is needed for nothing but the two steps: with both evaluators dead and burning,
    /// a settle through a calling contract with exactly minSettleGas still reaches the fallback word.
    function test_minSettleGas_is_enough_when_both_evaluators_burn_their_gas() public {
        _curveScenario();
        _killBoth(2);
        vm.warp(block.timestamp + 10 * EPOCH);
        Forwarder f = new Forwarder();
        f.forward{gas: kernel.minSettleGas()}(address(kernel));
        Record memory r = _rec(kernel.count());
        assertTrue(_has(r.flags, RecordFlags.FALLBACK));
        assertGt(r.buyExecuted, 0);
    }

    /// One wei of gas below the kernel's own first check is refused before anything happens; the check
    /// counts both evaluators' allowances.
    function test_first_check_counts_both_evaluators() public {
        _curveScenario();
        uint256 budget = 600_000 + 2 * _wm(G_CLAIM) + 15 * _wm(G_VIEW) + _wm(G_NETLIST) + _wm(STEP_FLOOR)
            + _wm(SEALED_FLOOR) + _wm(G_TRANSFER) + _wm(G_SWAP);
        // a limit that would pass a first check that left out the sealed evaluator's share (and this settle,
        // in which TapeOut answers, would then complete): it is refused up front
        (bool ok,, bytes4 err) = _attempt(budget - _wm(SEALED_FLOOR) + 300_000);
        assertFalse(ok);
        assertEq(err, Kernel.InsufficientGas.selector);
        assertEq(kernel.count(), 1, "nothing happened");
        (ok,,) = _attempt(kernel.minSettleGas());
        assertTrue(ok);
    }

    function test_minSettleGas_is_enough_when_every_leg_is_expensive_graduated() public {
        _graduatedScenario();
        vault.setBurnGas(60_000); // each claim: the vault's work plus one token transfer
        token.setBurnGas(70_000); // every token transfer
        router.setBurnGas(350_000); // the swap, plus the token transfer inside it
        circuits.setStepBurn(STEP_FLOOR - 40_000);
        uint256 m = kernel.minSettleGas();
        vm.prank(keeper);
        (bool ok,) = address(kernel).call{gas: m}(abi.encodeCall(IKernelMin.settle, ()));
        assertTrue(ok, "funded with minSettleGas");
        Record memory r = _rec(kernel.count());
        assertEq(r.flags, RecordFlags.GRADUATED | RecordFlags.BUY_SHRUNK, "no leg failed for lack of gas");
        assertGt(r.buyExecuted, 0);
        assertGt(r.tokensOut, r.buyExecuted);
    }

    function test_settle_through_a_calling_contract_with_minSettleGas() public {
        _curveScenario();
        Forwarder f = new Forwarder();
        uint256 m = kernel.minSettleGas();
        // the forwarder keeps 1/64; minSettleGas already includes that
        f.forward{gas: m}(address(kernel));
        assertEq(kernel.count(), 2);
    }

    // ------------------------------------------------------------------ helpers

    function _settleAndGet() internal returns (Record memory) {
        return _rec(_settle());
    }
}

contract Forwarder {
    function forward(address kernel) external {
        (bool ok, bytes memory ret) = kernel.call(abi.encodeCall(IKernelMin.settle, ()));
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}
