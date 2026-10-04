"""Generate chips/rtl/fg_params.vh from chips/rtl/fg_params.json (the single source of truth).

    python chips/rtl/gen_params.py            # rewrite fg_params.vh
    python chips/rtl/gen_params.py --check    # exit 1 if fg_params.vh is stale

The .vh holds file-scope localparams and one function, so it is passed to Yosys as a source file in
front of fg_core.v (`read_verilog -sv fg_params.vh fg_core.v`); no `include is needed.
"""
from __future__ import annotations

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "fg_params.json")
DST = os.path.join(HERE, "fg_params.vh")

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


def main() -> int:
    with open(SRC, "r", encoding="utf-8") as f:
        doc = json.load(f)
    check_constraints(doc)
    text = render(doc)
    if "--check" in sys.argv:
        with open(DST, "r", encoding="utf-8") as f:
            if f.read() != text:
                print("fg_params.vh is stale: run python chips/rtl/gen_params.py")
                return 1
        print("fg_params.vh matches fg_params.json")
        return 0
    with open(DST, "w", encoding="utf-8") as f:
        f.write(text)
    print("wrote", DST)
    return 0


if __name__ == "__main__":
    sys.exit(main())
