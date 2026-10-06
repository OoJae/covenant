// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "../Base.t.sol";
import {Kernel} from "../../src/Kernel.sol";
import {KernelMath} from "../../src/KernelMath.sol";
import {TradeMath} from "../../src/lib/TradeMath.sol";
import {Record, Envelope, RecordFlags, IKernelV1, IKernelMin} from "../../src/interfaces/IKernelV1.sol";
import {ChipModel} from "../mocks/MockTapeOut.sol";
import {MockManager, MockToken, MockVault} from "../mocks/MockIgnix.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice settle() while the token is on its bonding curve: inflow accounting, the input word, routing,
///         the curve buy and its guards.
contract SettleCurveTest is Base {
    // 50% buy, 25% hold, 18.75% allowance, 6.25% reserve, no release, no ceiling
    bytes14 internal W = _word(128, 64, 48, 16, 0, 1023);

    function setUp() public override {
        super.setUp();
        _fixture(W);
    }

    // ------------------------------------------------------------------ epochs

    function test_settle_reverts_in_the_bind_epoch() public {
        vm.expectRevert(Kernel.EpochNotElapsed.selector);
        kernel.settle();
        vm.warp(block.timestamp + EPOCH - 1);
        vm.expectRevert(Kernel.EpochNotElapsed.selector);
        kernel.settle();
        vm.warp(block.timestamp + 1);
        assertEq(kernel.epochNow(), 1);
        assertEq(_settle(), 1);
    }

    function test_at_most_one_settle_per_epoch() public {
        _nextEpoch();
        _settle();
        vm.expectRevert(Kernel.EpochNotElapsed.selector);
        kernel.settle();
        vm.warp(block.timestamp + EPOCH - 1);
        vm.expectRevert(Kernel.EpochNotElapsed.selector);
        kernel.settle();
        vm.warp(block.timestamp + 1);
        assertEq(_settle(), 2);
        assertEq(kernel.count(), 2);
        assertEq(kernel.lastEpoch(), 2);
    }

    function test_zero_inflow_settle_still_steps_and_records() public {
        _nextEpoch();
        uint32 n = _settle();
        Record memory r = _rec(n);
        assertEq(r.epoch, 1);
        assertEq(r.time, block.timestamp);
        assertEq(r.inflow, 0);
        assertEq(r.allow, 0);
        assertEq(r.buyDecided, 0);
        assertEq(r.flags, 0, "no flags: an empty vault is not a failed claim");
        assertEq(r.clampBits, 0);
        assertEq(r.outputs, W);
        // the FIXED chip counts beats in its state: one beat happened
        assertEq(KernelMath.stateBits(kernel.state()), 1);
        assertEq(r.stateAfter, kernel.state());
    }

    function test_settle_emits_Settled() public {
        _buy(alice, 1 ether);
        _nextEpoch();
        vm.recordLogs();
        _settle();
        Record memory r = _rec(1);
        bytes32 sig = keccak256(
            "Settled(uint32,uint32,bytes12,bytes14,uint16,uint8,bytes32,uint128,uint128,uint128,uint128,uint128)"
        );
        bool found;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig && logs[i].emitter == address(kernel)) {
                found = true;
                assertEq(uint256(logs[i].topics[1]), 1, "n");
                assertEq(logs[i].data, _eventData(r), "event data equals the stored record");
            }
        }
        assertTrue(found, "Settled emitted");
    }

    function _eventData(Record memory r) internal pure returns (bytes memory) {
        return bytes.concat(
            abi.encode(r.epoch, r.inputs, r.outputs, r.clampBits, r.flags, r.stateAfter),
            abi.encode(r.inflow, r.allow, r.buyDecided, r.buyExecuted, r.tokensOut)
        );
    }

    // ------------------------------------------------------------------ the whole loop, by hand

    /// One buy of 1 OKB pays 0.03 OKB of tax. Every number below is computed by hand from the interface.
    function test_first_funded_settle_numbers() public {
        _buy(alice, 1 ether);
        assertEq(address(vault).balance, 0.03 ether, "3% buy tax sits in the vault");
        _nextEpoch();
        TradeMath.Curve memory c = _curve();
        _settle();
        Record memory r = _rec(1);

        uint256 inflow = 0.03 ether;
        uint256 allow = (inflow * 48) / 256; // 0.005625
        uint256 buyShare = (inflow * 128) / 256; // 0.015
        uint256 toReserve = inflow - allow - buyShare; // 0.009375
        assertEq(allow, 5_625_000_000_000_000);
        assertEq(buyShare, 15_000_000_000_000_000);
        assertEq(toReserve, 9_375_000_000_000_000);

        assertEq(r.inflow, inflow, "inflow");
        assertEq(r.reserveBefore, 0, "reserveBefore");
        assertEq(r.allow, allow, "allow");
        assertEq(r.buyDecided, buyShare, "buyDecided");
        assertEq(r.buyExecuted, buyShare, "buyExecuted");
        assertEq(r.clampBits, 0, "the chip decides: no clamp");
        assertEq(r.flags, 0, "no flags");

        // the buy: exact quote from the curve as it stood before the settle
        uint256 net = buyShare - (buyShare * 400) / 10_000; // 1% fee + 3% tax
        uint256 expectOut = c.vToken - TradeMath.ceilDiv(c.vQuote * c.vToken, c.vQuote + net);
        assertEq(r.tokensOut, expectOut, "tokens from the exact quote");
        assertEq(token.balanceOf(address(kernel)), expectOut, "tokens are in the kernel");
        assertEq(kernel.lockedTokens(), expectOut, "and counted as locked");

        // books
        assertEq(kernel.reserve(), toReserve, "reserve");
        assertEq(kernel.creditOf(payee, NATIVE), allow, "allowance is a pull credit");
        assertEq(kernel.totalCredits(NATIVE), allow);
        assertEq(address(kernel).balance, allow + toReserve, "balance = credits + reserve");
        assertEq(kernel.cumInflow(), inflow);
        assertEq(kernel.allowPaidCum(), allow);
        (uint128 cum, uint128 paid) = kernel.cums(1);
        assertEq(cum, inflow);
        assertEq(paid, allow);

        // the kernel's own buy paid 3% tax back into its vault: it is next epoch's inflow
        assertEq(address(vault).balance, (buyShare * 300) / 10_000);
    }

    function test_input_word_fields() public {
        _buy(alice, 1 ether);
        _nextEpoch();
        TradeMath.Curve memory c = _curve();
        _settle();
        KernelMath.InputFields memory f = _in(1);
        assertEq(f.tax, KernelMath.lg8(0.03 ether), "TAX");
        assertEq(f.tax, 438, "0.03 OKB is code 438");
        assertEq(f.taxCum, f.tax, "TAXCUM on the first settle");
        assertEq(f.rev, 0);
        assertEq(f.revCum, 0);
        assertEq(f.res, 0, "RES: empty reserve");
        assertEq(f.esc, 0);
        assertEq(f.prog, (c.sold * 255) / c.sellable, "PROG");
        assertEq(f.lock, 0, "LOCK: nothing locked yet");
        assertEq(f.dt, 1, "DT");
        assertEq(f.grad, 0);
        assertEq(KernelMath.inputWord(_rec(1).inputs) >> 81, 0, "bits 81-95 are zero");

        // second settle, three epochs later, with a reserve and locked tokens
        _buy(bob, 2 ether);
        vm.warp(block.timestamp + 3 * EPOCH);
        uint256 reserveBefore = kernel.reserve();
        uint256 locked = kernel.lockedTokens();
        uint256 vaultBal = address(vault).balance;
        c = _curve();
        _settle();
        f = _in(2);
        assertEq(f.tax, KernelMath.lg8(vaultBal), "TAX 2");
        assertEq(f.taxCum, KernelMath.lg8(0.03 ether + vaultBal), "TAXCUM includes this settle");
        assertEq(f.res, KernelMath.lg8(reserveBefore), "RES is the reserve before routing");
        assertEq(f.prog, (c.sold * 255) / c.sellable, "PROG 2");
        assertEq(f.lock, (locked * 255) / 1e27, "LOCK");
        assertEq(f.dt, 3, "DT counts epochs since the last persisted step");
        assertEq(_rec(2).epoch, 4);
    }

    function test_dt_saturates_at_15() public {
        _nextEpoch();
        _settle();
        vm.warp(block.timestamp + 40 * EPOCH);
        _settle();
        assertEq(_in(2).dt, 15);
    }

    // ------------------------------------------------------------------ inflow is a balance delta

    /// (a) a third party calls claimFor before the settle. The kernel accepts native OKB from the vault only
    /// inside its own claim, so the push is refused (the live vault reverts TransferFailed), the tax waits in
    /// the vault, and the settle claims and routes all of it.
    function test_inflow_thirdPartyClaimForBeforeSettle_onCurve() public {
        _buy(alice, 1 ether);
        vm.prank(bob);
        vm.expectRevert(MockVault.TransferFailed.selector);
        vault.claimFor(address(kernel), NATIVE);
        assertEq(address(vault).balance, 0.03 ether, "the tax is still in the vault");
        assertEq(address(kernel).balance, 0);
        _nextEpoch();
        _settle();
        Record memory r = _rec(1);
        assertEq(r.inflow, 0.03 ether, "claimed by the settle itself");
        assertEq(r.flags, 0);
        assertEq(r.allow, (0.03 ether * 48) / 256);
        assertEq(r.buyExecuted, 0.015 ether);
    }

    /// Inflow is the balance beyond the books, not the amount a claim reports: value that reached the kernel
    /// outside any claim (a forced transfer cannot be refused) is routed like tax.
    function test_inflow_is_balance_minus_accounted_not_the_claim_amount() public {
        _buy(alice, 1 ether); // 0.03 in the vault
        vm.deal(address(kernel), 0.5 ether); // arrives behind the kernel's back
        _nextEpoch();
        _settle();
        Record memory r = _rec(1);
        assertEq(r.inflow, 0.53 ether, "claimed tax plus what was already here");
        assertEq(address(kernel).balance, kernel.totalCredits(NATIVE) + kernel.reserve());
    }

    /// (c) the claim reverts, but money that already arrived is still routed
    function test_inflow_claimRevertsButBalanceAlreadyArrived() public {
        vm.deal(address(kernel), 0.03 ether); // already arrived
        _buy(alice, 2 ether); // 0.06 accrues in the vault
        vault.setMode(1); // and the vault breaks
        _nextEpoch();
        _settle();
        Record memory r = _rec(1);
        assertTrue(_has(r.flags, RecordFlags.CLAIM_FAILED), "flag 4");
        assertEq(r.inflow, 0.03 ether, "what had arrived is routed");
        assertEq(r.buyExecuted, 0.015 ether, "the legs still run");
        // 0.06 of tax plus the 3% the kernel's own buy just paid
        uint256 waiting = 0.06 ether + (0.015 ether * 300) / 10_000;
        assertEq(address(vault).balance, waiting, "the rest waits in the vault");

        vault.setMode(0);
        _nextEpoch();
        _settle();
        r = _rec(2);
        assertFalse(_has(r.flags, RecordFlags.CLAIM_FAILED));
        assertEq(r.inflow, waiting);
    }

    function test_claim_paused_is_a_flag_and_settle_continues() public {
        _buy(alice, 1 ether);
        vault.setMode(3); // IGNIX DIVIDEND pause: claim reverts Paused()
        _nextEpoch();
        _settle();
        Record memory r = _rec(1);
        assertTrue(_has(r.flags, RecordFlags.CLAIM_FAILED));
        assertEq(r.inflow, 0);
        assertEq(KernelMath.stateBits(kernel.state()), 1, "the chip still stepped");
    }

    function test_claim_that_burns_all_its_gas_is_a_flag() public {
        _buy(alice, 1 ether);
        vault.setMode(2);
        _nextEpoch();
        _settle();
        assertTrue(_has(_rec(1).flags, RecordFlags.CLAIM_FAILED));
        assertEq(kernel.count(), 1);
    }

    function test_forced_native_is_counted_as_inflow() public {
        // a self-destruct or coinbase payment cannot be refused; it is inflow like any other
        vm.deal(address(kernel), 1 ether);
        _nextEpoch();
        _settle();
        assertEq(_rec(1).inflow, 1 ether);
    }

    // ------------------------------------------------------------------ receive()

    function test_receive_refuses_plain_transfers() public {
        vm.prank(alice);
        (bool ok,) = address(kernel).call{value: 1 ether}("");
        assertFalse(ok, "a plain transfer is refused");
        vm.deal(launcher, 1 ether);
        vm.prank(launcher);
        (ok,) = address(kernel).call{value: 1 ether}("");
        assertFalse(ok, "the launcher cannot fund a kernel that buys");
        vm.deal(payee, 1 ether);
        vm.prank(payee);
        (ok,) = address(kernel).call{value: 1 ether}("");
        assertFalse(ok, "nor can the allowance payee");
    }

    /// Outside the kernel's own claim and its own buyTo nobody is accepted: not the vault, not the Manager,
    /// not the router, not WOKB. No IGNIX refund or push path can be used to send money into a kernel.
    function test_receive_refuses_vault_manager_router_wokb_outside_own_calls() public {
        address[4] memory senders = [address(vault), address(manager), address(router), address(wokb)];
        for (uint256 i = 0; i < 4; i++) {
            vm.deal(senders[i], 1 ether);
            vm.prank(senders[i]);
            (bool ok,) = address(kernel).call{value: 0.1 ether}("");
            assertFalse(ok);
        }
        assertEq(address(kernel).balance, 0);
        // a stranger's curve sell cannot name the kernel as the payee of a Manager payment either: the only
        // Manager payment a kernel accepts is one made inside its own buyTo
        _buy(alice, 1 ether);
        _nextEpoch();
        _settle();
        Record memory r = _rec(1);
        assertEq(r.flags & (RecordFlags.CLAIM_FAILED | RecordFlags.BUY_FAILED), 0);
        assertGt(r.inflow, 0, "the kernel's own claim was accepted");
        assertGt(r.buyExecuted, 0, "and so was its own buy");
    }

    function test_refund_from_the_manager_inside_own_buy_is_accepted_and_accounted() public {
        _buy(alice, 1 ether);
        manager.setRefundWei(1000); // the Manager sends 1000 wei back to the buy recipient
        vm.deal(address(manager), address(manager).balance + 1 ether);
        _nextEpoch();
        _settle();
        Record memory r = _rec(1);
        // the refund did not break the buy, but the buy moved less than was decided: flag 32, and nothing else
        assertEq(r.flags, RecordFlags.BUY_FAILED, "flag 32: a buy moved less than decided");
        assertEq(r.buyDecided, 0.015 ether);
        assertEq(r.buyExecuted, 0.015 ether - 1000, "what was spent is measured net of the refund");
        assertGt(r.tokensOut, 0, "the tokens did arrive");
        assertEq(kernel.lockedTokens(), r.tokensOut);
        assertEq(
            address(kernel).balance, kernel.totalCredits(NATIVE) + kernel.reserve(), "and the refund is in the reserve"
        );
        assertEq(r.nativeIn, 0, "nativeIn is the router leg's; it is 0 on the curve");
    }

    /// Flag 32 is about what the call moved against what it was sent, not about a cap: a buy shrunk by a cap
    /// that then executes in full carries flag 128 only.
    function test_a_shrunk_buy_that_executes_in_full_is_not_flagged_as_failed() public {
        _fixtureHostile(_word(0, 0, 0, 256, 128, 1023));
        vm.deal(address(vault), 6 ether);
        _nextEpoch();
        _settle();
        _nextEpoch();
        _settle();
        Record memory r = _rec(2);
        assertLt(r.buyExecuted, r.buyDecided, "shrunk");
        assertEq(r.flags, RecordFlags.BUY_SHRUNK, "flag 128 alone");
        // the same buy with a refund on top: both flags
        manager.setRefundWei(7);
        vm.deal(address(manager), address(manager).balance + 1 ether);
        _nextEpoch();
        _settle();
        r = _rec(3);
        assertEq(r.flags, RecordFlags.BUY_SHRUNK | RecordFlags.BUY_FAILED);
    }

    /// The IGNIX token probes contracts it meets with token0(), token1() and fee() during its protection
    /// window and taxes those that look like pools. The kernel answers none of them and has no fallback.
    function test_kernel_has_no_fallback_and_answers_no_pool_probe() public {
        bytes4[3] memory probes =
            [bytes4(keccak256("token0()")), bytes4(keccak256("token1()")), bytes4(keccak256("fee()"))];
        for (uint256 i = 0; i < 3; i++) {
            (bool ok,) = address(kernel).staticcall{gas: 10_000}(abi.encodeWithSelector(probes[i]));
            assertFalse(ok);
        }
        (bool okAny,) = address(kernel).call(hex"deadbeef");
        assertFalse(okAny, "unknown selector");
        (okAny,) = address(kernel).call{value: 0}(hex"00");
        assertFalse(okAny, "any calldata that is not a function");
    }

    /// Before graduation the kernel has no way to move, approve or sell the tokens it bought.
    function test_bought_tokens_cannot_leave_before_graduation() public {
        _buy(alice, 10 ether);
        _nextEpoch();
        _settle();
        uint256 locked = kernel.lockedTokens();
        assertGt(locked, 0);
        vm.expectRevert(Kernel.NotGraduated.selector);
        kernel.burnLocked();
        assertEq(kernel.withdrawCredit(payee, address(token)), 0, "no token credit exists on the curve");
        assertEq(token.allowance(address(kernel), address(manager)), 0, "the Manager was never approved");
        assertEq(token.balanceOf(address(kernel)), locked);
    }

    // ------------------------------------------------------------------ clamps on the curve

    function test_K2_allowance_share_above_capT_is_clipped_and_excess_stays() public {
        _fixtureHostile(_word(0, 0, 256, 0, 0, 1023)); // everything to the allowance
        _buy(alice, 1 ether);
        _nextEpoch();
        _settle();
        Record memory r = _rec(1);
        assertEq(r.clampBits & KernelMath.K2, KernelMath.K2, "K2");
        // capT = 64/256 = 25% of the inflow, which is also the 25% lifetime cap: no K2L
        assertEq(r.allow, 0.03 ether / 4);
        assertEq(r.buyDecided, 0);
        assertEq(kernel.reserve(), 0.03 ether - r.allow, "the clipped excess is in the reserve");
    }

    function test_K1T_malformed_group_becomes_reserve_and_state_still_advances() public {
        _fixtureHostile(_word(200, 200, 200, 200, 0, 1023)); // sums to 800
        _buy(alice, 1 ether);
        _nextEpoch();
        _settle();
        Record memory r = _rec(1);
        assertEq(r.clampBits, KernelMath.K1T);
        assertEq(r.allow, 0);
        assertEq(r.buyDecided, 0);
        assertEq(kernel.reserve(), 0.03 ether);
        assertEq(KernelMath.stateBits(kernel.state()), 1, "state advanced: a bad word never freezes the kernel");
    }

    function test_K3_release_above_relMax_is_clipped() public {
        _fixtureHostile(_word(0, 0, 0, 256, 256, 1023)); // hoard the inflow, release everything
        _buy(alice, 10 ether);
        _nextEpoch();
        _settle(); // reserve = 0.3
        _nextEpoch();
        _settle();
        Record memory r = _rec(2);
        assertEq(r.clampBits & KernelMath.K3, KernelMath.K3);
        assertEq(r.reserveBefore, 0.3 ether);
        assertEq(r.buyDecided, 0.15 ether, "relMax = 128/256 of the reserve");
    }

    function test_K5_floor_forces_a_release_from_a_hoarding_chip() public {
        _fixtureHostile(_word(0, 0, 0, 256, 0, 1023)); // hoard everything, never release
        _buy(alice, 10 ether);
        _nextEpoch();
        _settle();
        assertEq(_rec(1).clampBits, 0, "empty reserve: the floor does not apply yet");
        _nextEpoch();
        _settle();
        Record memory r = _rec(2);
        // lg8(0.3 OKB) = 464 >= floorMin 400, REL 0 < floorRel 2
        assertEq(r.clampBits, KernelMath.K5);
        assertEq(r.buyDecided, (0.3 ether * 2) / 256);
        assertEq(r.buyExecuted, r.buyDecided);
        assertGt(r.tokensOut, 0, "a hoarding chip cannot stop the minimum release");
    }

    function test_K2L_lifetime_cap() public {
        Envelope memory e = _env();
        e.capT = 128; // the largest allowance share the factory accepts
        e.allowCumBps = 1000; // 10% of cumulative inflow
        e.fbAllow = 0;
        _fixtureWith2(ChipModel.fixedChip(8, _word(128, 0, 128, 0, 0, 1023)), e);
        _buy(alice, 1 ether);
        _nextEpoch();
        _settle();
        Record memory r = _rec(1);
        assertEq(r.clampBits, KernelMath.K2L);
        assertEq(r.allow, 0.003 ether, "10% of 0.03");
    }

    function test_chip_ceiling_is_not_a_clamp() public {
        // CEIL = 399 is 0.001 OKB
        _fixtureHostile(_word(128, 64, 48, 16, 0, 399));
        _buy(alice, 1 ether);
        _nextEpoch();
        _settle();
        Record memory r = _rec(1);
        assertEq(r.clampBits, 0);
        assertEq(r.allow, KernelMath.exp8(399));
        assertLe(r.allow, 0.001 ether);
    }

    // ------------------------------------------------------------------ the curve buy and its guards

    function test_buy_is_capped_so_a_sandwich_loses_money() public {
        // release half of a large reserve at once: far above the impact cap
        _fixtureHostile(_word(0, 0, 0, 256, 128, 1023));
        vm.deal(address(vault), 6 ether); // accrued tax
        _nextEpoch();
        _settle();
        _nextEpoch();
        TradeMath.Curve memory c = _curve();
        _settle();
        Record memory r = _rec(2);
        assertEq(r.reserveBefore, 6 ether);
        assertEq(r.buyDecided, 3 ether);
        // cap = vQuote * (100 + 100 + (300 + 300) * (256 - 64) / 256) / 4 / 10000 = vQuote * 1.625%
        uint256 cap = (c.vQuote * (200 * 256 + 600 * 192)) / (256 * 4 * 10_000);
        assertEq(cap, (c.vQuote * 1625) / 100_000);
        assertLt(cap, 0.5 ether);
        assertEq(r.buyExecuted, cap, "shrunk to the cap");
        assertTrue(_has(r.flags, RecordFlags.BUY_SHRUNK), "flag 128");
        assertEq(kernel.reserve(), 6 ether - cap, "the unexecuted part stays in the reserve");
    }

    /// The fee part of the cap is what the Manager reports for this token in the same settle, buy side plus
    /// sell side (100 + 100 today): the cap follows a change of either, and the quote stays exact.
    function test_impact_cap_uses_the_fees_the_manager_reports() public {
        _fixtureHostile(_word(0, 0, 0, 256, 128, 1023));
        vm.deal(address(vault), 6 ether);
        _nextEpoch();
        _settle();
        manager.setFees(address(token), 30, 250);
        _nextEpoch();
        TradeMath.Curve memory c = _curve();
        assertEq(c.buyFeeBps + c.sellFeeBps, 280);
        _settle();
        Record memory r = _rec(2);
        assertEq(r.buyDecided, 3 ether);
        // cap = vQuote * (30 + 250 + (300 + 300) * (256 - 64) / 256) / 4 / 10000 = vQuote * 1.825%
        uint256 cap = (c.vQuote * (280 * 256 + 600 * 192)) / (256 * 4 * 10_000);
        assertEq(cap, (c.vQuote * 1825) / 100_000);
        assertEq(r.buyExecuted, cap, "shrunk to the cap made with the Manager's fees");
        assertEq(r.flags, RecordFlags.BUY_SHRUNK, "flag 128 alone: the Manager took the quote made with them");
        assertEq(r.tokensOut, TradeMath.curveOut(c, cap));
    }

    /// The attacker buys, lets the kernel buy at its cap, and sells everything, all in one block.
    function testFuzz_sandwich_of_a_capped_buy_is_unprofitable(uint256 size) public {
        size = bound(size, 0.01 ether, 70 ether);
        _fixtureHostile(_word(0, 0, 0, 256, 128, 1023));
        vm.deal(address(vault), 20 ether);
        _nextEpoch();
        _settle();
        _nextEpoch();
        uint256 before = bob.balance;
        _buy(bob, size);
        _settle();
        Record memory r = _rec(2);
        assertTrue(_has(r.flags, RecordFlags.BUY_SHRUNK), "the kernel bought at its cap");
        assertGt(r.buyExecuted, 0);
        _sell(bob, token.balanceOf(bob));
        assertLt(bob.balance, before, "the round trip costs more than the kernel's buy moved the price");
    }

    /// The same when the attacker is the allowance payee and gets the allowance share of his own tax back.
    /// Two worlds from one starting state: in the second the payee sandwiches the kernel's buy. His wealth
    /// (balance plus credits, after the settle that routes his sell tax) must not be higher than without it.
    function testFuzz_sandwich_by_the_allowance_payee_is_unprofitable(uint256 size, uint16 capT) public {
        size = bound(size, 0.01 ether, 60 ether);
        capT = uint16(bound(capT, 0, 128)); // every allowance cap the factory accepts
        Envelope memory e = _env();
        e.capT = capT;
        e.fbAllow = 0;
        e.allowCumBps = 5000; // the largest lifetime share the factory accepts
        e.allowancePayee = bob; // the attacker
        // everything the envelope allows goes to the allowance; half of the reserve is released every settle
        _fixtureWith2(ChipModel.fixedChip(8, _word(0, 0, 256, 0, 128, 1023)), e);
        vm.deal(address(vault), 20 ether);
        _nextEpoch();
        _settle();
        _nextEpoch();
        uint256 snap = vm.snapshotState();

        // world A: no attack
        _settle();
        _nextEpoch();
        _settle();
        uint256 wealthA = bob.balance + kernel.creditOf(bob, NATIVE);

        // world B: buy, settle, sell, all in one block; then the settle that routes the sell tax
        vm.revertToState(snap);
        _buy(bob, size);
        _settle();
        _sell(bob, token.balanceOf(bob));
        _nextEpoch();
        _settle();
        uint256 wealthB = bob.balance + kernel.creditOf(bob, NATIVE);

        assertLt(wealthB, wealthA, "the sandwich lost money even with the allowance rebate");
    }

    function test_buy_never_graduates_the_curve() public {
        _fixtureHostile(_word(256, 0, 0, 0, 128, 1023));
        // leave very little on the curve
        uint256 cost = manager.costToGraduate(address(token));
        _buy(whale, cost - 0.02 ether);
        _nextEpoch();
        TradeMath.Curve memory c = _curve();
        uint256 room = TradeMath.maxNonGraduatingBuy(c);
        assertGt(room, 0);
        _settle();
        Record memory r = _rec(1);
        assertGt(r.buyDecided, room, "the chip asked for more than the curve has left");
        assertEq(r.buyExecuted, room, "shrunk to the largest buy that leaves the curve open");
        assertTrue(_has(r.flags, RecordFlags.BUY_SHRUNK));
        assertEq(manager.pairOf(address(token)), address(0), "not graduated");
        MockManager.Token memory t = manager.raw(address(token));
        assertLt(t.sold, t.sellable, "at least one wei of token is left");
        assertFalse(kernel.graduated());
    }

    function test_buy_skipped_when_curve_is_one_wei_from_sold_out() public {
        _fixtureHostile(_word(256, 0, 0, 0, 128, 1023));
        uint256 cost = manager.costToGraduate(address(token));
        _buy(whale, cost - 0.02 ether);
        // each settle buys what is left without closing the curve, until nothing meaningful remains
        for (uint256 i = 0; i < 6; i++) {
            _nextEpoch();
            _settle();
        }
        Record memory r = _rec(6);
        assertEq(manager.pairOf(address(token)), address(0), "still not graduated");
        assertEq(address(kernel).balance, kernel.reserve() + kernel.totalCredits(NATIVE));
        assertTrue(r.buyExecuted <= r.buyDecided);
    }

    function test_buy_skipped_during_anti_snipe_window() public {
        // a token launched with a 50% anti-snipe surcharge decaying over 30 minutes
        Built memory b = _buildSnipe();
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        manager.buy{value: 10 ether}(address(b.token), 10 ether, 0);
        vm.warp(block.timestamp + EPOCH); // 15 minutes in: surcharge still 25%
        assertGt(manager.snipeBpsNow(address(b.token)), 0);
        b.kernel.settle();
        Record memory r = b.kernel.records(1);
        assertGt(r.buyDecided, 0);
        assertEq(r.buyExecuted, 0);
        assertTrue(_has(r.flags, RecordFlags.BUY_SKIPPED), "flag 16");
        assertEq(b.kernel.reserve(), r.inflow - r.allow, "the buy amount stays in the reserve");

        vm.warp(block.timestamp + EPOCH); // 30 minutes: window over
        assertEq(manager.snipeBpsNow(address(b.token)), 0);
        b.kernel.settle();
        r = b.kernel.records(2);
        assertFalse(_has(r.flags, RecordFlags.BUY_SKIPPED));
    }

    function test_buy_skipped_during_founder_round() public {
        _buy(alice, 1 ether);
        manager.setFounderRound(address(token), uint64(block.timestamp + 10 * EPOCH));
        _nextEpoch();
        _settle();
        Record memory r = _rec(1);
        assertTrue(_has(r.flags, RecordFlags.BUY_SKIPPED), "FounderOnly is a guard, not a failure");
        assertFalse(_has(r.flags, RecordFlags.BUY_FAILED));
        assertEq(r.buyExecuted, 0);
        assertEq(kernel.reserve(), 0.03 ether - r.allow);
    }

    function test_founder_round_is_checked_before_the_call() public {
        _buy(alice, 1 ether);
        manager.setFounderRound(address(token), uint64(block.timestamp + 10 * EPOCH));
        manager.setBuyMode(1); // a call to buyTo would fail and be flagged as a failed buy
        _nextEpoch();
        _settle();
        Record memory r = _rec(1);
        assertTrue(_has(r.flags, RecordFlags.BUY_SKIPPED));
        assertFalse(_has(r.flags, RecordFlags.BUY_FAILED), "buyTo was not called at all");
    }

    function test_buy_skipped_during_buy_pause() public {
        _buy(alice, 1 ether);
        manager.setPaused(1, uint64(block.timestamp + 100 * EPOCH));
        _nextEpoch();
        _settle();
        Record memory r = _rec(1);
        assertTrue(_has(r.flags, RecordFlags.BUY_SKIPPED));
        assertFalse(_has(r.flags, RecordFlags.BUY_FAILED));
        assertEq(r.buyExecuted, 0);
    }

    function test_buy_call_failure_is_flagged_and_amount_stays() public {
        _buy(alice, 1 ether);
        manager.setBuyMode(1);
        _nextEpoch();
        _settle();
        Record memory r = _rec(1);
        assertTrue(_has(r.flags, RecordFlags.BUY_FAILED), "flag 32");
        assertEq(r.buyDecided, 0.015 ether);
        assertEq(r.buyExecuted, 0);
        assertEq(r.tokensOut, 0);
        assertEq(kernel.reserve(), 0.03 ether - r.allow, "nothing lost, nothing re-routed");
        assertEq(address(kernel).balance, 0.03 ether);
    }

    function test_buy_that_burns_all_its_gas_is_flagged() public {
        _buy(alice, 1 ether);
        manager.setBuyMode(2);
        _nextEpoch();
        _settle();
        assertTrue(_has(_rec(1).flags, RecordFlags.BUY_FAILED));
        assertEq(address(kernel).balance, 0.03 ether);
    }

    function test_buy_reverts_when_manager_formula_differs_from_quote() public {
        _buy(alice, 1 ether);
        manager.setBuyMode(3); // the Manager would deliver one wei less than the exact quote
        _nextEpoch();
        _settle();
        Record memory r = _rec(1);
        assertTrue(_has(r.flags, RecordFlags.BUY_FAILED), "Slippage: minTokensOut is the exact quote");
        assertEq(r.buyExecuted, 0);
    }

    function test_manager_cannot_reenter_settle_during_buy() public {
        _buy(alice, 1 ether);
        manager.setReenter(address(kernel), abi.encodeCall(IKernelMin.settle, ()));
        _nextEpoch();
        _settle();
        // the reentrant settle reverted inside buyTo, so the buy failed and was flagged
        assertTrue(_has(_rec(1).flags, RecordFlags.BUY_FAILED));
        assertEq(kernel.count(), 1);
    }

    function test_manager_cannot_reenter_withdraw_during_buy() public {
        _buy(alice, 1 ether);
        manager.setReenter(address(kernel), abi.encodeCall(IKernelV1.withdrawCredit, (payee, NATIVE)));
        _nextEpoch();
        _settle();
        assertTrue(_has(_rec(1).flags, RecordFlags.BUY_FAILED));
        assertEq(kernel.creditOf(payee, NATIVE), _rec(1).allow, "credit untouched");
    }

    // ------------------------------------------------------------------ curve read failures

    function test_curve_read_revert_is_a_flag_and_buy_is_skipped() public {
        _buy(alice, 1 ether);
        manager.setTokensMode(1);
        _nextEpoch();
        _settle();
        Record memory r = _rec(1);
        assertTrue(_has(r.flags, RecordFlags.CURVE_READ_FAILED), "flag 8");
        assertTrue(_has(r.flags, RecordFlags.BUY_SKIPPED), "flag 16");
        assertEq(_in(1).prog, 0, "PROG reads 0 when the curve cannot be read");
        assertEq(r.allow, (0.03 ether * 48) / 256, "the allowance is still credited");
        assertEq(r.buyExecuted, 0);
    }

    function test_curve_read_short_return_is_a_failed_read() public {
        _buy(alice, 1 ether);
        manager.setTokensMode(2); // 480 bytes
        _nextEpoch();
        _settle();
        assertTrue(_has(_rec(1).flags, RecordFlags.CURVE_READ_FAILED));
    }

    function test_curve_read_longer_return_is_accepted() public {
        _buy(alice, 1 ether);
        manager.setTokensMode(3); // 544 bytes: the struct grew upstream
        _nextEpoch();
        _settle();
        Record memory r = _rec(1);
        assertEq(r.flags, 0, "an appended field does not disable buys");
        assertEq(r.buyExecuted, 0.015 ether);
    }

    function test_curve_read_absurd_values_are_a_failed_read() public {
        _buy(alice, 1 ether);
        manager.setTokensMode(4);
        _nextEpoch();
        _settle();
        assertTrue(_has(_rec(1).flags, RecordFlags.CURVE_READ_FAILED));
    }

    function test_curve_read_that_burns_gas_is_a_failed_read() public {
        _buy(alice, 1 ether);
        manager.setTokensMode(5);
        _nextEpoch();
        _settle();
        assertTrue(_has(_rec(1).flags, RecordFlags.CURVE_READ_FAILED));
    }

    function test_snipe_read_failure_does_not_block_the_buy() public {
        _buy(alice, 1 ether);
        manager.setSnipeReverts(true);
        _nextEpoch();
        // the mock's own buy path also reads the surcharge, so the buy itself fails here; the point is that
        // the kernel tried and flagged it instead of reverting
        _settle();
        Record memory r = _rec(1);
        assertTrue(_has(r.flags, RecordFlags.BUY_FAILED) || r.buyExecuted == r.buyDecided);
    }

    // ------------------------------------------------------------------ buys disabled

    function test_buy_disabled_credits_sink() public {
        Envelope memory e = _env();
        e.buyEnabled = false;
        e.sink = sinkAddr;
        _fixtureWith2(ChipModel.fixedChip(8, W), e);
        _buy(alice, 1 ether);
        _nextEpoch();
        _settle();
        Record memory r = _rec(1);
        assertEq(r.buyDecided, 0.015 ether);
        assertEq(r.buyExecuted, 0.015 ether, "credited, so it left the routable pool");
        assertEq(r.tokensOut, 0);
        assertEq(kernel.creditOf(sinkAddr, NATIVE), 0.015 ether);
        assertEq(kernel.lockedTokens(), 0, "no buy happened");
        assertEq(token.balanceOf(address(kernel)), 0);
        assertEq(address(kernel).balance, kernel.totalCredits(NATIVE) + kernel.reserve());
        assertEq(r.flags, 0);
    }

    // ------------------------------------------------------------------ helpers

    function _fixtureHostile(bytes14 word) internal {
        _fixtureWith2(ChipModel.fixedChip(8, word), _env());
    }

    uint256 internal _salt;

    function _fixtureWith2(bytes memory netlist, Envelope memory e) internal {
        Built memory b = _build(netlist, 2200, e, 300, bytes32(++_salt));
        kernel = b.kernel;
        token = b.token;
        vault = b.vault;
        chipId = b.chipId;
    }

    function _buildSnipe() internal returns (Built memory b) {
        vm.prank(launcher);
        b.chipId = fab.tapeoutChip(ChipModel.fixedChip(8, W), 2200);
        b.kernel = Kernel(payable(factory.create(_env(), b.chipId, bytes32("snipe"))));
        (address t, address v) = manager.createToken(launcher, address(b.kernel), 300, 300, 5000, 30, GRADUATION);
        b.token = MockToken(t);
        b.vault = MockVault(payable(v));
        vm.prank(launcher);
        circuits.transferFrom(launcher, address(b.kernel), b.chipId);
        b.kernel.bind(t);
    }
}
