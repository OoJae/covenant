// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {XLayerFork} from "../fork/XLayerFork.sol";
import {Splitter} from "../../src/Splitter.sol";
import {TeamRegistry} from "../../src/TeamRegistry.sol";
import {ICircuitFactory, ITransistors} from "../../src/interfaces/ITapeOut.sol";

interface IFactoryOwner {
    function owner() external view returns (address);
    function upgradeTransistors(address newImpl) external;
    function seal() external;
    function isSealed() external view returns (bool);
}

/// @dev A Transistors logic that behaves like the current one, plus one function that rewrites `creator`
///      (storage slot 0 of the verified layout). This is what "TapeOut's owner can upgrade processor logic"
///      allows.
contract RedirectingTransistorsLogic {
    address internal immutable PREVIOUS;

    constructor(address previous) {
        PREVIOUS = previous;
    }

    function setCreator(address newCreator) external {
        assembly {
            sstore(0, newCreator)
        }
    }

    /// @dev TapeOut's Transistors takes OKB only through mint(), which reaches the fallback below.
    receive() external payable {}

    fallback() external payable {
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

/// @notice Review tests (splitter lens): four sentences of the first story, each run against the real chain.
///         Every one of them found the sentence wanting. The story has been rewritten since, and each test
///         now shows the sentence that replaced the old one, against the same facts.
contract StoryClaimsForkTest is XLayerFork {
    address internal constant DEPLOYER = 0x84cE7bAe1b788C7aD985D57721cA428b401aE34D;

    function setUp() public {
        _fork();
    }

    /// First story: "No key can change these payees or shares." The key that owns TapeOut's factory could:
    /// one beacon upgrade and mint proceeds accrue to someone else.
    /// Now: "no key can change the splitter's payees or shares" (true: they are immutables), and the part of
    /// the story TapeOut's site shows says "TapeOut's owner can upgrade processor logic" (this is what that
    /// means in the worst case).
    function test_fork_claim_noKeyCanChangeTheSplittersPayees_andTapeOutsOwnerCanUpgrade() public {
        splitter = _ignite(maintainer);
        transistors = ITransistors(splitter.TRANSISTORS());
        string memory story = transistors.story();
        assertTrue(vm.contains(story, "no key can change the splitter's payees or shares"));
        assertFalse(vm.contains(story, "No key can change these payees or shares"));
        assertTrue(vm.indexOf(story, "TapeOut's owner can upgrade processor logic") < 600, "in the part that is shown");
        assertEq(address(uint160(uint256(vm.load(address(transistors), bytes32(0))))), address(splitter), "slot 0");

        address tank_ = splitter.TANK();

        address thief = makeAddr("whoever TapeOut's owner chooses");
        bytes32 beaconSlot = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;
        address beacon = address(uint160(uint256(vm.load(address(transistors), beaconSlot))));
        (, bytes memory ret) = beacon.staticcall(abi.encodeWithSignature("implementation()"));
        address current = abi.decode(ret, (address));

        RedirectingTransistorsLogic logic = new RedirectingTransistorsLogic(current);
        address tapeoutOwner = IFactoryOwner(FACTORY).owner();
        vm.prank(tapeoutOwner);
        IFactoryOwner(FACTORY).upgradeTransistors(address(logic));
        RedirectingTransistorsLogic(payable(address(transistors))).setCreator(thief);
        assertEq(transistors.creator(), thief);

        // a user mints at list price; nothing reaches the splitter any more
        _mint(user, 0, 1000);
        assertEq(transistors.owed(address(splitter)), 0);
        assertEq(transistors.owed(thief), 1000 * PRICE);
        splitter.pull();
        assertEq(splitter.TANK().balance + maintainer.balance, 0);
        vm.prank(thief);
        transistors.withdraw();
        assertEq(thief.balance, 1000 * PRICE);

        // the splitter itself is as it was: same payees, same shares, and what reaches it is still split
        assertEq(splitter.TANK(), tank_);
        assertEq(splitter.MAINTAINER(), maintainer);
        assertEq(splitter.TANK_BPS(), 8500);
        assertEq(splitter.MAINTAINER_BPS(), 1500);
        vm.deal(address(splitter), 1 ether);
        splitter.pull();
        assertEq(tank_.balance, 0.85 ether);
        assertEq(maintainer.balance, 0.15 ether);
    }

    /// First story: "the team pays list price." The maintainer payee is the same wallet that deploys and
    /// mints (docs/WALLETS.md): of every 0.00002 OKB it pays for a transistor, 15% comes back to it with the
    /// next pull(). The sentence is gone from the story; the fact is the same.
    function test_fork_claim_theTeamPaysListPrice_isNoLongerClaimed() public {
        vm.deal(DEPLOYER, 1 ether);
        uint256 fee = ICircuitFactory(FACTORY).deployFee();
        vm.prank(DEPLOYER);
        Splitter s = new Splitter{value: fee}(FACTORY, DEPLOYER, COMMIT);
        ITransistors t = ITransistors(s.TRANSISTORS());
        assertFalse(vm.contains(t.story(), "pays list price"));

        uint256 before = DEPLOYER.balance;
        vm.prank(DEPLOYER);
        t.mint{value: 1000 * PRICE + PROTOCOL_FEE}(0, 1000);
        vm.prank(user);
        s.pull();
        uint256 netPaid = before - DEPLOYER.balance - PROTOCOL_FEE;

        console2.log("list price of 1000 transistors (wei):", 1000 * PRICE);
        console2.log("what the team wallet paid, net (wei): ", netPaid);
        assertEq(netPaid, 1000 * PRICE * 85 / 100, "the team's own mints cost it 85% of list");
    }

    /// First story: "TapeOut's factory is unsealed and its owner can upgrade processor logic", and neither
    /// the constructor nor the script read isSealed(): after a seal, creation still succeeded and the
    /// processor carried a sentence that was false for ever.
    /// Now the constructor reads it: after a seal, creation reverts.
    function test_fork_claim_tapeOutsOwnerCanUpgrade_isCheckedAtCreation() public {
        // unsealed, as it is today: creation works
        _ignite(maintainer);

        address tapeoutOwner = IFactoryOwner(FACTORY).owner();
        vm.prank(tapeoutOwner);
        IFactoryOwner(FACTORY).seal();
        assertTrue(IFactoryOwner(FACTORY).isSealed());
        assertEq(IFactoryOwner(FACTORY).owner(), address(0), "sealed: no owner any more");

        // nobody can upgrade anything any more ...
        vm.prank(tapeoutOwner);
        (bool ok,) = FACTORY.call(abi.encodeCall(IFactoryOwner.upgradeTransistors, (address(this))));
        assertFalse(ok);

        // ... so the sentence would be false, and the processor is not created
        uint256 fee = ICircuitFactory(FACTORY).deployFee();
        vm.expectRevert(Splitter.FactorySealed.selector);
        new Splitter{value: fee}(FACTORY, maintainer, COMMIT);
    }

    /// First story: "Team wallets self-declare in registry <address>." At the block the story was written
    /// the registry was empty, and a stranger was "team" one transaction later, ahead of the real maintainer.
    /// Now: "Team wallets are listed in registry <address>: the deployer, then wallets that a listed wallet
    /// invited and that declared themselves."
    function test_fork_claim_teamWalletsAreListed_startingWithTheDeployer() public {
        vm.deal(DEPLOYER, 1 ether);
        uint256 fee = ICircuitFactory(FACTORY).deployFee();
        vm.prank(DEPLOYER);
        Splitter s = new Splitter{value: fee}(FACTORY, DEPLOYER, COMMIT);
        TeamRegistry r = TeamRegistry(s.REGISTRY());
        assertTrue(
            vm.contains(
                ITransistors(s.TRANSISTORS()).story(),
                string.concat(
                    "Team wallets are listed in registry ",
                    vm.toString(address(r)),
                    ": the deployer, then wallets that a listed wallet invited and that declared themselves."
                )
            )
        );

        // the only team wallet that has acted so far is in it, from the creation block on
        assertEq(r.count(), 1);
        assertTrue(r.isTeam(DEPLOYER));
        (address w, string memory role,) = r.at(0);
        assertEq(w, DEPLOYER);
        assertEq(role, "deployer");

        // a stranger cannot get in
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(TeamRegistry.NotInvited.selector);
        r.declare("maintainer");
        assertFalse(r.isTeam(stranger));

        // the keeper wallet gets in the way the story says: invited by a listed wallet, declared by itself
        address keeperWallet = makeAddr("keeper wallet");
        vm.prank(DEPLOYER);
        r.invite(keeperWallet);
        console2.log("invite() as a transaction (gas):", vm.lastFrameGas().gasTotalUsed);
        vm.prank(keeperWallet);
        r.declare("keeper");
        console2.log("declare() as a transaction (gas):", vm.lastFrameGas().gasTotalUsed);
        (w, role,) = r.at(1);
        assertEq(w, keeperWallet);
        assertEq(role, "keeper");
        assertEq(r.count(), 2);
    }
}
