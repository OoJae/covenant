// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {CircuitFactory} from "tapeout/CircuitFactory.sol";
import {Circuits} from "tapeout/Circuits.sol";
import {Transistors} from "tapeout/Transistors.sol";

/// @notice Test fixture: TapeOut's own contracts, compiled unmodified from the vendored verified source
///         (contracts/vendor/tapeout-xlayer) and wired the way they are on X Layer: a UUPS factory that
///         owns two beacons, every processor a pair of beacon proxies.
/// @dev Lets the Fab suite run without a network. The fork suite runs the same tests against the
///      deployed contracts.
contract LocalTapeOut {
    address public immutable factory;

    constructor(address owner, address protocolWallet, uint256 deployFee, uint256 protocolFee) {
        address transistorImpl = address(new Transistors());
        address circuitImpl = address(new Circuits());
        address factoryImpl = address(new CircuitFactory());
        factory = address(
            new ERC1967Proxy(
                factoryImpl,
                abi.encodeCall(
                    CircuitFactory.initialize,
                    (owner, transistorImpl, circuitImpl, protocolWallet, deployFee, protocolFee)
                )
            )
        );
    }

    /// @dev The treasury address is a constant of TapeOut's circuit implementation.
    function treasury() external view returns (address) {
        return Circuits(CircuitFactory(factory).circuitBeacon().implementation()).TREASURY();
    }
}
