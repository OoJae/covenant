// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LocalBase} from "../utils/LocalBase.sol";
import {Story} from "../../script/lib/Story.sol";
import {Splitter} from "../../src/Splitter.sol";
import {MockTransistors} from "../mocks/MockTapeOut.sol";

/// @notice Review test (splitter lens), adapted to the story without a repository argument.
///         The story for ANY maintainer, deployer nonce and commit equals the independent template:
///         OpenZeppelin's EIP-55 rendering against Foundry's, and the commit rendered with its leading zeros.
contract StoryFuzzTest is LocalBase {
    function setUp() public {
        _deployLocal(maintainer);
    }

    function _check(address maintainer_, bytes20 commit) internal {
        Splitter s = new Splitter{value: factory.deployFee()}(address(factory), maintainer_, commit);
        string memory onChain = MockTransistors(s.TRANSISTORS()).story();
        string memory expected = Story.expected(address(s), s.TANK(), maintainer_, s.REGISTRY(), commit);
        assertEq(onChain, expected);
    }

    function testFuzz_story_matchesTheTemplate(address maintainer_, bytes20 commit, uint8 burnNonces) public {
        vm.assume(maintainer_ != address(0) && commit != bytes20(0));
        // move this contract's nonce so that the splitter and its two children land on fresh addresses
        vm.setNonce(address(this), vm.getNonce(address(this)) + uint64(burnNonces));
        _check(maintainer_, commit);
    }

    function test_story_commitWithLeadingZeros_keepsAll40HexDigits() public {
        _check(maintainer, hex"00000000e5f60718293a4b5c6d7e8f9001234567");
        _check(maintainer, hex"0000000000000000000000000000000000000001");
        _check(address(1), hex"0a00000000000000000000000000000000000000");
    }
}
