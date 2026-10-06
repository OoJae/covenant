// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {KernelMath} from "core/KernelMath.sol";

/// @title KernelMathV2
/// @notice Kernel v1's routing (core/KernelMath.sol, INTERFACE section 8) with a code shift for the quote asset,
///         bit for bit equal to `route_tax_v2` in chips/golden/kernel_model_v2.py. Pure, integer only, never
///         reverts on any chip output. With `s = 0` every function here is exactly its kernel v1 counterpart.
///
///         Why a shift. A chip compiled for kernel v1 (the Flow Governor) reads amounts as lg8 codes of wei of
///         OKB. A v2 kernel on the curve holds USD₮0, 6 decimals. Two identities hold exactly for every integer
///         s >= 0 (chips/golden/kernel_model_v2.py checks them exhaustively for small amounts and s <= 40):
///
///             lg8(x << s)        == min(1023, lg8(x) + 8 s)        for x >= 1 (and 0 for x = 0)
///             exp8(c + 8 s) >> s == exp8(c)                         for 1 <= c <= 1023 - 8 s
///
///         So a kernel that shows the chip lg8(amount << s) and turns every amount code the chip or the
///         envelope gives back into exp8(code) >> s presents USD₮0 amounts to the chip exactly as amounts
///         2^s times larger, and the chip's code-level proofs carry over unchanged. With s = 33, one USD₮0
///         base unit reads as 2^33 wei: 1 OKB of the chip's calibration is 10^18 / 2^33 = 116.415 USD₮0.
///
///         Envelope codes (`ceilMax`, `floorMin`) are in the same shifted code space as the chip's codes, so
///         an envelope means the same thing to a chip on either kernel. After graduation the regime asset is
///         the project token (18 decimals, as on kernel v1) and the kernel passes s = 0.
library KernelMathV2 {
    uint256 internal constant AMOUNT_MAX = type(uint128).max;

    /// @notice lg8 of an amount seen through a shift of `s` bits: lg8(min(x, 2^128 - 1) << s).
    /// @dev    Saturating x at 2^128 - 1 first changes no code (lg8 is already 1023 there) and keeps the shift
    ///         inside 256 bits for every s the factory accepts (s <= 40).
    function lg8s(uint256 x, uint256 s) internal pure returns (uint256) {
        if (x > AMOUNT_MAX) x = AMOUNT_MAX;
        return KernelMath.lg8(x << s);
    }

    /// @notice The smallest amount of the shifted unit whose code is c, in base units, rounded down:
    ///         exp8(c) >> s. Used for ceilings: rounding down can only make a ceiling tighter.
    function exp8s(uint256 c, uint256 s) internal pure returns (uint256) {
        return KernelMath.exp8(c) >> s;
    }

    /// @notice Routing of the regime asset for one settle (INTERFACE section 8.2, with the shift). Never reverts.
    /// @param  s the code shift in bits: the kernel's quote shift on the curve, 0 after graduation
    /// @dev    Differences from KernelMath.route, and nothing else:
    ///           chip ceiling   allow = min(allow, exp8(CEIL) >> s)                (not a clamp, as in v1)
    ///           K2C            ceiling exp8(ceilMax) >> s
    ///           K5             lg8(reserve0 << s) >= floorMin
    function route(
        KernelMath.RouteEnv memory env,
        uint256 outWord,
        uint256 inflow,
        uint256 reserve0,
        uint256 cumInflow,
        uint256 allowPaidCum,
        bool graduated,
        uint256 s
    ) internal pure returns (KernelMath.Routed memory r) {
        uint16 clamp;

        // ---- shares: K1T, K2 (as kernel v1)
        {
            uint256 tb = outWord & 0x1ff;
            uint256 th = (outWord >> 9) & 0x1ff;
            uint256 ta = (outWord >> 18) & 0x1ff;
            uint256 tr = (outWord >> 27) & 0x1ff;
            unchecked {
                if (tb > 256 || th > 256 || ta > 256 || tr > 256 || tb + th + ta + tr != 256) {
                    (tb, th, ta, tr) = (0, 0, 0, 256);
                    clamp |= KernelMath.K1T;
                }
                if (graduated) {
                    // no allowance in the token regime: the share stays in the reserve; not a clamp
                    tr += ta;
                    ta = 0;
                }
                if (ta > env.capT) {
                    tr += ta - env.capT;
                    ta = env.capT;
                    clamp |= KernelMath.K2;
                }
            }
            r.sBuy = tb;
            r.sHold = th;
            r.sAllow = ta;
            r.sRes = tr;
        }

        // ---- allowance: chip ceiling, K2C, K2L. Amounts are bounded by the caller to 128 bits.
        {
            uint256 allow = (inflow * r.sAllow) / 256;
            uint256 ceil = (outWord >> 81) & 0x3ff;
            if (ceil != KernelMath.LG8_MAX) {
                uint256 c = exp8s(ceil, s);
                if (allow > c) allow = c;
            }
            if (env.ceilMax != KernelMath.LG8_MAX) {
                uint256 cm = exp8s(env.ceilMax, s);
                if (allow > cm) {
                    allow = cm;
                    clamp |= KernelMath.K2C;
                }
            }
            uint256 lim = (cumInflow * env.allowCumBps) / 10000;
            uint256 room = lim > allowPaidCum ? lim - allowPaidCum : 0;
            if (allow > room) {
                allow = room;
                clamp |= KernelMath.K2L;
            }
            r.allow = allow;
        }

        r.buyShare = (inflow * r.sBuy) / 256;
        r.toReserve = inflow - r.allow - r.buyShare;

        // ---- release: K3, K5
        {
            uint256 rel = (outWord >> 72) & 0x1ff;
            if (rel > env.relMax) {
                rel = env.relMax;
                clamp |= KernelMath.K3;
            }
            if (lg8s(reserve0, s) >= env.floorMin && rel < env.floorRel) {
                rel = env.floorRel;
                clamp |= KernelMath.K5;
            }
            r.rel = rel;
            r.release = (reserve0 * rel) / 256;
        }

        r.clamp = clamp;
        r.buyDecided = r.buyShare + r.release;
        r.reserveAfter = reserve0 - r.release + r.toReserve;
    }
}
