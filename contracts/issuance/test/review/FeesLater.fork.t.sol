// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {XLayerFork} from "../fork/XLayerFork.sol";
import {Splitter} from "../../src/Splitter.sol";
import {ICircuitFactory} from "../../src/interfaces/ITapeOut.sol";

interface IFactoryFees {
    function owner() external view returns (address);
    function setProtocolFee(uint256 v) external;
    function setDeployFee(uint256 v) external;
    function seal() external;
    function isSealed() external view returns (bool);
}

/// @notice Review test (story lens): "TapeOut's own fees ... (at creation: 0.00066 OKB per mint call, ...)" and
///         "TapeOut's owner can upgrade processor logic".
///         Adapted: the third test showed that a Splitter created after TapeOut sealed its factory still wrote
///         that the factory was unsealed. The constructor now refuses to be created then.
contract FeesLaterForkTest is XLayerFork {
    function setUp() public {
        _forkAndIgnite();
    }

    function test_review_factoryFeeChangeAfterCreation_doesNotTouchThisProcessor() public {
        address tapeoutOwner = IFactoryFees(FACTORY).owner();
        vm.prank(tapeoutOwner);
        IFactoryFees(FACTORY).setProtocolFee(0.005 ether);
        assertEq(ICircuitFactory(FACTORY).protocolFee(), 0.005 ether);
        assertEq(transistors.protocolFee(), 0.00066 ether, "the clone keeps the fee it was created with");

        // minting still costs price * n + 0.00066
        vm.deal(user, 1 ether);
        vm.prank(user);
        transistors.mint{value: PRICE + 0.00066 ether}(0, 1);
        assertEq(transistors.owed(user), 0);
    }

    function test_review_factoryFeeChangeBeforeCreation_makesCreationRevert() public {
        address tapeoutOwner = IFactoryFees(FACTORY).owner();
        vm.prank(tapeoutOwner);
        IFactoryFees(FACTORY).setProtocolFee(0.005 ether);
        vm.expectRevert(Splitter.TapeOutFeesChanged.selector);
        new Splitter{value: 0.0066 ether}(FACTORY, maintainer, COMMIT);
    }

    function test_review_deployFeeChangeBeforeCreation_makesCreationRevert() public {
        address tapeoutOwner = IFactoryFees(FACTORY).owner();
        vm.prank(tapeoutOwner);
        IFactoryFees(FACTORY).setDeployFee(0.0067 ether);
        vm.expectRevert(Splitter.WrongDeployFee.selector);
        new Splitter{value: 0.0066 ether}(FACTORY, maintainer, COMMIT);
    }

    /// The story of the first processor (created in setUp, before the seal) stays true of its creation block.
    /// A second one cannot be created once the factory is sealed: its story would say that TapeOut's owner
    /// can upgrade processor logic, and there is no owner any more.
    function test_review_sealedFactory_creationReverts() public {
        address tapeoutOwner = IFactoryFees(FACTORY).owner();
        vm.prank(tapeoutOwner);
        IFactoryFees(FACTORY).seal();
        assertTrue(IFactoryFees(FACTORY).isSealed());
        assertEq(IFactoryFees(FACTORY).owner(), address(0));

        vm.expectRevert(Splitter.FactorySealed.selector);
        new Splitter{value: 0.0066 ether}(FACTORY, maintainer, COMMIT);

        assertTrue(vm.contains(transistors.story(), "TRUST (at creation): unaudited; TapeOut's owner can upgrade"));
    }
}
