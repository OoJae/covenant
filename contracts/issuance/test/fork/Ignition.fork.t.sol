// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {XLayerFork, ICpuEval} from "./XLayerFork.sol";
import {Story} from "../../script/lib/Story.sol";
import {Splitter} from "../../src/Splitter.sol";
import {KeeperTank} from "../../src/KeeperTank.sol";
import {TeamRegistry} from "../../src/TeamRegistry.sol";
import {ICircuitFactory, ICircuits, ITransistors} from "../../src/interfaces/ITapeOut.sol";
import {MockKernel} from "../mocks/MockKernel.sol";
import {ReentrantKernel, ToggleMaintainer, LyingKernel, SilentWallet} from "../mocks/Hostile.sol";

interface IFactoryAdmin {
    function owner() external view returns (address);
    function upgradeCircuits(address newImpl) external;
    function cpuCount() external view returns (uint256);
    function cpuAt(uint256 i) external view returns (address);
    function protocolWallet() external view returns (address);
    function isSealed() external view returns (bool);
}

/// @dev What a hostile TapeOut logic upgrade could look like: every netlist reads as 1,000 NAND gates,
///      everything else behaves as before.
contract InflatingCircuitsLogic {
    address internal immutable PREVIOUS;

    constructor(address previous) {
        PREVIOUS = previous;
    }

    function netlist(uint256) external pure returns (bytes memory nl) {
        nl = new bytes(7 * 1000);
    }

    fallback() external {
        address previous = PREVIOUS;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), previous, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

/// @notice The issuance contracts against the real TapeOut factory, on X Layer forked at block 72,370,000.
contract IgnitionForkTest is XLayerFork {
    event Pulled(uint256 toTank, uint256 toMaintainer);
    event ToppedUp(uint256 indexed chipId, address indexed from, uint256 amount);
    event Funded(address indexed from, uint256 amount);

    uint256 internal cpuCountBefore;

    function setUp() public {
        _fork();
        cpuCountBefore = IFactoryAdmin(FACTORY).cpuCount();

        splitter = _ignite(maintainer);
        tank = KeeperTank(payable(splitter.TANK()));
        registry = TeamRegistry(splitter.REGISTRY());
        transistors = ITransistors(splitter.TRANSISTORS());
        circuits = ICircuits(splitter.CIRCUITS());
        vm.deal(user, 100 ether);
    }

    // ------------------------------------------------------------------ 1. the processor

    function test_fork_liveFactsThisSuiteAssumes() public view {
        assertEq(ICircuitFactory(FACTORY).deployFee(), 0.0066 ether);
        assertEq(ICircuitFactory(FACTORY).protocolFee(), 0.00066 ether);
        assertFalse(IFactoryAdmin(FACTORY).isSealed(), "the story says TapeOut's owner can upgrade processor logic");
        assertTrue(IFactoryAdmin(FACTORY).owner() != address(0));
        assertEq(block.basefee, 0.02 gwei);
    }

    function test_fork_ignite_createsTheProcessorAsDescribed() public view {
        // registered with the real factory, as the newest processor
        assertTrue(ICircuitFactory(FACTORY).isCPU(address(circuits)));
        assertEq(IFactoryAdmin(FACTORY).cpuCount(), cpuCountBefore + 1);
        assertEq(IFactoryAdmin(FACTORY).cpuAt(cpuCountBefore), address(circuits));

        // the five parameters
        assertEq(transistors.creator(), address(splitter));
        assertEq(transistors.supplyCap(), 67_108_864);
        assertEq(transistors.mintPrice(), 20_000_000_000_000);
        assertEq(transistors.cpuName(), "Covenant");
        assertEq(transistors.cpuSymbol(), "CVNT");
        assertEq(transistors.minted(), 0);

        // the pair, and TapeOut's own fees as the story states them
        assertEq(transistors.circuits(), address(circuits));
        assertEq(circuits.transistors(), address(transistors));
        assertEq(transistors.protocolFee(), 0.00066 ether);
        assertEq(circuits.TAPEOUT_FEE(), 0.0013 ether);

        // the payees
        assertEq(splitter.TRANSISTORS(), address(transistors));
        assertEq(splitter.CIRCUITS(), address(circuits));
        assertEq(splitter.MAINTAINER(), maintainer);
        assertEq(tank.SPLITTER(), address(splitter));
        assertEq(tank.circuits(), address(circuits));
        assertEq(tank.transistors(), address(transistors));
        assertEq(tank.mintPrice(), 20_000_000_000_000);
        assertEq(tank.ALLOWANCE_BPS(), splitter.TANK_BPS());

        // the registry starts with the account that sent the creation (here this test contract)
        assertEq(registry.count(), 1);
        (address founder, string memory role, uint256 listedAt) = registry.at(0);
        assertEq(founder, address(this));
        assertEq(role, "deployer");
        assertEq(listedAt, block.timestamp);
        assertTrue(registry.isTeam(address(this)));

        // exactly the deploy fee was paid; nothing is stranded anywhere
        assertEq(address(splitter).balance, 0);
        assertEq(ICircuitFactory(FACTORY).owed(address(splitter)), 0);
        assertEq(transistors.owed(address(splitter)), 0);
    }

    function test_fork_ignite_storyIsByteForByteTheTemplate() public view {
        string memory expected = Story.expected(address(splitter), address(tank), maintainer, address(registry), COMMIT);
        string memory onChain = transistors.story();

        bytes memory a = bytes(onChain);
        bytes memory b = bytes(expected);
        assertEq(a.length, b.length, "story length");
        for (uint256 i = 0; i < a.length; i++) {
            if (a[i] != b[i]) revert(string.concat("story differs at byte ", vm.toString(i)));
        }
        assertEq(onChain, expected);

        // printable ASCII, no trailing newline
        for (uint256 i = 0; i < a.length; i++) {
            assertTrue(uint8(a[i]) >= 0x20 && uint8(a[i]) <= 0x7e, "non-printable byte in story");
        }
        assertEq(a[a.length - 1], bytes1("."));

        // what TapeOut's own site shows of it stands alone: no address to hide, no URL to rewrite
        string memory shown = Story.shown(onChain);
        assertEq(bytes(shown).length, 600);
        assertFalse(vm.contains(shown, "0x"));
        assertFalse(vm.contains(shown, "http"));

        console2.log("STORY (", a.length, "bytes ):");
        console2.log(onChain);
        console2.log("FIRST 600 CHARACTERS:");
        console2.log(shown);
    }

    function test_fork_ignite_gas() public view {
        console2.log("Splitter deployment, whole transaction (gas):", igniteGas);
        console2.log("  at the fork block's price (wei):", igniteGas * gasPrice);
        // far below X Layer's block gas limit, and nowhere near a 16.7M per-transaction cap
        assertLt(igniteGas, 8_000_000);
    }

    // ------------------------------------------------------------------ 2. mint and pull

    function test_fork_mint_thenPull_splits85_15() public {
        _mint(user, 0, 1234);
        _mint(user, 1, 77);
        assertEq(transistors.balanceOf(user, 0), 1234);
        assertEq(transistors.balanceOf(user, 1), 77);
        assertEq(transistors.minted(), 1311);
        uint256 proceeds = 1311 * PRICE;
        assertEq(transistors.owed(address(splitter)), proceeds);

        vm.expectEmit(true, true, true, true, address(splitter));
        emit Pulled(proceeds * 85 / 100, proceeds * 15 / 100);
        vm.prank(makeAddr("anyone"));
        splitter.pull();

        assertEq(address(tank).balance, proceeds * 85 / 100);
        assertEq(maintainer.balance, proceeds * 15 / 100);
        assertEq(address(tank).balance + maintainer.balance, proceeds);
        assertEq(address(splitter).balance, 0);
        assertEq(transistors.owed(address(splitter)), 0);

        // a second pull with nothing owed does not revert and moves nothing
        vm.recordLogs();
        splitter.pull();
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(address(tank).balance, proceeds * 85 / 100);
        assertEq(maintainer.balance, proceeds * 15 / 100);
    }

    function test_fork_pull_dustGoesToTheTank() public {
        _mint(user, 0, 1);
        vm.deal(address(splitter), 7); // 7 stray wei on top of one transistor's price
        uint256 amount = PRICE + 7;

        splitter.pull();

        assertEq(maintainer.balance, amount * 1500 / 10_000); // 3,000,000,000,001 (exact share ends in .05)
        assertEq(address(tank).balance, amount - maintainer.balance);
        assertEq(address(tank).balance, 17_000_000_000_006); // exact share ends in .95
        assertEq(address(tank).balance + maintainer.balance, amount);
    }

    function testFuzz_fork_pull_conservation(uint24 nNand, uint24 nLatch, uint64 stray) public {
        uint256 a = bound(uint256(nNand), 0, 2_000_000);
        uint256 b = bound(uint256(nLatch), 0, 2_000_000);
        if (a != 0) _mint(user, 0, a);
        if (b != 0) _mint(user, 1, b);
        vm.deal(address(splitter), stray);
        uint256 amount = (a + b) * PRICE + stray;

        splitter.pull();

        uint256 toMaintainer = maintainer.balance;
        uint256 toTank = address(tank).balance;
        assertEq(toTank + toMaintainer, amount, "payouts do not add up");
        assertEq(toMaintainer, amount * 1500 / 10_000);
        assertGe(toTank * 10_000, amount * 8500);
        assertLt(toTank * 10_000, amount * 8500 + 10_000);
        assertEq(address(splitter).balance, 0);
    }

    function test_fork_onlyTheSplitterIsOwedTheProceeds() public {
        _mint(user, 0, 500);
        // nobody else can withdraw the creator's proceeds from TapeOut
        vm.prank(maintainer);
        vm.expectRevert(bytes("nothing owed"));
        transistors.withdraw();
        vm.prank(user);
        vm.expectRevert(bytes("nothing owed"));
        transistors.withdraw();
        assertEq(transistors.owed(address(splitter)), 500 * PRICE);

        // overpaying a mint is credited to the minter by TapeOut, never to the splitter
        vm.deal(user, 1 ether);
        vm.prank(user);
        transistors.mint{value: PRICE + PROTOCOL_FEE + 12345}(0, 1);
        assertEq(transistors.owed(user), 12345);
        assertEq(transistors.owed(address(splitter)), 501 * PRICE);
    }

    // ------------------------------------------------------------------ 3. tape out, settle, refund

    function test_fork_tapeout_thenSettleAndRefund() public {
        // a user tapes out the 3-NAND netlist
        uint256 chipId = _tapeoutNand3(user);
        assertEq(chipId, circuits.nextId());
        assertEq(circuits.ownerOf(chipId), user);
        assertEq(transistors.balanceOf(user, 0), 0, "three transistors burned");
        (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount) = circuits.circuitInfo(chipId);
        assertEq(nIn, 2);
        assertEq(nOut, 1);
        assertEq(nState, 0);
        assertEq(gateCount, 3);
        assertEq(circuits.netlist(chipId), NAND3);

        // the chip NFT goes to a kernel
        MockKernel kernel = new MockKernel(chipId);
        vm.prank(user);
        circuits.transferFrom(user, address(kernel), chipId);
        assertEq(circuits.ownerOf(chipId), address(kernel));

        // allowance = 3 transistors * price * 85%
        assertEq(tank.burnedOf(chipId), 3);
        assertEq(tank.allowanceOf(chipId), 3 * PRICE * 85 / 100);
        assertEq(tank.allowanceOf(chipId), 51_000_000_000_000);

        // the proceeds of those three transistors back it exactly
        splitter.pull();
        assertEq(address(tank).balance, 51_000_000_000_000);

        // first settlement: refunded in full at the price paid (the tip of 1 wei is under MAX_TIP)
        Settled memory first = _settleAs(keeper, address(kernel));
        assertEq(kernel.settles(), 1);
        assertEq(first.paid, first.gasCounted * gasPrice);
        assertLe(first.gasCounted, first.txGasBilled, "counted more gas than the transaction used");
        assertLe(first.paid, first.txGasBilled * gasPrice, "refund exceeds the caller's gas cost");
        assertLe(first.paid, 51_000_000_000_000);
        assertEq(keeper.balance, first.paid);
        assertEq(tank.spent(chipId), first.paid);
        assertEq(tank.remainingOf(chipId), 51_000_000_000_000 - first.paid);
        console2.log("settle #1: transaction gas", first.txGasBilled, "counted", first.gasCounted);

        // a heavier settlement uses up the rest: paid what is left, not what it cost
        kernel.setBurnGas(3_000_000);
        Settled memory second = _settleAs(keeper, address(kernel));
        assertEq(kernel.settles(), 2);
        assertEq(second.paid, 51_000_000_000_000 - first.paid, "second refund is capped by the allowance");
        assertLt(second.paid, second.gasCounted * gasPrice);
        assertEq(tank.spent(chipId), 51_000_000_000_000, "spent accumulates up to the allowance");
        assertEq(tank.remainingOf(chipId), 0);

        // exhausted: the settlement still happens, the refund is zero
        Settled memory third = _settleAs(keeper, address(kernel));
        assertEq(kernel.settles(), 3);
        assertEq(third.paid, 0);
        assertEq(tank.spent(chipId), 51_000_000_000_000);
        assertEq(keeper.balance, 51_000_000_000_000);
        assertEq(address(tank).balance, 0);
    }

    function test_fork_refund_isCappedAtBaseFeePlusMaxTip() public {
        uint256 chipId = _tapeoutNand3(user);
        MockKernel kernel = new MockKernel(chipId);
        vm.prank(user);
        circuits.transferFrom(user, address(kernel), chipId);
        vm.prank(user);
        tank.topUp{value: 1 ether}(chipId);

        vm.txGasPrice(1 gwei); // fifty times the base fee
        Settled memory r = _settleAs(keeper, address(kernel));
        assertEq(r.paid, r.gasCounted * (block.basefee + 0.001 gwei));
        assertEq(r.paid, r.gasCounted * 0.021 gwei, "at the pinned block: 5% above the base fee, no more");
        assertLt(r.paid, r.txGasBilled * 1 gwei);
    }

    function test_fork_settle_requiresTheKernelToHoldTheChip() public {
        uint256 chipId = _tapeoutNand3(user);
        MockKernel kernel = new MockKernel(chipId);
        splitter.pull();

        vm.expectRevert(KeeperTank.KernelDoesNotHoldChip.selector);
        tank.settleAndRefund(address(kernel));

        // the real ERC-721 reverts for a chip that does not exist
        LyingKernel liar = new LyingKernel(chipId + 1);
        vm.expectRevert();
        tank.settleAndRefund(address(liar));
        assertEq(tank.spent(chipId), 0);
    }

    function test_fork_hostileKernel_reentryIsBlocked_andBurningGasGainsNothing() public {
        // re-entry
        uint256 chipA = _tapeoutNand3(user);
        ReentrantKernel reentrant = new ReentrantKernel(tank, chipA, true);
        vm.prank(user);
        circuits.transferFrom(user, address(reentrant), chipA);
        // gas burning
        uint256 chipB = _tapeoutNand3(user);
        MockKernel burner = new MockKernel(chipB);
        vm.prank(user);
        circuits.transferFrom(user, address(burner), chipB);
        burner.setBurnGas(4_000_000);
        splitter.pull();

        Settled memory r = _settleAs(keeper, address(reentrant));
        assertTrue(reentrant.reentryBlocked());
        assertEq(reentrant.settles(), 1);
        assertEq(address(reentrant).balance, 0);
        assertLe(r.paid, r.txGasBilled * gasPrice);

        address attacker = makeAddr("attacker");
        uint256 refunds;
        uint256 gasBill;
        for (uint256 i = 0; i < 3; i++) {
            r = _settleAs(attacker, address(burner));
            refunds += r.paid;
            gasBill += r.txGasBilled * gasPrice;
        }
        assertLe(refunds, gasBill);
        assertEq(refunds, 51_000_000_000_000, "it can only empty its own allowance");
        assertEq(tank.spent(chipB), 51_000_000_000_000);
        assertEq(tank.remainingOf(chipA), 51_000_000_000_000 - tank.spent(chipA), "the other chip is untouched by it");
    }

    // ------------------------------------------------------------------ 4. a circuit made only of a REF

    function test_fork_refOnlyCircuit_burnsNothing_andHasNoAllowance() public {
        uint256 base = _tapeoutNand3(user);

        // REF record: opcode 0x02, processor (20 bytes), circuit id (u64), nIns 2, nOuts 1, inputs = signals 2 and 3
        bytes memory refNetlist =
            abi.encodePacked(uint8(2), address(circuits), uint64(base), uint8(2), uint8(1), uint24(2), uint24(3));
        assertEq(refNetlist.length, 31 + 3 * 2);

        // no transistors needed: the user holds none
        assertEq(transistors.balanceOf(user, 0), 0);
        assertEq(transistors.balanceOf(user, 1), 0);
        vm.prank(user);
        uint256 refChip = circuits.tapeout{value: TAPEOUT_FEE}(refNetlist, 2, 1);
        assertEq(transistors.minted(), 3, "the REF tape-out minted and burned nothing");

        // TapeOut reports 3 gates for it (recursive through the REF) ...
        (,,, uint32 gateCount) = circuits.circuitInfo(refChip);
        assertEq(gateCount, 3);
        // ... but it burned nothing, so it has no allowance
        assertEq(tank.burnedOf(refChip), 0);
        assertEq(tank.allowanceOf(refChip), 0);
        assertEq(tank.burnedOf(base), 3);

        // both circuits compute NAND(in0, in1): the REF chip is a real, working circuit
        for (uint8 inputs = 0; inputs < 4; inputs++) {
            bytes memory out = ICpuEval(address(circuits)).eval(refChip, abi.encodePacked(inputs));
            assertEq(uint8(out[0]), inputs == 3 ? 0 : 1);
            assertEq(ICpuEval(address(circuits)).eval(base, abi.encodePacked(inputs)), out);
        }

        // settling it works and pays nothing, even with a funded tank
        MockKernel kernel = new MockKernel(refChip);
        vm.prank(user);
        circuits.transferFrom(user, address(kernel), refChip);
        splitter.pull();
        assertGt(address(tank).balance, 0);
        Settled memory r = _settleAs(keeper, address(kernel));
        assertEq(r.paid, 0);
        assertEq(kernel.settles(), 1);

        // until someone tops it up
        vm.prank(user);
        tank.topUp{value: 0.01 ether}(refChip);
        r = _settleAs(keeper, address(kernel));
        assertEq(r.paid, r.gasCounted * gasPrice);
        assertEq(tank.spent(base), 0, "the referenced chip's allowance is untouched");
    }

    // ------------------------------------------------------------------ 5. top-ups through receive()

    function test_fork_receive_attributesAKernelsTransferToItsChip() public {
        uint256 chipId = _tapeoutNand3(user);
        MockKernel kernel = new MockKernel(chipId);
        vm.prank(user);
        circuits.transferFrom(user, address(kernel), chipId);
        vm.deal(address(kernel), 10 ether);

        // exactly the documented floor is enough against the real processor
        vm.expectEmit(true, true, true, true, address(tank));
        emit ToppedUp(chipId, address(kernel), 1 ether);
        assertTrue(kernel.pay(address(tank), 1 ether, tank.RECEIVE_MIN_GAS()));
        console2.log("kernel -> tank plain transfer, whole transaction (gas):", vm.lastFrameGas().gasTotalUsed);
        assertEq(tank.toppedUp(chipId), 1 ether);
        assertEq(tank.allowanceOf(chipId), 51_000_000_000_000 + 1 ether);

        // below the floor the tank refuses rather than guess
        assertFalse(kernel.pay(address(tank), 1 ether, 150_000));
        assertEq(tank.toppedUp(chipId), 1 ether);

        // for every amount of forwarded gas: refused, or credited to the chip; never unattributed
        uint256 credited = 1 ether;
        for (uint256 gasLimit = 0; gasLimit <= 300_000; gasLimit += 5_000) {
            if (kernel.pay(address(tank), 0.1 ether, gasLimit)) credited += 0.1 ether;
            assertEq(tank.toppedUp(chipId), credited);
            assertEq(address(tank).balance, credited);
        }
    }

    function test_fork_receive_fromOthers_isUnattributedBacking() public {
        uint256 chipId = _tapeoutNand3(user);

        // an EOA
        vm.expectEmit(true, true, true, true, address(tank));
        emit Funded(user, 1 ether);
        vm.prank(user);
        (bool ok,) = address(tank).call{value: 1 ether}("");
        assertTrue(ok);

        // the user still holds the chip: a contract claiming it is not its holder
        LyingKernel liar = new LyingKernel(chipId);
        vm.deal(address(liar), 1 ether);
        vm.expectEmit(true, true, true, true, address(tank));
        emit Funded(address(liar), 1 ether);
        assertTrue(liar.pay(address(tank), 1 ether));

        // a contract wallet with no chipId()
        SilentWallet wallet = new SilentWallet();
        vm.deal(address(wallet), 1 ether);
        assertTrue(wallet.pay(address(tank), 1 ether, 300_000));

        // the Splitter
        vm.expectEmit(true, true, true, true, address(tank));
        emit Funded(address(splitter), 51_000_000_000_000);
        splitter.pull();

        assertEq(tank.toppedUp(chipId), 0);
        assertEq(tank.allowanceOf(chipId), 51_000_000_000_000);
        assertEq(address(tank).balance, 3 ether + 51_000_000_000_000);
    }

    // ------------------------------------------------------------------ 6. a maintainer that cannot be paid

    function test_fork_maintainerPushFailure_fallsBackToThePullBalance() public {
        ToggleMaintainer refusing = new ToggleMaintainer();
        Splitter s = _ignite(address(refusing));
        ITransistors t = ITransistors(s.TRANSISTORS());

        vm.deal(user, 10 ether);
        vm.prank(user);
        t.mint{value: 1000 * PRICE + PROTOCOL_FEE}(0, 1000);
        uint256 proceeds = 1000 * PRICE;

        s.pull();
        assertEq(s.TANK().balance, proceeds * 85 / 100, "the tank is paid regardless");
        assertEq(address(refusing).balance, 0);
        assertEq(s.maintainerOwed(), proceeds * 15 / 100);
        assertEq(address(s).balance, proceeds * 15 / 100);

        // the credit is not split again
        s.pull();
        assertEq(s.TANK().balance, proceeds * 85 / 100);
        assertEq(s.maintainerOwed(), proceeds * 15 / 100);

        // still refusing: the claim fails and the credit stays
        vm.expectRevert(Splitter.TransferFailed.selector);
        s.claimMaintainer();
        assertEq(s.maintainerOwed(), proceeds * 15 / 100);

        // accepting: anyone can trigger the claim, the money goes to the maintainer
        refusing.setAccept(true);
        vm.prank(makeAddr("anyone"));
        s.claimMaintainer();
        assertEq(address(refusing).balance, proceeds * 15 / 100);
        assertEq(s.maintainerOwed(), 0);
        assertEq(address(s).balance, 0);
    }

    // ------------------------------------------------------------------ 7. what "TapeOut can upgrade" means here

    /// The story says TapeOut's factory owner can upgrade processor logic. This is what that does to the tank:
    /// a chip whose burn count was already fixed by its first settlement keeps it; a chip that was never
    /// settled is read through the new logic. Refunds stay bounded by gas spent either way.
    function test_fork_tapeOutLogicUpgrade_cannotInflateAnAllowanceAlreadyFixed() public {
        uint256 settledChip = _tapeoutNand3(user);
        uint256 freshChip = _tapeoutNand3(user);
        MockKernel kernel = new MockKernel(settledChip);
        MockKernel freshKernel = new MockKernel(freshChip);
        vm.startPrank(user);
        circuits.transferFrom(user, address(kernel), settledChip);
        circuits.transferFrom(user, address(freshKernel), freshChip);
        vm.stopPrank();
        splitter.pull();
        _settleAs(keeper, address(kernel)); // fixes burned = 3 for settledChip

        // TapeOut's owner swaps the Circuits logic for one that reports 1,000 gates for every netlist
        address circuitsLogic = _beaconImplementation(address(circuits));
        InflatingCircuitsLogic inflating = new InflatingCircuitsLogic(circuitsLogic);
        address tapeoutOwner = IFactoryAdmin(FACTORY).owner();
        vm.prank(tapeoutOwner);
        IFactoryAdmin(FACTORY).upgradeCircuits(address(inflating));
        assertEq(circuits.netlist(settledChip).length, 7000, "the upgrade took effect");

        assertEq(tank.burnedOf(settledChip), 3, "already fixed");
        assertEq(tank.allowanceOf(settledChip), 51_000_000_000_000);
        assertEq(tank.burnedOf(freshChip), 1000, "never settled: read through the upgraded logic");

        // even then a refund is what the caller's gas cost, not what the inflated allowance says
        Settled memory r = _settleAs(keeper, address(freshKernel));
        assertLe(r.paid, r.txGasBilled * gasPrice);
        assertLe(r.paid, address(tank).balance + r.paid);
    }

    function _beaconImplementation(address beaconProxy) internal view returns (address impl) {
        // ERC-1967 beacon slot
        bytes32 slot = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;
        address beacon = address(uint160(uint256(vm.load(beaconProxy, slot))));
        (bool ok, bytes memory ret) = beacon.staticcall(abi.encodeWithSignature("implementation()"));
        require(ok, "beacon");
        impl = abi.decode(ret, (address));
    }
}
