// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {Fab} from "../src/Fab.sol";
import {SealedVM} from "../src/SealedVM.sol";

interface IFactoryLike {
    function isCPU(address circuits) external view returns (bool);
}

interface ICircuitsLike {
    function factory() external view returns (address);
    function transistors() external view returns (address);
    function TAPEOUT_FEE() external view returns (uint256);
    function nextId() external view returns (uint256);
}

interface ITransistorsLike {
    function circuits() external view returns (address);
    function mintPrice() external view returns (uint256);
    function protocolFee() external view returns (uint256);
    function supplyCap() external view returns (uint256);
    function minted() external view returns (uint256);
    function cpuName() external view returns (string memory);
    function cpuSymbol() external view returns (string memory);
}

/// @title DeployEvaluator: deploys SealedVM and the Fab for one TapeOut processor on X Layer
/// @notice Two creations, no initialisation, nothing to configure afterwards: both contracts are
///         immutable from their first block.
///
///         Simulate (sends nothing, needs no key):
///
///           COVENANT_CIRCUITS=0x... COVENANT_TRANSISTORS=0x... \
///             forge script script/DeployEvaluator.s.sol --rpc-url https://rpc.xlayer.tech
///
///         The broadcast command, to be run by the wallet holder only, is in README.md.
contract DeployEvaluator is Script {
    /// @dev TapeOut's processor factory on X Layer.
    address internal constant TAPEOUT_FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    uint256 internal constant XLAYER_CHAIN_ID = 196;

    function run() external returns (SealedVM sealedVM, Fab fab) {
        return deploy(vm.envAddress("COVENANT_CIRCUITS"), vm.envAddress("COVENANT_TRANSISTORS"));
    }

    /// @param circuits    the circuit contract (ERC-721) of the Covenant processor
    /// @param transistors the transistor contract (ERC-1155) of the same processor
    function deploy(address circuits, address transistors) public returns (SealedVM sealedVM, Fab fab) {
        // ---- before: the two addresses are one processor of TapeOut's factory, on X Layer
        require(block.chainid == XLAYER_CHAIN_ID, "DeployEvaluator: not X Layer (chain 196)");
        require(IFactoryLike(TAPEOUT_FACTORY).isCPU(circuits), "DeployEvaluator: circuits is not a TapeOut processor");
        require(ICircuitsLike(circuits).factory() == TAPEOUT_FACTORY, "DeployEvaluator: processor of another factory");
        require(ICircuitsLike(circuits).transistors() == transistors, "DeployEvaluator: transistors do not match");
        require(ITransistorsLike(transistors).circuits() == circuits, "DeployEvaluator: circuits do not match");

        uint256 mintPrice = ITransistorsLike(transistors).mintPrice();
        uint256 protocolFee = ITransistorsLike(transistors).protocolFee();
        uint256 tapeoutFee = ICircuitsLike(circuits).TAPEOUT_FEE();

        // ---- the two transactions
        vm.startBroadcast();
        sealedVM = new SealedVM();
        fab = new Fab(circuits, transistors);
        vm.stopBroadcast();

        // ---- after: the Fab is wired to the processor, and prices the smallest chip from the processor's
        //      prices of this moment (it stores none of them)
        require(address(fab.CIRCUITS()) == circuits && address(fab.TRANSISTORS()) == transistors, "Fab: processor");

        (uint256 nNand, uint256 nLatch, uint256 cost) = fab.quote(_smallestChip());
        require(nNand == 111 && nLatch == 1, "Fab: quote counts");
        require(cost == mintPrice * 112 + 2 * protocolFee + tapeoutFee, "Fab: quote cost");

        console2.log(
            "processor            ", ITransistorsLike(transistors).cpuName(), ITransistorsLike(transistors).cpuSymbol()
        );
        console2.log("  circuits           ", circuits);
        console2.log("  transistors        ", transistors);
        console2.log("  supply cap         ", ITransistorsLike(transistors).supplyCap());
        console2.log("  minted so far      ", ITransistorsLike(transistors).minted());
        console2.log("  circuits taped out ", ICircuitsLike(circuits).nextId());
        console2.log("SealedVM             ", address(sealedVM));
        console2.log("Fab                  ", address(fab));
        console2.log("  prices today, read by the Fab on every call:");
        console2.log("  mint price (wei)   ", mintPrice);
        console2.log("  protocol fee (wei) ", protocolFee);
        console2.log("  tape-out fee (wei) ", tapeoutFee);
        console2.log("  smallest chip (wei)", cost);
    }

    /// @dev One LATCH that takes constant 0, then 111 NAND gates of the two constants: 112 records.
    function _smallestChip() internal pure returns (bytes memory nl) {
        nl = hex"01000000";
        for (uint256 i = 0; i < 111; i++) {
            nl = bytes.concat(nl, hex"00000000000001");
        }
    }
}
