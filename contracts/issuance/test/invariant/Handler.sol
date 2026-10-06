// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {Splitter} from "../../src/Splitter.sol";
import {KeeperTank} from "../../src/KeeperTank.sol";
import {MockTransistors, MockCircuits} from "../mocks/MockTapeOut.sol";
import {MockKernel} from "../mocks/MockKernel.sol";
import {ToggleMaintainer} from "../mocks/Hostile.sol";

/// @notice Drives the whole issuance system with random actions and keeps an independent ledger ("ghosts")
///         of every wei that should have moved. The invariant suite compares the contracts with the ledger.
contract Handler is Test {
    uint256 internal constant PRICE = 0.00002 ether;
    uint256 internal constant PROTOCOL_FEE = 0.00066 ether;
    uint256 internal constant TAPEOUT_FEE = 0.0013 ether;
    bytes32 internal constant REFUNDED_SIG = keccak256("Refunded(uint256,address,address,uint256,uint256)");

    Splitter public splitter;
    KeeperTank public tank;
    MockTransistors public transistors;
    MockCircuits public circuits;
    ToggleMaintainer public maintainer;

    address[] public actors;
    uint256[] public chips;
    MockKernel[] public kernels;

    // ---- the independent ledger ----
    uint256 public ghostMinted; // transistors sold
    uint256 public ghostBurned; // transistors burned by tape-outs
    uint256 public ghostProceeds; // wei paid for transistors at list price
    uint256 public ghostStray; // wei sent straight to the splitter
    uint256 public ghostDistributed; // wei the splitter has split so far
    uint256 public ghostPulls; // pulls that split something
    uint256 public ghostTankFromSplitter;
    uint256 public ghostMaintainerShare; // pushed or credited
    uint256 public ghostTankIn; // every wei that ever entered the tank
    uint256 public ghostRefunded; // every wei the tank ever paid out
    uint256 public ghostGasValue; // sum of (gas counted * refund price) over all settlements
    uint256 public ghostSettles;
    mapping(uint256 chipId => uint256) public ghostChipBurned;
    mapping(uint256 chipId => uint256) public ghostChipToppedUp;
    mapping(uint256 chipId => uint256) public ghostChipRefunded;

    constructor(Splitter splitter_, ToggleMaintainer maintainer_) {
        splitter = splitter_;
        tank = KeeperTank(payable(splitter_.TANK()));
        transistors = MockTransistors(splitter_.TRANSISTORS());
        circuits = MockCircuits(splitter_.CIRCUITS());
        maintainer = maintainer_;
        for (uint256 i = 0; i < 4; i++) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
        }
    }

    function chipCount() external view returns (uint256) {
        return chips.length;
    }

    function chipAt(uint256 i) external view returns (uint256) {
        return chips[i];
    }

    // ------------------------------------------------------------------ actions

    function mint(uint256 actorSeed, bool latch, uint256 amount) external {
        amount = bound(amount, 1, 50_000);
        _mint(actors[actorSeed % actors.length], latch ? 1 : 0, amount);
    }

    function pull(uint256 callerSeed) external {
        uint256 pending = transistors.owed(address(splitter)) + address(splitter).balance - splitter.maintainerOwed();
        uint256 tankBefore = address(tank).balance;
        uint256 maintainerBefore = address(maintainer).balance;
        uint256 creditBefore = splitter.maintainerOwed();

        vm.prank(actors[callerSeed % actors.length]);
        splitter.pull();

        uint256 toTank = address(tank).balance - tankBefore;
        uint256 toMaintainer =
            (address(maintainer).balance - maintainerBefore) + (splitter.maintainerOwed() - creditBefore);

        // every pull, taken on its own
        assertEq(toTank + toMaintainer, pending, "pull: payouts != amount");
        assertEq(toMaintainer, pending * 1500 / 10_000, "pull: maintainer share");
        assertEq(transistors.owed(address(splitter)), 0, "pull: proceeds left behind");
        assertEq(address(splitter).balance, splitter.maintainerOwed(), "pull: splitter keeps more than the credit");

        if (pending != 0) ghostPulls++;
        ghostDistributed += pending;
        ghostTankFromSplitter += toTank;
        ghostMaintainerShare += toMaintainer;
        ghostTankIn += toTank;
    }

    function tapeout(uint256 actorSeed, uint8 nNand, uint8 nLatch, bool withRef) external {
        address who = actors[actorSeed % actors.length];
        uint256 nn = uint256(nNand) % 40;
        uint256 nl = uint256(nLatch) % 8;
        bool ref = withRef && chips.length != 0;
        if (nn + nl == 0 && !ref) nn = 1;

        bytes memory netlist;
        for (uint256 i = 0; i < nl; i++) {
            netlist = bytes.concat(netlist, hex"01000002");
        }
        for (uint256 i = 0; i < nn; i++) {
            netlist = bytes.concat(netlist, hex"00000002000003");
        }
        if (ref) {
            netlist = bytes.concat(
                netlist,
                abi.encodePacked(
                    uint8(2), address(circuits), uint64(chips[0]), uint8(2), uint8(1), uint24(2), uint24(3)
                )
            );
        }

        if (nn != 0) _mint(who, 0, nn);
        if (nl != 0) _mint(who, 1, nl);
        vm.deal(who, who.balance + TAPEOUT_FEE);
        vm.startPrank(who);
        uint256 chipId = circuits.tapeout{value: TAPEOUT_FEE}(netlist, 2, 1);
        MockKernel kernel = new MockKernel(chipId);
        circuits.transferFrom(who, address(kernel), chipId);
        vm.stopPrank();

        chips.push(chipId);
        kernels.push(kernel);
        ghostBurned += nn + nl;
        ghostChipBurned[chipId] = nn + nl;
    }

    function settle(uint256 kernelSeed, uint256 callerSeed, uint64 baseFee, uint64 tip, uint32 burn) external {
        if (kernels.length == 0) return;
        MockKernel kernel = kernels[kernelSeed % kernels.length];
        address caller = actors[callerSeed % actors.length];
        uint256 chipId = chips[kernelSeed % kernels.length];

        uint256 fee = bound(uint256(baseFee), 0, 200 gwei);
        uint256 gasPrice = fee + bound(uint256(tip), 0, 20 gwei);
        vm.fee(fee);
        vm.txGasPrice(gasPrice);
        kernel.setBurnGas(uint256(burn) % 300_000);

        uint256 remainingBefore = tank.remainingOf(chipId);
        uint256 tankBefore = address(tank).balance;
        uint256 callerBefore = caller.balance;
        uint256 settlesBefore = kernel.settles();

        vm.recordLogs();
        vm.prank(caller, caller);
        tank.settleAndRefund(address(kernel));
        (uint256 counted, uint256 paid) = _refunded(vm.getRecordedLogs());

        uint256 cap = fee + tank.MAX_TIP();
        uint256 price = gasPrice < cap ? gasPrice : cap;
        assertLe(paid, counted * price, "settle: refund above gas counted at the capped price");
        assertLe(paid, remainingBefore, "settle: refund above the chip's remaining allowance");
        assertLe(paid, tankBefore, "settle: refund above the tank's balance");
        assertEq(caller.balance - callerBefore, paid, "settle: caller not paid what the event says");
        assertEq(tankBefore - address(tank).balance, paid, "settle: tank paid something else");
        assertEq(kernel.settles(), settlesBefore + 1, "settle: kernel not settled");

        ghostRefunded += paid;
        ghostChipRefunded[chipId] += paid;
        ghostGasValue += counted * price;
        ghostSettles++;

        // The price applied to the settlement above. The fuzzer's own calls into this handler are not part
        // of the system under test and must not be priced (forge would fund their senders for gas).
        vm.txGasPrice(0);
        vm.fee(0);
    }

    function topUp(uint256 chipSeed, uint256 actorSeed, uint64 amount) external {
        if (chips.length == 0) return;
        uint256 chipId = chips[chipSeed % chips.length];
        address who = actors[actorSeed % actors.length];
        vm.deal(who, who.balance + amount);
        vm.prank(who);
        tank.topUp{value: amount}(chipId);
        ghostChipToppedUp[chipId] += amount;
        ghostTankIn += amount;
    }

    /// @dev a kernel pays the tank with a plain transfer: must be credited to its own chip
    function kernelPays(uint256 kernelSeed, uint64 amount) external {
        if (kernels.length == 0) return;
        MockKernel kernel = kernels[kernelSeed % kernels.length];
        uint256 chipId = chips[kernelSeed % kernels.length];
        vm.deal(address(kernel), address(kernel).balance + amount);
        bool ok = kernel.pay(address(tank), amount, 300_000);
        assertTrue(ok, "kernelPays: refused");
        ghostChipToppedUp[chipId] += amount;
        ghostTankIn += amount;
    }

    function donateToSplitter(uint256 actorSeed, uint64 amount) external {
        address who = actors[actorSeed % actors.length];
        vm.deal(who, who.balance + amount);
        vm.prank(who);
        (bool ok,) = address(splitter).call{value: amount}("");
        assertTrue(ok);
        ghostStray += amount;
    }

    function donateToTank(uint256 actorSeed, uint64 amount) external {
        address who = actors[actorSeed % actors.length];
        vm.deal(who, who.balance + amount);
        vm.prank(who);
        (bool ok,) = address(tank).call{value: amount}("");
        assertTrue(ok);
        ghostTankIn += amount;
    }

    function setMaintainerAccepts(bool accept) external {
        maintainer.setAccept(accept);
    }

    function claimMaintainer(uint256 callerSeed) external {
        uint256 owed = splitter.maintainerOwed();
        if (owed == 0 || !maintainer.accept()) return;
        uint256 before = address(maintainer).balance;
        vm.prank(actors[callerSeed % actors.length]);
        splitter.claimMaintainer();
        assertEq(address(maintainer).balance - before, owed, "claim: wrong amount");
        assertEq(splitter.maintainerOwed(), 0, "claim: credit left");
    }

    // ------------------------------------------------------------------ internals

    function _mint(address who, uint256 id, uint256 amount) internal {
        vm.deal(who, who.balance + PRICE * amount + PROTOCOL_FEE);
        vm.prank(who);
        transistors.mint{value: PRICE * amount + PROTOCOL_FEE}(id, amount);
        ghostMinted += amount;
        ghostProceeds += PRICE * amount;
    }

    function _refunded(Vm.Log[] memory logs) internal view returns (uint256 counted, uint256 paid) {
        uint256 n;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(tank) && logs[i].topics[0] == REFUNDED_SIG) {
                (counted, paid) = abi.decode(logs[i].data, (uint256, uint256));
                n++;
            }
        }
        assertEq(n, 1, "settle: expected exactly one Refunded event");
    }
}
