// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test-only helpers that build TAP-20 netlists and random byte strings.
library NetlistBuilder {
    uint256 internal constant V1_IN = 96;
    uint256 internal constant V1_OUT = 112;
    uint256 internal constant V1_FIRST = 2 + V1_IN; // index of the signal the first record produces

    /// @dev One NAND record: 0x00 a:u24 b:u24.
    function nand(uint256 a, uint256 b) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0x00), uint24(a), uint24(b));
    }

    /// @dev One LATCH record: 0x01 d:u24.
    function latch(uint256 d) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0x01), uint24(d));
    }

    /// @notice The smallest kind of valid v1 chip with `k` state bits (1 <= k <= 256).
    /// @dev k LATCH records wired as a shift register fed by input 0 (LATCH 0 takes input 0, LATCH i takes
    ///      LATCH i-1), then 112 NAND records: output j = NAND(input j mod 96, LATCH j mod k).
    function minimalV1(uint256 k) internal pure returns (bytes memory nl) {
        require(k >= 1 && k <= 256, "k");
        for (uint256 i = 0; i < k; i++) {
            nl = bytes.concat(nl, latch(i == 0 ? 2 : V1_FIRST + i - 1));
        }
        for (uint256 j = 0; j < V1_OUT; j++) {
            nl = bytes.concat(nl, nand(2 + (j % V1_IN), V1_FIRST + (j % k)));
        }
    }

    /// @notice A random valid v1 chip: `nLatch` leading LATCH records, then `nNand` NAND records.
    function randomV1(uint256 seed, uint256 nLatch, uint256 nNand) internal pure returns (bytes memory) {
        return random(seed, V1_IN, nLatch, nNand, true);
    }

    /// @notice A random well-formed flat netlist with `nIn` inputs.
    /// @dev NAND inputs are earlier signals: uniformly chosen, or from the last 16 signals (deep chains),
    ///      or a constant, or the same signal twice. A LATCH d is any signal of the circuit, earlier or
    ///      later, or the LATCH itself, or a constant. With `latchesFirst` false the LATCH records are
    ///      spread uniformly among the NAND records.
    function random(uint256 seed, uint256 nIn, uint256 nLatch, uint256 nNand, bool latchesFirst)
        internal
        pure
        returns (bytes memory nl)
    {
        uint256 total = 4 * nLatch + 7 * nNand;
        uint256 nSignals = 2 + nIn + nLatch + nNand;
        nl = new bytes(total + 32); // slack: records are written as whole words
        assembly ("memory-safe") {
            mstore(nl, total)
            let p := add(nl, 0x20)
            let o := add(2, nIn) // index of the signal the next record produces
            let latchesLeft := nLatch
            let nandsLeft := nNand

            for {} or(latchesLeft, nandsLeft) {} {
                mstore(0x00, seed)
                mstore(0x20, o)
                let h := keccak256(0x00, 0x40)
                let m := and(h, 0xff)

                let isLatch := gt(latchesLeft, 0)
                if iszero(latchesFirst) {
                    isLatch := lt(mod(shr(200, h), add(latchesLeft, nandsLeft)), latchesLeft)
                }

                switch isLatch
                case 1 {
                    let d := mod(shr(8, h), nSignals)
                    if lt(m, 24) { d := o } // holds its own value
                    if and(gt(m, 23), lt(m, 40)) { d := and(shr(8, h), 1) } // a constant
                    mstore(p, or(shl(248, 1), shl(224, d)))
                    p := add(p, 4)
                    latchesLeft := sub(latchesLeft, 1)
                }
                default {
                    let a := mod(shr(8, h), o)
                    let b := mod(shr(72, h), o)
                    if lt(m, 16) { b := a } // both inputs the same signal
                    if and(gt(m, 15), lt(m, 32)) { a := and(shr(136, h), 1) } // a constant
                    if and(gt(m, 31), lt(m, 112)) {
                        let win := 16
                        if lt(o, 16) { win := o }
                        a := sub(o, add(1, mod(shr(8, h), win)))
                        b := sub(o, add(1, mod(shr(72, h), win)))
                    }
                    mstore(p, or(shl(224, a), shl(200, b)))
                    p := add(p, 7)
                    nandsLeft := sub(nandsLeft, 1)
                }
                o := add(o, 1)
            }
        }
    }

    /// @notice `n` pseudo-random bytes.
    function randomBytes(uint256 seed, uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        bytes32 h;
        for (uint256 i = 0; i < n; i++) {
            if (i % 32 == 0) h = keccak256(abi.encode(seed, i));
            out[i] = h[i % 32];
        }
    }

    /// @notice One random edit of a netlist: a byte overwritten, 1 to 7 bytes cut off the end, the last
    ///         record removed, or 1 to 7 bytes appended.
    /// @dev Index bytes are small numbers, so most overwrites use a small value: that is what turns an
    ///      index into a forward reference or an opcode into LATCH or REF.
    function damage(bytes memory nl, uint256 r) internal pure returns (bytes memory) {
        uint256 kind = r % 8;
        r >>= 8;
        if (kind < 5 && nl.length != 0) {
            uint256 at = r % nl.length;
            nl[at] = kind < 3 ? bytes1(uint8((r >> 32) % 48)) : bytes1(uint8(r >> 32));
            return nl;
        }
        if (kind == 5 && nl.length != 0) {
            uint256 cut = 1 + (r % 7);
            return head(nl, cut > nl.length ? 0 : nl.length - cut);
        }
        if (kind == 6 && nl.length != 0) {
            // walk the records (as far as they parse) and keep everything before the last one
            uint256 p = 0;
            uint256 last = 0;
            while (p < nl.length) {
                last = p;
                p += nl[p] == 0x01 ? 4 : 7;
            }
            return head(nl, last);
        }
        return bytes.concat(nl, randomBytes(r, 1 + (r % 7)));
    }

    /// @notice One edit aimed at a rule: in a random record, the opcode is replaced by 0 to 3, or a NAND
    ///         input is moved to within two of the gate's own signal, or a LATCH d is moved to within two
    ///         of the number of signals. `nl` must parse as NAND and LATCH records up to the chosen one.
    function aim(bytes memory nl, uint256 nIn, uint256 r) internal pure returns (bytes memory) {
        // count the records, as far as they parse
        uint256 count = 0;
        for (uint256 p = 0; p < nl.length; p += nl[p] == 0x01 ? 4 : 7) {
            count++;
        }
        if (count == 0) return nl;

        // find the chosen record
        uint256 target = r % count;
        uint256 at = 0;
        for (uint256 i = 0; i < target; i++) {
            at += nl[at] == 0x01 ? 4 : 7;
        }
        bool isLatch = nl[at] == 0x01;
        if (at + (isLatch ? 4 : 7) > nl.length) return nl;

        uint256 kind = (r >> 64) % 3;
        uint256 nudge = (r >> 72) % 5; // -2 .. +2
        if (kind == 0) {
            nl[at] = bytes1(uint8((r >> 80) % 4));
        } else if (isLatch) {
            _putU24(nl, at + 1, 2 + nIn + count - 2 + nudge);
        } else {
            _putU24(nl, at + 1 + 3 * ((r >> 80) & 1), 2 + nIn + target - 2 + nudge);
        }
        return nl;
    }

    function _putU24(bytes memory b, uint256 p, uint256 v) private pure {
        b[p] = bytes1(uint8(v >> 16));
        b[p + 1] = bytes1(uint8(v >> 8));
        b[p + 2] = bytes1(uint8(v));
    }

    /// @notice The first `n` bytes of `b`.
    function head(bytes memory b, uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = b[i];
        }
    }

    /// @notice Number of bytes that hold `nBits` bits.
    function bytesFor(uint256 nBits) internal pure returns (uint256) {
        return (nBits + 7) / 8;
    }
}
