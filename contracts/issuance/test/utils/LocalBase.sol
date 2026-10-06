// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {Splitter} from "../../src/Splitter.sol";
import {KeeperTank} from "../../src/KeeperTank.sol";
import {TeamRegistry} from "../../src/TeamRegistry.sol";
import {MockFactory, MockTransistors, MockCircuits} from "../mocks/MockTapeOut.sol";
import {MockKernel} from "../mocks/MockKernel.sol";

/// @notice Deploys the issuance contracts against the small TapeOut imitation. No network needed.
abstract contract LocalBase is Test {
    // The 3-NAND netlist that tapes out on the real processor contracts (2 inputs, 1 output).
    bytes internal constant NAND3 = hex"000000020000030000000400000400000005000005";

    bytes20 internal constant COMMIT = hex"a1b2c3d4e5f60718293a4b5c6d7e8f9001234567";

    // X Layer on 2026-10-04: base fee 0.02 gwei, typical tip 1 wei.
    uint256 internal constant BASEFEE = 0.02 gwei;
    uint256 internal constant GASPRICE = 0.02 gwei + 1;

    uint256 internal constant PRICE = 0.00002 ether;
    uint256 internal constant PROTOCOL_FEE = 0.00066 ether;
    uint256 internal constant TAPEOUT_FEE = 0.0013 ether;

    bytes32 internal constant REFUNDED_SIG = keccak256("Refunded(uint256,address,address,uint256,uint256)");

    MockFactory internal factory;
    address internal maintainer = makeAddr("maintainer");
    address internal keeper = makeAddr("keeper");
    address internal user = makeAddr("user");

    Splitter internal splitter;
    KeeperTank internal tank;
    TeamRegistry internal registry;
    MockTransistors internal transistors;
    MockCircuits internal circuits;

    function _deployLocal(address maintainer_) internal {
        factory = new MockFactory();
        splitter = new Splitter{value: factory.deployFee()}(address(factory), maintainer_, COMMIT);
        tank = KeeperTank(payable(splitter.TANK()));
        registry = TeamRegistry(splitter.REGISTRY());
        transistors = MockTransistors(splitter.TRANSISTORS());
        circuits = MockCircuits(splitter.CIRCUITS());

        vm.fee(BASEFEE);
        vm.txGasPrice(GASPRICE);
        vm.deal(user, 1000 ether);
    }

    /// @dev mints `amount` transistors of `id` to `who` at list price plus TapeOut's per-call fee
    function _mint(address who, uint256 id, uint256 amount) internal {
        vm.deal(who, who.balance + PRICE * amount + PROTOCOL_FEE);
        vm.prank(who);
        transistors.mint{value: PRICE * amount + PROTOCOL_FEE}(id, amount);
    }

    /// @dev mints what `nl` burns, tapes it out from `who`, returns the new chip id
    function _tapeout(address who, bytes memory nl, uint256 nNand, uint256 nLatch, uint32 nIn, uint32 nOut)
        internal
        returns (uint256 chipId)
    {
        if (nNand != 0) _mint(who, 0, nNand);
        if (nLatch != 0) _mint(who, 1, nLatch);
        vm.deal(who, who.balance + TAPEOUT_FEE);
        vm.prank(who);
        chipId = circuits.tapeout{value: TAPEOUT_FEE}(nl, nIn, nOut);
    }

    /// @dev a 3-NAND chip held by a fresh MockKernel
    function _chipInKernel() internal returns (uint256 chipId, MockKernel kernel) {
        chipId = _tapeout(user, NAND3, 3, 0, 2, 1);
        kernel = new MockKernel(chipId);
        vm.prank(user);
        circuits.transferFrom(user, address(kernel), chipId);
    }

    /// @dev `n` NAND records that are valid as a netlist with 2 inputs (each gate reads the two inputs)
    function _nands(uint256 n) internal pure returns (bytes memory nl) {
        for (uint256 i = 0; i < n; i++) {
            nl = bytes.concat(nl, hex"00000002000003");
        }
    }

    struct Settled {
        uint256 gasCounted; // `gasUsed` in the Refunded event
        uint256 paid; // `paid` in the Refunded event
        uint256 txGas; // gas the whole transaction consumed, intrinsic gas included, before refunds
        uint256 txGasBilled; // the same after EIP-3529 refunds: what the sender is charged for
    }

    /// @dev One real transaction from `caller` (an EOA that is also tx.origin) to settleAndRefund.
    function _settleAs(address caller, address kernel) internal returns (Settled memory r) {
        vm.recordLogs();
        vm.prank(caller, caller);
        tank.settleAndRefund(kernel);
        Vm.Gas memory g = vm.lastFrameGas();
        (r.gasCounted, r.paid) = _lastRefunded(vm.getRecordedLogs());
        r.txGas = g.gasTotalUsed;
        r.txGasBilled = g.gasTotalUsed - uint256(int256(g.gasRefunded));
    }

    function _lastRefunded(Vm.Log[] memory logs) internal view returns (uint256 gasCounted, uint256 paid) {
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(tank) && logs[i].topics[0] == REFUNDED_SIG) {
                (gasCounted, paid) = abi.decode(logs[i].data, (uint256, uint256));
                found = true;
            }
        }
        require(found, "no Refunded event");
    }

    function _refundPrice() internal view returns (uint256) {
        uint256 cap = block.basefee + tank.MAX_TIP();
        return tx.gasprice < cap ? tx.gasprice : cap;
    }
}
