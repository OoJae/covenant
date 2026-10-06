// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IKernelMin, Envelope} from "core/interfaces/IKernelV1.sol";

/// @title Covenant kernel ABI v2 (chips/INTERFACE-V2.md)
/// @notice A kernel v2 is the RECIPIENT of an IGNIX Directed vault whose quote is an ERC-20 (USD₮0). Everything
///         that is not about the quote asset is kernel v1 (chips/INTERFACE.md, revision 2). `chipId()` and
///         `settle()` are `IKernelMin`, unchanged, so the immutable KeeperTank serves v2 kernels as they are.

/// @notice Everything a v2 kernel knows besides its envelope. Written once into the clone's bytecode by the
///         factory: a clone's immutable arguments are `abi.encode(GlobalsV2, Envelope)`.
struct GlobalsV2 {
    address manager; // IgnixManager (UUPS proxy)
    address v2Router; // Uniswap V2 Router02
    address quote; // the ERC-20 quote asset (USD₮0 on X Layer)
    address factory; // the KernelFactoryV2 that created this clone
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
    uint256 stepFloor; // gas for one step of TapeOut's evaluator: 200,000 + 2,600 * gateCount + 800 * nState
    uint256 sealedFloor; // gas for one step of the sealed evaluator: 40,000 + 200 * nNand + 400 * nState
    // Code shift, in bits, applied to quote-asset amounts before the chip sees them (curve regime only):
    // the chip reads lg8(amount << quoteShift) = lg8(amount) + 8 * quoteShift. 33 for USD₮0 (NOTES.md).
    uint256 quoteShift;
}

/// @notice One settle. Same 14-word layout as kernel v1's `Record`; the last field is the quote asset (USD₮0)
///         that the post-graduation router buy spent, where kernel v1 has native OKB.
struct RecordV2 {
    uint32 epoch;
    uint40 time;
    uint16 clampBits;
    uint8 flags; // core/interfaces/IKernelV1.sol RecordFlags, unchanged
    bytes12 inputs; // exactly the bytes passed to step
    bytes14 outputs; // exactly the bytes returned by step (or the fallback word)
    bytes32 stateAfter;
    uint128 inflow; // regime asset: USD₮0 on the curve, the project token after graduation
    uint128 reserveBefore; // regime asset
    uint128 allow; // USD₮0 credited to the allowance payee (0 after graduation)
    uint128 buyDecided; // regime asset
    uint128 buyExecuted; // regime asset: USD₮0 spent on the curve, or tokens that left for 0xdEaD
    uint128 tokensOut; // tokens received on the curve, or tokens that reached 0xdEaD (both legs) after graduation
    uint128 quoteIn; // USD₮0 spent by the post-graduation router buy (0 on the curve)
}

interface IKernelFactoryV2Callback {
    function noteBound(address token) external;
}

interface IKernelV2 is IKernelMin {
    event Settled(
        uint32 indexed n,
        uint32 epoch,
        bytes12 inputs,
        bytes14 outputs,
        uint16 clampBits,
        uint8 flags,
        bytes32 stateAfter,
        uint128 inflow,
        uint128 allow,
        uint128 buyDecided,
        uint128 buyExecuted,
        uint128 tokensOut
    );

    function bind(address token) external;
    function withdrawCredit(address payee, address asset) external returns (uint256 paid); // anyone; pays only payee
    function burnLocked() external returns (uint256 burned); // after graduation; anyone may call
    function token() external view returns (address);
    function vault() external view returns (address);
    function count() external view returns (uint32);
    function records(uint32 n) external view returns (RecordV2 memory); // all zero for n = 0 or n > count
    function cums(uint32 n) external view returns (uint128 cumInflow, uint128 allowPaidCum);
    function state() external view returns (bytes32);
    function epochNow() external view returns (uint32);
    function lastEpoch() external view returns (uint32);
    function lastStepEpoch() external view returns (uint32);
    function bindTime() external view returns (uint40);
    function reserve() external view returns (uint256); // regime asset, as of the last settle
    function creditOf(address payee, address asset) external view returns (uint256);
    function totalCredits(address asset) external view returns (uint256);
    function lockedTokens() external view returns (uint256);
    function burnedTokens() external view returns (uint128);
    function graduated() external view returns (bool);
    function pair() external view returns (address);
    function envelope() external view returns (Envelope memory);
    function evaluator() external view returns (address vm, bool sealedMode);
    function minSettleGas() external view returns (uint256);
    // ---- v2
    function globals() external view returns (GlobalsV2 memory);
    function quote() external view returns (address); // the quote asset this kernel routes on the curve
    function quoteShift() external view returns (uint256); // code shift in bits (curve regime)
    function cumInflow() external view returns (uint128);
    function allowPaidCum() external view returns (uint128);
    function tokenSupply() external view returns (uint256);
}
