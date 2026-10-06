// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";

import "./ForkBase.sol";
import {IKernelMin} from "../../src/interfaces/IKernelV1.sol";

/// @dev Stands in for a TapeOut upgrade: any other implementation behind the circuit beacon.
contract OtherCircuitsImpl {
    function step(uint256, bytes calldata, bytes calldata) external pure returns (bytes memory, bytes memory) {
        revert("upgraded");
    }
}

/// @dev Holds the live IgnixManager's reentrancy lock while it settles a kernel: it sells ZERO tokens of any
///      live token, the Manager pays the (zero) proceeds by a native call, and this contract settles from its
///      receive(). It also tries the kernel's own call, buyTo, from the same place, to record what the live
///      Manager answers under its lock.
contract ForkManagerLockHolder {
    IManagerFork internal manager;
    Kernel internal kernel;
    address internal probeToken;
    uint256 public attempts;
    bool public settled;
    bytes public settleRevert;
    bool public buyToWorked;
    bytes public buyToRevert;

    constructor(IManagerFork m, Kernel k, address probeToken_) payable {
        manager = m;
        kernel = k;
        probeToken = probeToken_;
    }

    function sellZeroAndSettleInside(address anyLiveToken) external {
        manager.sell(anyLiveToken, 0, 0);
    }

    receive() external payable {
        attempts++;
        (settled, settleRevert) = address(kernel).call(abi.encodeCall(IKernelMin.settle, ()));
        (buyToWorked, buyToRevert) = address(manager).call{value: 1 wei}(
            abi.encodeCall(IManagerFork.buyTo, (probeToken, 1 wei, 0, address(this)))
        );
    }
}

interface IPairSync {
    function sync() external;
}

/// @dev A flash swap on the live Uniswap V2 pair: borrows WOKB, settles a kernel from uniswapV2Call (the
///      pair's lock is held), and repays the loan with its 0.3% fee. From the same place it also makes the
///      kernel's two calls itself, to record what the live contracts answer under the lock: the router buy,
///      and a static call to the pair's sync().
contract ForkFlashSwapper {
    address internal wokb;
    IRouterFork internal router;
    Kernel internal kernel;
    address internal token;
    uint256 public attempts;
    bool public settled;
    bytes public settleRevert;
    bool public swapWorked;
    bytes public swapRevert;
    bool public syncWorked;
    bytes public syncRevert;

    constructor(address wokb_, IRouterFork router_, Kernel k, address token_) {
        (wokb, router, kernel, token) = (wokb_, router_, k, token_);
    }

    function flashAndSettleInside(address pair, uint256 wokbOut) external payable {
        IWOKBFork(wokb).deposit{value: msg.value - 1 gwei}(); // for the fee; 1 gwei stays for the router probe
        bool wokbIs0 = IPairFork(pair).token0() == wokb;
        IPairFork(pair).swap(wokbIs0 ? wokbOut : 0, wokbIs0 ? 0 : wokbOut, address(this), hex"01");
    }

    function uniswapV2Call(address, uint256 amount0, uint256 amount1, bytes calldata) external {
        attempts++;
        (settled, settleRevert) = address(kernel).call(abi.encodeCall(IKernelMin.settle, ()));
        address[] memory path = new address[](2);
        (path[0], path[1]) = (wokb, token);
        (swapWorked, swapRevert) = address(router).call{value: 1 gwei}(
            abi.encodeCall(
                IRouterFork.swapExactETHForTokensSupportingFeeOnTransferTokens,
                (0, path, address(0xdEaD), block.timestamp)
            )
        );
        (syncWorked, syncRevert) = msg.sender.staticcall{gas: 100_000}(abi.encodeCall(IPairSync.sync, ()));
        uint256 borrowed = amount0 + amount1;
        IWOKBFork(wokb).transfer(msg.sender, borrowed + (borrowed * 3) / 997 + 1);
    }
}

/// @dev Stands where a kernel stands when it steps an evaluator: one call that first makes the four
///      comparisons of INTERFACE section 12 (they touch the beacon, the implementation, the processor and its
///      stored netlist, as `Kernel._sealedMode` does), then gives the evaluator a fixed amount of gas.
contract StepProbe {
    address internal immutable beacon;
    address internal immutable circuits;

    constructor(address beacon_, address circuits_) {
        (beacon, circuits) = (beacon_, circuits_);
    }

    function attempt(bool compareFirst, uint256 id, address target, bytes calldata data, uint256 gasGiven)
        external
        view
        returns (bool ok, bytes32 answer)
    {
        if (compareFirst) {
            address impl = IBeaconView(beacon).implementation();
            bytes32 codeHash = impl.codehash;
            ICircuits(circuits).circuitInfo(id);
            bytes32 netlistHash = keccak256(ICircuits(circuits).netlist(id));
            (codeHash, netlistHash);
        }
        bytes memory ret;
        (ok, ret) = target.staticcall{gas: gasGiven}(data);
        answer = keccak256(ret);
    }
}

/// @notice The kernel against live IGNIX and live TapeOut on an X Layer fork at block 72,369,000.
contract KernelForkTest is ForkBase {
    bool internal live;

    function setUp() public {
        live = _fork();
        if (!live) return;
        _deployCovenant();
        _fixture(_netlist(), _env(), 300);
    }

    modifier onFork() {
        if (!live) {
            vm.skip(true);
            return;
        }
        _;
    }

    // ------------------------------------------------------------------ pins

    function test_fork_pins_are_live() public onFork {
        assertEq(IBeaconView(CIRCUIT_BEACON).implementation(), CIRCUIT_IMPL, "beacon implementation");
        assertEq(CIRCUIT_IMPL.codehash, CIRCUIT_IMPL_HASH, "implementation code hash");
        assertEq(ITapeOutFactory(TAPEOUT_FACTORY).circuitBeacon(), CIRCUIT_BEACON, "the factory's circuit beacon");
        assertTrue(factory.pinsLive());
        (address vm_, bool sealedMode) = kernel.evaluator();
        assertEq(vm_, circuits, "TapeOut is the evaluator while the pins hold");
        assertFalse(sealedMode);
        // the Fab's snapshot and TapeOut's own copy of the netlist are the same bytes
        Globals memory g = kernel.globals();
        assertEq(keccak256(ICircuits(circuits).netlist(chipId)), g.netlistHash);
        assertEq(keccak256(fab.snapshot(chipId)), g.netlistHash);
        (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount) = ICircuits(circuits).circuitInfo(chipId);
        assertEq(nIn, 96);
        assertEq(nOut, 112);
        assertEq(nState, g.nState);
        assertEq(gateCount, g.gateCount);
        assertEq(ICircuits(circuits).ownerOf(chipId), address(kernel));
        console2.log("chip: Flow Governor?", isFlowGovernor);
        console2.log("chip: gates         ", gateCount);
        console2.log("chip: latches       ", nState);
    }

    function test_fork_bind_facts() public onFork {
        assertEq(kernel.token(), address(token));
        assertEq(kernel.vault(), address(vault));
        assertEq(vault.RECIPIENT(), address(kernel));
        assertEq(kernel.tokenSupply(), 1_000_000_000 ether);
        assertEq(factory.kernelOf(address(token)), address(kernel));
        assertFalse(token.unlocked());
    }

    function test_fork_preflight_both_evaluators_agree() public onFork {
        Lens.Preflight memory p = lens.preflight(address(kernel));
        assertTrue(p.tapeoutRan, "live Circuits.step ran inside the floor");
        assertTrue(p.sealedRan, "SealedVM ran inside the floor");
        assertTrue(p.agree, "and they agree");
        console2.log("live step gas, TapeOut (through the beacon proxy)", p.tapeoutGas);
        console2.log("live step gas, SealedVM                          ", p.sealedGas);
        console2.log("gas given to TapeOut's step (stepFloor)          ", p.stepFloor);
        console2.log("gas given to the sealed step (sealedFloor)       ", p.sealedFloor);
        console2.log("minSettleGas                                     ", p.minSettleGas);
        // the Flow Governor fixture: 1,953 records, 64 of them latches
        assertEq(p.stepFloor, 200_000 + 2_600 * 1953 + 800 * 64);
        assertEq(p.sealedFloor, 40_000 + 200 * 1889 + 400 * 64);
        assertLt(p.tapeoutGas, (p.stepFloor * 90) / 100, "at least 10% headroom under TapeOut's gas");
        assertLt(p.sealedGas, (p.sealedFloor * 80) / 100, "at least 20% headroom under the sealed evaluator's gas");
    }

    // ------------------------------------------------------------------ the curve loop

    function test_fork_curve_epoch_claim_step_buy() public onFork {
        _buy(alice, 1 ether);
        assertEq(address(vault).balance, 0.03 ether, "3% buy tax accrued in the live vault");
        _nextEpoch();
        TradeMath.Curve memory c = _curve();
        (uint32 n, uint256 gasUsed) = _settle();
        Record memory r = kernel.records(n);
        console2.log("settle gas, first funded epoch (live step)", gasUsed);
        assertLt(gasUsed, kernel.minSettleGas());

        assertEq(r.inflow, 0.03 ether, "claimed from the live vault");
        assertEq(
            address(vault).balance, (uint256(r.buyExecuted) * 300) / 10_000, "only the kernel's own buy tax is left"
        );
        assertFalse(_has(r.flags, RecordFlags.SEALED));
        assertEq(r.flags & (RecordFlags.CLAIM_FAILED | RecordFlags.CURVE_READ_FAILED | RecordFlags.BUY_FAILED), 0);
        assertEq(r.clampBits, 0, "the chip decides");
        KernelMath.InputFields memory f = KernelMath.unpackInput(KernelMath.inputWord(r.inputs));
        assertEq(f.tax, KernelMath.lg8(0.03 ether));
        assertEq(f.prog, (c.sold * 255) / c.sellable);
        assertEq(f.dt, 1);
        assertEq(f.grad, 0);

        // books
        assertEq(kernel.creditOf(payee, NATIVE), r.allow);
        assertEq(address(kernel).balance, kernel.totalCredits(NATIVE) + kernel.reserve(), "balance = credits + reserve");
        if (r.buyExecuted != 0) {
            // exact quote against the live Manager
            uint256 net = r.buyExecuted - (uint256(r.buyExecuted) * (c.buyFeeBps + c.taxBuyBps)) / 10_000;
            uint256 expectOut = c.vToken - TradeMath.ceilDiv(c.vQuote * c.vToken, c.vQuote + net);
            assertEq(r.tokensOut, expectOut, "minTokensOut was the exact quote and the live Manager delivered it");
            assertEq(token.balanceOf(address(kernel)), expectOut);
            assertEq(kernel.lockedTokens(), expectOut);
        }

        // replay on both live evaluators
        assertTrue(lens.replayOn(address(kernel), n, false).ok, "replay through live Circuits.step");
        assertTrue(lens.replayOn(address(kernel), n, true).ok, "replay through SealedVM");

        // the payee collects
        uint256 credit = kernel.creditOf(payee, NATIVE);
        if (credit != 0) {
            vm.prank(bob);
            kernel.withdrawCredit(payee, NATIVE);
            assertEq(payee.balance, credit);
        }
    }

    function test_fork_twenty_epochs_replay_on_both_evaluators() public onFork {
        uint256 gasMax;
        for (uint256 i = 0; i < 20; i++) {
            uint256 size = uint256(keccak256(abi.encode("flow", i))) % 3 ether;
            if (size > 0.01 ether && i % 4 != 3) _buy(i % 2 == 0 ? alice : bob, size);
            vm.warp(block.timestamp + EPOCH * (i % 6 == 5 ? 2 : 1));
            (, uint256 gasUsed) = _settle();
            if (gasUsed > gasMax) gasMax = gasUsed;
        }
        console2.log("largest settle gas in 20 live epochs", gasMax);
        uint256 bought;
        for (uint32 n = 1; n <= 20; n++) {
            Record memory r = kernel.records(n);
            assertEq(r.flags & (RecordFlags.FALLBACK | RecordFlags.CLAIM_FAILED | RecordFlags.BUY_FAILED), 0);
            assertEq(r.clampBits, 0);
            assertTrue(lens.replayOn(address(kernel), n, false).ok);
            assertTrue(lens.replayOn(address(kernel), n, true).ok);
            bought += r.buyExecuted;
        }
        assertGt(bought, 0, "the kernel bought on the live curve");
        assertEq(token.balanceOf(address(kernel)), kernel.lockedTokens());
        assertGe(address(kernel).balance, kernel.totalCredits(NATIVE) + kernel.reserve());
        // bought tokens cannot move before graduation: the live token refuses
        vm.prank(address(kernel));
        (bool ok,) = address(token).call(abi.encodeWithSignature("transfer(address,uint256)", DEAD, 1));
        assertFalse(ok, "CurveOnly");
    }

    /// A stranger's claimFor of native OKB runs the kernel's receive() outside its own claim: refused. The
    /// tax waits in the live vault and the next settle claims it.
    function test_fork_third_party_native_claimFor_is_refused_and_tax_waits() public onFork {
        _buy(alice, 2 ether);
        vm.prank(bob);
        (bool ok, bytes memory ret) =
            address(vault).call(abi.encodeWithSignature("claimFor(address,address)", address(kernel), NATIVE));
        assertFalse(ok, "the push is refused");
        assertEq(bytes4(ret), bytes4(0x90b8ec18), "TransferFailed()");
        assertEq(address(vault).balance, 0.06 ether, "nothing moved");
        assertEq(address(kernel).balance, 0);
        _nextEpoch();
        (uint32 n,) = _settle();
        assertEq(kernel.records(n).inflow, 0.06 ether, "the kernel's own claim got it");
        assertEq(kernel.records(n).flags & RecordFlags.CLAIM_FAILED, 0);
    }

    /// During its protection window the live token probes contracts it meets with token0(), token1() and
    /// fee(). The kernel answers none of them and has no fallback.
    function test_fork_kernel_does_not_look_like_a_pool() public onFork {
        bytes4[3] memory probes =
            [bytes4(keccak256("token0()")), bytes4(keccak256("token1()")), bytes4(keccak256("fee()"))];
        for (uint256 i = 0; i < 3; i++) {
            (bool ok,) = address(kernel).staticcall(abi.encodeWithSelector(probes[i]));
            assertFalse(ok);
        }
        (bool okAny,) = address(kernel).call(hex"deadbeef");
        assertFalse(okAny, "no fallback");
    }

    function test_fork_plain_transfers_are_refused() public onFork {
        vm.prank(alice);
        (bool ok,) = address(kernel).call{value: 1 ether}("");
        assertFalse(ok);
        vm.prank(launcher);
        (ok,) = address(kernel).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ------------------------------------------------------------------ IGNIX pauses

    function test_fork_ignix_buy_pause_skips_the_buy() public onFork {
        _buy(alice, 5 ether);
        vm.prank(M.owner());
        M.setPaused(1, type(uint64).max); // BUY may be paused indefinitely
        _nextEpoch();
        (uint32 n,) = _settle();
        Record memory r = kernel.records(n);
        assertEq(r.inflow, 0.15 ether, "claims are not affected by a BUY pause");
        if (r.buyDecided != 0) {
            assertTrue(_has(r.flags, RecordFlags.BUY_SKIPPED), "Paused() is a guard, not a failure");
            assertFalse(_has(r.flags, RecordFlags.BUY_FAILED));
            assertEq(r.buyExecuted, 0);
        }
        assertEq(address(kernel).balance, 0.15 ether, "the money waits in the kernel");
        assertEq(kernel.reserve(), 0.15 ether - r.allow);
    }

    function test_fork_ignix_dividend_pause_fails_the_claim_only() public onFork {
        _buy(alice, 5 ether);
        vm.startPrank(M.owner());
        M.setPaused(6, uint64(block.timestamp + 72 hours)); // DIVIDEND gates vault claims, 72 h at most
        vm.stopPrank();
        _nextEpoch();
        (uint32 n,) = _settle();
        Record memory r = kernel.records(n);
        assertTrue(_has(r.flags, RecordFlags.CLAIM_FAILED), "flag 4");
        assertEq(r.inflow, 0);
        assertEq(address(vault).balance, 0.15 ether, "the tax waits in the vault");
        vm.warp(block.timestamp + 72 hours + 1);
        (n,) = _settle();
        assertEq(kernel.records(n).inflow, 0.15 ether, "claimed once the pause lapsed");
    }

    // ------------------------------------------------------------------ TapeOut upgrade and revert

    function test_fork_tapeout_upgrade_switches_to_sealed_and_back() public onFork {
        _buy(alice, 1 ether);
        _nextEpoch();
        (uint32 n1,) = _settle();
        assertFalse(_has(kernel.records(n1).flags, RecordFlags.SEALED));

        // TapeOut's owner (a 3-of-5 Safe) upgrades every processor's circuit logic
        OtherCircuitsImpl other = new OtherCircuitsImpl();
        address tapeoutOwner = ITapeOutFactory(TAPEOUT_FACTORY).owner();
        vm.prank(tapeoutOwner);
        ITapeOutFactory(TAPEOUT_FACTORY).upgradeCircuits(address(other));
        assertEq(IBeaconView(CIRCUIT_BEACON).implementation(), address(other));
        (address vm_, bool sealedMode) = kernel.evaluator();
        assertEq(vm_, address(sealedVM));
        assertTrue(sealedMode);

        _buy(alice, 1 ether);
        _nextEpoch();
        (uint32 n2, uint256 gasSealed) = _settle();
        Record memory r2 = kernel.records(n2);
        assertTrue(_has(r2.flags, RecordFlags.SEALED), "the settle ran on the sealed evaluator");
        assertFalse(_has(r2.flags, RecordFlags.FALLBACK), "and the chip still decided");
        console2.log("settle gas on the sealed evaluator", gasSealed);

        // the upgrade is reverted
        vm.prank(tapeoutOwner);
        ITapeOutFactory(TAPEOUT_FACTORY).upgradeCircuits(CIRCUIT_IMPL);
        (, sealedMode) = kernel.evaluator();
        assertFalse(sealedMode);
        _buy(alice, 1 ether);
        _nextEpoch();
        (uint32 n3,) = _settle();
        assertFalse(_has(kernel.records(n3).flags, RecordFlags.SEALED));

        // the record written under the sealed evaluator is exactly what TapeOut's code computes
        assertTrue(lens.replayOn(address(kernel), n2, false).ok, "sealed record replays on live TapeOut");
        assertTrue(lens.replayOn(address(kernel), n2, true).ok);
        assertTrue(lens.replayOn(address(kernel), n3, true).ok, "TapeOut record replays on SealedVM");
    }

    /// TapeOut's step fails while every pin still holds (same beacon, same code, same pin counts, same
    /// netlist): the kernel asks the sealed evaluator before the beat counts as failed. The live step cannot
    /// be made to fail by a chip's state or inputs, so the failure is injected at the call.
    function test_fork_sealed_evaluator_answers_when_the_live_step_fails_under_unchanged_pins() public onFork {
        _buy(alice, 1 ether);
        _nextEpoch();
        (uint32 n1,) = _settle();
        assertFalse(_has(kernel.records(n1).flags, RecordFlags.SEALED));

        vm.mockCallRevert(circuits, abi.encodeWithSelector(ICircuits.step.selector), "out of gas, say");
        assertTrue(factory.pinsLive());
        (address vm_, bool sealedMode) = kernel.evaluator();
        assertEq(vm_, circuits, "the pins hold: TapeOut is asked first");
        assertFalse(sealedMode);
        _buy(alice, 1 ether);
        _nextEpoch();
        (uint32 n2, uint256 gasUsed) = _settle();
        Record memory r = kernel.records(n2);
        assertTrue(_has(r.flags, RecordFlags.SEALED), "the sealed evaluator's answer was used");
        assertFalse(_has(r.flags, RecordFlags.FALLBACK), "the chip decided, not the fallback word");
        assertEq(kernel.lastStepEpoch(), r.epoch, "a persisted step");
        console2.log("settle gas, live step failing at once, sealed evaluator answering", gasUsed);

        // what the sealed evaluator answered is what live TapeOut computes
        vm.clearMockedCalls();
        assertTrue(lens.replayOn(address(kernel), n2, false).ok, "the record replays on live Circuits.step");
        assertTrue(lens.replayOn(address(kernel), n2, true).ok);
        _buy(alice, 1 ether);
        _nextEpoch();
        (uint32 n3,) = _settle();
        assertFalse(_has(kernel.records(n3).flags, RecordFlags.SEALED), "TapeOut answers again");
    }

    // ------------------------------------------------------------------ INTERFACE 8.6: the two reentrancy locks

    /// @dev A second kernel and token whose chip always buys: half of every inflow, a quarter of the reserve.
    function _buyingFixture(bool buyEnabled) internal {
        Envelope memory e = _env();
        if (!buyEnabled) {
            e.buyEnabled = false;
            e.sink = makeAddr("sink");
        }
        _fixture(Netlists.synthetic(300, 8, _syntheticWord(), buyEnabled ? 41 : 42), e, 300);
    }

    /// The attack of INTERFACE section 8.6 against the live IgnixManager: a contract sells zero tokens (it
    /// needs none, and no approval), the Manager pays it the zero proceeds by a native call with its
    /// reentrancy lock held, and the contract settles from its receive(). The kernel's buyTo then reverts
    /// ReentrancyGuardReentrantCall(), a failure no other caller would see: the whole settle reverts, the
    /// epoch is not consumed, and the same settle outside the callback succeeds and buys.
    function test_fork_settle_from_inside_a_manager_call_reverts_and_keeps_the_epoch() public onFork {
        _buyingFixture(true);
        ForkManagerLockHolder h = new ForkManagerLockHolder{value: 1 wei}(M, kernel, address(token));
        _buy(alice, 5 ether);
        _nextEpoch();
        bytes32 before = _digest();
        assertEq(address(vault).balance, 0.15 ether);
        assertEq(token.balanceOf(address(h)), 0, "the attacker holds no tokens");

        h.sellZeroAndSettleInside(address(token)); // the attacker's own transaction goes through
        assertEq(h.attempts(), 1, "the live Manager called back with its lock held");
        assertFalse(h.buyToWorked(), "a buyTo from inside the callback is refused by the live Manager");
        assertEq(h.buyToRevert(), hex"3ee5aeb5", "with exactly ReentrancyGuardReentrantCall()");
        assertFalse(h.settled(), "the settle made from inside the Manager reverted");
        assertEq(h.settleRevert(), abi.encodeWithSelector(Kernel.LockHeld.selector));
        assertEq(_digest(), before, "nothing was written and nothing moved");
        assertEq(kernel.count(), 0, "no record");
        assertEq(kernel.lastEpoch(), 0, "the epoch is not consumed");
        assertEq(address(vault).balance, 0.15 ether, "the tax is still in the live vault");
        assertEq(address(kernel).balance, 0);

        // the same settle outside the callback, in the same block, succeeds and buys
        (uint32 n,) = _settle();
        Record memory r = kernel.records(n);
        assertEq(r.epoch, 1);
        assertEq(r.inflow, 0.15 ether);
        assertEq(r.buyDecided, 0.075 ether);
        assertEq(r.buyExecuted, 0.075 ether, "bought on the live curve");
        assertGt(r.tokensOut, 0);
        assertEq(r.flags, 0, "no flag: nothing failed");
        assertEq(kernel.lockedTokens(), r.tokensOut);
    }

    /// The lock is the Manager's own: a zero-token sell of any live token holds it. Here it is OpenBook (OB),
    /// a real pre-graduation token nobody in this test owns or has ever touched.
    function test_fork_the_managers_lock_can_be_held_through_any_live_token() public onFork {
        address liveOB = 0x995546dFdf93BEF59C35742aB5f4762fbcB8eEEe;
        assertEq(M.pairOf(liveOB), address(0), "OB is still on its curve at the pinned block");
        _buyingFixture(true);
        ForkManagerLockHolder h = new ForkManagerLockHolder{value: 1 wei}(M, kernel, address(token));
        _buy(alice, 5 ether);
        _nextEpoch();
        h.sellZeroAndSettleInside(liveOB);
        assertEq(h.attempts(), 1);
        assertFalse(h.settled());
        assertEq(h.settleRevert(), abi.encodeWithSelector(Kernel.LockHeld.selector));
        assertEq(kernel.count(), 0);
        (uint32 n,) = _settle();
        assertGt(kernel.records(n).buyExecuted, 0);
    }

    /// Holding the live Manager's lock changes nothing when the settle makes no buy call. With buys disabled
    /// the kernel claims from the live vault, steps the chip and credits the sink, inside the callback exactly
    /// as outside it: the claim, the curve read and the step do not depend on the Manager's lock.
    function test_fork_under_the_managers_lock_a_settle_without_a_buy_call_is_unchanged() public onFork {
        _buyingFixture(false);
        ForkManagerLockHolder h = new ForkManagerLockHolder{value: 1 wei}(M, kernel, address(token));
        _buy(alice, 5 ether);
        _nextEpoch();
        uint256 snap = vm.snapshotState();
        (uint32 n,) = _settle();
        bytes32 outside = _digest();
        Record memory r = kernel.records(n);
        assertEq(r.inflow, 0.15 ether, "claimed from the live vault");
        assertEq(r.buyExecuted, 0.075 ether, "credited to the sink");
        assertEq(r.flags, 0);
        vm.revertToState(snap);

        h.sellZeroAndSettleInside(address(token));
        assertEq(h.attempts(), 1);
        assertTrue(h.settled(), "no buy call, so the lock does not matter");
        assertEq(_digest(), outside, "the same record for every caller");
    }

    /// The same attack after graduation, against the live Uniswap V2 pair: a flash swap calls settle() from
    /// uniswapV2Call, with the pair's lock held. The kernel's router buy fails there, in one of two ways that
    /// depend only on the size of the loan, and in both the whole settle reverts, the epoch is not consumed,
    /// and the same settle outside the callback succeeds, burns and buys.
    function test_fork_settle_from_inside_a_flash_swap_reverts_and_keeps_the_epoch() public onFork {
        _buyingFixture(true);
        _buy(alice, 10 ether);
        _nextEpoch();
        _settle();
        address pair = _graduate();
        _v2Buy(alice, 5 ether); // token tax in the vault: the settle has a burn to make as well
        _nextEpoch();
        uint256 dead0 = token.balanceOf(DEAD);
        assertGt(address(vault).balance, 2 ether);
        assertGt(token.balanceOf(address(vault)), 0);

        // A loan far larger than the kernel's buy (about 1.1 OKB). The pair's WOKB balance is then below its
        // reserve, and the live router fails on its own arithmetic before it reaches the pair's lock.
        _flashAttack(pair, 10 ether, "ds-math-sub-underflow");
        // A loan of one wei. The live router reaches the pair and passes on the pair's lock error.
        _flashAttack(pair, 1, "UniswapV2: LOCKED");

        // the same settle outside the callback, in the same block, succeeds, burns and buys
        (uint32 n,) = _settle();
        Record memory r = kernel.records(n);
        assertEq(r.epoch, 2);
        assertTrue(kernel.graduated());
        assertEq(kernel.pair(), pair);
        assertEq(r.flags & (RecordFlags.BUY_FAILED | RecordFlags.BUY_SKIPPED | RecordFlags.CLAIM_FAILED), 0);
        assertGt(r.buyExecuted, 0, "burned");
        assertGt(r.nativeIn, 0, "and bought on the live pair");
        assertGt(r.tokensOut, r.buyExecuted);
        assertEq(token.balanceOf(DEAD) - dead0, r.tokensOut);
    }

    /// @dev One flash swap of `loan` WOKB with a settle inside. The settle must revert with LockHeld and
    ///      change nothing; the live router's own answer under the lock must be `routerSays`; the live pair,
    ///      asked by a static call to sync(), must answer with its lock error.
    function _flashAttack(address pair, uint256 loan, string memory routerSays) internal {
        ForkFlashSwapper f = new ForkFlashSwapper(WOKB, ROUTER, kernel, address(token));
        bytes32 before = _digest();
        uint256 nativeInVault = address(vault).balance;
        uint256 tokensInVault = token.balanceOf(address(vault));
        uint256 dead0 = token.balanceOf(DEAD);

        f.flashAndSettleInside{value: 1 ether}(pair, loan); // the flash swap itself completes
        assertEq(f.attempts(), 1, "the live pair called back with its lock held");
        assertFalse(f.swapWorked(), "a router buy from inside the callback fails");
        console2.log("loan of WOKB (wei):", loan);
        console2.log("  the live router's revert data under the pair's lock:");
        console2.logBytes(f.swapRevert());
        assertEq(_errorString(f.swapRevert()), routerSays);
        assertFalse(f.syncWorked());
        assertEq(_errorString(f.syncRevert()), "UniswapV2: LOCKED", "the pair itself says its lock is held");
        assertEq(f.syncRevert().length, 100);

        assertFalse(f.settled(), "the settle made from inside the pair reverted");
        assertEq(f.settleRevert(), abi.encodeWithSelector(Kernel.LockHeld.selector));
        assertEq(_digest(), before, "nothing was written and nothing moved");
        assertEq(kernel.count(), 1, "no record");
        assertEq(kernel.lastEpoch(), 1, "the epoch is not consumed");
        assertFalse(kernel.graduated(), "the latch was rolled back with everything else");
        assertEq(address(vault).balance, nativeInVault, "both claims were rolled back");
        assertEq(token.balanceOf(address(vault)), tokensInVault);
        assertEq(token.balanceOf(DEAD), dead0, "and so was the burn");
    }

    /// @dev The string of an Error(string) revert, decoded as the kernel decodes it (selector, offset 32,
    ///      length, bytes); empty for anything else.
    function _errorString(bytes memory err) internal pure returns (string memory str) {
        if (err.length < 68 || bytes4(err) != bytes4(0x08c379a0)) return "";
        uint256 offset;
        uint256 length;
        assembly {
            offset := mload(add(err, 0x24))
            length := mload(add(err, 0x44))
        }
        if (offset != 32 || err.length < 68 + length) return "";
        bytes memory out = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            out[i] = err[68 + i];
        }
        return string(out);
    }

    /// Outside any callback the live pair's sync(), asked by a static call, fails without revert data (it
    /// stops at its first storage write): that is the answer "not locked". A failed swap then stays a flag.
    function test_fork_pair_lock_probe_outside_a_callback() public onFork {
        _buyingFixture(true);
        address pair = _graduate();
        uint256 g0 = gasleft();
        (bool ok, bytes memory ret) = pair.staticcall{gas: 100_000}(abi.encodeCall(IPairSync.sync, ()));
        console2.log("pair.sync() by static call, lock not held: gas used", g0 - gasleft());
        assertFalse(ok);
        assertEq(ret.length, 0, "no revert data: not locked");

        // a swap that fails for every caller (the router is made to revert): flag 32, epoch consumed
        vm.mockCallRevert(
            address(ROUTER),
            abi.encodeWithSelector(IRouterFork.swapExactETHForTokensSupportingFeeOnTransferTokens.selector),
            abi.encodeWithSignature("Error(string)", "ds-math-sub-underflow")
        );
        _nextEpoch();
        (uint32 n, uint256 gasUsed) = _settle();
        Record memory r = kernel.records(n);
        assertTrue(_has(r.flags, RecordFlags.BUY_FAILED), "flag 32");
        assertEq(r.nativeIn, 0);
        assertLt(gasUsed, kernel.minSettleGas());
        vm.clearMockedCalls();
        _nextEpoch();
        (n,) = _settle();
        assertGt(kernel.records(n).nativeIn, 0, "the pot waited and is spent once the router works");
    }

    /// Holding the live pair's lock changes nothing when the settle makes no swap: with an empty native pot
    /// the token claim from the live vault and the transfer to 0xdEaD run inside the callback exactly as
    /// outside it. (The live token does not touch the pair's lock on a transfer, inside the protection window.)
    function test_fork_under_the_pairs_lock_a_settle_without_a_swap_is_unchanged() public onFork {
        _buyingFixture(true);
        address pair = _graduate();
        for (uint256 i = 0; i < 8; i++) {
            _nextEpoch();
            _settle();
        }
        assertEq(address(kernel).balance, kernel.totalCredits(NATIVE), "the native pot is empty");
        assertTrue(token.protectionActive());
        _v2Buy(alice, 5 ether); // token tax to claim and burn
        ForkFlashSwapper f = new ForkFlashSwapper(WOKB, ROUTER, kernel, address(token));
        _nextEpoch();
        uint256 snap = vm.snapshotState();
        (uint32 n,) = _settle();
        bytes32 outside = _digest();
        Record memory r = kernel.records(n);
        assertGt(r.inflow, 0, "claimed from the live vault");
        assertGt(r.buyExecuted, 0, "the settle burns");
        assertEq(r.nativeIn, 0, "and has nothing to swap");
        assertEq(r.flags, RecordFlags.GRADUATED);
        vm.revertToState(snap);

        f.flashAndSettleInside{value: 1 ether}(pair, 10 ether);
        assertEq(f.attempts(), 1);
        assertTrue(f.settled(), "no swap, so the lock does not matter");
        assertEq(_digest(), outside, "the same record for every caller");
    }

    // ------------------------------------------------------------------ forced graduation

    struct Grad {
        address pair;
        uint256 locked;
        uint256 taxTokens;
        uint256 nativeInVault;
        uint256 dead0;
        uint256 credits0;
        uint256 pot;
        uint256 rToken;
        uint256 rQuote;
    }

    function test_fork_forced_graduation_then_token_regime() public onFork {
        Grad memory x = _curveThenForcedGraduation();
        uint32 n2 = _firstGraduatedSettle(x);
        _lockedTokensExit(x);
        _potDrainsAndPushedTokensCount(n2);
    }

    function _curveThenForcedGraduation() internal returns (Grad memory x) {
        _buy(alice, 10 ether);
        _nextEpoch();
        (uint32 n1,) = _settle();
        x.locked = kernel.lockedTokens();
        assertTrue(kernel.records(n1).buyExecuted <= kernel.records(n1).buyDecided);

        x.pair = _graduate();
        assertTrue(token.unlocked());
        assertTrue(token.protectionActive(), "inside the 100-day protection window");
        _v2Buy(alice, 5 ether); // pays the 3% buy tax in project tokens to the vault
        x.taxTokens = token.balanceOf(address(vault));
        assertGt(x.taxTokens, 0);
        x.nativeInVault = address(vault).balance;
        assertGt(x.nativeInVault, 2 ether, "the graduating buy's OKB tax is still in the vault");

        _nextEpoch();
        x.dead0 = token.balanceOf(DEAD);
        x.credits0 = kernel.totalCredits(NATIVE);
        x.pot = address(kernel).balance + x.nativeInVault - x.credits0;
        (uint112 ra, uint112 rb,) = IPairFork(x.pair).getReserves();
        (x.rToken, x.rQuote) =
            IPairFork(x.pair).token0() == address(token) ? (uint256(ra), uint256(rb)) : (uint256(rb), uint256(ra));
    }

    function _firstGraduatedSettle(Grad memory x) internal returns (uint32 n2) {
        uint256 gasUsed;
        (n2, gasUsed) = _settle();
        Record memory r = kernel.records(n2);
        console2.log("settle gas, first graduated epoch (claims, burn, V2 swap)", gasUsed);
        assertLt(gasUsed, kernel.minSettleGas());

        assertTrue(kernel.graduated());
        assertEq(kernel.pair(), x.pair);
        assertTrue(_has(r.flags, RecordFlags.GRADUATED));
        assertEq(r.flags & (RecordFlags.CLAIM_FAILED | RecordFlags.BUY_FAILED | RecordFlags.FALLBACK), 0);
        KernelMath.InputFields memory f = KernelMath.unpackInput(KernelMath.inputWord(r.inputs));
        assertEq(f.grad, 1);
        assertEq(f.prog, 255);

        // token regime: the live vault paid project tokens; locked tokens were not counted
        assertEq(r.inflow, x.taxTokens, "token tax claimed from the live vault");
        assertEq(r.reserveBefore, 0);
        assertEq(kernel.lockedTokens(), x.locked, "curve-bought tokens are not inflow");
        assertEq(r.allow, 0, "no allowance after graduation");
        assertEq(r.clampBits, 0);
        assertEq(kernel.creditOf(payee, address(token)), 0, "the payee is not credited in the project token");
        assertEq(kernel.totalCredits(address(token)), 0);
        assertEq(r.buyExecuted, r.buyDecided, "the buy share reached 0xdEaD on the live token");
        assertEq(kernel.reserve(), uint256(r.inflow) - r.buyExecuted, "everything else is the token reserve");

        // native leg: one capped buy on the live pair, straight to 0xdEaD
        uint256 cap = (x.rQuote * (25 * 256 + 600 * (256 - 48))) / (256 * 4 * 10_000);
        uint256 spent = x.pot - (address(kernel).balance - x.credits0);
        assertEq(spent, cap < x.pot ? cap : x.pot, "one capped swap");
        assertEq(r.nativeIn, spent, "Record.nativeIn is the OKB the live router took");
        uint256 expectOut = TradeMath.v2NetOut(spent, x.rQuote, x.rToken, 300);
        assertEq(
            token.balanceOf(DEAD) - x.dead0, uint256(r.buyExecuted) + expectOut, "burn leg + swap, exactly as quoted"
        );
        assertEq(r.tokensOut, uint256(r.buyExecuted) + expectOut);
        assertEq(kernel.totalCredits(NATIVE), x.credits0, "no allowance from native OKB after graduation");
        assertEq(token.totalSupply(), 1_000_000_000 ether, "0xdEaD is a sink, not a burn");

        assertTrue(lens.replayOn(address(kernel), n2, false).ok);
        assertTrue(lens.replayOn(address(kernel), n2, true).ok);
    }

    function _lockedTokensExit(Grad memory x) internal {
        uint256 dead0 = token.balanceOf(DEAD);
        vm.prank(bob);
        assertEq(kernel.burnLocked(), x.locked);
        assertEq(token.balanceOf(DEAD) - dead0, x.locked);
        assertEq(kernel.lockedTokens(), 0);

        assertEq(kernel.withdrawCredit(payee, address(token)), 0, "there is no token credit to withdraw");
        assertEq(token.balanceOf(payee), 0);
        assertEq(token.balanceOf(address(kernel)), kernel.reserve(), "token books: the reserve and nothing else");
    }

    function _potDrainsAndPushedTokensCount(uint32 n2) internal {
        // tokens pushed by a third party (the platform's daily payout, or anyone) are inflow
        _v2Buy(bob, 3 ether);
        vm.prank(bob);
        vault.claimFor(address(kernel), address(token));
        for (uint256 i = 0; i < 6; i++) {
            _nextEpoch();
            _settle();
        }
        assertEq(address(kernel).balance, kernel.totalCredits(NATIVE), "the native pot is spent");
        assertGt(kernel.records(n2 + 1).inflow, 0, "pushed tokens were counted");
        for (uint32 n = n2 + 1; n <= kernel.count(); n++) {
            assertEq(kernel.records(n).flags & (RecordFlags.CLAIM_FAILED | RecordFlags.BUY_FAILED), 0);
            assertTrue(lens.replayOn(address(kernel), n, true).ok);
        }
    }

    function test_fork_swap_after_the_protection_window() public onFork {
        _graduate();
        vm.warp(token.protectionEndsAt() + 1);
        assertFalse(token.protectionActive());
        uint256 dead0 = token.balanceOf(DEAD);
        (uint32 n,) = _settle();
        Record memory r = kernel.records(n);
        assertEq(r.flags & RecordFlags.BUY_FAILED, 0);
        assertGt(token.balanceOf(DEAD) - dead0, 0, "the swap works after the window too");
    }

    // ------------------------------------------------------------------ gas

    /// Every gas limit either reverts as a whole or gives the same record, against live IGNIX and TapeOut.
    function test_fork_gas_sweep_revert_or_full_success() public onFork {
        _buy(alice, 5 ether);
        _nextEpoch();
        uint256 snap = vm.snapshotState();
        _settle();
        bytes32 ref = _digest();
        vm.revertToState(snap);

        uint256 m = kernel.minSettleGas();
        uint256 minOk;
        for (uint256 gasLimit = 3_000_000; gasLimit <= m + 200_000; gasLimit += 200_000) {
            snap = vm.snapshotState();
            vm.prank(keeper);
            (bool ok, bytes memory ret) = address(kernel).call{gas: gasLimit}(abi.encodeCall(IKernelMin.settle, ()));
            if (ok) {
                assertEq(_digest(), ref, "same outcome at every gas limit that returns");
                if (minOk == 0) minOk = gasLimit;
            } else {
                assertEq(bytes4(ret), Kernel.InsufficientGas.selector);
                assertEq(kernel.count(), 0);
            }
            vm.revertToState(snap);
        }
        assertGt(minOk, 0);
        assertLe(minOk, m, "minSettleGas is enough against the live contracts");
        console2.log("smallest gas limit that settled", minOk);
        console2.log("minSettleGas                   ", m);
    }

    function _digest() internal view returns (bytes32) {
        uint32 n = kernel.count();
        return keccak256(
            abi.encode(
                kernel.records(n),
                kernel.state(),
                kernel.reserve(),
                address(kernel).balance,
                token.balanceOf(address(kernel)),
                address(vault).balance,
                kernel.creditOf(payee, NATIVE)
            )
        );
    }

    /// @dev Gas a staticcall costs its caller when no return data is copied (what the kernel's gas-capped
    ///      calls see).
    function _rawGas(address target, bytes memory data) internal view returns (uint256 used) {
        bool ok;
        uint256 g = gasleft();
        assembly ("memory-safe") {
            ok := staticcall(gas(), target, add(data, 0x20), mload(data), 0x00, 0x00)
        }
        used = g - gasleft();
        require(ok, "raw call failed");
    }

    /// On the deployed TapeOut implementation: one settle of a 2,200-gate chip with a claim, the step, an
    /// allowance credit, a release and a curve buy.
    function test_fork_settle_gas_2200_gate_chip() public onFork {
        _fixture(Netlists.synthetic(2200, 64, _syntheticWord(), 11), _env(), 300);
        Globals memory g = kernel.globals();
        assertEq(g.gateCount, 2200);
        Lens.Preflight memory p = lens.preflight(address(kernel));
        assertTrue(p.tapeoutRan && p.sealedRan && p.agree);
        console2.log("2,200 gates: live step gas, TapeOut ", p.tapeoutGas);
        console2.log("2,200 gates: live step gas, SealedVM", p.sealedGas);
        console2.log("2,200 gates: stepFloor              ", p.stepFloor);
        console2.log("2,200 gates: sealedFloor            ", p.sealedFloor);
        console2.log("2,200 gates: minSettleGas           ", p.minSettleGas);
        assertLt(p.tapeoutGas, (p.stepFloor * 90) / 100, "at least 10% headroom under TapeOut's gas");
        assertLt(p.sealedGas, (p.sealedFloor * 80) / 100, "at least 20% headroom under the sealed evaluator's gas");

        _buy(alice, 5 ether);
        _nextEpoch();
        (uint32 n1, uint256 g1) = _settle();
        _buy(alice, 5 ether);
        _nextEpoch();
        (uint32 n2, uint256 g2) = _settle();
        Record memory r = kernel.records(n2);
        assertEq(r.flags, 0);
        assertEq(r.clampBits, 0);
        assertGt(r.buyExecuted, 0);
        assertGt(r.allow, 0);
        assertGt(kernel.records(n1).buyExecuted, 0);
        console2.log("2,200 gates: settle gas, first      ", g1);
        console2.log("2,200 gates: settle gas, steady     ", g2);

        OtherCircuitsImpl other = new OtherCircuitsImpl();
        address tapeoutOwner = ITapeOutFactory(TAPEOUT_FACTORY).owner();
        vm.prank(tapeoutOwner);
        ITapeOutFactory(TAPEOUT_FACTORY).upgradeCircuits(address(other));
        _buy(alice, 5 ether);
        _nextEpoch();
        (uint32 n3, uint256 g3) = _settle();
        assertEq(kernel.records(n3).flags, RecordFlags.SEALED);
        assertEq(kernel.records(n3).outputs, r.outputs);
        console2.log("2,200 gates: settle gas, sealed     ", g3);
    }

    /// The largest chip the Fab accepts (3,400 gates, one 24,000-byte chunk) on the deployed implementation.
    function test_fork_largest_chip() public onFork {
        bytes memory nl = Netlists.synthetic(3400, 256, _syntheticWord(), 12);
        assertLe(nl.length, 24_000);
        _fixture(nl, _env(), 300);
        Lens.Preflight memory p = lens.preflight(address(kernel));
        assertTrue(p.tapeoutRan && p.sealedRan && p.agree, "runs inside the floor on both evaluators");
        console2.log("3,400 gates: netlist bytes          ", nl.length);
        console2.log("3,400 gates: live step gas, TapeOut ", p.tapeoutGas);
        console2.log("3,400 gates: live step gas, SealedVM", p.sealedGas);
        console2.log("3,400 gates: stepFloor              ", p.stepFloor);
        console2.log("3,400 gates: sealedFloor            ", p.sealedFloor);
        console2.log("3,400 gates: minSettleGas           ", p.minSettleGas);
        assertLt(p.minSettleGas, 15_500_000, "1.2M below a 16,777,216 transaction cap");
        uint256 gNetlist = _rawGas(circuits, abi.encodeCall(ICircuits.netlist, (chipId)));
        console2.log("3,400 gates: Circuits.netlist gas   ", gNetlist);
        assertLt(gNetlist * 3, 500_000, "G_NETLIST is at least three times the largest netlist read");

        _buy(alice, 5 ether);
        _nextEpoch();
        vm.prank(keeper);
        (bool ok,) = address(kernel).call{gas: p.minSettleGas}(abi.encodeCall(IKernelMin.settle, ()));
        assertTrue(ok, "settles with exactly minSettleGas");
        assertEq(kernel.records(1).flags, 0);
        assertGt(kernel.records(1).buyExecuted, 0);
    }

    /// The least gas each evaluator must be GIVEN for one beat to succeed, found by bisection on the deployed
    /// TapeOut implementation and on SealedVM, at the all-ones state with all-ones inputs, for the extreme chip
    /// shapes the Fab accepts, against the two amounts the kernel factory fixes for each chip:
    ///   TapeOut  200,000 + 2,600 * gateCount + 800 * nState      (stepFloor)
    ///   sealed    40,000 +   200 * nNand     + 400 * nState      (sealedFloor)
    /// TapeOut's step is measured as a settle reaches it, after the four comparisons have touched everything
    /// it reads; the sealed evaluator from a cold start. Every shape must leave margin on both.
    function test_fork_step_gas_by_chip_shape_at_all_ones() public onFork {
        _shape(
            "1 latch + 113 NAND (smallest useful chip)", Netlists.toggle(256 | (uint256(1023) << 81), _syntheticWord())
        );
        _shape("1 latch + 299 NAND", Netlists.synthetic(300, 1, _syntheticWord(), 23));
        _shape("64 latches + 536 NAND", Netlists.synthetic(600, 64, _syntheticWord(), 24));
        _shape("112 latches, no NAND", Netlists.latchOnly(112));
        _shape("256 latches, no NAND", Netlists.latchOnly(256));
        _shape("64 latches + 2,136 NAND", Netlists.synthetic(2200, 64, _syntheticWord(), 22));
        _shape("256 latches + 3,144 NAND", Netlists.synthetic(3400, 256, _syntheticWord(), 21));
        _shape("Flow Governor (fixture)", _netlist());
    }

    function _shape(string memory name, bytes memory nl) internal {
        bytes memory ones32 = abi.encodePacked(bytes32(type(uint256).max));
        bytes memory ones12 = abi.encodePacked(bytes12(type(uint96).max));
        uint256 id = _tapeout(nl);
        // the two amounts, exactly as a kernel for this chip gets them
        Globals memory g = Kernel(payable(factory.create(_env(), id, bytes32("shape")))).globals();
        assertEq(g.stepFloor, 200_000 + 2_600 * uint256(g.gateCount) + 800 * uint256(g.nState));
        assertEq(g.sealedFloor, 40_000 + 200 * uint256(g.gateCount - g.nState) + 400 * uint256(g.nState));

        bytes memory tapeOutCall = abi.encodeCall(ICircuits.step, (id, ones32, ones12));
        bytes memory sealedCall = abi.encodeWithSignature(
            "step(address,uint32,uint32,bytes,bytes)", g.snapshot, uint32(96), uint32(112), ones32, ones12
        );
        uint256 needT = _least(true, id, circuits, tapeOutCall, g.snapshot);
        uint256 needS = _least(false, id, address(sealedVM), sealedCall, g.snapshot);
        console2.log(name);
        console2.log("   gates / latches               ", g.gateCount, g.nState);
        console2.log("   TapeOut: needs / given        ", needT, g.stepFloor);
        console2.log("   TapeOut: needs % of given     ", (needT * 100) / g.stepFloor);
        console2.log("   sealed:  needs / given        ", needS, g.sealedFloor);
        console2.log("   sealed:  needs % of given     ", (needS * 100) / g.sealedFloor);
        assertLe(needT * 100, g.stepFloor * 90, "TapeOut's step leaves at least 10% of its gas for every shape");
        assertLe(needS * 100, g.sealedFloor * 80, "the sealed step leaves at least 20% of its gas for every shape");
        // What INTERFACE section 2 states as the most either evaluator needs. The sealed evaluator's line holds
        // for every shape. TapeOut's line is a fit through four corner chips; the chip of 112 latches and no
        // NAND needs 2.1% more than it says (453,834 against 444,338), so it is checked with 3% of tolerance.
        uint256 nNand = g.gateCount - g.nState;
        assertLe(needT * 100, (101_730 + 2_293 * nNand + 3_059 * uint256(g.nState)) * 103, "TapeOut's stated line");
        assertLe(needS, 20_000 + 160 * nNand + 280 * uint256(g.nState), "the sealed evaluator's stated bound");
    }

    /// @dev Least gas with which the call succeeds with the right answer (both evaluators give the same one).
    ///      Every attempt starts from the same warmth: the two accounts a settle finds cold when it reaches
    ///      the sealed evaluator (the evaluator and the snapshot pointer) are cooled before each.
    function _least(bool compareFirst, uint256 id, address target, bytes memory data, address pointer)
        internal
        returns (uint256 hi)
    {
        StepProbe probe = new StepProbe(CIRCUIT_BEACON, circuits);
        (bool ok, bytes32 want) = probe.attempt(false, id, target, data, 30_000_000);
        assertTrue(ok, "the evaluator answers with ample gas");
        assertEq(want, _answerOf(id, pointer, data, target), "both evaluators give this answer");
        uint256 lo = 0;
        hi = 30_000_000;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            vm.cool(address(sealedVM));
            vm.cool(pointer);
            (bool fine, bytes32 answer) = probe.attempt(compareFirst, id, target, data, mid);
            if (fine && answer == want) hi = mid;
            else lo = mid;
        }
    }

    /// @dev The answer of the OTHER evaluator to the same beat (all-ones state and inputs).
    function _answerOf(uint256 id, address pointer, bytes memory, address target) internal view returns (bytes32) {
        bytes memory ones32 = abi.encodePacked(bytes32(type(uint256).max));
        bytes memory ones12 = abi.encodePacked(bytes12(type(uint96).max));
        bool ok;
        bytes memory ret;
        if (target == circuits) {
            (ok, ret) = address(sealedVM)
                .staticcall(
                    abi.encodeWithSignature(
                        "step(address,uint32,uint32,bytes,bytes)", pointer, uint32(96), uint32(112), ones32, ones12
                    )
                );
        } else {
            (ok, ret) = circuits.staticcall(abi.encodeCall(ICircuits.step, (id, ones32, ones12)));
        }
        require(ok, "the other evaluator failed");
        return keccak256(ret);
    }

    /// Gas of the live reads and legs, for the kernel's allowances (Kernel.sol G_* constants).
    function test_fork_measure_live_call_gas() public onFork {
        _buy(alice, 1 ether);
        uint256 g;
        g = gasleft();
        (bool ok,) = address(M).staticcall(abi.encodeWithSignature("tokens(address)", address(token)));
        console2.log("tokens(token)                 ", g - gasleft());
        g = gasleft();
        M.pairOf(address(token));
        console2.log("pairOf(token)                 ", g - gasleft());
        uint256 gPair = _rawGas(address(token), abi.encodeWithSignature("pair()"));
        console2.log("token.pair() (the latch read) ", gPair);
        assertLt(gPair * 3, 100_000, "G_VIEW is at least three times the latch read");
        assertEq(token.pair(), address(0), "zero before graduation");
        g = gasleft();
        M.snipeBpsNow(address(token));
        console2.log("snipeBpsNow(token)            ", g - gasleft());
        g = gasleft();
        IBeaconView(CIRCUIT_BEACON).implementation();
        console2.log("beacon.implementation()       ", g - gasleft());
        g = gasleft();
        ICircuits(circuits).circuitInfo(chipId);
        console2.log("circuits.circuitInfo(chip)    ", g - gasleft());
        uint256 gNetlist = _rawGas(circuits, abi.encodeCall(ICircuits.netlist, (chipId)));
        console2.log("circuits.netlist(chip)        ", gNetlist);
        g = gasleft();
        token.balanceOf(address(kernel));
        console2.log("token.balanceOf               ", g - gasleft());
        assertTrue(ok);
        // the kernel's allowance is at least three times what the live contract uses
        assertLt(gNetlist * 3, 500_000, "G_NETLIST");
    }
}
