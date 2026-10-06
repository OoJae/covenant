// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {XLayerFork} from "../fork/XLayerFork.sol";
import {Ignite} from "../../script/Ignite.s.sol";
import {Splitter} from "../../src/Splitter.sol";
import {ITransistors} from "../../src/interfaces/ITapeOut.sol";

/// @notice Review test (story lens): what the Ignite script lets into the story.
///         When it was reviewed the repository URL was free text taken from REPO_URL: a zero-width space, a
///         line break or any sentence at all went into the immutable story and passed the script's own check.
///         The URL is now part of the fixed text and neither the constructor nor the script takes a string.
contract IgniteInputForkTest is XLayerFork {
    bytes20 internal constant REAL_COMMIT = hex"11d58e0dae448dfe449feafce38fd619eb85d6a2";

    function setUp() public {
        _fork();
        vm.deal(DEFAULT_SENDER, 1 ether);
    }

    function _nonPrintable(bytes memory b) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < b.length; i++) {
            if (uint8(b[i]) < 0x20 || uint8(b[i]) > 0x7e) n++;
        }
    }

    /// Whatever REPO_URL holds, it reaches nothing. (No other test reads or sets REPO_URL.)
    function test_review_ignite_noFreeTextReachesTheStory() public {
        vm.setEnv("REPO_URL", unicode"audited by a top firm. SOURCE: none​\n");
        Splitter s = new Ignite().ignite(DEFAULT_SENDER, REAL_COMMIT, false);
        string memory story = ITransistors(s.TRANSISTORS()).story();

        assertEq(bytes(story).length, 1366, "the length depends on nothing the deployer types");
        assertEq(_nonPrintable(bytes(story)), 0, "the immutable story is printable ASCII");
        assertFalse(vm.contains(story, "top firm"));
        assertFalse(vm.contains(story, "SOURCE: none"));
        assertTrue(
            vm.contains(
                story, "SOURCE: https://github.com/OoJae/covenant commit 11d58e0dae448dfe449feafce38fd619eb85d6a2."
            )
        );
        assertEq(vm.split(story, "http").length - 1, 1, "one URL, the fixed one");
    }

    /// The only text input left is the commit, and it must be exactly 20 bytes of hex.
    function test_review_ignite_commitIsTheOnlyTextInput_andItIsParsedStrictly() public {
        Ignite script = new Ignite();
        string[5] memory bad = [
            unicode"11d58e0dae448dfe449feafce38fd619eb85d6a2​", // with a zero-width space
            "11d58e0dae448dfe449feafce38fd619eb85d6a2\n", // with a line break
            "11d58e0dae448dfe449feafce38fd619eb85d6a", // 39 characters
            "11d58e0", // a short hash
            "HEAD"
        ];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.expectRevert();
            script.parseCommit(bad[i]);
        }
        assertEq(script.parseCommit("11d58e0dae448dfe449feafce38fd619eb85d6a2"), REAL_COMMIT);
    }
}
