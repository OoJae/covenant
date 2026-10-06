// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {Envelope} from "core/interfaces/IKernelV1.sol";
import {IFabV1} from "core/interfaces/IEvaluators.sol";

import {GlobalsV2, IKernelFactoryV2Callback} from "./interfaces/IKernelV2.sol";
import {KernelV2} from "./KernelV2.sol";

/// @title KernelFactoryV2
/// @notice Creates v2 kernels (KernelV2: an IGNIX Directed vault quoted in an ERC-20, USD₮0) as deterministic
///         clones whose whole configuration (envelope, chip pins, every address the kernel talks to, the quote
///         asset and its code shift) is the clone's bytecode. No owner, no setter, no upgrade path.
///
///         Kernel v1's factory (contracts/core/src/KernelFactory.sol) with two differences:
///           - the quote asset is a pin, in place of WOKB, and must answer decimals() with QUOTE_DECIMALS;
///           - the code shift is a pin (`quoteShift`, at most MAX_QUOTE_SHIFT bits), copied into every kernel.
///         The envelope checks are kernel v1's, number for number. Envelope codes (ceilMax, floorMin) are in the
///         chip's code space, the same space the shifted amounts are shown in (KernelMathV2).
contract KernelFactoryV2 is IKernelFactoryV2Callback {
    // ------------------------------------------------------------------ limits (kernel v1's, unchanged)

    uint256 public constant MAX_GATES = 3400;
    uint256 public constant MAX_NETLIST_BYTES = 24_000;
    uint256 public constant STEP_BASE = 200_000;
    uint256 public constant STEP_PER_GATE = 2_600;
    uint256 public constant STEP_PER_LATCH = 800;
    uint256 public constant SEALED_BASE = 40_000;
    uint256 public constant SEALED_PER_NAND = 200;
    uint256 public constant SEALED_PER_LATCH = 400;
    uint256 public constant MAX_FALLBACK_DELAY = 30 days;
    uint256 public constant MAX_HALF_LIFE = 30 days;
    uint256 public constant HALVING_SETTLES = 178;

    // ------------------------------------------------------------------ the quote asset

    /// The decimals the shift below was derived for (USD₮0).
    uint8 public constant QUOTE_DECIMALS = 6;
    /// Largest accepted shift. lg8(x << s) stays exact and inside 256 bits for every 128-bit amount.
    uint256 public constant MAX_QUOTE_SHIFT = 40;

    // ------------------------------------------------------------------ pins, shared by every kernel

    address public immutable kernelImpl;
    address public immutable manager;
    address public immutable v2Router;
    address public immutable quote;
    uint256 public immutable quoteShift;
    address public immutable circuits;
    address public immutable fab;
    address public immutable sealedVM;
    address public immutable beacon;
    address public immutable impl0;
    bytes32 public immutable impl0Hash;

    mapping(address kernel => bool) public isKernel;
    mapping(address token => address kernel) public kernelOf;

    event KernelCreated(address indexed kernel, uint256 indexed chipId, address indexed launcher, bytes32 salt);
    event KernelBound(address indexed kernel, address indexed token);

    /// which: 1 launcher, 2 epochLen, 3 allowancePayee, 4 capT, 5 capV, 6 allowCumBps, 7 ceilMax, 8 relMax,
    ///        9 floorRel, 10 floorMin, 11 fallbackEpochs, 12 fbAllow, 13 buys disabled, 14 fallback delay too
    ///        long, 15 the reserve would drain too slowly
    error BadEnvelope(uint8 which);
    /// which: 1 not a Fab chip, 2 nState, 3 gateCount, 4 snapshot shape, 5 snapshot hash
    error BadChip(uint8 which);
    /// which: 1 manager, 2 router, 3 quote (no code, or not QUOTE_DECIMALS), 4 circuits, 5 Fab, 6 SealedVM,
    ///        7 beacon, 8 pinned implementation, 9 the Fab is for another processor, 10 quote shift too large
    error BadPin(uint8 which);
    error NotKernel();

    /// @param quote_      the ERC-20 quote asset (USD₮0)
    /// @param quoteShift_ code shift in bits (33 for USD₮0: NOTES.md section 3)
    constructor(
        address manager_,
        address v2Router_,
        address quote_,
        uint256 quoteShift_,
        address circuits_,
        address fab_,
        address sealedVM_,
        address beacon_,
        address impl0_,
        bytes32 impl0Hash_
    ) {
        if (manager_.code.length == 0) revert BadPin(1);
        if (v2Router_.code.length == 0) revert BadPin(2);
        if (quote_.code.length == 0) revert BadPin(3);
        {
            (bool ok, bytes memory ret) = quote_.staticcall(abi.encodeWithSignature("decimals()"));
            if (!ok || ret.length != 32 || abi.decode(ret, (uint256)) != QUOTE_DECIMALS) revert BadPin(3);
        }
        if (circuits_.code.length == 0) revert BadPin(4);
        if (fab_.code.length == 0) revert BadPin(5);
        if (sealedVM_.code.length == 0) revert BadPin(6);
        if (beacon_.code.length == 0) revert BadPin(7);
        if (impl0_ == address(0) || impl0Hash_ == bytes32(0)) revert BadPin(8);
        {
            (bool ok, bytes memory ret) = fab_.staticcall(abi.encodeWithSignature("CIRCUITS()"));
            if (ok && ret.length == 32 && abi.decode(ret, (address)) != circuits_) revert BadPin(9);
        }
        if (quoteShift_ > MAX_QUOTE_SHIFT) revert BadPin(10);
        manager = manager_;
        v2Router = v2Router_;
        quote = quote_;
        quoteShift = quoteShift_;
        circuits = circuits_;
        fab = fab_;
        sealedVM = sealedVM_;
        beacon = beacon_;
        impl0 = impl0_;
        impl0Hash = impl0Hash_;
        kernelImpl = address(new KernelV2());
    }

    /// @notice The code shift in lg8 codes: 8 codes per bit (264 for a 33-bit shift).
    function codeShift() external view returns (uint256) {
        return 8 * quoteShift;
    }

    // ------------------------------------------------------------------ create

    /// @notice Creates the kernel for (env, chipId, salt), or returns it if it already exists.
    function create(Envelope calldata env, uint256 chipId, bytes32 salt) external returns (address kernel) {
        bytes memory args = _args(env, chipId);
        kernel = Clones.predictDeterministicAddressWithImmutableArgs(kernelImpl, args, salt);
        if (isKernel[kernel]) return kernel;
        Clones.cloneDeterministicWithImmutableArgs(kernelImpl, args, salt);
        isKernel[kernel] = true;
        emit KernelCreated(kernel, chipId, env.launcher, salt);
    }

    /// @notice The address `create` gives for the same arguments. Reverts on arguments `create` would reject.
    function predict(Envelope calldata env, uint256 chipId, bytes32 salt) external view returns (address) {
        return Clones.predictDeterministicAddressWithImmutableArgs(kernelImpl, _args(env, chipId), salt);
    }

    /// @notice Called by a kernel from inside `bind`, after its checks passed.
    function noteBound(address token) external override {
        if (!isKernel[msg.sender]) revert NotKernel();
        kernelOf[token] = msg.sender;
        emit KernelBound(msg.sender, token);
    }

    /// @notice True while TapeOut's live circuit implementation is the pinned one.
    function pinsLive() external view returns (bool) {
        (bool ok, bytes memory ret) = beacon.staticcall(abi.encodeWithSignature("implementation()"));
        if (!ok || ret.length < 32) return false;
        return abi.decode(ret, (address)) == impl0 && impl0.codehash == impl0Hash;
    }

    // ------------------------------------------------------------------ internals

    function _args(Envelope calldata env, uint256 chipId) private view returns (bytes memory) {
        _checkEnvelope(env);
        GlobalsV2 memory g;
        g.manager = manager;
        g.v2Router = v2Router;
        g.quote = quote;
        g.factory = address(this);
        g.circuits = circuits;
        g.fab = fab;
        g.sealedVM = sealedVM;
        g.beacon = beacon;
        g.impl0 = impl0;
        g.impl0Hash = impl0Hash;
        g.chipId = chipId;
        (g.snapshot, g.netlistHash, g.nState, g.gateCount, g.netlistLen) = _chip(chipId);
        g.stepFloor = STEP_BASE + STEP_PER_GATE * uint256(g.gateCount) + STEP_PER_LATCH * uint256(g.nState);
        g.sealedFloor =
            SEALED_BASE + SEALED_PER_NAND * uint256(g.gateCount - g.nState) + SEALED_PER_LATCH * uint256(g.nState);
        g.quoteShift = quoteShift;
        return abi.encode(g, env);
    }

    /// @dev chips/INTERFACE.md section 7, check for check (kernel v1's factory).
    function _checkEnvelope(Envelope calldata e) private pure {
        if (e.launcher == address(0)) revert BadEnvelope(1);
        if (e.epochLen < 300 || e.epochLen > 86_400) revert BadEnvelope(2);
        if (e.allowancePayee == address(0)) revert BadEnvelope(3);
        if (e.capT > 128) revert BadEnvelope(4);
        if (e.capV > 255) revert BadEnvelope(5);
        if (e.allowCumBps > 5000) revert BadEnvelope(6);
        if (e.ceilMax > 1023) revert BadEnvelope(7);
        if (e.relMax == 0 || e.relMax > 256) revert BadEnvelope(8);
        if (e.floorRel == 0 || e.floorRel > e.relMax) revert BadEnvelope(9);
        if (e.floorMin == 0 || e.floorMin > 425) revert BadEnvelope(10);
        if (e.fallbackEpochs < 2) revert BadEnvelope(11);
        if (e.fbAllow > e.capT) revert BadEnvelope(12);
        if (!e.buyEnabled) revert BadEnvelope(13);
        if (uint256(e.epochLen) * e.fallbackEpochs > MAX_FALLBACK_DELAY) revert BadEnvelope(14);
        if (uint256(e.epochLen) * HALVING_SETTLES > MAX_HALF_LIFE * e.floorRel) revert BadEnvelope(15);
    }

    /// @dev Reads the chip from the Fab and checks its snapshot (kernel v1's factory, unchanged).
    function _chip(uint256 chipId)
        private
        view
        returns (address snapshot, bytes32 netlistHash, uint32 nState, uint32 gateCount, uint32 netlistLen)
    {
        if (!IFabV1(fab).isChip(chipId)) revert BadChip(1);
        (snapshot, netlistHash, nState, gateCount,,) = IFabV1(fab).chipInfo(chipId);
        if (nState == 0 || nState > 256) revert BadChip(2);
        if (gateCount < nState || gateCount > MAX_GATES) revert BadChip(3);
        uint256 size = snapshot.code.length;
        if (size < 2 || size > MAX_NETLIST_BYTES + 1) revert BadChip(4);
        bytes memory code = snapshot.code;
        if (code[0] != 0x00) revert BadChip(4);
        bytes32 h;
        assembly ("memory-safe") {
            h := keccak256(add(code, 0x21), sub(size, 1))
        }
        if (h != netlistHash) revert BadChip(5);
        netlistLen = uint32(size - 1);
    }
}
