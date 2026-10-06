// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title KernelMath
/// @notice The arithmetic of Covenant interface v1 (chips/INTERFACE.md sections 3-8), bit for bit equal to the
///         reference model chips/golden/kernel_model.py. Pure, integer only, never reverts on any chip output.
/// @dev    No CLZ opcode: X Layer has no Osaka. The most significant bit is found by binary search.
library KernelMath {
    // ----------------------------------------------------------------------------------- constants

    uint256 internal constant LG8_MAX = 1023;

    uint256 internal constant IN_BITS = 96;
    uint256 internal constant OUT_BITS = 112;
    uint256 internal constant IN_BYTES = 12;
    uint256 internal constant OUT_BYTES = 14;

    /// Clamp bits written to a record (values frozen by chips/golden/vectors.json, layout.clampBits).
    uint16 internal constant K1T = 1 << 0; // tax share group malformed: treated as 100% reserve
    uint16 internal constant K1V = 1 << 1; // revenue share group malformed (kernel v2; never set by v1)
    uint16 internal constant K2 = 1 << 2; // T_ALLOW above capT: clipped, the excess stays in the reserve
    uint16 internal constant K2C = 1 << 3; // allowance amount above the envelope ceiling: clipped
    uint16 internal constant K2L = 1 << 4; // allowance above the lifetime cap: clipped
    uint16 internal constant K3 = 1 << 5; // REL above relMax: clipped
    uint16 internal constant K5 = 1 << 6; // REL below the reserve floor: raised
    uint16 internal constant K2V = 1 << 7; // revenue allowance share above capV (kernel v2; never set by v1)

    // ----------------------------------------------------------------------------------- types

    /// The fields of the 96-bit input word (INTERFACE section 5).
    struct InputFields {
        uint256 tax; // 10 bits, lg8
        uint256 taxCum; // 10 bits, lg8
        uint256 rev; // 10 bits, lg8 (kernel v1: 0)
        uint256 revCum; // 10 bits, lg8 (kernel v1: 0)
        uint256 res; // 10 bits, lg8
        uint256 esc; // 10 bits, lg8 (kernel v1: 0)
        uint256 prog; // 8 bits
        uint256 lock; // 8 bits
        uint256 dt; // 4 bits
        uint256 grad; // 1 bit
    }

    /// The fields of the 112-bit output word (INTERFACE section 6).
    struct OutputFields {
        uint256 tBuy;
        uint256 tHold;
        uint256 tAllow;
        uint256 tRes;
        uint256 vBuy;
        uint256 vHold;
        uint256 vAllow;
        uint256 vRes;
        uint256 rel;
        uint256 ceil;
        uint256 mode;
        uint256 tier;
        uint256 flags;
        uint256 aux;
    }

    /// The numeric envelope values the routing function needs.
    struct RouteEnv {
        uint256 capT;
        uint256 allowCumBps;
        uint256 ceilMax;
        uint256 relMax;
        uint256 floorRel;
        uint256 floorMin;
    }

    /// Result of routing one settle (kernel_model.Routed).
    struct Routed {
        uint16 clamp;
        uint256 allow; // credited to the allowance payee
        uint256 buyShare; // part of the fresh inflow sent to buy-and-lock
        uint256 release; // part of the pre-settle reserve sent to buy-and-lock
        uint256 buyDecided; // buyShare + release
        uint256 toReserve; // part of the fresh inflow that stays (hold + reserve + clipped excess + dust)
        uint256 reserveAfter; // if the whole decided buy executes
        uint256 sBuy; // effective shares after K1T and K2
        uint256 sHold;
        uint256 sAllow;
        uint256 sRes;
        uint256 rel; // effective REL after K3 and K5
    }

    // ----------------------------------------------------------------------------------- log code

    /// @notice Index of the most significant set bit; 0 for x = 0 (callers treat zero separately).
    function msb(uint256 x) internal pure returns (uint256 r) {
        unchecked {
            if (x >> 128 != 0) {
                x >>= 128;
                r = 128;
            }
            if (x >> 64 != 0) {
                x >>= 64;
                r += 64;
            }
            if (x >> 32 != 0) {
                x >>= 32;
                r += 32;
            }
            if (x >> 16 != 0) {
                x >>= 16;
                r += 16;
            }
            if (x >> 8 != 0) {
                x >>= 8;
                r += 8;
            }
            if (x >> 4 != 0) {
                x >>= 4;
                r += 4;
            }
            if (x >> 2 != 0) {
                x >>= 2;
                r += 2;
            }
            if (x >> 1 != 0) {
                r += 1;
            }
        }
    }

    /// @notice 10-bit log code in 1/8-octave steps. lg8(0) = 0, lg8(1) = 1, saturates at 1023.
    function lg8(uint256 x) internal pure returns (uint256 c) {
        if (x == 0) return 0;
        unchecked {
            uint256 e = msb(x);
            uint256 m = e >= 3 ? (x >> (e - 3)) & 7 : (x << (3 - e)) & 7;
            c = 8 * e + m + 1;
            if (c > LG8_MAX) c = LG8_MAX;
        }
    }

    /// @notice Floor inverse of lg8: the smallest amount whose code is c (0 for c = 0).
    /// @dev    Codes above 1023 cannot occur (10-bit fields); they are saturated so the function never reverts.
    function exp8(uint256 c) internal pure returns (uint256) {
        if (c == 0) return 0;
        if (c > LG8_MAX) c = LG8_MAX;
        unchecked {
            uint256 k = c - 1;
            return ((8 + (k & 7)) << (k >> 3)) >> 3;
        }
    }

    // ----------------------------------------------------------------------------------- bytes <-> words

    /// @dev Reverses the low `n` bytes of `x` (n <= 32). Higher bytes of `x` must be zero.
    function _reverse(uint256 x, uint256 n) private pure returns (uint256 r) {
        unchecked {
            for (uint256 i = 0; i < n; ++i) {
                r = (r << 8) | (x & 0xff);
                x >>= 8;
            }
        }
    }

    /// @notice TAP-20 byte string of a 96-bit word: byte i holds bits 8i..8i+7 (little-endian).
    function inputBytes(uint256 word) internal pure returns (bytes12) {
        return bytes12(uint96(_reverse(word & type(uint96).max, IN_BYTES)));
    }

    /// @notice The 96-bit word held by 12 TAP-20 bytes.
    function inputWord(bytes12 b) internal pure returns (uint256) {
        return _reverse(uint256(uint96(b)), IN_BYTES);
    }

    /// @notice TAP-20 byte string of a 112-bit word.
    function outputBytes(uint256 word) internal pure returns (bytes14) {
        return bytes14(uint112(_reverse(word & type(uint112).max, OUT_BYTES)));
    }

    /// @notice The 112-bit word held by 14 TAP-20 bytes.
    function outputWord(bytes14 b) internal pure returns (uint256) {
        return _reverse(uint256(uint112(b)), OUT_BYTES);
    }

    /// @notice Kernel storage form of a chip state: the TAP-20 byte string, right-padded with zeros to 32 bytes.
    ///         Bytes past the 32nd are dropped (the Fab enforces nState <= 256, so there are none).
    function stateToBytes32(bytes memory s) internal pure returns (bytes32 out) {
        uint256 n = s.length;
        if (n == 0) return bytes32(0);
        assembly ("memory-safe") {
            out := mload(add(s, 0x20))
        }
        if (n < 32) {
            // memory past the end of `s` is not guaranteed to be zero
            out &= bytes32(~(type(uint256).max >> (8 * n)));
        }
    }

    /// @notice The state as an integer: state bit i is bit i of the result.
    function stateBits(bytes32 s) internal pure returns (uint256) {
        return _reverse(uint256(s), 32);
    }

    /// @notice Packs the input fields into the 96-bit word. Each field is masked to its width.
    function packInput(InputFields memory f) internal pure returns (uint256 word) {
        unchecked {
            word = (f.tax & 0x3ff) | ((f.taxCum & 0x3ff) << 10) | ((f.rev & 0x3ff) << 20) | ((f.revCum & 0x3ff) << 30)
                | ((f.res & 0x3ff) << 40) | ((f.esc & 0x3ff) << 50) | ((f.prog & 0xff) << 60) | ((f.lock & 0xff) << 68)
                | ((f.dt & 0xf) << 76) | ((f.grad & 1) << 80);
        }
    }

    function unpackInput(uint256 word) internal pure returns (InputFields memory f) {
        f.tax = word & 0x3ff;
        f.taxCum = (word >> 10) & 0x3ff;
        f.rev = (word >> 20) & 0x3ff;
        f.revCum = (word >> 30) & 0x3ff;
        f.res = (word >> 40) & 0x3ff;
        f.esc = (word >> 50) & 0x3ff;
        f.prog = (word >> 60) & 0xff;
        f.lock = (word >> 68) & 0xff;
        f.dt = (word >> 76) & 0xf;
        f.grad = (word >> 80) & 1;
    }

    function unpackOutput(uint256 word) internal pure returns (OutputFields memory o) {
        o.tBuy = word & 0x1ff;
        o.tHold = (word >> 9) & 0x1ff;
        o.tAllow = (word >> 18) & 0x1ff;
        o.tRes = (word >> 27) & 0x1ff;
        o.vBuy = (word >> 36) & 0x1ff;
        o.vHold = (word >> 45) & 0x1ff;
        o.vAllow = (word >> 54) & 0x1ff;
        o.vRes = (word >> 63) & 0x1ff;
        o.rel = (word >> 72) & 0x1ff;
        o.ceil = (word >> 81) & 0x3ff;
        o.mode = (word >> 91) & 0x7;
        o.tier = (word >> 94) & 0x3;
        o.flags = (word >> 96) & 0xff;
        o.aux = (word >> 104) & 0xff;
    }

    function packOutput(OutputFields memory o) internal pure returns (uint256 word) {
        unchecked {
            word = (o.tBuy & 0x1ff) | ((o.tHold & 0x1ff) << 9) | ((o.tAllow & 0x1ff) << 18) | ((o.tRes & 0x1ff) << 27)
                | ((o.vBuy & 0x1ff) << 36) | ((o.vHold & 0x1ff) << 45) | ((o.vAllow & 0x1ff) << 54)
                | ((o.vRes & 0x1ff) << 63) | ((o.rel & 0x1ff) << 72) | ((o.ceil & 0x3ff) << 81) | ((o.mode & 0x7) << 91)
                | ((o.tier & 0x3) << 94) | ((o.flags & 0xff) << 96) | ((o.aux & 0xff) << 104);
        }
    }

    /// @notice The output word the kernel applies when the evaluator has failed past the grace period:
    ///         T_BUY = 256 - fbAllow, T_ALLOW = fbAllow, REL = relMax, CEIL = 1023, everything else 0.
    function fallbackWord(uint256 fbAllow, uint256 relMax) internal pure returns (uint256) {
        unchecked {
            uint256 a = fbAllow > 256 ? 256 : fbAllow;
            return (256 - a) | (a << 18) | ((relMax & 0x1ff) << 72) | (LG8_MAX << 81);
        }
    }

    // ----------------------------------------------------------------------------------- small codes

    /// @notice PROG: min(254, sold * 255 / sellable); 255 once graduated; 0 if sellable is 0.
    function progCode(uint256 sold, uint256 sellable, bool graduated) internal pure returns (uint256) {
        if (graduated) return 255;
        if (sellable == 0) return 0;
        if (sold >= sellable) return 254; // sold * 255 / sellable >= 255, capped at 254
        unchecked {
            // Real values are at most 128 bits. Larger ones (a hostile or broken read) are scaled down so the
            // product cannot overflow; the function never reverts.
            if (sellable >> 248 != 0) {
                sold >>= 8;
                sellable >>= 8;
            }
            return (sold * 255) / sellable; // sold < sellable, so the quotient is at most 254
        }
    }

    /// @notice LOCK: min(255, locked * 255 / totalSupply); 0 if totalSupply is 0.
    function lockCode(uint256 lockedOrBurned, uint256 totalSupply) internal pure returns (uint256) {
        if (totalSupply == 0) return 0;
        if (lockedOrBurned >= totalSupply) return 255;
        unchecked {
            if (totalSupply >> 248 != 0) {
                lockedOrBurned >>= 8;
                totalSupply >>= 8;
            }
            return (lockedOrBurned * 255) / totalSupply; // lockedOrBurned < totalSupply: at most 254
        }
    }

    /// @notice DT: epochs since the last persisted step, at least 1, saturating at 15.
    function dtCode(uint256 epochNow, uint256 lastEpoch) internal pure returns (uint256) {
        if (epochNow <= lastEpoch) return 1; // unreachable from settle(), which requires a new epoch
        unchecked {
            uint256 d = epochNow - lastEpoch;
            return d > 15 ? 15 : d;
        }
    }

    // ----------------------------------------------------------------------------------- routing

    /// @notice Routing of the regime asset for one settle (INTERFACE section 8). Never reverts.
    /// @param  env          numeric envelope values
    /// @param  outWord      the chip's 112-bit output word (or the fallback word)
    /// @param  inflow       fresh inflow of the regime asset (a balance delta)
    /// @param  reserve0     reserve before routing
    /// @param  cumInflow    cumulative inflow in the current regime, `inflow` included
    /// @param  allowPaidCum allowance credited so far in the current regime
    /// @param  graduated    the regime. Kernel v1 pays no allowance after graduation: the T_ALLOW share joins
    ///                      the reserve share, `allow` is 0 and none of K2, K2C, K2L is set
    function route(
        RouteEnv memory env,
        uint256 outWord,
        uint256 inflow,
        uint256 reserve0,
        uint256 cumInflow,
        uint256 allowPaidCum,
        bool graduated
    ) internal pure returns (Routed memory r) {
        uint16 clamp;

        // ---- shares: K1T, K2 (written straight into the result to keep the stack shallow)
        {
            uint256 tb = outWord & 0x1ff;
            uint256 th = (outWord >> 9) & 0x1ff;
            uint256 ta = (outWord >> 18) & 0x1ff;
            uint256 tr = (outWord >> 27) & 0x1ff;
            unchecked {
                // K1T: a malformed share group becomes 100% reserve. Each share is < 512: the sum cannot overflow.
                if (tb > 256 || th > 256 || ta > 256 || tr > 256 || tb + th + ta + tr != 256) {
                    (tb, th, ta, tr) = (0, 0, 0, 256);
                    clamp |= K1T;
                }
                if (graduated) {
                    // No allowance in the token regime: the share stays in the reserve. Not a clamp. With an
                    // allowance share of zero the amount below is zero and none of K2, K2C, K2L can fire.
                    tr += ta;
                    ta = 0;
                }
                // K2: the excess allowance share stays in the reserve.
                if (ta > env.capT) {
                    tr += ta - env.capT;
                    ta = env.capT;
                    clamp |= K2;
                }
            }
            r.sBuy = tb;
            r.sHold = th;
            r.sAllow = ta;
            r.sRes = tr;
        }

        // ---- allowance: chip ceiling, K2C, K2L
        // Amounts are bounded by the caller to 128 bits, so the products below cannot overflow 256 bits.
        {
            uint256 allow = (inflow * r.sAllow) / 256;
            uint256 ceil = (outWord >> 81) & 0x3ff;
            if (ceil != LG8_MAX) {
                // the chip's own ceiling; not a clamp
                uint256 c = exp8(ceil);
                if (allow > c) allow = c;
            }
            if (env.ceilMax != LG8_MAX) {
                uint256 cm = exp8(env.ceilMax);
                if (allow > cm) {
                    allow = cm;
                    clamp |= K2C;
                }
            }
            uint256 lim = (cumInflow * env.allowCumBps) / 10000;
            uint256 room = lim > allowPaidCum ? lim - allowPaidCum : 0;
            if (allow > room) {
                allow = room;
                clamp |= K2L;
            }
            r.allow = allow;
        }

        r.buyShare = (inflow * r.sBuy) / 256;
        // allow <= inflow * sAllow / 256 and buyShare = inflow * sBuy / 256 with sAllow + sBuy <= 256,
        // so the difference cannot be negative.
        r.toReserve = inflow - r.allow - r.buyShare;

        // ---- release: K3, K5
        {
            uint256 rel = (outWord >> 72) & 0x1ff;
            if (rel > env.relMax) {
                rel = env.relMax;
                clamp |= K3;
            }
            if (lg8(reserve0) >= env.floorMin && rel < env.floorRel) {
                rel = env.floorRel;
                clamp |= K5;
            }
            r.rel = rel;
            r.release = (reserve0 * rel) / 256;
        }

        r.clamp = clamp;
        r.buyDecided = r.buyShare + r.release;
        // rel <= relMax <= 256 for every envelope the factory accepts, so release <= reserve0.
        r.reserveAfter = reserve0 - r.release + r.toReserve;
    }
}
