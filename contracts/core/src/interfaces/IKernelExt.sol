// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IKernelV1} from "./IKernelV1.sol";

/// @notice Everything a kernel knows besides its envelope. Written once into the clone's bytecode by the factory.
/// @dev    A clone's immutable arguments are `abi.encode(Globals, Envelope)`; the kernel decodes them whole.
struct Globals {
    address manager; // IgnixManager (UUPS proxy)
    address v2Router; // Uniswap V2 Router02
    address wokb; // wrapped native OKB
    address factory; // the KernelFactory that created this clone
    address circuits; // the Covenant processor's Circuits contract (ERC-721 and TapeOut evaluator)
    address fab; // the Fab that taped the chip out and holds its netlist snapshot
    address sealedVM; // the sealed evaluator
    address beacon; // TapeOut's circuit beacon
    address impl0; // the pinned TapeOut circuit implementation
    bytes32 impl0Hash; // code hash of that implementation
    address snapshot; // SSTORE2 pointer: 0x00 followed by the chip's exact netlist bytes
    bytes32 netlistHash; // keccak256 of the netlist bytes
    uint256 chipId; // id of the chip in `circuits`
    uint32 nState; // number of latches, 1..256
    uint32 gateCount; // NAND + LATCH records
    uint32 netlistLen; // netlist bytes
    uint256 stepFloor; // gas given to one step of TapeOut's evaluator: 200,000 + 2,600 * gateCount + 800 * nState
    uint256 sealedFloor; // gas given to one step of the sealed evaluator: 40,000 + 200 * nNand + 400 * nState
}

interface IKernelFactoryCallback {
    function noteBound(address token) external;
}

/// @notice Kernel v1 members that are not part of the frozen ABI of chips/INTERFACE.md section 10.
///         The Lens, the tests and the dashboard use them; nothing immutable depends on them.
interface IKernelExt is IKernelV1 {
    function globals() external view returns (Globals memory);
    function cumInflow() external view returns (uint128);
    function allowPaidCum() external view returns (uint128);
    function tokenSupply() external view returns (uint256);
}
