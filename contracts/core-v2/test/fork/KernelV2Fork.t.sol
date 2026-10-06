// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./ForkBaseV2.sol";
import {KernelV2GasPins} from "../utils/GasPinsV2.sol";

/// @dev Stands in for a TapeOut upgrade: any other implementation behind the circuit beacon.
contract OtherCircuitsImplV2 {
    function step(uint256, bytes calldata, bytes calldata) external pure returns (bytes memory, bytes memory) {
        revert("upgraded");
    }
}

/// @dev Holds the live Manager's reentrancy lock: it sells zero tokens of a native-quoted token (the Manager pays
///      the zero proceeds by a native call under its lock) and settles the v2 kernel from its receive().
contract ManagerLockHolderV2 {
    IManagerV2Fork internal manager;
    KernelV2 internal kernel;
    uint256 public attempts;
    bool public settled;
    bytes public settleRevert;

    constructor(IManagerV2Fork m, KernelV2 k) {
        (manager, kernel) = (m, k);
    }

    function sellZeroAndSettleInside(address anyNativeToken) external {
        manager.sell(anyNativeToken, 0, 0);
    }

    receive() external payable {
        attempts++;
        (settled, settleRevert) = address(kernel).call(abi.encodeCall(IKernelMin.settle, ()));
    }
}

/// @dev A flash swap of USD₮0 on the live token/USD₮0 pair that settles the kernel from uniswapV2Call.
contract FlashSwapperV2 {
    IUSDT0Fork internal q;
    KernelV2 internal kernel;
    bool public settled;
    bytes public settleRevert;

    constructor(IUSDT0Fork q_, KernelV2 k) {
        (q, kernel) = (q_, k);
    }

    function run(address pair, uint256 quoteOut) external {
        bool quoteIs0 = IPairV2Fork(pair).token0() == address(q);
        IPairV2Fork(pair).swap(quoteIs0 ? quoteOut : 0, quoteIs0 ? 0 : quoteOut, address(this), hex"01");
    }

    function uniswapV2Call(address, uint256 amount0, uint256 amount1, bytes calldata) external {
        (settled, settleRevert) = address(kernel).call(abi.encodeCall(IKernelMin.settle, ()));
        uint256 borrowed = amount0 + amount1;
        q.transfer(msg.sender, borrowed + (borrowed * 3) / 997 + 1);
    }
}

/// @notice Kernel v2 on an X Layer fork: the real Flow Governor taped out through the live Fab, a Directed token
///         quoted in USD₮0 launched through the live IgnixManager with the kernel as recipient, unrelated traders,
///         x402 revenue paid to the kernel by EIP-3009, settles across epochs on live TapeOut and the live SealedVM,
///         graduation into the live token/USD₮0 pair, the post-graduation buy and burn, the fallback, the locks,
///         IGNIX's and Tether's switches, and the KeeperTank.
contract KernelV2ForkTest is ForkBaseV2 {
    bool internal live;

    function setUp() public {
        live = _fork();
        if (!live) return;
        _deployV2();
        _fixture();
    }

    modifier onFork() {
        if (!live) {
            vm.skip(true);
            return;
        }
        _;
    }

    // ------------------------------------------------------------------ facts

    function test_fork_v2_pins_bind_facts_and_preflight() public onFork {
        assertTrue(factory.pinsLive(), "TapeOut's live implementation is the pinned one");
        assertEq(factory.quote(), address(USDT0));
        assertEq(factory.quoteShift(), 33);
        assertEq(kernel.quote(), address(USDT0));
        assertEq(kernel.quoteShift(), 33);
        assertEq(vault.QUOTE(), address(USDT0), "the live vault is quoted in USD0");
        assertEq(vault.RECIPIENT(), address(kernel));
        assertEq(vault.TOKEN(), address(token));
        assertEq(kernel.token(), address(token));
        assertEq(ICircuitsFork(CIRCUITS).ownerOf(chipId), address(kernel), "the kernel holds the Flow Governor");
        assertEq(address(token).codehash, 0xe4a9dfa056a271c2bab97dd1b2968f0f7364b654f79ebc4d11b50f96ebe75dec);
        GlobalsV2 memory g = kernel.globals();
        assertEq(g.nState, 64);
        assertEq(g.gateCount, 1952);
        assertEq(g.netlistLen, 13_472);
        LensV2.Preflight memory p = lens.preflight(address(kernel));
        assertTrue(p.tapeoutRan && p.sealedRan && p.agree, "live TapeOut and the live SealedVM agree");
        console2.log("chip id (taped out on the fork)", chipId);
        console2.log("preflight TapeOut step gas", p.tapeoutGas, "of", p.stepFloor);
        console2.log("preflight sealed step gas", p.sealedGas, "of", p.sealedFloor);
        console2.log("minSettleGas", p.minSettleGas);
        console2.log("KernelV2 runtime bytes", factory.kernelImpl().code.length);
        console2.log("KernelFactoryV2 runtime bytes", address(factory).code.length);
        console2.log("LensV2 runtime bytes", address(lens).code.length);
    }

    function test_fork_v2_plain_okb_is_refused_and_forced_okb_is_never_counted() public onFork {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(kernel).call{value: 1 ether}("");
        assertFalse(ok, "no receive()");
        vm.deal(address(kernel), 3 ether); // SELFDESTRUCT cannot be refused
        _buy(alice, 100e6);
        _nextEpoch();
        (uint32 n,) = _settle();
        assertEq(kernel.records(n).inflow, 3e6, "only USD0 is inflow");
        assertEq(address(kernel).balance, 3 ether, "forced OKB stays where it is");
    }

    // ------------------------------------------------------------------ the curve, epoch after epoch

    function test_fork_v2_twenty_epochs_traders_and_x402_revenue_on_the_flow_governor() public onFork {
        address[3] memory traders = [alice, bob, whale];
        uint256 maxGas;
        for (uint256 i = 0; i < 20; i++) {
            _buy(traders[i % 3], 20e6 + i * 3e6);
            if (i % 4 == 3) _sell(traders[(i + 1) % 3], token.balanceOf(traders[(i + 1) % 3]) / 3);
            for (uint256 j = 0; j < 1 + (i % 3); j++) {
                _x402(500_000); // $0.50 calls paid to the kernel
            }
            _nextEpoch();
            (uint32 n, uint256 g) = _settle();
            if (g > maxGas) maxGas = g;
            RecordV2 memory r = kernel.records(n);
            KernelMath.InputFields memory f = KernelMath.unpackInput(KernelMath.inputWord(r.inputs));
            assertEq(f.tax, KernelMathV2.lg8s(r.inflow, 33), "TAX is the shifted code");
            assertEq(f.tax, KernelMath.lg8(uint256(r.inflow) << 33), "exactly what v1 would show for x * 2^33 wei");
            assertEq(f.rev, 0);
            assertEq(r.clampBits, 0, "the Flow Governor's proofs: no clamp fires on the reference envelope");
            assertEq(r.flags & (RecordFlags.FALLBACK | RecordFlags.SEALED | RecordFlags.CLAIM_FAILED), 0);
            assertLe(uint256(r.allow) * 256, uint256(r.inflow) * 48);
            assertLe(r.allow, 3_932_160, "at most 3.932160 USD0 per settle");
            _books();
        }
        assertGt(kernel.lockedTokens(), 0, "the kernel bought on the live curve");
        assertGt(kernel.creditOf(payee, address(USDT0)), 0, "the allowance, in USD0");
        // every record replays on live TapeOut and on the live SealedVM
        (uint32 next, uint32 bad) = lens.replayRange(address(kernel), 1, kernel.count(), false);
        assertEq(next, kernel.count() + 1);
        assertEq(bad, 0);
        (next, bad) = lens.replayRange(address(kernel), 1, kernel.count(), true);
        assertEq(bad, 0);
        console2.log("largest settle gas over 20 curve epochs (Flow Governor on live TapeOut)", maxGas);
        uint256 paid = kernel.withdrawCredit(payee, address(USDT0));
        assertEq(USDT0.balanceOf(payee), paid, "the payee received its USD0");
    }

    function test_fork_v2_curve_buy_is_exact_and_leaves_no_allowance() public onFork {
        _buy(alice, 300e6);
        _x402(500_000);
        _nextEpoch();
        _settle();
        _buy(bob, 200e6);
        _nextEpoch();
        TradeMath.Curve memory c = _curve();
        uint256 v0 = USDT0.balanceOf(address(vault));
        uint256 k0 = USDT0.balanceOf(address(kernel));
        (uint32 n, uint256 g) = _settle();
        RecordV2 memory r = kernel.records(n);
        assertGt(r.buyExecuted, 0, "the Flow Governor bought");
        (uint256 amt, uint256 out,) = TradeMath.curveBuy(c, r.buyDecided, 48);
        assertEq(r.buyExecuted, amt);
        assertEq(r.tokensOut, out, "the exact quote, on the live Manager");
        assertEq(USDT0.allowance(address(kernel), address(M)), 0);
        // USD0 moved only by the claim (vault -> kernel) and the buy (kernel -> Manager, whose tax -> vault)
        assertEq(USDT0.balanceOf(address(kernel)), k0 + v0 - r.buyExecuted);
        assertEq(USDT0.balanceOf(address(vault)), (r.buyExecuted * 300) / 10_000, "the echo of the kernel's own buy");
        console2.log("settle gas with a curve buy (approve, buyTo, reset)", g);
    }

    function test_fork_v2_third_party_claimFor_pushes_usdt0_and_is_inflow() public onFork {
        _buy(alice, 100e6);
        vm.prank(bob);
        vault.claimFor(address(kernel), address(USDT0)); // works for an ERC-20 quote: no callback
        assertEq(USDT0.balanceOf(address(kernel)), 3e6);
        _nextEpoch();
        (uint32 n,) = _settle();
        assertEq(kernel.records(n).inflow, 3e6);
    }

    function test_fork_v2_ignix_dividend_pause_fails_the_claim_and_revenue_still_routes() public onFork {
        _buy(alice, 100e6);
        _x402(500_000);
        vm.prank(M.owner());
        M.setPaused(6, uint64(block.timestamp + 72 hours));
        _nextEpoch();
        (uint32 n,) = _settle();
        RecordV2 memory r = kernel.records(n);
        assertTrue(_has(r.flags, RecordFlags.CLAIM_FAILED), "flag 4");
        assertEq(r.inflow, 500_000, "revenue paid to the kernel does not wait for the vault");
        vm.warp(block.timestamp + 72 hours + 1);
        (n,) = _settle();
        assertGe(kernel.records(n).inflow, 3e6, "the tax arrives once the pause lapsed");
    }

    function test_fork_v2_ignix_buy_pause_skips_the_buy() public onFork {
        _buy(alice, 200e6);
        vm.prank(M.owner());
        M.setPaused(1, uint64(block.timestamp + 10 hours));
        _nextEpoch();
        (uint32 n,) = _settle();
        RecordV2 memory r = kernel.records(n);
        if (r.buyDecided != 0) assertTrue(_has(r.flags, RecordFlags.BUY_SKIPPED), "Paused() is a guard");
        assertEq(r.buyExecuted, 0);
        assertEq(USDT0.allowance(address(kernel), address(M)), 0);
    }

    function test_fork_v2_tether_block_never_stops_settles_and_the_credit_waits() public onFork {
        _buy(alice, 300e6);
        _nextEpoch();
        _settle();
        address own = USDT0.owner();
        vm.prank(own);
        USDT0.addToBlockedList(address(kernel));
        _buy(alice, 300e6);
        _nextEpoch();
        (uint32 n,) = _settle();
        RecordV2 memory r = kernel.records(n);
        assertGe(r.inflow, 9e6, "a blocked kernel still receives its claim");
        assertEq(r.buyExecuted, 0, "the live Manager cannot pull from a blocked kernel");
        if (r.buyDecided != 0) assertTrue(_has(r.flags, RecordFlags.BUY_FAILED));
        assertEq(USDT0.allowance(address(kernel), address(M)), 0, "no allowance is left while blocked");
        vm.expectRevert(KernelV2.PayFailed.selector);
        kernel.withdrawCredit(payee, address(USDT0));
        vm.prank(own);
        USDT0.removeFromBlockedList(address(kernel));
        assertGt(kernel.withdrawCredit(payee, address(USDT0)), 0);
    }

    /// What USD₮0 itself does with a blocked holder's approve (recorded in NOTES.md): measured, not assumed.
    function test_fork_v2_usdt0_approve_from_a_blocked_address() public onFork {
        vm.prank(USDT0.owner());
        USDT0.addToBlockedList(address(kernel));
        vm.prank(address(kernel));
        (bool ok,) = address(USDT0).call(abi.encodeWithSignature("approve(address,uint256)", address(M), 1));
        console2.log("approve by a blocked holder succeeds (1 = yes)", ok ? 1 : 0);
        _fund(address(kernel), 5e6);
        vm.prank(address(kernel));
        (bool okT,) = address(USDT0).call(abi.encodeWithSignature("transfer(address,uint256)", alice, 1));
        assertFalse(okT, "a blocked holder cannot send");
        _fund(alice, 1);
        vm.prank(alice);
        USDT0.transfer(address(kernel), 1); // but it still receives
    }

    // ------------------------------------------------------------------ evaluators

    function test_fork_v2_tapeout_upgrade_switches_to_the_live_sealed_vm_and_back() public onFork {
        _buy(alice, 50e6);
        _nextEpoch();
        _settle();
        address tapeoutOwner = ITapeOutFactoryFork(TAPEOUT_FACTORY).owner();
        address other = address(new OtherCircuitsImplV2());
        vm.prank(tapeoutOwner);
        ITapeOutFactoryFork(TAPEOUT_FACTORY).upgradeCircuits(other);
        (, bool sealedMode) = kernel.evaluator();
        assertTrue(sealedMode);
        _buy(alice, 50e6);
        _nextEpoch();
        (uint32 n2, uint256 g) = _settle();
        assertTrue(_has(kernel.records(n2).flags, RecordFlags.SEALED), "the live SealedVM answered");
        assertFalse(_has(kernel.records(n2).flags, RecordFlags.FALLBACK));
        console2.log("settle gas on the live SealedVM", g);
        vm.prank(tapeoutOwner);
        ITapeOutFactoryFork(TAPEOUT_FACTORY).upgradeCircuits(CIRCUIT_IMPL);
        assertTrue(lens.replayOn(address(kernel), n2, false).ok, "the sealed record replays on live TapeOut");
    }

    /// Both evaluators dead: settles revert for the grace period (nothing moves, the tax and the revenue wait),
    /// then the fallback word applies; when an evaluator answers again the chip decides again.
    function test_fork_v2_fallback_after_the_grace_period() public onFork {
        _buy(alice, 100e6);
        _nextEpoch();
        _settle();
        address tapeoutOwner = ITapeOutFactoryFork(TAPEOUT_FACTORY).owner();
        address other = address(new OtherCircuitsImplV2());
        vm.prank(tapeoutOwner);
        ITapeOutFactoryFork(TAPEOUT_FACTORY).upgradeCircuits(other);
        vm.mockCallRevert(SEALED_VM, abi.encodeWithSignature("step(address,uint32,uint32,bytes,bytes)"), "dead");
        _x402(500_000);
        _buy(alice, 100e6);
        uint32 last = kernel.lastStepEpoch();
        for (uint256 i = 1; i < 16; i++) {
            _nextEpoch();
            vm.prank(keeper);
            vm.expectRevert(KernelV2.StepFailed.selector);
            kernel.settle();
        }
        _nextEpoch(); // 16 epochs without a persisted step
        (uint32 n,) = _settle();
        RecordV2 memory r = kernel.records(n);
        assertTrue(_has(r.flags, RecordFlags.FALLBACK), "the fallback word");
        assertEq(kernel.lastStepEpoch(), last, "not a persisted step");
        assertEq(r.allow, (uint256(r.inflow) * 8) / 256 > 3_932_160 ? 3_932_160 : (uint256(r.inflow) * 8) / 256);
        assertGt(r.buyExecuted, 0, "the fallback keeps buying");
        vm.clearMockedCalls();
        vm.prank(tapeoutOwner);
        ITapeOutFactoryFork(TAPEOUT_FACTORY).upgradeCircuits(CIRCUIT_IMPL);
        _nextEpoch();
        (n,) = _settle();
        assertFalse(_has(kernel.records(n).flags, RecordFlags.FALLBACK), "the chip decides again");
        _books();
    }

    // ------------------------------------------------------------------ graduation and after

    function test_fork_v2_graduation_quote_pot_buy_to_dead_and_burnLocked() public onFork {
        for (uint256 i = 0; i < 4; i++) {
            _buy(alice, 150e6);
            _x402(500_000);
            _nextEpoch();
            _settle();
        }
        address pair = _graduate();
        assertEq(IERC20Fork(address(token)).pair(), pair);
        (uint256 rT0, uint256 rQ0) = _pairReserves(pair);
        console2.log("opening reserves: tokens, USD0", rT0, rQ0);
        uint256 locked = kernel.lockedTokens();
        assertGt(locked, 0);

        _nextEpoch();
        uint256 d0 = token.balanceOf(DEAD);
        (uint32 n, uint256 gGrad) = _settle();
        RecordV2 memory r = kernel.records(n);
        assertTrue(kernel.graduated(), "latched from token.pair()");
        assertEq(kernel.pair(), pair);
        assertTrue(_has(r.flags, RecordFlags.GRADUATED));
        assertGt(r.quoteIn, 0, "the USD0 pot bought on the live token/USD0 pair");
        assertEq(token.balanceOf(DEAD) - d0, r.tokensOut, "and the tokens reached 0xdEaD");
        assertEq(USDT0.allowance(address(kernel), address(ROUTER)), 0, "router allowance reset");
        console2.log("first graduated settle gas (claims, burn, approve, router buy, reset)", gGrad);

        uint256 dl = token.balanceOf(DEAD);
        assertEq(kernel.burnLocked(), locked);
        assertEq(token.balanceOf(DEAD) - dl, locked, "the curve tokens are burned");

        // after graduation: V2 traders pay token tax, revenue keeps arriving, the pot drains
        for (uint256 i = 0; i < 12; i++) {
            _v2Buy(bob, 40e6);
            _x402(500_000);
            _nextEpoch();
            (n,) = _settle();
            r = kernel.records(n);
            assertEq(r.allow, 0, "no allowance after graduation");
            _books();
        }
        assertEq(kernel.allowPaidCum(), 0);
        assertEq(kernel.creditOf(payee, address(token)), 0);
        for (uint256 i = 0; i < 40 && USDT0.balanceOf(address(kernel)) > kernel.totalCredits(address(USDT0)); i++) {
            _nextEpoch();
            _settle();
        }
        assertLe(USDT0.balanceOf(address(kernel)), kernel.totalCredits(address(USDT0)) + 10, "the pot drained");
        (uint32 nx, uint32 bad) = lens.replayRange(address(kernel), 1, kernel.count(), true);
        assertEq(bad, 0, "every record replays on the live SealedVM");
        nx;
    }

    function test_fork_v2_sandwich_of_the_quote_leg_loses_money() public onFork {
        _buy(alice, 500e6);
        _nextEpoch();
        _settle();
        address pair = _graduate();
        _nextEpoch();
        _settle();
        _fund(address(kernel), 500e6); // a large pot (an unrelated payer's revenue)
        (, uint256 rQ) = _pairReserves(pair);
        address mev = makeAddr("sandwicher");
        uint256 size = rQ / 5;
        _v2Buy(mev, size);
        _nextEpoch();
        _settle();
        uint256 tokens = token.balanceOf(mev);
        vm.startPrank(mev);
        token.approve(address(ROUTER), tokens);
        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokens, 0, _path(address(token), address(USDT0)), mev, block.timestamp
        );
        vm.stopPrank();
        assertLt(USDT0.balanceOf(mev), size, "the sandwich lost money on the live pair");
    }

    // ------------------------------------------------------------------ the two locks (INTERFACE 8.6)

    function test_fork_v2_settle_inside_the_managers_lock_reverts_and_keeps_the_epoch() public onFork {
        address liveNativeToken = 0x995546dFdf93BEF59C35742aB5f4762fbcB8eEEe; // OB, OKB-quoted, on its curve
        assertEq(M.pairOf(liveNativeToken), address(0));
        _buy(alice, 300e6);
        _nextEpoch();
        // a settle that would buy
        uint256 snap = vm.snapshotState();
        (uint32 n0,) = _settle();
        bool buys = kernel.records(n0).buyExecuted != 0;
        vm.revertToState(snap);
        ManagerLockHolderV2 h = new ManagerLockHolderV2(M, kernel);
        h.sellZeroAndSettleInside(liveNativeToken);
        assertEq(h.attempts(), 1, "the live Manager called back with its lock held");
        if (buys) {
            assertFalse(h.settled());
            assertEq(h.settleRevert(), abi.encodeWithSelector(KernelV2.LockHeld.selector));
            assertEq(kernel.count(), 0, "no record; the epoch is not consumed");
            (uint32 n,) = _settle();
            assertGt(kernel.records(n).buyExecuted, 0, "the same settle outside the callback buys");
        }
    }

    function test_fork_v2_settle_inside_a_flash_swap_on_the_usdt0_pair_reverts() public onFork {
        _buy(alice, 500e6);
        _nextEpoch();
        _settle();
        address pair = _graduate();
        _nextEpoch();
        FlashSwapperV2 fs = new FlashSwapperV2(USDT0, kernel);
        (, uint256 rQ) = _pairReserves(pair);
        _fund(address(fs), rQ / 10);
        fs.run(pair, rQ / 20);
        assertFalse(fs.settled());
        assertEq(fs.settleRevert(), abi.encodeWithSelector(KernelV2.LockHeld.selector));
        uint32 c = kernel.count();
        (uint32 n,) = _settle();
        assertEq(n, c + 1);
        assertGt(kernel.records(n).quoteIn, 0, "outside the callback the same settle swaps");
    }

    // ------------------------------------------------------------------ KeeperTank and gas

    function test_fork_v2_the_live_keeper_tank_settles_a_v2_kernel_unchanged() public onFork {
        _buy(alice, 100e6);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        IKeeperTankFork(KEEPER_TANK).topUp{value: 0.05 ether}(chipId);
        _nextEpoch();
        vm.txGasPrice(0.05 gwei);
        vm.deal(keeper, 1 ether);
        uint256 b0 = keeper.balance;
        vm.prank(keeper, keeper);
        IKeeperTankFork(KEEPER_TANK).settleAndRefund(address(kernel));
        assertEq(kernel.count(), 1, "the tank settled the v2 kernel");
        assertGt(keeper.balance, b0, "and refunded its keeper in OKB");
    }

    function test_fork_v2_measure_live_call_gas() public onFork {
        _buy(alice, 100e6);
        // claim(USD0) by the kernel, as the kernel makes it
        vm.prank(address(kernel));
        uint256 g0 = gasleft();
        (bool ok,) = address(vault).call(abi.encodeWithSignature("claim(address)", address(USDT0)));
        uint256 gClaim = g0 - gasleft();
        assertTrue(ok);
        vm.prank(address(kernel));
        g0 = gasleft();
        USDT0.approve(address(M), 1e6);
        uint256 gApprove = g0 - gasleft();
        vm.prank(address(kernel));
        g0 = gasleft();
        USDT0.approve(address(M), 0);
        uint256 gReset = g0 - gasleft();
        g0 = gasleft();
        USDT0.allowance(address(kernel), address(M));
        uint256 gAllowance = g0 - gasleft();
        g0 = gasleft();
        USDT0.balanceOf(address(kernel));
        uint256 gBalance = g0 - gasleft();
        // the kernel's own buyTo (approve exact, buyTo, reset) and the router buy after graduation, as the kernel
        // makes them, from cold
        deal(address(USDT0), address(kernel), 10e6);
        vm.prank(address(kernel));
        USDT0.approve(address(M), 5e6);
        vm.prank(address(kernel));
        g0 = gasleft();
        (ok,) = address(M).call(
            abi.encodeWithSignature("buyTo(address,uint256,uint256,address)", address(token), 5e6, 0, address(kernel))
        );
        uint256 gBuy = g0 - gasleft();
        assertTrue(ok);
        console2.log("claim(USD0)  ", gClaim);
        console2.log("approve      ", gApprove);
        console2.log("approve(0)   ", gReset);
        console2.log("allowance    ", gAllowance);
        console2.log("balanceOf    ", gBalance);
        console2.log("buyTo (USD0) ", gBuy);
        // against the constants the kernel really uses (review B-F8: changing one trips this test)
        KernelV2GasPins pins = new KernelV2GasPins();
        assertLt(gClaim * 3, pins.gClaim(), "G_CLAIM is more than three times the cost");
        assertLt(gApprove * 3, pins.gApprove(), "G_APPROVE is more than three times the cost");
        assertLt(gReset * 3, pins.gApprove(), "G_APPROVE is more than three times the cost of approve(0)");
        assertLt(gBalance * 3, pins.gView(), "G_VIEW is more than three times the cost");
        assertLt(gAllowance * 3, pins.gView(), "G_VIEW is more than three times the cost of allowance");
        assertLt(gBuy * 3, pins.gBuy(), "G_BUY is more than three times the cost");
        console2.log("G_BUY / measured buyTo (x1000)", pins.gBuy() * 1000 / gBuy);
    }

    function test_fork_v2_measure_router_buy_gas() public onFork {
        _buy(alice, 300e6);
        address pair = _graduate();
        pair;
        deal(address(USDT0), address(kernel), 10e6);
        vm.prank(address(kernel));
        USDT0.approve(address(ROUTER), 5e6);
        vm.prank(address(kernel));
        uint256 g0 = gasleft();
        (bool ok,) = address(ROUTER).call(
            abi.encodeCall(
                IRouterV2Fork.swapExactTokensForTokensSupportingFeeOnTransferTokens,
                (5e6, 0, _path(address(USDT0), address(token)), DEAD, block.timestamp)
            )
        );
        uint256 gSwap = g0 - gasleft();
        assertTrue(ok);
        console2.log("router buy USD0 -> token to 0xdEaD", gSwap);
        KernelV2GasPins pins = new KernelV2GasPins();
        assertLt(gSwap * 3, pins.gSwap(), "G_SWAP is more than three times the cost");
        vm.prank(address(kernel));
        g0 = gasleft();
        token.transfer(DEAD, 0);
        console2.log("token transfer to 0xdEaD (0 tokens)", g0 - gasleft());
        // claim(token) after graduation, the kernel holding no token yet (a zero-to-non-zero write)
        _v2Buy(bob, 20e6);
        vm.prank(address(kernel));
        g0 = gasleft();
        (ok,) = address(vault).call(abi.encodeWithSignature("claim(address)", address(token)));
        uint256 gClaimToken = g0 - gasleft();
        assertTrue(ok);
        console2.log("claim(token) after graduation", gClaimToken);
        assertLt(gClaimToken * 3, pins.gClaim(), "G_CLAIM is more than three times the cost");
    }

    /// For every gas limit around minSettleGas a settle on the fork either reverts as a whole or writes exactly
    /// the record of the unlimited settle.
    function test_fork_v2_gas_sweep_revert_or_full_success() public onFork {
        _buy(alice, 300e6);
        _x402(500_000);
        _nextEpoch();
        uint256 m = kernel.minSettleGas();
        uint256 snap = vm.snapshotState();
        vm.prank(keeper);
        kernel.settle{gas: 40_000_000}();
        bytes32 ref = keccak256(abi.encode(kernel.records(1), kernel.reserve(), USDT0.balanceOf(address(kernel))));
        vm.revertToState(snap);
        uint256 okAt;
        for (uint256 g = m - 1_500_000; g <= m + 300_000; g += 30_000) {
            snap = vm.snapshotState();
            vm.prank(keeper);
            (bool ok, bytes memory ret) = address(kernel).call{gas: g}(abi.encodeCall(IKernelMin.settle, ()));
            if (ok) {
                bytes32 d = keccak256(abi.encode(kernel.records(1), kernel.reserve(), USDT0.balanceOf(address(kernel))));
                assertEq(d, ref, "identical record");
                if (okAt == 0) okAt = g;
            } else {
                assertTrue(ret.length == 0 || bytes4(ret) == KernelV2.InsufficientGas.selector, "lack of gas only");
            }
            vm.revertToState(snap);
        }
        assertGt(okAt, 0);
        assertLe(okAt, m, "minSettleGas is enough");
        console2.log("minSettleGas", m, "smallest successful limit in the sweep", okAt);
    }
}
