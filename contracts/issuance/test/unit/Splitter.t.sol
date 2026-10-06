// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {LocalBase} from "../utils/LocalBase.sol";
import {Story} from "../../script/lib/Story.sol";
import {Splitter} from "../../src/Splitter.sol";
import {KeeperTank} from "../../src/KeeperTank.sol";
import {TeamRegistry} from "../../src/TeamRegistry.sol";
import {MockFactory, MockTransistors} from "../mocks/MockTapeOut.sol";
import {
    ToggleMaintainer,
    ReentrantMaintainer,
    GuzzlerMaintainer,
    BombMaintainer,
    SlowMaintainer,
    PickyMaintainer
} from "../mocks/Hostile.sol";

/// @dev Code that refuses every OKB transfer. Etched over the tank to reach a revert the real tank never causes.
contract RefusingCode {
    receive() external payable {
        revert("refused");
    }
}

contract SplitterTest is LocalBase {
    event Pulled(uint256 toTank, uint256 toMaintainer);
    event MaintainerCredited(uint256 amount);
    event MaintainerClaimed(uint256 amount);

    function setUp() public {
        _deployLocal(maintainer);
    }

    // ------------------------------------------------------------------ helpers

    function _newSplitter(address maintainer_) internal returns (Splitter) {
        return new Splitter{value: factory.deployFee()}(address(factory), maintainer_, COMMIT);
    }

    struct Balances {
        uint256 tank;
        uint256 maintainer;
        uint256 credited;
    }

    function _balances(Splitter s) internal view returns (Balances memory b) {
        b.tank = s.TANK().balance;
        b.maintainer = s.MAINTAINER().balance;
        b.credited = s.maintainerOwed();
    }

    /// @dev The split of `amount`: conservation, the rounded-down maintainer share, dust to the tank.
    function _assertSplit(uint256 amount, uint256 toTank, uint256 toMaintainer) internal pure {
        assertEq(toTank + toMaintainer, amount, "payouts do not add up to the amount");

        // maintainer: the exact share rounded down, i.e. less than 1 wei below exact
        assertEq(toMaintainer, amount * 1500 / 10_000, "maintainer share");
        assertLe(toMaintainer * 10_000, amount * 1500);
        assertGt((toMaintainer + 1) * 10_000, amount * 1500);

        // tank: never below 85%, and above it only by the dust of the one rounding (less than 1 wei)
        assertGe(toTank * 10_000, amount * 8500, "tank below 85%");
        assertLt(toTank * 10_000, amount * 8500 + 10_000, "tank dust of 1 wei or more");
    }

    // ------------------------------------------------------------------ creation

    function test_constants() public view {
        assertEq(splitter.NAME(), "Covenant");
        assertEq(splitter.SYMBOL(), "CVNT");
        assertEq(splitter.SUPPLY(), 67_108_864);
        assertEq(splitter.SUPPLY(), 2 ** 26);
        assertEq(splitter.PRICE(), 0.00002 ether);
        assertEq(splitter.PRICE(), 20_000_000_000_000);
        assertEq(splitter.TANK_BPS(), 8500);
        assertEq(splitter.MAINTAINER_BPS(), 1500);
        assertEq(splitter.TANK_BPS() + splitter.MAINTAINER_BPS(), 10_000);
        assertEq(splitter.MAINTAINER_GAS(), 50_000);
        // the tank's allowance share is the share the tank is paid
        assertEq(tank.ALLOWANCE_BPS(), splitter.TANK_BPS());
    }

    function test_creation_wiresEverything() public view {
        // the processor
        assertTrue(factory.isCPU(address(circuits)));
        assertEq(transistors.creator(), address(splitter));
        assertEq(transistors.supplyCap(), 67_108_864);
        assertEq(transistors.mintPrice(), 0.00002 ether);
        assertEq(transistors.cpuName(), "Covenant");
        assertEq(transistors.cpuSymbol(), "CVNT");
        assertEq(transistors.circuits(), address(circuits));
        assertEq(circuits.transistors(), address(transistors));

        // the payees
        assertEq(splitter.MAINTAINER(), maintainer);
        assertEq(tank.SPLITTER(), address(splitter));
        assertEq(tank.circuits(), address(circuits));
        assertEq(tank.transistors(), address(transistors));
        assertEq(tank.mintPrice(), 0.00002 ether);

        // the registry starts with one entry: the account that sent the creation (here this test contract)
        assertEq(registry.count(), 1);
        (address founder, string memory role, uint256 listedAt) = registry.at(0);
        assertEq(founder, address(this));
        assertEq(role, "deployer");
        assertEq(listedAt, block.timestamp);
        assertTrue(registry.isTeam(address(this)));
        assertFalse(registry.isTeam(maintainer), "the maintainer is not listed unless it is the deployer");
        assertFalse(registry.isTeam(address(splitter)));

        // three distinct contracts, none of them the maintainer
        assertTrue(address(tank) != address(registry) && address(tank) != address(splitter));
        assertTrue(address(registry) != address(splitter));
        assertTrue(maintainer != address(tank) && maintainer != address(registry));

        // exactly the deploy fee went to the factory; nothing is stranded
        assertEq(address(splitter).balance, 0);
        assertEq(factory.owed(address(splitter)), 0);
        assertEq(address(factory).balance, factory.deployFee());
        assertEq(splitter.maintainerOwed(), 0);
    }

    /// The story itself is tested in test/unit/Story.t.sol. Here: it is the template for these addresses.
    function test_creation_story_isByteForByteTheTemplate() public view {
        string memory expected = Story.expected(address(splitter), address(tank), maintainer, address(registry), COMMIT);
        string memory onChain = transistors.story();
        assertEq(onChain, expected);
        assertEq(keccak256(bytes(onChain)), keccak256(bytes(expected)));
    }

    /// The account that sends the creation is entry 0 of the registry, whoever it is.
    function testFuzz_creation_listsTheSenderAsDeployer(address sender, uint64 when) public {
        vm.assume(sender != address(0) && sender.code.length == 0);
        assumeNotForgeAddress(sender);
        vm.warp(when);
        uint256 fee = factory.deployFee();
        vm.deal(sender, fee);
        vm.prank(sender);
        Splitter s = new Splitter{value: fee}(address(factory), maintainer, COMMIT);

        TeamRegistry r = TeamRegistry(s.REGISTRY());
        assertEq(r.count(), 1);
        (address founder, string memory role, uint256 listedAt) = r.at(0);
        assertEq(founder, sender);
        assertEq(role, "deployer");
        assertEq(listedAt, when);
        assertTrue(r.isTeam(sender));
        assertEq(r.isTeam(address(this)), sender == address(this));
    }

    function test_creation_emitsIgnited() public {
        vm.recordLogs();
        Splitter s = _newSplitter(maintainer);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(s) && logs[i].topics[0] == Splitter.Ignited.selector) {
                found = true;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), s.TRANSISTORS());
                assertEq(address(uint160(uint256(logs[i].topics[2]))), s.CIRCUITS());
                (address t, address r, address m) = abi.decode(logs[i].data, (address, address, address));
                assertEq(t, s.TANK());
                assertEq(r, s.REGISTRY());
                assertEq(m, maintainer);
            }
        }
        assertTrue(found);
    }

    function test_creation_reverts_zeroMaintainer() public {
        uint256 fee = factory.deployFee();
        vm.expectRevert(Splitter.ZeroMaintainer.selector);
        new Splitter{value: fee}(address(factory), address(0), COMMIT);
    }

    function test_creation_reverts_zeroCommit() public {
        uint256 fee = factory.deployFee();
        vm.expectRevert(Splitter.ZeroCommit.selector);
        new Splitter{value: fee}(address(factory), maintainer, bytes20(0));
    }

    function test_creation_reverts_unlessValueIsExactlyTheDeployFee() public {
        uint256 fee = factory.deployFee();

        vm.expectRevert(Splitter.WrongDeployFee.selector);
        new Splitter{value: fee - 1}(address(factory), maintainer, COMMIT);

        // one wei too much would be credited by TapeOut to a balance nobody can withdraw
        vm.expectRevert(Splitter.WrongDeployFee.selector);
        new Splitter{value: fee + 1}(address(factory), maintainer, COMMIT);

        vm.expectRevert(Splitter.WrongDeployFee.selector);
        new Splitter(address(factory), maintainer, COMMIT);
    }

    function test_creation_reverts_ifTheDeployFeeMovedSinceItWasRead() public {
        uint256 quoted = factory.deployFee();
        factory.setDeployFee(quoted + 1);
        vm.expectRevert(Splitter.WrongDeployFee.selector);
        new Splitter{value: quoted}(address(factory), maintainer, COMMIT);
    }

    function test_creation_reverts_ifTapeOutsMintFeeIsNotWhatTheStorySays() public {
        factory.setProtocolFee(0.00067 ether);
        uint256 fee = factory.deployFee();
        vm.expectRevert(Splitter.TapeOutFeesChanged.selector);
        new Splitter{value: fee}(address(factory), maintainer, COMMIT);
    }

    function test_creation_reverts_ifTheClonesMintFeeIsNotWhatTheStorySays() public {
        factory.setSabotage(MockFactory.Sabotage.CloneFeeDiffers);
        uint256 fee = factory.deployFee();
        vm.expectRevert(Splitter.TapeOutFeesChanged.selector);
        new Splitter{value: fee}(address(factory), maintainer, COMMIT);
    }

    function test_creation_reverts_ifTapeOutsTapeoutFeeIsNotWhatTheStorySays() public {
        factory.setTapeoutFee(0.0014 ether);
        uint256 fee = factory.deployFee();
        vm.expectRevert(Splitter.TapeOutFeesChanged.selector);
        new Splitter{value: fee}(address(factory), maintainer, COMMIT);
    }

    function test_creation_reverts_ifTheProcessorIsNotWhatWasAskedFor() public {
        MockFactory.Sabotage[6] memory cases = [
            MockFactory.Sabotage.WrongCreator,
            MockFactory.Sabotage.WrongSupply,
            MockFactory.Sabotage.WrongPrice,
            MockFactory.Sabotage.WrongCircuitsLink,
            MockFactory.Sabotage.WrongTransistorsLink,
            MockFactory.Sabotage.NotRegistered
        ];
        uint256 fee = factory.deployFee();
        for (uint256 i = 0; i < cases.length; i++) {
            factory.setSabotage(cases[i]);
            vm.expectRevert(Splitter.ProcessorMismatch.selector);
            new Splitter{value: fee}(address(factory), maintainer, COMMIT);
        }
    }

    /// The story, the name and the symbol are immutable once the processor exists. If the factory stores
    /// anything but what it was given, creation reverts: three ways to mangle the story, one each for the
    /// name and the symbol. Each case alone, so that no check can hide behind another.
    function test_creation_reverts_ifTheStoredStoryIsCut() public {
        _expectMismatch(MockFactory.Sabotage.StoryCut);
    }

    function test_creation_reverts_ifOneCharacterOfTheStoredStoryDiffers() public {
        _expectMismatch(MockFactory.Sabotage.StoryOneCharacterOff);
    }

    function test_creation_reverts_ifTheStoredStoryIsLonger() public {
        _expectMismatch(MockFactory.Sabotage.StoryPadded);
    }

    function test_creation_reverts_ifTheStoredNameDiffers() public {
        _expectMismatch(MockFactory.Sabotage.WrongName);
    }

    function test_creation_reverts_ifTheStoredSymbolDiffers() public {
        _expectMismatch(MockFactory.Sabotage.WrongSymbol);
    }

    function _expectMismatch(MockFactory.Sabotage sabotage) internal {
        factory.setSabotage(sabotage);
        uint256 fee = factory.deployFee();
        vm.expectRevert(Splitter.ProcessorMismatch.selector);
        new Splitter{value: fee}(address(factory), maintainer, COMMIT);

        // the sabotage is the only thing wrong: without it the same creation goes through
        factory.setSabotage(MockFactory.Sabotage.None);
        new Splitter{value: fee}(address(factory), maintainer, COMMIT);
    }

    /// The sabotaged factory really stores what the tests above say it stores (a mock that mangled nothing
    /// would make them pass for the wrong reason only if the constructor reverted for another cause).
    function test_mockFactory_sabotage_storesMangledText() public {
        string memory good = transistors.story();
        MockFactory.Sabotage[5] memory cases = [
            MockFactory.Sabotage.StoryCut,
            MockFactory.Sabotage.StoryOneCharacterOff,
            MockFactory.Sabotage.StoryPadded,
            MockFactory.Sabotage.WrongName,
            MockFactory.Sabotage.WrongSymbol
        ];
        for (uint256 i = 0; i < cases.length; i++) {
            factory.setSabotage(cases[i]);
            (address t,) = factory.createCPU{value: factory.deployFee()}("Covenant", "CVNT", good, 67_108_864, PRICE);
            bytes memory stored = bytes(MockTransistors(t).story());
            bool storyDiffers = keccak256(stored) != keccak256(bytes(good));
            bool nameDiffers = keccak256(bytes(MockTransistors(t).cpuName())) != keccak256("Covenant");
            bool symbolDiffers = keccak256(bytes(MockTransistors(t).cpuSymbol())) != keccak256("CVNT");
            assertEq(storyDiffers, i < 3);
            assertEq(nameDiffers, i == 3);
            assertEq(symbolDiffers, i == 4);
            if (cases[i] == MockFactory.Sabotage.StoryCut) assertEq(stored.length, 280);
            if (cases[i] == MockFactory.Sabotage.StoryOneCharacterOff) assertEq(stored.length, bytes(good).length);
            if (cases[i] == MockFactory.Sabotage.StoryPadded) assertEq(stored.length, bytes(good).length + 1);
        }
    }

    /// The story says TapeOut's owner can upgrade processor logic. A sealed factory has no owner and can
    /// upgrade nothing: creation reverts rather than write that sentence.
    function test_creation_reverts_ifTheFactoryIsSealed() public {
        factory.setSealed(true);
        uint256 fee = factory.deployFee();
        vm.expectRevert(Splitter.FactorySealed.selector);
        new Splitter{value: fee}(address(factory), maintainer, COMMIT);

        factory.setSealed(false);
        new Splitter{value: fee}(address(factory), maintainer, COMMIT);
    }

    /// The statement must hold when creation ends, not only when it starts.
    function test_creation_reverts_ifTheFactorySealsItselfWhileCreating() public {
        factory.setSabotage(MockFactory.Sabotage.SealsItself);
        assertFalse(factory.isSealed());
        uint256 fee = factory.deployFee();
        vm.expectRevert(Splitter.FactorySealed.selector);
        new Splitter{value: fee}(address(factory), maintainer, COMMIT);
        assertFalse(factory.isSealed(), "the reverted creation left no trace");
    }

    function test_tankInit_cannotBeCalledAgain() public {
        vm.prank(address(splitter));
        vm.expectRevert(KeeperTank.AlreadyInitialised.selector);
        tank.init(address(circuits), address(transistors));

        vm.expectRevert(KeeperTank.NotSplitter.selector);
        tank.init(address(circuits), address(transistors));
    }

    // ------------------------------------------------------------------ pull

    function test_pull_splits85_15() public {
        _mint(user, 0, 1000); // 1000 * 0.00002 = 0.02 OKB of proceeds
        assertEq(transistors.owed(address(splitter)), 0.02 ether);

        vm.expectEmit(true, true, true, true, address(splitter));
        emit Pulled(0.017 ether, 0.003 ether);
        vm.prank(makeAddr("anyone"));
        splitter.pull();

        assertEq(address(tank).balance, 0.017 ether);
        assertEq(maintainer.balance, 0.003 ether);
        assertEq(address(splitter).balance, 0);
        assertEq(transistors.owed(address(splitter)), 0);
        assertEq(splitter.maintainerOwed(), 0);
    }

    function test_pull_countsNandAndLatchAlike() public {
        _mint(user, 0, 10);
        _mint(user, 1, 30);
        splitter.pull();
        _assertSplit(40 * PRICE, address(tank).balance, maintainer.balance);
    }

    function test_pull_twice_theSecondDoesNothingAndDoesNotRevert() public {
        _mint(user, 0, 1000);
        splitter.pull();
        Balances memory before = _balances(splitter);

        vm.recordLogs();
        splitter.pull();
        assertEq(vm.getRecordedLogs().length, 0, "a pull with nothing to split emits nothing");

        Balances memory afterwards = _balances(splitter);
        assertEq(afterwards.tank, before.tank);
        assertEq(afterwards.maintainer, before.maintainer);
    }

    function test_pull_beforeAnyMint_doesNotRevert() public {
        splitter.pull();
        assertEq(address(tank).balance, 0);
        assertEq(maintainer.balance, 0);
    }

    function test_pull_dustGoesToTheTank() public {
        // 3 wei: the maintainer's 0.45 rounds to zero
        vm.deal(address(splitter), 3);
        splitter.pull();
        assertEq(address(tank).balance, 3);
        assertEq(maintainer.balance, 0);

        // 7 wei: maintainer 1.05 -> 1, tank 5.95 -> 6
        vm.deal(address(splitter), 7);
        splitter.pull();
        assertEq(address(tank).balance, 3 + 6);
        assertEq(maintainer.balance, 1);

        // 1 wei
        vm.deal(address(splitter), 1);
        splitter.pull();
        assertEq(address(tank).balance, 3 + 6 + 1);
    }

    function test_pull_alsoSplitsOkbSentStraightToTheSplitter() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool ok,) = address(splitter).call{value: 1 ether}("");
        assertTrue(ok);

        splitter.pull();
        assertEq(address(tank).balance, 0.85 ether);
        assertEq(maintainer.balance, 0.15 ether);
    }

    function test_pull_whenWithdrawFailsForAnotherReason_stillSplitsWhatIsHere() public {
        _mint(user, 0, 1000);
        transistors.setWithdrawBroken(true);
        vm.deal(address(splitter), 1 ether);

        splitter.pull();
        assertEq(address(tank).balance, 0.85 ether);
        assertEq(transistors.owed(address(splitter)), 0.02 ether, "proceeds stay owed, not lost");

        transistors.setWithdrawBroken(false);
        splitter.pull();
        assertEq(address(tank).balance, 0.85 ether + 0.017 ether);
        assertEq(transistors.owed(address(splitter)), 0);
    }

    /// For any amount of proceeds and any stray balance: payouts add up to exactly what was there,
    /// the maintainer gets its share rounded down, the tank gets the rest.
    function testFuzz_pull_conservation(uint32 minted, uint96 stray) public {
        uint256 n = bound(uint256(minted), 0, 5_000_000);
        if (n != 0) _mint(user, n % 2, n);
        vm.deal(address(splitter), stray);
        uint256 amount = n * PRICE + stray;

        splitter.pull();

        _assertSplit(amount, address(tank).balance, maintainer.balance);
        assertEq(address(splitter).balance, 0);
        assertEq(transistors.owed(address(splitter)), 0);
    }

    /// The same over a sequence of pulls: every pull is split on its own, and the totals never drift.
    function testFuzz_pull_sequence(uint96[6] memory amounts) public {
        uint256 total;
        uint256 expectedMaintainer;
        for (uint256 i = 0; i < amounts.length; i++) {
            vm.deal(address(splitter), amounts[i]);
            splitter.pull();
            total += amounts[i];
            expectedMaintainer += uint256(amounts[i]) * 1500 / 10_000;
        }
        assertEq(maintainer.balance, expectedMaintainer);
        assertEq(address(tank).balance + maintainer.balance, total);
        assertGe(address(tank).balance * 10_000, total * 8500);
        assertEq(address(splitter).balance, 0);
    }

    // ------------------------------------------------------------------ maintainer push fails

    function test_maintainerPushFails_shareIsCredited_othersArePaid() public {
        ToggleMaintainer refusing = new ToggleMaintainer();
        Splitter s = _newSplitter(address(refusing));
        vm.deal(address(s), 1 ether);

        vm.expectEmit(true, true, true, true, address(s));
        emit MaintainerCredited(0.15 ether);
        vm.expectEmit(true, true, true, true, address(s));
        emit Pulled(0.85 ether, 0.15 ether);
        s.pull();

        assertEq(s.TANK().balance, 0.85 ether);
        assertEq(address(refusing).balance, 0);
        assertEq(s.maintainerOwed(), 0.15 ether);
        assertEq(address(s).balance, 0.15 ether, "the credited share stays in the splitter");
    }

    function test_creditedShare_isNeverSplitAgain() public {
        ToggleMaintainer refusing = new ToggleMaintainer();
        Splitter s = _newSplitter(address(refusing));
        vm.deal(address(s), 1 ether);
        s.pull();

        // nothing new: the 0.15 credited must not be re-split
        vm.recordLogs();
        s.pull();
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(s.TANK().balance, 0.85 ether);
        assertEq(s.maintainerOwed(), 0.15 ether);

        // 1 more OKB arrives: only that is split, and the credit grows by 15% of it
        vm.deal(address(s), address(s).balance + 1 ether);
        s.pull();
        assertEq(s.TANK().balance, 1.7 ether);
        assertEq(s.maintainerOwed(), 0.3 ether);
        assertEq(address(s).balance, 0.3 ether);
    }

    function test_claimMaintainer_paysTheMaintainer_whoeverCalls() public {
        ToggleMaintainer m = new ToggleMaintainer();
        Splitter s = _newSplitter(address(m));
        vm.deal(address(s), 1 ether);
        s.pull();
        m.setAccept(true);

        address stranger = makeAddr("stranger");
        vm.expectEmit(true, true, true, true, address(s));
        emit MaintainerClaimed(0.15 ether);
        vm.prank(stranger);
        s.claimMaintainer();

        assertEq(address(m).balance, 0.15 ether);
        assertEq(stranger.balance, 0);
        assertEq(s.maintainerOwed(), 0);
        assertEq(address(s).balance, 0);

        vm.expectRevert(Splitter.NothingOwed.selector);
        s.claimMaintainer();
    }

    function test_claimMaintainer_whileTheMaintainerStillRefuses_reverts_andKeepsTheCredit() public {
        ToggleMaintainer m = new ToggleMaintainer();
        Splitter s = _newSplitter(address(m));
        vm.deal(address(s), 1 ether);
        s.pull();

        vm.expectRevert(Splitter.TransferFailed.selector);
        s.claimMaintainer();
        assertEq(s.maintainerOwed(), 0.15 ether);
        assertEq(address(s).balance, 0.15 ether);
    }

    function test_claimMaintainer_nothingOwed_reverts() public {
        vm.expectRevert(Splitter.NothingOwed.selector);
        splitter.claimMaintainer();
    }

    function test_onceTheMaintainerAccepts_pushesWorkAgain() public {
        ToggleMaintainer m = new ToggleMaintainer();
        Splitter s = _newSplitter(address(m));
        vm.deal(address(s), 1 ether);
        s.pull();
        m.setAccept(true);

        vm.deal(address(s), address(s).balance + 1 ether);
        s.pull();
        assertEq(address(m).balance, 0.15 ether, "new share pushed");
        assertEq(s.maintainerOwed(), 0.15 ether, "old credit still claimable");
        s.claimMaintainer();
        assertEq(address(m).balance, 0.3 ether);
    }

    /// Whatever pattern of accepting and refusing: maintainer balance + credit is always 15% of each pull.
    function testFuzz_maintainerFallback_conservation(uint64[5] memory amounts, bool[5] memory accepts) public {
        ToggleMaintainer m = new ToggleMaintainer();
        Splitter s = _newSplitter(address(m));
        uint256 total;
        uint256 maintainerShare;
        for (uint256 i = 0; i < amounts.length; i++) {
            m.setAccept(accepts[i]);
            vm.deal(address(s), address(s).balance + amounts[i]);
            s.pull();
            total += amounts[i];
            maintainerShare += uint256(amounts[i]) * 1500 / 10_000;

            assertEq(address(m).balance + s.maintainerOwed(), maintainerShare);
            assertEq(address(s).balance, s.maintainerOwed(), "splitter holds exactly the credit");
            assertEq(s.TANK().balance + address(m).balance + s.maintainerOwed(), total);
        }
    }

    // ------------------------------------------------------------------ hostile maintainers

    function test_maintainerReentersPull_isBlocked() public {
        ReentrantMaintainer m = new ReentrantMaintainer();
        Splitter s = _newSplitter(address(m));
        m.arm(s, 0, false);
        vm.deal(address(s), 1 ether);

        s.pull();

        assertTrue(m.reentryBlocked(), "the nested pull() must hit the reentrancy guard");
        assertEq(s.TANK().balance, 0.85 ether);
        assertEq(address(m).balance, 0.15 ether);
        assertEq(address(s).balance, 0);
    }

    function test_maintainerReentersClaim_isBlocked() public {
        ReentrantMaintainer m = new ReentrantMaintainer();
        Splitter s = _newSplitter(address(m));
        // first make a credit exist: refuse once (the refusal rolls back whatever the maintainer recorded)
        m.arm(s, 0, true);
        vm.deal(address(s), 1 ether);
        s.pull();
        assertEq(s.maintainerOwed(), 0.15 ether);
        assertEq(s.TANK().balance, 0.85 ether);
        assertFalse(m.reentryBlocked());

        // now accept, but try to claim again from inside the claim
        m.arm(s, 1, false);
        s.claimMaintainer();
        assertTrue(m.reentryBlocked());
        assertEq(address(m).balance, 0.15 ether, "paid once, not twice");
        assertEq(s.maintainerOwed(), 0);
    }

    /// pull() and claimMaintainer() share one guard: a maintainer cannot claim its old credit from inside a
    /// pull, nor pull from inside a claim.
    function test_maintainerReentersAcrossFunctions_isBlocked() public {
        ReentrantMaintainer m = new ReentrantMaintainer();
        Splitter s = _newSplitter(address(m));
        m.arm(s, 0, true); // refuse once so that a credit exists
        vm.deal(address(s), 1 ether);
        s.pull();
        assertEq(s.maintainerOwed(), 0.15 ether);

        // during the next pull's push, try to claim the credit
        m.arm(s, 1, false);
        vm.deal(address(s), address(s).balance + 1 ether);
        s.pull();
        assertTrue(m.reentryBlocked(), "claimMaintainer() inside pull() must hit the guard");
        assertEq(s.maintainerOwed(), 0.15 ether, "the credit was not paid out through the back door");
        assertEq(address(m).balance, 0.15 ether, "only the new share was pushed");
        assertEq(s.TANK().balance, 1.7 ether);

        // during a claim, try to pull
        vm.deal(address(s), address(s).balance + 1 ether); // unsplit money a nested pull would move
        m.arm(s, 0, false);
        s.claimMaintainer();
        assertTrue(m.reentryBlocked(), "pull() inside claimMaintainer() must hit the guard");
        assertEq(address(m).balance, 0.3 ether);
        assertEq(s.maintainerOwed(), 0);
        assertEq(s.TANK().balance, 1.7 ether, "the nested pull did not run");
        assertEq(address(s).balance, 1 ether);
    }

    function test_maintainerThatBurnsAllItsGas_cannotBlockThePull() public {
        GuzzlerMaintainer m = new GuzzlerMaintainer();
        Splitter s = _newSplitter(address(m));
        vm.deal(address(s), 1 ether);

        s.pull();
        uint256 txGas = vm.lastFrameGas().gasTotalUsed;

        assertEq(s.TANK().balance, 0.85 ether);
        assertEq(s.maintainerOwed(), 0.15 ether);
        // the maintainer could burn at most MAINTAINER_GAS plus the 2,300 stipend
        assertLt(txGas, 250_000);
    }

    function test_maintainerThatRevertsWithAHugeBuffer_cannotBlockThePull() public {
        BombMaintainer m = new BombMaintainer();
        Splitter s = _newSplitter(address(m));
        vm.deal(address(s), 1 ether);

        s.pull();
        uint256 txGas = vm.lastFrameGas().gasTotalUsed;

        assertEq(s.TANK().balance, 0.85 ether);
        assertEq(s.maintainerOwed(), 0.15 ether);
        // the 100 kB of revert data is never copied into the splitter's memory
        assertLt(txGas, 250_000);
    }

    /// A caller cannot starve the maintainer push of gas to force the credit path: for every gas limit the
    /// pull either reverts as a whole or pays the maintainer directly.
    /// Two honest maintainer wallets that need most of MAINTAINER_GAS: one burns about 40,000 gas, the other
    /// refuses cheaply when offered less than 45,000 (the case the gas floor in pull() exists for).
    function test_pull_cannotBeStarvedIntoCreditingTheMaintainer() public {
        address[2] memory maintainers = [address(new SlowMaintainer()), address(new PickyMaintainer())];
        for (uint256 k = 0; k < maintainers.length; k++) {
            address m = maintainers[k];
            Splitter s = _newSplitter(m);
            vm.deal(address(s), 1 ether);

            uint256 succeeded;
            uint256 reverted;
            for (uint256 gasLimit = 60_000; gasLimit <= 400_000; gasLimit += 1_000) {
                uint256 snap = vm.snapshotState();
                try s.pull{gas: gasLimit}() {
                    succeeded++;
                    assertEq(s.maintainerOwed(), 0, "push failed for lack of gas and was credited");
                    assertEq(m.balance, 0.15 ether);
                } catch {
                    reverted++;
                    assertEq(address(s).balance, 1 ether, "a reverted pull moves nothing");
                }
                vm.revertToState(snap);
            }
            assertGt(succeeded, 0);
            assertGt(reverted, 0);
        }
    }

    function test_pull_withTooLittleGasForThePush_revertsWithInsufficientGas() public {
        vm.deal(address(splitter), 1 ether);
        bool sawInsufficientGas;
        for (uint256 gasLimit = 60_000; gasLimit <= 250_000; gasLimit += 500) {
            uint256 snap = vm.snapshotState();
            try splitter.pull{gas: gasLimit}() {}
            catch (bytes memory err) {
                if (bytes4(err) == Splitter.InsufficientGas.selector) sawInsufficientGas = true;
            }
            vm.revertToState(snap);
        }
        assertTrue(sawInsufficientGas);
    }

    /// pull() is all or nothing at every gas limit: either both payees are paid in full, or nothing has
    /// moved. (The tank transfer itself cannot be starved: the tank's receive hook runs within the 2,300 gas
    /// stipend of a value transfer, see testFuzz_receive_neverRevertsForTheSplitter. A pull that runs out of
    /// gas anywhere simply reverts as a whole.)
    function test_pull_isAllOrNothing_atEveryGasLimit() public {
        _mint(user, 0, 1000);
        vm.deal(address(splitter), 1 ether);
        uint256 total = 1 ether + 1000 * PRICE;

        uint256 succeeded;
        uint256 reverted;
        for (uint256 gasLimit = 22_000; gasLimit <= 300_000; gasLimit += 200) {
            uint256 snap = vm.snapshotState();
            try splitter.pull{gas: gasLimit}() {
                // Either withdraw() ran out of gas inside TapeOut (swallowed: only the stray OKB is split,
                // the proceeds stay owed) or everything was collected and split.
                uint256 split = address(tank).balance + maintainer.balance;
                assertTrue(split == total || split == 1 ether, "partial payout");
                assertEq(split + transistors.owed(address(splitter)), total);
                assertEq(address(splitter).balance, 0);
                _assertSplit(split, address(tank).balance, maintainer.balance);
                succeeded++;
            } catch {
                reverted++;
                assertEq(address(tank).balance + maintainer.balance, 0, "a reverted pull paid");
                assertEq(address(splitter).balance + transistors.owed(address(splitter)), total);
            }
            vm.revertToState(snap);
        }
        assertGt(succeeded, 0);
        assertGt(reverted, 0);
    }

    /// The tank cannot refuse the Splitter (its receive hook runs on the stipend alone, see
    /// testFuzz_receive_neverRevertsForTheSplitter), so this revert is out of reach with the real tank. Were
    /// the tank ever to refuse, pull() reverts as a whole: the tank's share is never left behind in the
    /// Splitter, to be split again by the next pull.
    function test_pull_ifTheTankRefused_revertsAsAWhole() public {
        vm.deal(address(splitter), 1 ether);
        vm.etch(address(tank), type(RefusingCode).runtimeCode);

        vm.expectRevert(Splitter.TransferFailed.selector);
        splitter.pull();
        assertEq(address(splitter).balance, 1 ether);
        assertEq(address(tank).balance, 0);
        assertEq(maintainer.balance, 0);
        assertEq(splitter.maintainerOwed(), 0);
    }

    // ------------------------------------------------------------------ nothing else

    function test_receive_acceptsOkb() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool ok,) = address(splitter).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(splitter).balance, 1 ether);
    }

    function test_hasNoAdminSurface() public {
        bytes[8] memory calls = [
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("transferOwnership(address)", address(this)),
            abi.encodeWithSignature("renounceOwnership()"),
            abi.encodeWithSignature("upgradeTo(address)", address(this)),
            abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(this), ""),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("setMaintainer(address)", address(this)),
            abi.encodeWithSignature("withdraw()")
        ];
        address[2] memory targets = [address(splitter), address(tank)];
        for (uint256 t = 0; t < targets.length; t++) {
            for (uint256 i = 0; i < calls.length; i++) {
                (bool ok,) = targets[t].call(calls[i]);
                assertFalse(ok);
            }
        }
    }

    /// Whatever anyone calls on the Splitter, OKB only ever leaves it towards the two payees, in the fixed
    /// proportions, and never to the caller.
    function testFuzz_arbitraryCall_cannotRedirectFunds(address caller, bytes calldata data, uint64 stray) public {
        vm.assume(caller != address(tank) && caller != maintainer);
        vm.assume(caller != address(splitter) && caller != address(transistors));
        _mint(user, 0, 123);
        vm.deal(address(splitter), stray);
        uint256 total = 123 * PRICE + stray;
        uint256 callerBefore = caller.balance;

        vm.prank(caller);
        (bool ok,) = address(splitter).call(data);
        ok;

        assertEq(caller.balance, callerBefore, "the caller gained OKB");
        uint256 paidOut = address(tank).balance + maintainer.balance;
        uint256 stillHere = address(splitter).balance + transistors.owed(address(splitter));
        assertEq(paidOut + stillHere, total, "OKB went somewhere else");
        if (paidOut != 0) _assertSplit(total, address(tank).balance, maintainer.balance);
    }
}
