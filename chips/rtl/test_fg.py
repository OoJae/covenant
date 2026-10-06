"""RTL == model check for the Flow Governor, run on the synthesised netlist bytes.

    chips/.venv-fg/bin/python chips/rtl/test_fg.py [--tap chips/out/fg.tap] [--n 200000] [--seed 1]

The RTL is proven equal to these bytes for every (s, x) by chips/props/prove.py (yosys miter and z3), so
checking the bytes against the Python model checks the RTL against the model.

What is compared, bit for bit (64 next-state bits and 112 output bits per vector):
  1. uniform random (s, x)                                   --n vectors
  2. boundary-biased (s, x): fields drawn near every threshold of the control law   --n vectors
  3. random walks from reset: reachable states, kernel-shaped inputs               --n vectors
  4. every settle of every scenario in chips/model/scenarios.py (revision-2 kernel and idealised kernel),
     plus the cadence variants

The netlist is evaluated twice: by the small evaluator in this file (written from the vendored contract
source contracts/vendor/tapeout-xlayer/src/lib/NetlistVM.sol, independent of tapc) and, on a sample,
by tapc.sim.
"""
from __future__ import annotations

import argparse
import os
import random
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CHIPS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(CHIPS, "model"))
sys.path.insert(0, os.path.join(CHIPS, "tools"))

import flow_governor as fg  # noqa: E402
import scenarios as sc  # noqa: E402
from flow_governor import km  # noqa: E402

N_IN, N_OUT, N_STATE = 96, 112, 64


# ----------------------------------------------------------------------------- independent evaluator
def parse_tap(data: bytes, n_in: int):
    """TAP-20 flat netlist -> list of ('N', a, b) / ('L', d). Signals: 0 = const 0, 1 = const 1,
    2..2+nIn-1 = inputs, then one signal per record in order."""
    recs = []
    p = 0
    while p < len(data):
        op = data[p]
        if op == 0x00:
            recs.append(("N", int.from_bytes(data[p + 1:p + 4], "big"), int.from_bytes(data[p + 4:p + 7], "big")))
            p += 7
        elif op == 0x01:
            recs.append(("L", int.from_bytes(data[p + 1:p + 4], "big")))
            p += 4
        else:
            raise ValueError(f"opcode {op:#x} at byte {p}: only NAND and LATCH are allowed")
    return recs


def planes_of(values, n_bits):
    """V integers of n_bits -> n_bits integers of V bits (bit v of plane i = bit i of values[v])."""
    fmt = f"0{n_bits}b"
    rows = [format(v, fmt) for v in reversed(values)]
    cols = ["".join(c) for c in zip(*rows)]
    return [int(cols[n_bits - 1 - i], 2) for i in range(n_bits)]


def values_of(planes, n_vec):
    fmt = f"0{n_vec}b"
    rows = [format(p, fmt) for p in reversed(planes)]
    cols = ["".join(c) for c in zip(*rows)]
    return [int(cols[n_vec - 1 - v], 2) for v in range(n_vec)]


def eval_many(recs, states, inputs):
    """One beat on V vectors at once. Returns (new_states, outputs) as integer lists."""
    v = len(states)
    mask = (1 << v) - 1
    sp = planes_of(states, N_STATE)
    sig = [0, mask] + planes_of(inputs, N_IN)
    latch_d = []
    li = 0
    for r in recs:
        if r[0] == "N":
            sig.append(mask ^ (sig[r[1]] & sig[r[2]]))
        else:
            sig.append(sp[li])
            latch_d.append(r[1])
            li += 1
    assert li == N_STATE, f"expected {N_STATE} latches, found {li}"
    ns = [sig[d] for d in latch_d]
    out = sig[len(sig) - N_OUT:]
    return values_of(ns, v), values_of(out, v)


# ----------------------------------------------------------------------------- vector generators
def uniform(rng, n):
    return [(rng.getrandbits(64), rng.getrandbits(96)) for _ in range(n)]


def _near(rng, centre, lo, hi, spread=3):
    return min(hi, max(lo, centre + rng.randint(-spread, spread)))


def boundary(rng, n):
    """Fields drawn around the thresholds of the control law, so that every comparator sees both sides."""
    p = fg.P
    tax_pts = [0, 1, p["FLOOR_Q"], p["FLOOR_T"], 1023] + [p["FLOOR_Q"] + v for v in p["LOG8DT"]] \
        + [p["FLOOR_T"] + v for v in p["LOG8DT"]]
    cum_pts = [0, p["M1"], p["M2"], p["M3"], 1023]
    res_pts = [0, p["RESMIN_Q"], p["RESMIN_T"], 1023]
    out = []
    for _ in range(n):
        st = {}
        for name, _, w, _ in fg.STATE_FIELDS:
            st[name] = rng.getrandbits(w)
        grad = rng.getrandbits(1)
        floor = p["FLOOR_T"] if grad else p["FLOOR_Q"]
        dt = rng.choice([0, 1, 1, 1, 2, 3, 4, 5, 8, 15, rng.getrandbits(4)])
        k = floor + p["LOG8DT"][dt if dt else 1]
        mode = rng.random()
        if mode < 0.5:
            # make the reading land near the stored average / peak, where surge, dip and slew decisions flip
            if rng.random() < 0.5:
                l = _near(rng, st["PK"] + rng.choice([0, p["SURGE_TH"], p["XSURGE_TH"], p["SURGE_TH"] + p["RB_SPAN"]]),
                          0, 1023, 2)
            else:
                l = _near(rng, (st["A"] >> 2) + rng.choice([0, -p["DIP_TH"], p["DIP_TH"], -3, 3]), 0, 1023, 2)
            tax = min(1023, max(0, k + l))
        else:
            tax = _near(rng, rng.choice(tax_pts), 0, 1023, 2) if rng.random() < 0.7 else rng.getrandbits(10)
        if rng.random() < 0.3:
            # states near the drawdown trigger: the average just below the peak
            st["A"] = min(4095, max(0, 4 * (st["PK"] - rng.choice([15, 16, 17, 31, 32, 33, 0, 1])) + rng.randint(-4, 4)))
        if rng.random() < 0.3:
            st["MODE"] = rng.choice([0, 1, 2, 3, 4])
        if rng.random() < 0.3:
            st["LIVE"] = rng.choice([0, 1, 8, dt, max(0, dt - 1), min(15, dt + 1)])
        if rng.random() < 0.3:
            st["CD"] = rng.choice([0, 1, dt & 7, max(0, dt - 1) & 7, min(7, dt + 1)])
        x = km.pack_input({
            "TAX": tax,
            "TAXCUM": _near(rng, rng.choice(cum_pts), 0, 1023, 2) if rng.random() < 0.7 else rng.getrandbits(10),
            "REV": rng.getrandbits(10), "REVCUM": rng.getrandbits(10),
            "RES": _near(rng, rng.choice(res_pts), 0, 1023, 2) if rng.random() < 0.7 else rng.getrandbits(10),
            "ESC": rng.getrandbits(10), "PROG": rng.getrandbits(8), "LOCK": rng.getrandbits(8),
            "DT": dt, "GRAD": grad, "ZERO": rng.getrandbits(15) if rng.random() < 0.5 else 0})
        out.append((fg.pack_state(st), x))
    return out


def walks(rng, n):
    """Random walks from the reset state with kernel-shaped inputs (reserved bits zero, DT >= 1)."""
    out = []
    while len(out) < n:
        s = 0
        grad = 0
        tax_base = rng.choice([0, 360, 383, 410, 440, 480])
        cum = 0
        res = 0
        for _ in range(rng.randint(20, 400)):
            if not grad and rng.random() < 0.004:
                grad = 1
                cum = 0
                tax_base = rng.choice([0, fg.P["FLOOR_T"] + 5, 540, 585, 620])
            r = rng.random()
            if r < 0.35:
                tax = 0
            elif r < 0.85:
                tax = min(1023, max(0, tax_base + rng.randint(-12, 12)))
            else:
                tax = rng.getrandbits(10)
            cum = max(cum, min(1023, tax + rng.randint(0, 40)))
            res = min(1023, max(0, res + rng.randint(-20, 20))) if rng.random() < 0.8 else rng.getrandbits(10)
            dt = rng.choice([1, 1, 1, 1, 1, 1, 2, 2, 3, 4, 6, 9, 15])
            x = km.pack_input({"TAX": tax, "TAXCUM": cum, "RES": res, "PROG": 255 if grad else rng.getrandbits(8) % 255,
                               "LOCK": rng.getrandbits(8), "DT": dt, "GRAD": grad})
            out.append((s, x))
            s, _ = fg.step(s, x)
            if len(out) >= n:
                break
    return out


def scenario_vectors():
    """Every settle of every scenario, under the revision-2 kernel and under the idealised one, at the scenario's
    own cadence and at six slower ones."""
    vec = []
    S = sc.scenarios()
    for mode in (sc.REV2, sc.IDEAL):
        for name, sdef in S.items():
            kw = {k: sdef[k] for k in sc.RUN_KEYS if k in sdef}
            t = sc.run(name, sdef["flows"], mode=mode, **kw)
            vec += [(r.s_before, r.x) for r in t.rows]
            if "settle_at" not in sdef:
                for k in (2, 3, 4, 6, 8, 12):
                    t = sc.run(name, sdef["flows"], mode=mode, **dict(kw, settle_at=lambda e, k=k: e % k == 0))
                    vec += [(r.s_before, r.x) for r in t.rows]
    return vec


# ----------------------------------------------------------------------------- comparison
def compare(recs, vectors, label, batch=20000, tapc_nl=None, tapc_sample=2000):
    t0 = time.perf_counter()
    bad = 0
    first = None
    for i in range(0, len(vectors), batch):
        chunk = vectors[i:i + batch]
        ns, ys = eval_many(recs, [s for s, _ in chunk], [x for _, x in chunk])
        for (s, x), a, b in zip(chunk, ns, ys):
            ms, my = fg.step(s, x)
            if a != ms or b != my:
                bad += 1
                if first is None:
                    first = (s, x, a, b, ms, my)
    extra = ""
    if tapc_nl is not None and vectors:
        from tapc import sim as tsim
        sample = vectors[:tapc_sample]
        tn, ty = tsim.step_many_int(tapc_nl, [s for s, _ in sample], [x for _, x in sample])
        tb = sum(1 for (s, x), a, b in zip(sample, tn, ty) if (a, b) != fg.step(s, x))
        bad += tb
        extra = f"; tapc.sim on {len(sample)}: {tb} mismatches"
    dt = time.perf_counter() - t0
    print(f"{label:<28} {len(vectors):>8} vectors  {bad} mismatches  ({dt:.1f} s{extra})")
    if first:
        s, x, a, b, ms, my = first
        print(f"  first mismatch: s={s:#018x} x={x:#026x}")
        print(f"    netlist ns={a:#018x} y={b:#030x}")
        print(f"    model   ns={ms:#018x} y={my:#030x}")
        print("    state  ", fg.unpack_state(s))
        print("    net ns ", fg.unpack_state(a), km.unpack_output(b))
        print("    mod ns ", fg.unpack_state(ms), km.unpack_output(my))
    return bad


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tap", default=os.path.join(CHIPS, "out", "fg.tap"))
    ap.add_argument("--n", type=int, default=200000)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args(argv)
    with open(a.tap, "rb") as f:
        data = f.read()
    recs = parse_tap(data, N_IN)
    n_nand = sum(1 for r in recs if r[0] == "N")
    n_latch = len(recs) - n_nand
    assert all(r[0] == "L" for r in recs[:n_latch]) and n_latch == N_STATE, "latches must come first"
    print(f"{a.tap}: {len(data)} bytes, {n_nand} NAND + {n_latch} LATCH")
    tapc_nl = None
    try:
        from tapc import netlist as tnl
        tapc_nl = tnl.check(data, N_IN, N_OUT, None)
    except Exception as e:  # tapc is optional here
        print("  (tapc.sim cross-check skipped:", e, ")")
    rng = random.Random(a.seed)
    bad = 0
    bad += compare(recs, uniform(rng, a.n), "uniform random (s, x)", tapc_nl=tapc_nl)
    bad += compare(recs, boundary(rng, a.n), "boundary-biased (s, x)", tapc_nl=tapc_nl)
    bad += compare(recs, walks(rng, a.n), "random walks from reset", tapc_nl=tapc_nl)
    bad += compare(recs, scenario_vectors(), "scenario traces", tapc_nl=tapc_nl)
    print("RTL == model:", "PASS" if bad == 0 else f"FAIL ({bad} mismatches)")
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
