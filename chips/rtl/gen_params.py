"""Generate chips/rtl/fg_params.vh from chips/rtl/fg_params.json (the single source of truth).

    python chips/rtl/gen_params.py            # rewrite fg_params.vh
    python chips/rtl/gen_params.py --check    # exit 1 if fg_params.vh is stale
    python chips/rtl/gen_params.py --show     # print the derived numbers

The .vh holds file-scope localparams and one function, so it is passed to Yosys as a source file in
front of fg_core.v (`read_verilog -sv fg_params.vh fg_core.v`); no `include is needed.

Before anything is written, three groups of relations are checked, and a failure stops the build:

  check_constraints   what the RTL and the proofs rely on (shift-add structure, share sums, ordering);
  check_envelope      the reference envelope against the kernel factory's limits (chips/INTERFACE.md section 7);
  check_reference     the token-regime thresholds, derived from the reference token's curve.
"""
from __future__ import annotations

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "fg_params.json")
DST = os.path.join(HERE, "fg_params.vh")
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "golden"))

import kernel_model as km  # noqa: E402

# name -> bit width of the localparam
CHIP_WIDTHS = {
    "FLOOR_Q": 10, "FLOOR_T": 10, "RESMIN_Q": 10, "RESMIN_T": 10,
    "M1": 10, "M2": 10, "M3": 10,
    "AL0": 6, "AL1": 6, "AL2": 6, "AL3": 6,
    "CEIL0": 10, "CEIL_STEP": 10,
    "RC": 8, "RB_MIN": 8, "RB_GAIN": 3, "RB_SPAN": 5,
    "SURGE_TH": 6, "XSURGE_TH": 6, "DIP_TH": 6, "DD_TH": 10, "SUR_ON": 2,
    "SLEW_Q": 4, "PK_DIV": 3, "DRYN": 4, "WARMN": 2, "TRN": 3, "CDN": 3,
    "TR_MIN": 8, "TR_MAX": 8, "REL_CAP": 9, "LEAK": 2,
}
ENV_WIDTHS = {
    "capT": 9, "capV": 9, "allowCumBps": 14, "ceilMax": 10, "relMax": 9, "floorRel": 9, "floorMin": 10,
    "fallbackEpochs": 16, "fbAllow": 9, "epochLen": 32,
}
THIRTY_DAYS = 30 * 86400


def render(doc: dict) -> str:
    c, e = doc["chip"], doc["envelope"]
    L = ["// GENERATED from fg_params.json by gen_params.py. Do not edit by hand.",
         "// Flow Governor constants (FG_*) and the reference-token envelope (ENV_*).",
         "// Every value is frozen into an immutable chip or kernel clone: change the JSON, regenerate,",
         "// re-run every proof.", ""]
    for k, w in CHIP_WIDTHS.items():
        v = c[k]
        assert 0 <= v < (1 << w), (k, v, w)
        L.append(f"localparam [{w - 1}:0] FG_{k} = {w}'d{v};")
    L.append("")
    for k, w in ENV_WIDTHS.items():
        v = int(e[k])
        assert 0 <= v < (1 << w), (k, v, w)
        L.append(f"localparam [{w - 1}:0] ENV_{k.upper()} = {w}'d{v};")
    L += ["", "// round(8 * log2(dt)): the code offset that turns a settle covering dt epochs into a per-epoch rate.",
          "// Written as a chain of conditionals, not a case statement: Yosys would turn a case into a ROM cell,",
          "// which its SAT pass and its SMT-LIB writer do not model as a constant table.",
          "function automatic [4:0] fg_log8dt(input [3:0] dt);", "  fg_log8dt ="]
    tab = c["LOG8DT"]
    assert len(tab) == 16 and tab[0] == 0 and tab[1] == 0 and all(0 <= v < 32 for v in tab)
    for i in range(2, 16):
        L.append(f"    (dt == 4'd{i}) ? 5'd{tab[i]} :")
    L += ["    5'd0;", "endfunction", ""]
    return "\n".join(L)


def check_constraints(doc: dict) -> None:
    """Relations the RTL and the proofs rely on. Fail loudly if a constant change breaks one."""
    c, e = doc["chip"], doc["envelope"]
    assert c["FLOOR_Q"] <= c["FLOOR_T"] and c["FLOOR_T"] + max(c["LOG8DT"]) < 1024
    assert c["M1"] < c["M2"] < c["M3"]
    assert c["AL0"] >= c["AL1"] >= c["AL2"] >= c["AL3"] >= 0
    assert c["AL0"] == e["capT"], "the envelope cap equals the largest allowance share"
    assert e["allowCumBps"] * 256 >= e["capT"] * 10000, "the lifetime cap can never bind (NOTES.md)"
    assert e["fbAllow"] <= c["AL3"], "the fallback must not loosen the ratchet"
    assert c["CEIL0"] == e["ceilMax"] and c["CEIL0"] - 3 * c["CEIL_STEP"] >= 0
    assert c["RB_MIN"] + c["RB_GAIN"] * c["RB_SPAN"] + (c["AL0"] >> 1) <= 256
    assert c["RC"] + c["AL0"] <= 256
    assert c["TR_MIN"] <= c["TR_MAX"] and 2 * c["TR_MAX"] == c["REL_CAP"] == e["relMax"]
    assert c["LEAK"] >= e["floorRel"] and c["LEAK"] * 15 <= c["TR_MIN"], "a tranche is never below the leak"
    assert c["SLEW_Q"] == 12 and c["PK_DIV"] == 4 and c["TRN"] == 4 and c["SUR_ON"] == 2, "shift-add structure in the RTL"
    assert c["DRYN"] == 8 and c["WARMN"] == 3 and c["CDN"] == 6
    assert c["DIP_TH"] == 8 and c["SURGE_TH"] == 8 and c["XSURGE_TH"] == 32 and c["DD_TH"] == 16
    assert c["RB_GAIN"] == 4 and c["RB_SPAN"] == 16 and c["RB_MIN"] == 128
    assert c["TR_MIN"] == 32 and c["TR_MAX"] == 64 and c["LEAK"] == 2
    # round(8 * log2(dt)), checked in integers: 2^(2k-1) <= dt^16 < 2^(2k+1)  <=>  k - 1/2 <= 8 log2(dt) < k + 1/2
    assert c["LOG8DT"][0] == 0, "DT = 0 is read as 1"
    for dt in range(1, 16):
        k = c["LOG8DT"][dt]
        assert (1 << (2 * k)) <= 2 * dt ** 16 < (1 << (2 * k + 2)), f"LOG8DT[{dt}] is not round(8 log2 {dt})"


def check_envelope(doc: dict) -> None:
    """The reference envelope against the factory checks of chips/INTERFACE.md section 7 (revision 2).

    A kernel with an envelope outside these limits cannot be created, so a reference envelope that broke one
    would make every proof against it a proof about a kernel that cannot exist. The three address fields
    (launcher, allowancePayee, sink) are chosen at deployment and are not part of this file; `sink` only
    matters when buyEnabled is false.
    """
    e = doc["envelope"]
    assert 300 <= e["epochLen"] <= 86400, "epochLen: 300 .. 86400"
    assert 0 <= e["capT"] <= 128, "capT <= 128"
    assert 0 <= e["capV"] <= 255, "capV <= 255"
    assert 0 <= e["allowCumBps"] <= 5000, "allowCumBps <= 5000"
    assert 0 <= e["ceilMax"] <= km.LG8_MAX, "ceilMax <= 1023"
    assert 1 <= e["relMax"] <= 256, "relMax: 1 .. 256"
    assert 1 <= e["floorRel"] <= e["relMax"], "floorRel: 1 .. relMax"
    assert e["epochLen"] * 178 <= THIRTY_DAYS * e["floorRel"], "the reserve must halve within 30 days at the floor"
    assert 1 <= e["floorMin"] <= 425, "floorMin: 1 .. 425"
    assert e["fallbackEpochs"] >= 2, "fallbackEpochs >= 2"
    assert e["epochLen"] * e["fallbackEpochs"] <= THIRTY_DAYS, "the fallback word applies within 30 days"
    assert 0 <= e["fbAllow"] <= e["capT"], "fbAllow <= capT"
    assert e["buyEnabled"] is True, "the reference kernel buys (a kernel with buyEnabled false needs a sink)"
    # what the chip is compiled against (INTERFACE 8.2): these make the kernel_model.Envelope of the proofs
    km.fallback_word(km.Envelope(capT=e["capT"], capV=e["capV"], allowCumBps=e["allowCumBps"], ceilMax=e["ceilMax"],
                                 relMax=e["relMax"], floorRel=e["floorRel"], floorMin=e["floorMin"]), e["fbAllow"])


def reference(doc: dict) -> dict:
    """Numbers derived from the reference token's curve (IGNIX CurveMath.params), in integers."""
    r = doc["reference"]
    supply, C, D, G = (int(r[k]) for k in ("totalSupply", "curveSupply", "pairSupply", "graduationQuote"))
    assert supply == C + D and C > D > 0 and G > 0
    T = C * C // (C - D)                       # virtual token reserve of a fresh curve
    E = G * (T - C) // C                       # virtual quote reserve of a fresh curve
    fee = r["curveBuyFeeBps"] + r["taxBuyBps"]
    raised = km.ceil_div(E * C, T - C)         # net quote the curve holds when it is sold out
    # token base units per base unit of quote when the pair opens: `pairSupply` tokens against `raised` quote.
    # The shift is that ratio in lg8 codes, rounded to the nearest code:
    #   k - 1/2 <= 8 log2(D / raised) < k + 1/2   <=>   2^(2k-1) * raised^16 <= D^16 < 2^(2k+1) * raised^16
    shift = next(k for k in range(1, 1024)
                 if (raised ** 16 << (2 * k - 1)) <= D ** 16 < (raised ** 16 << (2 * k + 1)))
    return {"T": T, "E": E, "C": C, "D": D, "G": G, "raised": raised, "shift": shift,
            "costToSellOut": km.ceil_div(raised * km.BPS, km.BPS - fee),
            "maxNonGraduatingBuy": km.max_non_graduating_buy(E, T, 0, C, r["curveBuyFeeBps"], r["taxBuyBps"]),
            "impactCapFresh": km.impact_cap(E, r["curveBuyFeeBps"] + r["curveSellFeeBps"], r["taxBuyBps"],
                                            r["taxSellBps"], doc["envelope"]["capT"]),
            "impactCapPair": km.impact_cap(raised, km.V2_ROUND_TRIP_FEE_BPS, r["taxBuyBps"], r["taxSellBps"],
                                           doc["envelope"]["capT"])}


def check_reference(doc: dict) -> dict:
    """FLOOR_T and RESMIN_T are FLOOR_Q and RESMIN_Q moved by the token-per-quote ratio at graduation."""
    c, r = doc["chip"], doc["reference"]
    d = reference(doc)
    assert 0 < r["taxBuyBps"] <= 1000 and 0 <= r["taxSellBps"] <= 1000, "IGNIX: at most 10% per side"
    assert r["curveBuyFeeBps"] == 100 and r["curveSellFeeBps"] == 100, "the platform's curve fee is forced on chain"
    # the curve raises exactly the graduation amount, and the pair opens with it (contracts/probes, Q6)
    assert d["raised"] == d["G"], "a sold-out curve holds exactly the graduation amount"
    assert 0 < d["costToSellOut"] - d["maxNonGraduatingBuy"] <= 2, "the largest non-graduating buy is just under the cost"
    assert c["TOKEN_SHIFT"] == d["shift"], f"TOKEN_SHIFT must be {d['shift']} for this curve"
    assert c["FLOOR_T"] == c["FLOOR_Q"] + c["TOKEN_SHIFT"], "FLOOR_T = FLOOR_Q + TOKEN_SHIFT"
    assert c["RESMIN_T"] == c["RESMIN_Q"] + c["TOKEN_SHIFT"], "RESMIN_T = RESMIN_Q + TOKEN_SHIFT"
    # the same two numbers the other way round: convert the amount behind each quote threshold at the opening
    # price of the pair and take its code. (A code is 9% wide, so this can differ from the shift by one code
    # for other thresholds; for these two it must not.)
    for q, t in (("FLOOR_Q", "FLOOR_T"), ("RESMIN_Q", "RESMIN_T")):
        assert km.lg8(km.exp8(c[q]) * d["D"] // d["raised"]) == c[t], f"{t} is not the code of {q} in tokens"
    # the milestones and the ceiling are quote-regime only: the tier is frozen and the allowance is 0 once
    # graduated (properties P3), so they need no token twin
    return d


def main() -> int:
    with open(SRC, "r", encoding="utf-8") as f:
        doc = json.load(f)
    check_constraints(doc)
    check_envelope(doc)
    d = check_reference(doc)
    if "--show" in sys.argv:
        c = doc["chip"]
        print(f"fresh curve: vQuote {d['E']} wei, vToken {d['T']} base units; sold out after {d['raised']} wei net "
              f"({d['costToSellOut']} wei gross)")
        print(f"pair at graduation: {d['D']} token base units against {d['raised']} wei "
              f"= {d['D'] // d['raised']} base units per wei = {d['shift']} lg8 codes")
        for k in ("FLOOR_Q", "RESMIN_Q", "FLOOR_T", "RESMIN_T"):
            print(f"  {k:<9} code {c[k]}  = {km.exp8(c[k])} base units")
        print(f"impact cap of one kernel buy: {d['impactCapFresh']} wei on a fresh curve, "
              f"{d['impactCapPair']} wei on the pair at graduation")
        return 0
    text = render(doc)
    if "--check" in sys.argv:
        with open(DST, "r", encoding="utf-8") as f:
            if f.read() != text:
                print("fg_params.vh is stale: run python chips/rtl/gen_params.py")
                return 1
        print("fg_params.vh matches fg_params.json; envelope within the factory limits; "
              f"token shift {d['shift']} codes")
        return 0
    with open(DST, "w", encoding="utf-8") as f:
        f.write(text)
    print("wrote", DST)
    return 0


if __name__ == "__main__":
    sys.exit(main())
