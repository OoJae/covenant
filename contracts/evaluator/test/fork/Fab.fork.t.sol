// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FabSuite} from "../utils/FabSuite.sol";
import {ICircuitsView, ITapeOutFactory} from "../utils/Oracles.sol";
import {XLayerFork} from "../utils/XLayerFork.sol";

interface IBeacon {
    function implementation() external view returns (address);
}

/// @notice The Fab suite against TapeOut's deployed contracts, on an X Layer fork at a pinned block.
/// @dev The processor is created through the real factory (createCPU with the deploy fee), so its
///      transistor and circuit contracts are beacon proxies onto TapeOut's live implementations.
contract FabForkTest is FabSuite, XLayerFork {
    function _factory() internal override returns (ITapeOutFactory) {
        _selectFork();
        return ITapeOutFactory(TAPEOUT_FACTORY);
    }

    /// @notice The on-chain facts this package was written against, at the pinned block.
    function test_fork_pinnedFacts() public view {
        assertEq(factory.deployFee(), 0.0066 ether);
        assertEq(factory.protocolFee(), 0.00066 ether);
        assertEq(factory.circuitBeacon(), CIRCUIT_BEACON);
        assertEq(IBeacon(CIRCUIT_BEACON).implementation(), CIRCUIT_IMPL);
        assertEq(
            CIRCUIT_IMPL.codehash, CIRCUIT_IMPL_CODEHASH, "not the implementation the vendored source was read from"
        );
        assertEq(CIRCUIT_IMPL.code.length, 12562);
        assertEq(ICircuitsView(address(circuits)).TAPEOUT_FEE(), 0.0013 ether);
        assertEq(treasury, 0xEBeceDeA36e598b64E17f8d519EB77441C539F76);
        assertEq(treasury.code.length, 0);
        assertEq(transistors.supplyCap(), SUPPLY);
        assertEq(transistors.mintPrice(), MINT_PRICE);
        assertEq(transistors.creator(), creator);
    }

    /// forge-config: default.fuzz.runs = 96
    function testFuzz_acceptsExactlyV1Chips(uint256 seed) public {
        _checkAcceptsExactlyV1Chips(seed);
    }

    /// forge-config: default.fuzz.runs = 32
    function testFuzz_tapeout_invariants(uint256 seed, uint16 latchSeed, uint16 nandSeed, bool toBob) public {
        _checkTapeoutInvariants(seed, latchSeed, nandSeed, toBob);
    }
}
