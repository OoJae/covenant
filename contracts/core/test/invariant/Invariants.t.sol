// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "../Base.t.sol";
import {Handler} from "./Handler.sol";
import {Kernel} from "../../src/Kernel.sol";
import {KernelMath} from "../../src/KernelMath.sol";
import {Record, Envelope, RecordFlags} from "../../src/interfaces/IKernelV1.sol";
import {ChipModel, MockImplV2} from "../mocks/MockTapeOut.sol";
import {MockToken, MockVault} from "../mocks/MockIgnix.sol";

/// @notice Stateful invariants of the kernel, over four kernels at once:
///           0  a pseudo-random chip (well formed half the time, hostile otherwise), default envelope
///           1  a chip that demands everything (allowance 256, release 256), the loosest envelope the
///              factory accepts
///           2  the pseudo-random chip with buys disabled (decided buys go to a sink)
///           3  a chip that hoards everything and never releases
contract InvariantsTest is Base {
    Handler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new Handler(
            manager, router, wokb, circuits, sealedVM, beacon, address(impl), address(new MockImplV2()), lens
        );

        Envelope memory e0 = _env();
        _add(ChipModel.hashChip(64, bytes32("seed-0")), e0, 300, "k0");

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

        Envelope memory e3 = _env();
        e3.fallbackEpochs = 3;
        _add(ChipModel.fixedChip(8, _word(0, 0, 0, 256, 0, 1023)), e3, 500, "k3");

        bytes4[] memory sel = new bytes4[](23);
        sel[0] = Handler.trade.selector;
        sel[1] = Handler.graduate.selector;
        sel[2] = Handler.warp.selector;
        sel[3] = Handler.claimFor.selector;
        sel[4] = Handler.donateVault.selector;
        sel[5] = Handler.donateKernel.selector;
        sel[6] = Handler.forceSend.selector;
        sel[7] = Handler.giftTokens.selector;
        sel[8] = Handler.withdraw.selector;
        sel[9] = Handler.burnLocked.selector;
        sel[10] = Handler.faultEvaluator.selector;
        sel[11] = Handler.upgradeBeacon.selector;
        sel[12] = Handler.tamperNetlist.selector;
        sel[13] = Handler.faultIgnix.selector;
        sel[14] = Handler.pairFault.selector;
        sel[15] = Handler.clearFaults.selector;
        sel[16] = Handler.settleNow.selector;
        sel[17] = Handler.settleNextEpoch.selector;
        sel[18] = Handler.settleLater.selector;
        sel[19] = Handler.settleAll.selector;
        sel[20] = Handler.tradeBuy.selector;
        sel[21] = Handler.settleInsideManager.selector;
        sel[22] = Handler.settleInsidePair.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    function _add(bytes memory netlist, Envelope memory e, uint16 taxBps, bytes32 salt) internal {
        Built memory b = _build(netlist, 2200, e, taxBps, salt);
        handler.add(b.kernel, b.token, b.vault, e, b.chipId, netlist);
    }

    // ------------------------------------------------------------------ invariants

    /// forge runs one whole campaign per invariant function, so the eight invariants are checked together
    /// after every call of a single campaign. Each has its own message.
    function invariant_kernel() public view {
        _inv_no_violation_recorded();
        _inv_balance_covers_credits_reserve_and_locked();
        _inv_credits_belong_to_payee_and_sink_only();
        _inv_no_token_allowance();
        _inv_lifetime_allowance_cap();
        _inv_one_settle_per_epoch();
        _inv_chip_and_envelope_are_fixed();
        _inv_regime_is_monotone();
    }

    /// Every check made around an action: routes of value, one settle per epoch, the gas limit never changes
    /// an outcome, a held reentrancy lock never changes an outcome (the settle is the same or reverts whole),
    /// a funded settle never reverts outside the grace period, replay on both evaluators.
    function _inv_no_violation_recorded() internal view {
        assertEq(handler.violations(), 0, handler.lastViolation());
    }

    /// The contract always holds what it owes and what it says it has in reserve and locked.
    function _inv_balance_covers_credits_reserve_and_locked() internal view {
        for (uint256 i = 0; i < handler.count(); i++) {
            Handler.Ctx memory c = handler.ctx(i);
            Kernel k = c.kernel;
            bool grad = k.graduated();
            assertGe(
                address(k).balance, k.totalCredits(NATIVE) + (grad ? 0 : k.reserve()), "native covers credits + reserve"
            );
            if (c.token.balanceOfReverts()) continue;
            assertGe(
                c.token.balanceOf(address(k)),
                k.totalCredits(address(c.token)) + k.lockedTokens() + (grad ? k.reserve() : 0),
                "tokens cover credits + locked + reserve"
            );
        }
    }

    /// Only the allowance payee and the sink ever hold a credit, and the totals are their sum.
    function _inv_credits_belong_to_payee_and_sink_only() internal view {
        for (uint256 i = 0; i < handler.count(); i++) {
            Handler.Ctx memory c = handler.ctx(i);
            Kernel k = c.kernel;
            address tok = address(c.token);
            uint256 sinkNative = c.env.sink == c.env.allowancePayee ? 0 : k.creditOf(c.env.sink, NATIVE);
            uint256 sinkTok = c.env.sink == c.env.allowancePayee ? 0 : k.creditOf(c.env.sink, tok);
            assertEq(k.totalCredits(NATIVE), k.creditOf(c.env.allowancePayee, NATIVE) + sinkNative);
            assertEq(k.totalCredits(tok), k.creditOf(c.env.allowancePayee, tok) + sinkTok);
            if (c.env.buyEnabled) {
                assertEq(
                    k.creditOf(c.env.sink, NATIVE), c.env.sink == c.env.allowancePayee ? k.totalCredits(NATIVE) : 0
                );
            }
        }
    }

    /// Kernel v1 pays no allowance after graduation: the allowance payee never holds a credit in the project
    /// token, and the graduated regime's allowance total stays zero.
    function _inv_no_token_allowance() internal view {
        for (uint256 i = 0; i < handler.count(); i++) {
            Handler.Ctx memory c = handler.ctx(i);
            Kernel k = c.kernel;
            assertEq(k.creditOf(c.env.allowancePayee, address(c.token)), 0, "a token credit for the allowance payee");
            if (c.env.buyEnabled) assertEq(k.totalCredits(address(c.token)), 0, "a token credit without a sink");
            if (k.graduated()) assertEq(k.allowPaidCum(), 0, "an allowance total in the graduated regime");
        }
    }

    /// The lifetime allowance never exceeds allowCumBps of the regime's cumulative inflow.
    function _inv_lifetime_allowance_cap() internal view {
        for (uint256 i = 0; i < handler.count(); i++) {
            Handler.Ctx memory c = handler.ctx(i);
            Kernel k = c.kernel;
            assertLe(uint256(k.allowPaidCum()) * 10_000, uint256(k.cumInflow()) * c.env.allowCumBps);
        }
    }

    /// Records are in strictly increasing epochs, never ahead of the clock.
    function _inv_one_settle_per_epoch() internal view {
        for (uint256 i = 0; i < handler.count(); i++) {
            Kernel k = handler.ctx(i).kernel;
            uint32 n = k.count();
            assertLe(k.lastEpoch(), k.epochNow());
            assertLe(k.lastStepEpoch(), k.lastEpoch());
            if (n >= 2) assertLt(k.records(n - 1).epoch, k.records(n).epoch);
            if (n >= 1) assertEq(k.records(n).epoch, k.lastEpoch());
        }
    }

    /// The chip NFT never leaves; the configuration never changes.
    function _inv_chip_and_envelope_are_fixed() internal view {
        for (uint256 i = 0; i < handler.count(); i++) {
            Handler.Ctx memory c = handler.ctx(i);
            assertEq(circuits.ownerOf(c.chipId), address(c.kernel));
            assertEq(keccak256(abi.encode(c.kernel.envelope())), keccak256(abi.encode(c.env)));
            assertEq(c.kernel.token(), address(c.token));
            assertEq(c.kernel.vault(), address(c.vault));
        }
    }

    /// A graduated kernel never goes back, and a kernel with buys disabled never holds tokens it bought.
    function _inv_regime_is_monotone() internal view {
        for (uint256 i = 0; i < handler.count(); i++) {
            Handler.Ctx memory c = handler.ctx(i);
            if (c.kernel.graduated()) {
                assertTrue(c.token.pairAddr() != address(0));
                assertEq(c.kernel.pair(), c.token.pairAddr(), "the kernel's pair is the one the token reports");
            } else {
                assertEq(c.kernel.pair(), address(0));
            }
            if (!c.env.buyEnabled) {
                assertEq(c.kernel.lockedTokens(), 0);
                assertEq(c.kernel.burnedTokens(), 0);
            }
        }
    }

    // ------------------------------------------------------------------ no balance is unreachable

    /// After every run: with the dependencies working again, a call sequence exists that pays every credit,
    /// sends every locked token to 0xdEaD and spends the native pot. The regime reserve leaves at no less
    /// than the floor rate while it is above the floor threshold.
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
        emit log_named_uint("reverted: step failed ", handler.settlesStepFailed());
        emit log_named_uint("reverted: lack of gas ", handler.settlesGasReverted());
        emit log_named_uint("replays checked       ", handler.replays());
        emit log_named_uint("under a lock: same    ", handler.lockedSettlesSame());
        emit log_named_uint("under a lock: reverted", handler.lockedSettlesReverted());
    }

    function _drain(Handler.Ctx memory c) internal {
        Kernel k = c.kernel;
        address tok = address(c.token);

        // 1. graduate (anyone can, by buying what is left) and let the kernel see it
        if (c.token.pairAddr() == address(0)) {
            uint256 cost = manager.costToGraduate(tok);
            vm.prank(whale);
            manager.buy{value: cost + 1 ether}(tok, cost + 1 ether, 0);
        }
        vm.warp(block.timestamp + 20 * EPOCH); // past any pause, founder round or grace period
        k.settle();
        assertTrue(k.graduated(), "the kernel latched graduation");

        // 2. locked tokens: their one exit
        uint256 locked = k.lockedTokens();
        uint256 dead0 = c.token.balanceOf(DEAD);
        k.burnLocked();
        assertEq(k.lockedTokens(), 0, "locked tokens left");
        assertEq(c.token.balanceOf(DEAD), dead0 + locked);

        // 3. the native pot: capped per epoch, but it empties
        for (uint256 j = 0; j < 400; j++) {
            if (address(k).balance <= k.totalCredits(NATIVE) + 1e9) break;
            vm.warp(block.timestamp + EPOCH);
            k.settle();
        }
        assertLe(address(k).balance, k.totalCredits(NATIVE) + 1e9, "the native pot was spent (dust aside)");

        // 4. the token reserve leaves at the floor rate or faster while it is above the floor threshold
        uint256 r0 = k.reserve();
        uint256 threshold = KernelMath.exp8(c.env.floorMin);
        if (r0 > threshold && c.token.balanceOf(address(c.vault)) == 0) {
            uint256 before = c.token.balanceOf(DEAD) + k.creditOf(c.env.sink, tok);
            vm.warp(block.timestamp + EPOCH);
            k.settle();
            Record memory r = k.records(k.count());
            if (r.inflow == 0) {
                assertGe(r.buyDecided, (uint256(r.reserveBefore) * c.env.floorRel) / 256, "the floor released");
                assertGt(c.token.balanceOf(DEAD) + k.creditOf(c.env.sink, tok), before, "and it left the kernel");
            }
        }

        // 5. every credit can be collected
        k.withdrawCredit(c.env.allowancePayee, NATIVE);
        k.withdrawCredit(c.env.allowancePayee, tok);
        if (c.env.sink != address(0)) {
            k.withdrawCredit(c.env.sink, NATIVE);
            k.withdrawCredit(c.env.sink, tok);
        }
        assertEq(k.totalCredits(NATIVE), 0);
        assertEq(k.totalCredits(tok), 0);

        // what remains is the token reserve (still draining at the floor rate) and dust
        assertLe(address(k).balance, 1e9, "no native value is left behind");
        assertEq(c.token.balanceOf(address(k)), k.reserve(), "the only tokens left are the routable reserve");
    }
}
