// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LocalBase} from "../utils/LocalBase.sol";
import {Splitter} from "../../src/Splitter.sol";
import {TeamRegistry} from "../../src/TeamRegistry.sol";

/// @notice Review test (splitter lens), kept as the reviewer wrote it for the fixes it proposed. Those fixes
///         are now in src/; the only adaptations are the constructor's arguments and the name of the
///         registry's error for an unlisted inviter (NotListed). Its two tests of the launchpad socket went
///         with the socket (NOTES.md, section 9).
contract FixesTest is LocalBase {
    function setUp() public {
        _deployLocal(maintainer);
    }

    // ---- registry: seeded with the deployer, closed to strangers
    function test_fix_registry_deployerIsEntryZero_atCreation() public view {
        assertEq(registry.count(), 1);
        (address w, string memory role,) = registry.at(0);
        assertEq(w, address(this), "the account that created the Splitter");
        assertEq(role, "deployer");
        assertTrue(registry.isTeam(address(this)));
    }

    function test_fix_registry_strangerCannotDeclare() public {
        vm.prank(makeAddr("impostor"));
        vm.expectRevert(TeamRegistry.NotInvited.selector);
        registry.declare("maintainer");

        vm.prank(makeAddr("impostor"));
        vm.expectRevert(TeamRegistry.NotListed.selector);
        registry.invite(makeAddr("impostor"));
    }

    function test_fix_registry_invitedWalletDeclaresItself() public {
        address keeperWallet = makeAddr("keeper wallet");
        registry.invite(keeperWallet); // by the deployer (this test contract)
        assertFalse(registry.isTeam(keeperWallet), "an invitation is not a declaration");
        vm.prank(keeperWallet);
        registry.declare("keeper");
        assertTrue(registry.isTeam(keeperWallet));
        assertEq(registry.count(), 2);
    }

    // ---- splitter: a sealed factory would make the story false, so creation reverts
    function test_fix_splitter_sealedFactory_reverts() public {
        factory.setSealed(true);
        uint256 fee = factory.deployFee();
        vm.expectRevert(Splitter.FactorySealed.selector);
        new Splitter{value: fee}(address(factory), maintainer, COMMIT);
    }
}
