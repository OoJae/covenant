// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Reference consumer for the TAP draft "Stateful Circuit Consumers". Not audited. It exists to be read and
// to reproduce the draft's test vectors against a processor contract.
//
// It keeps the state of one sequential circuit in word form (section 3), checks its pinned values before
// every beat (section 6), stores one record per beat (section 5) and implements the reader interface
// (section 7). When a pinned value differs it performs no beat: it has no alternate evaluator.
//
// The caller of beat() supplies the input string. That is the one thing a real consumer must not copy:
// a real consumer assembles its inputs itself, from data it has reason to trust.

interface IProcessorContract {
    function step(uint256 id, bytes calldata state, bytes calldata inputs)
        external
        view
        returns (bytes memory newState, bytes memory outputs);
    function circuitInfo(uint256 id) external view returns (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount);
    function netlist(uint256 id) external view returns (bytes memory);
}

interface IBeacon {
    function implementation() external view returns (address);
}

/// Reader interface of section 7. ERC-165 interface ID 0x0d1e10c5.
interface ICircuitConsumer {
    event Beat(uint256 indexed n, uint8 source, bytes inputs, bytes outputs, bytes stateAfter);

    function circuit() external view returns (address processor, uint256 id, uint32 nIn, uint32 nOut, uint32 nState);
    function circuitState() external view returns (bytes memory state);
    function beatCount() external view returns (uint256);
    function beatAt(uint256 n)
        external
        view
        returns (uint8 source, bytes memory inputs, bytes memory outputs, bytes memory stateAfter);
    function pinnedEvaluator()
        external
        view
        returns (address beacon, address implementation, bytes32 implementationCodeHash, bytes32 netlistHash);
}

contract ReferenceConsumer is ICircuitConsumer {
    /// The circuit has no state, or more than 256 state bits: this consumer uses the word form.
    error UnsupportedState(uint32 nState);
    /// `beacon` has no implementation with code.
    error BadBeacon();
    /// A pinned value differs: the evaluator is not the one this consumer was bound to.
    error EvaluatorChanged();
    /// The input string is not exactly ceil(nIn / 8) bytes with its unused bits zero.
    error BadInputs();
    /// The evaluator returned strings of the wrong length, or a state with a bit set at nState or above.
    error BadResult();
    error NoSuchBeat(uint256 n);

    uint8 private constant SOURCE_PROCESSOR = 1;

    address private immutable PROCESSOR;
    uint256 private immutable ID;
    uint32 private immutable N_IN;
    uint32 private immutable N_OUT;
    uint32 private immutable N_STATE;
    address private immutable BEACON;
    address private immutable IMPLEMENTATION;
    bytes32 private immutable IMPLEMENTATION_CODE_HASH;
    bytes32 private immutable NETLIST_HASH;

    struct Record {
        bytes inputs;
        bytes outputs;
        bytes32 stateAfter; // word form
    }

    bytes32 private _state; // word form: the state string, then zero bytes. All zero before the first beat.
    Record[] private _records;

    /// @param beacon_ The beacon of the processor contract: the address in its ERC-1967 beacon slot
    ///        0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50. A contract cannot read that
    ///        slot, so the deployer supplies it; anyone can compare it with eth_getStorageAt.
    constructor(address processor_, uint256 id_, address beacon_) {
        (uint32 nIn, uint32 nOut, uint32 nState,) = IProcessorContract(processor_).circuitInfo(id_);
        if (nState == 0 || nState > 256) revert UnsupportedState(nState);
        address implementation = IBeacon(beacon_).implementation();
        if (implementation.code.length == 0) revert BadBeacon();
        PROCESSOR = processor_;
        ID = id_;
        N_IN = nIn;
        N_OUT = nOut;
        N_STATE = nState;
        BEACON = beacon_;
        IMPLEMENTATION = implementation;
        IMPLEMENTATION_CODE_HASH = implementation.codehash;
        NETLIST_HASH = keccak256(IProcessorContract(processor_).netlist(id_));
    }

    // ------------------------------------------------------------------ one beat (section 4)

    function beat(bytes calldata inputs) external returns (uint256 n) {
        if (!_canonical(inputs, N_IN)) revert BadInputs();
        if (!evaluatorUnchanged()) revert EvaluatorChanged();

        // The state argument is the word: 32 bytes. A conforming evaluator ignores every bit at nState and above.
        (bytes memory newState, bytes memory outputs) =
            IProcessorContract(PROCESSOR).step(ID, abi.encodePacked(_state), inputs);
        if (outputs.length != (uint256(N_OUT) + 7) / 8 || !_canonical(newState, N_STATE)) revert BadResult();

        // _canonical() has checked that newState is ceil(nState / 8) bytes, at most 32: the conversion pads it
        // with zero bytes on the right and truncates nothing.
        // forge-lint: disable-next-line(unsafe-typecast)
        _state = bytes32(newState);
        _records.push(Record({inputs: inputs, outputs: outputs, stateAfter: _state}));
        n = _records.length;
        emit Beat(n, SOURCE_PROCESSOR, inputs, outputs, newState);
    }

    /// True while every pinned value still holds (section 6).
    function evaluatorUnchanged() public view returns (bool) {
        try IBeacon(BEACON).implementation() returns (address current) {
            if (current != IMPLEMENTATION) return false;
        } catch {
            return false;
        }
        if (IMPLEMENTATION.codehash != IMPLEMENTATION_CODE_HASH) return false;
        try IProcessorContract(PROCESSOR).circuitInfo(ID) returns (uint32 nIn, uint32 nOut, uint32 nState, uint32) {
            if (nIn != N_IN || nOut != N_OUT || nState != N_STATE) return false;
        } catch {
            return false;
        }
        try IProcessorContract(PROCESSOR).netlist(ID) returns (bytes memory nl) {
            return keccak256(nl) == NETLIST_HASH;
        } catch {
            return false;
        }
    }

    // ------------------------------------------------------------------ reader interface (section 7)

    function circuit() external view returns (address, uint256, uint32, uint32, uint32) {
        return (PROCESSOR, ID, N_IN, N_OUT, N_STATE);
    }

    function circuitState() external view returns (bytes memory) {
        return _string(_state);
    }

    function beatCount() external view returns (uint256) {
        return _records.length;
    }

    function beatAt(uint256 n) external view returns (uint8, bytes memory, bytes memory, bytes memory) {
        if (n == 0 || n > _records.length) revert NoSuchBeat(n);
        Record storage r = _records[n - 1];
        return (SOURCE_PROCESSOR, r.inputs, r.outputs, _string(r.stateAfter));
    }

    function pinnedEvaluator() external view returns (address, address, bytes32, bytes32) {
        return (BEACON, IMPLEMENTATION, IMPLEMENTATION_CODE_HASH, NETLIST_HASH);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ICircuitConsumer).interfaceId || interfaceId == 0x01ffc9a7;
    }

    // ------------------------------------------------------------------ strings and words (section 3)

    /// True when `s` is exactly ceil(n / 8) bytes and every bit at position n and above is zero.
    function _canonical(bytes memory s, uint256 n) private pure returns (bool) {
        if (s.length != (n + 7) / 8) return false;
        return n % 8 == 0 || uint8(s[s.length - 1]) >> (n % 8) == 0;
    }

    /// The state string held by a word: its first ceil(nState / 8) bytes.
    function _string(bytes32 word) private view returns (bytes memory s) {
        uint256 len = (uint256(N_STATE) + 7) / 8;
        s = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            s[i] = word[i];
        }
    }
}
