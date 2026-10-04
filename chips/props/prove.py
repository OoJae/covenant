"""Run every Flow Governor proof and record the verdicts and solver times.

    chips/.venv-fg/bin/python chips/props/prove.py [--tap chips/out/fg.tap] [--timeout 1800] [--jobs 6]

Everything is a statement about the netlist bytes (chips/out/fg.tap), for every 64-bit state and every
96-bit input word, proven twice:

  engine "yosys-sat"  Yosys reads the unpacked bytes (tapc unpack) and proves each property with its built-in
                      SAT solver (MiniSat);
  engine "z3"         z3, either on the SMT-LIB that Yosys writes for the same wrapper, or (the `bytes:` rows)
                      on terms built straight from the bytes by tapc, with the properties written again in
                      Python (fg_props.py). The `bytes:` rows share nothing with the Yosys path.

  EQ   RTL == netlist bytes                     (yosys miter + SAT; z3 on word-level SMT-LIB of the RTL)
  P1   share groups sum to 256, each share <= 256, no holder share
  P2   clamp-freedom against the reference envelope: K2 allowance cap, K3 release cap, K5 reserve floor,
       K2C ceiling (K1 is P1; K2L is arithmetic, see check_k2l below)
  P3   ratchets: tier never decreases; allowance and ceiling bounded by the tier and non-increasing in it
  P4   inductive state invariant, true at reset
  P5   REV, REVCUM, ESC, PROG, LOCK and bits 81..95 are ignored
  P6   cooldown: only the floor leak while cooling down; the counter strictly decreases
  P7   reachability witness: two reachable states, one input word, two different routes; all modes reachable

Results go to chips/out/fg.proofs.json.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import subprocess
import sys
import time
from concurrent.futures import ProcessPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
CHIPS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(CHIPS, "model"))
sys.path.insert(0, os.path.join(CHIPS, "tools"))
sys.path.insert(0, HERE)

import flow_governor as fg  # noqa: E402
from flow_governor import km  # noqa: E402
from tapc import netlist as tnl  # noqa: E402
from tapc import prove as tp  # noqa: E402
from tapc import sim as tsim  # noqa: E402

RTL = [os.path.join(CHIPS, "rtl", "fg_params.vh"), os.path.join(CHIPS, "rtl", "fg_core.v")]
PROPS_V = [os.path.join(CHIPS, "rtl", "fg_params.vh"), os.path.join(HERE, "fg_props.v")]
PROPS_PY = os.path.join(HERE, "fg_props.py")
BUILD = os.path.join(HERE, "build")

GROUPS = [
    ("P1", "share groups sum to 256", "p1_"),
    ("P2", "clamp-freedom against the envelope", "p2_"),
    ("P3", "ratchets never loosen", "p3_"),
    ("P4", "inductive state invariant", "p4_"),
    ("P5", "unused inputs are ignored", "p5_"),
    ("P6", "cooldown", "p6_"),
    ("P7", "reachability witness", "w_"),
    ("PX", "extras", "px_"),
]


def check_k2l(n: int = 200000, seed: int = 3) -> dict:
    """K2L (lifetime cap) is a statement about amounts, not about the chip, so it is argued and tested here.

    Claim: with allowCumBps * 256 >= capT * 10000, K2L never binds for ANY chip. After K2 the kernel has
    T_ALLOW <= capT, so each settle credits at most floor(inflow_i * capT / 256). A sum of floors is at most
    the floor of the sum, so the allowance paid through settle n is at most floor(cum_n * capT / 256), which is
    at most floor(cum_n * allowCumBps / 10000) = the lifetime cap at settle n. Hence allow_n <= room_n.
    The test below drives kernel_model.route_tax with random words (allowance always at the cap) and random
    amounts and counts K2L hits.
    """
    env = fg.envelope()
    assert env.allowCumBps * 256 >= env.capT * 10000
    rng = random.Random(seed)
    hits = 0
    t0 = time.perf_counter()
    for _ in range(n // 200):
        cum = paid = 0
        for _ in range(200):
            inflow = rng.choice([0, 1, 255, 256, 257, rng.getrandbits(rng.randint(1, 90))])
            cum += inflow
            ta = rng.choice([env.capT, 256, rng.randint(0, 256)])
            word = km.pack_output({"T_BUY": 256 - ta, "T_ALLOW": ta, "V_RES": 256, "REL": 2, "CEIL": 1023})
            r = km.route_tax(env, word, inflow, 0, cum, paid)
            hits += 1 if r.clamp & km.K2L else 0
            paid += r.allow
    return {"name": "K2L never binds (lifetime cap)", "engine": "argument + randomized test",
            "status": "proved" if hits == 0 else "failed", "seconds": round(time.perf_counter() - t0, 3),
            "detail": f"{n} random settles with the allowance share at capT: {hits} K2L hits"}


def witness_on_bytes(nl, w: dict) -> dict:
    """Replay the witness and the tour on the bytes with the tapc simulator."""
    t0 = time.perf_counter()

    def chain(xs):
        s = 0
        modes = []
        for hx in xs:
            x = int.from_bytes(bytes.fromhex(hx[2:]), "little")
            (ns,), (y,) = tsim.step_many_int(nl, [s], [x])
            modes.append(fg.MODE_NAMES[(y >> 91) & 7])
            s = ns
        return s, modes

    i = lambda hx: int.from_bytes(bytes.fromhex(hx[2:]), "little")
    sa, _ = chain(w["reachA"]["inputs"])
    sb, _ = chain(w["reachB"]["inputs"])
    x = i(w["x"])
    (na, nb), (ya, yb) = tsim.step_many_int(nl, [sa, sb], [x, x])
    _, modes = chain(w["tour"]["inputs"])
    ok = (sa == i(w["reachA"]["state"]) and sb == i(w["reachB"]["state"]) and ya == i(w["outA"]["y"])
          and yb == i(w["outB"]["y"]) and (ya & ((1 << 91) - 1)) != (yb & ((1 << 91) - 1))
          and modes == w["tour"]["modes"] and set(modes) == set(fg.MODE_NAMES[:5]))
    return {"name": "P7 witness and tour replayed on the bytes", "engine": "tapc.sim",
            "status": "proved" if ok else "failed", "seconds": round(time.perf_counter() - t0, 3)}


def witness_z3(nl, timeout: int) -> list:
    """P7 on the bytes with z3: every step of the witness chains and of the tour is one valid implication
    (s = S_i and x = X_i) -> (ns = S_i+1 and y = Y_i), with the expected values taken from the model."""
    import z3
    import witness as wit
    w = wit.build()
    i = lambda hx: int.from_bytes(bytes.fromhex(hx[2:]), "little")

    def eq(bits, value):
        return z3.And(*[b if (value >> k) & 1 else z3.Not(b) for k, b in enumerate(bits)])

    steps = []                                   # (state, input, expected next state, expected outputs)

    def chain(xs):
        s = 0
        for hx in xs:
            ns, y = fg.step(s, i(hx))
            steps.append((s, i(hx), ns, y))
            s = ns
        return s

    sa = chain(w["reachA"]["inputs"])
    sb = chain(w["reachB"]["inputs"])
    chain(w["tour"]["inputs"])
    assert sa == i(w["reachA"]["state"]) and sb == i(w["reachB"]["state"])
    x = i(w["x"])
    for s0 in (sa, sb):
        ns, y = fg.step(s0, x)
        steps.append((s0, x, ns, y))
    ya, yb = steps[-2][3], steps[-1][3]
    assert ya == i(w["outA"]["y"]) and yb == i(w["outB"]["y"]) and (ya ^ yb) & ((1 << 91) - 1)
    uniq = sorted(set(steps))

    def pred(c):
        return z3.And(*[z3.Implies(z3.And(eq(c.s, s0), eq(c.x, x0)), z3.And(eq(c.ns, ns), eq(c.y, y)))
                        for s0, x0, ns, y in uniq])

    rs = tp.check_z3(nl, [(f"P7 witness chains and mode tour ({len(uniq)} concrete steps)", pred)], timeout=timeout)
    for q in rs:
        q.name = "bytes: " + q.name
    return rs


def run_job(arg) -> list:
    """One proof job in its own process. Returns a list of ProofResult; a crash is a failed proof."""
    job, tap_path, timeout = arg
    t1 = time.perf_counter()
    try:
        with open(tap_path, "rb") as f:
            nl = tnl.check(f.read(), 96, 112, None)
        kind = job[0]
        if kind == "equiv":
            f = tp.equiv_yosys if job[1] == "yosys" else tp.equiv_z3
            return [f(RTL, "fg_core", nl, work=os.path.join(BUILD, f"equiv_{job[1]}"), timeout=timeout,
                      name="EQ fg_core == netlist bytes")]
        if kind == "prop":
            _, sig, eng = job
            return tp.prove_properties(PROPS_V, "fg_props", [sig], tap=nl, tap_module="fg_tap",
                                       work=os.path.join(BUILD, f"prop_{eng}_{sig}"), timeout=timeout, engine=eng)
        if kind == "witness":
            _, eng, wsigs = job
            return tp.prove_properties([os.path.join(BUILD, "fg_witness.v")], "fg_witness", list(wsigs), tap=nl,
                                       tap_module="fg_tap", work=os.path.join(BUILD, f"witness_{eng}"),
                                       timeout=timeout, engine=eng)
        if kind == "bytes_witness":
            return witness_z3(nl, timeout)
        if kind == "bytes":
            preds = dict(tp.load_predicates(PROPS_PY))
            rs = tp.check_z3(nl, [(job[1], preds[job[1]])], timeout=timeout)
            for q in rs:
                q.name = "bytes: " + q.name
            return rs
        raise ValueError(f"unknown job {job}")
    except Exception as e:
        return [tp.ProofResult(" ".join(str(v) for v in job[:2]), tp.ERROR, "?", time.perf_counter() - t1, {},
                               f"{type(e).__name__}: {e}")]


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tap", default=os.path.join(CHIPS, "out", "fg.tap"))
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--out", default=os.path.join(CHIPS, "out", "fg.proofs.json"))
    a = ap.parse_args(argv)

    subprocess.run([sys.executable, os.path.join(CHIPS, "rtl", "gen_params.py"), "--check"], check=True)
    with open(a.tap, "rb") as f:
        data = f.read()
    nl = tnl.check(data, 96, 112, None)
    print(f"{a.tap}: {len(data)} bytes, {nl.n_nand} NAND + {nl.n_latch} LATCH, keccak256 0x{tnl.keccak256(data).hex()}")

    import witness as wit
    w = wit.build()
    os.makedirs(BUILD, exist_ok=True)
    wv = os.path.join(BUILD, "fg_witness.v")
    with open(wv, "w", encoding="utf-8") as f:
        f.write(wit.verilog(w))
    with open(os.path.join(CHIPS, "out", "fg.witness.json"), "w", encoding="utf-8") as f:
        json.dump(w, f, indent=1)
        f.write("\n")

    sigs = tp.wrapper_outputs(PROPS_V, "fg_props", os.path.join(BUILD, "ports"), nl, tap_module="fg_tap")
    wsigs = tp.wrapper_outputs([wv], "fg_witness", os.path.join(BUILD, "ports_w"), nl, tap_module="fg_tap")
    preds = tp.load_predicates(PROPS_PY)
    print(f"{len(sigs)} wrapper properties, {len(wsigs)} witness checks, {len(preds)} byte-level predicates")

    jobs = [("equiv", "yosys"), ("equiv", "z3")]
    for sig in sigs:
        for eng in ("yosys", "z3"):
            jobs.append(("prop", sig, eng))
    jobs.append(("witness", "yosys", tuple(wsigs)))     # the z3-via-Yosys path overflows the wasm stack on the
    jobs.append(("bytes_witness",))                     # chained wrapper; z3 checks the same steps on the bytes
    for name, _ in preds:
        jobs.append(("bytes", name))

    t0 = time.perf_counter()
    results = []
    # one process per job: z3's Python API is not thread-safe, and Yosys runs as a subprocess anyway
    with ProcessPoolExecutor(max_workers=a.jobs) as ex:
        for rs in ex.map(run_job, [(j, a.tap, a.timeout) for j in jobs]):
            results += rs
    wall = time.perf_counter() - t0

    rows = [{"name": r.name, "engine": r.engine, "status": r.status, "seconds": round(r.seconds, 3),
             **({"counterexample": {k: hex(v) for k, v in r.counterexample.items()}} if r.counterexample else {}),
             **({"detail": r.detail} if r.detail and not r.ok else {})} for r in results]
    rows.append(witness_on_bytes(nl, w))
    rows.append(check_k2l())

    ok = all(r["status"] == "proved" for r in rows)
    width = max(len(r["name"]) for r in rows)
    for r in rows:
        print(f"{r['status'].upper():8s} {r['name']:<{width}}  {r['engine']:<26s} {r['seconds']:>8.2f} s"
              + (f"  {r.get('detail', '')}" if r.get("detail") else "")
              + (f"  cex {r['counterexample']}" if r.get("counterexample") else ""))
    by_engine = {}
    for r in rows:
        e = by_engine.setdefault(r["engine"], [0, 0.0])
        e[0] += 1
        e[1] += r["seconds"]
    print(f"\n{sum(r['status'] == 'proved' for r in rows)}/{len(rows)} proved; wall time {wall:.1f} s; "
          + "; ".join(f"{k}: {v[0]} checks, {v[1]:.1f} s" for k, v in by_engine.items()))

    doc = {
        "format": "covenant-proofs/1", "chip": fg.P["name"],
        "keccak256": "0x" + tnl.keccak256(data).hex(), "bytes": len(data),
        "nNand": nl.n_nand, "nLatch": nl.n_latch, "ok": ok,
        "space": "every 64-bit state and every 96-bit input word (2^160 pairs), except P7 which is a witness",
        "envelope": fg.ENV,
        "tools": {"yosys": __import__("tapc").yosys.short_version(), "z3": __import__("z3").get_version_string()},
        "wallSeconds": round(wall, 1),
        "groups": [{"id": g, "title": t, "prefix": p} for g, t, p in GROUPS],
        "proofs": rows,
    }
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=1)
        f.write("\n")
    print("wrote", a.out, "- ALL PROVED" if ok else "- FAILURES")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
