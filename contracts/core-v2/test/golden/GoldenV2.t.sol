// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {KernelMath} from "core/KernelMath.sol";
import {KernelMathV2} from "../../src/KernelMathV2.sol";

/// @notice Every code and routing vector of chips/golden/vectors_v2.json (kernel_model_v2.py) against
///         KernelMathV2, bit for bit; and every routing vector of kernel v1's chips/golden/vectors.json against
///         KernelMathV2 with a shift of zero (kernel v1's arithmetic is the s = 0 case of kernel v2's).
///         The settle sequences of vectors_v2.json are replayed by DiffSettlesV2.t.sol.
contract GoldenV2Test is Test {
    string internal json;

    function setUp() public {
        json = vm.readFile(string.concat(vm.projectRoot(), "/../../chips/golden/vectors_v2.json"));
    }

    struct CodeV {
        uint256 code;
        uint256 s;
        uint256 x;
    }

    struct Env {
        uint256 allowCumBps;
        uint256 capT;
        uint256 capV;
        uint256 ceilMax;
        uint256 floorMin;
        uint256 floorRel;
        uint256 relMax;
    }

    struct Expect {
        uint256 allow;
        uint256 buyDecided;
        uint256 buyShare;
        uint256 clamp;
        uint256 rel;
        uint256 release;
        uint256 reserveAfter;
        uint256[] shares;
        uint256 toReserve;
    }

    struct RouteV {
        uint256 allowPaidCum;
        uint256 cumInflow;
        Env envelope;
        Expect expect;
        bool graduated;
        uint256 inflow;
        uint256 reserve0;
        uint256 shift;
        uint256 word;
    }

    struct RouteV1 {
        uint256 allowPaidCum;
        uint256 cumInflow;
        Env envelope;
        Expect expect;
        bool graduated;
        uint256 inflow;
        uint256 reserve0;
        uint256 word;
    }

    string internal constant T_ENV =
        "JEnv(uint256 allowCumBps,uint256 capT,uint256 capV,uint256 ceilMax,uint256 floorMin,uint256 floorRel,uint256 relMax)";
    string internal constant T_EXPECT =
        "JExpect(uint256 allow,uint256 buyDecided,uint256 buyShare,uint256 clamp,uint256 rel,uint256 release,uint256 reserveAfter,uint256[] shares,uint256 toReserve)";
    string internal constant T_ROUTE =
        "JRouteV(uint256 allowPaidCum,uint256 cumInflow,JEnv envelope,JExpect expect,bool graduated,uint256 inflow,uint256 reserve0,uint256 shift,uint256 word)";

    function test_golden_v2_format_and_shift() public view {
        assertEq(vm.parseJsonString(json, ".format"), "covenant-golden-v2/1");
        assertEq(vm.parseJsonUint(json, ".shift.quoteShift"), 33);
        assertEq(vm.parseJsonUint(json, ".shift.codeShift"), 264);
        assertEq(vm.parseJsonUint(json, ".shift.quoteDecimals"), 6);
        assertEq(vm.parseJsonUint(json, ".shift.maxShift"), 40);
    }

    function test_golden_v2_lg8s() public view {
        CodeV[] memory v =
            abi.decode(vm.parseJsonTypeArray(json, ".lg8s", "JCode(uint256 code,uint256 s,uint256 x)"), (CodeV[]));
        assertGt(v.length, 1000);
        for (uint256 i = 0; i < v.length; i++) {
            assertEq(KernelMathV2.lg8s(v[i].x, v[i].s), v[i].code, vm.toString(i));
            // the identity the shift rests on
            if (v[i].x != 0) {
                uint256 c = KernelMath.lg8(v[i].x) + 8 * v[i].s;
                assertEq(v[i].code, c > 1023 ? 1023 : c);
            }
        }
    }

    function test_golden_v2_exp8s() public view {
        CodeV[] memory v =
            abi.decode(vm.parseJsonTypeArray(json, ".exp8s", "JCode(uint256 code,uint256 s,uint256 x)"), (CodeV[]));
        assertEq(v.length, 3 * 1024);
        for (uint256 i = 0; i < v.length; i++) {
            assertEq(KernelMathV2.exp8s(v[i].code, v[i].s), v[i].x, vm.toString(i));
            if (v[i].code >= 1 && v[i].code + 8 * v[i].s <= 1023) {
                assertEq(KernelMath.exp8(v[i].code + 8 * v[i].s) >> v[i].s, KernelMath.exp8(v[i].code));
            }
        }
    }

    function _routeEnv(Env memory e) internal pure returns (KernelMath.RouteEnv memory) {
        return KernelMath.RouteEnv({
            capT: e.capT,
            allowCumBps: e.allowCumBps,
            ceilMax: e.ceilMax,
            relMax: e.relMax,
            floorRel: e.floorRel,
            floorMin: e.floorMin
        });
    }

    function _check(RouteV memory v, uint256 i) internal pure returns (uint256) {
        KernelMath.Routed memory r = KernelMathV2.route(
            _routeEnv(v.envelope), v.word, v.inflow, v.reserve0, v.cumInflow, v.allowPaidCum, v.graduated, v.shift
        );
        string memory tag = vm.toString(i);
        Expect memory e = v.expect;
        assertEq(r.clamp, e.clamp, string.concat("clamp ", tag));
        assertEq(r.allow, e.allow, string.concat("allow ", tag));
        assertEq(r.buyShare, e.buyShare, string.concat("buyShare ", tag));
        assertEq(r.release, e.release, string.concat("release ", tag));
        assertEq(r.buyDecided, e.buyDecided, string.concat("buyDecided ", tag));
        assertEq(r.toReserve, e.toReserve, string.concat("toReserve ", tag));
        assertEq(r.reserveAfter, e.reserveAfter, string.concat("reserveAfter ", tag));
        assertEq(r.rel, e.rel, string.concat("rel ", tag));
        assertEq(r.sBuy, e.shares[0]);
        assertEq(r.sHold, e.shares[1]);
        assertEq(r.sAllow, e.shares[2]);
        assertEq(r.sRes, e.shares[3]);
        assertEq(r.allow + r.buyShare + r.toReserve, v.inflow, "conservation");
        if (v.graduated) assertEq(r.allow, 0, "no allowance after graduation");
        return r.clamp;
    }

    function test_golden_v2_routing() public view {
        RouteV[] memory v = abi.decode(
            vm.parseJsonTypeArray(json, ".routing", string.concat(T_ROUTE, T_ENV, T_EXPECT)), (RouteV[])
        );
        assertEq(v.length, 3000);
        uint256 seen;
        uint256 shifted;
        for (uint256 i = 0; i < v.length; i++) {
            seen |= _check(v[i], i);
            if (v[i].shift == 33) shifted++;
        }
        uint256 all =
            uint256(KernelMath.K1T) | KernelMath.K2 | KernelMath.K2C | KernelMath.K2L | KernelMath.K3 | KernelMath.K5;
        assertEq(seen, all, "every clamp exercised");
        assertGt(shifted, 1500, "most vectors use the USD0 shift");
    }

    function test_golden_v2_routing_boundary() public view {
        RouteV[] memory v = abi.decode(
            vm.parseJsonTypeArray(json, ".routingBoundary", string.concat(T_ROUTE, T_ENV, T_EXPECT)), (RouteV[])
        );
        assertEq(v.length, 153);
        for (uint256 i = 0; i < v.length; i++) {
            _check(v[i], i);
        }
    }

    /// Kernel v1's own vectors, through kernel v2's routing with a shift of zero.
    function test_golden_v1_vectors_through_v2_routing_with_shift_zero() public view {
        string memory v1 = vm.readFile(string.concat(vm.projectRoot(), "/../../chips/golden/vectors.json"));
        string memory t = string.concat(
            "JRouteV1(uint256 allowPaidCum,uint256 cumInflow,JEnv envelope,JExpect expect,bool graduated,uint256 inflow,uint256 reserve0,uint256 word)",
            T_ENV,
            T_EXPECT
        );
        string[2] memory keys = [".revision2.routingBoundary", ".revision2.routingGraduated"];
        uint256 n;
        for (uint256 k = 0; k < 2; k++) {
            RouteV1[] memory v = abi.decode(vm.parseJsonTypeArray(v1, keys[k], t), (RouteV1[]));
            for (uint256 i = 0; i < v.length; i++) {
                _check(
                    RouteV(
                        v[i].allowPaidCum,
                        v[i].cumInflow,
                        v[i].envelope,
                        v[i].expect,
                        v[i].graduated,
                        v[i].inflow,
                        v[i].reserve0,
                        0,
                        v[i].word
                    ),
                    i
                );
                n++;
            }
        }
        assertEq(n, 187, "67 boundary and 120 graduated vectors of revision 2");
    }
}
