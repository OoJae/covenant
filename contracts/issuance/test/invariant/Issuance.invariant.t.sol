// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Splitter} from "../../src/Splitter.sol";
import {KeeperTank} from "../../src/KeeperTank.sol";
import {MockFactory, MockTransistors} from "../mocks/MockTapeOut.sol";
import {ToggleMaintainer} from "../mocks/Hostile.sol";
import {Handler} from "./Handler.sol";

/// @notice Stateful fuzzing of the whole issuance system: random mints, pulls, tape-outs, settlements,
///         top-ups, donations, and a maintainer that accepts or refuses at random.
///         After every sequence the contracts must agree with the handler's independent ledger.
contract IssuanceInvariantTest is Test {
    uint256 internal constant PRICE = 0.00002 ether;

    Handler internal handler;
    Splitter internal splitter;
    KeeperTank internal tank;
    MockTransistors internal transistors;
    ToggleMaintainer internal maintainer;

    function setUp() public {
        MockFactory factory = new MockFactory();
        maintainer = new ToggleMaintainer();
        maintainer.setAccept(true);
        splitter = new Splitter{value: factory.deployFee()}(
            address(factory), address(maintainer), bytes20(hex"a1b2c3d4e5f60718293a4b5c6d7e8f9001234567")
        );
        tank = KeeperTank(payable(splitter.TANK()));
        transistors = MockTransistors(splitter.TRANSISTORS());

        handler = new Handler(splitter, maintainer);
        targetContract(address(handler));

        // The fuzzer picks transaction senders from addresses it has seen, contracts included. A contract
        // has no key and can never send a transaction, and forge funds a sender for gas, which would show
        // up as OKB from nowhere in the ledgers below. So the system's own contracts are not senders.
        excludeSender(address(splitter));
        excludeSender(address(tank));
        excludeSender(splitter.REGISTRY());
        excludeSender(address(transistors));
        excludeSender(splitter.CIRCUITS());
        excludeSender(address(maintainer));
        excludeSender(address(factory));
        excludeSender(address(handler));
        for (uint256 i = 0; i < 4; i++) {
            excludeSender(handler.actors(i));
        }
    }

    /// Every wei of proceeds and stray OKB is exactly one of: still owed by TapeOut, waiting in the splitter,
    /// or paid to one of the two payees.
    function invariant_everyWeiOfProceedsIsAccountedFor() public view {
        uint256 cameIn = handler.ghostProceeds() + handler.ghostStray();
        uint256 isSomewhere = transistors.owed(address(splitter)) + address(splitter).balance
            + handler.ghostTankFromSplitter() + address(maintainer).balance;
        assertEq(cameIn, isSomewhere);

        // the splitter never holds less than the maintainer's credit
        assertGe(address(splitter).balance, splitter.maintainerOwed());
    }

    /// Over any number of pulls the two shares stay 85 / 15, off only by rounding dust that always lands in
    /// the tank: less than one wei per pull.
    function invariant_sharesStay85_15() public view {
        uint256 d = handler.ghostDistributed();
        uint256 n = handler.ghostPulls();
        uint256 toTank = handler.ghostTankFromSplitter();
        uint256 toMaintainer = handler.ghostMaintainerShare();

        assertEq(toTank + toMaintainer, d);
        assertLe(toMaintainer * 10_000, d * 1500);
        assertGt((toMaintainer + n) * 10_000 + 1, d * 1500);
        assertGe(toTank * 10_000, d * 8500);
        assertLe(toTank * 10_000, d * 8500 + n * 10_000);

        // maintainer: what it holds plus what it is still owed is its whole share
        assertEq(address(maintainer).balance + splitter.maintainerOwed(), toMaintainer);
    }

    /// The tank's balance is everything that came in minus everything refunded; refunds equal the sum of
    /// `spent`; no chip spent more than its allowance; and all refunds together never exceed the gas counted
    /// at the capped price.
    function invariant_tankLedger() public view {
        assertEq(address(tank).balance, handler.ghostTankIn() - handler.ghostRefunded());
        assertLe(handler.ghostRefunded(), handler.ghostGasValue());

        uint256 spentTotal;
        uint256 burnAllowanceTotal;
        uint256 n = handler.chipCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 chipId = handler.chipAt(i);
            uint256 spent = tank.spent(chipId);
            spentTotal += spent;

            assertEq(tank.burnedOf(chipId), handler.ghostChipBurned(chipId), "burn count");
            assertEq(tank.toppedUp(chipId), handler.ghostChipToppedUp(chipId), "top-ups");
            assertEq(spent, handler.ghostChipRefunded(chipId), "spent");
            uint256 allowance =
                handler.ghostChipBurned(chipId) * PRICE * 8500 / 10_000 + handler.ghostChipToppedUp(chipId);
            assertEq(tank.allowanceOf(chipId), allowance, "allowance");
            assertLe(spent, allowance, "a chip spent more than its allowance");
            assertEq(tank.remainingOf(chipId), allowance - spent, "remaining");

            burnAllowanceTotal += handler.ghostChipBurned(chipId) * PRICE * 8500 / 10_000;
        }
        assertEq(spentTotal, handler.ghostRefunded());

        // allowances created by burns never exceed 85% of what was paid for transistors
        assertLe(handler.ghostBurned(), handler.ghostMinted());
        assertLe(burnAllowanceTotal, handler.ghostProceeds() * 8500 / 10_000);
    }
}
