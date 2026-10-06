// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IFabV1
/// @notice Covenant interface v1, section 11 (chips/INTERFACE.md, revision 2). Copied verbatim from that document.
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
