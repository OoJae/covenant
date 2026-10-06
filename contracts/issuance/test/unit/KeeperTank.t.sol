// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {LocalBase} from "../utils/LocalBase.sol";
import {KeeperTank} from "../../src/KeeperTank.sol";
import {NetlistScan} from "../../src/lib/NetlistScan.sol";
import {MockKernel} from "../mocks/MockKernel.sol";
import {
    ReentrantKernel,
    BusyKernel,
    StorageRefundKernel,
    ReturnBombKernel,
    LyingKernel,
    PickyKernel,
    KernelAndMaintainer,
    SilentWallet,
    GasTrapSender,
    ShortAnswerSender,
    MeteredBatch,
    ReentrantCaller,
    RejectingCaller
} from "../mocks/Hostile.sol";

contract KeeperTankTest is LocalBase {
    event Refunded(
        uint256 indexed chipId, address indexed kernel, address indexed caller, uint256 gasUsed, uint256 paid
    );
    event ToppedUp(uint256 indexed chipId, address indexed from, uint256 amount);
    event Funded(address indexed from, uint256 amount);
    event Initialised(address indexed circuits, address indexed transistors, uint256 mintPrice);

    bytes4 internal constant REENTRANT = bytes4(keccak256("ReentrancyGuardReentrantCall()"));

    // allowance of the 3-NAND chip: 3 * 0.00002 OKB * 85%
    uint256 internal constant NAND3_ALLOWANCE = 51_000_000_000_000;

    function setUp() public {
        _deployLocal(maintainer);
    }

    // ------------------------------------------------------------------ helpers

    /// @dev 12 OKB of unattributed backing in the tank, the way it really arrives
    function _fundTank() internal {
        _mint(user, 0, 1_000_000);
        splitter.pull();
    }

    function _topUp(uint256 chipId, uint256 amount) internal {
        vm.deal(user, user.balance + amount);
        vm.prank(user);
        tank.topUp{value: amount}(chipId);
    }

    function _give(uint256 chipId, address to) internal {
        vm.prank(user);
        circuits.transferFrom(user, to, chipId);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _refundedLogs() internal view returns (uint256[] memory counted, uint256[] memory paid) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(tank) && logs[i].topics[0] == REFUNDED_SIG) n++;
        }
        counted = new uint256[](n);
        paid = new uint256[](n);
        n = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(tank) && logs[i].topics[0] == REFUNDED_SIG) {
                (counted[n], paid[n]) = abi.decode(logs[i].data, (uint256, uint256));
                n++;
            }
        }
    }

    // ------------------------------------------------------------------ setup

    function test_constants() public view {
        assertEq(tank.ALLOWANCE_BPS(), 8500);
        assertEq(tank.MAX_TIP(), 0.001 gwei);
        assertEq(tank.MAX_TIP(), 1_000_000);
        assertEq(tank.OVERHEAD(), 34_000);
        assertEq(tank.OVERHEAD_REPEAT(), 10_500);
        assertEq(tank.RECEIVE_MIN_GAS(), 200_000);
        assertEq(tank.SPLITTER(), address(splitter));
    }

    function test_init_onlyTheDeployer_onlyOnce() public {
        KeeperTank fresh = new KeeperTank(); // this test contract plays the Splitter
        assertEq(fresh.SPLITTER(), address(this));
        assertEq(fresh.circuits(), address(0));

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(KeeperTank.NotSplitter.selector);
        fresh.init(address(circuits), address(transistors));

        vm.expectRevert(KeeperTank.ZeroAddress.selector);
        fresh.init(address(0), address(transistors));
        vm.expectRevert(KeeperTank.ZeroAddress.selector);
        fresh.init(address(circuits), address(0));

        vm.expectEmit(true, true, true, true, address(fresh));
        emit Initialised(address(circuits), address(transistors), PRICE);
        fresh.init(address(circuits), address(transistors));
        assertEq(fresh.circuits(), address(circuits));
        assertEq(fresh.transistors(), address(transistors));
        assertEq(fresh.mintPrice(), PRICE);

        vm.expectRevert(KeeperTank.AlreadyInitialised.selector);
        fresh.init(address(circuits), address(transistors));
    }

    function test_init_theRealTank_isAlreadyInitialised_andOnlyTheSplitterCouldCall() public {
        vm.expectRevert(KeeperTank.NotSplitter.selector);
        tank.init(address(1), address(2));

        vm.prank(address(splitter));
        vm.expectRevert(KeeperTank.AlreadyInitialised.selector);
        tank.init(address(1), address(2));
    }

    // ------------------------------------------------------------------ allowance

    function test_allowance_ofTheThreeNandChip() public {
        (uint256 chipId,) = _chipInKernel();
        assertEq(tank.burnedOf(chipId), 3);
        assertEq(tank.allowanceOf(chipId), 3 * PRICE * 8500 / 10_000);
        assertEq(tank.allowanceOf(chipId), NAND3_ALLOWANCE);
        assertEq(tank.remainingOf(chipId), NAND3_ALLOWANCE);
        assertEq(tank.spent(chipId), 0);
        assertEq(tank.toppedUp(chipId), 0);
    }

    function test_allowance_countsNandAndLatch_notRef() public {
        // 2 NAND + 1 LATCH + a REF to chip 1 (2 inputs, 1 output)
        (uint256 first,) = _chipInKernel();
        bytes memory ref =
            abi.encodePacked(uint8(2), address(circuits), uint64(first), uint8(2), uint8(1), uint24(2), uint24(3));
        bytes memory nl = bytes.concat(hex"00000002000003", hex"01000004", hex"00000004000005", ref);
        uint256 chipId = _tapeout(user, nl, 2, 1, 2, 1);

        assertEq(tank.burnedOf(chipId), 3);
        assertEq(tank.allowanceOf(chipId), NAND3_ALLOWANCE);
    }

    function test_allowance_ofAChipThatDoesNotExist_reverts() public {
        vm.expectRevert(bytes("no circuit"));
        tank.burnedOf(999);
        vm.expectRevert(bytes("no circuit"));
        tank.allowanceOf(999);
        vm.expectRevert(bytes("no circuit"));
        tank.remainingOf(999);
    }

    function testFuzz_allowance(uint16 nNand, uint8 nLatch, uint64 topUp) public {
        uint256 nn = uint256(nNand) % 400;
        bytes memory nl = _nands(nn);
        for (uint256 i = 0; i < nLatch; i++) {
            nl = bytes.concat(nl, hex"01000002");
        }
        vm.assume(nl.length != 0);
        uint256 chipId = _tapeout(user, nl, nn, nLatch, 2, 1);
        if (topUp != 0) _topUp(chipId, topUp);

        assertEq(tank.burnedOf(chipId), nn + nLatch);
        assertEq(tank.allowanceOf(chipId), (nn + nLatch) * PRICE * 8500 / 10_000 + topUp);
        assertEq(tank.remainingOf(chipId), tank.allowanceOf(chipId));
    }

    /// Allowances that come from burns are always backed: the tank receives 85% of every transistor sold,
    /// and only burned ones create an allowance.
    function testFuzz_burnAllowances_areBackedOncePulled(uint8 chips, uint16 unburned) public {
        uint256 n = 1 + uint256(chips) % 6;
        uint256 totalAllowance;
        for (uint256 i = 0; i < n; i++) {
            uint256 gates = 1 + (i * 37) % 90;
            uint256 chipId = _tapeout(user, _nands(gates), gates, 0, 2, 1);
            totalAllowance += tank.allowanceOf(chipId);
        }
        if (unburned != 0) _mint(user, 1, unburned);
        splitter.pull();
        assertGe(address(tank).balance, totalAllowance);
    }

    // ------------------------------------------------------------------ who can be settled

    function test_settle_requiresTheKernelToHoldItsChip() public {
        uint256 chipId = _tapeout(user, NAND3, 3, 0, 2, 1);
        MockKernel kernel = new MockKernel(chipId);
        _fundTank();

        // the chip is still in the user's wallet
        vm.expectRevert(KeeperTank.KernelDoesNotHoldChip.selector);
        tank.settleAndRefund(address(kernel));
        assertEq(kernel.settles(), 0);

        _give(chipId, address(kernel));

        // some other contract pointing at the same chip gets nothing
        LyingKernel liar = new LyingKernel(chipId);
        vm.expectRevert(KeeperTank.KernelDoesNotHoldChip.selector);
        tank.settleAndRefund(address(liar));
        assertEq(liar.settles(), 0);
        assertEq(tank.spent(chipId), 0);

        // the holder is settled
        _settleAs(keeper, address(kernel));
        assertEq(kernel.settles(), 1);
    }

    function test_settle_aChipThatDoesNotExist_reverts() public {
        LyingKernel liar = new LyingKernel(999);
        vm.expectRevert(bytes("ERC721NonexistentToken"));
        tank.settleAndRefund(address(liar));
    }

    function test_settle_anAddressWithoutCode_reverts() public {
        vm.expectRevert();
        tank.settleAndRefund(makeAddr("not a kernel"));
    }

    function test_settle_bubblesTheKernelsRevertUnchanged() public {
        (uint256 chipId, MockKernel kernel) = _chipInKernel();
        _fundTank();

        kernel.setRevertMode(1);
        vm.expectRevert(bytes("kernel: epoch not elapsed"));
        tank.settleAndRefund(address(kernel));

        kernel.setRevertMode(2);
        vm.expectRevert(abi.encodeWithSelector(MockKernel.NothingToSettle.selector, 42));
        tank.settleAndRefund(address(kernel));

        kernel.setRevertMode(3);
        vm.expectRevert(bytes(""));
        tank.settleAndRefund(address(kernel));

        // a reverted settlement costs the chip nothing
        assertEq(tank.spent(chipId), 0);
        assertEq(kernel.settles(), 0);
    }

    // ------------------------------------------------------------------ the refund

    function test_settle_refundsTheCallersGas() public {
        (uint256 chipId, MockKernel kernel) = _chipInKernel();
        _fundTank();
        uint256 tankBefore = address(tank).balance;

        vm.expectEmit(true, true, true, false, address(tank));
        emit Refunded(chipId, address(kernel), keeper, 0, 0);
        Settled memory r = _settleAs(keeper, address(kernel));

        assertEq(kernel.settles(), 1);
        assertGt(r.paid, 0);
        assertEq(r.paid, r.gasCounted * GASPRICE, "tip of 1 wei is under the cap: refund at the price paid");
        assertLe(r.gasCounted, r.txGasBilled, "counted more gas than the transaction used");
        assertLe(r.paid, r.txGasBilled * GASPRICE, "refund exceeds what the caller paid for gas");

        assertEq(keeper.balance, r.paid);
        assertEq(address(tank).balance, tankBefore - r.paid);
        assertEq(tank.spent(chipId), r.paid);
        assertEq(tank.remainingOf(chipId), NAND3_ALLOWANCE - r.paid);
    }

    function test_refund_isCappedAtBaseFeePlusMaxTip() public {
        (uint256 chipId, MockKernel kernel) = _chipInKernel();
        _topUp(chipId, 1 ether);
        vm.fee(1 gwei);
        vm.txGasPrice(5 gwei); // a 4 gwei tip: 4,000 times MAX_TIP

        Settled memory r = _settleAs(keeper, address(kernel));
        assertEq(r.paid, r.gasCounted * (1 gwei + 0.001 gwei));
        assertLt(r.paid, r.txGasBilled * 5 gwei);
    }

    /// Why MAX_TIP is small. A tip that is refunded costs the caller nothing, so the cap is how much faster
    /// than necessary any caller can use up a chip's allowance. At X Layer's base fee of 0.02 gwei the cap of
    /// 0.001 gwei is 5%; a tip of half the base fee (the first version's cap) is refunded at the cap only.
    function test_refund_aTipCannotDrainTheAllowanceMuchFaster() public {
        (uint256 chipId, MockKernel kernel) = _chipInKernel();
        _topUp(chipId, 1 ether);
        _settleAs(keeper, address(kernel)); // the first settlement of a chip costs more: out of the way
        assertEq(block.basefee, 0.02 gwei);

        vm.txGasPrice(0.02 gwei);
        Settled memory plain = _settleAs(keeper, address(kernel));
        vm.txGasPrice(0.02 gwei + 0.001 gwei);
        Settled memory capped = _settleAs(keeper, address(kernel));
        vm.txGasPrice(0.02 gwei + 0.01 gwei);
        Settled memory greedy = _settleAs(keeper, address(kernel));

        // per unit of gas counted: the base fee, then 5% more at the cap, and no more than that above it
        assertEq(plain.paid, plain.gasCounted * 0.02 gwei);
        assertEq(capped.paid, capped.gasCounted * 0.021 gwei);
        assertEq(greedy.paid, greedy.gasCounted * 0.021 gwei, "a larger tip is not refunded beyond the cap");
        assertEq(uint256(0.021 gwei) * 100, uint256(0.02 gwei) * 105, "the largest refunded tip drains 5% faster");
        assertEq(greedy.gasCounted, capped.gasCounted);
        assertEq(greedy.paid, capped.paid);

        // the capped caller got its whole price back per unit of gas; the greedy one paid 0.009 gwei per
        // unit out of its own pocket
        assertLe(capped.paid, capped.txGasBilled * 0.021 gwei);
        assertLe(greedy.paid + greedy.txGasBilled * 0.009 gwei, greedy.txGasBilled * 0.03 gwei);
    }

    function test_refund_usesTheGasPriceWhenItIsUnderTheCap() public {
        (uint256 chipId, MockKernel kernel) = _chipInKernel();
        _topUp(chipId, 1 ether);
        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei + 0.001 gwei - 1);
        Settled memory r = _settleAs(keeper, address(kernel));
        assertEq(r.paid, r.gasCounted * (1 gwei + 0.001 gwei - 1));

        // exactly at the cap
        vm.txGasPrice(1 gwei + 0.001 gwei);
        r = _settleAs(keeper, address(kernel));
        assertEq(r.paid, r.gasCounted * (1 gwei + 0.001 gwei));

        // one wei above it
        vm.txGasPrice(1 gwei + 0.001 gwei + 1);
        r = _settleAs(keeper, address(kernel));
        assertEq(r.paid, r.gasCounted * (1 gwei + 0.001 gwei));
    }

    function test_refund_atZeroGasPrice_isZero_andStillSettles() public {
        (uint256 chipId, MockKernel kernel) = _chipInKernel();
        _fundTank();
        vm.txGasPrice(0);

        Settled memory r = _settleAs(keeper, address(kernel));
        assertEq(r.paid, 0);
        assertEq(kernel.settles(), 1);
        assertEq(tank.spent(chipId), 0);
    }

    function test_refund_whenTheAllowanceRunsOut_paysTheRest_thenZero_andStillSettles() public {
        (uint256 chipId, MockKernel kernel) = _chipInKernel();
        _fundTank();
        kernel.setBurnGas(1_500_000); // about 0.0000314 OKB per settlement at 0.02 gwei; the allowance is 0.000051

        Settled memory first = _settleAs(keeper, address(kernel));
        assertEq(first.paid, first.gasCounted * GASPRICE, "first refund is paid in full");

        Settled memory second = _settleAs(keeper, address(kernel));
        assertEq(second.paid, NAND3_ALLOWANCE - first.paid, "second refund is whatever is left");
        assertLt(second.paid, second.gasCounted * GASPRICE);

        Settled memory third = _settleAs(keeper, address(kernel));
        assertEq(third.paid, 0, "exhausted");

        assertEq(kernel.settles(), 3, "an exhausted chip is still settled");
        assertEq(tank.spent(chipId), NAND3_ALLOWANCE);
        assertEq(tank.remainingOf(chipId), 0);
        assertEq(keeper.balance, NAND3_ALLOWANCE);
    }

    function test_refund_isCappedByTheTanksBalance() public {
        (uint256 chipId, MockKernel kernel) = _chipInKernel();
        // proceeds not pulled yet: the allowance exists but the tank is empty
        assertEq(address(tank).balance, 0);
        Settled memory r = _settleAs(keeper, address(kernel));
        assertEq(r.paid, 0);
        assertEq(kernel.settles(), 1);

        vm.deal(address(tank), 1000);
        r = _settleAs(keeper, address(kernel));
        assertEq(r.paid, 1000);
        assertEq(tank.spent(chipId), 1000);
        assertEq(address(tank).balance, 0);

        // anyone can restore the backing
        splitter.pull();
        r = _settleAs(keeper, address(kernel));
        assertEq(r.paid, r.gasCounted * GASPRICE);
    }

    function test_refund_oneChipCannotSpendAnothersAllowance() public {
        (uint256 chipA, MockKernel kernelA) = _chipInKernel();
        (uint256 chipB,) = _chipInKernel();
        _fundTank();
        _topUp(chipB, 1 ether);
        kernelA.setBurnGas(3_000_000);

        _settleAs(keeper, address(kernelA));
        Settled memory r = _settleAs(keeper, address(kernelA));
        assertEq(r.paid, 0);
        assertEq(tank.spent(chipA), NAND3_ALLOWANCE);
        assertEq(tank.spent(chipB), 0);
        assertEq(tank.remainingOf(chipB), NAND3_ALLOWANCE + 1 ether);
    }

    /// For any base fee, tip, kernel workload, top-up and tank balance, the refund is exactly
    /// min(counted gas * capped price, remaining allowance, tank balance), the counted gas never exceeds the
    /// gas the transaction was billed for, and the refund never exceeds what the caller paid.
    function testFuzz_refundBound(uint64 baseFee, uint64 tip, uint32 burn, uint96 topUp, uint96 tankBalance) public {
        uint256 fee = bound(uint256(baseFee), 0, 1000 gwei);
        uint256 gasPrice = fee + bound(uint256(tip), 0, 100 gwei);
        vm.fee(fee);
        vm.txGasPrice(gasPrice);

        (uint256 chipId, MockKernel kernel) = _chipInKernel();
        kernel.setBurnGas(bound(uint256(burn), 0, 3_000_000));
        if (topUp != 0) _topUp(chipId, topUp);
        vm.deal(address(tank), tankBalance);

        uint256 remainingBefore = tank.remainingOf(chipId);
        Settled memory r = _settleAs(keeper, address(kernel));

        uint256 price = _min(gasPrice, fee + 0.001 gwei);
        assertEq(r.paid, _min(r.gasCounted * price, _min(remainingBefore, tankBalance)), "refund formula");
        // The overhead constant assumes the storage write and the transfer of a paid refund. When nothing is
        // paid neither happens, so the comparison is only meaningful (and only matters) when money moves.
        if (r.paid != 0) assertLe(r.gasCounted, r.txGasBilled, "counted more gas than was billed");
        assertLe(r.paid, r.txGasBilled * gasPrice, "refund exceeds what the caller paid");

        assertEq(keeper.balance, r.paid);
        assertEq(tank.spent(chipId), r.paid);
        assertEq(tank.remainingOf(chipId), remainingBefore - r.paid);
        assertEq(address(tank).balance, uint256(tankBalance) - r.paid);
        assertEq(kernel.settles(), 1);
    }

    /// Over any sequence of settlements a chip never pays out more than its allowance.
    function testFuzz_spentNeverExceedsAllowance(uint32[8] memory burns, uint64 topUp) public {
        (uint256 chipId, MockKernel kernel) = _chipInKernel();
        _fundTank();
        if (topUp != 0) _topUp(chipId, topUp % 0.0002 ether);
        uint256 allowance = tank.allowanceOf(chipId);

        uint256 total;
        for (uint256 i = 0; i < burns.length; i++) {
            kernel.setBurnGas(uint256(burns[i]) % 2_000_000);
            Settled memory r = _settleAs(keeper, address(kernel));
            total += r.paid;
            assertLe(tank.spent(chipId), allowance);
            assertEq(tank.spent(chipId), total);
        }
        assertEq(keeper.balance, total);
        assertEq(kernel.settles(), burns.length);
    }

    // ------------------------------------------------------------------ the burn count is fixed at first use

    function test_burned_isReadLiveUntilFirstSettle_thenFixed() public {
        (uint256 chipId, MockKernel kernel) = _chipInKernel();
        _fundTank();

        // before the first settlement the count follows the netlist
        circuits.overwriteNetlist(chipId, _nands(5));
        assertEq(tank.burnedOf(chipId), 5);
        circuits.overwriteNetlist(chipId, NAND3);
        assertEq(tank.burnedOf(chipId), 3);

        _settleAs(keeper, address(kernel));

        // afterwards a logic upgrade that rewrites the netlist cannot inflate (or break) the allowance
        circuits.overwriteNetlist(chipId, _nands(2_000));
        assertEq(tank.burnedOf(chipId), 3);
        assertEq(tank.allowanceOf(chipId), NAND3_ALLOWANCE);

        circuits.overwriteNetlist(chipId, hex"ff");
        assertEq(tank.burnedOf(chipId), 3);
        _settleAs(keeper, address(kernel));
        assertEq(kernel.settles(), 2);
    }

    function test_settle_aChipWhoseNetlistIsMalformed_reverts() public {
        (uint256 chipId, MockKernel kernel) = _chipInKernel();
        circuits.overwriteNetlist(chipId, hex"ff");
        vm.expectRevert(abi.encodeWithSelector(NetlistScan.BadOpcode.selector, 0, 0xff));
        tank.settleAndRefund(address(kernel));

        circuits.overwriteNetlist(chipId, hex"0000");
        vm.expectRevert(abi.encodeWithSelector(NetlistScan.TruncatedRecord.selector, 0));
        tank.settleAndRefund(address(kernel));
    }

    // ------------------------------------------------------------------ hostile kernels

    function test_hostile_kernelReentersSettleAndRefund_bubbling_reverts() public {
        uint256 chipId = _tapeout(user, NAND3, 3, 0, 2, 1);
        ReentrantKernel kernel = new ReentrantKernel(tank, chipId, false);
        _give(chipId, address(kernel));
        _fundTank();

        vm.prank(keeper, keeper);
        vm.expectRevert(REENTRANT);
        tank.settleAndRefund(address(kernel));

        assertEq(tank.spent(chipId), 0);
        assertEq(keeper.balance, 0);
    }

    function test_hostile_kernelReentersSettleAndRefund_swallowing_isRefundedOnce() public {
        uint256 chipId = _tapeout(user, NAND3, 3, 0, 2, 1);
        ReentrantKernel kernel = new ReentrantKernel(tank, chipId, true);
        _give(chipId, address(kernel));
        _fundTank();

        vm.recordLogs();
        vm.prank(keeper, keeper);
        tank.settleAndRefund(address(kernel));
        Vm.Gas memory g = vm.lastFrameGas();
        (uint256[] memory counted, uint256[] memory paid) = _refundedLogs();

        assertTrue(kernel.reentryBlocked(), "the nested call must hit the reentrancy guard");
        assertEq(counted.length, 1, "exactly one refund");
        assertEq(kernel.settles(), 1);
        assertEq(address(kernel).balance, 0, "the kernel received nothing");
        assertEq(keeper.balance, paid[0]);
        assertEq(tank.spent(chipId), paid[0]);
        assertLe(paid[0], (g.gasTotalUsed - uint256(int256(g.gasRefunded))) * GASPRICE);
    }

    /// An attacker who owns both the chip and the keeper and burns gas in settle() never comes out ahead:
    /// every refund is at most the gas bill of the transaction that earned it.
    function test_hostile_kernelBurnsGas_gainsNothing() public {
        (uint256 chipId, MockKernel kernel) = _chipInKernel();
        _fundTank();
        _topUp(chipId, 0.001 ether);
        kernel.setBurnGas(5_000_000);
        address attacker = keeper;

        uint256 refunds;
        uint256 gasBill;
        for (uint256 i = 0; i < 12; i++) {
            Settled memory r = _settleAs(attacker, address(kernel));
            refunds += r.paid;
            gasBill += r.txGasBilled * GASPRICE;
            assertLe(r.paid, r.txGasBilled * GASPRICE);
        }
        assertLe(refunds, gasBill, "attacker was refunded more than its gas cost");
        assertEq(tank.remainingOf(chipId), 0, "and all it achieved was to empty its own chip's allowance");
        assertEq(refunds, NAND3_ALLOWANCE + 0.001 ether);
    }

    function testFuzz_hostile_kernelBurnsGas_gainsNothing(uint32 burn, uint64 baseFee, uint64 tip, uint64 topUp)
        public
    {
        uint256 fee = bound(uint256(baseFee), 0, 500 gwei);
        uint256 gasPrice = fee + bound(uint256(tip), 0, 50 gwei);
        vm.fee(fee);
        vm.txGasPrice(gasPrice);
        (uint256 chipId, MockKernel kernel) = _chipInKernel();
        _fundTank();
        if (topUp != 0) _topUp(chipId, topUp);
        kernel.setBurnGas(bound(uint256(burn), 0, 8_000_000));

        for (uint256 i = 0; i < 3; i++) {
            Settled memory r = _settleAs(keeper, address(kernel));
            assertLe(r.paid, r.txGasBilled * gasPrice);
        }
    }

    /// A kernel may pull the Splitter and top itself up while it is being settled. Nothing breaks, the
    /// top-up counts at once, and the refund obeys the same bound.
    function test_hostile_kernelPullsAndTopsUpDuringSettle() public {
        uint256 chipId = _tapeout(user, NAND3, 3, 0, 2, 1);
        BusyKernel kernel = new BusyKernel(tank, splitter, chipId);
        _give(chipId, address(kernel));
        vm.deal(address(kernel), 1 ether);
        _mint(user, 0, 500_000); // proceeds waiting in TapeOut: the kernel's pull() brings them in

        // explicit topUp during settle()
        kernel.configure(0.1 ether, false);
        Settled memory r = _settleAs(keeper, address(kernel));
        assertEq(tank.toppedUp(chipId), 0.1 ether);
        // 500,003 transistors were sold (3 of them for this chip): 85% of their price is now in the tank
        assertEq(
            address(tank).balance,
            500_003 * PRICE * 8500 / 10_000 + 0.1 ether - r.paid,
            "the pull inside settle() arrived"
        );
        assertLe(r.paid, r.txGasBilled * GASPRICE);
        assertEq(tank.spent(chipId), r.paid);

        // plain transfer during settle(), attributed through receive()
        kernel.configure(0.2 ether, true);
        r = _settleAs(keeper, address(kernel));
        assertEq(tank.toppedUp(chipId), 0.3 ether);
        assertLe(r.paid, r.txGasBilled * GASPRICE);
        assertEq(kernel.settles(), 2);
    }

    /// One hostile contract that is both the Splitter's maintainer and a kernel. Being settled, it re-enters
    /// settleAndRefund (blocked) and pulls the Splitter; being paid by that pull, it pulls again (blocked).
    /// It ends with exactly its 15% and its keeper with one refund.
    function test_hostile_kernelThatIsAlsoTheMaintainer_cannotReenterSettleOrPull() public {
        KernelAndMaintainer hostile = new KernelAndMaintainer();
        _deployLocal(address(hostile)); // a processor whose maintainer is the hostile contract
        uint256 chipId = _tapeout(user, NAND3, 3, 0, 2, 1);
        _give(chipId, address(hostile));
        hostile.arm(tank, splitter, chipId);
        _mint(user, 0, 1000);
        uint256 proceeds = 1003 * PRICE;

        vm.recordLogs();
        vm.prank(keeper, keeper);
        tank.settleAndRefund(address(hostile));
        Vm.Gas memory g = vm.lastFrameGas();
        (uint256[] memory counted, uint256[] memory paid) = _refundedLogs();

        assertTrue(hostile.settleReentryBlocked(), "nested settleAndRefund must hit the tank's guard");
        assertTrue(hostile.pullReentryBlocked(), "nested pull must hit the splitter's guard");
        assertEq(hostile.settles(), 1);

        // exactly one split, at the fixed shares
        assertEq(address(hostile).balance, proceeds * 1500 / 10_000, "the maintainer share, once");
        assertEq(address(tank).balance, proceeds * 8500 / 10_000 - paid[0]);
        assertEq(address(splitter).balance, 0);
        assertEq(splitter.maintainerOwed(), 0);

        // exactly one refund, to the keeper, within its gas bill
        assertEq(counted.length, 1);
        assertEq(keeper.balance, paid[0]);
        assertEq(tank.spent(chipId), paid[0]);
        assertLe(paid[0], (g.gasTotalUsed - uint256(int256(g.gasRefunded))) * GASPRICE);
    }

    function test_hostile_kernelReturnsAHugeBuffer_tankDoesNotCopyIt() public {
        uint256 chipId = _tapeout(user, NAND3, 3, 0, 2, 1);
        ReturnBombKernel kernel = new ReturnBombKernel(chipId, 1_000_000); // 1 MB: about 2.0M gas for the kernel
        _give(chipId, address(kernel));
        _fundTank();
        _topUp(chipId, 1 ether);

        Settled memory r = _settleAs(keeper, address(kernel));
        // copying 1 MB into the tank's memory would cost about 2.0M gas more
        assertLt(r.txGas, 2_500_000);
        assertLe(r.paid, r.txGasBilled * GASPRICE);
    }

    /// The stated caveat, pinned down. Gas the EVM gives back for clearing storage (EIP-3529) is invisible to
    /// a contract, so a kernel that sets and clears storage inside settle() makes the counted gas exceed the
    /// billed gas, by at most a quarter. It is paid from that kernel's own allowance and nowhere else.
    function test_caveat_storageRefundsEarnedInsideSettle() public {
        uint256 chipId = _tapeout(user, NAND3, 3, 0, 2, 1);
        StorageRefundKernel kernel = new StorageRefundKernel(chipId, 200);
        _give(chipId, address(kernel));
        _fundTank();
        _topUp(chipId, 0.001 ether);
        (uint256 otherChip,) = _chipInKernel();

        Settled memory r = _settleAs(keeper, address(kernel));

        assertLe(r.gasCounted, r.txGas, "never more than the gas the transaction consumed");
        assertGt(r.gasCounted, r.txGasBilled, "this is the caveat: more than the gas billed after refunds");
        assertLe(r.paid * 4, r.txGasBilled * GASPRICE * 5, "by at most a quarter (EIP-3529 caps refunds at 1/5)");

        // it came out of the hostile kernel's own allowance
        assertEq(tank.spent(chipId), r.paid);
        assertLe(tank.spent(chipId), tank.allowanceOf(chipId));
        assertEq(tank.spent(otherChip), 0);
        assertEq(tank.remainingOf(otherChip), NAND3_ALLOWANCE);
    }

    /// The whole of what such an attacker can ever take is its own allowance, and it paid the mint proceeds
    /// (of which only 85% became allowance) plus every top-up itself.
    function test_caveat_isBoundedByWhatTheAttackerPaidIn() public {
        address attacker = makeAddr("attacker");
        vm.deal(attacker, 10 ether);
        uint256 startBalance = attacker.balance;

        // attacker buys 3 transistors, tapes out, runs a refund-farming kernel and keeps the keeper refunds
        vm.startPrank(attacker);
        transistors.mint{value: 3 * PRICE + PROTOCOL_FEE}(0, 3);
        uint256 chipId = circuits.tapeout{value: TAPEOUT_FEE}(NAND3, 2, 1);
        StorageRefundKernel kernel = new StorageRefundKernel(chipId, 60);
        circuits.transferFrom(attacker, address(kernel), chipId);
        vm.stopPrank();
        splitter.pull();

        uint256 gasBill;
        for (uint256 i = 0; i < 6; i++) {
            Settled memory r = _settleAs(attacker, address(kernel));
            gasBill += r.txGasBilled * GASPRICE;
        }
        assertEq(tank.remainingOf(chipId), 0, "allowance fully drained");

        // refunds received minus everything paid (mint, TapeOut fees, gas for the settlements)
        uint256 paidIn = 3 * PRICE + PROTOCOL_FEE + TAPEOUT_FEE;
        assertEq(attacker.balance, startBalance - paidIn + NAND3_ALLOWANCE);
        assertLt(attacker.balance + 0, startBalance - gasBill, "the attacker ends below where it started");
        assertLt(NAND3_ALLOWANCE, 3 * PRICE, "the allowance is 85% of what the attacker paid for the transistors");
    }

    // ------------------------------------------------------------------ hostile callers

    function test_hostile_callerReentersWhileBeingRefunded_isBlocked() public {
        (uint256 chipId, MockKernel kernel) = _chipInKernel();
        _fundTank();
        ReentrantCaller caller = new ReentrantCaller(tank, address(kernel), true);

        vm.recordLogs();
        caller.run();
        (uint256[] memory counted, uint256[] memory paid) = _refundedLogs();

        assertTrue(caller.reentryBlocked());
        assertEq(counted.length, 1);
        assertEq(kernel.settles(), 1);
        assertEq(address(caller).balance, paid[0]);
        assertEq(tank.spent(chipId), paid[0]);
    }

    function test_hostile_callerThatRevertsOnRefund_revertsEverything() public {
        (uint256 chipId, MockKernel kernel) = _chipInKernel();
        _fundTank();

        ReentrantCaller bubbling = new ReentrantCaller(tank, address(kernel), false);
        vm.expectRevert(KeeperTank.RefundFailed.selector);
        bubbling.run();

        RejectingCaller rejecting = new RejectingCaller();
        vm.expectRevert(KeeperTank.RefundFailed.selector);
        rejecting.run(tank, address(kernel));

        assertEq(kernel.settles(), 0);
        assertEq(tank.spent(chipId), 0);
    }

    function test_callerThatCannotReceive_isFineWhenNothingIsOwed() public {
        (, MockKernel kernel) = _chipInKernel();
        _fundTank();
        vm.txGasPrice(0);
        RejectingCaller rejecting = new RejectingCaller();
        rejecting.run(tank, address(kernel));
        assertEq(kernel.settles(), 1);
    }

    // ------------------------------------------------------------------ several settlements in one transaction

    /// The 21,000 base cost is granted once per transaction, not once per call: a batching keeper is never
    /// refunded more gas for a call than that call (plus, for the first one, the transaction itself) consumed.
    function test_batch_baseCostIsGrantedOncePerTransaction() public {
        (uint256 chipA, MockKernel kernelA) = _chipInKernel();
        (uint256 chipB, MockKernel kernelB) = _chipInKernel();
        _fundTank();
        _topUp(chipA, 1 ether);
        _topUp(chipB, 1 ether);
        // reach the steady state first (the very first refund of a chip is 17,100 gas more expensive)
        _settleAs(keeper, address(kernelA));
        _settleAs(keeper, address(kernelB));

        MeteredBatch batch = new MeteredBatch();
        address[] memory kernels = new address[](3);
        kernels[0] = address(kernelA);
        kernels[1] = address(kernelB);
        kernels[2] = address(kernelA); // same chip twice: its `spent` slot is already dirty the second time

        vm.recordLogs();
        vm.prank(keeper, keeper);
        batch.run(tank, kernels);
        Vm.Gas memory g = vm.lastFrameGas();
        (uint256[] memory counted, uint256[] memory paid) = _refundedLogs();
        assertEq(counted.length, 3);

        uint256 billed = g.gasTotalUsed - uint256(int256(g.gasRefunded));
        assertLe(counted[0] + counted[1] + counted[2], billed, "counted more gas than the transaction was billed");
        assertLe(paid[0] + paid[1] + paid[2], billed * GASPRICE, "batch refunded more than its gas cost");
        assertEq(address(batch).balance, paid[0] + paid[1] + paid[2]);

        // first call: counted = what the call consumed + part of the 21,000 base cost
        assertGt(counted[0], batch.frameGas(0));
        assertLe(counted[0], batch.frameGas(0) + 21_000);
        // later calls: never more than the call itself consumed
        assertLe(counted[1], batch.frameGas(1));
        assertLe(counted[2], batch.frameGas(2));
        // and tight: on a repeat call the keeper is short by about 1,100 gas when the chip's `spent` slot
        // was already written in this transaction, and by 2,800 more when it was not
        assertLt(batch.frameGas(1) - counted[1], 4_500);
        assertLt(batch.frameGas(2) - counted[2], 1_700);

        // had every call been granted the full OVERHEAD, each repeat call would have been over-refunded
        uint256 extra = tank.OVERHEAD() - tank.OVERHEAD_REPEAT();
        assertGt(counted[1] + extra, batch.frameGas(1));
        assertGt(counted[2] + extra, batch.frameGas(2));
    }

    function test_batch_aRevertedCallDoesNotUseUpTheBaseGrant() public {
        (uint256 chipA, MockKernel failing) = _chipInKernel();
        (uint256 chipB, MockKernel working) = _chipInKernel();
        _fundTank();
        _topUp(chipA, 1 ether);
        _topUp(chipB, 1 ether);
        _settleAs(keeper, address(working));
        failing.setRevertMode(1);

        MeteredBatch batch = new MeteredBatch();
        address[] memory kernels = new address[](2);
        kernels[0] = address(failing);
        kernels[1] = address(working);

        vm.recordLogs();
        vm.prank(keeper, keeper);
        batch.run(tank, kernels);
        (uint256[] memory counted,) = _refundedLogs();

        assertFalse(batch.succeeded(0));
        assertTrue(batch.succeeded(1));
        assertEq(counted.length, 1);
        // the surviving call is the first refund of the transaction: it carries the base cost
        assertGt(counted[0], batch.frameGas(1));
        assertLe(counted[0], batch.frameGas(1) + 21_000);
    }

    function test_separateTransactions_eachGetTheBaseCost() public {
        (uint256 chipId, MockKernel kernel) = _chipInKernel();
        _fundTank();
        _topUp(chipId, 1 ether);
        _settleAs(keeper, address(kernel));

        Settled memory a = _settleAs(keeper, address(kernel));
        Settled memory b = _settleAs(keeper, address(kernel));
        assertEq(a.gasCounted, b.gasCounted, "identical transactions count identical gas");
        assertGt(a.gasCounted, a.txGas - 21_000, "the base cost is included");
        assertLe(a.gasCounted, a.txGasBilled);
    }

    // ------------------------------------------------------------------ paying in

    function test_topUp_addsToTheChipsAllowance() public {
        (uint256 chipId,) = _chipInKernel();
        vm.deal(user, 1 ether);

        vm.expectEmit(true, true, true, true, address(tank));
        emit ToppedUp(chipId, user, 0.25 ether);
        vm.prank(user);
        tank.topUp{value: 0.25 ether}(chipId);

        assertEq(tank.toppedUp(chipId), 0.25 ether);
        assertEq(tank.allowanceOf(chipId), NAND3_ALLOWANCE + 0.25 ether);
        assertEq(address(tank).balance, 0.25 ether);

        // top-ups accumulate, from anyone, and a zero top-up changes nothing
        address other = makeAddr("someone else");
        vm.deal(other, 1 ether);
        vm.prank(other);
        tank.topUp{value: 0.5 ether}(chipId);
        vm.prank(other);
        tank.topUp(chipId);
        assertEq(tank.toppedUp(chipId), 0.75 ether);
        assertEq(tank.remainingOf(chipId), NAND3_ALLOWANCE + 0.75 ether);
        assertEq(address(tank).balance, 0.75 ether);
    }

    function test_topUp_ofOneChip_doesNotTouchAnother() public {
        (uint256 chipA,) = _chipInKernel();
        (uint256 chipB,) = _chipInKernel();
        _topUp(chipA, 1 ether);
        assertEq(tank.toppedUp(chipA), 1 ether);
        assertEq(tank.toppedUp(chipB), 0);
        assertEq(tank.allowanceOf(chipB), NAND3_ALLOWANCE);
    }

    function test_receive_fromTheSplitter_isUnattributedBacking() public {
        (uint256 chipId,) = _chipInKernel();
        _mint(user, 0, 1000);

        vm.expectEmit(true, true, true, true, address(tank));
        emit Funded(address(splitter), 0.017 ether + 51_000_000_000_000); // 85% of 1003 transistors
        splitter.pull();

        assertEq(tank.toppedUp(chipId), 0);
    }

    function testFuzz_receive_neverRevertsForTheSplitter(uint96 amount, uint32 gasLimit) public {
        vm.deal(address(splitter), amount);
        // The Splitter path does no probing. With any value attached it even runs on the 2,300 gas stipend
        // alone (no gas forwarded at all), so the Splitter's payment to the tank cannot be starved.
        uint256 gas_ = bound(uint256(gasLimit), amount == 0 ? 3_000 : 0, 1_000_000);
        vm.prank(address(splitter));
        (bool ok,) = address(tank).call{value: amount, gas: gas_}("");
        assertTrue(ok);
        assertEq(address(tank).balance, amount);
    }

    function test_receive_fromTheSplitter_runsOnTheStipendAlone() public {
        vm.deal(address(splitter), 1 ether);
        vm.expectEmit(true, true, true, true, address(tank));
        emit Funded(address(splitter), 1 ether);
        vm.prank(address(splitter));
        (bool ok,) = address(tank).call{value: 1 ether, gas: 0}("");
        assertTrue(ok);
    }

    function test_receive_fromAnEoa_isUnattributedBacking() public {
        (uint256 chipId,) = _chipInKernel();
        vm.deal(user, 1 ether);

        vm.expectEmit(true, true, true, true, address(tank));
        emit Funded(user, 1 ether);
        vm.prank(user);
        (bool ok,) = address(tank).call{value: 1 ether}("");
        assertTrue(ok);

        assertEq(tank.toppedUp(chipId), 0);
        assertEq(address(tank).balance, 1 ether);
    }

    function test_receive_fromAKernel_isCreditedToItsChip() public {
        (uint256 chipId, MockKernel kernel) = _chipInKernel();
        vm.deal(address(kernel), 1 ether);

        vm.expectEmit(true, true, true, true, address(tank));
        emit ToppedUp(chipId, address(kernel), 0.4 ether);
        bool ok = kernel.pay(address(tank), 0.4 ether, 300_000);
        assertTrue(ok);

        assertEq(tank.toppedUp(chipId), 0.4 ether);
        assertEq(tank.allowanceOf(chipId), NAND3_ALLOWANCE + 0.4 ether);
    }

    /// With too little gas for the two probes the tank refuses the transfer; it never guesses.
    function test_receive_fromAContract_withTooLittleGas_reverts() public {
        (uint256 chipId, MockKernel kernel) = _chipInKernel();
        vm.deal(address(kernel), 1 ether);

        assertFalse(kernel.pay(address(tank), 0.4 ether, 190_000));
        assertFalse(kernel.pay(address(tank), 0.4 ether, 2_300));
        assertFalse(kernel.pay(address(tank), 0.4 ether, 0));
        assertEq(address(tank).balance, 0);
        assertEq(tank.toppedUp(chipId), 0);

        assertTrue(kernel.pay(address(tank), 0.4 ether, 200_000));
        assertEq(tank.toppedUp(chipId), 0.4 ether);
    }

    /// For every amount of gas a kernel forwards: the transfer either fails, or is credited to its chip.
    /// It is never accepted as unattributed.
    function test_receive_fromAKernel_isNeverSilentlyUnattributed() public {
        (uint256 chipId, MockKernel kernel) = _chipInKernel();
        vm.deal(address(kernel), 100 ether);
        uint256 credited;
        for (uint256 gasLimit = 0; gasLimit <= 400_000; gasLimit += 2_500) {
            bool ok = kernel.pay(address(tank), 1 ether, gasLimit);
            if (ok) credited += 1 ether;
            assertEq(tank.toppedUp(chipId), credited);
            assertEq(address(tank).balance, credited);
        }
        assertGt(credited, 0);
    }

    /// The same for a kernel whose chipId() refuses cheaply when it gets too little gas. Without the gas
    /// floor in receive() such a kernel's transfer could be accepted and not credited.
    function test_receive_fromAKernelWhoseChipIdNeedsGas_isNeverSilentlyUnattributed() public {
        uint256 chipId = _tapeout(user, NAND3, 3, 0, 2, 1);
        PickyKernel kernel = new PickyKernel(chipId);
        _give(chipId, address(kernel));
        vm.deal(address(kernel), 200 ether);

        uint256 credited;
        for (uint256 gasLimit = 0; gasLimit <= 400_000; gasLimit += 1_000) {
            bool ok = kernel.pay(address(tank), 1 ether, gasLimit);
            if (ok) credited += 1 ether;
            assertEq(tank.toppedUp(chipId), credited, "accepted without being credited to the kernel's chip");
            assertEq(address(tank).balance, credited);
        }
        assertGt(credited, 0);
    }

    function test_receive_fromAContractThatDoesNotHoldTheChip_isUnattributed() public {
        (uint256 chipId,) = _chipInKernel();
        LyingKernel liar = new LyingKernel(chipId);
        vm.deal(address(liar), 1 ether);

        vm.expectEmit(true, true, true, true, address(tank));
        emit Funded(address(liar), 1 ether);
        assertTrue(liar.pay(address(tank), 1 ether));
        assertEq(tank.toppedUp(chipId), 0);

        // pointing at a chip that does not exist
        LyingKernel nowhere = new LyingKernel(999);
        vm.deal(address(nowhere), 1 ether);
        assertTrue(nowhere.pay(address(tank), 1 ether));
        assertEq(tank.toppedUp(999), 0);
        assertEq(address(tank).balance, 2 ether);
    }

    function test_receive_fromAContractWithoutChipId_isUnattributed() public {
        SilentWallet wallet = new SilentWallet(); // fallback answers every call with empty data
        vm.deal(address(wallet), 1 ether);
        vm.expectEmit(true, true, true, true, address(tank));
        emit Funded(address(wallet), 1 ether);
        assertTrue(wallet.pay(address(tank), 1 ether, 300_000));

        ShortAnswerSender short = new ShortAnswerSender(); // answers chipId() with 31 bytes
        vm.deal(address(short), 1 ether);
        vm.expectEmit(true, true, true, true, address(tank));
        emit Funded(address(short), 1 ether);
        assertTrue(short.pay(address(tank), 1 ether));

        assertEq(address(tank).balance, 2 ether);
    }

    function test_receive_fromAContractWhoseChipIdBurnsGas_isBounded() public {
        GasTrapSender trap = new GasTrapSender();
        vm.deal(address(trap), 1 ether);

        vm.expectEmit(true, true, true, true, address(tank));
        emit Funded(address(trap), 1 ether);
        assertTrue(trap.pay(address(tank), 1 ether));
        // the probe is capped at 50,000 gas
        assertLt(vm.lastFrameGas().gasTotalUsed, 120_000);
    }

    // ------------------------------------------------------------------ nothing else takes OKB out

    function testFuzz_arbitraryCall_cannotTakeOkbOut(address caller, bytes calldata data, uint64 value) public {
        vm.assume(caller != address(tank));
        vm.assume(data.length < 4 || bytes4(data[:4]) != KeeperTank.settleAndRefund.selector);
        (uint256 chipId,) = _chipInKernel();
        _fundTank();
        _topUp(chipId, 1 ether);
        uint256 tankBefore = address(tank).balance;
        vm.deal(caller, value);

        vm.prank(caller);
        (bool ok,) = address(tank).call{value: value}(data);

        assertGe(address(tank).balance, tankBefore);
        if (ok) assertEq(address(tank).balance, tankBefore + value);
        assertEq(tank.spent(chipId), 0);
    }

    function testFuzz_settleAndRefund_ofARandomAddress_paysNothing(address caller, address kernel) public {
        (uint256 chipId, MockKernel real) = _chipInKernel();
        vm.assume(kernel != address(real));
        _fundTank();
        uint256 tankBefore = address(tank).balance;

        vm.prank(caller);
        (bool ok,) = address(tank).call(abi.encodeCall(KeeperTank.settleAndRefund, (kernel)));
        assertFalse(ok);
        assertEq(address(tank).balance, tankBefore);
        assertEq(tank.spent(chipId), 0);
    }
}
