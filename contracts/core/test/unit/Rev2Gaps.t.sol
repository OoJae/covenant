// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "../Base.t.sol";
import {Kernel} from "../../src/Kernel.sol";
import {KernelFactory} from "../../src/KernelFactory.sol";
import {Globals} from "../../src/interfaces/IKernelExt.sol";
import {Record, Envelope, RecordFlags, IKernelMin} from "../../src/interfaces/IKernelV1.sol";
import {IIgnixManager} from "../../src/interfaces/IIgnix.sol";
import {ChipModel} from "../mocks/MockTapeOut.sol";
import {MockPair, MockManager, MockWOKB} from "../mocks/MockIgnix.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Holds the IgnixManager's reentrancy lock while it settles a kernel. It sells ZERO tokens of any live
///      token: the Manager pays the (zero) proceeds to the seller by a native call, with its lock held, and
///      this contract calls kernel.settle() from its receive(). It needs no tokens, no approval and no money.
contract ManagerLockHolder {
    MockManager internal manager;
    Kernel internal kernel;
    uint256 public attempts;
    bool public settled;
    bytes public settleRevert;

    constructor(MockManager m, Kernel k) {
        manager = m;
        kernel = k;
    }

    function sellZeroAndSettleInside(address anyLiveToken) external {
        manager.sell(anyLiveToken, 0, 0);
    }

    receive() external payable {
        attempts++;
        (settled, settleRevert) = address(kernel).call(abi.encodeCall(IKernelMin.settle, ()));
    }
}

/// @dev A flash swap on the Uniswap V2 pair: borrows WOKB, calls kernel.settle() from uniswapV2Call (the
///      pair's lock is held), and repays the loan with its 0.3% fee.
contract FlashSwapper {
    MockWOKB internal wokb;
    Kernel internal kernel;
    uint256 public attempts;
    bool public settled;
    bytes public settleRevert;

    constructor(MockWOKB w, Kernel k) {
        wokb = w;
        kernel = k;
    }

    function flashAndSettleInside(MockPair pair, uint256 wokbOut) external payable {
        wokb.deposit{value: msg.value}(); // for the fee
        bool wokbIs0 = pair.token0() == address(wokb);
        pair.swap(wokbIs0 ? wokbOut : 0, wokbIs0 ? 0 : wokbOut, address(this), hex"01");
    }

    function uniswapV2Call(address, uint256 amount0, uint256 amount1, bytes calldata) external {
        attempts++;
        (settled, settleRevert) = address(kernel).call(abi.encodeCall(IKernelMin.settle, ()));
        uint256 borrowed = amount0 + amount1;
        wokb.transfer(msg.sender, borrowed + (borrowed * 3) / 997 + 1);
    }
}

/// @dev The same two lock holders with a gas limit on the settle they make.
contract GasLimitedLockHolder {
    MockManager internal manager;
    Kernel internal kernel;
    uint256 internal gasLimit;
    bool public settled;
    bytes public settleRevert;

    constructor(MockManager m, Kernel k) {
        manager = m;
        kernel = k;
    }

    function sellZeroAndSettleInside(address anyLiveToken, uint256 gasLimit_) external {
        gasLimit = gasLimit_;
        manager.sell(anyLiveToken, 0, 0);
    }

    receive() external payable {
        (settled, settleRevert) = address(kernel).call{gas: gasLimit}(abi.encodeCall(IKernelMin.settle, ()));
    }
}

contract GasLimitedFlashSwapper {
    MockWOKB internal wokb;
    Kernel internal kernel;
    uint256 internal gasLimit;
    bool public settled;
    bytes public settleRevert;

    constructor(MockWOKB w, Kernel k) {
        wokb = w;
        kernel = k;
    }

    function flashAndSettleInside(MockPair pair, uint256 wokbOut, uint256 gasLimit_) external payable {
        gasLimit = gasLimit_;
        wokb.deposit{value: msg.value}();
        bool wokbIs0 = pair.token0() == address(wokb);
        pair.swap(wokbIs0 ? wokbOut : 0, wokbIs0 ? 0 : wokbOut, address(this), hex"01");
    }

    function uniswapV2Call(address, uint256 amount0, uint256 amount1, bytes calldata) external {
        (settled, settleRevert) = address(kernel).call{gas: gasLimit}(abi.encodeCall(IKernelMin.settle, ()));
        uint256 borrowed = amount0 + amount1;
        wokb.transfer(msg.sender, borrowed + (borrowed * 3) / 997 + 1);
    }
}

/// @notice What chips/INTERFACE.md revision 2 changed (its section 14), item by item, on the mock world.
///         Each test was a test of the revision-1 behaviour before the kernel was brought up to revision 2;
///         the two reentrancy-lock attacks of section 8.6 are reproduced here and again on the fork.
contract Rev2GapsTest is Base {
    bytes14 internal W = _word(128, 64, 48, 16, 0, 1023);

    function setUp() public override {
        super.setUp();
        _fixture(W);
    }

    /// @dev Everything a settle writes or moves.
    function _digest() internal view returns (bytes32) {
        uint32 n = kernel.count();
        (uint128 cum, uint128 paid) = kernel.cums(n);
        bytes32 a = keccak256(abi.encode(n, kernel.records(n), cum, paid, kernel.state(), kernel.reserve()));
        bytes32 b = keccak256(
            abi.encode(
                kernel.lockedTokens(),
                kernel.burnedTokens(),
                kernel.graduated(),
                kernel.lastEpoch(),
                kernel.lastStepEpoch(),
                address(kernel).balance,
                token.balanceOf(address(kernel)),
                address(vault).balance,
                token.balanceOf(address(vault))
            )
        );
        bytes32 c = keccak256(
            abi.encode(
                token.balanceOf(DEAD),
                kernel.creditOf(payee, NATIVE),
                kernel.creditOf(payee, address(token)),
                kernel.totalCredits(NATIVE),
                kernel.totalCredits(address(token))
            )
        );
        return keccak256(abi.encode(a, b, c));
    }

    // ------------------------------------------------------------------ 8.2, 9.3: no allowance after graduation

    /// Revision 2, sections 8.2 and 9.3: no allowance after graduation. The T_ALLOW share of token inflow
    /// stays in the reserve; the payee is never credited in project tokens; no clamp bit says so.
    function test_rev2_8_2_no_allowance_after_graduation() public {
        _buy(alice, 10 ether);
        _nextEpoch();
        _settle();
        assertEq(_rec(1).allow, (0.3 ether * 48) / 256, "on the curve the allowance is paid, in OKB");
        _graduate();
        _v2Buy(alice, 2 ether);
        uint256 taxTokens = token.balanceOf(address(vault));
        assertGt((taxTokens * 48) / 256, 0, "the chip asks for an allowance out of this inflow");
        _nextEpoch();
        _settle();
        Record memory r = _rec(2);
        assertEq(r.inflow, taxTokens);
        assertEq(r.allow, 0, "none is paid");
        assertEq(r.clampBits, 0, "and no clamp is recorded: K2, K2C and K2L are not evaluated");
        assertEq(kernel.creditOf(payee, address(token)), 0);
        assertEq(kernel.totalCredits(address(token)), 0);
        assertEq(r.buyDecided, (taxTokens * 128) / 256, "the buy share is unchanged");
        assertEq(kernel.reserve(), taxTokens - r.buyExecuted, "the allowance share joined the reserve");
        assertEq(kernel.allowPaidCum(), 0);
        // the OKB allowance credit made on the curve stays withdrawable
        uint256 credit = kernel.creditOf(payee, NATIVE);
        assertEq(credit, _rec(1).allow);
        assertEq(kernel.withdrawCredit(payee, NATIVE), credit);
    }

    /// The fallback word after graduation pays no allowance either.
    function test_rev2_8_2_fallback_word_pays_no_allowance_after_graduation() public {
        _graduate();
        _nextEpoch();
        _settle(); // latch
        _v2Buy(alice, 2 ether);
        _killBoth(1);
        vm.warp(block.timestamp + 4 * EPOCH);
        _settle();
        Record memory r = _rec(2);
        assertTrue(_has(r.flags, RecordFlags.FALLBACK));
        assertEq(r.outputs, _word(224, 0, 32, 0, 128, 1023), "the fallback word asks for 32/256");
        assertGt(r.inflow, 0);
        assertEq(r.allow, 0);
        assertEq(r.clampBits, 0);
        assertEq(r.buyDecided, (uint256(r.inflow) * 224) / 256 + (uint256(r.reserveBefore) * 128) / 256);
        assertEq(kernel.creditOf(payee, address(token)), 0);
    }

    // ------------------------------------------------------------------ 7: envelope limits

    /// Revision 2, section 7: the factory refuses every envelope outside the tightened limits, and with it
    /// what the limits guarantee: never more than half of the inflow as allowance, a floor that applies to
    /// every reserve worth more than dust, a reserve that drains.
    function test_rev2_7_factory_rejects_envelopes_outside_the_revision_2_limits() public {
        vm.prank(launcher);
        uint256 id = fab.tapeoutChip(ChipModel.fixedChip(8, W), 200);
        Envelope memory e;

        e = _env();
        e.capT = 256; // capT <= 128
        _expectBadEnvelope(e, id, 4);
        e = _env();
        e.allowCumBps = 9999; // allowCumBps <= 5000
        _expectBadEnvelope(e, id, 6);
        e = _env();
        e.epochLen = 2 days; // epochLen <= 86400
        e.fallbackEpochs = 2;
        _expectBadEnvelope(e, id, 2);
        e = _env();
        e.floorMin = 0; // floorMin >= 1
        _expectBadEnvelope(e, id, 10);
        e = _env();
        e.epochLen = 86_400;
        e.floorRel = 1; // epochLen * 178 <= 2592000 * floorRel
        e.fallbackEpochs = 2;
        _expectBadEnvelope(e, id, 15);

        // the reference envelope (chips/rtl/fg_params.json) and the loosest one the limits allow both pass
        e = _env();
        e.capT = 48;
        e.capV = 0;
        e.allowCumBps = 1875;
        e.ceilMax = 440;
        e.floorMin = 1;
        e.fallbackEpochs = 16;
        e.fbAllow = 8;
        factory.create(e, id, "reference");
        e = _env();
        e.capT = 128;
        e.allowCumBps = 5000;
        e.fbAllow = 128;
        e.relMax = 256;
        e.floorRel = 1;
        e.floorMin = 1;
        factory.create(e, id, "loosest");
    }

    function _expectBadEnvelope(Envelope memory e, uint256 id, uint8 which) internal {
        vm.expectRevert(abi.encodeWithSelector(KernelFactory.BadEnvelope.selector, which));
        factory.create(e, id, bytes32("x"));
    }

    // ------------------------------------------------------------------ 2: step gas

    /// Revision 2, section 2: the step gas covers every chip shape, latch-heavy ones included, and each
    /// evaluator has its own amount, both fixed at creation.
    function test_rev2_2_step_gas_counts_latches_and_each_evaluator_has_its_own() public {
        vm.prank(launcher);
        uint256 id = fab.tapeoutChip(ChipModel.fixedChip(256, W), 256); // 256 latches and nothing else
        Kernel k = Kernel(payable(factory.create(_env(), id, "latches")));
        Globals memory g = k.globals();
        assertEq(g.stepFloor, 200_000 + 2_600 * 256 + 800 * 256, "TapeOut: 200,000 + 2,600 per gate + 800 per latch");
        assertEq(g.sealedFloor, 40_000 + 200 * 0 + 400 * 256, "sealed: 40,000 + 200 per NAND + 400 per latch");
        // what the two evaluators need at most for a chip of this shape (INTERFACE section 2)
        assertGt(g.stepFloor, 101_730 + 3_059 * 256);
        assertGt(g.sealedFloor, 20_000 + 280 * 256);
        // revision 1 gave both evaluators 60,000 + 2,600 per gate: 725,600, less than TapeOut's step needs here
        assertLt(uint256(60_000 + 2_600 * 256), 101_730 + 3_059 * 256);
    }

    // ------------------------------------------------------------------ 8.6: the Manager's lock

    /// Revision 2, section 8.6, the attack: a caller holds the IgnixManager's reentrancy lock (a zero-token
    /// sell is enough) and settles from inside. The kernel's buyTo then fails with
    /// ReentrancyGuardReentrantCall(), a failure no other caller would see. Revision 1 recorded it as a
    /// failed buy and consumed the epoch; revision 2 reverts the whole settle.
    function test_rev2_8_6_settle_from_inside_a_manager_call_reverts_and_keeps_the_epoch() public {
        ManagerLockHolder h = new ManagerLockHolder(manager, kernel);
        _buy(alice, 5 ether);
        _nextEpoch();
        assertEq(address(h).balance, 0, "the attacker needs no money");
        assertEq(token.balanceOf(address(h)), 0, "and no tokens");
        bytes32 before = _digest();
        uint256 inVault = address(vault).balance;
        assertEq(inVault, 0.15 ether);

        h.sellZeroAndSettleInside(address(token)); // the attacker's own transaction goes through
        assertEq(h.attempts(), 1, "the Manager did call back with its lock held");
        assertFalse(h.settled(), "the settle made from inside the Manager reverted");
        assertEq(bytes4(h.settleRevert()), Kernel.LockHeld.selector);
        assertEq(h.settleRevert().length, 4);
        assertEq(_digest(), before, "nothing was written and nothing moved");
        assertEq(kernel.count(), 0, "no record");
        assertEq(kernel.lastEpoch(), 0, "the epoch is not consumed");
        assertEq(address(vault).balance, inVault, "the tax is still in the vault: the claim was rolled back");

        // the same settle outside the callback, in the same block, succeeds and buys
        _settle();
        Record memory r = _rec(1);
        assertEq(r.epoch, 1);
        assertEq(r.inflow, 0.15 ether);
        assertEq(r.buyDecided, 0.075 ether);
        assertEq(r.buyExecuted, 0.075 ether, "bought");
        assertGt(r.tokensOut, 0);
        assertEq(r.flags, 0, "no flag: nothing failed");
        assertEq(kernel.lockedTokens(), r.tokensOut);
    }

    /// The lock is the Manager's, not the token's: a zero-token sell of ANY live token holds it.
    function test_rev2_8_6_the_lock_can_be_held_through_any_live_token() public {
        (address other,) = manager.createToken(bob, bob, 100, 100, 0, 0, GRADUATION); // somebody else's token
        ManagerLockHolder h = new ManagerLockHolder(manager, kernel);
        _buy(alice, 5 ether);
        _nextEpoch();
        h.sellZeroAndSettleInside(other);
        assertEq(h.attempts(), 1);
        assertFalse(h.settled());
        assertEq(bytes4(h.settleRevert()), Kernel.LockHeld.selector);
        assertEq(kernel.count(), 0);
        _settle();
        assertGt(_rec(1).buyExecuted, 0);
    }

    /// A caught failure must be one every caller would see, and so must a success: when the settle makes no
    /// buy call (nothing decided, a guard skips the buy, or buys are disabled), holding the Manager's lock
    /// changes nothing, and the record is the one any other caller gets.
    function test_rev2_8_6_under_the_managers_lock_a_settle_without_a_buy_call_is_unchanged() public {
        // (a) nothing to buy: an empty vault
        _sameInsideAndOutsideTheManager();
        // (b) the buy is skipped by a guard before the call: an open founder round
        _buy(alice, 5 ether);
        manager.setFounderRound(address(token), uint64(block.timestamp + 100 * EPOCH));
        Record memory r = _sameInsideAndOutsideTheManager();
        assertGt(r.buyDecided, 0);
        assertTrue(_has(r.flags, RecordFlags.BUY_SKIPPED));
        manager.setFounderRound(address(token), 0);
        // (c) the curve cannot be read: skipped as well
        manager.setTokensMode(1);
        r = _sameInsideAndOutsideTheManager();
        assertTrue(_has(r.flags, RecordFlags.CURVE_READ_FAILED) && _has(r.flags, RecordFlags.BUY_SKIPPED));
        manager.setTokensMode(0);
        // (d) with a buy to make, the two differ: outside it buys, inside it reverts
        ManagerLockHolder h = new ManagerLockHolder(manager, kernel);
        _nextEpoch();
        h.sellZeroAndSettleInside(address(token));
        assertFalse(h.settled());
        assertEq(bytes4(h.settleRevert()), Kernel.LockHeld.selector);
    }

    /// @dev One epoch later: the settle as the keeper sends it, and the same settle from inside a Manager
    ///      call, from the same state. Both must return and write the same thing.
    function _sameInsideAndOutsideTheManager() internal returns (Record memory r) {
        ManagerLockHolder h = new ManagerLockHolder(manager, kernel);
        _nextEpoch();
        uint256 snap = vm.snapshotState();
        _settle();
        bytes32 outside = _digest();
        vm.revertToState(snap);
        h.sellZeroAndSettleInside(address(token));
        assertEq(h.attempts(), 1);
        assertTrue(h.settled(), "no buy call, so the lock does not matter");
        assertEq(_digest(), outside, "the same record for every caller");
        r = _rec(kernel.count());
    }

    /// With buys disabled the kernel never calls the Manager's buyTo, so its lock never matters.
    function test_rev2_8_6_under_the_managers_lock_a_kernel_with_buys_disabled_is_unchanged() public {
        Envelope memory e = _env();
        e.buyEnabled = false;
        e.sink = sinkAddr;
        Built memory b = _build(ChipModel.fixedChip(8, W), 2200, e, 300, bytes32("nobuy"));
        kernel = b.kernel;
        token = b.token;
        vault = b.vault;
        _buy(alice, 5 ether);
        Record memory r = _sameInsideAndOutsideTheManager();
        assertEq(r.buyExecuted, 0.075 ether, "credited to the sink");
        assertEq(kernel.creditOf(sinkAddr, NATIVE), 0.075 ether);
    }

    /// After graduation the kernel makes no Manager buy, so the Manager's lock does not matter there either.
    function test_rev2_8_6_the_managers_lock_does_not_matter_after_graduation() public {
        (address other,) = manager.createToken(bob, bob, 100, 100, 0, 0, GRADUATION); // a token still on its curve
        _buy(alice, 10 ether);
        _nextEpoch();
        _settle();
        _graduate();
        _v2Buy(alice, 2 ether);
        ManagerLockHolder h = new ManagerLockHolder(manager, kernel);
        _nextEpoch();
        uint256 snap = vm.snapshotState();
        _settle();
        bytes32 outside = _digest();
        assertGt(_rec(2).nativeIn, 0, "the settle swaps");
        vm.revertToState(snap);
        h.sellZeroAndSettleInside(other);
        assertEq(h.attempts(), 1);
        assertTrue(h.settled());
        assertEq(_digest(), outside);
    }

    /// Only the Manager's lock error reverts the settle. It is recognised by its selector, the first four
    /// bytes of the revert data; every other failure of buyTo stays a flag, as before.
    function test_rev2_8_6_only_the_lock_error_reverts_the_settle() public {
        assertEq(IIgnixManager.ReentrancyGuardReentrantCall.selector, bytes4(0x3ee5aeb5));
        assertEq(MockManager.ReentrancyGuardReentrantCall.selector, bytes4(0x3ee5aeb5));
        _buy(alice, 5 ether);
        _nextEpoch();

        manager.setBuyRevertData(hex"3ee5aeb5");
        vm.prank(keeper);
        vm.expectRevert(Kernel.LockHeld.selector);
        kernel.settle();
        assertEq(kernel.count(), 0);
        // like the Manager's other errors it is matched by selector: bytes after the four change nothing
        manager.setBuyRevertData(abi.encodePacked(bytes4(0x3ee5aeb5), uint256(1)));
        vm.prank(keeper);
        vm.expectRevert(Kernel.LockHeld.selector);
        kernel.settle();
        assertEq(kernel.count(), 0);

        // near misses and the other errors of the Manager: flag 32 (or 16 for a guard), and the settle returns
        _expectBuyFlag(hex"3ee5aeb4", RecordFlags.BUY_FAILED);
        _expectBuyFlag(hex"3fe5aeb5", RecordFlags.BUY_FAILED);
        _expectBuyFlag(hex"3ee5ae", RecordFlags.BUY_FAILED); // three bytes: not a selector
        _expectBuyFlag("", RecordFlags.BUY_FAILED);
        _expectBuyFlag(
            abi.encodeWithSignature("Error(string)", "ReentrancyGuardReentrantCall()"), RecordFlags.BUY_FAILED
        );
        _expectBuyFlag(abi.encodeWithSignature("Error(string)", "UniswapV2: LOCKED"), RecordFlags.BUY_FAILED);
        _expectBuyFlag(abi.encodeWithSelector(MockManager.Slippage.selector), RecordFlags.BUY_FAILED);
        _expectBuyFlag(abi.encodeWithSelector(MockManager.TransferFailed.selector), RecordFlags.BUY_FAILED);
        _expectBuyFlag(abi.encodeWithSelector(MockManager.Graduated_.selector), RecordFlags.BUY_FAILED);
        _expectBuyFlag(abi.encodeWithSelector(MockManager.FounderOnly.selector), RecordFlags.BUY_SKIPPED);
        _expectBuyFlag(abi.encodeWithSelector(MockManager.Paused.selector), RecordFlags.BUY_SKIPPED);
    }

    function _expectBuyFlag(bytes memory revertData, uint8 flag) internal {
        uint256 snap = vm.snapshotState();
        manager.setBuyRevertData(revertData);
        _settle();
        Record memory r = _rec(1);
        assertEq(r.flags, flag, "one flag, and the settle returned");
        assertEq(r.buyExecuted, 0);
        assertEq(kernel.reserve(), uint256(r.inflow) - r.allow, "the amount waits in the reserve");
        vm.revertToState(snap);
    }

    // ------------------------------------------------------------------ 8.6: the pair's lock

    /// The same attack after graduation: a flash swap on the pair calls settle() from uniswapV2Call, with the
    /// pair's lock held. The kernel's router buy then fails with "UniswapV2: LOCKED". Revision 1 recorded a
    /// failed buy and consumed the epoch; revision 2 reverts the whole settle.
    function test_rev2_8_6_settle_from_inside_a_flash_swap_reverts_and_keeps_the_epoch() public {
        _buy(alice, 10 ether);
        _nextEpoch();
        _settle();
        MockPair pair = _graduate();
        _v2Buy(alice, 2 ether); // token tax in the vault: the settle has a burn to make as well
        _nextEpoch();
        FlashSwapper f = new FlashSwapper(wokb, kernel);
        bytes32 before = _digest();
        uint256 nativeInVault = address(vault).balance;
        uint256 tokensInVault = token.balanceOf(address(vault));
        assertGt(nativeInVault, 2 ether);
        assertGt(tokensInVault, 0);

        f.flashAndSettleInside{value: 1 ether}(pair, 10 ether); // the flash swap itself completes
        assertEq(f.attempts(), 1, "the pair did call back with its lock held");
        assertFalse(f.settled(), "the settle made from inside the pair reverted");
        assertEq(bytes4(f.settleRevert()), Kernel.LockHeld.selector);
        assertEq(_digest(), before, "nothing was written and nothing moved");
        assertEq(kernel.count(), 1, "no record");
        assertEq(kernel.lastEpoch(), 1, "the epoch is not consumed");
        assertFalse(kernel.graduated(), "the latch was rolled back with everything else");
        assertEq(address(vault).balance, nativeInVault, "both claims were rolled back");
        assertEq(token.balanceOf(address(vault)), tokensInVault);
        assertEq(token.balanceOf(DEAD), 0, "and so was the burn");

        // the same settle outside the callback, in the same block, succeeds, burns and buys
        _settle();
        Record memory r = _rec(2);
        assertEq(r.epoch, 2);
        assertTrue(kernel.graduated());
        assertEq(r.flags, RecordFlags.GRADUATED | RecordFlags.BUY_SHRUNK, "no failure flag");
        assertGt(r.buyExecuted, 0, "burned");
        assertGt(r.nativeIn, 0, "and bought on the pair");
        assertGt(r.tokensOut, r.buyExecuted);
        assertEq(token.balanceOf(DEAD), r.tokensOut);
    }

    /// The router does not always get as far as the pair's lock. When the flash swap borrowed more WOKB than
    /// the kernel's buy brings, the router fails on its own arithmetic first (the pair's WOKB balance is below
    /// its reserve); when it borrowed less, the router reaches the pair and passes on "UniswapV2: LOCKED".
    /// Both are failures only the lock holder sees, and both revert the settle: the kernel reads the router's
    /// error and, failing that, asks the pair whether its lock is held.
    function test_rev2_8_6_flash_swap_of_any_size_reverts_the_settle() public {
        _buy(alice, 10 ether);
        _nextEpoch();
        _settle();
        MockPair pair = _graduate();
        _nextEpoch();
        uint256 pot = address(kernel).balance + address(vault).balance - kernel.totalCredits(NATIVE);
        assertGt(pot, 2 ether);
        // the kernel's swap would bring about 1 OKB (its impact cap); borrow far less, about as much, far more
        uint256[5] memory borrowed = [uint256(1), 0.01 ether, 1 ether, 10 ether, 80 ether];
        for (uint256 i = 0; i < borrowed.length; i++) {
            uint256 snap = vm.snapshotState();
            FlashSwapper f = new FlashSwapper(wokb, kernel);
            bytes32 before = _digest();
            f.flashAndSettleInside{value: 1 ether}(pair, borrowed[i]);
            assertEq(f.attempts(), 1);
            assertFalse(f.settled(), "reverted, whatever the size of the loan");
            assertEq(bytes4(f.settleRevert()), Kernel.LockHeld.selector);
            assertEq(_digest(), before);
            vm.revertToState(snap);
        }
        _settle();
        assertGt(_rec(2).nativeIn, 0, "and outside any callback the swap goes through");
    }

    /// Each of the two ways the lock is recognised is enough on its own.
    function test_rev2_8_6_the_routers_error_and_the_lock_probe_each_suffice() public {
        _buy(alice, 10 ether);
        _nextEpoch();
        _settle();
        MockPair pair = _graduate();
        _nextEpoch();
        uint256 snap = vm.snapshotState();

        // (a) the router passes on the pair's lock error; the pair, asked, does not confirm it (here it is
        //     not locked at all): the router's error alone reverts the settle
        router.setRevertData(abi.encodeWithSignature("Error(string)", "UniswapV2: LOCKED"));
        vm.prank(keeper);
        vm.expectRevert(Kernel.LockHeld.selector);
        kernel.settle();
        vm.revertToState(snap);

        // (b) the router fails with something else entirely while the pair's lock is held: the probe alone
        //     reverts the settle
        router.setRevertData(abi.encodeWithSignature("Error(string)", "ds-math-sub-underflow"));
        FlashSwapper f = new FlashSwapper(wokb, kernel);
        f.flashAndSettleInside{value: 1 ether}(pair, 1);
        assertEq(f.attempts(), 1);
        assertFalse(f.settled());
        assertEq(bytes4(f.settleRevert()), Kernel.LockHeld.selector);
        router.setRevertData("");
        f.flashAndSettleInside{value: 1 ether}(pair, 1);
        assertFalse(f.settled(), "a failure with no revert data at all, under the lock");
        assertEq(bytes4(f.settleRevert()), Kernel.LockHeld.selector);
        vm.revertToState(snap);

        // (c) neither: the same failures outside any callback are failures every caller sees. Flag 32.
        router.setRevertData(abi.encodeWithSignature("Error(string)", "ds-math-sub-underflow"));
        _settle();
        assertTrue(_has(_rec(2).flags, RecordFlags.BUY_FAILED));
        assertEq(kernel.lastEpoch(), 2, "this one does consume the epoch, for everybody");
    }

    /// A settle from inside the lock never returns, at any gas limit: it reverts for the lock or for lack of
    /// gas. (The probe gets its gas like every other call, so it cannot be starved into saying "not locked".)
    function test_rev2_8_6_no_gas_limit_lets_a_settle_under_a_lock_through() public {
        _buy(alice, 10 ether);
        _nextEpoch();
        _settle();
        MockPair pair = _graduate();
        _nextEpoch();
        GasLimitedFlashSwapper f = new GasLimitedFlashSwapper(wokb, kernel);
        uint256 seenLock;
        uint256 seenGas;
        for (uint256 gasLimit = 50_000; gasLimit <= 14_000_000; gasLimit += 97_000) {
            uint256 snap = vm.snapshotState();
            f.flashAndSettleInside{value: 1 ether}(pair, 10 ether, gasLimit);
            assertFalse(f.settled(), "a settle under the pair's lock returned");
            bytes4 err = f.settleRevert().length >= 4 ? bytes4(f.settleRevert()) : bytes4(0);
            assertTrue(
                err == Kernel.LockHeld.selector || err == Kernel.InsufficientGas.selector || err == bytes4(0),
                "reverted for the lock or for lack of gas, nothing else"
            );
            if (err == Kernel.LockHeld.selector) seenLock++;
            else seenGas++;
            vm.revertToState(snap);
        }
        assertGt(seenLock, 10);
        assertGt(seenGas, 10);
    }

    /// The same for the Manager's lock on the curve.
    function test_rev2_8_6_no_gas_limit_lets_a_settle_under_the_managers_lock_through() public {
        _buy(alice, 5 ether);
        _nextEpoch();
        GasLimitedLockHolder h = new GasLimitedLockHolder(manager, kernel);
        uint256 seenLock;
        uint256 seenGas;
        for (uint256 gasLimit = 50_000; gasLimit <= 14_000_000; gasLimit += 97_000) {
            uint256 snap = vm.snapshotState();
            h.sellZeroAndSettleInside(address(token), gasLimit);
            assertFalse(h.settled(), "a settle under the Manager's lock returned");
            bytes4 err = h.settleRevert().length >= 4 ? bytes4(h.settleRevert()) : bytes4(0);
            assertTrue(
                err == Kernel.LockHeld.selector || err == Kernel.InsufficientGas.selector || err == bytes4(0),
                "reverted for the lock or for lack of gas, nothing else"
            );
            if (err == Kernel.LockHeld.selector) seenLock++;
            else seenGas++;
            vm.revertToState(snap);
        }
        assertGt(seenLock, 10);
        assertGt(seenGas, 10);
    }

    /// Holding the pair's lock changes nothing when the settle makes no swap: with an empty native pot the
    /// claims and the burn do not touch the pair's lock, and the record is the one any other caller gets.
    function test_rev2_8_6_under_the_pairs_lock_a_settle_without_a_swap_is_unchanged() public {
        _buy(alice, 10 ether);
        _nextEpoch();
        _settle();
        MockPair pair = _graduate();
        for (uint256 i = 0; i < 12; i++) {
            _nextEpoch();
            _settle();
        }
        assertEq(address(kernel).balance, kernel.totalCredits(NATIVE), "the native pot is empty");
        _v2Buy(alice, 2 ether); // token tax to claim and burn
        FlashSwapper f = new FlashSwapper(wokb, kernel);
        _nextEpoch();
        uint256 snap = vm.snapshotState();
        _settle();
        bytes32 outside = _digest();
        Record memory r = _rec(kernel.count());
        assertGt(r.buyExecuted, 0, "the settle burns");
        assertEq(r.nativeIn, 0, "and has nothing to swap");
        vm.revertToState(snap);
        // the flash swap moves the pair's balances while it is open; the settle does not read them without a pot
        f.flashAndSettleInside{value: 1 ether}(pair, 10 ether);
        assertEq(f.attempts(), 1);
        assertTrue(f.settled(), "no swap, so the lock does not matter");
        assertEq(_digest(), outside, "the same record for every caller");
    }

    // ------------------------------------------------------------------ 9.2: the graduation latch

    /// Revision 2, section 9.2: the latch is set in the first settle in which the token itself reports a
    /// pair, and `pair` is that address. The Manager's pairOf is not used for it.
    function test_rev2_9_2_latch_reads_the_token_not_the_manager() public {
        MockPair pair = _graduate();
        assertEq(token.pair(), address(pair), "the token itself reports its pair");
        manager.setPairOfReverts(true);
        _nextEpoch();
        vm.prank(keeper);
        kernel.settle();
        assertTrue(kernel.graduated(), "latched although Manager.pairOf cannot be read");
        assertEq(kernel.pair(), address(pair));
        assertTrue(_has(_rec(1).flags, RecordFlags.GRADUATED));
    }

    /// The kernel's `pair` is whatever the token reported, even where the Manager says something else.
    function test_rev2_9_2_pair_is_the_address_the_token_reported() public {
        MockPair pair = _graduate();
        address lie = makeAddr("another pair");
        vm.mockCall(address(manager), abi.encodeWithSignature("pairOf(address)", address(token)), abi.encode(lie));
        _nextEpoch();
        vm.prank(keeper);
        kernel.settle();
        assertEq(kernel.pair(), address(pair));
    }

    /// And the other way round: while the token reports no pair there is no latch, whatever the Manager says.
    function test_rev2_9_2_no_latch_while_the_token_reports_no_pair() public {
        vm.mockCall(
            address(manager), abi.encodeWithSignature("pairOf(address)", address(token)), abi.encode(makeAddr("pair"))
        );
        _buy(alice, 5 ether);
        _nextEpoch();
        _settle();
        assertFalse(kernel.graduated());
        assertEq(kernel.pair(), address(0));
        assertEq(_in(1).grad, 0);
        assertGt(_rec(1).buyExecuted, 0, "still the curve regime: the kernel bought on the curve");
    }

    // ------------------------------------------------------------------ 10: bind

    /// Revision 2, section 10: bind is also allowed when the caller is the launcher, whoever created the
    /// token, so that a token launched from the wrong wallet can still be bound. Nobody else can bind it.
    function test_rev2_10_bind_by_the_launcher_of_a_token_created_elsewhere() public {
        vm.prank(launcher);
        uint256 id = fab.tapeoutChip(ChipModel.fixedChip(8, W), 200);
        Kernel k = Kernel(payable(factory.create(_env(), id, "bind")));
        (address t,) = manager.createToken(alice, address(k), 300, 300, 0, 0, GRADUATION); // the wrong wallet
        vm.prank(launcher);
        circuits.transferFrom(launcher, address(k), id);

        vm.prank(alice); // not the token's creator
        vm.expectRevert(abi.encodeWithSelector(Kernel.BindCheck.selector, uint8(5)));
        k.bind(t);
        vm.prank(bob); // not a stranger
        vm.expectRevert(abi.encodeWithSelector(Kernel.BindCheck.selector, uint8(5)));
        k.bind(t);

        vm.prank(launcher);
        k.bind(t);
        assertEq(k.token(), t);
        assertEq(factory.kernelOf(t), address(k));
    }

    // ------------------------------------------------------------------ 10: Record.nativeIn

    /// Revision 2, section 10: Record.nativeIn is the OKB the post-graduation router buy spent. It is in the
    /// record (and still in the NativeSwept event); it is 0 on the curve.
    function test_rev2_10_native_spent_is_in_the_record() public {
        _buy(alice, 10 ether);
        _nextEpoch();
        _settle();
        assertEq(_rec(1).nativeIn, 0, "0 on the curve, where buyExecuted is the OKB spent");
        assertGt(_rec(1).buyExecuted, 0);
        _graduate();
        _nextEpoch();
        uint256 before = address(kernel).balance + address(vault).balance;
        vm.recordLogs();
        _settle();
        uint256 spent = before - address(kernel).balance;
        Record memory r = _rec(2);
        assertGt(spent, 0);
        assertEq(r.nativeIn, spent, "the record carries it");
        bytes32 sig = keccak256("NativeSwept(uint32,uint256,uint256)");
        bool found;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig && logs[i].emitter == address(kernel)) {
                (uint256 nativeIn, uint256 burned) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(nativeIn, r.nativeIn, "and the event agrees with the record");
                assertEq(burned, r.tokensOut - r.buyExecuted);
                found = true;
            }
        }
        assertTrue(found, "NativeSwept emitted");
        // the Settled event is unchanged: nativeIn is not part of it
        bytes32 settledSig = keccak256(
            "Settled(uint32,uint32,bytes12,bytes14,uint16,uint8,bytes32,uint128,uint128,uint128,uint128,uint128)"
        );
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == settledSig) assertEq(logs[i].data.length, 11 * 32);
        }
    }
}
