// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {NetlistVM} from "tapeout/lib/NetlistVM.sol";
import {SSTORE2} from "tapeout/lib/SSTORE2.sol";

// This file is compiled with via-IR (foundry.toml, compilation_restrictions): TapeOut's NetlistVM does not
// compile on the legacy pipeline. Tests never import it; they deploy the two contracts from their artifacts
// (deployCode) and talk to them through the interfaces in Netlists.sol, so everything under src/ is always
// the production (legacy pipeline) build.

/// @notice TapeOut's own evaluator, unmodified, behind the same external surface as its Circuits contract.
/// @dev    `NetlistVM` and `SSTORE2` are TapeOut's verified MIT sources (contracts/vendor/tapeout-xlayer,
///         implementation 0x977f217887E085D298Cb3819cDAD5A0ee35F29B2 on X Layer). The real Circuits contract
///         is an upgradeable ERC-721 behind a beacon proxy; this harness keeps only what a kernel calls:
///         `step`, `netlist`, `circuitInfo`, `ownerOf`. `step` is the same source as on chain (SSTORE2 read,
///         then NetlistVM.run) but a different build (via-IR here, solc 0.8.24 legacy on chain), so its gas is
///         indicative only. The fork suite measures the deployed implementation.
contract TapeCircuits {
    struct Circ {
        address chunk;
        uint32 nIn;
        uint32 nOut;
        uint32 nState;
        uint32 gateCount;
        address owner;
    }

    mapping(uint256 => Circ) internal _circ;
    uint256 public nextId;

    function tapeout(bytes calldata nl, uint32 nIn, uint32 nOut) external returns (uint256 id) {
        (,, uint32 nState, uint32 gateCount) = NetlistVM.analyze(nl, nIn, nOut, address(0));
        id = ++nextId;
        _circ[id] = Circ(SSTORE2.write(nl), nIn, nOut, nState, gateCount, msg.sender);
    }

    function ownerOf(uint256 id) external view returns (address) {
        require(_circ[id].owner != address(0), "ERC721NonexistentToken");
        return _circ[id].owner;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(_circ[id].owner == from && msg.sender == from, "not owner");
        _circ[id].owner = to;
    }

    function netlist(uint256 id) public view returns (bytes memory) {
        require(_circ[id].owner != address(0), "no circuit");
        return SSTORE2.read(_circ[id].chunk);
    }

    function circuitInfo(uint256 id) external view returns (uint32, uint32, uint32, uint32) {
        Circ storage c = _circ[id];
        require(c.owner != address(0), "no circuit");
        return (c.nIn, c.nOut, c.nState, c.gateCount);
    }

    function step(uint256 id, bytes calldata state, bytes calldata inputs)
        external
        view
        returns (bytes memory newState, bytes memory outputs)
    {
        Circ storage c = _circ[id];
        require(c.owner != address(0), "no circuit");
        (newState, outputs) = NetlistVM.run(netlist(id), c.nIn, c.nOut, state, inputs);
    }
}

/// @notice A Fab for the harness above: tapes out, snapshots the netlist (SSTORE2) and hands over the NFT.
contract TapeFab {
    struct Info {
        address snapshot;
        bytes32 netlistHash;
        uint32 nState;
        uint32 gateCount;
        address author;
    }

    TapeCircuits public immutable CIRCUITS;
    mapping(uint256 => Info) internal _info;

    constructor(TapeCircuits c) {
        CIRCUITS = c;
    }

    function tapeoutChip(bytes calldata nl) external returns (uint256 chipId) {
        chipId = CIRCUITS.tapeout(nl, 96, 112);
        (,, uint32 nState, uint32 gateCount) = CIRCUITS.circuitInfo(chipId);
        _info[chipId] = Info(SSTORE2.write(nl), keccak256(nl), nState, gateCount, msg.sender);
        CIRCUITS.transferFrom(address(this), msg.sender, chipId);
    }

    function isChip(uint256 chipId) external view returns (bool) {
        return _info[chipId].snapshot != address(0);
    }

    function chipInfo(uint256 chipId) external view returns (address, bytes32, uint32, uint32, address, bytes32) {
        Info storage i = _info[chipId];
        return (i.snapshot, i.netlistHash, i.nState, i.gateCount, i.author, bytes32(0));
    }

    function snapshot(uint256 chipId) external view returns (bytes memory) {
        return SSTORE2.read(_info[chipId].snapshot);
    }
}
