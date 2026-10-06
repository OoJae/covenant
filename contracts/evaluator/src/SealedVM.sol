// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISealedVM} from "./interfaces/ISealedVM.sol";
import {BadOpcode, FutureSignal, LatchOutOfRange, TooFewSignals, TruncatedRecord} from "./lib/NetlistErrors.sol";

/// @title SealedVM: an evaluator for flat TAP-20 netlists that nobody can change
/// @notice One beat of a circuit made of NAND and LATCH records only, read from an SSTORE2 pointer
///         (runtime code = 0x00 followed by the raw netlist bytes). For every well-formed flat netlist
///         and any state and input byte strings it returns exactly what TapeOut's `Circuits.step` returns.
///         It rejects every netlist TAP-20 calls ill-formed, and every REF record.
///
///         The contract has no storage, no owner, no upgrade path and no external calls. It reads the
///         code of `snapshot` and nothing else.
///
/// @dev    A port of the one-beat semantics of TapeOut's `NetlistVM.run` (MIT, verified source of the
///         circuit implementation 0x977f217887E085D298Cb3819cDAD5A0ee35F29B2 on X Layer), restricted to
///         flat netlists and rewritten for gas. No TapeOut code is copied; the semantics are those of
///         TAP-20 sections 2 to 5:
///
///         - signal 0 is constant 0, signal 1 is constant 1, input i is signal 2 + i;
///         - each record appends one signal: NAND (0x00 a:u24 b:u24) gives NOT(a AND b), with a and b
///           earlier signals; LATCH (0x01 d:u24) gives its stored bit, the k-th LATCH owning state bit k;
///         - after all records are evaluated, each LATCH takes its new bit from signal d, which may be
///           any signal of the beat, earlier or later;
///         - the outputs are the last nOut signals;
///         - bit i of a vector is bit (i mod 8) of byte (i / 8); results are exactly ceil(n / 8) bytes
///           with zero padding; state and inputs are read leniently (a missing byte reads as zero and
///           anything beyond n bits is ignored).
///
///         Memory used by one call, all of it allocated through the free memory pointer by `_load`:
///
///           [code, end)        the pointer's code: the 0x00 byte, then the netlist
///           [end, end + 64)    32 bytes of 0xff, an opcode no record has, then 32 bytes never read as data
///           [sig, sig + cap)   one byte per signal, 0 or 1; signal i lives at sig + i
///           [.., + 64)         slack
///
///         A record is decoded with one `mload` of the 32 bytes at its first byte. A signal is read with
///         `mload(base + i)` where `base = sig - 31`, which puts the signal in the lowest byte of the
///         word, so its value is `word & 1`. Every signal byte is written, as exactly 0 or 1, before
///         anything reads it.
contract SealedVM is ISealedVM {
    /// @dev TAP-20 bounds: at most 65,536 input pins and 65,536 output pins, at most 2^24 signals.
    uint256 internal constant MAX_PINS = 1 << 16;
    uint256 internal constant MAX_SIGNALS = 1 << 24;

    /// @notice `nIn` is above 65,536, or `nOut` is zero or above 65,536.
    error BadPins();
    /// @notice `snapshot` has no code, or its code does not start with the 0x00 byte of an SSTORE2 pointer.
    error BadSnapshot();
    /// @notice The netlist is long enough to produce more than 2^24 signals.
    error TooManySignals();
    // The netlist itself is rejected with the errors of lib/NetlistErrors.sol: TruncatedRecord,
    // BadOpcode (anything but NAND 0x00 and LATCH 0x01), FutureSignal, LatchOutOfRange, TooFewSignals.

    /// @dev Eight bits to eight bytes and back, one multiplication each way. See `_spread` and `_pack`.
    uint256 private constant SPREAD = 0x8040201008040201;
    uint256 private constant TOP_BITS = 0x8080808080808080;

    /// @dev Memory pointers for one evaluation. See the layout in the contract comment.
    struct Tape {
        uint256 first; // address of the first netlist byte
        uint256 end; // address one past the last netlist byte
        uint256 sig; // address of signal 0; signal i is the byte at sig + i
    }

    /// @inheritdoc ISealedVM
    function step(address snapshot, uint32 nIn, uint32 nOut, bytes calldata state, bytes calldata inputs)
        external
        view
        returns (bytes memory newState, bytes memory outputs)
    {
        if (nIn > MAX_PINS || nOut == 0 || nOut > MAX_PINS) revert BadPins();

        Tape memory t = _load(snapshot, nIn);
        uint256 lead = _preset(t, nIn, inputs, state);

        (uint256 nSignals, uint256 nLatch) = _evaluate(t, lead, 2 + uint256(nIn) + lead, state);
        if (nSignals < 2 + uint256(nIn) + nOut) revert TooFewSignals(nSignals - 2 - nIn);

        newState = _nextState(t, nSignals, nLatch);
        outputs = _pack(t.sig + nSignals - nOut, nOut);
    }

    /// @dev Copies the netlist into memory, writes the sentinel after it and reserves the signal buffer.
    function _load(address snapshot, uint256 nIn) private view returns (Tape memory t) {
        uint256 size = snapshot.code.length;
        if (size == 0) revert BadSnapshot();

        // A record is at least 4 bytes long, so a netlist of (size - 1) bytes holds at most
        // ceil((size - 1) / 4) records, each producing one signal.
        uint256 cap = 2 + nIn + (size + 2) / 4;
        if (cap > MAX_SIGNALS) revert TooManySignals();

        uint256 firstByte;
        assembly ("memory-safe") {
            let code := mload(0x40)
            extcodecopy(snapshot, code, 0, size)
            firstByte := byte(0, mload(code))

            let end := add(code, size)
            mstore(end, not(0))

            let sig := add(end, 64)
            mstore(t, add(code, 1))
            mstore(add(t, 0x20), end)
            mstore(add(t, 0x40), sig)

            // cap signal bytes and 64 bytes of slack, rounded up to a whole word
            mstore(0x40, and(add(add(sig, cap), 95), not(31)))
        }
        if (firstByte != 0) revert BadSnapshot();
    }

    /// @dev Writes every signal that is known before the first gate is evaluated: the two constants, the
    ///      inputs, and the outputs of the leading LATCH records, which are their stored bits. A v1 chip
    ///      has all its LATCH records at the front, so its whole state is placed here, eight bits at a time.
    /// @return lead number of LATCH records before the first record that is not a LATCH
    function _preset(Tape memory t, uint256 nIn, bytes calldata inputs, bytes calldata state)
        private
        pure
        returns (uint256 lead)
    {
        uint256 first = t.first;
        uint256 sig = t.sig;
        assembly ("memory-safe") {
            mstore8(sig, 0)
            mstore8(add(sig, 1), 1)

            // The sentinel after the netlist is not a LATCH opcode, so this stops at the end at the latest.
            let p := first
            for {} eq(byte(0, mload(p)), 1) {} { p := add(p, 4) }
            lead := shr(2, sub(p, first))
        }
        // In this order: each call may overwrite a few bytes after its own signals.
        _spread(sig + 2, nIn, inputs);
        _spread(sig + 2 + nIn, lead, state);
    }

    /// @dev Writes `n` signals at address `dst`, one byte each: the first `n` bits of `src`, bit i being
    ///      bit (i mod 8) of byte (i / 8). Bytes missing from `src` read as zero.
    ///
    ///      It writes whole groups: up to 38 bytes after the n-th signal are overwritten as well (with the
    ///      bits of `src` beyond n, then zeros). Those bytes are signals that are produced later, and so
    ///      written again before they are read, or slack.
    function _spread(uint256 dst, uint256 n, bytes calldata src) private pure {
        assembly ("memory-safe") {
            let nBytes := shr(3, add(n, 7))
            let have := src.length
            if gt(have, nBytes) { have := nBytes }

            // One byte v of src becomes eight signal bytes. v * SPREAD puts bit j of v at bit 63 - 8j,
            // the top bit of byte j of a 64-bit word counted from its most significant byte. Nothing
            // carries, because the 64 partial products (bit j shifted by 63 - 9m) land on 64 different
            // bits. The mask keeps those eight bits. Shifting left by 185 moves each to the bottom of its
            // byte (down 7) and the eight bytes to the front of the word (up 192), where mstore puts them
            // at the eight lowest addresses, followed by 24 zero bytes.
            let k := 0
            for {} lt(k, have) { k := add(k, 1) } {
                let v := byte(0, calldataload(add(src.offset, k)))
                mstore(add(dst, shl(3, k)), shl(185, and(mul(v, SPREAD), TOP_BITS)))
            }
            for {
                let a := add(dst, shl(3, k))
                let e := add(dst, shl(3, nBytes))
            } lt(a, e) { a := add(a, 32) } { mstore(a, 0) }
        }
    }

    /// @dev The single pass over the records. Reverts unless every record is a complete NAND whose
    ///      inputs are earlier signals, or a complete LATCH.
    /// @param lead        number of leading LATCH records, already given their signals by `_preset`
    /// @param firstSignal index of the signal the first record after them produces (2 + nIn + lead)
    /// @return nSignals   total number of signals, constants and inputs included
    /// @return nLatch     number of LATCH records, which is the number of state bits
    function _evaluate(Tape memory t, uint256 lead, uint256 firstSignal, bytes calldata state)
        private
        pure
        returns (uint256 nSignals, uint256 nLatch)
    {
        uint256 stopAt; // where the loop below stopped
        assembly ("memory-safe") {
            let base := sub(mload(add(t, 0x40)), 31) // mload(base + i) holds signal i in its lowest byte
            let p := add(mload(t), shl(2, lead)) // address of the record being read
            let q := add(base, firstSignal) // base + index of the signal the record at p produces
            nLatch := lead

            for {} 1 {} {
                let w := mload(p)

                // The record at p as a NAND: 0x00, a, b. The top four bytes of w are the opcode and a.
                // Read as one number they are below the index being produced (itself at most 2^24)
                // only when the opcode is 0x00 and a is an earlier signal, so one comparison checks both.
                let ra := add(base, shr(224, w))
                let rb := add(base, and(shr(200, w), 0xffffff))

                if iszero(and(lt(ra, q), lt(rb, q))) {
                    // Not a NAND with earlier inputs. Anything but a LATCH ends the pass: the sentinel
                    // after a well-formed netlist, or a bad record.
                    if iszero(eq(shr(248, w), 1)) { break }

                    // A LATCH after the leading ones. Its output is the stored bit: bit nLatch of
                    // `state`, zero if `state` is too short.
                    let k := shr(3, nLatch)
                    let bit := 0
                    if lt(k, state.length) {
                        bit := and(shr(and(nLatch, 7), byte(0, calldataload(add(state.offset, k)))), 1)
                    }
                    mstore8(add(q, 31), bit)
                    nLatch := add(nLatch, 1)
                    q := add(q, 1)
                    p := add(p, 4)
                    continue
                }

                mstore8(add(q, 31), iszero(and(and(mload(ra), mload(rb)), 1)))
                p := add(p, 7)
                q := add(q, 1)
            }
            stopAt := p
            nSignals := sub(q, base)
        }

        uint256 end = t.end;
        if (stopAt == end) return (nSignals, nLatch);

        // A record that runs past the end reads sentinel bytes. Whether it was evaluated or not, the
        // pass cannot stop exactly at `end`.
        if (stopAt > end) revert TruncatedRecord();
        uint256 opcode;
        assembly ("memory-safe") {
            opcode := byte(0, mload(stopAt))
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        if (opcode != 0) revert BadOpcode(stopAt - t.first, uint8(opcode)); // one byte, read just above
        if (stopAt + 7 > end) revert TruncatedRecord();
        revert FutureSignal(stopAt - t.first);
    }

    /// @dev The second pass: each LATCH takes its new bit from signal d of this beat.
    ///      Opcodes and record lengths were checked by `_evaluate`.
    function _nextState(Tape memory t, uint256 nSignals, uint256 nLatch) private pure returns (bytes memory newState) {
        newState = new bytes((nLatch + 7) / 8);
        uint256 bad = type(uint256).max; // the d of a LATCH that is not a signal, if there is one
        assembly ("memory-safe") {
            let base := sub(mload(add(t, 0x40)), 31)
            let p := mload(t)
            let dst := add(newState, 0x20)

            for { let i := 0 } lt(i, nLatch) {} {
                let w := mload(p)
                if iszero(shr(248, w)) {
                    p := add(p, 7) // NAND
                    continue
                }
                let d := and(shr(224, w), 0xffffff)
                if iszero(lt(d, nSignals)) {
                    bad := d
                    break
                }
                if and(mload(add(base, d)), 1) {
                    let a := add(dst, shr(3, i))
                    mstore8(a, or(byte(0, mload(a)), shl(and(i, 7), 1)))
                }
                p := add(p, 4)
                i := add(i, 1)
            }
        }
        if (bad != type(uint256).max) revert LatchOutOfRange(bad, nSignals);
    }

    /// @dev Packs the `n` signals that start at address `src` into ceil(n / 8) bytes, bit i of the
    ///      result being signal i. Called last: it clears the 32 bytes after the signals.
    function _pack(uint256 src, uint256 n) private pure returns (bytes memory out) {
        out = new bytes((n + 7) / 8);
        assembly ("memory-safe") {
            // A final group of fewer than eight signals is packed together with the bytes after it.
            mstore(add(src, n), 0)

            // Eight signal bytes x0 .. x7, each 0 or 1, are read as the top eight bytes of a word and
            // moved down to a 64-bit number in which x_j sits at bit 56 - 8j. Multiplying by SPREAD puts
            // x_j at bit 56 + j, again with no carries, so bits 56 to 63 of the product are the packed byte.
            let dst := add(out, 0x20)
            let nBytes := mload(out)
            for { let k := 0 } lt(k, nBytes) { k := add(k, 1) } {
                mstore8(add(dst, k), shr(56, mul(shr(192, mload(add(src, shl(3, k)))), SPREAD)))
            }
        }
    }
}
