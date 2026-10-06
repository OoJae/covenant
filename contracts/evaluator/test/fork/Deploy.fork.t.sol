// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DeployEvaluator} from "../../script/DeployEvaluator.s.sol";
import {Fab} from "../../src/Fab.sol";
import {SealedVM} from "../../src/SealedVM.sol";
import {NetlistBuilder} from "../utils/NetlistBuilder.sol";
import {ICircuitsView, ITapeOutFactory} from "../utils/Oracles.sol";
import {XLayerFork} from "../utils/XLayerFork.sol";

/// @notice The deploy script, run inside the fork against a processor created through the real factory.
contract DeployEvaluatorForkTest is XLayerFork {
    DeployEvaluator internal script;
    address internal transistors;
    address internal circuits;

    function setUp() public {
        _selectFork();
        ITapeOutFactory factory = ITapeOutFactory(TAPEOUT_FACTORY);
        address creator = makeAddr("splitter");
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        (transistors, circuits) =
            factory.createCPU{value: factory.deployFee()}("Covenant", "CVNT", "script test", 67_108_864, 0.00002 ether);
        script = new DeployEvaluator();
    }

    function test_fork_script_deploysBoth_andTheyWork() public {
        (SealedVM sealedVM, Fab fab) = script.deploy(circuits, transistors);

        assertEq(address(fab.CIRCUITS()), circuits);
        assertEq(address(fab.TRANSISTORS()), transistors);
        _assertSmallestChipQuote(fab);

        // the deployed pair tapes out a chip and evaluates it like TapeOut does
        bytes memory nl = NetlistBuilder.minimalV1(8);
        (,, uint256 cost) = fab.quote(nl);
        address alice = makeAddr("alice");
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        uint256 chipId = fab.tapeoutChip{value: cost}(nl, bytes32(0));
        (address pointer,,,,,) = fab.chipInfo(chipId);

        bytes memory state = hex"a5";
        bytes memory inputs = NetlistBuilder.randomBytes(1, 12);
        (bytes memory nsT, bytes memory outT) = ICircuitsView(circuits).step(chipId, state, inputs);
        (bytes memory nsS, bytes memory outS) = sealedVM.step(pointer, 96, 112, state, inputs);
        assertEq(nsS, nsT);
        assertEq(outS, outT);
    }

    /// @dev The smallest chip (111 NAND + 1 LATCH) at the processor's prices of the fork block. The Fab stores
    ///      no price; this is what it reads from the processor now.
    function _assertSmallestChipQuote(Fab fab) internal view {
        bytes memory smallest = hex"01000000";
        for (uint256 i = 0; i < 111; i++) {
            smallest = bytes.concat(smallest, hex"00000000000001");
        }
        (uint256 nNand, uint256 nLatch, uint256 cost) = fab.quote(smallest);
        assertEq(nNand, 111);
        assertEq(nLatch, 1);
        assertEq(cost, 0.00002 ether * 112 + 2 * 0.00066 ether + 0.0013 ether);
    }

    function test_fork_script_refusesAPairThatIsNotOneProcessor() public {
        ITapeOutFactory factory = ITapeOutFactory(TAPEOUT_FACTORY);
        vm.deal(address(this), 1 ether);
        (address t2,) = factory.createCPU{value: factory.deployFee()}("Other", "OTH", "", 1000, 1);

        vm.expectRevert(bytes("DeployEvaluator: transistors do not match"));
        script.deploy(circuits, t2);
        vm.expectRevert(bytes("DeployEvaluator: circuits is not a TapeOut processor"));
        script.deploy(transistors, circuits);
        vm.expectRevert(bytes("DeployEvaluator: circuits is not a TapeOut processor"));
        script.deploy(makeAddr("nobody"), transistors);
    }

    function test_fork_script_refusesAnotherChain() public {
        vm.chainId(1);
        vm.expectRevert(bytes("DeployEvaluator: not X Layer (chain 196)"));
        script.deploy(circuits, transistors);
    }
}
