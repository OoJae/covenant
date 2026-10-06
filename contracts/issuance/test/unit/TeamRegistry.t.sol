// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {TeamRegistry} from "../../src/TeamRegistry.sol";

contract TeamRegistryTest is Test {
    uint256 internal constant T0 = 1_791_000_000;

    TeamRegistry internal registry;

    address internal founder = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal stranger = makeAddr("stranger");

    event Invited(address indexed wallet, address indexed by);
    event Declared(address indexed wallet, uint256 indexed index, string role);

    /// @dev The registry is created by this test contract, the way the Splitter creates it: the creator is
    ///      not the founder and gets no rights.
    function setUp() public {
        vm.warp(T0);
        registry = new TeamRegistry(founder);
    }

    function _invite(address by, address wallet) internal {
        vm.prank(by);
        registry.invite(wallet);
    }

    function _declare(address wallet, string memory role) internal {
        vm.prank(wallet);
        registry.declare(role);
    }

    // ------------------------------------------------------------------ the root

    function test_startsWithTheFounderAsEntryZero() public view {
        assertEq(registry.count(), 1);
        (address wallet, string memory role, uint256 timestamp) = registry.at(0);
        assertEq(wallet, founder);
        assertEq(role, "deployer");
        assertEq(timestamp, T0);

        assertTrue(registry.isTeam(founder));
        assertFalse(registry.isInvited(founder), "the founder is listed, not invited");
        assertFalse(registry.isTeam(alice));
        assertFalse(registry.isInvited(alice));
        assertEq(registry.MAX_ROLE_BYTES(), 64);
    }

    function test_constructor_emitsDeclaredForTheFounder() public {
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectEmit(true, true, true, true, next);
        emit Declared(carol, 0, "deployer");
        TeamRegistry r = new TeamRegistry(carol);
        assertEq(address(r), next);
    }

    /// Whoever creates the registry (the Splitter, in production) is not listed and can do nothing with it.
    function test_theCreatorOfTheRegistry_hasNoRights() public {
        assertFalse(registry.isTeam(address(this)));

        vm.expectRevert(TeamRegistry.NotListed.selector);
        registry.invite(alice);
        vm.expectRevert(TeamRegistry.NotInvited.selector);
        registry.declare("deployer");

        assertEq(registry.count(), 1);
        assertFalse(registry.isInvited(alice));
    }

    function test_founder_cannotDeclareAgain() public {
        vm.prank(founder);
        vm.expectRevert(TeamRegistry.AlreadyDeclared.selector);
        registry.declare("maintainer");

        // not even after inviting itself
        _invite(founder, founder);
        vm.prank(founder);
        vm.expectRevert(TeamRegistry.AlreadyDeclared.selector);
        registry.declare("maintainer");

        (, string memory role,) = registry.at(0);
        assertEq(role, "deployer");
        assertEq(registry.count(), 1);
    }

    // ------------------------------------------------------------------ invite

    function test_invite_byAListedWallet_marksTheWalletAndNothingElse() public {
        vm.expectEmit(true, true, true, true, address(registry));
        emit Invited(alice, founder);
        _invite(founder, alice);

        assertTrue(registry.isInvited(alice));
        assertFalse(registry.isTeam(alice), "an invitation is not a listing");
        assertEq(registry.count(), 1);
        assertFalse(registry.isInvited(bob));
        assertFalse(registry.isInvited(founder), "the inviter is not the invited");
    }

    function test_invite_byAStranger_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(TeamRegistry.NotListed.selector);
        registry.invite(stranger);

        vm.prank(stranger);
        vm.expectRevert(TeamRegistry.NotListed.selector);
        registry.invite(alice);

        assertFalse(registry.isInvited(stranger));
        assertFalse(registry.isInvited(alice));
    }

    /// Being invited is not enough to invite: only a wallet that is listed can.
    function test_invite_byAnInvitedWalletThatHasNotDeclared_reverts() public {
        _invite(founder, alice);

        vm.prank(alice);
        vm.expectRevert(TeamRegistry.NotListed.selector);
        registry.invite(bob);
        assertFalse(registry.isInvited(bob));

        _declare(alice, "keeper");
        _invite(alice, bob);
        assertTrue(registry.isInvited(bob));
    }

    function test_invite_again_orOfAListedWallet_changesNothing() public {
        _invite(founder, alice);
        _invite(founder, alice);
        _declare(alice, "keeper");

        // inviting a wallet that is already listed does not let it declare a second time
        _invite(founder, alice);
        vm.prank(alice);
        vm.expectRevert(TeamRegistry.AlreadyDeclared.selector);
        registry.declare("maintainer");

        assertEq(registry.count(), 2);
        (, string memory role,) = registry.at(1);
        assertEq(role, "keeper");
    }

    // ------------------------------------------------------------------ declare

    function test_declare_byAnInvitedWallet_listsIt() public {
        _invite(founder, alice);

        vm.warp(T0 + 3600);
        vm.expectEmit(true, true, true, true, address(registry));
        emit Declared(alice, 1, "maintainer");
        _declare(alice, "maintainer");

        assertTrue(registry.isTeam(alice));
        assertFalse(registry.isTeam(bob));
        assertEq(registry.count(), 2);

        (address wallet, string memory role, uint256 timestamp) = registry.at(1);
        assertEq(wallet, alice);
        assertEq(role, "maintainer");
        assertEq(timestamp, T0 + 3600);

        // entry 0 is untouched
        (wallet, role, timestamp) = registry.at(0);
        assertEq(wallet, founder);
        assertEq(role, "deployer");
        assertEq(timestamp, T0);
    }

    /// What the review found in the first version: any stranger could list itself as "team".
    function test_declare_withoutAnInvitation_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(TeamRegistry.NotInvited.selector);
        registry.declare("maintainer");

        assertFalse(registry.isTeam(stranger));
        assertEq(registry.count(), 1);
    }

    /// An invitation is for one wallet. Nobody else can use it, and nobody can list a wallet but its owner.
    function test_declare_usesOnlyTheCallersOwnInvitation() public {
        _invite(founder, alice);

        vm.prank(bob);
        vm.expectRevert(TeamRegistry.NotInvited.selector);
        registry.declare("maintainer");
        assertFalse(registry.isTeam(bob));
        assertFalse(registry.isTeam(alice), "alice has not declared herself");

        // the founder cannot declare on her behalf either
        vm.prank(founder);
        vm.expectRevert(TeamRegistry.AlreadyDeclared.selector);
        registry.declare("maintainer");
        assertEq(registry.count(), 1);
    }

    function test_declare_twice_reverts() public {
        _invite(founder, alice);
        _declare(alice, "maintainer");

        vm.prank(alice);
        vm.expectRevert(TeamRegistry.AlreadyDeclared.selector);
        registry.declare("keeper");

        // the first declaration is untouched
        (, string memory role,) = registry.at(1);
        assertEq(role, "maintainer");
        assertEq(registry.count(), 2);
    }

    function test_declare_roleOf64Bytes_ok_65_reverts() public {
        _invite(founder, alice);
        _invite(founder, bob);

        string memory role64 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
        assertEq(bytes(role64).length, 64);
        _declare(alice, role64);
        (, string memory stored,) = registry.at(1);
        assertEq(stored, role64);

        string memory role65 = string.concat(role64, "x");
        vm.prank(bob);
        vm.expectRevert(TeamRegistry.RoleTooLong.selector);
        registry.declare(role65);
        assertFalse(registry.isTeam(bob));

        // the invitation is still good for a role that fits
        _declare(bob, "keeper");
        assertTrue(registry.isTeam(bob));
    }

    function test_declare_emptyRole_ok() public {
        _invite(founder, alice);
        _declare(alice, "");
        (address wallet, string memory role,) = registry.at(1);
        assertEq(wallet, alice);
        assertEq(bytes(role).length, 0);
    }

    function test_declare_multibyteRole_countsBytesNotCharacters() public {
        _invite(founder, alice);
        // 22 three-byte characters = 66 bytes
        string memory role = unicode"維護者維護者維護者維護者維護者維護者維護者維";
        assertEq(bytes(role).length, 66);
        vm.prank(alice);
        vm.expectRevert(TeamRegistry.RoleTooLong.selector);
        registry.declare(role);
    }

    // ------------------------------------------------------------------ the list

    /// The story's sentence: "the deployer, then wallets that a listed wallet invited and that declared
    /// themselves". A chain three deep, in order, with its timestamps.
    function test_chainOfInvitations_orderAndTimestampsArePreserved() public {
        vm.warp(T0 + 1000);
        _invite(founder, alice);
        vm.warp(T0 + 2000);
        _declare(alice, "maintainer");

        vm.warp(T0 + 3000);
        _invite(alice, bob);
        vm.warp(T0 + 4000);
        _declare(bob, "keeper operator");

        assertEq(registry.count(), 3);
        (address w0, string memory r0, uint256 t0) = registry.at(0);
        (address w1, string memory r1, uint256 t1) = registry.at(1);
        (address w2, string memory r2, uint256 t2) = registry.at(2);
        assertEq(w0, founder);
        assertEq(r0, "deployer");
        assertEq(t0, T0);
        assertEq(w1, alice);
        assertEq(r1, "maintainer");
        assertEq(t1, T0 + 2000, "the time of the declaration, not of the invitation");
        assertEq(w2, bob);
        assertEq(r2, "keeper operator");
        assertEq(t2, T0 + 4000);
    }

    function test_at_outOfRange_reverts() public {
        registry.at(0);
        vm.expectRevert(stdError.indexOOBError);
        registry.at(1);

        _invite(founder, alice);
        vm.expectRevert(stdError.indexOOBError);
        registry.at(1);

        _declare(alice, "maintainer");
        registry.at(1);
        vm.expectRevert(stdError.indexOOBError);
        registry.at(2);
    }

    function test_acceptsNoOkb() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(registry).call{value: 1}("");
        assertFalse(ok);

        vm.deal(founder, 1 ether);
        vm.prank(founder);
        (ok,) = address(registry).call{value: 1}(abi.encodeCall(TeamRegistry.invite, (alice)));
        assertFalse(ok, "invite is not payable");
    }

    // ------------------------------------------------------------------ fuzz

    /// Any wallet the founder invites, any role within the limit: listed once, as itself, at the next index.
    function testFuzz_declare(address who, string calldata role, uint64 when) public {
        vm.assume(who != founder);
        vm.assume(bytes(role).length <= 64);
        _invite(founder, who);
        vm.warp(when);

        _declare(who, role);

        assertTrue(registry.isTeam(who));
        assertEq(registry.count(), 2);
        (address wallet, string memory stored, uint256 timestamp) = registry.at(1);
        assertEq(wallet, who);
        assertEq(stored, role);
        assertEq(timestamp, when);

        vm.prank(who);
        vm.expectRevert(TeamRegistry.AlreadyDeclared.selector);
        registry.declare(role);
    }

    function testFuzz_declare_tooLong_reverts(address who, uint8 extra) public {
        vm.assume(who != founder);
        _invite(founder, who);
        bytes memory role = new bytes(65 + uint256(extra));
        vm.prank(who);
        vm.expectRevert(TeamRegistry.RoleTooLong.selector);
        registry.declare(string(role));
    }

    /// No wallet outside the list can get in, or let anyone in, by itself.
    function testFuzz_withoutAnInvitation_nobodyGetsIn(address who, address other, string calldata role) public {
        vm.assume(who != founder);

        vm.prank(who);
        vm.expectRevert(TeamRegistry.NotInvited.selector);
        registry.declare(role);

        vm.prank(who);
        vm.expectRevert(TeamRegistry.NotListed.selector);
        registry.invite(other);

        assertFalse(registry.isTeam(who));
        assertFalse(registry.isInvited(other));
        assertEq(registry.count(), 1);
    }

    /// Any sequence of invitations and declarations among five wallets, checked against the rule written
    /// out independently: a wallet is listed if and only if it is the founder, or it declared itself after
    /// a wallet that was listed at that moment had invited it.
    function testFuzz_registryFollowsTheRule(uint8[32] memory steps) public {
        address[5] memory pool = [founder, alice, bob, carol, stranger];
        bool[5] memory listed;
        bool[5] memory invited;
        listed[0] = true;
        uint256 listedCount = 1;

        for (uint256 i = 0; i < steps.length; i++) {
            uint256 actor = steps[i] % 5;
            uint256 target = (steps[i] / 5) % 5;
            bool isInvite = (steps[i] / 25) % 2 == 0;

            vm.prank(pool[actor]);
            if (isInvite) {
                if (listed[actor]) {
                    invited[target] = true;
                } else {
                    vm.expectRevert(TeamRegistry.NotListed.selector);
                }
                registry.invite(pool[target]);
            } else {
                if (listed[actor]) {
                    vm.expectRevert(TeamRegistry.AlreadyDeclared.selector);
                } else if (!invited[actor]) {
                    vm.expectRevert(TeamRegistry.NotInvited.selector);
                } else {
                    listed[actor] = true;
                    listedCount++;
                }
                registry.declare("role");
            }

            assertEq(registry.count(), listedCount);
            for (uint256 k = 0; k < pool.length; k++) {
                assertEq(registry.isTeam(pool[k]), listed[k], "isTeam");
                assertEq(registry.isInvited(pool[k]), invited[k], "isInvited");
            }
        }

        // every entry is a different wallet of the pool, and entry 0 is still the founder
        (address first,,) = registry.at(0);
        assertEq(first, founder);
        for (uint256 a = 0; a < listedCount; a++) {
            (address wa,,) = registry.at(a);
            assertTrue(registry.isTeam(wa));
            for (uint256 b = a + 1; b < listedCount; b++) {
                (address wb,,) = registry.at(b);
                assertTrue(wa != wb, "a wallet is listed twice");
            }
        }
    }

    /// There is no function that could edit or remove an entry or an invitation: everything except the
    /// known selectors reverts, and nothing a stranger sends changes what is listed.
    function testFuzz_nothingElseIsCallable(address anyone, bytes4 selector, bytes calldata args) public {
        vm.assume(
            selector != registry.declare.selector && selector != registry.invite.selector
                && selector != registry.count.selector && selector != registry.at.selector
                && selector != registry.isTeam.selector && selector != registry.isInvited.selector
                && selector != registry.MAX_ROLE_BYTES.selector
        );
        _invite(founder, alice);
        _declare(alice, "maintainer");
        _invite(founder, bob);

        vm.prank(anyone);
        (bool ok,) = address(registry).call(abi.encodePacked(selector, args));
        assertFalse(ok);

        assertEq(registry.count(), 2);
        (address wallet, string memory role,) = registry.at(1);
        assertEq(wallet, alice);
        assertEq(role, "maintainer");
        assertTrue(registry.isInvited(bob), "an invitation cannot be withdrawn");
        assertTrue(registry.isTeam(founder));
    }

    /// The same for the functions that do exist: whatever a wallet outside the list calls, with whatever
    /// arguments, the list does not change.
    function testFuzz_aStrangerCannotChangeTheList(address anyone, bytes calldata data) public {
        vm.assume(anyone != founder && anyone != alice && anyone != bob);
        _invite(founder, alice);
        _declare(alice, "maintainer");
        _invite(founder, bob);

        vm.recordLogs();
        vm.prank(anyone);
        (bool ok,) = address(registry).call(data);
        ok;

        assertEq(vm.getRecordedLogs().length, 0, "a stranger's call emitted an event");
        assertEq(registry.count(), 2);
        assertFalse(registry.isTeam(anyone));
        assertFalse(registry.isInvited(anyone));
        assertFalse(registry.isTeam(bob));
    }
}
