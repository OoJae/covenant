// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TeamRegistry} from "../../src/TeamRegistry.sol";

// Review tests (splitter lens): attacks on the TeamRegistry, written by the reviewer. One of them showed a
// defect and now shows its repair: any stranger could list itself in the registry as "team"; the registry is
// now rooted in the deployer.
// (This file held the attacks on the LaunchpadSocket as well; they went with the socket, NOTES.md section 9.)

// ---------------------------------------------------------------------------------------------- registry

contract RegistryAttackTest is Test {
    TeamRegistry internal registry;
    address internal deployer = makeAddr("deployer");
    address internal maintainer = makeAddr("maintainer");
    address internal impostor = makeAddr("impostor");

    function setUp() public {
        registry = new TeamRegistry(deployer);
    }

    /// When it was reviewed, anyone could put themselves in the "team" registry, with any role text, before
    /// the team did, and nothing distinguished the entry from a real one. Now the impostor is refused, and
    /// so is everything else it can try.
    function test_attack_impostorDeclaresAsTeam_isRefused() public {
        vm.prank(impostor);
        vm.expectRevert(TeamRegistry.NotInvited.selector);
        registry.declare("maintainer");

        // it cannot invite itself, nor a second wallet of its own
        vm.prank(impostor);
        vm.expectRevert(TeamRegistry.NotListed.selector);
        registry.invite(impostor);
        vm.prank(impostor);
        vm.expectRevert(TeamRegistry.NotListed.selector);
        registry.invite(makeAddr("impostor's other wallet"));

        assertFalse(registry.isTeam(impostor), "isTeam(impostor)");
        assertFalse(registry.isInvited(impostor));
        assertEq(registry.count(), 1);

        // the real maintainer is invited by the deployer and declares itself: entry 1, after the deployer
        vm.prank(deployer);
        registry.invite(maintainer);
        vm.prank(maintainer);
        registry.declare("maintainer");
        (address w0, string memory r0,) = registry.at(0);
        (address w1, string memory r1,) = registry.at(1);
        assertEq(w0, deployer);
        assertEq(r0, "deployer");
        assertEq(w1, maintainer);
        assertEq(r1, "maintainer");
        assertEq(registry.count(), 2);

        // still no way to remove an entry: there is no function for it
        (bool ok,) = address(registry).call(abi.encodeWithSignature("remove(uint256)", 0));
        assertFalse(ok);
    }

    /// When it was reviewed, flooding the registry cost one cheap transaction per entry, from anybody.
    /// Now a stranger cannot add an entry at any price. A listed wallet can (it invites, the invited wallet
    /// declares), which is the rule the story states; this is what one such entry costs.
    function test_attack_spam_isClosedToStrangers() public {
        string memory role = "OFFICIAL Covenant presale wallet - send OKB here to get CVNT 2x!";
        assertEq(bytes(role).length, 64);
        for (uint256 i = 0; i < 50; i++) {
            vm.prank(address(uint160(0x1000 + i)));
            vm.expectRevert(TeamRegistry.NotInvited.selector);
            registry.declare(role);
        }
        assertEq(registry.count(), 1);

        uint256 total;
        uint256 n = 20;
        for (uint256 i = 0; i < n; i++) {
            address wallet = address(uint160(0x1000 + i));
            vm.prank(deployer);
            registry.invite(wallet);
            total += vm.lastFrameGas().gasTotalUsed;
            vm.prank(wallet);
            registry.declare(role);
            total += vm.lastFrameGas().gasTotalUsed;
        }
        console2.log("gas per entry made by a listed wallet (invite + declare, two transactions):", total / n);
        assertEq(registry.count(), 1 + n);
    }

    /// The views stay cheap however long the list gets (no view iterates).
    function test_views_areBounded() public {
        for (uint256 i = 0; i < 300; i++) {
            address wallet = address(uint160(0x1000 + i));
            vm.prank(deployer);
            registry.invite(wallet);
            vm.prank(wallet);
            registry.declare("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
        }
        uint256 g = gasleft();
        registry.at(300);
        uint256 gasAt = g - gasleft();
        g = gasleft();
        registry.count();
        uint256 gasCount = g - gasleft();
        g = gasleft();
        registry.isTeam(address(uint160(0x1000 + 150)));
        uint256 gasIsTeam = g - gasleft();
        console2.log("at(300) gas:", gasAt);
        console2.log("count() gas:", gasCount);
        console2.log("isTeam() gas:", gasIsTeam);
        assertLt(gasAt, 30_000);
        assertLt(gasCount, 10_000);
        assertLt(gasIsTeam, 10_000);
    }

    /// Role bytes are not validated: control characters, an embedded NUL, ANSI escapes and invalid UTF-8 are
    /// all stored and emitted as they are. Only an invited wallet can write one.
    function test_role_acceptsArbitraryBytes() public {
        bytes memory nasty = hex"1b5b324a000a0d202e2eff";
        vm.prank(deployer);
        registry.invite(maintainer);
        vm.prank(maintainer);
        registry.declare(string(nasty));
        (, string memory role,) = registry.at(1);
        assertEq(bytes(role), nasty);
    }

    /// A third party can list neither itself nor a wallet that is not theirs, whatever it sends.
    function testFuzz_cannotDeclareSomeoneElse(address victim, address attacker_, bytes calldata junk) public {
        vm.assume(victim != attacker_ && attacker_ != deployer && victim != deployer);
        vm.prank(attacker_);
        (bool ok,) = address(registry).call(junk);
        ok;
        assertFalse(registry.isTeam(victim));
        assertFalse(registry.isTeam(attacker_));
        assertFalse(registry.isInvited(victim));
        assertEq(registry.count(), 1);
        (address w,,) = registry.at(0);
        assertEq(w, deployer);
    }
}
