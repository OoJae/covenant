"""Are the proofs able to fail? Ten deliberately broken chips, each of which must be caught.

    chips/.venv-fg/bin/python chips/props/mutants.py

Each mutant is the real RTL with one line changed. It is synthesised to its own netlist (in
chips/props/build/mutants, never in chips/out) and the named properties are run on those bytes against the
ORIGINAL constants and envelope. A property suite that proved these chips too would be worthless.
"""
from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CHIPS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(CHIPS, "tools"))

from tapc import prove as tp  # noqa: E402
from tapc import synth  # noqa: E402

VH = os.path.join(CHIPS, "rtl", "fg_params.vh")
CORE = os.path.join(CHIPS, "rtl", "fg_core.v")
PROPS = os.path.join(HERE, "fg_props.v")
WORK = os.path.join(HERE, "build", "mutants")


def rep(text: str, old: str, new: str) -> str:
    assert old in text, f"mutation site not found: {old}"
    return text.replace(old, new, 1)


# (what is broken, edit of (params, core), properties expected to fail)
MUTANTS = [
    ("allowance 49/256 at tier 0",
     lambda v, c: (rep(v, "FG_AL0 = 6'd48", "FG_AL0 = 6'd49"), c), ["p2_allow_cap", "p3_allow_bound"]),
    ("leak of 1 per epoch, under the floor",
     lambda v, c: (v, rep(c, "wire [8:0] leak = {4'd0, dt, 1'b0};", "wire [8:0] leak = {5'd0, dt};")),
     ["p2_floor", "p2_floor_always"]),
    ("tier follows TAXCUM down",
     lambda v, c: (v, rep(c, "wire [1:0] TIER1 = GRAD ? TIER : ((tm > TIER) ? tm : TIER);",
                          "wire [1:0] TIER1 = GRAD ? TIER : tm;")), ["p3_tier_up"]),
    ("DEFEND may open on the graduation step",
     lambda v, c: (v, rep(c, "& trig & can & ~ge;", "& trig & can;")), ["px_grad_step", "p6_no_release"]),
    ("PROG bit 0 leaks into the reserve test",
     lambda v, c: (v, rep(c, "wire can = (RES >= resmin);", "wire can = (RES >= resmin) | x[60];")), ["p5_ignored"]),
    ("buy share one short of 256",
     lambda v, c: (v, rep(c, "wire [8:0] buy   = 9'd256 -", "wire [8:0] buy   = 9'd255 -")), ["p1_t_sum"]),
    ("a tranche during the cooldown",
     lambda v, c: (v, rep(c, "wire [8:0] rel = is_def ?", "wire [8:0] rel = (is_def | rest_cont) ?")),
     ["p6_no_release", "p6_tranche_flag"]),
    ("the peak may sit below the average",
     lambda v, c: (v, rep(c, "wire [9:0]  PK1    = seed ? l : ((a1c > pkd) ? a1c : pkd);",
                          "wire [9:0]  PK1    = seed ? l : pkd;")), ["p4_step"]),
    ("allowance paid after graduation",
     lambda v, c: (v, rep(c, "wire [5:0] al   = GRAD ? 6'd0 : al_t;", "wire [5:0] al   = al_t;")), ["p3_no_allow_grad"]),
    ("ceiling one code above the envelope",
     lambda v, c: (rep(v, "FG_CEIL0 = 10'd440", "FG_CEIL0 = 10'd441"), c), ["p2_ceil"]),
]


def main() -> int:
    with open(VH, "r", encoding="utf-8") as f:
        vh = f.read()
    with open(CORE, "r", encoding="utf-8") as f:
        core = f.read()
    ok = True
    for i, (name, edit, sigs) in enumerate(MUTANTS, 1):
        d = os.path.join(WORK, f"m{i}")
        os.makedirs(d, exist_ok=True)
        v2, c2 = edit(vh, core)
        pv, pc = os.path.join(d, "fg_params.vh"), os.path.join(d, "fg_core.v")
        with open(pv, "w", encoding="utf-8") as f:
            f.write(v2)
        with open(pc, "w", encoding="utf-8") as f:
            f.write(c2)
        r = synth.synthesize([pv, pc], "fg", out_dir=d, top="fg_core", recipe="rich-area",
                             build_dir=os.path.join(d, "build"), n_in=96, n_out=112)
        res = tp.prove_properties([VH, PROPS], "fg_props", sigs, tap=r.packed.netlist, tap_module="fg_tap",
                                  work=os.path.join(d, "prove"), timeout=600, engine="yosys")
        verdict = ", ".join(f"{x.name.split('.')[-1]} {x.status}" for x in res)
        caught = all(x.status == tp.FAILED for x in res)
        ok &= caught
        print(f"{'CAUGHT' if caught else 'MISSED'}  M{i:<2} {name:<40} {verdict}")
    print("mutation check:", "every mutant is caught" if ok else "A MUTANT SURVIVED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
