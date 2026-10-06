// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../BaseV2.t.sol";
import {HandlerV2} from "./HandlerV2.sol";

/// @notice Stateful invariants of kernel v2, over four kernels at once (kernel v1's set, in the USD₮0 world):
///           0  a pseudo-random chip (well formed half the time, hostile otherwise), default envelope
///           1  a chip that demands everything (allowance 256, release 256), the loosest envelope accepted
///           2  the pseudo-random chip with buys disabled (decided buys go to a sink; a clone outside the factory)
///           3  a chip that hoards everything and never releases, on the reference envelope
contract InvariantsV2Test is BaseV2 {
    HandlerV2 internal handler;
    uint256 internal floorChecks;

    function setUp() public override {
        super.setUp();
        handler = new HandlerV2(
            usdt, manager, router, circuits, sealedVM, beacon, address(impl), address(new MockImplV2()), lens
        );

        _add(ChipModel.hashChip(64, bytes32("seed-0")), _env(), 300, "k0");

        Envelope memory e1 = _env();
        e1.capT = 128;
        e1.allowCumBps = 5000;
        e1.relMax = 256;
        e1.floorRel = 1;
        e1.floorMin = 1;
        e1.fbAllow = 128;
        e1.fallbackEpochs = 2;
        _add(ChipModel.fixedChip(1, _word(0, 0, 256, 0, 256, 1023)), e1, 1000, "k1");

        Envelope memory e2 = _env();
        e2.buyEnabled = false;
        e2.sink = sinkAddr;
        e2.ceilMax = 440;
        _add(ChipModel.hashChip(256, bytes32("seed-2")), e2, 100, "k2");

        Envelope memory e3 = _refEnv();
        e3.fallbackEpochs = 3;
        _add(ChipModel.fixedChip(8, _word(0, 0, 0, 256, 0, 1023)), e3, 500, "k3");

        bytes4[] memory sel = new bytes4[](26);
        sel[0] = HandlerV2.trade.selector;
        sel[1] = HandlerV2.graduate.selector;
        sel[2] = HandlerV2.warp.selector;
        sel[3] = HandlerV2.claimFor.selector;
        sel[4] = HandlerV2.donateVault.selector;
        sel[5] = HandlerV2.revenue.selector;
        sel[6] = HandlerV2.plainOkb.selector;
        sel[7] = HandlerV2.forceOkb.selector;
        sel[8] = HandlerV2.giftTokens.selector;
        sel[9] = HandlerV2.withdraw.selector;
        sel[10] = HandlerV2.burnLocked.selector;
        sel[11] = HandlerV2.faultEvaluator.selector;
        sel[12] = HandlerV2.upgradeBeacon.selector;
        sel[13] = HandlerV2.tamperNetlist.selector;
        sel[14] = HandlerV2.faultIgnix.selector;
        sel[15] = HandlerV2.faultQuote.selector;
        sel[16] = HandlerV2.pairFault.selector;
        sel[17] = HandlerV2.clearFaults.selector;
        sel[18] = HandlerV2.settleNow.selector;
        sel[19] = HandlerV2.settleNextEpoch.selector;
        sel[20] = HandlerV2.settleLater.selector;
        sel[21] = HandlerV2.settleAll.selector;
        sel[22] = HandlerV2.tradeBuy.selector;
        sel[23] = HandlerV2.settleInsideManager.selector;
        sel[24] = HandlerV2.settleInsidePair.selector;
        sel[25] = HandlerV2.settleUnreadable.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    function _add(bytes memory netlist, Envelope memory e, uint16 taxBps, bytes32 salt) internal {
        Built memory b = _build(netlist, 2200, e, taxBps, salt);
        handler.add(b.kernel, b.token, b.vault, e, b.chipId, netlist);
    }

    /// The invariants, checked together after every call of one campaign.
    function invariant_kernel_v2() public view {
        assertEq(handler.violations(), 0, handler.lastViolation());
        _inv_balance_covers_credits_reserve_and_locked();
        _inv_credits_belong_to_payee_and_sink_only();
        _inv_no_allowance_left_to_manager_or_router();
        _inv_no_token_allowance_and_lifetime_cap();
        _inv_one_settle_per_epoch();
        _inv_chip_envelope_and_quote_are_fixed();
        _inv_forced_okb_never_moves();
    }

    /// The contract always holds what it owes and what it says it has in reserve and locked. (Tether can destroy a
    /// blocked kernel's balance; the handler never does, so the books always hold here.)
    function _inv_balance_covers_credits_reserve_and_locked() internal view {
        if (usdt.balanceOfReverts()) return;
        for (uint256 i = 0; i < handler.count(); i++) {
            HandlerV2.Ctx memory c = handler.ctx(i);
            KernelV2 k = c.kernel;
            bool grad = k.graduated();
            assertGe(
                usdt.balanceOf(address(k)), k.totalCredits(address(usdt)) + (grad ? 0 : k.reserve()), "USD0 books"
            );
            if (c.token.balanceOfReverts()) continue;
            assertGe(
                c.token.balanceOf(address(k)),
                k.totalCredits(address(c.token)) + k.lockedTokens() + (grad ? k.reserve() : 0),
                "token books"
            );
        }
    }

    function _inv_credits_belong_to_payee_and_sink_only() internal view {
        for (uint256 i = 0; i < handler.count(); i++) {
            HandlerV2.Ctx memory c = handler.ctx(i);
            KernelV2 k = c.kernel;
            address tok = address(c.token);
            uint256 sinkQ = c.env.sink == c.env.allowancePayee ? 0 : k.creditOf(c.env.sink, address(usdt));
            uint256 sinkT = c.env.sink == c.env.allowancePayee ? 0 : k.creditOf(c.env.sink, tok);
            assertEq(k.totalCredits(address(usdt)), k.creditOf(c.env.allowancePayee, address(usdt)) + sinkQ);
            assertEq(k.totalCredits(tok), k.creditOf(c.env.allowancePayee, tok) + sinkT);
            assertEq(k.totalCredits(address(0)), 0, "no native credits exist in kernel v2");
        }
    }

    function _inv_no_allowance_left_to_manager_or_router() internal view {
        for (uint256 i = 0; i < handler.count(); i++) {
            KernelV2 k = handler.ctx(i).kernel;
            assertEq(usdt.allowance(address(k), address(manager)), 0, "Manager allowance");
            assertEq(usdt.allowance(address(k), address(router)), 0, "router allowance");
        }
    }

    function _inv_no_token_allowance_and_lifetime_cap() internal view {
        for (uint256 i = 0; i < handler.count(); i++) {
            HandlerV2.Ctx memory c = handler.ctx(i);
            KernelV2 k = c.kernel;
            assertEq(k.creditOf(c.env.allowancePayee, address(c.token)), 0, "a token credit for the allowance payee");
            if (k.graduated()) assertEq(k.allowPaidCum(), 0, "an allowance total in the graduated regime");
            assertLe(uint256(k.allowPaidCum()) * 10_000, uint256(k.cumInflow()) * c.env.allowCumBps, "lifetime cap");
        }
    }

    function _inv_one_settle_per_epoch() internal view {
        for (uint256 i = 0; i < handler.count(); i++) {
            KernelV2 k = handler.ctx(i).kernel;
            uint32 n = k.count();
            assertLe(k.lastEpoch(), k.epochNow());
            assertLe(k.lastStepEpoch(), k.lastEpoch());
            if (n >= 2) assertLt(k.records(n - 1).epoch, k.records(n).epoch);
            if (n >= 1) assertEq(k.records(n).epoch, k.lastEpoch());
        }
    }

    function _inv_chip_envelope_and_quote_are_fixed() internal view {
        for (uint256 i = 0; i < handler.count(); i++) {
            HandlerV2.Ctx memory c = handler.ctx(i);
            assertEq(circuits.ownerOf(c.chipId), address(c.kernel));
            assertEq(keccak256(abi.encode(c.kernel.envelope())), keccak256(abi.encode(c.env)));
            assertEq(c.kernel.token(), address(c.token));
            assertEq(c.kernel.quote(), address(usdt));
            assertEq(c.kernel.quoteShift(), 33);
            if (c.kernel.graduated()) assertEq(c.kernel.pair(), c.token.pairAddr());
            else assertEq(c.kernel.pair(), address(0));
        }
    }

    function _inv_forced_okb_never_moves() internal view {
        for (uint256 i = 0; i < handler.count(); i++) {
            HandlerV2.Ctx memory c = handler.ctx(i);
            assertEq(address(c.kernel).balance, c.forcedOkb, "native OKB is never counted, routed or sent");
        }
    }

    // ------------------------------------------------------------------ no balance is unreachable

    /// After every run, with the dependencies working again, a call sequence exists that pays every credit,
    /// sends every locked token to 0xdEaD and spends the USD₮0 pot; the token reserve leaves at the floor rate or
    /// faster while it is above the floor threshold (step 4, kernel v1's, review B-F5). What remains is the token
    /// reserve, USD₮0 dust too small to buy a single token unit, and any forced OKB (which no code path can move:
    /// stated in NOTES.md).
    function afterInvariant() public {
        handler.clearFaults();
        for (uint256 i = 0; i < handler.count(); i++) {
            _drain(handler.ctx(i));
        }
        emit log_named_uint("settles ok            ", handler.settlesOk());
        emit log_named_uint("  graduated regime    ", handler.settlesGraduated());
        emit log_named_uint("  fallback applied    ", handler.settlesFallback());
        emit log_named_uint("  sealed evaluator    ", handler.settlesSealed());
        emit log_named_uint("curve buys executed   ", handler.buysExecuted());
        emit log_named_uint("V2 swaps executed     ", handler.swapsExecuted());
        emit log_named_uint("revenue paid (USD0)   ", handler.revenuePaid());
        emit log_named_uint("reverted: step failed ", handler.settlesStepFailed());
        emit log_named_uint("reverted: lack of gas ", handler.settlesGasReverted());
        emit log_named_uint("replays checked       ", handler.replays());
        emit log_named_uint("under a lock: same    ", handler.lockedSettlesSame());
        emit log_named_uint("under a lock: reverted", handler.lockedSettlesReverted());
        emit log_named_uint("unreadable balance    ", handler.settlesBlind());
        emit log_named_uint("  of the regime asset ", handler.settlesBlindRegime());
        emit log_named_uint("floor checks (drain)  ", floorChecks);
    }

    function _drain(HandlerV2.Ctx memory c) internal {
        KernelV2 k = c.kernel;
        address tok = address(c.token);
        if (c.token.pairAddr() == address(0)) {
            uint256 cost = manager.costToGraduate(tok);
            usdt.mint(whale, cost + 1e6);
            vm.startPrank(whale);
            usdt.approve(address(manager), cost + 1e6);
            manager.buy(tok, cost + 1e6, 0);
            vm.stopPrank();
        }
        vm.warp(block.timestamp + 20 * EPOCH);
        k.settle();
        assertTrue(k.graduated(), "the kernel latched graduation");

        uint256 locked = k.lockedTokens();
        uint256 dead0 = c.token.balanceOf(DEAD);
        k.burnLocked();
        assertEq(k.lockedTokens(), 0, "locked tokens left");
        assertEq(c.token.balanceOf(DEAD), dead0 + locked);

        for (uint256 j = 0; j < 400; j++) {
            if (usdt.balanceOf(address(k)) <= k.totalCredits(address(usdt)) + 1_000) break;
            vm.warp(block.timestamp + EPOCH);
            k.settle();
        }
        assertLe(usdt.balanceOf(address(k)), k.totalCredits(address(usdt)) + 1_000, "the USD0 pot was spent");

        // 4. guarantee 3 in the token regime (shift 0): in a settle with no new inflow, a reserve above the floor
        //    threshold is offered to the buy leg at floorRel / 256 or faster, and it leaves the kernel (0xdEaD, or
        //    the sink). The pot's last buys pay token tax into the vault, so settle until a settle sees no inflow.
        uint256 threshold = KernelMathV2.exp8s(c.env.floorMin, 0);
        for (uint256 j = 0; j < 8; j++) {
            if (k.reserve() <= threshold) break;
            uint256 out0 = c.token.balanceOf(DEAD) + k.creditOf(c.env.sink, tok);
            vm.warp(block.timestamp + EPOCH);
            RecordV2 memory r = k.records(k.settle());
            if (r.inflow != 0) continue;
            if (r.reserveBefore <= threshold) break;
            floorChecks++;
            assertGe(r.buyDecided, (uint256(r.reserveBefore) * c.env.floorRel) / 256, "the floor released");
            assertGt(r.buyExecuted, 0, "the release was executed");
            assertGt(c.token.balanceOf(DEAD) + k.creditOf(c.env.sink, tok), out0, "and it left the kernel");
            break;
        }

        k.withdrawCredit(c.env.allowancePayee, address(usdt));
        k.withdrawCredit(c.env.allowancePayee, tok);
        if (c.env.sink != address(0)) {
            k.withdrawCredit(c.env.sink, address(usdt));
            k.withdrawCredit(c.env.sink, tok);
        }
        assertEq(k.totalCredits(address(usdt)), 0);
        assertEq(k.totalCredits(tok), 0);
        assertLe(usdt.balanceOf(address(k)), 1_000, "no more than $0.001 of USD0 dust is left behind");
        assertEq(c.token.balanceOf(address(k)), k.reserve(), "the only tokens left are the routable reserve");
    }
}
