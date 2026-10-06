// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {KernelMath} from "core/KernelMath.sol";
import {KernelMathV2} from "../../src/KernelMathV2.sol";

/// @notice Properties of KernelMathV2 for any input: the shift identities, the s = 0 case is kernel v1, and the
///         routing never reverts and keeps every guarantee of INTERFACE section 7 for any output word.
contract KernelMathV2FuzzTest is Test {
    function _env(uint256 seed) internal pure returns (KernelMath.RouteEnv memory e) {
        e.capT = seed % 129;
        e.allowCumBps = (seed >> 8) % 5001;
        e.ceilMax = (seed >> 24) % 3 == 0 ? 1023 : (seed >> 34) % 1024;
        e.relMax = 1 + (seed >> 44) % 256;
        e.floorRel = 1 + (seed >> 54) % e.relMax;
        e.floorMin = 1 + (seed >> 64) % 425;
    }

    /// lg8(x << s) == min(1023, lg8(x) + 8 s) for x >= 1, and 0 for x = 0.
    function testFuzz_lg8s_is_lg8_moved_by_8s_codes(uint256 x, uint8 s8) public pure {
        uint256 s = s8 % 41;
        x = bound(x, 0, type(uint128).max);
        uint256 c = KernelMathV2.lg8s(x, s);
        if (x == 0) {
            assertEq(c, 0);
        } else {
            uint256 want = KernelMath.lg8(x) + 8 * s;
            assertEq(c, want > 1023 ? 1023 : want);
        }
    }

    /// Amounts above 2^128 - 1 saturate like kernel v1's: the code is 1023 for every shift.
    function testFuzz_lg8s_saturates(uint256 x, uint8 s8) public pure {
        x = bound(x, uint256(type(uint128).max), type(uint256).max);
        assertEq(KernelMathV2.lg8s(x, s8 % 41), 1023);
    }

    /// exp8(c + 8 s) >> s == exp8(c): a code moved by 8 s and decoded with the shift is the code itself.
    function testFuzz_exp8s_identity(uint16 c16, uint8 s8) public pure {
        uint256 s = s8 % 41;
        uint256 c = bound(c16, 1, 1023 - 8 * s);
        assertEq(KernelMathV2.exp8s(c + 8 * s, s), KernelMath.exp8(c));
        // a ceiling decoded through the shift is never above the amount the chip meant
        assertLe(KernelMathV2.exp8s(c, s) << s, KernelMath.exp8(c));
    }

    /// With s = 0, KernelMathV2.route is KernelMath.route, field for field, for any word and any amounts.
    function testFuzz_shift_zero_is_kernel_v1(
        uint256 seed,
        uint256 word,
        uint128 inflow,
        uint128 reserve0,
        uint128 prior,
        uint128 paid,
        bool grad
    ) public pure {
        KernelMath.RouteEnv memory e = _env(seed);
        word &= (uint256(1) << 112) - 1;
        uint256 cum = uint256(inflow) + prior;
        if (cum > type(uint128).max) cum = type(uint128).max;
        KernelMath.Routed memory a = KernelMath.route(e, word, inflow, reserve0, cum, paid, grad);
        KernelMath.Routed memory b = KernelMathV2.route(e, word, inflow, reserve0, cum, paid, grad, 0);
        assertEq(keccak256(abi.encode(a)), keccak256(abi.encode(b)));
    }

    /// Any word, any amounts, any shift the factory accepts: no revert, conservation, and the envelope holds.
    function testFuzz_route_any_word_any_shift(
        uint256 seed,
        uint256 word,
        uint128 inflow,
        uint128 reserve0,
        uint128 prior,
        uint128 paid,
        bool grad,
        uint8 s8
    ) public pure {
        uint256 s = grad ? 0 : s8 % 41;
        KernelMath.RouteEnv memory e = _env(seed);
        word &= (uint256(1) << 112) - 1;
        uint256 cum = uint256(inflow) + prior;
        if (cum > type(uint128).max) cum = type(uint128).max;
        KernelMath.Routed memory r = KernelMathV2.route(e, word, inflow, reserve0, cum, paid, grad, s);
        assertEq(r.allow + r.buyShare + r.toReserve, inflow, "conservation");
        assertLe(r.release, reserve0);
        assertEq(r.sBuy + r.sHold + r.sAllow + r.sRes, 256, "effective shares sum to 256");
        assertLe(r.allow * 256, uint256(inflow) * e.capT, "allowance at most capT / 256 of the inflow");
        if (e.ceilMax != 1023) assertLe(r.allow, KernelMathV2.exp8s(e.ceilMax, s), "per-settle ceiling");
        assertLe(r.allow, cum * e.allowCumBps / 10_000 > paid ? cum * e.allowCumBps / 10_000 - paid : 0, "lifetime");
        assertLe(r.rel, e.relMax > e.floorRel ? e.relMax : e.floorRel);
        if (grad) assertEq(r.allow, 0, "no allowance after graduation");
        assertEq(r.reserveAfter, uint256(reserve0) - r.release + r.toReserve);
        assertEq(r.clamp & (KernelMath.K1V | KernelMath.K2V), 0, "the revenue clamps are never set (c')");
    }

    /// The chip sees a quote amount x exactly as kernel v1 would show it x * 2^s wei: the three amount codes of the
    /// input word agree for every amount. This is what lets a chip compiled for OKB run unchanged.
    function testFuzz_the_chip_sees_x_as_v1_would_see_x_times_2_pow_s(uint128 x, uint8 s8) public pure {
        uint256 s = s8 % 41;
        assertEq(KernelMathV2.lg8s(x, s), KernelMath.lg8(uint256(x) << s));
    }
}
