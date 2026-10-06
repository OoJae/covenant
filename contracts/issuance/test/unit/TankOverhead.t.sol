// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";
import {LocalBase} from "../utils/LocalBase.sol";
import {KeeperTank} from "../../src/KeeperTank.sol";
import {MockKernel} from "../mocks/MockKernel.sol";
import {MeteredBatch} from "../mocks/Hostile.sol";

/// @notice Justifies KeeperTank.OVERHEAD and OVERHEAD_REPEAT against real transactions.
///
///         The suite runs in isolate mode: every top-level call below is executed as its own transaction,
///         so `vm.lastFrameGas()` reports the gas of the whole transaction, with the 21,000 base cost and
///         the calldata included and with EIP-3529 refunds settled. That is what a receipt's `gasUsed`
///         shows on-chain.
///
///         The tank measures gas from its first line to the end of the kernel call. Whatever the transaction
///         consumed beyond that window is "unmeasured", and the overhead constant must never exceed it.
contract TankOverheadTest is LocalBase {
    // Unmeasured execution gas of a paid refund in the steady state, on this exact bytecode.
    // 2,900 SSTORE + 6,800 CALL with value + 2,387 LOG4 + 300 reentrancy guard + 1,215 everything else.
    uint256 internal constant UNMEASURED_EXECUTION = 13_602;

    uint256 internal chipId;
    MockKernel internal kernel;

    function setUp() public {
        _deployLocal(maintainer);
        (chipId, kernel) = _chipInKernel();
        _mint(user, 0, 1_000_000);
        splitter.pull();
        vm.deal(user, user.balance + 1 ether);
        vm.prank(user);
        tank.topUp{value: 1 ether}(chipId);
    }

    function _calldataGas(address kernel_) internal pure returns (uint256 gas_) {
        bytes memory data = abi.encodeCall(KeeperTank.settleAndRefund, (kernel_));
        for (uint256 i = 0; i < data.length; i++) {
            gas_ += data[i] == 0 ? 4 : 16;
        }
    }

    /// @dev gas the transaction was billed for outside the tank's measured window
    function _unmeasured(Settled memory r, uint256 overhead) internal pure returns (uint256) {
        return r.txGasBilled - (r.gasCounted - overhead);
    }

    function test_isolateModeIsOn() public view {
        assertTrue(vm.isIsolateMode(), "this suite must run with isolate = true (see foundry.toml)");
    }

    /// The documented breakdown, pinned to the gas unit. If KeeperTank's code changes, this fails and the
    /// constants must be re-derived.
    function test_overhead_steadyState_isPinned() public {
        _settleAs(keeper, address(kernel)); // the first refund of a chip is dearer, see below
        Settled memory r = _settleAs(keeper, address(kernel));
        assertGt(r.paid, 0);

        uint256 unmeasured = _unmeasured(r, tank.OVERHEAD());
        uint256 calldataGas = _calldataGas(address(kernel));
        assertEq(unmeasured - 21_000 - calldataGas, UNMEASURED_EXECUTION);
        assertEq(uint256(2_900 + 6_800 + 2_387 + 300 + 1_215), UNMEASURED_EXECUTION);

        // OVERHEAD is below the unmeasured gas even if the transaction carried no calldata at all ...
        assertLe(tank.OVERHEAD(), 21_000 + UNMEASURED_EXECUTION);
        // ... and within 602 gas of it, so a keeper is left short by 602 gas plus its calldata.
        assertEq(21_000 + UNMEASURED_EXECUTION - tank.OVERHEAD(), 602);
        assertEq(r.txGasBilled - r.gasCounted, 602 + calldataGas);

        console2.log("steady state: transaction gas", r.txGasBilled);
        console2.log("steady state: gas counted by the tank", r.gasCounted);
        console2.log("steady state: unmeasured gas", unmeasured);
        console2.log("steady state: calldata gas (not counted)", calldataGas);
    }

    /// The very first refund ever paid for a chip writes `spent[chipId]` from zero: 20,000 instead of 2,900.
    /// The keeper absorbs that once per chip.
    function test_overhead_firstRefundOfAChip_isDearerBy17100() public {
        Settled memory r = _settleAs(keeper, address(kernel));
        assertGt(r.paid, 0);
        uint256 unmeasured = _unmeasured(r, tank.OVERHEAD());
        assertEq(unmeasured - 21_000 - _calldataGas(address(kernel)), UNMEASURED_EXECUTION + 17_100);
        assertLe(r.gasCounted, r.txGasBilled);
    }

    /// A repeat call in the same transaction: the part of the call that the window misses is at least
    /// OVERHEAD_REPEAT, with the chip's `spent` slot already dirty (the cheapest case).
    function test_overheadRepeat_isBelowWhatARepeatCallMisses() public {
        _settleAs(keeper, address(kernel));
        MeteredBatch batch = new MeteredBatch();
        address[] memory kernels = new address[](2);
        kernels[0] = address(kernel);
        kernels[1] = address(kernel);

        vm.recordLogs();
        vm.prank(keeper, keeper);
        batch.run(tank, kernels);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256[2] memory counted;
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(tank) && logs[i].topics[0] == REFUNDED_SIG) {
                (counted[n],) = abi.decode(logs[i].data, (uint256, uint256));
                n++;
            }
        }
        assertEq(n, 2);

        // what the second call cost the batching contract, minus the tank's measured window
        uint256 missed = batch.frameGas(1) - (counted[1] - tank.OVERHEAD_REPEAT());
        console2.log("repeat call: gas the window misses, as paid by the batching contract", missed);
        assertGe(missed, tank.OVERHEAD_REPEAT());
        assertLt(missed - tank.OVERHEAD_REPEAT(), 1_700);
        // the documented figure: steady state less the 2,800 saved on a dirty slot
        assertEq(UNMEASURED_EXECUTION - 2_800, 10_802);
        assertLe(tank.OVERHEAD_REPEAT(), 10_802);
    }

    /// Whatever the kernel's address (zero bytes are cheaper calldata) and workload, with a refund paid:
    /// counted gas + calldata gas never exceeds the gas billed.
    function testFuzz_overhead_neverExceedsUnmeasuredGas(address kernelAddr, uint32 burn) public {
        vm.assume(uint160(kernelAddr) > 0xffff && kernelAddr.code.length == 0);
        assumeNotForgeAddress(kernelAddr);
        vm.assume(kernelAddr != keeper && kernelAddr != user && kernelAddr != maintainer);

        uint256 id = _tapeout(user, NAND3, 3, 0, 2, 1);
        deployCodeTo("MockKernel.sol:MockKernel", abi.encode(id), kernelAddr);
        vm.prank(user);
        circuits.transferFrom(user, kernelAddr, id);
        vm.prank(user);
        tank.topUp{value: 0.5 ether}(id);
        MockKernel(payable(kernelAddr)).setBurnGas(uint256(burn) % 2_000_000);

        uint256 calldataGas = _calldataGas(kernelAddr);
        Settled memory first = _settleAs(keeper, kernelAddr);
        Settled memory steady = _settleAs(keeper, kernelAddr);
        assertGt(first.paid, 0);
        assertGt(steady.paid, 0);

        assertLe(first.gasCounted + calldataGas, first.txGasBilled);
        assertLe(steady.gasCounted + calldataGas, steady.txGasBilled);
        assertEq(steady.txGasBilled - steady.gasCounted - calldataGas, 602);
    }

    /// A kernel address made almost entirely of zero bytes: the cheapest calldata there is.
    function test_overhead_kernelAddressFullOfZeroBytes() public {
        address kernelAddr = address(uint160(0x010000));
        uint256 id = _tapeout(user, NAND3, 3, 0, 2, 1);
        deployCodeTo("MockKernel.sol:MockKernel", abi.encode(id), kernelAddr);
        vm.prank(user);
        circuits.transferFrom(user, kernelAddr, id);
        vm.prank(user);
        tank.topUp{value: 0.5 ether}(id);

        assertEq(_calldataGas(kernelAddr), 4 * 16 + 31 * 4 + 16);
        _settleAs(keeper, kernelAddr);
        Settled memory r = _settleAs(keeper, kernelAddr);
        assertGt(r.paid, 0);
        assertLe(r.gasCounted, r.txGasBilled);
        assertEq(r.txGasBilled - r.gasCounted, 602 + _calldataGas(kernelAddr));
    }

    /// An EIP-2930 access list moves gas from the measured window into the (uncounted) intrinsic cost.
    /// It can only make the keeper worse off, never better.
    function test_overhead_withAnAccessList() public {
        _settleAs(keeper, address(kernel));
        Settled memory plain = _settleAs(keeper, address(kernel));

        VmSafe.AccessListItem[] memory list = new VmSafe.AccessListItem[](3);
        bytes32[] memory tankSlots = new bytes32[](6);
        tankSlots[0] = bytes32(uint256(0)); // circuits
        tankSlots[1] = bytes32(uint256(2)); // mintPrice
        tankSlots[2] = keccak256(abi.encode(chipId, uint256(3))); // toppedUp[chipId]
        tankSlots[3] = keccak256(abi.encode(chipId, uint256(4))); // spent[chipId]
        tankSlots[4] = keccak256(abi.encode(chipId, uint256(5))); // burned cache
        tankSlots[5] = bytes32(uint256(1)); // transistors (never read by settleAndRefund: pure cost)
        list[0] = VmSafe.AccessListItem({target: address(tank), storageKeys: tankSlots});
        list[1] = VmSafe.AccessListItem({target: address(kernel), storageKeys: new bytes32[](0)});
        list[2] = VmSafe.AccessListItem({target: address(circuits), storageKeys: new bytes32[](0)});
        vm.accessList(list);
        Settled memory listed = _settleAs(keeper, address(kernel));
        vm.noAccessList();

        assertGt(listed.paid, 0);
        assertLt(listed.gasCounted, plain.gasCounted, "pre-warmed reads shrink the measured window");
        assertLe(listed.gasCounted, listed.txGasBilled);
        assertGe(
            listed.txGasBilled - listed.gasCounted, plain.txGasBilled - plain.gasCounted, "an access list never helps"
        );
        console2.log("with access list: billed", listed.txGasBilled, "counted", listed.gasCounted);
    }

    /// The storage layout the access-list test relies on (and that off-chain tools may read).
    function test_storageLayout() public {
        _settleAs(keeper, address(kernel));
        assertEq(address(uint160(uint256(vm.load(address(tank), bytes32(uint256(0)))))), address(circuits));
        assertEq(address(uint160(uint256(vm.load(address(tank), bytes32(uint256(1)))))), address(transistors));
        assertEq(uint256(vm.load(address(tank), bytes32(uint256(2)))), PRICE);
        assertEq(uint256(vm.load(address(tank), keccak256(abi.encode(chipId, uint256(3))))), 1 ether);
        assertEq(uint256(vm.load(address(tank), keccak256(abi.encode(chipId, uint256(4))))), tank.spent(chipId));
        assertEq(uint256(vm.load(address(tank), keccak256(abi.encode(chipId, uint256(5))))), 3 + 1);
    }

    /// A keeper that calls through its own contract: the first refund of the transaction still carries the
    /// base cost and still stays within what the call and the transaction consumed.
    function test_overhead_whenTheCallerIsAContract() public {
        _settleAs(keeper, address(kernel));
        MeteredBatch batch = new MeteredBatch();
        address[] memory kernels = new address[](1);
        kernels[0] = address(kernel);

        vm.recordLogs();
        vm.prank(keeper, keeper);
        batch.run(tank, kernels);
        Vm.Gas memory g = vm.lastFrameGas();
        (uint256 counted, uint256 paid) = _lastRefunded(vm.getRecordedLogs());

        assertGt(paid, 0);
        assertLe(counted, batch.frameGas(0) + 21_000);
        assertLe(counted, g.gasTotalUsed - uint256(int256(g.gasRefunded)));
        assertEq(address(batch).balance, paid);
    }
}
