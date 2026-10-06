// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseV2.t.sol";
import {KernelV2GasPins} from "../utils/GasPinsV2.sol";

/// @dev The kernel without its first, whole-settle gas check: one guard is left in front of every external call,
///      so a sweep of the gas limit crosses each of them on its own (kernel v1's technique).
contract KernelV2NoFloor is KernelV2 {
    function _minSettleGas(uint256, uint256) internal pure override returns (uint256) {
        return 0;
    }
}

/// @notice The caller's gas limit must never decide an outcome: for every gas limit a v2 settle either reverts as
///         a whole or writes exactly the record it writes with unlimited gas. The new external calls of v2 (the
///         quote asset's balanceOf, approve and allowance, and the ERC-20 claim) are guarded like v1's.
contract GasV2Test is BaseV2 {
    bytes14 internal W = _word(128, 64, 48, 16, 64, 1023);

    // KernelV2's allowances, repeated on purpose
    uint256 internal constant G_VIEW = 100_000;
    uint256 internal constant G_NETLIST = 500_000;
    uint256 internal constant G_CLAIM = 350_000;
    uint256 internal constant G_APPROVE = 200_000;
    uint256 internal constant G_BUY = 700_000;
    uint256 internal constant G_TRANSFER = 200_000;
    uint256 internal constant G_SWAP = 700_000;
    uint256 internal constant STEP_FLOOR = 200_000 + 2_600 * 2200 + 800 * 64;
    uint256 internal constant SEALED_FLOOR = 40_000 + 200 * (2200 - 64) + 400 * 64;

    MockPair internal pair;

    function _useNoFloorKernel() internal {
        vm.etch(factory.kernelImpl(), address(new KernelV2NoFloor()).code);
    }

    function _digest() internal view returns (bytes32) {
        uint32 n = kernel.count();
        (uint128 cum, uint128 paid) = kernel.cums(n);
        bytes32 a = keccak256(abi.encode(n, kernel.records(n), cum, paid, kernel.state(), kernel.reserve()));
        bytes32 b = keccak256(
            abi.encode(
                kernel.lockedTokens(),
                kernel.burnedTokens(),
                kernel.graduated(),
                usdt.balanceOf(address(kernel)),
                token.balanceOf(address(kernel)),
                usdt.balanceOf(address(vault)),
                token.balanceOf(address(vault))
            )
        );
        bytes32 c = keccak256(
            abi.encode(
                token.balanceOf(DEAD),
                kernel.creditOf(payee, address(usdt)),
                usdt.allowance(address(kernel), address(manager)),
                usdt.allowance(address(kernel), address(router))
            )
        );
        return keccak256(abi.encode(a, b, c));
    }

    function _attempt(uint256 gasLimit) internal returns (bool ok, bytes32 digest, bytes4 err) {
        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        bytes memory ret;
        (ok, ret) = address(kernel).call{gas: gasLimit}(abi.encodeCall(IKernelMin.settle, ()));
        if (ok) digest = _digest();
        else if (ret.length >= 4) err = bytes4(ret);
        vm.revertToState(snap);
    }

    function _sweep(uint256 from, uint256 to, uint256 step_) internal returns (uint256 minOk) {
        (bool okRef, bytes32 ref,) = _attempt(40_000_000);
        assertTrue(okRef, "the reference settle succeeds with ample gas");
        uint32 before = kernel.count();
        for (uint256 g = from; g <= to; g += step_) {
            (bool ok, bytes32 d, bytes4 err) = _attempt(g);
            if (ok) {
                assertEq(d, ref, "a settle that returned wrote exactly what the unlimited one writes");
                if (minOk == 0) minOk = g;
            } else {
                assertTrue(err == KernelV2.InsufficientGas.selector || err == bytes4(0), "reverted for lack of gas only");
                assertEq(kernel.count(), before);
            }
        }
        assertGt(minOk, 0, "the sweep reached a successful settle");
    }

    function _settleAndGet() internal returns (RecordV2 memory) {
        _settle();
        return _rec(kernel.count());
    }

    function _curveScenario() internal {
        _fixture(W);
        _buy(alice, 100e6);
        _nextEpoch();
        _settle();
        _buy(alice, 500e6);
        _revenue(5e6);
        _nextEpoch();
        // the next settle claims, steps, credits, releases a quarter of the reserve and buys at the cap
    }

    function _graduatedScenario() internal {
        _fixture(W);
        _buy(alice, 300e6);
        _nextEpoch();
        _settle();
        pair = _graduate();
        _nextEpoch();
        _settle();
        _v2Buy(alice, 50e6);
        _revenue(3e6);
        _nextEpoch();
        // the next settle claims both assets, steps, burns, approves the router and swaps the pot
    }

    function test_gasSweep_curve_each_guard_alone() public {
        _useNoFloorKernel();
        _curveScenario();
        uint256 minOk = _sweep(20_000, 7_000_000, 3_000);
        assertGt(minOk, STEP_FLOOR + STEP_FLOOR / 63, "no settle with less than the step needs");
        RecordV2 memory r = _settleAndGet();
        assertGt(r.buyExecuted, 0, "the scenario really bought");
        assertEq(r.flags & (RecordFlags.BUY_FAILED | RecordFlags.CLAIM_FAILED), 0);
    }

    function test_gasSweep_graduated_each_guard_alone() public {
        _useNoFloorKernel();
        _graduatedScenario();
        uint256 minOk = _sweep(20_000, 7_000_000, 3_000);
        assertGt(minOk, STEP_FLOOR + STEP_FLOOR / 63);
        RecordV2 memory r = _settleAndGet();
        assertGt(r.buyExecuted, 0, "the scenario really burned");
        assertGt(r.quoteIn, 0, "and really swapped USD0");
        assertEq(r.flags & (RecordFlags.BUY_FAILED | RecordFlags.CLAIM_FAILED), 0);
    }

    function test_gasSweep_caller_cannot_force_the_fallback() public {
        _useNoFloorKernel();
        _fixture(W);
        _revenue(3e6);
        circuits.setStepBurn(STEP_FLOOR - 60_000);
        vm.warp(block.timestamp + 10 * EPOCH);
        _sweep(20_000, 7_500_000, 3_000);
        RecordV2 memory r = _settleAndGet();
        assertFalse(_has(r.flags, RecordFlags.FALLBACK), "the chip decided at every gas limit that returned");
        assertEq(r.outputs, W);
    }

    function test_gasSweep_tapeout_dead_sealed_answers_each_guard_alone() public {
        _useNoFloorKernel();
        _fixture(W);
        _revenue(3e6);
        circuits.setStepMode(2);
        sealedVM.setStepBurn(SEALED_FLOOR - 40_000);
        vm.warp(block.timestamp + 10 * EPOCH);
        uint256 minOk = _sweep(20_000, 9_000_000, 3_000);
        assertGt(minOk, STEP_FLOOR + SEALED_FLOOR);
        RecordV2 memory r = _settleAndGet();
        assertTrue(_has(r.flags, RecordFlags.SEALED));
        assertFalse(_has(r.flags, RecordFlags.FALLBACK));
    }

    /// The new v2 calls, each made expensive: the ERC-20 claim, the quote's balanceOf, approve and allowance,
    /// the buy. Every gas limit still gives revert-or-identical, and nothing fails for lack of gas.
    function test_gasSweep_expensive_quote_legs_each_guard_alone() public {
        _useNoFloorKernel();
        _curveScenario();
        // each leg made expensive but kept under its allowance: the claim (vault + one USD0 transfer) under
        // G_CLAIM, the buy (Manager + pull + tax + token transfer) under G_BUY
        vault.setBurnGas(120_000);
        manager.setBurnGas(300_000);
        usdt.setBurnGas(30_000); // every USD0 transfer (the claim, the pull, the tax) burns this much
        circuits.setStepBurn(STEP_FLOOR - 60_000);
        _sweep(100_000, 9_000_000, 4_000);
        RecordV2 memory r = _settleAndGet();
        assertEq(r.flags & (RecordFlags.BUY_FAILED | RecordFlags.CLAIM_FAILED), 0, "expensive is not failed");
        assertGt(r.buyExecuted, 0);
    }

    function testFuzz_any_gas_limit_reverts_or_fully_succeeds(uint256 gasLimit, bool grad) public {
        _useNoFloorKernel();
        if (grad) _graduatedScenario();
        else _curveScenario();
        gasLimit = bound(gasLimit, 0, 8_000_000);
        (, bytes32 ref,) = _attempt(40_000_000);
        (bool ok, bytes32 d, bytes4 err) = _attempt(gasLimit);
        if (ok) assertEq(d, ref);
        else assertTrue(err == KernelV2.InsufficientGas.selector || err == bytes4(0));
    }

    // ------------------------------------------------------------------ the real kernel: minSettleGas

    function _wm(uint256 g) internal pure returns (uint256) {
        return g + g / 63 + 20_000;
    }

    /// The constants restated above are the kernel's own (read through KernelV2GasPins), and the curve leg stays
    /// below the graduated legs: raising G_BUY from 600,000 to 700,000 (review B-F8) left minSettleGas unchanged.
    function test_restated_constants_are_the_kernels() public {
        KernelV2GasPins p = new KernelV2GasPins();
        assertEq(p.gView(), G_VIEW);
        assertEq(p.gNetlist(), G_NETLIST);
        assertEq(p.gClaim(), G_CLAIM);
        assertEq(p.gApprove(), G_APPROVE);
        assertEq(p.gBuy(), G_BUY);
        assertEq(p.gTransfer(), G_TRANSFER);
        assertEq(p.gSwap(), G_SWAP);
        assertEq(p.gSelf(), 600_000);
        assertEq(p.nViews(), 18);
        assertLt(_wm(G_BUY) + 2 * _wm(G_APPROVE), _wm(G_TRANSFER) + _wm(G_SWAP) + 2 * _wm(G_APPROVE));
        _fixture(W);
        GlobalsV2 memory g = kernel.globals();
        uint256 m = p.minSettleGasOf(g.stepFloor, g.sealedFloor) + 40_000;
        m = m + m / 63 + 5_000;
        m = m + m / 63 + 5_000;
        assertEq(kernel.minSettleGas(), m + 30_000);
        assertEq(kernel.minSettleGas(), 12_542_576, "the 2,200-gate chip's figure, as before the G_BUY change");
    }

    function test_minSettleGas_formula() public {
        _fixture(W);
        // 18 view-sized calls (17 on the longest path, the first graduated settle with a successful swap, plus
        // one); the graduated legs (burn, approve, swap, reset) are the larger pair
        uint256 m = 600_000 + 2 * _wm(G_CLAIM) + 18 * _wm(G_VIEW) + _wm(G_NETLIST) + _wm(STEP_FLOOR)
            + _wm(SEALED_FLOOR) + _wm(G_TRANSFER) + _wm(G_SWAP) + 2 * _wm(G_APPROVE) + 40_000;
        m = m + m / 63 + 5_000;
        m = m + m / 63 + 5_000;
        assertEq(kernel.minSettleGas(), m + 30_000);
        emit log_named_uint("minSettleGas, 2,200-gate fixture chip", kernel.minSettleGas());
        assertLt(kernel.minSettleGas(), 13_000_000);
    }

    function test_below_minSettleGas_reverts_before_anything_moves() public {
        _curveScenario();
        uint256 m = kernel.minSettleGas();
        (bool ok,, bytes4 err) = _attempt(m - 500_000);
        assertFalse(ok);
        assertEq(err, KernelV2.InsufficientGas.selector);
        (ok,,) = _attempt(m);
        assertTrue(ok, "minSettleGas is enough");
    }

    function test_minSettleGas_is_enough_when_every_leg_is_expensive_curve() public {
        _curveScenario();
        vault.setBurnGas(120_000);
        manager.setBurnGas(300_000);
        usdt.setBurnGas(30_000);
        circuits.setStepMode(2);
        sealedVM.setStepBurn(SEALED_FLOOR - 40_000);
        uint256 m = kernel.minSettleGas();
        vm.prank(keeper);
        (bool ok,) = address(kernel).call{gas: m}(abi.encodeCall(IKernelMin.settle, ()));
        assertTrue(ok, "funded with minSettleGas");
        RecordV2 memory r = _rec(kernel.count());
        assertEq(r.flags & (RecordFlags.BUY_FAILED | RecordFlags.CLAIM_FAILED), 0, "no leg failed for lack of gas");
        assertTrue(_has(r.flags, RecordFlags.SEALED));
        assertGt(r.buyExecuted, 0);
    }

    function test_minSettleGas_is_enough_in_the_costliest_graduated_settle() public {
        _fixture(W);
        _buy(alice, 300e6);
        _nextEpoch();
        _settle();
        pair = _graduate();
        _v2Buy(alice, 50e6);
        _nextEpoch(); // the first graduated settle: the latch read is on the path too
        vault.setBurnGas(120_000);
        router.setBurnGas(450_000);
        token.setBurnGas(30_000);
        usdt.setBurnGas(30_000);
        circuits.setStepMode(2);
        sealedVM.setStepBurn(SEALED_FLOOR - 40_000);
        uint256 m = kernel.minSettleGas();
        vm.prank(keeper);
        (bool ok,) = address(kernel).call{gas: m}(abi.encodeCall(IKernelMin.settle, ()));
        assertTrue(ok, "funded with minSettleGas");
        RecordV2 memory r = _rec(kernel.count());
        assertTrue(_has(r.flags, RecordFlags.GRADUATED));
        assertEq(r.flags & (RecordFlags.BUY_FAILED | RecordFlags.CLAIM_FAILED), 0, "no leg failed for lack of gas");
        assertGt(r.quoteIn, 0);
    }

    function test_settle_through_a_calling_contract_with_minSettleGas() public {
        _curveScenario();
        uint256 m = kernel.minSettleGas();
        Caller c = new Caller();
        (bool ok,) = address(c).call{gas: m}(abi.encodeCall(Caller.settle, (address(kernel))));
        assertTrue(ok, "a contract with minSettleGas left can settle (the KeeperTank's case)");
        assertEq(kernel.count(), 2);
    }
}

contract Caller {
    function settle(address k) external {
        IKernelMin(k).settle();
    }
}
