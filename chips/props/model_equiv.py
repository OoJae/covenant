"""Model == netlist bytes, for every one of the 2^160 (state, input) pairs.

    chips/.venv-fg/bin/python chips/props/model_equiv.py [--tap chips/out/fg.tap] [--n 200000] [--jobs 8]

chips/rtl/test_fg.py compares the behavioural model (chips/model/flow_governor.py) with the bytes on sampled
vectors. This script replaces the sample by a proof, along two independent routes.

  Route A, the source itself. chips/props/symexec.py executes the SOURCE of `flow_governor.step` (and of the
  functions it calls: `_satsub`, `kernel_model.pack_output`, `pack_fields`) on z3 terms instead of numbers. The
  result is not a second description of the model, it is the model as a formula over (s, x). z3 then proves
  two things for every (s, x): that formula equals the netlist, field by field; and every condition under
  which Python would have raised instead of returning (the model's own assert, the range checks of
  `pack_fields`, an index outside a table) is impossible.

  Route B, a hand-written twin. `twin(S, X)` below is `step` written once more as z3 bit-vector terms, line for
  line, 16 bits wide, by hand. z3 proves the twin equal to the netlist too. It shares nothing with route A
  except the constants, so a mistake in the symbolic executor and a mistake in the twin would have to coincide.

  The netlist side of both is built straight from the bytes by tapc (one Bool per NAND record; no Yosys, no
  RTL). There is one query per field of the state and of the output word, each in its own process: "some bit
  of this field differs" must be unsatisfiable.

  Tests of the two formulas. Both are turned back into ordinary Python functions by a small compiler
  (`compile_terms`) and compared with the real `step` on --n uniform random, --n boundary-biased and --n
  random-walk vectors plus every scenario settle: all 64 next-state bits and all 112 output bits. A sample is
  also evaluated by z3 itself (substitute + simplify), so the compiler is not trusted either. For route A this
  is a test of the symbolic executor; the proof does not depend on it.

  The proofs can fail. For every field, a formula that differs from the right one in a single bit at a single
  one of the 2^160 points (a "needle") must be refuted, and the counterexample must be exactly that point. And
  the model run with one wrong constant (eight of them, one at a time, on both routes) must be refuted with a
  counterexample on which the bytes and the wrong model really differ.

Together with the EQ proof of prove.py (RTL == bytes) this makes model, RTL and bytes one function.
Results go to chips/out/fg.model.json.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import sys
import time
from concurrent.futures import ProcessPoolExecutor

import z3

HERE = os.path.dirname(os.path.abspath(__file__))
CHIPS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(CHIPS, "model"))
sys.path.insert(0, os.path.join(CHIPS, "tools"))
sys.path.insert(0, os.path.join(CHIPS, "rtl"))

import flow_governor as fg  # noqa: E402
from flow_governor import km  # noqa: E402
from tapc import netlist as tnl  # noqa: E402
from tapc import prove as tp  # noqa: E402
import symexec  # noqa: E402

IDLE, CRUISE, BANK, DEFEND, REST = range(5)
W = 16                               # width of every signed intermediate; nothing in the law exceeds 13 bits


# ------------------------------------------------------------------------------------------------ the twin
def twin(S, X, p: dict = fg.P, needle=None):
    """z3 terms for one beat. S: 64-bit state, X: 96-bit input word. Returns (ns, y, fields, obligations):
    the 64-bit next state, the 112-bit output word, every named field, and the conditions under which the
    Python model would raise (its assert, a value that does not fit its field).

    needle = (field, s, x) builds a deliberately wrong twin for the self-test: bit 0 of that field is flipped
    at the single point (s, x) and nowhere else."""
    If, And, Or, Not, Ext = z3.If, z3.And, z3.Or, z3.Not, z3.Extract
    UGT, UGE, ULT, ULE = z3.UGT, z3.UGE, z3.ULT, z3.ULE

    def bv(v: int, w: int = W):
        return z3.BitVecVal(v, w)

    def zx(v, w: int = W):
        return z3.ZeroExt(w - v.size(), v) if v.size() < w else v

    def b2i(c, w: int = W):
        return If(c, bv(1, w), bv(0, w))

    def satsub(a, b):                        # a - b if a > b else 0, on non-negative values
        a, b = zx(a), zx(b)
        return If(UGT(a, b), a - b, bv(0))

    def umin(a, b):
        return If(ULE(a, b), a, b)

    def smin(a, b):                          # signed (the Python model's min on possibly negative values)
        return If(a <= b, a, b)

    def smax(a, b):
        return If(a >= b, a, b)

    def table(index, values):                # values[index] for an index proven to be in range
        t = bv(values[-1])
        for i in range(len(values) - 2, -1, -1):
            t = If(index == i, bv(values[i]), t)
        return t

    # ---- state (every field zero-extended to W bits: the model works on plain integers)
    f = {n: zx(Ext(o + w - 1, o, S)) for n, o, w, _ in fg.STATE_FIELDS}
    A, PK, PKDIV, MODE, TIER, GSEEN = f["A"], f["PK"], f["PKDIV"], f["MODE"], f["TIER"], f["GSEEN"]
    WARM, LIVE, SUR, TR, CD, NBANK, NDEF, CLOCK = (f[k] for k in ("WARM", "LIVE", "SUR", "TR", "CD", "NBANK", "NDEF", "CLOCK"))

    # ---- inputs actually used
    x = {n: zx(Ext(o + w - 1, o, X)) for n, o, w in km.INPUT_FIELDS if n in ("TAX", "TAXCUM", "RES", "DT", "GRAD")}
    TAX, TAXCUM, RES, DT = x["TAX"], x["TAXCUM"], x["RES"], x["DT"]
    GRAD = x["GRAD"] == 1

    dt = If(DT != 0, DT, bv(1))

    # ---- graduation
    ge = And(GRAD, GSEEN == 0)                                   # GRAD & (GSEEN ^ 1)
    A, PK, PKDIV, MODE, WARM, LIVE, SUR, TR, CD = (If(ge, bv(0), v) for v in (A, PK, PKDIV, MODE, WARM, LIVE, SUR, TR, CD))

    floor = If(GRAD, bv(p["FLOOR_T"]), bv(p["FLOOR_Q"]))
    resmin = If(GRAD, bv(p["RESMIN_T"]), bv(p["RESMIN_Q"]))

    # ---- reading
    K = floor + table(dt, p["LOG8DT"])
    l = satsub(TAX, K)
    live = l != 0
    cold = LIVE == 0
    seed = And(cold, live)
    warm = Or(seed, WARM != 0)

    d = 4 * l - A                                                # signed
    g = l - PK                                                   # signed
    surge = And(Not(cold), WARM == 0, g >= p["SURGE_TH"])        # `>=` on z3 bit-vectors is the signed comparison
    xsurge = And(surge, g >= p["XSURGE_TH"])
    dip = And(Not(cold), d <= -4 * p["DIP_TH"])

    # ---- average
    sh_dt = If(dt == 1, bv(2), If(ULE(dt, bv(3)), bv(1), bv(0)))
    sh = If(And(warm, d >= 0), bv(0), sh_dt)
    st = d >> sh                                                 # `>>` on z3 bit-vectors is the arithmetic shift
    lim = p["SLEW_Q"] * dt
    stp = If(st >= -lim, st, -lim)
    A1 = If(seed, 4 * l, A + stp)
    obligations = [("the model's assert 0 <= A1 <= 4095", And(A1 >= 0, A1 <= 4095))]

    # ---- decaying peak, drawdown depth
    pdsum = PKDIV + dt
    dec = z3.LShR(pdsum, 2)
    PKDIV1 = pdsum & 3
    pkd = satsub(PK, dec)
    a1c = z3.LShR(A1, 2)                                         # A1 is non-negative (the obligation above)
    PK1 = If(seed, l, smax(a1c, pkd))
    dd = PK1 - a1c

    # ---- timers and meters
    LIVE1 = If(live, bv(p["DRYN"]), satsub(LIVE, dt))
    drought = LIVE1 == 0
    WARM1 = If(seed, bv(p["WARMN"]), satsub(WARM, dt))
    SUR1 = If(surge, smin(bv(3), SUR + dt + b2i(xsurge)), satsub(SUR, dt))

    # ---- allowance ratchet
    tm = If(UGE(TAXCUM, bv(p["M3"])), bv(3), If(UGE(TAXCUM, bv(p["M2"])), bv(2), If(UGE(TAXCUM, bv(p["M1"])), bv(1), bv(0))))
    TIER1 = If(GRAD, TIER, smax(TIER, tm))

    can = UGE(RES, resmin)

    # ---- mode
    in_def, in_rest, in_bank = MODE == DEFEND, MODE == REST, MODE == BANK
    trn = smin(dt, TR)
    over = dt - trn
    def_go = And(in_def, TR != 0, can, Not(surge))
    rest_start = And(in_def, Not(def_go))
    rest_cont = And(in_rest, CD >= dt)
    bank_stay = And(in_bank, SUR1 != 0)
    base = Not(Or(in_def, rest_cont, bank_stay))
    slack = If(in_rest, dt - CD, bv(1))                          # negative when unused, as in the model
    bank_enter = And(base, surge, SUR1 >= p["SUR_ON"])
    fade = And(in_bank, dip)
    trig = Or(dd >= p["DD_TH"], drought, fade)
    def_enter = And(base, Not(bank_enter), trig, can, Not(ge))
    nen = smin(slack, bv(p["TRN"] - 1))
    is_def = Or(def_go, def_enter)
    ntr = If(def_enter, nen, If(def_go, trn, bv(0)))

    go_on = And(def_go, over == 0)
    MODE1 = If(def_enter, bv(DEFEND), If(go_on, bv(DEFEND), If(def_go, bv(REST), If(rest_start, bv(REST),
            If(rest_cont, bv(REST), If(Or(bank_stay, bank_enter), bv(BANK), If(drought, bv(IDLE), bv(CRUISE))))))))
    TR1 = If(def_enter, p["TRN"] - nen, If(go_on, TR - trn, bv(0)))
    CD1 = If(def_enter, bv(0), If(go_on, bv(0), If(def_go, satsub(bv(p["CDN"]), over),
          If(rest_start, satsub(bv(p["CDN"]), dt), If(rest_cont, CD - dt, bv(0))))))
    is_bank = MODE1 == BANK

    # ---- shares of fresh tax
    al_t = table(TIER1, [p["AL0"], p["AL1"], p["AL2"], p["AL3"]])
    al = If(GRAD, bv(0), al_t)
    gg = smin(smax(g - p["SURGE_TH"], bv(0)), bv(p["RB_SPAN"]))
    allow = If(is_def, bv(0), If(is_bank, z3.LShR(al, 1), al))
    res = If(is_def, bv(0), If(is_bank, p["RB_MIN"] + p["RB_GAIN"] * gg, bv(p["RC"])))
    buy = 256 - allow - res

    # ---- reserve release
    r = smin(smax(2 * dd, bv(p["TR_MIN"])), bv(p["TR_MAX"]))
    rel = If(is_def, If(ntr >= 2, 2 * r, r), p["LEAK"] * dt)

    ceil = p["CEIL0"] - p["CEIL_STEP"] * TIER1

    # ---- telemetry
    NBANK1 = smin(bv(31), NBANK + b2i(bank_enter))
    NDEF1 = smin(bv(63), NDEF + b2i(def_enter))
    CLOCK1 = (CLOCK + dt) & 1023
    GSEEN1 = GSEEN | b2i(GRAD)
    flags = (b2i(surge) | b2i(dip) << 1 | b2i(Not(live)) << 2 | b2i(is_def) << 3 | b2i(ge) << 4
             | b2i(TIER1 != TIER) << 5 | b2i(MODE1 == REST) << 6 | b2i(warm) << 7)
    aux = smin(dd, bv(255))

    state = {"A": A1, "PK": PK1, "PKDIV": PKDIV1, "MODE": MODE1, "TIER": TIER1, "GSEEN": GSEEN1, "WARM": WARM1,
             "LIVE": LIVE1, "SUR": SUR1, "TR": TR1, "CD": CD1, "NBANK": NBANK1, "NDEF": NDEF1, "CLOCK": CLOCK1}
    out = {"T_BUY": buy, "T_HOLD": bv(0), "T_ALLOW": allow, "T_RES": res,
           "V_BUY": bv(0), "V_HOLD": bv(0), "V_ALLOW": bv(0), "V_RES": bv(256),
           "REL": rel, "CEIL": ceil, "MODE": MODE1, "TIER": TIER1, "FLAGS": flags, "AUX": aux}

    def pack(values: dict, layout, total: int, what: str):
        """Concatenate fields into one word. Each value must fit its field, as pack_state / pack_output check."""
        parts, pos = [], 0
        for name, off, width in layout:
            assert off == pos, "fields must be contiguous"
            v = values[name]
            obligations.append((f"{what}.{name} fits {width} bits", And(v >= 0, v < (1 << width))))
            parts.append(Ext(width - 1, 0, v))
            pos += width
        assert pos == total
        return z3.Concat(*reversed(parts)) if len(parts) > 1 else parts[0]

    if needle is not None:
        which, s_at, x_at = needle
        group = state if which.startswith("ns.") else out
        group[which[which.index(".") + 1:]] ^= b2i(And(S == s_at, X == x_at))
    ns = pack(state, [(n, o, w) for n, o, w, _ in fg.STATE_FIELDS], fg.N_STATE, "ns")
    y = pack(out, km.OUTPUT_FIELDS, km.OUT_BITS, "y")
    fields = {f"ns.{n}": (o, w) for n, o, w, _ in fg.STATE_FIELDS}
    fields.update({f"y.{n}": (o, w) for n, o, w in km.OUTPUT_FIELDS})
    return ns, y, fields, obligations


# ------------------------------------------------------------------------------------------------ terms -> Python
def compile_terms(terms, S, X):
    """A Python function (s, x) -> tuple of integers / booleans that evaluates the given z3 terms.

    Every distinct subterm becomes one assignment. Only the operations the twin uses are known; anything else
    raises, so a term this compiler does not understand cannot be mis-evaluated silently."""
    K = z3
    lines, names = [], {S.get_id(): "s", X.get_id(): "x"}

    def mask(e):
        return (1 << e.size()) - 1

    def signed(code: str, w: int) -> str:
        return f"(({code}) - {1 << w} if ({code}) >> {w - 1} else ({code}))"

    def visit(e) -> str:
        key = e.get_id()
        if key in names:
            return names[key]
        k, ch = e.decl().kind(), e.children()
        if z3.is_bv_value(e):
            code = str(e.as_long())
        elif k == K.Z3_OP_TRUE:
            code = "True"
        elif k == K.Z3_OP_FALSE:
            code = "False"
        else:
            a = [visit(c) for c in ch]
            w = e.size() if z3.is_bv(e) else 0
            cw = ch[0].size() if ch and z3.is_bv(ch[0]) else 0
            if k == K.Z3_OP_EXTRACT:
                hi, lo = e.params()
                code = f"({a[0]} >> {lo}) & {(1 << (hi - lo + 1)) - 1}"
            elif k == K.Z3_OP_ZERO_EXT:
                code = a[0]
            elif k == K.Z3_OP_CONCAT:
                code, pos = "", 0
                for c, n in zip(reversed(ch), reversed(a)):
                    code += (" | " if code else "") + f"({n} << {pos})"
                    pos += c.size()
            elif k == K.Z3_OP_BADD:
                code = f"({' + '.join(a)}) & {mask(e)}"
            elif k == K.Z3_OP_BSUB:
                code = f"({' - '.join(a)}) & {mask(e)}"
            elif k == K.Z3_OP_BMUL:
                code = f"({' * '.join(a)}) & {mask(e)}"
            elif k == K.Z3_OP_BNEG:
                code = f"(-{a[0]}) & {mask(e)}"
            elif k == K.Z3_OP_BAND:
                code = " & ".join(a)
            elif k == K.Z3_OP_BOR:
                code = " | ".join(a)
            elif k == K.Z3_OP_BXOR:
                code = " ^ ".join(a)
            elif k == K.Z3_OP_BSHL:
                code = f"({a[0]} << {a[1]}) & {mask(e)}"
            elif k == K.Z3_OP_BLSHR:
                code = f"{a[0]} >> {a[1]}"
            elif k == K.Z3_OP_BASHR:
                code = f"({signed(a[0], w)} >> {a[1]}) & {mask(e)}"
            elif k == K.Z3_OP_ITE:
                code = f"{a[1]} if {a[0]} else {a[2]}"
            elif k == K.Z3_OP_EQ:
                code = f"{a[0]} == {a[1]}"
            elif k == K.Z3_OP_DISTINCT and len(a) == 2:
                code = f"{a[0]} != {a[1]}"
            elif k in (K.Z3_OP_ULEQ, K.Z3_OP_ULT, K.Z3_OP_UGEQ, K.Z3_OP_UGT):
                op = {K.Z3_OP_ULEQ: "<=", K.Z3_OP_ULT: "<", K.Z3_OP_UGEQ: ">=", K.Z3_OP_UGT: ">"}[k]
                code = f"{a[0]} {op} {a[1]}"
            elif k in (K.Z3_OP_SLEQ, K.Z3_OP_SLT, K.Z3_OP_SGEQ, K.Z3_OP_SGT):
                op = {K.Z3_OP_SLEQ: "<=", K.Z3_OP_SLT: "<", K.Z3_OP_SGEQ: ">=", K.Z3_OP_SGT: ">"}[k]
                code = f"{signed(a[0], cw)} {op} {signed(a[1], cw)}"
            elif k == K.Z3_OP_AND:
                code = " and ".join(f"({v})" for v in a)
            elif k == K.Z3_OP_OR:
                code = " or ".join(f"({v})" for v in a)
            elif k == K.Z3_OP_NOT:
                code = f"not {a[0]}"
            elif k == K.Z3_OP_IMPLIES:
                code = f"(not {a[0]}) or ({a[1]})"
            else:
                raise NotImplementedError(f"z3 operation {e.decl().name()} is not known to this compiler")
        name = f"v{len(names)}"
        names[key] = name
        lines.append(f"    {name} = {code}")
        return name

    sys.setrecursionlimit(max(sys.getrecursionlimit(), 20000))
    outs = [visit(t) for t in terms]
    src = "def f(s, x):\n" + "\n".join(lines) + f"\n    return ({', '.join(outs)},)\n"
    scope: dict = {}
    exec(compile(src, "<twin>", "exec"), scope)
    return scope["f"], len(lines)


# ------------------------------------------------------------------------------------------------ route A
def source_terms(p: dict = fg.P):
    """The model's own source, executed on z3 terms: (S, X, ns, y, obligations)."""
    m = symexec.Machine()
    ns, y = m.call(fg.step, [m.input("s", 64), m.input("x", 96), p])
    m.oblige("step returns a state word of 64 bits", z3.And(ns.term >= 0, ns.term < (1 << 64)))
    m.oblige("step returns an output word of 112 bits", z3.And(y.term >= 0, y.term < (1 << 112)))
    obligations = [(f"source {i + 1}: {what}", cond) for i, (what, cond) in enumerate(m.obligations)]
    return m.inputs["s"], m.inputs["x"], z3.Extract(63, 0, ns.term), z3.Extract(111, 0, y.term), obligations


def formulas(route: str, S, X, p: dict = fg.P, needle=None):
    """(ns, y, fields, obligations) of one route over the shared inputs S and X."""
    if route == "twin":
        return twin(S, X, p, needle)
    s2, x2, ns, y, obligations = source_terms(p)
    assert s2.eq(S) and x2.eq(X), "both routes must range over the same (s, x)"
    fields = {f"ns.{n}": (o, w) for n, o, w, _ in fg.STATE_FIELDS}
    fields.update({f"y.{n}": (o, w) for n, o, w in km.OUTPUT_FIELDS})
    if needle is not None:
        which, s_at, x_at = needle
        off, _ = fields[which]
        hit = z3.If(z3.And(S == s_at, X == x_at), z3.BitVecVal(1, 1), z3.BitVecVal(0, 1))
        if which.startswith("ns."):
            ns = ns ^ z3.ZeroExt(63, hit) << off
        else:
            y = y ^ z3.ZeroExt(111, hit) << off
    return ns, y, fields, obligations


# ------------------------------------------------------------------------------------------------ step 1: test
def test_formulas(n: int, seed: int) -> dict:
    import test_fg

    S, X = z3.BitVec("s", 64), z3.BitVec("x", 96)
    rng = random.Random(seed)
    sets = [("uniform random (s, x)", test_fg.uniform(rng, n)), ("boundary-biased (s, x)", test_fg.boundary(rng, n)),
            ("random walks from reset", test_fg.walks(rng, n)), ("scenario traces", test_fg.scenario_vectors())]
    out = {"seed": seed, "vectors": sum(len(v) for _, v in sets), "mismatches": 0, "z3Mismatches": 0}
    for route, label in (("source", "the model's source, executed symbolically"), ("twin", "the hand-written twin")):
        ns, y, _, obligations = formulas(route, S, X)
        f, n_terms = compile_terms([ns, y] + [c for _, c in obligations], S, X)
        rows = []
        for name, vectors in sets:
            t0 = time.perf_counter()
            bad = 0
            first = None
            for s, x in vectors:
                got = f(s, x)
                if (got[0], got[1]) != fg.step(s, x) or not all(got[2:]):
                    bad += 1
                    first = first or (hex(s), hex(x))
            rows.append({"set": name, "vectors": len(vectors), "mismatches": bad,
                         "seconds": round(time.perf_counter() - t0, 1), **({"first": first} if first else {})})
            print(f"  {route:<6} == step  {name:<26} {len(vectors):>8} vectors  {bad} mismatches  ({rows[-1]['seconds']} s)")
        # the compiler itself: a sample evaluated by z3 (substitute + simplify) must give what the compiled code gives
        t0 = time.perf_counter()
        sample = [v for _, vs in sets for v in vs[:150]]
        zbad = 0
        for s, x in sample:
            sub = [(S, z3.BitVecVal(s, 64)), (X, z3.BitVecVal(x, 96))]
            zn = z3.simplify(z3.substitute(ns, *sub)).as_long()
            zy = z3.simplify(z3.substitute(y, *sub)).as_long()
            if (zn, zy) != f(s, x)[:2] or (zn, zy) != fg.step(s, x):
                zbad += 1
        print(f"  {route:<6} evaluated by z3 itself on {len(sample)} of them: {zbad} mismatches ({time.perf_counter() - t0:.1f} s)")
        out[route] = {"what": label, "sets": rows, "mismatches": sum(r["mismatches"] for r in rows),
                      "z3Evaluated": len(sample), "z3Mismatches": zbad, "subterms": n_terms}
        out["mismatches"] += out[route]["mismatches"]
        out["z3Mismatches"] += zbad
    return out


# ------------------------------------------------------------------------------------------------ step 2: proofs
def _solve(goal, timeout: int):
    """Is `goal` satisfiable? Returns (status, seconds, model or None)."""
    solver = z3.SolverFor("QF_BV")
    solver.set("timeout", int(timeout) * 1000)
    solver.add(goal)
    t0 = time.perf_counter()
    r = solver.check()
    dt = time.perf_counter() - t0
    if r == z3.unsat:
        return "proved", dt, None
    if r == z3.sat:
        return "failed", dt, solver.model()
    return "timeout", dt, None


MUTANTS = [("FLOOR_T", +1), ("RESMIN_Q", -1), ("M2", +1), ("DD_TH", +1), ("XSURGE_TH", -1), ("CDN", -1),
           ("TR_MAX", +1), ("RC", +1)]


def _netlist_terms(tap_path: str, S, X):
    with open(tap_path, "rb") as f:
        nl = tnl.check(f.read(), 96, 112, None)
    return nl, tp.Z3Circuit(nl, s=[z3.Extract(i, i, S) == 1 for i in range(64)],
                            x=[z3.Extract(i, i, X) == 1 for i in range(96)])


def _differs(c, ns, y, fields, name):
    off, width = fields[name]
    word, bits = (ns, c.ns) if name.startswith("ns.") else (y, c.y)
    return z3.Or(*[z3.Xor(bits[off + i], z3.Extract(off + i, off + i, word) == 1) for i in range(width)])


def prove_job(arg) -> dict:
    """One query in its own process: z3's Python API is not thread-safe.

    kind "total":  a condition under which Python would raise is impossible, for every (s, x);
         "field":  the netlist and the formula of one route agree on one field for every (s, x);
         "needle": the same query against a formula with one flipped bit at one point: must fail, at that point;
         "mutant": the whole comparison against the model run with one wrong constant: must fail, and the
                   counterexample must be real (the bytes, simulated, differ from the wrong model, evaluated)."""
    kind, route, name, tap_path, timeout, extra = arg
    S, X = z3.BitVec("s", 64), z3.BitVec("x", 96)
    row = {"name": name, "route": route, "engine": "z3"}
    try:
        if kind == "total":
            _, _, _, obligations = formulas(route, S, X)
            label, cond = next(o for o in obligations if o[0] == name)
            status, secs, model = _solve(z3.Not(cond), timeout)
            row.update(claim=f"for every (s, x): {label}")
        elif kind == "field":
            ns, y, fields, _ = formulas(route, S, X)
            _, c = _netlist_terms(tap_path, S, X)
            off, width = fields[name]
            status, secs, model = _solve(_differs(c, ns, y, fields, name), timeout)
            row.update(bits=width, offset=off,
                       claim=f"for every (s, x): bits {off}..{off + width - 1} of the netlist's "
                             f"{'next state' if name.startswith('ns.') else 'output word'} equal the model's {name[name.index('.') + 1:]}")
        elif kind == "needle":
            s_at, x_at = extra
            ns, y, fields, _ = formulas(route, S, X, needle=(name, s_at, x_at))
            _, c = _netlist_terms(tap_path, S, X)
            status, secs, model = _solve(_differs(c, ns, y, fields, name), timeout)
            found = model is not None and (model.eval(S, model_completion=True).as_long(),
                                           model.eval(X, model_completion=True).as_long()) == (s_at, x_at)
            return {"name": name, "route": route, "engine": "z3", "seconds": round(secs, 3),
                    "point": [hex(s_at), hex(x_at)],
                    "status": "refuted at the needle" if status == "failed" and found else f"NOT CAUGHT ({status})"}
        else:
            from tapc import sim as tsim
            key, delta = extra
            wrong = dict(fg.P, **{key: fg.P[key] + delta})
            ns, y, fields, _ = formulas(route, S, X, wrong)
            nl, c = _netlist_terms(tap_path, S, X)
            status, secs, model = _solve(z3.Or(*[_differs(c, ns, y, fields, n) for n in fields]), timeout)
            real = False
            if model is not None:
                s0 = model.eval(S, model_completion=True).as_long()
                x0 = model.eval(X, model_completion=True).as_long()
                (bn,), (by,) = tsim.step_many_int(nl, [s0], [x0])
                # the bytes are right (they give what the real model gives) and the wrong model is wrong there
                real = (bn, by) == fg.step(s0, x0) and (bn, by) != fg.step(s0, x0, wrong)
                row["counterexample"] = {"s": hex(s0), "x": hex(x0)}
            row.update(seconds=round(secs, 3), constant=f"{key} {fg.P[key]} -> {fg.P[key] + delta}",
                       status="refuted, counterexample replayed" if status == "failed" and real else f"NOT CAUGHT ({status})")
            return row
        row.update(status=status, seconds=round(secs, 3))
        if model is not None:
            row["counterexample"] = {"s": hex(model.eval(S, model_completion=True).as_long()),
                                     "x": hex(model.eval(X, model_completion=True).as_long())}
    except Exception as e:                                           # a crash is not a proof
        row.update(status="error", seconds=0.0, detail=f"{type(e).__name__}: {e}")
    return row


ROUTES = (("source", "A, the model's own source executed symbolically"), ("twin", "B, the hand-written twin"))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tap", default=os.path.join(CHIPS, "out", "fg.tap"))
    ap.add_argument("--n", type=int, default=200000)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("--out", default=os.path.join(CHIPS, "out", "fg.model.json"))
    a = ap.parse_args(argv)

    with open(a.tap, "rb") as f:
        data = f.read()
    nl = tnl.check(data, 96, 112, None)
    print(f"{a.tap}: {len(data)} bytes, {nl.n_nand} NAND + {nl.n_latch} LATCH, keccak256 0x{tnl.keccak256(data).hex()}")

    print("tests: both formulas against the Python model")
    tested = test_formulas(a.n, a.seed)

    S, X = z3.BitVec("s", 64), z3.BitVec("x", 96)
    jobs, needles, mutants = [], [], []
    rng = random.Random(a.seed + 1)
    for route, _ in ROUTES:
        _, _, fields, obligations = formulas(route, S, X)
        jobs += [("total", route, label, a.tap, a.timeout, None) for label, _ in obligations]
        order = sorted(fields, key=lambda k: -fields[k][1])           # the heavy cones first
        jobs += [("field", route, name, a.tap, a.timeout, None) for name in order]
        needles += [("needle", route, name, a.tap, a.timeout, (rng.getrandbits(64), rng.getrandbits(96))) for name in order]
        mutants += [("mutant", route, f"{k} {'+' if d > 0 else '-'}1", a.tap, a.timeout, (k, d)) for k, d in MUTANTS]
    n_fields = len(fields)
    print(f"proofs: 2 routes x {n_fields} fields ({sum(w for _, w in fields.values())} bits each) and "
          f"{sum(j[0] == 'total' for j in jobs)} conditions under which Python would raise; then {len(needles)} needles "
          f"and {len(mutants)} wrong constants that must be refuted; {a.jobs} processes")
    t0 = time.perf_counter()
    with ProcessPoolExecutor(max_workers=a.jobs) as ex:
        rows = list(ex.map(prove_job, jobs))
        wall = time.perf_counter() - t0
        t1 = time.perf_counter()
        fail_rows = list(ex.map(prove_job, needles + mutants))
        wall3 = time.perf_counter() - t1
    for r in rows:
        print(f"  {r['status'].upper():8s} {r['route']:<6} {r['name']:<58} {r.get('bits', ''):>3} {r['seconds']:>8.2f} s"
              + (f"  cex {r['counterexample']}" if r.get("counterexample") else "")
              + (f"  {r['detail']}" if r.get("detail") else ""))
    needle_rows, mutant_rows = fail_rows[:len(needles)], fail_rows[len(needles):]
    for r in mutant_rows:
        print(f"  {r['status']:<34} {r['route']:<6} wrong constant {r.get('constant', r['name']):<22} {r['seconds']:>8.2f} s"
              + (f"  {r['detail']}" if r.get("detail") else ""))
    summary = {}
    ok = tested["mismatches"] == 0 and tested["z3Mismatches"] == 0
    print()
    for route, label in ROUTES:
        fr = [r for r in rows if r["route"] == route and "bits" in r]
        tr = [r for r in rows if r["route"] == route and "bits" not in r]
        bits = sum(r["bits"] for r in fr if r["status"] == "proved")
        nd = [r for r in needle_rows if r["route"] == route]
        mt = [r for r in mutant_rows if r["route"] == route]
        summary[route] = {"what": label, "fields": len(fr), "fieldsProved": sum(r["status"] == "proved" for r in fr),
                          "bits": 176, "bitsProved": bits,
                          "raiseConditions": len(tr), "raiseConditionsProvedImpossible": sum(r["status"] == "proved" for r in tr),
                          "needlesFound": sum(r["status"] == "refuted at the needle" for r in nd), "needles": len(nd),
                          "wrongConstantsRefuted": sum(r["status"].startswith("refuted") for r in mt), "wrongConstants": len(mt),
                          "solverSeconds": round(sum(r["seconds"] for r in fr + tr), 1)}
        q = summary[route]
        ok &= (q["fieldsProved"] == q["fields"] and bits == 176 and q["raiseConditionsProvedImpossible"] == q["raiseConditions"]
               and q["needlesFound"] == q["needles"] and q["wrongConstantsRefuted"] == q["wrongConstants"])
        print(f"route {label}: == netlist on {q['fieldsProved']}/{q['fields']} fields, {bits}/176 bits; "
              f"{q['raiseConditionsProvedImpossible']}/{q['raiseConditions']} raise conditions impossible; "
              f"{q['needlesFound']}/{q['needles']} needles found, {q['wrongConstantsRefuted']}/{q['wrongConstants']} wrong "
              f"constants refuted; solver {q['solverSeconds']} s")
    print(f"wall time: proofs {wall:.1f} s, refutations {wall3:.1f} s")
    doc = {
        "format": "covenant-model-equivalence/1", "chip": fg.P["name"],
        "keccak256": "0x" + tnl.keccak256(data).hex(), "bytes": len(data), "nNand": nl.n_nand, "nLatch": nl.n_latch,
        "ok": bool(ok),
        "claim": "the behavioural model chips/model/flow_governor.py and the netlist bytes compute the same "
                 "(next state, output word) for every 64-bit state and every 96-bit input word, and the model "
                 "never raises",
        "how": ["route A: chips/props/symexec.py executes the source of flow_governor.step (with _satsub and "
                "kernel_model.pack_output / pack_fields) on z3 terms; z3 proves that formula equal to the netlist, "
                "one query per field, and proves every condition under which Python would raise impossible",
                "route B: chips/props/model_equiv.py:twin, the same law written by hand as 16-bit z3 terms, proven "
                "equal to the netlist the same way",
                "the netlist terms are built straight from the bytes (one Bool per NAND record)",
                "both formulas are also compiled back to Python and compared with the real step on the vectors "
                "under `tested`; for route A that tests the symbolic executor, the proof does not rely on it",
                "non-vacuity: single-point needles and wrong constants under `canFail` are all refuted"],
        "tools": {"z3": z3.get_version_string()},
        "routes": summary, "tested": tested, "wallSeconds": round(wall, 1),
        "proofs": rows,
        "canFail": {"what": "the same queries against deliberately wrong formulas: each must be refuted",
                    "wallSeconds": round(wall3, 1), "needles": needle_rows, "wrongConstants": mutant_rows},
    }
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=1)
        f.write("\n")
    print("wrote", a.out, "- MODEL == BYTES" if ok else "- NOT ESTABLISHED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
