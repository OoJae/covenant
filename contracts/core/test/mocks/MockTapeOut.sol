// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Test doubles of TapeOut's Circuits contract, its beacon, the Fab and the sealed evaluator.
//
// A "chip" here is a small program instead of a NAND netlist, so tests can state what a chip outputs. Both
// evaluators (MockCircuits.step and MockSealedVM.step) run the same pure function over the same netlist bytes,
// as the real pair must. On top of that MockCircuits and MockSealedVM have failure switches: revert, burn gas,
// wrong lengths, return bombs, malformed ABI.

/// @notice The pure chip model. Netlist layout: [kind][nState - 1][payload...].
library ChipModel {
    uint8 internal constant HASH = 0xF0; // pseudo-random words: well formed half the time, hostile otherwise
    uint8 internal constant FIXED = 0xF1; // payload = one 14-byte output word; the state is a counter
    uint8 internal constant SCRIPT = 0xF2; // payload = k words of 14 bytes; word[counter % k]; state counts
    uint8 internal constant TOGGLE = 0xF3; // payload = two words; word A when state bit 0 is 0, else word B

    function nState(bytes memory nl) internal pure returns (uint256) {
        return uint256(uint8(nl[1])) + 1;
    }

    function fixedChip(uint256 nState_, bytes14 word) internal pure returns (bytes memory) {
        return abi.encodePacked(FIXED, uint8(nState_ - 1), word);
    }

    function hashChip(uint256 nState_, bytes32 seed) internal pure returns (bytes memory) {
        return abi.encodePacked(HASH, uint8(nState_ - 1), seed);
    }

    function toggleChip(uint256 nState_, bytes14 a, bytes14 b) internal pure returns (bytes memory) {
        return abi.encodePacked(TOGGLE, uint8(nState_ - 1), a, b);
    }

    function scriptChip(uint256 nState_, bytes14[] memory words) internal pure returns (bytes memory nl) {
        nl = abi.encodePacked(SCRIPT, uint8(nState_ - 1));
        for (uint256 i = 0; i < words.length; i++) {
            nl = bytes.concat(nl, words[i]);
        }
    }

    /// @dev State as a little-endian integer (TAP-20 packing); short or missing bytes read as zero.
    function _bits(bytes memory state, uint256 n) private pure returns (uint256 v) {
        uint256 len = (n + 7) / 8;
        for (uint256 i = 0; i < len && i < state.length; i++) {
            v |= uint256(uint8(state[i])) << (8 * i);
        }
        if (n < 256) v &= (uint256(1) << n) - 1;
    }

    function _pack(uint256 v, uint256 n) private pure returns (bytes memory out) {
        if (n < 256) v &= (uint256(1) << n) - 1;
        uint256 len = (n + 7) / 8;
        out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = bytes1(uint8(v >> (8 * i)));
        }
    }

    function _word14(bytes memory nl, uint256 off) private pure returns (bytes memory w) {
        w = new bytes(14);
        for (uint256 i = 0; i < 14; i++) {
            w[i] = nl[off + i];
        }
    }

    function _wordToBytes(uint256 word) private pure returns (bytes memory w) {
        w = new bytes(14);
        for (uint256 i = 0; i < 14; i++) {
            w[i] = bytes1(uint8(word >> (8 * i)));
        }
    }

    function eval(bytes memory nl, bytes memory state, bytes memory inputs)
        internal
        pure
        returns (bytes memory newState, bytes memory outputs)
    {
        uint8 kind = uint8(nl[0]);
        uint256 n = nState(nl);
        uint256 s = _bits(state, n);
        if (kind == FIXED) {
            return (_pack(s + 1, n), _word14(nl, 2));
        }
        if (kind == TOGGLE) {
            return (_pack(s ^ 1, n), _word14(nl, s & 1 == 0 ? 2 : 16));
        }
        if (kind == SCRIPT) {
            uint256 k = (nl.length - 2) / 14;
            return (_pack(s + 1, n), _word14(nl, 2 + 14 * (s % k)));
        }
        // HASH
        uint256 h = uint256(keccak256(abi.encode(keccak256(nl), s, keccak256(inputs))));
        newState = _pack(uint256(keccak256(abi.encode(h))), n);
        uint256 word;
        if (h & 1 == 0) {
            // a well-formed share group, any REL, a ceiling half of the time
            uint256 tb = (h >> 8) % 257;
            uint256 th = (h >> 24) % (257 - tb);
            uint256 ta = (h >> 40) % (257 - tb - th);
            uint256 tr = 256 - tb - th - ta;
            uint256 rel = (h >> 56) % 257;
            uint256 ceil = (h >> 72) & 1 == 0 ? 1023 : (h >> 80) % 1024;
            word = tb | (th << 9) | (ta << 18) | (tr << 27) | (rel << 72) | (ceil << 81) | ((h >> 100) << 91);
            word &= (uint256(1) << 112) - 1;
        } else {
            word = (h >> 16) & ((uint256(1) << 112) - 1); // anything at all
        }
        outputs = _wordToBytes(word);
    }
}

contract MockImpl {
    uint256 public constant version = 1;
}

contract MockImplV2 {
    uint256 public constant version = 2;
}

contract MockBeacon {
    address public impl;
    bool public reverts;

    constructor(address impl_) {
        impl = impl_;
    }

    function implementation() external view returns (address) {
        require(!reverts, "beacon");
        return impl;
    }

    function upgradeTo(address i) external {
        impl = i;
    }

    function setReverts(bool v) external {
        reverts = v;
    }
}

/// @notice Shared failure switches of the two evaluators.
abstract contract StepFaults {
    // 0 normal, 1 revert, 2 burn all gas, 3 state one byte short, 4 outputs one byte long, 5 return bomb,
    // 6 malformed offsets, 7 empty return, 8 state one byte long, 9 return the programmed override,
    // 10 right lengths but truncated data
    uint8 public stepMode;
    uint256 public stepBurn; // extra gas burned by a normal step (models the cost of a large netlist)
    bytes public overrideState;
    bytes public overrideOutputs;

    function setStepMode(uint8 m) external {
        stepMode = m;
    }

    function setStepBurn(uint256 g) external {
        stepBurn = g;
    }

    function setOverride(bytes calldata state, bytes calldata outputs) external {
        overrideState = state;
        overrideOutputs = outputs;
        stepMode = 9;
    }

    function _burn() internal view {
        uint256 target = stepBurn;
        if (target == 0) return;
        uint256 start = gasleft();
        uint256 x;
        while (start - gasleft() < target) {
            x = uint256(keccak256(abi.encode(x)));
        }
    }

    function _faulty(bytes memory newState, bytes memory outputs) internal view returns (bytes memory, bytes memory) {
        uint8 m = stepMode;
        if (m == 0) {
            _burn();
            return (newState, outputs);
        }
        if (m == 1) revert("step broken");
        if (m == 2) {
            while (true) {}
        }
        if (m == 3) return (new bytes(newState.length - 1), outputs);
        if (m == 4) return (newState, new bytes(15));
        if (m == 5) {
            // 1 MB of return data: copying it would cost the caller its gas
            assembly {
                return(0, 1048576)
            }
        }
        if (m == 6) {
            // offsets pointing far outside the return data
            assembly {
                mstore(0x00, 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff00)
                mstore(0x20, 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff)
                mstore(0x40, 1)
                mstore(0x60, 0)
                mstore(0x80, 14)
                mstore(0xa0, 0)
                return(0x00, 0xc0)
            }
        }
        if (m == 7) {
            assembly {
                return(0, 0)
            }
        }
        if (m == 8) return (new bytes(newState.length + 1), outputs);
        if (m == 10) {
            // well-formed offsets and lengths, but the output bytes are cut off: 160 bytes instead of 192
            uint256 stateLen = newState.length;
            assembly {
                mstore(0x00, 0x40)
                mstore(0x20, 0x80)
                mstore(0x40, stateLen)
                mstore(0x60, 0)
                mstore(0x80, 14)
                return(0x00, 0xa0)
            }
        }
        return (overrideState, overrideOutputs);
    }
}

/// @notice TapeOut Circuits: ERC-721 ownership, netlist storage and the evaluator.
contract MockCircuits is StepFaults {
    struct Circ {
        bytes netlist;
        uint32 nIn;
        uint32 nOut;
        uint32 nState;
        uint32 gateCount;
        address owner;
    }

    mapping(uint256 => Circ) internal _circ;
    uint256 public nextId;

    function tapeout(bytes calldata nl, uint32 gateCount) external returns (uint256 id) {
        id = ++nextId;
        Circ storage c = _circ[id];
        c.netlist = nl;
        c.nIn = 96;
        c.nOut = 112;
        c.nState = uint32(ChipModel.nState(nl));
        c.gateCount = gateCount;
        c.owner = msg.sender;
    }

    function ownerOf(uint256 id) external view returns (address) {
        address o = _circ[id].owner;
        require(o != address(0), "ERC721NonexistentToken");
        return o;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(_circ[id].owner == from && msg.sender == from, "not owner");
        _circ[id].owner = to;
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        require(_circ[id].owner == from && msg.sender == from, "not owner");
        _circ[id].owner = to;
        if (to.code.length != 0) {
            (bool ok, bytes memory ret) = to.call(
                abi.encodeWithSignature("onERC721Received(address,address,uint256,bytes)", msg.sender, from, id, "")
            );
            require(ok && ret.length >= 32 && bytes4(ret) == 0x150b7a02, "ERC721InvalidReceiver");
        }
    }

    function netlist(uint256 id) external view returns (bytes memory) {
        require(_circ[id].owner != address(0), "no circuit");
        return _circ[id].netlist;
    }

    function circuitInfo(uint256 id) external view returns (uint32, uint32, uint32, uint32) {
        Circ storage c = _circ[id];
        require(c.owner != address(0), "no circuit");
        return (c.nIn, c.nOut, c.nState, c.gateCount);
    }

    function step(uint256 id, bytes calldata state, bytes calldata inputs)
        external
        view
        returns (bytes memory, bytes memory)
    {
        Circ storage c = _circ[id];
        require(c.owner != address(0), "no circuit");
        (bytes memory ns, bytes memory out) = ChipModel.eval(c.netlist, state, inputs);
        return _faulty(ns, out);
    }

    // ---- what a hostile upgrade could do to the proxy's storage
    function rewriteNetlist(uint256 id, bytes calldata nl) external {
        _circ[id].netlist = nl;
    }

    function rewriteInfo(uint256 id, uint32 nIn, uint32 nOut, uint32 nState_, uint32 gateCount) external {
        Circ storage c = _circ[id];
        (c.nIn, c.nOut, c.nState, c.gateCount) = (nIn, nOut, nState_, gateCount);
    }
}

/// @notice The sealed evaluator: the same chip model over the Fab snapshot (0x00 followed by the netlist).
contract MockSealedVM is StepFaults {
    function step(address snapshot, uint32, uint32, bytes calldata state, bytes calldata inputs)
        external
        view
        returns (bytes memory, bytes memory)
    {
        bytes memory code = snapshot.code;
        require(code.length > 1, "no snapshot");
        bytes memory nl = new bytes(code.length - 1);
        for (uint256 i = 0; i < nl.length; i++) {
            nl[i] = code[i + 1];
        }
        (bytes memory ns, bytes memory out) = ChipModel.eval(nl, state, inputs);
        return _faulty(ns, out);
    }
}

/// @notice The Fab: tapes a chip out on MockCircuits, snapshots the netlist (SSTORE2 convention) and hands
///         the NFT to the caller.
contract MockFab {
    struct Info {
        address snapshot;
        bytes32 netlistHash;
        uint32 nState;
        uint32 gateCount;
        address author;
        bytes32 manifestHash;
    }

    MockCircuits public immutable CIRCUITS;
    mapping(uint256 => Info) internal _info;

    constructor(MockCircuits c) {
        CIRCUITS = c;
    }

    function tapeoutChip(bytes calldata nl, uint32 gateCount) external returns (uint256 chipId) {
        chipId = CIRCUITS.tapeout(nl, gateCount);
        bytes memory runtime = abi.encodePacked(hex"00", nl);
        bytes memory creation = abi.encodePacked(hex"600B5981380380925939F3", runtime);
        address ptr;
        assembly {
            ptr := create(0, add(creation, 0x20), mload(creation))
        }
        require(ptr != address(0), "SSTORE2");
        _info[chipId] = Info(ptr, keccak256(nl), uint32(ChipModel.nState(nl)), gateCount, msg.sender, bytes32(0));
        CIRCUITS.transferFrom(address(this), msg.sender, chipId);
    }

    /// @dev Registers a chip record that disagrees with reality (factory tests).
    function forge(uint256 chipId, address pointer, bytes32 netlistHash, uint32 nState, uint32 gateCount) external {
        _info[chipId] = Info(pointer, netlistHash, nState, gateCount, msg.sender, bytes32(0));
    }

    function isChip(uint256 chipId) external view returns (bool) {
        return _info[chipId].snapshot != address(0);
    }

    function chipInfo(uint256 chipId) external view returns (address, bytes32, uint32, uint32, address, bytes32) {
        Info storage i = _info[chipId];
        return (i.snapshot, i.netlistHash, i.nState, i.gateCount, i.author, i.manifestHash);
    }

    function snapshot(uint256 chipId) external view returns (bytes memory nl) {
        bytes memory code = _info[chipId].snapshot.code;
        nl = new bytes(code.length - 1);
        for (uint256 i = 0; i < nl.length; i++) {
            nl[i] = code[i + 1];
        }
    }
}
