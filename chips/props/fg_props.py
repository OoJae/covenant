"""Flow Governor properties as z3 predicates over the TAP-20 bytes.

Second, independent path for chips/props/fg_props.v: tapc builds one z3 Bool term per NAND record straight
from the netlist bytes (no Yosys, no unpacked Verilog, no MiniSat), and each `prop_*` function below returns
a z3 Bool term that must be valid for every (s, x).

    tapc prove z3 --tap chips/out/fg.tap --props chips/props/fg_props.py

Field offsets come from chips/golden/kernel_model.py and chips/model/flow_governor.py; constants from
chips/rtl/fg_params.json. Nothing here is derived from the RTL.
"""
from __future__ import annotations

import os
import sys

import z3

HERE = os.path.dirname(os.path.abspath(__file__))
CHIPS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(CHIPS, "model"))
sys.path.insert(0, os.path.join(CHIPS, "tools"))

import flow_governor as fg  # noqa: E402
from flow_governor import km  # noqa: E402
from tapc import prove as tp  # noqa: E402

P, ENV = fg.P, fg.ENV
IN = {n: (o, w) for n, o, w in km.INPUT_FIELDS}
OUT = {n: (o, w) for n, o, w in km.OUTPUT_FIELDS}
ST = {n: (o, w) for n, o, w, _ in fg.STATE_FIELDS}
IDLE, CRUISE, BANK, DEFEND, REST = range(5)


def bv(bits):
    return tp.Z3Circuit.bv(bits)


def f_x(c, name):
    o, w = IN[name]
    return bv(c.x[o:o + w])


def f_y(c, name, y=None):
    o, w = OUT[name]
    return bv((y if y is not None else c.y)[o:o + w])


def f_s(c, name, s=None):
    o, w = ST[name]
    return bv((s if s is not None else c.s)[o:o + w])


def f_ns(c, name):
    o, w = ST[name]
    return bv(c.ns[o:o + w])


def zx(v, width):
    return z3.ZeroExt(width - v.size(), v)


def _dt(c):
    d = f_x(c, "DT")
    return z3.If(d == 0, z3.BitVecVal(1, 4), d)


def _same(a_bits, b_bits):
    return z3.And(*[p == q for p, q in zip(a_bits, b_bits)])


# ----------------------------------------------------------------------------- P1
def prop_p1_t_group_sums_to_256(c):
    tot = sum(zx(f_y(c, n), 12) for n in ("T_BUY", "T_HOLD", "T_ALLOW", "T_RES"))
    each = z3.And(*[z3.ULE(f_y(c, n), 256) for n in ("T_BUY", "T_HOLD", "T_ALLOW", "T_RES")])
    return z3.And(tot == 256, each)


def prop_p1_v_group_sums_to_256(c):
    tot = sum(zx(f_y(c, n), 12) for n in ("V_BUY", "V_HOLD", "V_ALLOW", "V_RES"))
    each = z3.And(*[z3.ULE(f_y(c, n), 256) for n in ("V_BUY", "V_HOLD", "V_ALLOW", "V_RES")])
    return z3.And(tot == 256, each)


def prop_p1_no_holder_share(c):
    return f_y(c, "T_HOLD") == 0


# ----------------------------------------------------------------------------- P2
def prop_p2_k2_allowance_cap(c):
    return z3.ULE(f_y(c, "T_ALLOW"), ENV["capT"])


def prop_p2_k2v_revenue_allowance_cap(c):
    return z3.ULE(f_y(c, "V_ALLOW"), ENV["capV"])


def prop_p2_k3_release_cap(c):
    return z3.ULE(f_y(c, "REL"), ENV["relMax"])


def prop_p2_k5_reserve_floor(c):
    return z3.Or(z3.ULT(f_x(c, "RES"), ENV["floorMin"]), z3.UGE(f_y(c, "REL"), ENV["floorRel"]))


def prop_p2_k5_floor_for_every_reserve(c):
    return z3.UGE(f_y(c, "REL"), ENV["floorRel"])


def prop_p2_k2c_ceiling(c):
    if ENV["ceilMax"] == km.LG8_MAX:
        return z3.BoolVal(True)
    ceil = f_y(c, "CEIL")
    return z3.And(z3.ULE(ceil, ENV["ceilMax"]), ceil != km.LG8_MAX)


# ----------------------------------------------------------------------------- P3
def _al_of(tier):
    return z3.If(tier == 0, z3.BitVecVal(P["AL0"], 9),
                 z3.If(tier == 1, z3.BitVecVal(P["AL1"], 9),
                       z3.If(tier == 2, z3.BitVecVal(P["AL2"], 9), z3.BitVecVal(P["AL3"], 9))))


def prop_p3_tier_never_decreases(c):
    return z3.And(z3.UGE(f_ns(c, "TIER"), f_s(c, "TIER")), f_y(c, "TIER") == f_ns(c, "TIER"))


def prop_p3_allowance_bounded_by_tier(c):
    assert P["AL0"] >= P["AL1"] >= P["AL2"] >= P["AL3"]
    tier = f_y(c, "TIER")
    ceil_of = z3.BitVecVal(P["CEIL0"], 10) - zx(tier, 10) * P["CEIL_STEP"]
    return z3.And(z3.ULE(f_y(c, "T_ALLOW"), _al_of(tier)), f_y(c, "CEIL") == ceil_of)


def prop_p3_higher_tier_never_loosens(c):
    """Two copies that differ only in the stored tier."""
    ta = z3.BitVec("ta", 2)
    o, w = ST["TIER"]
    s2 = list(c.s)
    for i in range(w):
        s2[o + i] = z3.Extract(i, i, ta) == 1
    c2 = tp.Z3Circuit(c.netlist, s=s2, x=c.x)
    return z3.Implies(z3.UGE(ta, f_s(c, "TIER")),
                      z3.And(z3.ULE(f_y(c, "T_ALLOW", c2.y), f_y(c, "T_ALLOW")),
                             z3.ULE(f_y(c, "CEIL", c2.y), f_y(c, "CEIL"))))


def prop_p3_graduated_tier_frozen_and_no_allowance(c):
    return z3.Implies(f_x(c, "GRAD") == 1,
                      z3.And(f_ns(c, "TIER") == f_s(c, "TIER"), f_y(c, "T_ALLOW") == 0))


# ----------------------------------------------------------------------------- P4
def _inv(c, get):
    A, PK, MODE, WARM, LIVE = get("A"), get("PK"), get("MODE"), get("WARM"), get("LIVE")
    SUR, TR, CD = get("SUR"), get("TR"), get("CD")
    span = 1023 - P["FLOOR_Q"]
    return z3.And(
        z3.ULE(MODE, 4),
        z3.ULE(LIVE, P["DRYN"]),
        z3.ULE(CD, 5),
        z3.Or(MODE == DEFEND, TR == 0),
        z3.Or(MODE == REST, CD == 0),
        z3.Or(MODE != BANK, SUR != 0),
        z3.Or(WARM == 0, z3.UGE(zx(LIVE, 5), zx(WARM, 5) + 5)),
        z3.UGE(PK, z3.Extract(11, 2, A)),
        z3.ULE(PK, span),
        z3.ULE(A, 4 * span),
    )


def prop_p4_invariant_is_inductive(c):
    return z3.Implies(_inv(c, lambda n: f_s(c, n)), _inv(c, lambda n: f_ns(c, n)))


def prop_p4_invariant_holds_at_reset(c):
    zero = [z3.BoolVal(False)] * len(c.s)
    return _inv(c, lambda n: z3.simplify(f_s(c, n, zero)))


def prop_p4_mode_output_is_mode_latch(c):
    return f_y(c, "MODE") == f_ns(c, "MODE")


# ----------------------------------------------------------------------------- P5
USED = ("TAX", "TAXCUM", "RES", "DT", "GRAD")


def prop_p5_unused_inputs_ignored(c):
    xa = [z3.Bool(f"xa{i}") for i in range(len(c.x))]
    xb = list(xa)
    for n in USED:
        o, w = IN[n]
        xb[o:o + w] = c.x[o:o + w]
    c2 = tp.Z3Circuit(c.netlist, s=c.s, x=xb)
    return z3.And(_same(c.ns, c2.ns), _same(c.y, c2.y))


# ----------------------------------------------------------------------------- P6
def prop_p6_cooldown(c):
    dt = _dt(c)
    cd, mode = f_s(c, "CD"), f_s(c, "MODE")
    ge = z3.And(f_x(c, "GRAD") == 1, f_s(c, "GSEEN") == 0)
    cooling = z3.And(mode == REST, cd != 0)
    inside = z3.And(mode == REST, z3.UGE(zx(cd, 4), dt))
    leak = zx(dt, 9) * P["LEAK"]
    rel = f_y(c, "REL")
    return z3.And(
        z3.Implies(z3.Or(inside, z3.And(cooling, ge)), rel == leak),          # only the floor leak
        z3.Implies(cooling, z3.ULT(f_ns(c, "CD"), cd)),                       # strictly decreasing
        z3.Implies(z3.And(inside, z3.Not(ge)),
                   z3.And(f_ns(c, "MODE") == REST, zx(f_ns(c, "CD"), 4) == zx(cd, 4) - dt)),
    )


def prop_p6_release_above_leak_is_a_flagged_tranche(c):
    rel = f_y(c, "REL")
    leak = zx(_dt(c), 9) * P["LEAK"]
    release = z3.Extract(3, 3, f_y(c, "FLAGS")) == 1
    return z3.And(
        z3.Or(rel == leak, z3.And(release, z3.UGE(rel, P["TR_MIN"]))),
        z3.Implies(release, z3.And(f_y(c, "T_BUY") == 256, f_y(c, "T_ALLOW") == 0, f_y(c, "T_RES") == 0)),
    )


# ----------------------------------------------------------------------------- extras
def prop_px_dt_zero_reads_as_one(c):
    o, w = IN["DT"]
    x1 = list(c.x)
    x1[o:o + w] = [z3.BoolVal(True), z3.BoolVal(False), z3.BoolVal(False), z3.BoolVal(False)]
    c2 = tp.Z3Circuit(c.netlist, s=c.s, x=x1)
    return z3.Implies(f_x(c, "DT") == 0, z3.And(_same(c.ns, c2.ns), _same(c.y, c2.y)))


def prop_px_graduation_seen_once(c):
    return f_ns(c, "GSEEN") == (f_s(c, "GSEEN") | f_x(c, "GRAD"))


def prop_px_graduation_step_only_reseeds(c):
    ge = z3.And(f_x(c, "GRAD") == 1, f_s(c, "GSEEN") == 0)
    flags = f_y(c, "FLAGS")
    leak = zx(_dt(c), 9) * P["LEAK"]
    return z3.And(
        (z3.Extract(4, 4, flags) == 1) == ge,
        z3.Implies(ge, z3.And(f_y(c, "REL") == leak, z3.Extract(3, 3, flags) == 0, z3.ULE(f_ns(c, "MODE"), CRUISE),
                              f_ns(c, "TIER") == f_s(c, "TIER"), f_ns(c, "TR") == 0, f_ns(c, "CD") == 0)))
