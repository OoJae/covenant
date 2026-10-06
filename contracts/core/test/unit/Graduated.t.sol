// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "../Base.t.sol";
import {Kernel} from "../../src/Kernel.sol";
import {KernelMath} from "../../src/KernelMath.sol";
import {TradeMath} from "../../src/lib/TradeMath.sol";
import {Record, Envelope, RecordFlags} from "../../src/interfaces/IKernelV1.sol";
import {ChipModel} from "../mocks/MockTapeOut.sol";
import {MockPair, MockRouter} from "../mocks/MockIgnix.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice settle() after the token graduated to Uniswap V2: the regime switch, token inflow, the burn leg,
///         the native leg, locked tokens.
contract GraduatedTest is Base {
    // 50% buy, 25% hold, 18.75% allowance, 6.25% reserve, no release, no ceiling
    bytes14 internal W = _word(128, 64, 48, 16, 0, 1023);
    MockPair internal pair;

    function setUp() public override {
        super.setUp();
        _fixture(W);
    }

    /// @dev One funded curve epoch (the kernel buys and locks tokens), then a whale graduates the curve.
    function _curveThenGraduate() internal {
        _buy(alice, 10 ether);
        _nextEpoch();
        _settle(); // record 1
        pair = _graduate();
    }

    function _reserves() internal view returns (uint256 rToken, uint256 rQuote) {
        (uint112 a, uint112 b,) = pair.getReserves();
        (rToken, rQuote) = address(token) < address(wokb) ? (uint256(a), uint256(b)) : (uint256(b), uint256(a));
    }

    // ------------------------------------------------------------------ the regime switch

    function test_graduation_is_latched_by_the_first_settle_that_sees_the_pair() public {
        _curveThenGraduate();
        assertFalse(kernel.graduated(), "not latched until a settle sees it");
        assertEq(kernel.pair(), address(0));
        assertEq(token.pair(), address(pair), "the token itself reports its pair");
        uint256 oldReserve = kernel.reserve();
        assertEq(oldReserve, 0.09375 ether);
        _nextEpoch();
        vm.expectEmit(true, false, false, true, address(kernel));
        emit Kernel.GraduationSeen(address(pair), oldReserve);
        _settle();
        assertTrue(kernel.graduated());
        assertEq(kernel.pair(), address(pair), "the kernel's pair is the address the token reported");
        Record memory r = _rec(2);
        assertTrue(_has(r.flags, RecordFlags.GRADUATED), "flag 64");
        KernelMath.InputFields memory f = _in(2);
        assertEq(f.grad, 1, "GRAD");
        assertEq(f.prog, 255, "PROG is 255 once graduated");
        assertFalse(_has(_rec(1).flags, RecordFlags.GRADUATED));
    }

    function test_first_graduated_settle_numbers() public {
        _curveThenGraduate();
        uint256 locked = kernel.lockedTokens();
        assertGt(locked, 0);
        _v2Buy(alice, 2 ether); // pays the buy tax in tokens to the vault
        uint256 taxTokens = token.balanceOf(address(vault));
        assertGt(taxTokens, 0);
        uint256 nativeCreditBefore = kernel.creditOf(payee, NATIVE);
        _nextEpoch();
        _settle();
        Record memory r = _rec(2);

        // regime asset is now the project token; totals restart
        assertEq(r.inflow, taxTokens, "inflow in project tokens");
        assertEq(r.reserveBefore, 0, "the token reserve starts at zero");
        assertEq(_in(2).tax, KernelMath.lg8(taxTokens));
        assertEq(_in(2).taxCum, KernelMath.lg8(taxTokens), "TAXCUM restarts at graduation");
        assertEq(kernel.cumInflow(), taxTokens);

        // no allowance after graduation: the chip's 48/256 stays in the reserve, and no clamp says so
        uint256 burn = (taxTokens * 128) / 256;
        assertEq(r.allow, 0, "no allowance after graduation");
        assertEq(r.clampBits, 0, "and it is not a clamp");
        assertEq(r.buyDecided, burn);
        assertEq(r.buyExecuted, burn, "the buy share of token tax went to 0xdEaD");
        assertEq(kernel.creditOf(payee, address(token)), 0, "the payee is never credited in the project token");
        assertEq(kernel.totalCredits(address(token)), 0);
        assertEq(kernel.creditOf(payee, NATIVE), nativeCreditBefore, "and no allowance is taken from native OKB");
        assertEq(kernel.reserve(), taxTokens - burn, "token reserve: everything that was not burned");
        assertEq(kernel.allowPaidCum(), 0, "the regime's allowance total restarts at zero and stays there");
        (uint128 cum, uint128 paid) = kernel.cums(2);
        assertEq(cum, taxTokens);
        assertEq(paid, 0);

        // locked tokens were not counted as inflow and are still there
        assertEq(kernel.lockedTokens(), locked);
        assertEq(
            token.balanceOf(address(kernel)),
            locked + kernel.totalCredits(address(token)) + kernel.reserve(),
            "token balance = locked + credits + reserve"
        );
    }

    /// (4) tokens bought on the curve are not re-counted as fresh inflow at graduation
    function test_inflow_lockedTokensAreNotRecountedAtGraduation() public {
        _curveThenGraduate();
        uint256 locked = kernel.lockedTokens();
        assertEq(token.balanceOf(address(kernel)), locked);
        assertEq(token.balanceOf(address(vault)), 0, "no token tax yet");
        _nextEpoch();
        _settle();
        Record memory r = _rec(2);
        assertEq(r.inflow, 0, "the kernel holds tokens, and none of them is inflow");
        assertEq(r.buyDecided, 0);
        assertEq(kernel.lockedTokens(), locked);
        assertEq(token.balanceOf(DEAD), r.tokensOut, "only the native leg sent anything to 0xdEaD");
    }

    /// (b) tokens pushed after graduation without any claim by the kernel
    function test_inflow_tokensPushedAfterGraduationWithoutClaim() public {
        _curveThenGraduate();
        _nextEpoch();
        _settle(); // record 2: latches graduation
        _v2Buy(alice, 2 ether);
        uint256 taxTokens = token.balanceOf(address(vault));
        // the platform's daily payout, or anyone: the vault's balance is pushed to the kernel
        vm.prank(bob);
        vault.claimFor(address(kernel), address(token));
        assertEq(token.balanceOf(address(vault)), 0);
        // the kernel's own swap in settle 2 paid buy tax too; it arrived with the same push
        _nextEpoch();
        _settle();
        Record memory r = _rec(3);
        assertEq(r.inflow, taxTokens, "pushed tokens are inflow although the kernel claimed nothing");
        assertFalse(_has(r.flags, RecordFlags.CLAIM_FAILED));
        assertEq(r.allow, 0);
        assertEq(r.buyDecided, (taxTokens * 128) / 256, "routed like any other inflow");
    }

    function test_tokens_sent_straight_to_the_kernel_are_inflow_too() public {
        _curveThenGraduate();
        _nextEpoch();
        _settle();
        _v2Buy(alice, 1 ether);
        uint256 gift = token.balanceOf(alice) / 2;
        vm.prank(alice);
        token.transfer(address(kernel), gift);
        uint256 inVault = token.balanceOf(address(vault));
        _nextEpoch();
        _settle();
        assertEq(_rec(3).inflow, gift + inVault);
    }

    function test_token_claim_failure_is_a_flag_and_arrived_tokens_are_routed() public {
        _curveThenGraduate();
        _nextEpoch();
        _settle();
        _v2Buy(alice, 2 ether);
        vm.prank(bob);
        vault.claimFor(address(kernel), address(token));
        uint256 arrived = token.balanceOf(address(kernel)) - kernel.lockedTokens() - kernel.reserve()
            - kernel.totalCredits(address(token));
        _v2Buy(alice, 2 ether); // more tax accrues
        vault.setMode(3); // IGNIX DIVIDEND pause
        _nextEpoch();
        _settle();
        Record memory r = _rec(3);
        assertTrue(_has(r.flags, RecordFlags.CLAIM_FAILED));
        assertEq(r.inflow, arrived, "what had arrived is routed; the rest waits in the vault");
        assertGt(token.balanceOf(address(vault)), 0);
    }

    // ------------------------------------------------------------------ the burn leg

    function test_burn_failure_is_flagged_and_tokens_stay_in_reserve() public {
        _curveThenGraduate();
        _nextEpoch();
        _settle();
        _v2Buy(alice, 2 ether);
        uint256 taxTokens = token.balanceOf(address(vault));
        token.setFailure(false, false, false, DEAD); // transfers to 0xdEaD revert
        _nextEpoch();
        _settle();
        Record memory r = _rec(3);
        assertTrue(_has(r.flags, RecordFlags.BUY_FAILED), "flag 32");
        assertEq(r.buyDecided, taxTokens / 2);
        assertEq(r.buyExecuted, 0);
        assertEq(kernel.reserve(), taxTokens, "nothing lost: the buy share is in the reserve");

        // the next settle offers the reserve to the chip again
        token.setFailure(false, false, false, address(0));
        _nextEpoch();
        _settle();
        assertEq(_rec(4).reserveBefore, taxTokens);
    }

    function test_transfer_returning_false_counts_as_not_executed() public {
        _curveThenGraduate();
        _nextEpoch();
        _settle();
        _v2Buy(alice, 2 ether);
        _nextEpoch();
        // claim first, then make transfers return false without moving anything
        vm.prank(bob);
        vault.claimFor(address(kernel), address(token));
        token.setFailure(false, false, true, address(0));
        _settle();
        Record memory r = _rec(3);
        assertGt(r.buyDecided, 0);
        assertEq(r.buyExecuted, 0, "measured by balance, not by the return value");
        assertTrue(_has(r.flags, RecordFlags.BUY_FAILED));
    }

    function test_unreadable_token_balance_moves_nothing_and_loses_nothing() public {
        _curveThenGraduate();
        _nextEpoch();
        _settle();
        _v2Buy(alice, 2 ether);
        vm.prank(bob);
        vault.claimFor(address(kernel), address(token));
        uint256 bal = token.balanceOf(address(kernel));
        token.setFailure(true, false, false, address(0)); // balanceOf reverts
        _nextEpoch();
        _settle();
        Record memory r = _rec(3);
        assertEq(r.inflow, 0, "nothing new can be recognised");
        token.setFailure(false, false, false, address(0));
        assertEq(token.balanceOf(address(kernel)), bal, "nothing moved");
        _nextEpoch();
        _settle();
        assertGt(_rec(4).inflow, 0, "recognised once the balance can be read again");
    }

    // ------------------------------------------------------------------ the native leg

    function test_native_pot_buys_on_the_pair_and_burns() public {
        _curveThenGraduate();
        // the whale's graduating buy paid 3% tax in OKB: it is still in the vault
        uint256 inVault = address(vault).balance;
        assertGt(inVault, 2 ether);
        uint256 credits = kernel.totalCredits(NATIVE);
        uint256 pot = address(kernel).balance + inVault - credits;
        (uint256 rToken, uint256 rQuote) = _reserves();
        _nextEpoch();
        uint256 dead0 = token.balanceOf(DEAD);
        vm.recordLogs();
        _settle();
        Record memory r = _rec(2);

        // cap = WOKB reserve * (25 + (300 + 300) * (256 - 64) / 256) / 4 / 10000
        uint256 cap = (rQuote * (25 * 256 + 600 * 192)) / (256 * 4 * 10_000);
        assertLt(cap, pot, "the pot is larger than one epoch's cap");
        assertTrue(_has(r.flags, RecordFlags.BUY_SHRUNK), "flag 128");
        uint256 spent = pot - (address(kernel).balance - credits);
        assertEq(spent, cap, "exactly the cap was spent");
        assertEq(r.nativeIn, cap, "Record.nativeIn: the OKB the router buy spent");
        assertEq(_rec(1).nativeIn, 0, "0 on the curve");
        _assertNativeSwept(vm.getRecordedLogs(), 2, cap, TradeMath.v2NetOut(cap, rQuote, rToken, 300));

        uint256 expectOut = TradeMath.v2NetOut(cap, rQuote, rToken, 300);
        assertEq(token.balanceOf(DEAD) - dead0, expectOut, "the exact quote, net of the 3% buy tax");
        assertEq(r.tokensOut, expectOut, "tokensOut counts what reached 0xdEaD");
        assertEq(kernel.burnedTokens(), expectOut);
        assertEq(kernel.creditOf(payee, NATIVE), credits, "no allowance is taken from native OKB");
        assertEq(r.buyDecided, 0, "the native leg is not a chip decision");

        // the rest of the pot waits for the next epochs
        for (uint256 i = 0; i < 3; i++) {
            _nextEpoch();
            _settle();
        }
        assertLt(address(kernel).balance - credits, pot - cap, "the pot keeps draining");
    }

    /// @dev The router leg's event carries the same two numbers as the record.
    function _assertNativeSwept(Vm.Log[] memory logs, uint32 n, uint256 nativeIn, uint256 burned) internal view {
        bytes32 sig = keccak256("NativeSwept(uint32,uint256,uint256)");
        uint256 found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != sig || logs[i].emitter != address(kernel)) continue;
            found++;
            assertEq(uint256(logs[i].topics[1]), n, "n");
            (uint256 a, uint256 b) = abi.decode(logs[i].data, (uint256, uint256));
            assertEq(a, nativeIn, "NativeSwept.nativeIn");
            assertEq(b, burned, "NativeSwept.tokensBurned");
        }
        assertEq(found, 1, "NativeSwept emitted once");
    }

    function test_native_pot_is_drained_to_zero_over_time() public {
        _curveThenGraduate();
        uint256 pot = address(kernel).balance + address(vault).balance - kernel.totalCredits(NATIVE);
        uint256 spent;
        for (uint256 i = 0; i < 12; i++) {
            _nextEpoch();
            uint256 before = address(kernel).balance + address(vault).balance;
            _settle();
            Record memory r = _rec(kernel.count());
            assertEq(
                r.nativeIn, before - address(kernel).balance - address(vault).balance, "nativeIn, settle by settle"
            );
            spent += r.nativeIn;
        }
        assertEq(address(kernel).balance, kernel.totalCredits(NATIVE), "every wei of the pot was spent");
        assertEq(address(vault).balance, 0);
        assertEq(spent, pot, "and the records add up to the pot");
    }

    /// A router that does not spend everything it was sent (the rest comes back by a forced transfer, which
    /// a kernel cannot refuse): the swap happened, but it moved less than decided. Flag 32.
    function test_swap_that_spends_less_than_it_was_sent_is_flagged() public {
        _curveThenGraduate();
        _nextEpoch();
        _settle(); // latch; a normal swap
        assertFalse(_has(_rec(2).flags, RecordFlags.BUY_FAILED));
        router.setRefundWei(1000);
        (, uint256 rQuote) = _reserves();
        uint256 cap = (rQuote * (25 * 256 + 600 * 192)) / (256 * 4 * 10_000);
        uint256 before = address(kernel).balance;
        uint256 dead0 = token.balanceOf(DEAD);
        _nextEpoch();
        vm.recordLogs();
        _settle();
        Record memory r = _rec(3);
        assertTrue(_has(r.flags, RecordFlags.BUY_FAILED), "flag 32: the buy moved less than decided");
        assertEq(r.nativeIn, cap - 1000, "what was really spent");
        assertEq(before - address(kernel).balance, cap - 1000);
        assertGt(token.balanceOf(DEAD) - dead0, r.buyExecuted, "the swap itself went through");
        assertEq(r.tokensOut, token.balanceOf(DEAD) - dead0);
        // the event says what the record says: what was spent, not what was sent, and what the swap burned
        _assertNativeSwept(vm.getRecordedLogs(), 3, cap - 1000, token.balanceOf(DEAD) - dead0 - r.buyExecuted);
    }

    /// What the kernel sends to the router, argument by argument: the capped amount as value, a minimum
    /// output of 99% of its own quote net of the buy tax, the path [WOKB, token], 0xdEaD as recipient and the
    /// block's time as deadline.
    function test_swap_call_arguments() public {
        _curveThenGraduate();
        _nextEpoch();
        _settle(); // latch; the first swap
        (uint256 rToken, uint256 rQuote) = _reserves();
        uint256 cap = (rQuote * (25 * 256 + 600 * 192)) / (256 * 4 * 10_000);
        assertGt(address(kernel).balance - kernel.totalCredits(NATIVE), cap, "the pot is still above the cap");
        uint256 quote = TradeMath.v2NetOut(cap, rQuote, rToken, 300);
        address[] memory path = new address[](2);
        path[0] = address(wokb);
        path[1] = address(token);
        _nextEpoch();
        vm.expectCall(
            address(router),
            cap,
            abi.encodeCall(
                MockRouter.swapExactETHForTokensSupportingFeeOnTransferTokens,
                ((quote * 9900) / 10_000, path, DEAD, block.timestamp)
            ),
            1
        );
        _settle();
        assertEq(_rec(3).nativeIn, cap);
    }

    /// The minimum output binds. A token that takes more buy tax than the Manager reports delivers less than
    /// 99% of the kernel's quote: the router refuses, nothing is spent, the failed swap is flag 32 and the pot
    /// waits. Within the one percent of slack the swap still fills.
    function test_swap_that_would_deliver_less_than_the_minimum_is_refused() public {
        _curveThenGraduate();
        _nextEpoch();
        _settle(); // latch; a normal swap
        assertFalse(_has(_rec(2).flags, RecordFlags.BUY_FAILED));

        uint256 snap = vm.snapshotState();
        vm.prank(address(manager));
        token.initTaxConfig(address(vault), 500, 300); // the token takes 5% on a buy; the Manager says 3%
        uint256 dead0 = token.balanceOf(DEAD);
        uint256 native0 = address(kernel).balance + address(vault).balance;
        _nextEpoch();
        _settle();
        Record memory r = _rec(3);
        assertTrue(_has(r.flags, RecordFlags.BUY_FAILED), "flag 32: the router refused the swap");
        assertEq(r.nativeIn, 0, "nothing was spent");
        assertEq(address(kernel).balance + address(vault).balance, native0, "the pot waits");
        assertEq(token.balanceOf(DEAD) - dead0, r.buyExecuted, "only the burn leg reached 0xdEaD");
        assertEq(r.tokensOut, r.buyExecuted);

        vm.revertToState(snap);
        vm.prank(address(manager));
        token.initTaxConfig(address(vault), 390, 300); // 3.9%: 96.1% of the gross output, above 99% of 97%
        _nextEpoch();
        _settle();
        r = _rec(3);
        assertFalse(_has(r.flags, RecordFlags.BUY_FAILED), "inside the slack the swap fills");
        assertGt(r.nativeIn, 0);
        assertGt(r.tokensOut, r.buyExecuted);
    }

    /// The pair's lock is recognised by decoding Error(string) from the swap's revert data: selector, offset,
    /// length and the 17 bytes of "UniswapV2: LOCKED". What follows the string is padding and may be anything.
    function test_swap_revert_data_is_decoded_as_a_string() public {
        _curveThenGraduate();
        _nextEpoch();
        bytes memory locked = abi.encodeWithSignature("Error(string)", "UniswapV2: LOCKED");
        assertEq(locked.length, 100);

        // exactly what Solidity encodes, and what the live pair returns (the fork suite prints it)
        _expectLockHeld(locked);
        // the same string with dirty padding after it (old compilers do not clean it)
        bytes memory dirty = bytes.concat(locked);
        for (uint256 i = 85; i < 100; i++) {
            dirty[i] = 0xee;
        }
        _expectLockHeld(dirty);
        // trailing bytes after a complete encoding change nothing
        _expectLockHeld(bytes.concat(locked, hex"deadbeef"));

        // anything shorter than a whole encoded Error(string) is not one: one byte short of the last word,
        // cut right after the string's last byte, and one byte short of the string
        _expectFlagged(_head(locked, 99));
        _expectFlagged(_head(locked, 85));
        _expectFlagged(_head(locked, 84));
        // another string of the same length
        _expectFlagged(abi.encodeWithSignature("Error(string)", "UniswapV2: LOCKEX"));
        _expectFlagged(abi.encodeWithSignature("Error(string)", "uniswapV2: LOCKED"));
        // the same bytes followed by more: a longer string
        _expectFlagged(abi.encodeWithSignature("Error(string)", "UniswapV2: LOCKED!"));
        // a prefix of it
        _expectFlagged(abi.encodeWithSignature("Error(string)", "UniswapV2: LOCKE"));
        // the other strings Uniswap V2 reverts with
        _expectFlagged(abi.encodeWithSignature("Error(string)", "UniswapV2: K"));
        _expectFlagged(abi.encodeWithSignature("Error(string)", "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"));
        _expectFlagged(abi.encodeWithSignature("Error(string)", "TransferHelper: ETH_TRANSFER_FAILED"));
        // the right string under another selector (Panic(uint256) has the selector 0x4e487b71)
        bytes memory wrongSelector = bytes.concat(locked);
        wrongSelector[0] = 0x4e;
        _expectFlagged(wrongSelector);
        wrongSelector = bytes.concat(locked);
        wrongSelector[3] = 0xa1;
        _expectFlagged(wrongSelector);
        // the right bytes with a length word that is not 17, or an offset that is not 32
        bytes memory wrongLength = bytes.concat(locked);
        wrongLength[67] = 0x12;
        _expectFlagged(wrongLength);
        wrongLength[67] = 0x11;
        wrongLength[36] = 0x01; // 17 + 2^248
        _expectFlagged(wrongLength);
        bytes memory wrongOffset = bytes.concat(locked);
        wrongOffset[35] = 0x40;
        _expectFlagged(wrongOffset);
        wrongOffset[35] = 0x20;
        wrongOffset[4] = 0x01; // 32 + 2^248
        _expectFlagged(wrongOffset);
        // the Manager's lock error means nothing here
        _expectFlagged(hex"3ee5aeb5");
        // no revert data at all
        _expectFlagged("");
    }

    /// The pair is asked about its lock only after a swap has failed: a settle whose swap goes through makes
    /// no call to sync() at all.
    function test_pair_lock_probe_is_made_only_after_a_failed_swap() public {
        _curveThenGraduate();
        _nextEpoch();
        assertEq(_syncCallsInSettle(), 0, "no probe when the swap succeeds");
        assertGt(_rec(2).nativeIn, 0);
        router.setMode(1);
        _nextEpoch();
        assertEq(_syncCallsInSettle(), 1, "one probe after the failed swap");
        assertTrue(_has(_rec(3).flags, RecordFlags.BUY_FAILED));
        // and none when there is no swap to make at all
        Envelope memory e = _env();
        e.buyEnabled = false;
        e.sink = sinkAddr;
        Built memory b = _build(ChipModel.fixedChip(8, W), 2200, e, 300, bytes32("noswap"));
        kernel = b.kernel;
        token = b.token;
        vault = b.vault;
        pair = _graduate();
        _nextEpoch();
        assertEq(_syncCallsInSettle(), 0);
    }

    /// @dev One settle; the number of calls it made to the pair's sync().
    function _syncCallsInSettle() internal returns (uint256 calls) {
        vm.startStateDiffRecording();
        _settle();
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        for (uint256 i = 0; i < acc.length; i++) {
            if (
                acc[i].account == address(pair) && acc[i].data.length >= 4
                    && bytes4(acc[i].data) == MockPair.sync.selector
            ) {
                calls++;
            }
        }
    }

    /// A failed swap is followed by one question to the pair: is your lock held? It is asked by a static call
    /// to sync(), and only a REVERT carrying "UniswapV2: LOCKED" means yes. Outside a pair callback the answer
    /// is always no, whatever a (mock) pair says, and the failed swap stays a flag.
    function test_pair_lock_probe_only_believes_a_revert_with_the_lock_string() public {
        _curveThenGraduate();
        _nextEpoch();
        router.setMode(1); // every swap fails, for every caller
        // 0: sync as in Uniswap V2 (a static call to it fails without data); 1: sync RETURNS the bytes of the
        // lock error instead of reverting with them; 2: sync reverts with another string; 3: sync burns its gas
        for (uint8 mode = 0; mode <= 3; mode++) {
            uint256 snap = vm.snapshotState();
            pair.setSyncMode(mode);
            _settle();
            Record memory r = _rec(2);
            assertTrue(_has(r.flags, RecordFlags.BUY_FAILED), "flag 32");
            assertEq(r.nativeIn, 0);
            vm.revertToState(snap);
        }
    }

    function _head(bytes memory b, uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = b[i];
        }
    }

    /// @dev The settle reverts as a whole with LockHeld and leaves everything as it was.
    function _expectLockHeld(bytes memory revertData) internal {
        uint256 snap = vm.snapshotState();
        router.setRevertData(revertData);
        uint256 inVault = address(vault).balance;
        vm.prank(keeper);
        vm.expectRevert(Kernel.LockHeld.selector);
        kernel.settle();
        assertEq(kernel.count(), 1, "no record");
        assertEq(kernel.lastEpoch(), 1, "the epoch is not consumed");
        assertFalse(kernel.graduated(), "not even the latch is kept");
        assertEq(address(vault).balance, inVault, "the claim was rolled back");
        vm.revertToState(snap);
    }

    /// @dev The settle returns, the failed swap is flag 32 and the pot waits.
    function _expectFlagged(bytes memory revertData) internal {
        uint256 snap = vm.snapshotState();
        router.setRevertData(revertData);
        _settle();
        Record memory r = _rec(2);
        assertTrue(_has(r.flags, RecordFlags.BUY_FAILED), "flag 32");
        assertEq(r.nativeIn, 0);
        assertEq(r.tokensOut, 0);
        assertGt(address(kernel).balance - kernel.totalCredits(NATIVE), 2 ether, "the pot waits");
        vm.revertToState(snap);
    }

    function test_swap_failure_is_flagged_and_pot_stays() public {
        _curveThenGraduate();
        router.setMode(1);
        _nextEpoch();
        _settle();
        Record memory r = _rec(2);
        assertTrue(_has(r.flags, RecordFlags.BUY_FAILED));
        assertEq(r.tokensOut, 0);
        assertEq(r.nativeIn, 0, "nothing was spent");
        uint256 pot = address(kernel).balance - kernel.totalCredits(NATIVE);
        assertGt(pot, 2 ether, "claimed and still here");
        router.setMode(2); // burns all its gas
        _nextEpoch();
        _settle();
        assertTrue(_has(_rec(3).flags, RecordFlags.BUY_FAILED));
        assertEq(address(kernel).balance - kernel.totalCredits(NATIVE), pot);
        router.setMode(0);
        _nextEpoch();
        _settle();
        assertFalse(_has(_rec(4).flags, RecordFlags.BUY_FAILED));
        assertLt(address(kernel).balance - kernel.totalCredits(NATIVE), pot);
    }

    function test_swap_skipped_when_pair_cannot_be_read() public {
        _curveThenGraduate();
        pair.setReservesRevert(true);
        _nextEpoch();
        _settle();
        Record memory r = _rec(2);
        assertTrue(_has(r.flags, RecordFlags.BUY_SKIPPED), "flag 16");
        assertFalse(_has(r.flags, RecordFlags.BUY_FAILED));
        assertEq(r.tokensOut, 0);
        assertEq(r.nativeIn, 0);
    }

    function test_unreadable_manager_after_graduation_shrinks_the_cap_but_does_not_stop_the_exit() public {
        _curveThenGraduate();
        _nextEpoch();
        _settle(); // latch
        manager.setTokensMode(1);
        (uint256 rToken, uint256 rQuote) = _reserves();
        uint256 credits = kernel.totalCredits(NATIVE);
        uint256 before = address(kernel).balance;
        uint256 dead0 = token.balanceOf(DEAD);
        _nextEpoch();
        _settle();
        Record memory r = _rec(3);
        assertTrue(_has(r.flags, RecordFlags.CURVE_READ_FAILED));
        // unknown tax: only the fee part of the cap is used
        uint256 cap = (rQuote * 25) / (4 * 10_000);
        assertEq(before - address(kernel).balance, cap);
        assertEq(r.nativeIn, cap);
        // 0xdEaD received the burn leg's tokens (tax on the kernel's own earlier swap) plus the swap's output
        assertEq(token.balanceOf(DEAD) - dead0, r.buyExecuted + TradeMath.v2NetOut(cap, rQuote, rToken, 300));
        assertEq(r.tokensOut, token.balanceOf(DEAD) - dead0);
        assertEq(kernel.totalCredits(NATIVE), credits);
    }

    /// The latch reads IgnixToken.pair(), not the Manager: an unreadable (or lying) Manager.pairOf changes
    /// nothing about when graduation is seen.
    function test_latch_reads_the_token_and_ignores_the_managers_pairOf() public {
        _curveThenGraduate();
        manager.setPairOfReverts(true);
        _nextEpoch();
        vm.prank(keeper);
        kernel.settle();
        assertTrue(kernel.graduated(), "latched from the token although the Manager cannot be asked");
        assertEq(kernel.pair(), address(pair));
        assertTrue(_has(_rec(2).flags, RecordFlags.GRADUATED));
        assertEq(_in(2).grad, 1);
    }

    /// A failed read of the token's pair neither sets nor clears the latch, and never reverts a settle:
    /// a revert (with data where an address would be), a short answer and a read that burns its gas.
    function test_token_pair_unreadable_keeps_the_curve_regime_without_reverting() public {
        _curveThenGraduate();
        for (uint8 mode = 1; mode <= 3; mode++) {
            uint256 snap = vm.snapshotState();
            token.setPairMode(mode);
            _nextEpoch();
            _settle();
            Record memory r = _rec(2);
            assertFalse(kernel.graduated(), "no latch while the token cannot be read");
            assertEq(kernel.pair(), address(0));
            assertFalse(_has(r.flags, RecordFlags.GRADUATED));
            assertEq(_in(2).grad, 0);
            // the curve is sold out: the buy is shrunk to nothing and skipped; the money waits
            assertEq(r.buyExecuted, 0);
            assertEq(kernel.reserve(), uint256(r.reserveBefore) + r.inflow - r.allow, "still the OKB books");
            token.setPairMode(0);
            _nextEpoch();
            _settle();
            assertTrue(kernel.graduated(), "picked up as soon as the token answers again");
            assertEq(kernel.pair(), address(pair));
            vm.revertToState(snap);
        }
    }

    /// Once latched the token is not asked again: a later failure of pair() cannot clear the latch.
    function test_latch_is_never_cleared() public {
        _curveThenGraduate();
        _nextEpoch();
        _settle();
        assertTrue(kernel.graduated());
        for (uint8 mode = 1; mode <= 3; mode++) {
            token.setPairMode(mode);
            _nextEpoch();
            _settle();
            assertTrue(kernel.graduated());
            assertEq(kernel.pair(), address(pair));
            assertTrue(_has(_rec(kernel.count()).flags, RecordFlags.GRADUATED));
        }
    }

    /// The attacker buys on the pair, lets the kernel buy at its cap, and sells, all in one block.
    function testFuzz_v2_sandwich_of_the_native_leg_is_unprofitable(uint256 size) public {
        size = bound(size, 0.01 ether, 200 ether);
        _curveThenGraduate();
        _nextEpoch();
        _settle(); // latch
        _nextEpoch();
        uint256 before = bob.balance;
        _v2Buy(bob, size);
        _settle();
        assertGt(_rec(3).tokensOut, 0, "the kernel bought");
        _v2Sell(bob, token.balanceOf(bob));
        assertLt(bob.balance, before, "the round trip costs more than the kernel's buy moved the price");
    }

    // ------------------------------------------------------------------ locked tokens

    function test_burnLocked_only_after_graduation() public {
        _buy(alice, 10 ether);
        _nextEpoch();
        _settle();
        assertGt(kernel.lockedTokens(), 0);
        vm.expectRevert(Kernel.NotGraduated.selector);
        kernel.burnLocked();
        // and the tokens cannot move by any other route: the token itself refuses
        vm.prank(address(kernel));
        vm.expectRevert();
        token.transfer(DEAD, 1);
    }

    function test_burnLocked_sends_curve_tokens_to_dead_and_keeps_LOCK() public {
        _curveThenGraduate();
        _nextEpoch();
        _settle();
        uint256 locked = kernel.lockedTokens();
        uint256 burned = kernel.burnedTokens();
        uint256 dead0 = token.balanceOf(DEAD);
        uint256 lockCode = _in(2).lock;

        vm.expectEmit(false, false, false, true, address(kernel));
        emit Kernel.LockedBurned(locked);
        vm.prank(bob); // anyone
        assertEq(kernel.burnLocked(), locked);
        assertEq(kernel.lockedTokens(), 0);
        assertEq(kernel.burnedTokens(), burned + locked);
        assertEq(token.balanceOf(DEAD) - dead0, locked);
        assertEq(kernel.burnLocked(), 0, "nothing left");

        // LOCK counts locked plus burned, so it did not move
        _nextEpoch();
        _settle();
        assertGe(_in(3).lock, lockCode);
        assertEq(
            token.balanceOf(address(kernel)),
            kernel.totalCredits(address(token)) + kernel.reserve(),
            "token balance = credits + reserve"
        );
    }

    function test_burnLocked_failure_reverts_and_changes_nothing() public {
        _curveThenGraduate();
        _nextEpoch();
        _settle();
        uint256 locked = kernel.lockedTokens();
        token.setFailure(false, false, false, DEAD);
        vm.expectRevert(Kernel.PayFailed.selector);
        kernel.burnLocked();
        assertEq(kernel.lockedTokens(), locked);
        // settle is unaffected by a blocked burn route
        _nextEpoch();
        _settle();
        assertEq(kernel.count(), 3);
    }

    // ------------------------------------------------------------------ buys disabled

    function test_buy_disabled_after_graduation_credits_sink_in_both_assets() public {
        Envelope memory e = _env();
        e.buyEnabled = false;
        e.sink = sinkAddr;
        Built memory b = _build(ChipModel.fixedChip(8, W), 2200, e, 300, bytes32("nobuy"));
        kernel = b.kernel;
        token = b.token;
        vault = b.vault;
        _buy(alice, 10 ether);
        _nextEpoch();
        _settle();
        assertEq(kernel.lockedTokens(), 0);
        uint256 curveReserve = kernel.reserve();
        pair = _graduate();
        _v2Buy(alice, 2 ether);
        uint256 taxTokens = token.balanceOf(address(vault));
        uint256 nativeInVault = address(vault).balance;
        uint256 sinkNative = kernel.creditOf(sinkAddr, NATIVE);
        _nextEpoch();
        _settle();
        Record memory r = _rec(2);
        assertEq(kernel.creditOf(sinkAddr, address(token)), taxTokens / 2, "token buy share goes to the sink");
        assertEq(r.buyExecuted, taxTokens / 2);
        assertEq(r.tokensOut, 0);
        assertEq(token.balanceOf(DEAD), 0, "nothing is burned and nothing is bought");
        assertEq(
            kernel.creditOf(sinkAddr, NATIVE),
            sinkNative + curveReserve + nativeInVault,
            "the native pot goes to the sink"
        );
        assertEq(address(kernel).balance, kernel.totalCredits(NATIVE), "every native wei is owed to someone");
        assertEq(r.flags, RecordFlags.GRADUATED);
    }

    // ------------------------------------------------------------------ token credits

    /// With no allowance after graduation, the only credit that can ever exist in the project token is the
    /// sink's, on a kernel whose buys are disabled. It is withdrawable like any other credit.
    function test_token_credit_exists_only_for_the_sink_and_is_withdrawable() public {
        Envelope memory e = _env();
        e.buyEnabled = false;
        e.sink = sinkAddr;
        Built memory b = _build(ChipModel.fixedChip(8, W), 2200, e, 300, bytes32("sinktok"));
        kernel = b.kernel;
        token = b.token;
        vault = b.vault;
        pair = _graduate();
        _v2Buy(alice, 2 ether);
        uint256 taxTokens = token.balanceOf(address(vault));
        _nextEpoch();
        _settle();
        uint256 credit = kernel.creditOf(sinkAddr, address(token));
        assertEq(credit, taxTokens / 2, "the buy share, credited instead of burned");
        assertEq(kernel.creditOf(payee, address(token)), 0, "nothing for the allowance payee");
        assertEq(kernel.totalCredits(address(token)), credit);
        assertEq(kernel.withdrawCredit(payee, address(token)), 0);
        vm.prank(bob);
        assertEq(kernel.withdrawCredit(sinkAddr, address(token)), credit);
        assertEq(token.balanceOf(sinkAddr), credit);
        assertEq(kernel.creditOf(sinkAddr, address(token)), 0);
        assertEq(kernel.totalCredits(address(token)), 0);
        assertEq(token.balanceOf(address(kernel)), kernel.reserve(), "what is left is the token reserve");
    }

    /// Many graduated settles of a chip that asks for the largest allowance it can: the payee's token credit
    /// stays zero, and so does the regime's allowance total.
    function test_no_token_allowance_ever_accrues() public {
        Envelope memory e = _env();
        e.capT = 128;
        e.allowCumBps = 5000;
        e.fbAllow = 128;
        Built memory b = _build(ChipModel.fixedChip(8, _word(0, 0, 256, 0, 0, 1023)), 2200, e, 300, bytes32("glutton"));
        kernel = b.kernel;
        token = b.token;
        vault = b.vault;
        _buy(alice, 10 ether);
        _nextEpoch();
        _settle();
        assertEq(_rec(1).allow, 0.15 ether, "on the curve the allowance is paid: half of 0.3 OKB");
        assertEq(_rec(1).clampBits, KernelMath.K2);
        uint256 nativeCredit = kernel.creditOf(payee, NATIVE);
        pair = _graduate();
        for (uint256 i = 0; i < 6; i++) {
            _v2Buy(alice, 1 ether);
            if (i == 3) _killBoth(1); // from here on the fallback word, which also asks for 128/256
            vm.warp(block.timestamp + (i == 3 ? 4 : 1) * EPOCH);
            _settle();
            Record memory r = _rec(kernel.count());
            assertTrue(_has(r.flags, RecordFlags.GRADUATED));
            assertEq(_has(r.flags, RecordFlags.FALLBACK), i >= 3);
            assertGt(r.inflow, 0);
            assertEq(r.allow, 0, "no allowance after graduation, from the chip or from the fallback word");
            assertEq(r.clampBits & (KernelMath.K2 | KernelMath.K2C | KernelMath.K2L), 0, "and no allowance clamp");
            if (i >= 3) assertEq(r.buyDecided, uint256(r.inflow) / 2 + uint256(r.reserveBefore) / 2, "fallback word");
        }
        assertEq(kernel.creditOf(payee, address(token)), 0);
        assertEq(kernel.totalCredits(address(token)), 0);
        assertEq(kernel.allowPaidCum(), 0);
        assertEq(kernel.creditOf(payee, NATIVE), nativeCredit, "the OKB credit made on the curve is still there");
        assertEq(kernel.withdrawCredit(payee, NATIVE), nativeCredit);
    }
}
