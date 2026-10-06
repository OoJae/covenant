// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Splitter} from "../../src/Splitter.sol";
import {ICircuitFactory, ITransistors} from "../../src/interfaces/ITapeOut.sol";
import {Story} from "../../script/lib/Story.sol";

/// @notice Review test (story lens). Prints the exact story the Splitter writes for the real parameters: the
///         real deployer at its real nonce, itself as maintainer, the real factory.
///         Adapted: no repository argument any more, and what TapeOut's own site shows is printed too.
///         Run with -vv to read it.
contract StoryReviewForkTest is Test {
    address internal constant FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    address internal constant DEPLOYER = 0x84cE7bAe1b788C7aD985D57721cA428b401aE34D;
    address internal constant MAINTAINER = 0x84cE7bAe1b788C7aD985D57721cA428b401aE34D;
    bytes20 internal constant COMMIT = hex"11d58e0dae448dfe449feafce38fd619eb85d6a2";

    function test_review_printStory() public {
        vm.createSelectFork(vm.envOr("XLAYER_RPC_URL", string("https://rpc.xlayer.tech")), 72_370_000);
        assertEq(vm.getNonce(DEPLOYER), 0, "deployer nonce at the fork block");
        uint256 fee = ICircuitFactory(FACTORY).deployFee();
        vm.deal(DEPLOYER, 1 ether);
        vm.prank(DEPLOYER, DEPLOYER);
        Splitter s = new Splitter{value: fee}(FACTORY, MAINTAINER, COMMIT);
        ITransistors t = ITransistors(s.TRANSISTORS());
        string memory story = t.story();
        bytes memory b = bytes(story);
        console2.log("splitter   ", address(s));
        console2.log("transistors", s.TRANSISTORS());
        console2.log("circuits   ", s.CIRCUITS());
        console2.log("tank       ", s.TANK());
        console2.log("registry   ", s.REGISTRY());
        console2.log("maintainer ", s.MAINTAINER());
        console2.log("length", b.length);
        console2.logBytes32(keccak256(b));
        console2.log(story);
        console2.log("first 600 characters:");
        console2.log(Story.shown(story));

        string memory expected = Story.expected(address(s), s.TANK(), MAINTAINER, s.REGISTRY(), COMMIT);
        assertEq(story, expected);
        assertEq(b.length, 1366);
        for (uint256 i = 0; i < b.length; i++) {
            assertTrue(uint8(b[i]) >= 0x20 && uint8(b[i]) <= 0x7e, "non printable");
        }
        // the addresses of the real deployment, as long as the deployer's nonce stays 0
        assertTrue(vm.contains(story, "splitter 0xfd73b7Bc92cDa68ec57799987fd3449BA5daDD88;"));
        assertTrue(vm.contains(story, "Keeper tank 0xAfed3eC2196BDc8F5a933D8f280c945f0D2D826e "));
        assertTrue(vm.contains(story, "Maintainer 0x84cE7bAe1b788C7aD985D57721cA428b401aE34D."));
        assertTrue(vm.contains(story, "registry 0x6f1a330b7FfAc901205704EACA8e46ee4091F3A2:"));
        assertTrue(vm.contains(story, " commit 11d58e0dae448dfe449feafce38fd619eb85d6a2."));
    }
}
