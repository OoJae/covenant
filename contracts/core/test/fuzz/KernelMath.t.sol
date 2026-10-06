// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {KernelMath} from "../../src/KernelMath.sol";

/// @notice Properties of KernelMath over the whole input space (the golden vectors are in test/golden).
contract KernelMathFuzzTest is Test {
    // ------------------------------------------------------------------ log code

    /// A bit-by-bit transcription of kernel_model.lg8, as a second implementation.
    function _lg8Slow(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 e;
        for (uint256 y = x; y > 1; y >>= 1) {
            e++;
        }
        uint256 m = e >= 3 ? (x >> (e - 3)) & 7 : (x << (3 - e)) & 7;
        uint256 c = 8 * e + m + 1;
        return c > 1023 ? 1023 : c;
    }

    function testFuzz_lg8_equals_the_slow_definition(uint256 x) public pure {
        assertEq(KernelMath.lg8(x), _lg8Slow(x));
    }

    function testFuzz_lg8_small_and_shifted(uint8 shift, uint16 mantissa) public pure {
        uint256 x = uint256(mantissa) << shift;
        assertEq(KernelMath.lg8(x), _lg8Slow(x));
    }

    function testFuzz_msb(uint256 x) public pure {
        vm.assume(x != 0);
        uint256 e = KernelMath.msb(x);
        assertEq(x >> e, 1, "the bit at msb is the highest set bit");
    }

    function testFuzz_lg8_is_monotone(uint256 a, uint256 b) public pure {
        if (a > b) (a, b) = (b, a);
        assertLe(KernelMath.lg8(a), KernelMath.lg8(b));
    }

    function testFuzz_exp8_is_a_floor_inverse(uint256 x) public pure {
        x = bound(x, 0, type(uint128).max);
        uint256 c = KernelMath.lg8(x);
        uint256 lo = KernelMath.exp8(c);
        assertLe(lo, x, "exp8(lg8(x)) <= x");
        if (x >= 8 && c < 1023) {
            assertLt(x, KernelMath.exp8(c + 1), "x is below the next code's floor");
            assertGe(lo * 9, x * 8, "one code is at most 1/8 of an octave: exp8(lg8(x)) >= 8x/9");
        }
    }

    function test_exp8_never_reverts_for_any_code() public pure {
        for (uint256 c = 0; c <= 1023; c++) {
            KernelMath.exp8(c);
        }
        assertEq(KernelMath.exp8(5000), KernelMath.exp8(1023), "codes above 1023 saturate");
        assertEq(KernelMath.lg8(type(uint256).max), 1023);
    }

    function test_reference_points() public pure {
        assertEq(KernelMath.lg8(1), 1);
        assertEq(KernelMath.lg8(1e6), 160);
        assertEq(KernelMath.lg8(0.001 ether), 399);
        assertEq(KernelMath.lg8(0.01 ether), 425);
        assertEq(KernelMath.lg8(1 ether), 478);
        assertEq(KernelMath.lg8(1e27), 717);
    }

    // ------------------------------------------------------------------ words

    function testFuzz_input_word_round_trip(uint96 word) public pure {
        bytes12 b = KernelMath.inputBytes(word);
        assertEq(KernelMath.inputWord(b), word);
        // TAP-20: bit i of the word is bit (i mod 8) of byte (i / 8)
        for (uint256 i = 0; i < 96; i += 7) {
            assertEq((uint8(b[i / 8]) >> (i % 8)) & 1, (uint256(word) >> i) & 1);
        }
        KernelMath.InputFields memory f = KernelMath.unpackInput(word & ((uint256(1) << 81) - 1));
        assertEq(KernelMath.packInput(f), word & ((uint256(1) << 81) - 1));
    }

    function testFuzz_output_word_round_trip(uint112 word) public pure {
        bytes14 b = KernelMath.outputBytes(word);
        assertEq(KernelMath.outputWord(b), word);
        for (uint256 i = 0; i < 112; i += 5) {
            assertEq((uint8(b[i / 8]) >> (i % 8)) & 1, (uint256(word) >> i) & 1);
        }
        assertEq(KernelMath.packOutput(KernelMath.unpackOutput(word)), word);
    }

    function testFuzz_packInput_masks_every_field(uint256 a, uint256 b, uint256 c, uint256 d) public pure {
        KernelMath.InputFields memory f;
        f.tax = a;
        f.taxCum = b;
        f.res = c;
        f.prog = d;
        f.lock = a ^ b;
        f.dt = c ^ d;
        f.grad = a;
        uint256 w = KernelMath.packInput(f);
        assertEq(w >> 81, 0, "nothing above bit 80");
        assertEq(w & 0x3ff, a & 0x3ff);
        assertEq((w >> 20) & 0xfffff, 0, "REV and REVCUM are zero in kernel v1");
        assertEq((w >> 50) & 0x3ff, 0, "ESC is zero in kernel v1");
    }

    function testFuzz_stateToBytes32_ignores_dirty_memory(bytes32 junk, uint8 len) public pure {
        uint256 n = bound(len, 0, 40);
        bytes memory s = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            s[i] = bytes1(uint8(i + 1));
        }
        // poison the memory right after the array
        assembly {
            mstore(add(add(s, 0x20), mload(s)), junk)
        }
        bytes32 out = KernelMath.stateToBytes32(s);
        for (uint256 i = 0; i < 32; i++) {
            assertEq(uint8(out[i]), i < n ? uint8(i + 1) : 0);
        }
    }

    function testFuzz_small_codes(uint128 sold, uint128 sellable, uint128 locked, uint128 supply, uint32 a, uint32 b)
        public
        pure
    {
        uint256 p = KernelMath.progCode(sold, sellable, false);
        assertLe(p, 254);
        if (sellable != 0 && sold < sellable) assertEq(p, (uint256(sold) * 255) / sellable);
        assertEq(KernelMath.progCode(sold, sellable, true), 255);
        uint256 l = KernelMath.lockCode(locked, supply);
        assertLe(l, 255);
        if (supply != 0 && locked <= supply) assertEq(l, (uint256(locked) * 255) / supply);
        uint256 dt = KernelMath.dtCode(a, b);
        assertGe(dt, 1);
        assertLe(dt, 15);
        // never reverts on absurd reads
        KernelMath.progCode(type(uint256).max - 1, type(uint256).max, false);
        KernelMath.lockCode(type(uint256).max - 1, type(uint256).max);
    }

    // ------------------------------------------------------------------ routing

    struct Env {
        uint256 capT;
        uint256 allowCumBps;
        uint256 ceilMax;
        uint256 relMax;
        uint256 floorRel;
        uint256 floorMin;
    }

    function _env(uint256 seed) internal pure returns (KernelMath.RouteEnv memory e) {
        // every envelope the factory accepts, and more: the routing arithmetic is total on these ranges
        // (the factory itself stops at capT 128, allowCumBps 5000 and floorMin 1..425)
        e.capT = uint256(keccak256(abi.encode(seed, 1))) % 257;
        e.allowCumBps = uint256(keccak256(abi.encode(seed, 2))) % 10_000;
        e.ceilMax =
            uint256(keccak256(abi.encode(seed, 3))) % 2 == 0 ? 1023 : uint256(keccak256(abi.encode(seed, 4))) % 1024;
        e.relMax = 1 + uint256(keccak256(abi.encode(seed, 5))) % 256;
        e.floorRel = 1 + uint256(keccak256(abi.encode(seed, 6))) % e.relMax;
        e.floorMin = uint256(keccak256(abi.encode(seed, 7))) % 426;
    }

    /// A direct transcription of kernel_model.route_tax, as a second implementation.
    function _model(
        KernelMath.RouteEnv memory e,
        uint256 word,
        uint256 inflow,
        uint256 reserve0,
        uint256 cum,
        uint256 paid,
        bool graduated
    ) internal pure returns (uint256 clamp, uint256 allow, uint256 buyShare, uint256 release) {
        uint256[4] memory t = [word & 511, (word >> 9) & 511, (word >> 18) & 511, (word >> 27) & 511];
        if (t[0] > 256 || t[1] > 256 || t[2] > 256 || t[3] > 256 || t[0] + t[1] + t[2] + t[3] != 256) {
            t = [uint256(0), 0, 0, 256];
            clamp |= 1;
        }
        if (!graduated) {
            if (t[2] > e.capT) {
                t[2] = e.capT;
                clamp |= 4;
            }
            allow = (inflow * t[2]) / 256;
            uint256 ceil = (word >> 81) & 1023;
            if (ceil != 1023 && allow > KernelMath.exp8(ceil)) allow = KernelMath.exp8(ceil);
            if (e.ceilMax != 1023 && allow > KernelMath.exp8(e.ceilMax)) {
                allow = KernelMath.exp8(e.ceilMax);
                clamp |= 8;
            }
            uint256 lim = (cum * e.allowCumBps) / 10_000;
            uint256 room = lim > paid ? lim - paid : 0;
            if (allow > room) {
                allow = room;
                clamp |= 16;
            }
        }
        buyShare = (inflow * t[0]) / 256;
        uint256 rel = (word >> 72) & 511;
        if (rel > e.relMax) {
            rel = e.relMax;
            clamp |= 32;
        }
        if (KernelMath.lg8(reserve0) >= e.floorMin && rel < e.floorRel) {
            rel = e.floorRel;
            clamp |= 64;
        }
        release = (reserve0 * rel) / 256;
    }

    /// For ANY 112-bit word a chip can output and any envelope the factory accepts: routing does not revert,
    /// conserves the inflow, and stays inside every limit of the envelope. Curve regime.
    function testFuzz_route_any_word_any_envelope(
        uint112 word,
        uint256 seed,
        uint128 inflow,
        uint128 reserve0,
        uint128 prior,
        uint128 paid
    ) public pure {
        KernelMath.RouteEnv memory e = _env(seed);
        uint256 cum = uint256(prior) + inflow;
        if (cum > type(uint128).max) cum = type(uint128).max;
        KernelMath.Routed memory r = KernelMath.route(e, word, inflow, reserve0, cum, paid, false);

        // second implementation
        (uint256 clamp, uint256 allow, uint256 buyShare, uint256 release) =
            _model(e, word, inflow, reserve0, cum, paid, false);
        assertEq(r.clamp, clamp, "clamp bits");
        assertEq(r.allow, allow, "allow");
        assertEq(r.buyShare, buyShare, "buyShare");
        assertEq(r.release, release, "release");

        // conservation
        assertEq(r.allow + r.buyShare + r.toReserve, inflow, "the inflow is fully accounted for");
        assertEq(r.buyDecided, r.buyShare + r.release);
        assertEq(r.reserveAfter, uint256(reserve0) - r.release + r.toReserve);
        assertEq(r.sBuy + r.sHold + r.sAllow + r.sRes, 256, "effective shares sum to 256");

        // the envelope holds whatever the chip said
        assertLe(r.sAllow, e.capT, "allowance share within capT");
        assertLe(r.allow * 256, uint256(inflow) * e.capT, "allowance within capT of the inflow");
        if (e.ceilMax != 1023) assertLe(r.allow, KernelMath.exp8(e.ceilMax), "allowance within the ceiling");
        uint256 lim = (cum * e.allowCumBps) / 10_000;
        if (paid <= lim) assertLe(r.allow + paid, lim, "lifetime allowance within allowCumBps of cumulative inflow");
        else assertEq(r.allow, 0, "over the lifetime cap already: nothing more");
        assertLe(r.rel, e.relMax, "release share within relMax");
        assertLe(r.release, (uint256(reserve0) * e.relMax) / 256);
        if (KernelMath.lg8(reserve0) >= e.floorMin) {
            assertGe(r.rel, e.floorRel, "the floor forces a minimum release");
            assertGe(r.release, (uint256(reserve0) * e.floorRel) / 256);
        }
        assertEq(r.clamp & (KernelMath.K1V | KernelMath.K2V), 0, "kernel v1 never sets the revenue clamps");
    }

    /// The same in the graduated regime: for ANY word, envelope and books there is no allowance at all, the
    /// allowance clamps are never evaluated, and everything else is what the curve regime computes.
    function testFuzz_route_graduated_pays_no_allowance(
        uint112 word,
        uint256 seed,
        uint128 inflow,
        uint128 reserve0,
        uint128 prior,
        uint128 paid
    ) public pure {
        KernelMath.RouteEnv memory e = _env(seed);
        uint256 cum = uint256(prior) + inflow;
        if (cum > type(uint128).max) cum = type(uint128).max;
        KernelMath.Routed memory r = KernelMath.route(e, word, inflow, reserve0, cum, paid, true);

        (uint256 clamp,, uint256 buyShare, uint256 release) = _model(e, word, inflow, reserve0, cum, paid, true);
        assertEq(r.clamp, clamp, "clamp bits");
        assertEq(r.allow, 0, "no allowance after graduation");
        assertEq(r.sAllow, 0, "the effective allowance share is zero");
        assertEq(r.clamp & (KernelMath.K2 | KernelMath.K2C | KernelMath.K2L), 0, "no allowance clamp is evaluated");
        assertEq(r.buyShare, buyShare, "buyShare");
        assertEq(r.release, release, "release");
        assertEq(r.buyShare + r.toReserve, inflow, "the whole inflow is bought or stays in the reserve");
        assertEq(r.buyDecided, r.buyShare + r.release);
        assertEq(r.reserveAfter, uint256(reserve0) - r.release + r.toReserve);
        assertEq(r.sBuy + r.sHold + r.sAllow + r.sRes, 256, "effective shares sum to 256");

        // the curve regime differs only by the allowance: same buy share, same release, and what it would
        // have paid as allowance stays in the reserve here
        KernelMath.Routed memory c = KernelMath.route(e, word, inflow, reserve0, cum, paid, false);
        assertEq(r.buyShare, c.buyShare);
        assertEq(r.sBuy, c.sBuy);
        assertEq(r.sHold, c.sHold);
        assertEq(r.sRes, c.sRes + c.sAllow, "the allowance share joined the reserve share");
        assertEq(r.rel, c.rel);
        assertEq(r.release, c.release);
        assertEq(r.toReserve, c.toReserve + c.allow, "the allowance of the curve regime stays in the reserve");
        assertEq(r.clamp, c.clamp & ~(KernelMath.K2 | KernelMath.K2C | KernelMath.K2L), "same K1T, K3 and K5");
    }

    /// A well-formed word inside the envelope is applied exactly and sets no clamp bit.
    function testFuzz_route_well_formed_word_is_not_clamped(
        uint256 seed,
        uint8 a,
        uint8 b,
        uint128 inflow,
        uint128 reserve0
    ) public pure {
        KernelMath.RouteEnv memory e = _env(seed);
        e.allowCumBps = 9999;
        e.ceilMax = 1023;
        uint256 ta = bound(a, 0, e.capT);
        uint256 tb = bound(b, 0, 256 - ta);
        uint256 rel = e.floorRel + (seed % (e.relMax - e.floorRel + 1));
        uint256 word = tb | (ta << 18) | ((256 - ta - tb) << 27) | (rel << 72) | (uint256(1023) << 81);
        // a paid-so-far of zero and a cumulative inflow equal to the inflow: room is 99.99% of it
        KernelMath.Routed memory r = KernelMath.route(e, word, inflow, reserve0, inflow, 0, false);
        uint256 expectAllow = (uint256(inflow) * ta) / 256;
        uint256 room = (uint256(inflow) * 9999) / 10_000;
        if (expectAllow <= room) {
            assertEq(r.clamp, 0, "the chip decided");
            assertEq(r.allow, expectAllow);
        } else {
            assertEq(r.clamp, KernelMath.K2L);
        }
        assertEq(r.buyShare, (uint256(inflow) * tb) / 256);
        assertEq(r.release, (uint256(reserve0) * rel) / 256);
    }

    function testFuzz_fallback_word_is_well_formed(uint256 seed, uint128 inflow, uint128 reserve0) public pure {
        KernelMath.RouteEnv memory e = _env(seed);
        uint256 fbAllow = seed % (e.capT + 1);
        uint256 w = KernelMath.fallbackWord(fbAllow, e.relMax);
        assertLt(w, uint256(1) << 112);
        KernelMath.Routed memory r = KernelMath.route(e, w, inflow, reserve0, inflow, 0, false);
        assertEq(r.clamp & (KernelMath.K1T | KernelMath.K2 | KernelMath.K3 | KernelMath.K5), 0);
        assertEq(r.sBuy, 256 - fbAllow);
        assertEq(r.sAllow, fbAllow);
        assertEq(r.rel, e.relMax);
        assertEq(r.toReserve + r.allow + r.buyShare, inflow);

        // after graduation the same word buys the same share and its allowance share stays in the reserve
        KernelMath.Routed memory g = KernelMath.route(e, w, inflow, reserve0, inflow, 0, true);
        assertEq(g.clamp, 0, "the fallback word is never clamped in the graduated regime");
        assertEq(g.sBuy, 256 - fbAllow);
        assertEq(g.sAllow, 0);
        assertEq(g.sRes, fbAllow);
        assertEq(g.allow, 0);
        assertEq(g.buyShare, r.buyShare);
        assertEq(g.rel, e.relMax);
    }

    function test_hostile_words() public pure {
        KernelMath.RouteEnv memory e =
            KernelMath.RouteEnv({capT: 48, allowCumBps: 1875, ceilMax: 440, relMax: 128, floorRel: 2, floorMin: 1});
        // all ones
        KernelMath.Routed memory r = KernelMath.route(e, (uint256(1) << 112) - 1, 1 ether, 1 ether, 1 ether, 0, false);
        assertEq(r.clamp, KernelMath.K1T | KernelMath.K3);
        assertEq(r.allow, 0);
        assertEq(r.buyShare, 0);
        assertEq(r.release, 0.5 ether);
        // all zeros: shares do not sum to 256
        r = KernelMath.route(e, 0, 1 ether, 1 ether, 1 ether, 0, false);
        assertEq(r.clamp, KernelMath.K1T | KernelMath.K5);
        assertEq(r.release, (uint256(1 ether) * 2) / 256);
        // everything to the allowance, release everything
        uint256 glutton = (uint256(256) << 18) | (uint256(256) << 72) | (uint256(1023) << 81);
        r = KernelMath.route(e, glutton, 1 ether, 1 ether, 1 ether, 0, false);
        assertEq(r.clamp, KernelMath.K2 | KernelMath.K2C | KernelMath.K3);
        assertEq(r.allow, KernelMath.exp8(440), "the envelope's ceiling, about 0.036 OKB");
        assertEq(r.release, 0.5 ether);
        assertEq(r.toReserve, 1 ether - r.allow);
        // the same glutton after graduation: nothing for the allowance, and only the release is clipped
        r = KernelMath.route(e, glutton, 1 ether, 1 ether, 1 ether, 0, true);
        assertEq(r.clamp, KernelMath.K3);
        assertEq(r.allow, 0);
        assertEq(r.sAllow, 0);
        assertEq(r.sRes, 256);
        assertEq(r.toReserve, 1 ether);
        assertEq(r.release, 0.5 ether);
    }
}
