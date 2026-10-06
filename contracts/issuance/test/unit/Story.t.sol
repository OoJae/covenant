// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LocalBase} from "../utils/LocalBase.sol";
import {Story} from "../../script/lib/Story.sol";
import {Splitter} from "../../src/Splitter.sol";
import {MockTransistors} from "../mocks/MockTapeOut.sol";

/// @notice The story the processor carries forever, checked against three things that do not share code:
///
///           1. the approved text itself: test/fixtures/story.head.txt and story.tail.txt, byte for byte,
///              with {S} {T} {A} {R} replaced by addresses and {C} by the commit;
///           2. the template in script/lib/Story.sol, which the Ignite script prints and checks;
///           3. what TapeOut's own site does with a story: it shows the first 600 characters, hides every
///              0x address and rewrites every URL. So those 600 characters must stand alone.
contract StoryTest is LocalBase {
    // keccak256 of the two approved files: neither can change without this test changing too
    bytes32 internal constant HEAD_KECCAK = 0xec272a5dc1af4735c4e9a081fa8e655f51885d5a9b5c092a7bf63617ba211f97;
    bytes32 internal constant TAIL_KECCAK = 0xe500fa79a5a5a65e02ee589c267b41e2c52e11e592d93fe2cd725bdb28925795;

    uint256 internal constant HEAD_LENGTH = 556;
    uint256 internal constant SHOWN = 600; // what TapeOut's site shows

    // LocalBase.COMMIT as git prints it
    string internal constant COMMIT_TEXT = "a1b2c3d4e5f60718293a4b5c6d7e8f9001234567";

    string internal story;

    function setUp() public {
        _deployLocal(maintainer);
        story = transistors.story();
    }

    // ------------------------------------------------------------------ helpers

    function _slice(string memory text, uint256 from, uint256 to) internal pure returns (string memory) {
        bytes memory all = bytes(text);
        bytes memory part = new bytes(to - from);
        for (uint256 i = from; i < to; i++) {
            part[i - from] = all[i];
        }
        return string(part);
    }

    function _count(string memory text, string memory needle) internal pure returns (uint256) {
        return vm.split(text, needle).length - 1;
    }

    /// @dev the approved text with its placeholders filled in, built from the two files and nothing else
    function _approved(
        address splitter_,
        address tank_,
        address maintainer_,
        address registry_,
        string memory commitText
    ) internal view returns (string memory) {
        string memory tail = vm.readFile("test/fixtures/story.tail.txt");
        tail = vm.replace(tail, "{S}", vm.toString(splitter_));
        tail = vm.replace(tail, "{T}", vm.toString(tank_));
        tail = vm.replace(tail, "{A}", vm.toString(maintainer_));
        tail = vm.replace(tail, "{R}", vm.toString(registry_));
        tail = vm.replace(tail, "{C}", commitText);
        return string.concat(vm.readFile("test/fixtures/story.head.txt"), tail);
    }

    // ------------------------------------------------------------------ 1. the approved text

    function test_fixtures_areTheApprovedFiles() public view {
        string memory head = vm.readFile("test/fixtures/story.head.txt");
        string memory tail = vm.readFile("test/fixtures/story.tail.txt");
        assertEq(bytes(head).length, HEAD_LENGTH);
        assertEq(bytes(tail).length, 617);
        assertEq(keccak256(bytes(head)), HEAD_KECCAK);
        assertEq(keccak256(bytes(tail)), TAIL_KECCAK);

        // each placeholder once, in the tail only
        string[5] memory placeholders = ["{S}", "{T}", "{A}", "{R}", "{C}"];
        for (uint256 i = 0; i < placeholders.length; i++) {
            assertEq(_count(tail, placeholders[i]), 1);
            assertEq(_count(head, placeholders[i]), 0);
        }
        assertEq(_count(tail, "{"), 5);
        assertEq(_count(head, "{"), 0);
    }

    function test_story_isTheApprovedText_byteForByte() public view {
        string memory approved = _approved(address(splitter), address(tank), maintainer, address(registry), COMMIT_TEXT);
        assertEq(story, approved);
        assertEq(keccak256(bytes(story)), keccak256(bytes(approved)));
        assertEq(_count(story, "{"), 0, "a placeholder was left in");
        assertEq(_count(story, "}"), 0);

        // 556 + 617, less five placeholders of three characters, plus four addresses and one commit
        assertEq(bytes(story).length, 556 + 617 - 5 * 3 + 4 * 42 + 40);
        assertEq(bytes(story).length, 1366);
    }

    /// The same for any deployer nonce, maintainer and commit: the three renderings agree.
    function testFuzz_story_isTheApprovedText(address maintainer_, bytes20 commit, uint8 nonces) public {
        vm.assume(maintainer_ != address(0) && commit != bytes20(0));
        vm.setNonce(address(this), vm.getNonce(address(this)) + uint64(nonces));
        Splitter s = new Splitter{value: factory.deployFee()}(address(factory), maintainer_, commit);
        string memory onChain = MockTransistors(s.TRANSISTORS()).story();

        string memory commitText = vm.replace(vm.toString(abi.encodePacked(commit)), "0x", "");
        assertEq(bytes(commitText).length, 40);
        assertEq(onChain, _approved(address(s), s.TANK(), maintainer_, s.REGISTRY(), commitText));
        assertEq(onChain, Story.expected(address(s), s.TANK(), maintainer_, s.REGISTRY(), commit));
        assertEq(bytes(onChain).length, 1366);
    }

    // ------------------------------------------------------------------ 2. the template the script uses

    function test_story_equalsTheScriptsTemplate() public view {
        assertEq(story, Story.expected(address(splitter), address(tank), maintainer, address(registry), COMMIT));
        assertEq(Story.head(), vm.readFile("test/fixtures/story.head.txt"));
        assertEq(Story.commitHex(COMMIT), COMMIT_TEXT);
        assertEq(Story.shown(story), _slice(story, 0, SHOWN));
        assertEq(Story.shown("short"), "short");
    }

    // ------------------------------------------------------------------ 3. what TapeOut's site shows

    /// The first 600 characters say what a buyer must know and hold nothing the site would hide or rewrite.
    function test_story_first600Characters_standAlone() public view {
        string memory shown = _slice(story, 0, SHOWN);
        assertEq(bytes(shown).length, 600);

        assertTrue(vm.contains(shown, "SUPPLY"));
        assertTrue(vm.contains(shown, "PRICE"));
        assertTrue(vm.contains(shown, "85%"));
        assertTrue(vm.contains(shown, "15%"));
        assertTrue(vm.contains(shown, "TRUST"));

        assertFalse(vm.contains(shown, "0x"), "an address in the part TapeOut's site shows: it would be hidden");
        assertFalse(vm.contains(shown, "http"), "a URL in the part TapeOut's site shows: it would be rewritten");

        // the head is whole inside those 600 characters, and they do not depend on any address
        assertEq(_slice(story, 0, HEAD_LENGTH), vm.readFile("test/fixtures/story.head.txt"));
        assertEq(_slice(shown, HEAD_LENGTH, SHOWN), "DETAILS: TapeOut's own fees are extra and no");
    }

    /// The sentences of the head, each checked against the constant it states.
    function test_story_head_saysWhatTheContractsDo() public view {
        string memory head = _slice(story, 0, HEAD_LENGTH);

        assertTrue(vm.contains(head, "COVENANT (CVNT)"));
        assertEq(splitter.NAME(), "Covenant");
        assertEq(splitter.SYMBOL(), "CVNT");

        assertTrue(vm.contains(head, "SUPPLY 67,108,864 (2^26), fixed"));
        assertEq(splitter.SUPPLY(), 67_108_864);
        assertEq(splitter.SUPPLY(), 2 ** 26);

        assertTrue(vm.contains(head, "PRICE 0.00002 OKB each, fixed"));
        assertEq(splitter.PRICE(), 0.00002 ether);

        assertTrue(vm.contains(head, "85% keeper tank"));
        assertTrue(vm.contains(head, "15% maintainer"));
        assertEq(splitter.TANK_BPS(), 8500);
        assertEq(splitter.MAINTAINER_BPS(), 1500);
        // the two shares are the whole: there is no third payee to name
        assertEq(splitter.TANK_BPS() + splitter.MAINTAINER_BPS(), 10_000);
        assertTrue(vm.contains(head, "(prepays the settlement gas of the chips whose transistors paid in)"));

        assertTrue(vm.contains(head, "TRUST (at creation): unaudited; TapeOut's owner can upgrade processor logic. "));
        assertFalse(factory.isSealed());
    }

    /// The details, each checked the same way.
    function test_story_tail_saysWhatTheContractsDo() public view {
        assertTrue(vm.contains(story, "0.00066 OKB per mint call, 0.0013 OKB per tape-out"));
        assertEq(transistors.protocolFee(), 0.00066 ether);
        assertEq(circuits.TAPEOUT_FEE(), 0.0013 ether);

        assertTrue(vm.contains(story, string.concat("creator and payee is splitter ", vm.toString(address(splitter)))));
        assertEq(transistors.creator(), address(splitter));
        assertTrue(vm.contains(story, string.concat("Keeper tank ", vm.toString(address(tank)))));
        assertEq(splitter.TANK(), address(tank));
        // the allowance the story states is the one the tank grants
        assertTrue(
            vm.contains(
                story,
                "up to that chip's prepaid allowance (85% of the mint price of the transistors it burned, plus top-ups)"
            )
        );
        assertEq(tank.ALLOWANCE_BPS(), 8500);
        assertEq(tank.mintPrice(), splitter.PRICE());
        assertTrue(vm.contains(story, string.concat("Maintainer ", vm.toString(maintainer), ".")));
        assertEq(splitter.MAINTAINER(), maintainer);
        assertTrue(vm.contains(story, string.concat("listed in registry ", vm.toString(address(registry)))));
        assertEq(splitter.REGISTRY(), address(registry));

        // "the deployer, then wallets that a listed wallet invited and that declared themselves"
        (address first, string memory role,) = registry.at(0);
        assertEq(first, address(this));
        assertEq(role, "deployer");

        // nothing is reserved for anyone else: no escrow, no launchpad share, no IgnixManager
        assertFalse(vm.contains(story, "escrow"));
        assertFalse(vm.contains(story, "socket"));
        assertFalse(vm.contains(story, "IgnixManager"));
        assertFalse(vm.contains(story, "25%"));
    }

    // ------------------------------------------------------------------ the bytes

    function test_story_isPrintableAscii() public view {
        bytes memory b = bytes(story);
        for (uint256 i = 0; i < b.length; i++) {
            assertTrue(uint8(b[i]) >= 0x20 && uint8(b[i]) <= 0x7e, "a byte outside 0x20..0x7e in the story");
        }
        // one line, no doubled space, no space at either end, a full stop at the end
        assertEq(_count(story, "  "), 0);
        assertTrue(b[0] != " ");
        assertEq(b[b.length - 1], bytes1("."));
    }

    /// The commit is written the way git prints it: 40 lower-case hex characters and no 0x in front, which
    /// TapeOut's site would take for an address and hide.
    function test_story_commitIs40BareHexCharacters() public view {
        bytes memory b = bytes(story);
        uint256 end = b.length - 1; // the final full stop
        uint256 start = end - 40;

        for (uint256 i = start; i < end; i++) {
            bool digit = b[i] >= "0" && b[i] <= "9";
            bool lowerHex = b[i] >= "a" && b[i] <= "f";
            assertTrue(digit || lowerHex, "the commit is not 40 lower-case hex characters");
        }
        assertEq(_slice(story, start, end), COMMIT_TEXT);
        assertEq(_slice(story, start - 8, start), " commit ", "something stands between 'commit' and the hash");
        assertFalse(vm.contains(story, string.concat("0x", COMMIT_TEXT)));

        // the only 0x in the whole story are the four addresses
        assertEq(_count(story, "0x"), 4);
        // and the only URL is the repository, once
        assertEq(_count(story, "http"), 1);
        assertTrue(
            vm.contains(story, string.concat("SOURCE: https://github.com/OoJae/covenant commit ", COMMIT_TEXT, "."))
        );
    }

    /// A commit that starts with zero bytes keeps all its 40 characters; one made of letters stays lower-case.
    function test_story_commit_keepsLeadingZeros_andLowerCase() public {
        bytes20[3] memory commits = [
            bytes20(hex"00000000e5f60718293a4b5c6d7e8f9001234567"),
            bytes20(hex"0000000000000000000000000000000000000001"),
            bytes20(hex"abcdefabcdefabcdefabcdefabcdefabcdefabcd")
        ];
        string[3] memory texts = [
            "00000000e5f60718293a4b5c6d7e8f9001234567",
            "0000000000000000000000000000000000000001",
            "abcdefabcdefabcdefabcdefabcdefabcdefabcd"
        ];
        for (uint256 i = 0; i < commits.length; i++) {
            Splitter s = new Splitter{value: factory.deployFee()}(address(factory), maintainer, commits[i]);
            string memory onChain = MockTransistors(s.TRANSISTORS()).story();
            assertEq(bytes(onChain).length, 1366);
            assertTrue(vm.contains(onChain, string.concat(" commit ", texts[i], ".")));
        }
    }

    /// Every address is written in EIP-55 mixed case, once.
    function test_story_namesFourAddresses_checksummed_once() public view {
        address[4] memory named = [address(splitter), address(tank), maintainer, address(registry)];
        for (uint256 i = 0; i < named.length; i++) {
            string memory checksummed = vm.toString(named[i]);
            assertEq(_count(story, checksummed), 1);
            // an address with a letter in it is not written in lower case
            if (keccak256(bytes(checksummed)) != keccak256(bytes(vm.toLowercase(checksummed)))) {
                assertEq(_count(story, vm.toLowercase(checksummed)), 0);
            }
        }
        // the processor's own two contracts are not in the story: they do not exist when it is written
        assertEq(_count(story, vm.toString(address(transistors))), 0);
        assertEq(_count(story, vm.toString(address(circuits))), 0);
    }
}
