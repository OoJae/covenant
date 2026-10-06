// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Splitter} from "../../src/Splitter.sol";
import {MockTransistors, MockCircuits} from "../mocks/MockTapeOut.sol";

/// @dev A factory that behaves like TapeOut's in every way the first Splitter's constructor checked, but can
///      store a different name, a different symbol, or the story cut to 280 bytes (the limit of TapeOut's own
///      create form).
contract ManglingFactory {
    uint256 public deployFee = 0.0066 ether;
    uint256 public protocolFee = 0.00066 ether;
    bool public isSealed;
    mapping(address => bool) public isCPU;
    mapping(address => uint256) public owed;

    bool internal immutable MANGLE_NAME;
    bool internal immutable MANGLE_SYMBOL;
    bool internal immutable MANGLE_STORY;

    constructor(bool mangleName, bool mangleSymbol, bool mangleStory) {
        MANGLE_NAME = mangleName;
        MANGLE_SYMBOL = mangleSymbol;
        MANGLE_STORY = mangleStory;
    }

    function createCPU(
        string calldata name,
        string calldata symbol,
        string calldata story,
        uint256 supply,
        uint256 price
    ) external payable returns (address, address) {
        require(msg.value >= deployFee, "deploy fee");
        MockCircuits circuits = new MockCircuits(0.0013 ether);
        MockTransistors.Init memory i;
        i.name = MANGLE_NAME ? "Somebody else" : name;
        i.symbol = MANGLE_SYMBOL ? "CPU" : symbol;
        i.story = MANGLE_STORY ? string(bytes(story)[:280]) : story;
        i.creator = msg.sender;
        i.supplyCap = supply;
        i.mintPrice = price;
        i.protocolWallet = address(0xFEE);
        i.protocolFee = protocolFee;
        i.circuits = address(circuits);
        MockTransistors transistors = new MockTransistors(i);
        circuits.setTransistors(address(transistors));
        isCPU[address(circuits)] = true;
        owed[address(0xFEE)] += deployFee;
        return (address(transistors), address(circuits));
    }
}

/// @notice Review test (story lens). When it was reviewed, three of the processor's five immutable parameters
///         were not read back: with this factory creation SUCCEEDED and the processor carried a cut story and
///         somebody else's name and symbol. The constructor now reads all three back: creation reverts, for
///         each of the three on its own.
contract StoryReviewTest is Test {
    bytes20 internal constant COMMIT = hex"11d58e0dae448dfe449feafce38fd619eb85d6a2";
    address internal constant MAINTAINER = 0x84cE7bAe1b788C7aD985D57721cA428b401aE34D;

    function test_review_constructorReadsBackNameSymbolAndStory() public {
        // what the reviewer's factory did: all three at once
        ManglingFactory all = new ManglingFactory(true, true, true);
        vm.expectRevert(Splitter.ProcessorMismatch.selector);
        new Splitter{value: 0.0066 ether}(address(all), MAINTAINER, COMMIT);

        // each of the three alone is enough
        bool[3][3] memory one = [[true, false, false], [false, true, false], [false, false, true]];
        for (uint256 k = 0; k < one.length; k++) {
            ManglingFactory factory = new ManglingFactory(one[k][0], one[k][1], one[k][2]);
            vm.expectRevert(Splitter.ProcessorMismatch.selector);
            new Splitter{value: 0.0066 ether}(address(factory), MAINTAINER, COMMIT);
        }

        // the same factory mangling nothing: creation succeeds, and the processor carries what it was given
        ManglingFactory honest = new ManglingFactory(false, false, false);
        Splitter s = new Splitter{value: 0.0066 ether}(address(honest), MAINTAINER, COMMIT);
        MockTransistors t = MockTransistors(s.TRANSISTORS());
        assertEq(bytes(t.story()).length, 1366);
        assertEq(t.cpuName(), "Covenant");
        assertEq(t.cpuSymbol(), "CVNT");
        assertEq(t.creator(), address(s));
        assertEq(t.supplyCap(), 67_108_864);
        assertEq(t.mintPrice(), 0.00002 ether);
    }
}
