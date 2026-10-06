// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {NetlistBuilder} from "./NetlistBuilder.sol";

/// @notice Test-only: section 2 of chips/INTERFACE.md written the slow and obvious way, independently of
///         NetlistScan, and a generator of chips that sit near its limits.
library V1Reference {
    uint256 internal constant FIRST = 98; // 2 constants + 96 inputs

    /// @return ok     whether `nl` is a v1 chip
    /// @return nNand  its NAND count, when ok
    /// @return nLatch its LATCH count, when ok
    function check(bytes memory nl) internal pure returns (bool ok, uint256 nNand, uint256 nLatch) {
        if (nl.length > 24000) return (false, 0, 0);
        uint256 p = 0;
        uint256 maxD = 0;
        while (p < nl.length) {
            uint8 op = uint8(nl[p]);
            if (op == 0x01) {
                if (nNand != 0) return (false, 0, 0); // LATCH after NAND
                if (p + 4 > nl.length) return (false, 0, 0);
                uint256 d = _u24(nl, p + 1);
                if (d > maxD) maxD = d;
                nLatch++;
                p += 4;
            } else if (op == 0x00) {
                if (p + 7 > nl.length) return (false, 0, 0);
                uint256 self = FIRST + nLatch + nNand;
                if (_u24(nl, p + 1) >= self || _u24(nl, p + 4) >= self) return (false, 0, 0);
                nNand++;
                p += 7;
            } else {
                return (false, 0, 0);
            }
        }
        uint256 gates = nNand + nLatch;
        if (nLatch < 1 || nLatch > 256) return (false, 0, 0);
        if (gates > 3400 || gates < 112) return (false, 0, 0);
        if (maxD >= FIRST + gates) return (false, 0, 0);
        return (true, nNand, nLatch);
    }

    /// @notice A chip near the limits of section 2 (about 112 records; 0, a few, or about 256 LATCH
    ///         records), then edited 0 to 3 times: the first edit is often aimed at one rule (an opcode,
    ///         a LATCH d near the number of signals, a NAND input near the gate's own signal), the others
    ///         are general damage. About a quarter of the results are still valid chips.
    function mutant(uint256 seed) internal pure returns (bytes memory nl) {
        uint256 r = uint256(keccak256(abi.encode(seed, "scan-mutant")));
        uint256 k;
        uint256 c = r % 20;
        if (c == 0) k = 0;
        else if (c < 17) k = 1 + ((r >> 8) % 6);
        else k = 255 + ((r >> 8) % 4); // 255 .. 258
        uint256 total = 110 + ((r >> 16) % 12); // 110 .. 121 records, unless the LATCH records alone are more
        uint256 n = k >= total ? (r >> 24) % 3 : total - k;
        nl = NetlistBuilder.randomV1(seed, k, n);

        uint256 edits = (r >> 32) % 4;
        for (uint256 e = 0; e < edits; e++) {
            uint256 x = uint256(keccak256(abi.encode(seed, e)));
            nl = (e == 0 && x % 3 != 0) ? NetlistBuilder.aim(nl, 96, x >> 8) : NetlistBuilder.damage(nl, x >> 8);
        }
    }

    function _u24(bytes memory b, uint256 p) private pure returns (uint256) {
        return (uint256(uint8(b[p])) << 16) | (uint256(uint8(b[p + 1])) << 8) | uint256(uint8(b[p + 2]));
    }
}
