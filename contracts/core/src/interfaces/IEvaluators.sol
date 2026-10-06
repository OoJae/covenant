// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Fab ABI v1 (chips/INTERFACE.md section 11), copied verbatim from that document.
interface IFabV1 {
    function tapeoutChip(bytes calldata netlist, bytes32 manifestHash) external payable returns (uint256 chipId);
    function tapeoutChipTo(bytes calldata netlist, bytes32 manifestHash, address to)
        external
        payable
        returns (uint256 chipId);
    function quote(bytes calldata netlist) external view returns (uint256 nNand, uint256 nLatch, uint256 cost);
    function isChip(uint256 chipId) external view returns (bool);
    function chipInfo(uint256 chipId)
        external
        view
        returns (
            address snapshot,
            bytes32 netlistHash,
            uint32 nState,
            uint32 gateCount,
            address author,
            bytes32 manifestHash
        );
    function snapshot(uint256 chipId) external view returns (bytes memory);
}

/// @title Sealed evaluator (chips/INTERFACE.md section 12), copied verbatim from that document.
interface ISealedVM {
    /// One TAP-20 beat over a flat netlist (NAND and LATCH records only) stored at an SSTORE2 pointer.
    /// Must return exactly what Circuits.step returns for the same netlist, state and inputs.
    function step(address snapshot, uint32 nIn, uint32 nOut, bytes calldata state, bytes calldata inputs)
        external
        view
        returns (bytes memory newState, bytes memory outputs);
}

/// @notice The parts of a TapeOut processor's circuit contract (ERC-721, a BeaconProxy) that the kernel reads.
/// @dev    Signatures from TapeOut's verified MIT source (contracts/vendor/tapeout-xlayer/src/Circuits.sol,
///         implementation 0x977f217887E085D298Cb3819cDAD5A0ee35F29B2 on X Layer).
interface ICircuits {
    function step(uint256 circuitId, bytes calldata state, bytes calldata inputs)
        external
        view
        returns (bytes memory newState, bytes memory outputs);
    function netlist(uint256 circuitId) external view returns (bytes memory);
    function circuitInfo(uint256 circuitId)
        external
        view
        returns (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount);
    function ownerOf(uint256 circuitId) external view returns (address);
}

/// @notice OpenZeppelin UpgradeableBeacon, as used by TapeOut's factory for every processor.
interface IBeacon {
    function implementation() external view returns (address);
}
