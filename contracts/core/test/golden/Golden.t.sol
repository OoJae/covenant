// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {KernelMath} from "../../src/KernelMath.sol";
import {TradeMath} from "../../src/lib/TradeMath.sol";

/// @notice Every vector of chips/golden/vectors.json (format covenant-golden/2) against KernelMath and
///         TradeMath, bit for bit. The sections that existed in format 1 are unchanged; the `revision2`
///         object adds routing at the envelope's edges, routing in the graduated regime, buy sizing and
///         edge cases of the small codes.
///         The file is read with vm.readFile (fs_permissions in foundry.toml) and decoded with
///         vm.parseJsonTypeArray, which coerces the decimal strings used for integers above 2^53.
/// @dev    The type descriptions use a "J" prefix so that forge does not try to match them against the Solidity
///         structs below by name (the JSON key `bytes` is not a legal Solidity field name).
contract GoldenTest is Test {
    string internal json;

    function setUp() public {
        json = vm.readFile(string.concat(vm.projectRoot(), "/../../chips/golden/vectors.json"));
    }

    // ------------------------------------------------------------------ JSON shapes

    struct Field {
        string name;
        uint256 offset;
        uint256 width;
    }

    struct CodeX {
        uint256 code;
        uint256 x;
    }

    struct InFields {
        uint256 DT;
        uint256 ESC;
        uint256 GRAD;
        uint256 LOCK;
        uint256 PROG;
        uint256 RES;
        uint256 REV;
        uint256 REVCUM;
        uint256 TAX;
        uint256 TAXCUM;
        uint256 ZERO;
    }

    struct InVec {
        bytes b;
        InFields fields;
        uint256 word;
    }

    struct OutFields {
        uint256 AUX;
        uint256 CEIL;
        uint256 FLAGS;
        uint256 MODE;
        uint256 REL;
        uint256 TIER;
        uint256 T_ALLOW;
        uint256 T_BUY;
        uint256 T_HOLD;
        uint256 T_RES;
        uint256 V_ALLOW;
        uint256 V_BUY;
        uint256 V_HOLD;
        uint256 V_RES;
    }

    struct OutVec {
        bytes b;
        OutFields fields;
        uint256 word;
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

    struct RouteVec {
        uint256 allowPaidCum;
        bytes b;
        uint256 cumInflow;
        Env envelope;
        Expect expect;
        uint256 inflow;
        uint256 reserve0;
        uint256 word;
    }

    struct ProgVec {
        uint256 code;
        bool graduated;
        uint256 sellable;
        uint256 sold;
    }

    struct LockVec {
        uint256 code;
        uint256 locked;
        uint256 totalSupply;
    }

    struct DtVec {
        uint256 code;
        uint256 epochNow;
        uint256 lastEpoch;
    }

    struct StateVec {
        uint256 bits;
        bytes32 b32;
        uint256 nState;
    }

    struct FbVec {
        bytes b;
        Env envelope;
        uint256 fbAllow;
        uint256 word;
    }

    // ---- revision 2

    struct Route2Vec {
        uint256 allowPaidCum;
        bytes b;
        uint256 cumInflow;
        Env envelope;
        Expect expect;
        bool graduated;
        uint256 inflow;
        uint256 reserve0;
        uint256 word;
    }

    struct CapVec {
        uint256 cap;
        uint256 capT;
        uint256 quoteReserve;
        uint256 roundTripFeeBps;
        uint256 taxBuyBps;
        uint256 taxSellBps;
    }

    struct MaxBuyVec {
        uint256 buyFeeBps;
        uint256 max;
        uint256 sellable;
        uint256 sold;
        uint256 taxBuyBps;
        uint256 vQuote;
        uint256 vToken;
    }

    struct CurveOutVec {
        uint256 buyFeeBps;
        uint256 quoteIn;
        uint256 taxBuyBps;
        uint256 tokensOut;
        uint256 vQuote;
        uint256 vToken;
    }

    struct CurveBuyVec {
        uint256 amount;
        uint256 buyFeeBps;
        uint256 capT;
        uint256 decided;
        uint256 minTokensOut;
        uint256 sellFeeBps;
        uint256 sellable;
        bool shrunk;
        uint256 sold;
        uint256 taxBuyBps;
        uint256 taxSellBps;
        uint256 vQuote;
        uint256 vToken;
    }

    struct V2Vec {
        uint256 amountIn;
        uint256 netOut;
        uint256 reserveIn;
        uint256 reserveOut;
        uint256 taxBuyBps;
    }

    struct FbGradVec {
        Env envelope;
        Expect expect;
        uint256 fbAllow;
        uint256 word;
    }

    string internal constant T_ENV =
        "JEnv(uint256 allowCumBps,uint256 capT,uint256 capV,uint256 ceilMax,uint256 floorMin,uint256 floorRel,uint256 relMax)";
    string internal constant T_EXPECT =
        "JExpect(uint256 allow,uint256 buyDecided,uint256 buyShare,uint256 clamp,uint256 rel,uint256 release,uint256 reserveAfter,uint256[] shares,uint256 toReserve)";

    // ------------------------------------------------------------------ format and layout

    function test_golden_format() public view {
        assertEq(vm.parseJsonString(json, ".format"), "covenant-golden/2");
        assertEq(vm.parseJsonUint(json, ".layout.inBits"), KernelMath.IN_BITS);
        assertEq(vm.parseJsonUint(json, ".layout.outBits"), KernelMath.OUT_BITS);
    }

    function test_golden_clampBits() public view {
        assertEq(vm.parseJsonUint(json, ".layout.clampBits.K1T"), KernelMath.K1T);
        assertEq(vm.parseJsonUint(json, ".layout.clampBits.K1V"), KernelMath.K1V);
        assertEq(vm.parseJsonUint(json, ".layout.clampBits.K2"), KernelMath.K2);
        assertEq(vm.parseJsonUint(json, ".layout.clampBits.K2C"), KernelMath.K2C);
        assertEq(vm.parseJsonUint(json, ".layout.clampBits.K2L"), KernelMath.K2L);
        assertEq(vm.parseJsonUint(json, ".layout.clampBits.K3"), KernelMath.K3);
        assertEq(vm.parseJsonUint(json, ".layout.clampBits.K5"), KernelMath.K5);
        assertEq(vm.parseJsonUint(json, ".layout.clampBits.K2V"), KernelMath.K2V);
    }

    /// The layout tables in the JSON must describe exactly the fields KernelMath packs and unpacks.
    function test_golden_layout_tables() public view {
        string memory t = "JField(string name,uint256 offset,uint256 width)";
        Field[] memory fin = abi.decode(vm.parseJsonTypeArray(json, ".layout.input", t), (Field[]));
        Field[] memory fout = abi.decode(vm.parseJsonTypeArray(json, ".layout.output", t), (Field[]));
        assertEq(fin.length, 11);
        string[11] memory en = ["TAX", "TAXCUM", "REV", "REVCUM", "RES", "ESC", "PROG", "LOCK", "DT", "GRAD", "ZERO"];
        uint8[11] memory eo = [0, 10, 20, 30, 40, 50, 60, 68, 76, 80, 81];
        uint8[11] memory ew = [10, 10, 10, 10, 10, 10, 8, 8, 4, 1, 15];
        for (uint256 i = 0; i < 11; i++) {
            assertEq(fin[i].name, en[i]);
            assertEq(fin[i].offset, eo[i]);
            assertEq(fin[i].width, ew[i]);
        }
        assertEq(fout.length, 14);
        string[14] memory on = [
            "T_BUY",
            "T_HOLD",
            "T_ALLOW",
            "T_RES",
            "V_BUY",
            "V_HOLD",
            "V_ALLOW",
            "V_RES",
            "REL",
            "CEIL",
            "MODE",
            "TIER",
            "FLAGS",
            "AUX"
        ];
        uint8[14] memory oo = [0, 9, 18, 27, 36, 45, 54, 63, 72, 81, 91, 94, 96, 104];
        uint8[14] memory ow = [9, 9, 9, 9, 9, 9, 9, 9, 9, 10, 3, 2, 8, 8];
        for (uint256 i = 0; i < 14; i++) {
            assertEq(fout[i].name, on[i]);
            assertEq(fout[i].offset, oo[i]);
            assertEq(fout[i].width, ow[i]);
        }
    }

    // ------------------------------------------------------------------ lg8 / exp8

    function test_golden_lg8() public view {
        CodeX[] memory v = abi.decode(vm.parseJsonTypeArray(json, ".lg8", "JCodeX(uint256 code,uint256 x)"), (CodeX[]));
        assertEq(v.length, 3623, "lg8 vector count");
        for (uint256 i = 0; i < v.length; i++) {
            assertEq(KernelMath.lg8(v[i].x), v[i].code, vm.toString(v[i].x));
        }
    }

    function test_golden_exp8() public view {
        CodeX[] memory v = abi.decode(vm.parseJsonTypeArray(json, ".exp8", "JCodeX(uint256 code,uint256 x)"), (CodeX[]));
        assertEq(v.length, 1024, "every code");
        for (uint256 i = 0; i < v.length; i++) {
            assertEq(v[i].code, i);
            assertEq(KernelMath.exp8(i), v[i].x, vm.toString(i));
            if (i > 0) {
                // exp8 is a monotone floor inverse: lg8(exp8(c)) <= c, with equality from the first full octave
                // (below 8 wei not every code is produced by lg8).
                assertGe(v[i].x, v[i - 1].x, "monotone");
                assertLe(KernelMath.lg8(v[i].x), i, "lg8(exp8(c)) <= c");
                if (i >= 25) {
                    assertEq(KernelMath.lg8(v[i].x), i, "lg8(exp8(c)) == c");
                    assertLt(KernelMath.lg8(v[i].x - 1), i, "one wei below is a lower code");
                }
                if (i >= 26) assertEq(KernelMath.lg8(v[i].x - 1), i - 1, "one wei below is the previous code");
            }
        }
    }

    // ------------------------------------------------------------------ input word

    function test_golden_inputs() public view {
        string memory t = string.concat(
            "JIn(bytes bytes,JInF fields,uint256 word)",
            "JInF(uint256 DT,uint256 ESC,uint256 GRAD,uint256 LOCK,uint256 PROG,uint256 RES,uint256 REV,uint256 REVCUM,uint256 TAX,uint256 TAXCUM,uint256 ZERO)"
        );
        InVec[] memory v = abi.decode(vm.parseJsonTypeArray(json, ".inputs", t), (InVec[]));
        assertEq(v.length, 64);
        for (uint256 i = 0; i < v.length; i++) {
            InFields memory x = v[i].fields;
            assertEq(x.ZERO, 0);
            uint256 w = KernelMath.packInput(
                KernelMath.InputFields({
                    tax: x.TAX,
                    taxCum: x.TAXCUM,
                    rev: x.REV,
                    revCum: x.REVCUM,
                    res: x.RES,
                    esc: x.ESC,
                    prog: x.PROG,
                    lock: x.LOCK,
                    dt: x.DT,
                    grad: x.GRAD
                })
            );
            assertEq(w, v[i].word, "word");
            assertEq(w >> 81, 0, "bits 81-95 are zero");
            assertEq(v[i].b.length, 12);
            bytes12 b = KernelMath.inputBytes(w);
            assertEq(abi.encodePacked(b), v[i].b, "bytes");
            assertEq(KernelMath.inputWord(b), w, "round trip");
            KernelMath.InputFields memory g = KernelMath.unpackInput(w);
            assertEq(g.tax, x.TAX);
            assertEq(g.taxCum, x.TAXCUM);
            assertEq(g.rev, x.REV);
            assertEq(g.revCum, x.REVCUM);
            assertEq(g.res, x.RES);
            assertEq(g.esc, x.ESC);
            assertEq(g.prog, x.PROG);
            assertEq(g.lock, x.LOCK);
            assertEq(g.dt, x.DT);
            assertEq(g.grad, x.GRAD);
        }
    }

    // ------------------------------------------------------------------ output word

    function test_golden_outputs() public view {
        string memory t = string.concat(
            "JOut(bytes bytes,JOutF fields,uint256 word)",
            "JOutF(uint256 AUX,uint256 CEIL,uint256 FLAGS,uint256 MODE,uint256 REL,uint256 TIER,uint256 T_ALLOW,uint256 T_BUY,uint256 T_HOLD,uint256 T_RES,uint256 V_ALLOW,uint256 V_BUY,uint256 V_HOLD,uint256 V_RES)"
        );
        OutVec[] memory v = abi.decode(vm.parseJsonTypeArray(json, ".outputs", t), (OutVec[]));
        assertEq(v.length, 60);
        for (uint256 i = 0; i < v.length; i++) {
            assertEq(v[i].b.length, 14);
            uint256 w = KernelMath.outputWord(bytes14(v[i].b));
            assertEq(w, v[i].word, "word from bytes");
            assertEq(abi.encodePacked(KernelMath.outputBytes(w)), v[i].b, "bytes from word");
            KernelMath.OutputFields memory o = KernelMath.unpackOutput(w);
            OutFields memory x = v[i].fields;
            assertEq(o.tBuy, x.T_BUY, "T_BUY");
            assertEq(o.tHold, x.T_HOLD, "T_HOLD");
            assertEq(o.tAllow, x.T_ALLOW, "T_ALLOW");
            assertEq(o.tRes, x.T_RES, "T_RES");
            assertEq(o.vBuy, x.V_BUY, "V_BUY");
            assertEq(o.vHold, x.V_HOLD, "V_HOLD");
            assertEq(o.vAllow, x.V_ALLOW, "V_ALLOW");
            assertEq(o.vRes, x.V_RES, "V_RES");
            assertEq(o.rel, x.REL, "REL");
            assertEq(o.ceil, x.CEIL, "CEIL");
            assertEq(o.mode, x.MODE, "MODE");
            assertEq(o.tier, x.TIER, "TIER");
            assertEq(o.flags, x.FLAGS, "FLAGS");
            assertEq(o.aux, x.AUX, "AUX");
            assertEq(KernelMath.packOutput(o), w, "pack(unpack)");
        }
    }

    // ------------------------------------------------------------------ routing

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

    function test_golden_routing() public view {
        string memory t = string.concat(
            "JRoute(uint256 allowPaidCum,bytes bytes,uint256 cumInflow,JEnv envelope,JExpect expect,uint256 inflow,uint256 reserve0,uint256 word)",
            T_ENV,
            T_EXPECT
        );
        RouteVec[] memory v = abi.decode(vm.parseJsonTypeArray(json, ".routing", t), (RouteVec[]));
        assertEq(v.length, 400);
        uint256 clampSeen;
        for (uint256 i = 0; i < v.length; i++) {
            // these vectors predate the regime argument: they are all in the curve regime
            clampSeen |= _checkRoute(
                Route2Vec(
                    v[i].allowPaidCum,
                    v[i].b,
                    v[i].cumInflow,
                    v[i].envelope,
                    v[i].expect,
                    false,
                    v[i].inflow,
                    v[i].reserve0,
                    v[i].word
                ),
                i
            );
        }
        // the vectors exercise every v1 clamp, and never a v2 one
        uint256 all =
            uint256(KernelMath.K1T) | KernelMath.K2 | KernelMath.K2C | KernelMath.K2L | KernelMath.K3 | KernelMath.K5;
        assertEq(clampSeen, all, "every v1 clamp exercised");
    }

    function _checkRoute(Route2Vec memory v, uint256 i) internal pure returns (uint256) {
        uint256 w = KernelMath.outputWord(bytes14(v.b));
        assertEq(w, v.word, "word");
        KernelMath.Routed memory r =
            KernelMath.route(_routeEnv(v.envelope), w, v.inflow, v.reserve0, v.cumInflow, v.allowPaidCum, v.graduated);
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
        assertEq(e.shares.length, 4);
        assertEq(r.sBuy, e.shares[0], string.concat("sBuy ", tag));
        assertEq(r.sHold, e.shares[1], string.concat("sHold ", tag));
        assertEq(r.sAllow, e.shares[2], string.concat("sAllow ", tag));
        assertEq(r.sRes, e.shares[3], string.concat("sRes ", tag));
        // conservation, as asserted by the generator
        assertEq(r.allow + r.buyShare + r.toReserve, v.inflow, "conservation");
        assertLe(r.release, v.reserve0);
        return r.clamp;
    }

    // ------------------------------------------------------------------ prog, lock, dt, state, fallback

    function test_golden_prog() public view {
        ProgVec[] memory v = abi.decode(
            vm.parseJsonTypeArray(json, ".prog", "JProg(uint256 code,bool graduated,uint256 sellable,uint256 sold)"),
            (ProgVec[])
        );
        assertEq(v.length, 80);
        for (uint256 i = 0; i < v.length; i++) {
            assertEq(KernelMath.progCode(v[i].sold, v[i].sellable, v[i].graduated), v[i].code, vm.toString(i));
        }
    }

    function test_golden_lock() public view {
        LockVec[] memory v = abi.decode(
            vm.parseJsonTypeArray(json, ".lock", "JLock(uint256 code,uint256 locked,uint256 totalSupply)"), (LockVec[])
        );
        assertEq(v.length, 30);
        for (uint256 i = 0; i < v.length; i++) {
            assertEq(KernelMath.lockCode(v[i].locked, v[i].totalSupply), v[i].code, vm.toString(i));
        }
    }

    function test_golden_dt() public view {
        DtVec[] memory v = abi.decode(
            vm.parseJsonTypeArray(json, ".dt", "JDt(uint256 code,uint256 epochNow,uint256 lastEpoch)"), (DtVec[])
        );
        assertEq(v.length, 18);
        for (uint256 i = 0; i < v.length; i++) {
            assertEq(KernelMath.dtCode(v[i].epochNow, v[i].lastEpoch), v[i].code, vm.toString(i));
        }
    }

    function test_golden_state() public view {
        StateVec[] memory v = abi.decode(
            vm.parseJsonTypeArray(json, ".state", "JState(uint256 bits,bytes32 bytes32,uint256 nState)"), (StateVec[])
        );
        assertEq(v.length, 6);
        for (uint256 i = 0; i < v.length; i++) {
            // the TAP-20 byte string of the state: ceil(nState / 8) bytes, little-endian
            uint256 n = (v[i].nState + 7) / 8;
            bytes memory raw = new bytes(n);
            for (uint256 k = 0; k < n; k++) {
                raw[k] = bytes1(uint8(v[i].bits >> (8 * k)));
            }
            bytes32 stored = KernelMath.stateToBytes32(raw);
            assertEq(stored, v[i].b32, "bytes32(newState)");
            assertEq(bytes32(raw), v[i].b32, "matches the built-in conversion");
            assertEq(KernelMath.stateBits(stored), v[i].bits, "bits");
        }
    }

    function test_golden_fallback() public view {
        string memory t = string.concat("JFb(bytes bytes,JEnv envelope,uint256 fbAllow,uint256 word)", T_ENV);
        FbVec[] memory v = abi.decode(vm.parseJsonTypeArray(json, ".fallback", t), (FbVec[]));
        assertEq(v.length, 3);
        for (uint256 i = 0; i < v.length; i++) {
            uint256 w = KernelMath.fallbackWord(v[i].fbAllow, v[i].envelope.relMax);
            assertEq(w, v[i].word, "word");
            assertEq(abi.encodePacked(KernelMath.outputBytes(w)), v[i].b, "bytes");
            KernelMath.OutputFields memory o = KernelMath.unpackOutput(w);
            assertEq(o.tBuy + o.tAllow, 256);
            assertEq(o.tHold + o.tRes, 0);
            assertEq(o.rel, v[i].envelope.relMax);
            assertEq(o.ceil, 1023);
            // the fallback word is well formed for its own envelope: routing it sets no K1T, K2 or K3
            KernelMath.Routed memory r = KernelMath.route(_routeEnv(v[i].envelope), w, 1 ether, 0, 1 ether, 0, false);
            assertEq(r.clamp & (KernelMath.K1T | KernelMath.K2 | KernelMath.K3), 0);
        }
    }

    // ================================================================== revision 2

    string internal constant T_ROUTE2 =
        "JRoute2(uint256 allowPaidCum,bytes bytes,uint256 cumInflow,JEnv envelope,JExpect expect,bool graduated,uint256 inflow,uint256 reserve0,uint256 word)";

    function _route2(string memory key) internal view returns (Route2Vec[] memory) {
        return abi.decode(vm.parseJsonTypeArray(json, key, string.concat(T_ROUTE2, T_ENV, T_EXPECT)), (Route2Vec[]));
    }

    /// Directed cases at the edges the random routing vectors miss: the chip's own ceiling against ceilMax,
    /// K2C at the equality point, CEIL 0, K2L with a room of zero, K5 at exp8(floorMin), share groups one off
    /// 256, capT and relMax exactly and one above, zero and 2^128 - 1 amounts.
    function test_golden_rev2_routing_boundary() public view {
        Route2Vec[] memory v = _route2(".revision2.routingBoundary");
        assertEq(v.length, 67);
        uint256 clampSeen;
        for (uint256 i = 0; i < v.length; i++) {
            assertFalse(v[i].graduated, "the boundary vectors are in the curve regime");
            clampSeen |= _checkRoute(v[i], i);
        }
        uint256 all =
            uint256(KernelMath.K1T) | KernelMath.K2 | KernelMath.K2C | KernelMath.K2L | KernelMath.K3 | KernelMath.K5;
        assertEq(clampSeen, all, "every v1 clamp exercised at its edge");
    }

    /// Kernel v1 after graduation: no allowance, the T_ALLOW share joins the reserve share, none of K2, K2C,
    /// K2L is evaluated.
    function test_golden_rev2_routing_graduated() public view {
        Route2Vec[] memory v = _route2(".revision2.routingGraduated");
        assertEq(v.length, 120);
        uint256 clampSeen;
        uint256 askedForAllowance;
        for (uint256 i = 0; i < v.length; i++) {
            assertTrue(v[i].graduated);
            assertEq(v[i].expect.allow, 0, "no allowance after graduation");
            assertEq(v[i].expect.shares[2], 0, "the effective allowance share is zero");
            clampSeen |= _checkRoute(v[i], i);
            // how many of these words asked for an allowance that the curve regime would have paid
            KernelMath.Routed memory curve = KernelMath.route(
                _routeEnv(v[i].envelope),
                v[i].word,
                v[i].inflow,
                v[i].reserve0,
                v[i].cumInflow,
                v[i].allowPaidCum,
                false
            );
            if (curve.allow != 0) askedForAllowance++;
        }
        assertEq(clampSeen & (KernelMath.K2 | KernelMath.K2C | KernelMath.K2L), 0, "no allowance clamp is evaluated");
        assertEq(
            clampSeen, uint256(KernelMath.K1T) | KernelMath.K3 | KernelMath.K5, "the other clamps are all exercised"
        );
        assertGt(askedForAllowance, 10, "the vectors include words the curve regime pays an allowance for");
    }

    function test_golden_rev2_impactCap() public view {
        CapVec[] memory v = abi.decode(
            vm.parseJsonTypeArray(
                json,
                ".revision2.buy.impactCap",
                "JCap(uint256 cap,uint256 capT,uint256 quoteReserve,uint256 roundTripFeeBps,uint256 taxBuyBps,uint256 taxSellBps)"
            ),
            (CapVec[])
        );
        assertEq(v.length, 60);
        for (uint256 i = 0; i < v.length; i++) {
            assertEq(
                TradeMath.impactCap(
                    v[i].quoteReserve, v[i].roundTripFeeBps, v[i].taxBuyBps, v[i].taxSellBps, v[i].capT
                ),
                v[i].cap,
                vm.toString(i)
            );
        }
    }

    function test_golden_rev2_maxNonGraduatingBuy() public view {
        MaxBuyVec[] memory v = abi.decode(
            vm.parseJsonTypeArray(
                json,
                ".revision2.buy.maxNonGraduatingBuy",
                "JMaxBuy(uint256 buyFeeBps,uint256 max,uint256 sellable,uint256 sold,uint256 taxBuyBps,uint256 vQuote,uint256 vToken)"
            ),
            (MaxBuyVec[])
        );
        assertEq(v.length, 84);
        uint256 zeros;
        for (uint256 i = 0; i < v.length; i++) {
            TradeMath.Curve memory c;
            c.buyFeeBps = v[i].buyFeeBps;
            c.taxBuyBps = v[i].taxBuyBps;
            c.vQuote = v[i].vQuote;
            c.vToken = v[i].vToken;
            c.sold = v[i].sold;
            c.sellable = v[i].sellable;
            assertEq(TradeMath.maxNonGraduatingBuy(c), v[i].max, vm.toString(i));
            if (v[i].max == 0) zeros++;
        }
        assertGt(zeros, 3, "includes states with no room, and states the Manager cannot be in");
    }

    function test_golden_rev2_curveOut() public view {
        CurveOutVec[] memory v = abi.decode(
            vm.parseJsonTypeArray(
                json,
                ".revision2.buy.curveOut",
                "JCurveOut(uint256 buyFeeBps,uint256 quoteIn,uint256 taxBuyBps,uint256 tokensOut,uint256 vQuote,uint256 vToken)"
            ),
            (CurveOutVec[])
        );
        assertEq(v.length, 54);
        for (uint256 i = 0; i < v.length; i++) {
            TradeMath.Curve memory c;
            c.buyFeeBps = v[i].buyFeeBps;
            c.taxBuyBps = v[i].taxBuyBps;
            c.vQuote = v[i].vQuote;
            c.vToken = v[i].vToken;
            assertEq(TradeMath.curveOut(c, v[i].quoteIn), v[i].tokensOut, vm.toString(i));
        }
    }

    /// The kernel's own sizing of the curve buy: TradeMath.curveBuy is the function Kernel._curveLeg calls.
    function test_golden_rev2_curveBuy() public view {
        CurveBuyVec[] memory v = abi.decode(
            vm.parseJsonTypeArray(
                json,
                ".revision2.buy.curveBuy",
                "JCurveBuy(uint256 amount,uint256 buyFeeBps,uint256 capT,uint256 decided,uint256 minTokensOut,uint256 sellFeeBps,uint256 sellable,bool shrunk,uint256 sold,uint256 taxBuyBps,uint256 taxSellBps,uint256 vQuote,uint256 vToken)"
            ),
            (CurveBuyVec[])
        );
        assertEq(v.length, 80);
        uint256 shrunkSeen;
        uint256 skippedSeen;
        uint256 fullSeen;
        for (uint256 i = 0; i < v.length; i++) {
            TradeMath.Curve memory c;
            c.buyFeeBps = v[i].buyFeeBps;
            c.sellFeeBps = v[i].sellFeeBps;
            c.taxBuyBps = v[i].taxBuyBps;
            c.taxSellBps = v[i].taxSellBps;
            c.vQuote = v[i].vQuote;
            c.vToken = v[i].vToken;
            c.sold = v[i].sold;
            c.sellable = v[i].sellable;
            assertTrue(TradeMath.sane(c), "a state the kernel would accept");
            (uint256 amount, uint256 out, bool shrunk) = TradeMath.curveBuy(c, v[i].decided, v[i].capT);
            assertEq(amount, v[i].amount, string.concat("amount ", vm.toString(i)));
            assertEq(out, v[i].minTokensOut, string.concat("minTokensOut ", vm.toString(i)));
            assertEq(shrunk, v[i].shrunk, string.concat("shrunk ", vm.toString(i)));
            if (shrunk) shrunkSeen++;
            if (amount == 0) skippedSeen++;
            if (amount == v[i].decided && amount != 0) fullSeen++;
        }
        assertGt(shrunkSeen, 5, "buys shrunk by a cap");
        assertGt(skippedSeen, 5, "buys skipped");
        assertGt(fullSeen, 5, "buys executed in full");
    }

    function test_golden_rev2_v2NetOut() public view {
        V2Vec[] memory v = abi.decode(
            vm.parseJsonTypeArray(
                json,
                ".revision2.buy.v2NetOut",
                "JV2(uint256 amountIn,uint256 netOut,uint256 reserveIn,uint256 reserveOut,uint256 taxBuyBps)"
            ),
            (V2Vec[])
        );
        assertEq(v.length, 60);
        for (uint256 i = 0; i < v.length; i++) {
            assertEq(
                TradeMath.v2NetOut(v[i].amountIn, v[i].reserveIn, v[i].reserveOut, v[i].taxBuyBps),
                v[i].netOut,
                vm.toString(i)
            );
        }
    }

    function test_golden_rev2_edges_lg8_prog_lock() public view {
        CodeX[] memory lg = abi.decode(
            vm.parseJsonTypeArray(json, ".revision2.edges.lg8", "JCodeX(uint256 code,uint256 x)"), (CodeX[])
        );
        assertEq(lg.length, 6);
        for (uint256 i = 0; i < lg.length; i++) {
            assertEq(KernelMath.lg8(lg[i].x), lg[i].code, vm.toString(lg[i].x));
        }
        ProgVec[] memory pr = abi.decode(
            vm.parseJsonTypeArray(
                json, ".revision2.edges.prog", "JProg(uint256 code,bool graduated,uint256 sellable,uint256 sold)"
            ),
            (ProgVec[])
        );
        assertEq(pr.length, 6);
        for (uint256 i = 0; i < pr.length; i++) {
            assertEq(KernelMath.progCode(pr[i].sold, pr[i].sellable, pr[i].graduated), pr[i].code, vm.toString(i));
        }
        LockVec[] memory lk = abi.decode(
            vm.parseJsonTypeArray(
                json, ".revision2.edges.lock", "JLock(uint256 code,uint256 locked,uint256 totalSupply)"
            ),
            (LockVec[])
        );
        assertEq(lk.length, 6);
        for (uint256 i = 0; i < lk.length; i++) {
            assertEq(KernelMath.lockCode(lk[i].locked, lk[i].totalSupply), lk[i].code, vm.toString(i));
        }
    }

    /// The fallback word in the graduated regime: its allowance share is not paid either.
    function test_golden_rev2_fallback_graduated() public view {
        FbGradVec[] memory v = abi.decode(
            vm.parseJsonTypeArray(
                json,
                ".revision2.edges.fallbackGraduated",
                string.concat("JFbGrad(JEnv envelope,JExpect expect,uint256 fbAllow,uint256 word)", T_ENV, T_EXPECT)
            ),
            (FbGradVec[])
        );
        assertEq(v.length, 1);
        for (uint256 i = 0; i < v.length; i++) {
            uint256 w = KernelMath.fallbackWord(v[i].fbAllow, v[i].envelope.relMax);
            assertEq(w, v[i].word, "word");
            assertGt(v[i].fbAllow, 0, "the fallback word asks for an allowance");
            // the amounts the generator routed this word with (gen_vectors.py, edge_vectors)
            KernelMath.Routed memory r = KernelMath.route(_routeEnv(v[i].envelope), w, 1e24, 1e23, 1e25, 0, true);
            Expect memory e = v[i].expect;
            assertEq(r.clamp, e.clamp, "clamp");
            assertEq(r.allow, e.allow, "allow");
            assertEq(r.allow, 0, "no allowance after graduation, from the fallback word either");
            assertEq(r.buyShare, e.buyShare, "buyShare");
            assertEq(r.release, e.release, "release");
            assertEq(r.buyDecided, e.buyDecided, "buyDecided");
            assertEq(r.toReserve, e.toReserve, "toReserve");
            assertEq(r.reserveAfter, e.reserveAfter, "reserveAfter");
            assertEq(r.rel, e.rel, "rel");
            assertEq(r.sBuy, e.shares[0]);
            assertEq(r.sHold, e.shares[1]);
            assertEq(r.sAllow, e.shares[2]);
            assertEq(r.sRes, e.shares[3]);
            assertEq(r.sRes, v[i].fbAllow, "the allowance share joined the reserve share");
        }
    }
}
