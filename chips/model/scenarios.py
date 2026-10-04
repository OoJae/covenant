"""Scenario runner: Flow Governor model + kernel routing (chips/golden/kernel_model.py) over many epochs.

    python chips/model/scenarios.py                 # summary of every scenario + all checks
    python chips/model/scenarios.py steady -v       # per-epoch table of one scenario
    python chips/model/scenarios.py --list
    python chips/model/scenarios.py --cadence       # the cadence-equivalence test only
    python chips/model/scenarios.py --dump DIR      # write every per-epoch table and trace (JSON) to DIR

Amounts are integers (wei of OKB before graduation, token base units after). The simulated kernel
does exactly what chips/INTERFACE.md section 8 says, through kernel_model.route_tax, so the
`clamp` column is the kernel's own clampBits. A proven chip keeps it at 0 on every row.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import sys
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional, Sequence

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import flow_governor as fg  # noqa: E402
from flow_governor import km  # noqa: E402

OKB = 10 ** 18
USD_PER_OKB = 122.0              # only used to print dollar hints


@dataclass
class Row:
    epoch: int
    dt: int
    inflow: int
    x: int
    y: int
    s_before: int
    s_after: int
    o: Dict[str, int]
    st: Dict[str, int]
    routed: km.Routed
    reserve_before: int
    reserve_after: int
    cum: int
    grad: int
    buy_executed: int


@dataclass
class Trace:
    name: str
    rows: List[Row] = field(default_factory=list)
    total_in: int = 0
    total_allow: int = 0
    total_buy: int = 0
    max_clamp: int = 0

    def modes(self) -> List[int]:
        return [r.o["MODE"] for r in self.rows]


class Kernel:
    """The parts of kernel v1 that touch the chip: input assembly, step, routing, bookkeeping."""

    def __init__(self, step: Callable = fg.step, env: Optional[km.Envelope] = None, exec_frac=None):
        self.step = step
        self.env = env or fg.envelope()
        self.state = 0
        self.last_epoch = 0
        self.grad = 0
        self.cum = 0
        self.reserve = 0
        self.allow_paid = 0
        self.pending = 0                      # inflow sitting in the vault since the last settle
        self.exec_frac = exec_frac            # None = every buy executes fully; else f(epoch) -> 0..256

    def accrue(self, amount: int):
        self.pending += amount

    def graduate(self):
        """Regime change: the tax unit becomes the project token. TAXCUM restarts. The OKB reserve is
        routed by the kernel's own post-graduation leg (INTERFACE section 9), not by the chip."""
        self.grad = 1
        self.cum = 0
        self.reserve = 0
        self.allow_paid = 0
        self.pending = 0

    def settle(self, epoch: int) -> Row:
        dt = km.dt_code(epoch, self.last_epoch)
        inflow, self.pending = self.pending, 0
        self.cum += inflow
        reserve0 = self.reserve
        x = km.pack_input({"TAX": km.lg8(inflow), "TAXCUM": km.lg8(self.cum), "RES": km.lg8(reserve0),
                           "PROG": 255 if self.grad else 0, "LOCK": 0, "DT": dt, "GRAD": self.grad})
        s0 = self.state
        ns, y = self.step(s0, x)
        r = km.route_tax(self.env, y, inflow, reserve0, self.cum, self.allow_paid)
        executed = r.buy_decided
        if self.exec_frac is not None:
            executed = r.buy_decided * self.exec_frac(epoch) // 256
        self.reserve = r.reserve_after + (r.buy_decided - executed)
        self.allow_paid += r.allow
        self.state = ns
        self.last_epoch = epoch
        return Row(epoch, dt, inflow, x, y, s0, ns, km.unpack_output(y), fg.unpack_state(ns), r,
                   reserve0, self.reserve, self.cum, self.grad, executed)


def run(name: str, flows: Sequence[int], settle_at: Optional[Callable[[int], bool]] = None,
        grad_epoch: Optional[int] = None, step: Callable = fg.step, exec_frac=None,
        env: Optional[km.Envelope] = None) -> Trace:
    """flows[i] is the tax that arrives during epoch i+1. settle_at(e) says whether a settle happens at the
    end of epoch e (default: every epoch). The last epoch always settles."""
    k = Kernel(step, env, exec_frac)
    t = Trace(name)
    n = len(flows)
    for e in range(1, n + 1):
        if grad_epoch is not None and e == grad_epoch:
            k.graduate()
        k.accrue(flows[e - 1])
        if settle_at is None or settle_at(e) or e == n:
            row = k.settle(e)
            t.rows.append(row)
            t.total_in += row.inflow
            t.total_allow += row.routed.allow
            t.total_buy += row.buy_executed
            t.max_clamp |= row.routed.clamp
    return t


# ----------------------------------------------------------------------------- printing
def fmt_amt(v: int) -> str:
    if v == 0:
        return "0"
    return f"{v:.3e}"


def table(t: Trace, limit: Optional[int] = None) -> str:
    hdr = (f"{'ep':>4} {'dt':>2} {'inflow':>10} {'TAX':>4} {'RES':>4} {'mode':>6} {'T':>1} "
           f"{'buy':>3} {'alw':>3} {'res':>3} {'REL':>3} {'CEIL':>4} | {'A':>6} {'PK':>4} {'dd':>3} "
           f"{'LV':>2} {'W':>1} {'S':>1} {'CD':>2} {'TR':>2} | {'allow':>10} {'bought':>10} "
           f"{'reserve':>10} {'clamp':>5} flags")
    lines = [hdr, "-" * len(hdr)]
    rows = t.rows if limit is None else t.rows[:limit]
    for r in rows:
        o, st = r.o, r.st
        lines.append(
            f"{r.epoch:>4} {r.dt:>2} {fmt_amt(r.inflow):>10} {(r.x & 1023):>4} {((r.x >> 40) & 1023):>4} "
            f"{fg.MODE_NAMES[o['MODE']]:>6} {o['TIER']:>1} {o['T_BUY']:>3} {o['T_ALLOW']:>3} {o['T_RES']:>3} "
            f"{o['REL']:>3} {o['CEIL']:>4} | {st['A'] / 4:>6.2f} {st['PK']:>4} {o['AUX']:>3} "
            f"{st['LIVE']:>2} {st['WARM']:>1} {st['SUR']:>1} {st['CD']:>2} {st['TR']:>2} | "
            f"{fmt_amt(r.routed.allow):>10} {fmt_amt(r.buy_executed):>10} {fmt_amt(r.reserve_after):>10} "
            f"{r.routed.clamp:>5} {fg.flags_str(o['FLAGS'])}")
    return "\n".join(lines)


def summary(t: Trace) -> Dict[str, object]:
    hist = [0] * 8
    for r in t.rows:
        hist[r.o["MODE"]] += r.dt if False else 1
    final_res = t.rows[-1].reserve_after if t.rows else 0
    # reserve measured in "epochs of average inflow"
    avg_in = t.total_in / max(1, t.rows[-1].epoch) if t.rows else 0
    max_res = max((r.reserve_after for r in t.rows), default=0)
    return {
        "settles": len(t.rows), "epochs": t.rows[-1].epoch if t.rows else 0,
        "in": t.total_in, "allow": t.total_allow, "bought": t.total_buy, "reserve_end": final_res,
        "allow_pct": 100.0 * t.total_allow / t.total_in if t.total_in else 0.0,
        "bought_pct": 100.0 * t.total_buy / t.total_in if t.total_in else 0.0,
        "reserve_end_pct": 100.0 * final_res / t.total_in if t.total_in else 0.0,
        "max_reserve_epochs": (max_res / avg_in) if avg_in else 0.0,
        "modes": {fg.MODE_NAMES[i]: hist[i] for i in range(5) if hist[i]},
        "tier_end": t.rows[-1].o["TIER"] if t.rows else 0,
        "clamp": t.max_clamp,
    }


def summary_line(t: Trace) -> str:
    s = summary(t)
    return (f"{t.name:<22} ep {s['epochs']:>4} settles {s['settles']:>4}  in {fmt_amt(s['in']):>9}  "
            f"allow {s['allow_pct']:5.1f}%  bought {s['bought_pct']:5.1f}%  left {s['reserve_end_pct']:5.1f}%  "
            f"maxRes {s['max_reserve_epochs']:5.1f} ep  tier {s['tier_end']}  clamp {s['clamp']}  {s['modes']}")


# ----------------------------------------------------------------------------- flows
def const(v: int, n: int) -> List[int]:
    return [int(v)] * n


def lognormal(rng: random.Random, median: float, sigma: float, n: int, p_zero: float = 0.0) -> List[int]:
    return [0 if rng.random() < p_zero else int(median * rng.lognormvariate(0.0, sigma)) for _ in range(n)]


def scenarios() -> Dict[str, dict]:
    """name -> dict(flows=..., settle_at=..., grad_epoch=..., note=...)."""
    S: Dict[str, dict] = {}
    f0 = 5 * 10 ** 15                         # 0.005 OKB of tax per epoch: about $20 of volume per epoch at 3%

    S["steady"] = dict(flows=const(f0, 400),
                       note="Constant inflow. The reserve must settle at a bounded level (leak = inflow share).")
    S["steady-small"] = dict(flows=const(25 * 10 ** 13, 400),
                             note="A $1 buy every epoch (2.5e14 wei of tax).")
    S["steady-large"] = dict(flows=const(2 * OKB, 400),
                             note="2 OKB of tax per epoch (about 67 OKB of volume per epoch).")
    S["surge"] = dict(flows=const(f0, 60) + const(16 * f0, 8) + const(f0, 80),
                      note="16x surge for 8 epochs inside a steady flow.")
    S["ramp"] = dict(flows=const(f0, 40) + [int(f0 * 1.5 ** i) for i in range(1, 13)] + const(f0 * 130, 40),
                     note="Flow ramps up by 1.5x per epoch for 12 epochs and stays high.")
    S["drawdown"] = dict(flows=const(8 * f0, 60) + [int(8 * f0 * 0.9 ** i) for i in range(1, 60)] + const(f0 // 60, 80),
                         note="Slow bleed: 10% less tax every epoch.")
    S["crash"] = dict(flows=const(8 * f0, 60) + const(f0 // 8, 120),
                      note="Flow falls 64x in one epoch and stays there.")
    S["drought"] = dict(flows=const(f0, 60) + const(0, 160),
                        note="Steady flow, then nothing at all.")
    S["silence-return"] = dict(flows=const(f0, 60) + const(0, 200) + const(f0, 60),
                               note="Long silence, then the same ordinary volume returns (the earlier design "
                                    "classed this as a surge for many epochs).")
    S["pause-return"] = dict(flows=const(f0, 40) + const(0, 5) + const(f0, 20) + const(0, 3) + const(f0, 20)
                             + const(0, 7) + const(f0, 20),
                             note="Short pauses of 5, 3 and 7 epochs between runs of the same volume.")
    rng = random.Random(7)
    S["dust"] = dict(flows=[25 * 10 ** 13 * rng.choice([1, 1, 1, 2, 4]) if rng.random() < 0.12 else 0
                            for _ in range(600)],
                     note="Sporadic $1-$4 buys, about one epoch in eight, zero in between.")
    rng = random.Random(8)
    S["subdust"] = dict(flows=[rng.choice([10 ** 11, 3 * 10 ** 12, 8 * 10 ** 12]) if rng.random() < 0.3 else 0
                               for _ in range(300)],
                        note="Inflows below the floor (1e11..8e12 wei). Nothing should be classed as live.")
    rng = random.Random(9)
    S["noisy"] = dict(flows=lognormal(rng, f0, 1.2, 600, p_zero=0.15),
                      note="Lognormal tax per epoch (sigma 1.2), 15% empty epochs: a small token with a few "
                           "trades per epoch.")
    rng = random.Random(10)
    S["noisy-dollars"] = dict(flows=lognormal(rng, 4 * 10 ** 14, 1.5, 800, p_zero=0.6),
                              note="The reference token's likely life: median $1.6 buys, 60% empty epochs.")
    S["launch"] = dict(flows=[int(OKB * 0.4 * 0.7 ** i) for i in range(40)] + lognormal(random.Random(11), 2 * 10 ** 15, 1.0, 300, 0.3),
                       note="Launch spike decaying 30% per epoch, then ordinary noisy volume.")
    S["milestones"] = dict(flows=const(10 ** 15, 30) + const(10 ** 16, 30) + const(10 ** 17, 30) + const(10 ** 18, 30),
                           note="Cumulative tax crosses 0.009, 0.099 and 1.009 OKB: the allowance ratchet.")
    S["whale"] = dict(flows=const(f0, 40) + [3 * OKB] + const(f0, 60),
                      note="One epoch with 3 OKB of tax (a 100 OKB trade): the allowance ceiling binds.")
    tok = 10 ** 22
    S["graduation"] = dict(flows=const(2 * 10 ** 16, 60) + const(tok, 60) + const(0, 40) + const(tok, 30),
                           grad_epoch=61,
                           note="Graduates at epoch 61: tax is then 1e22 token units per epoch.")
    S["graduation-busy"] = dict(flows=const(2 * 10 ** 16, 30) + const(16 * 2 * 10 ** 16, 6)
                                + lognormal(random.Random(12), 3 * 10 ** 23, 1.2, 200, 0.1),
                                grad_epoch=37,
                                note="Graduates in the middle of a surge (in BANK); token tax is noisy afterwards.")
    S["witness"] = dict(flows=[10 ** 16] + const(0, 30),
                        note="One epoch with 0.01 OKB of tax, then silence. The shortest trace in which one "
                             "input word is answered with two different routes.")
    rng = random.Random(13)
    sched = set()
    e = 0
    while e < 700:
        e += rng.choice([1, 1, 1, 2, 3, 5, 9, 14, 15, 16, 22, 40])
        sched.add(e)
    S["hostile-timing"] = dict(flows=lognormal(random.Random(9), f0, 1.2, 600, p_zero=0.15),
                               settle_at=lambda ep, sched=sched: ep in sched,
                               note="The 'noisy' flow settled at irregular gaps of 1..40 epochs (DT saturates at 15).")
    S["failed-buys"] = dict(flows=const(f0, 120) + const(0, 120), exec_frac=lambda ep: 0 if ep % 3 else 128,
                            note="Two buys in three fail and the third executes half: the rest stays in reserve.")
    return S


def run_named(name: str, **over) -> Trace:
    sc = dict(scenarios()[name])
    sc.update(over)
    return run(name, sc["flows"], sc.get("settle_at"), sc.get("grad_epoch"), exec_frac=sc.get("exec_frac"))


# ----------------------------------------------------------------------------- checks
def check_invariants(t: Trace) -> List[str]:
    """Checks that must hold on every row of every scenario."""
    bad = []
    env = fg.envelope()
    for r in t.rows:
        o = r.o
        if r.routed.clamp:
            bad.append(f"{t.name} ep {r.epoch}: clamp {r.routed.clamp}")
        if o["T_BUY"] + o["T_HOLD"] + o["T_ALLOW"] + o["T_RES"] != 256:
            bad.append(f"{t.name} ep {r.epoch}: T shares")
        if o["V_BUY"] + o["V_HOLD"] + o["V_ALLOW"] + o["V_RES"] != 256:
            bad.append(f"{t.name} ep {r.epoch}: V shares")
        if not (env.floorRel <= o["REL"] <= env.relMax):
            bad.append(f"{t.name} ep {r.epoch}: REL {o['REL']}")
        if r.routed.allow + r.routed.buy_share + r.routed.to_reserve != r.inflow:
            bad.append(f"{t.name} ep {r.epoch}: conservation")
        if r.grad and r.routed.allow:
            bad.append(f"{t.name} ep {r.epoch}: allowance after graduation")
    for a, b in zip(t.rows, t.rows[1:]):
        if b.o["TIER"] < a.o["TIER"]:
            bad.append(f"{t.name} ep {b.epoch}: tier decreased")
    return bad


def find_witness(t: Trace):
    """Two settles of one trace with the same input word and different routes."""
    seen: Dict[int, Row] = {}
    route_mask = (1 << 91) - 1                       # shares, REL, CEIL: everything the kernel acts on
    best = None
    for r in t.rows:
        q = seen.get(r.x)
        if q is not None and (q.y & route_mask) != (r.y & route_mask):
            cand = (q, r)
            if best is None or cand[1].epoch < best[1].epoch:
                best = cand
        seen.setdefault(r.x, r)
    return best


# ----------------------------------------------------------------------------- behaviour checks
def behaviour_checks(verbose: bool = True) -> bool:
    """Named, asserted findings. Each one is a sentence the judge guide relies on."""
    S = scenarios()
    out = []

    def check(name: str, ok: bool, detail: str = ""):
        out.append((name, ok, detail))

    # the reserve is bounded under steady inflow: it settles at RC / LEAK = 32 epochs of inflow
    # (when the chip's own ceiling cuts the allowance, the cut part stays in the reserve too, so the level can
    # rise towards (RC + AL0) / LEAK = 56 epochs at very large flows; it is bounded all the same)
    for n in ("steady-small", "steady", "steady-large"):
        f = S[n]["flows"][0]
        t = run(n, const(f, 2000))
        res = [r.reserve_after / f for r in t.rows]
        bound = (fg.P["RC"] + fg.P["AL0"]) / fg.P["LEAK"]
        check(f"{n}: reserve bounded under steady inflow (settles at {res[-1]:.1f} epochs of inflow; "
              f"last 500 epochs move it by {abs(res[-1] - res[-500]):.3f})",
              max(res) <= bound and abs(res[-1] - res[-500]) < 0.05 and t.max_clamp == 0)
        check(f"{n}: always CRUISE", all(r.o["MODE"] == fg.CRUISE for r in t.rows))

    # the collapse the earlier design showed: ordinary volume after a long silence is NOT a surge
    t = run_named("silence-return")
    back = [r for r in t.rows if r.epoch > 260]
    check("silence-return: no BANK epoch after the silence", all(r.o["MODE"] != fg.BANK for r in back))
    check("silence-return: the first settle after the silence re-seeds the average (warm flag, CRUISE)",
          back[0].o["FLAGS"] & 0x80 != 0 and back[0].o["MODE"] == fg.CRUISE and back[0].st["A"] == back[-1].st["A"])
    t = run_named("pause-return")
    check("pause-return: pauses of 3, 5 and 7 epochs never lead to BANK", all(r.o["MODE"] != fg.BANK for r in t.rows))
    # the same statement for every level and every pause length, on the bare chip: 40 epochs at one tax code,
    # a pause of k epochs, then 12 epochs at the same code again
    bad = 0
    n = 0
    for grad, floor in ((0, fg.P["FLOOR_Q"]), (1, fg.P["FLOOR_T"])):
        for tax in range(floor + 1, 1024, 3):
            xl = km.pack_input({"TAX": tax, "TAXCUM": 300, "RES": 700, "DT": 1, "GRAD": grad})
            xq = km.pack_input({"TAX": 0, "TAXCUM": 300, "RES": 700, "DT": 1, "GRAD": grad})
            s0 = 0
            for _ in range(40):
                s0, _ = fg.step(s0, xl)
            s = s0
            for k in range(1, 70):
                s, _ = fg.step(s, xq)                       # one more quiet epoch
                q = s
                n += 1
                for _ in range(12):
                    q, y = fg.step(q, xl)
                    if (y >> 91) & 7 == fg.BANK:
                        bad += 1
                        break
    check(f"pause sweep: {n} combinations of level (every third code above the floor, both regimes) and pause "
          f"(1..69 epochs): a return at the old level never enters BANK", bad == 0)

    # drought: the reserve is released in tranches with a cooldown, and nothing is stranded
    t = run_named("drought")
    peak = max(r.reserve_after for r in t.rows)
    check(f"drought: the reserve drains ({100 * t.rows[-1].reserve_after / peak:.2f}% of its peak is left after 160 quiet epochs)",
          t.rows[-1].reserve_after < peak // 100)
    rest = [r for r in t.rows if r.s_before >> 24 & 7 == fg.REST and (r.s_before >> 40 & 7) >= 1]
    check("drought: while cooling down the release is exactly the floor leak", all(r.o["REL"] == fg.P["LEAK"] for r in rest) and len(rest) > 10)
    check("drought: DEFEND windows are 4 epochs, cooldowns 6",
          [fg.MODE_NAMES[r.o["MODE"]] for r in t.rows[65:76]] == ["DEFEND"] * 4 + ["REST"] * 6 + ["DEFEND"])

    # dust
    t = run_named("subdust")
    check("subdust: inflows below the floor never count as live flow", all(r.o["MODE"] == fg.IDLE for r in t.rows))
    t = run_named("dust")
    check("dust: sporadic $1-$4 buys are never banked as a surge for more than 4 epochs in a row",
          max((len(g) for g in "".join("B" if r.o["MODE"] == fg.BANK else "." for r in t.rows).split(".")), default=0) <= 4)

    # ratchet
    t = run_named("milestones")
    tiers = [r.o["TIER"] for r in t.rows]
    allow = {tier: next(r.o["T_ALLOW"] for r in t.rows if r.o["TIER"] == tier and r.o["MODE"] == fg.CRUISE) for tier in range(4)}
    check(f"milestones: tier steps 0,1,2,3 and the CRUISE allowance steps {allow}",
          sorted(set(tiers)) == [0, 1, 2, 3] and tiers == sorted(tiers)
          and [allow[i] for i in range(4)] == [fg.P["AL0"], fg.P["AL1"], fg.P["AL2"], fg.P["AL3"]])

    # ceiling
    t = run_named("whale")
    wh = max(t.rows, key=lambda r: r.inflow)
    check(f"whale: the allowance of the 3 OKB epoch is cut to exp8(CEIL) = {km.exp8(wh.o['CEIL']):.3e} wei by the chip's own "
          f"ceiling, no clamp", wh.routed.allow == km.exp8(wh.o["CEIL"]) and wh.routed.clamp == 0 and wh.o["MODE"] == fg.BANK)

    # graduation
    t = run_named("graduation")
    g = next(r for r in t.rows if r.grad)
    pre = [r for r in t.rows if not r.grad][-1]
    check("graduation: averages re-seeded on the first token settle, tier kept, allowance zero from then on",
          g.o["FLAGS"] & 0x10 != 0 and g.o["FLAGS"] & 0x80 != 0 and g.o["TIER"] == pre.o["TIER"]
          and all(r.routed.allow == 0 and r.o["T_ALLOW"] == 0 for r in t.rows if r.grad))

    # scale: multiplying every amount by a power of two shifts every code by a multiple of 8, so the mode
    # sequence is identical as long as readings stay above the floor and the reserve above RESMIN
    base = S["surge"]["flows"]
    seqs = []
    for k in (0, 4, 10):
        tr = run("scale", [v << k for v in base])
        seqs.append([r.o["MODE"] for r in tr.rows])
    check("scale: the surge scenario at x1, x16 and x1024 gives the same mode sequence", seqs[0] == seqs[1] == seqs[2])

    # hostile timing
    t = run_named("hostile-timing")
    check("hostile-timing: irregular gaps of 1..40 epochs never set a clamp bit and never lower the tier",
          t.max_clamp == 0 and all(b.o["TIER"] >= a.o["TIER"] for a, b in zip(t.rows, t.rows[1:])))

    # failed buys
    t = run_named("failed-buys")
    check("failed-buys: what the buy leg does not execute stays in the reserve and is offered again",
          t.total_in == t.total_allow + t.total_buy + t.rows[-1].reserve_after)

    # conservation everywhere
    tot_ok = True
    for n in S:
        t = run_named(n)
        if S[n].get("grad_epoch") is None:
            tot_ok &= t.total_in == t.total_allow + t.total_buy + t.rows[-1].reserve_after
    check("every scenario: inflow = allowance + bought + reserve, to the wei", tot_ok)

    ok = all(o for _, o, _ in out)
    if verbose:
        print("behaviour checks")
        for name, o, detail in out:
            print(f"  {'PASS' if o else 'FAIL'}  {name}{('  ' + detail) if detail else ''}")
        print("behaviour checks:", "PASS" if ok else "FAIL")
    return ok


# ----------------------------------------------------------------------------- cadence equivalence
# Definition (also in FLOW_GOVERNOR.md, "Cadence"). The reference keeper settles every epoch. Another
# keeper settles the same flow on a different schedule. A *common settle point* is an epoch at which
# both settle. The two are EQUIVALENT when all of the following hold:
#   E1  tier:   the allowance tier is identical at every common settle point (exact);
#   E2  clamps: neither run ever sets a clamp bit (exact);
#   E3  money:  at the end of the run the cumulative allowance differs by at most TOL_ALLOW points of
#               cumulative inflow, and the cumulative amount bought differs by at most TOL_BUY points;
#   E4  timing: at no fewer than TOL_MODE percent of the common settle points, the mode of the slower
#               keeper equals the mode of the reference keeper at some epoch within LAG epochs
#               (IDLE and CRUISE count as one mode: they route identically).
# E4 is only required on flows that are constant between changes (the DETERMINISTIC list) and for
# schedules that skip at most 3 epochs in a row; on noisy flows a slower keeper sees a smoother flow,
# so its BANK and DEFEND episodes legitimately differ and only E1..E3 are required.
# A spike shorter than the gap between settles (the SPIKE list: one epoch of tax 600 times the average)
# cannot be seen as a spike by the slower keeper. There only E1, E2 and the allowance half of E3 are
# required; the amount bought so far is reported, not asserted (everything not paid as allowance is
# bought eventually by both keepers; only the timing differs).
DETERMINISTIC = ["steady", "steady-small", "steady-large", "surge", "ramp", "drawdown", "crash", "drought",
                 "silence-return", "pause-return", "milestones", "graduation"]
NOISY = ["dust", "noisy", "noisy-dollars", "launch", "graduation-busy"]
SPIKE = ["whale"]
FAST = (2, 3, 4)
SLOW = (6, 8, 12)
TOL = {
    "fast": {"allow": 2.0, "buy": 6.0, "mode": 85.0},
    "slow": {"allow": 4.0, "buy": 10.0, "mode": None},
}


def _schedules():
    """name -> (class, factory(flows) -> settle_at)"""
    S = {}
    for k in FAST:
        S[f"every {k}"] = ("fast", lambda flows, k=k: (lambda e: e % k == 0), k + 2)
    for k in SLOW:
        S[f"every {k}"] = ("slow", lambda flows, k=k: (lambda e: e % k == 0), k + 2)

    def quiet_skip(flows, n=8):
        # settles whenever tax arrived in the epoch, otherwise every n-th epoch since its last settle
        last = [0]

        def f(e):
            if flows[e - 1] > 0 or e - last[0] >= n:
                last[0] = e
                return True
            return False
        return f
    S["skip quiet (8)"] = ("slow", quiet_skip, 10)

    def random_miss(flows, p=0.25, seed=5):
        rng = random.Random(seed)
        miss = [rng.random() < p for _ in flows]
        return lambda e: not miss[e - 1]
    S["miss 25%"] = ("fast", random_miss, 5)
    return S


def compare(flows: Sequence[int], name: str, settle_at, lag: int, grad_epoch=None) -> Dict[str, object]:
    base = run(name + "@1", flows, None, grad_epoch)
    by_epoch = {r.epoch: r for r in base.rows}
    t = run(name + "@x", flows, settle_at, grad_epoch)
    norm = lambda v: fg.CRUISE if v == fg.IDLE else v
    tier_ok, agree, common = True, 0, 0
    for r in t.rows:
        b = by_epoch.get(r.epoch)
        if b is None:
            continue
        common += 1
        tier_ok &= b.o["TIER"] == r.o["TIER"]
        near = {norm(by_epoch[e].o["MODE"]) for e in range(r.epoch - lag, r.epoch + lag + 1) if e in by_epoch}
        agree += norm(r.o["MODE"]) in near
    tin = max(1, base.total_in)
    return {"tier": tier_ok, "clamp": base.max_clamp | t.max_clamp, "common": common,
            "mode": 100.0 * agree / max(1, common),
            "allow": 100.0 * abs(t.total_allow - base.total_allow) / tin,
            "buy": 100.0 * abs(t.total_buy - base.total_buy) / tin,
            "settles": len(t.rows)}


def cadence_test(verbose: bool = True) -> bool:
    ok = True
    S = scenarios()
    scheds = _schedules()
    worst = {}
    if verbose:
        print("cadence equivalence: reference keeper (every epoch) versus other schedules")
        print(f"{'scenario':<16} {'schedule':<15} {'settles':>7} {'tier':>5} {'mode agree%':>11} {'allow d':>8} {'bought d':>8} clamp")
    for n in DETERMINISTIC + NOISY + SPIKE:
        for sname, (cls, factory, lag) in scheds.items():
            flows = S[n]["flows"]
            c = compare(flows, n, factory(flows), lag, S[n].get("grad_epoch"))
            tol = TOL[cls]
            need_mode = tol["mode"] is not None and n in DETERMINISTIC
            need_buy = n not in SPIKE
            good = (c["tier"] and c["clamp"] == 0 and c["allow"] <= tol["allow"]
                    and (not need_buy or c["buy"] <= tol["buy"])
                    and (not need_mode or c["mode"] >= tol["mode"]))
            ok &= good
            w = worst.setdefault(cls, {"allow": 0.0, "buy": 0.0, "mode": 100.0})
            w["allow"] = max(w["allow"], c["allow"])
            if need_buy:
                w["buy"] = max(w["buy"], c["buy"])
            if need_mode:
                w["mode"] = min(w["mode"], c["mode"])
            if verbose:
                print(f"{n:<16} {sname:<15} {c['settles']:>7} {str(c['tier']):>5} {c['mode']:>11.1f} "
                      f"{c['allow']:>8.2f} {c['buy']:>8.2f} {c['clamp']:>5}"
                      f"{'' if good else '   <-- outside tolerance'}")
    if verbose:
        for cls, w in worst.items():
            print(f"worst case, {cls} schedules: allowance {w['allow']:.2f} pts (limit {TOL[cls]['allow']}), "
                  f"bought {w['buy']:.2f} pts (limit {TOL[cls]['buy']})"
                  + (f", mode agreement on deterministic flows {w['mode']:.1f}% (limit {TOL[cls]['mode']})"
                     if TOL[cls]["mode"] is not None else ""))
        print("cadence test:", "PASS" if ok else "FAIL")
    return ok


# ----------------------------------------------------------------------------- main
def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("name", nargs="?")
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--cadence", action="store_true")
    ap.add_argument("--dump")
    ap.add_argument("--limit", type=int)
    a = ap.parse_args(argv)
    S = scenarios()
    if a.list:
        for n, sc in S.items():
            print(f"{n:<18} {sc['note']}")
        return 0
    if a.cadence:
        return 0 if cadence_test() else 1
    if a.name:
        t = run_named(a.name)
        print(S[a.name]["note"])
        print(table(t, a.limit))
        print(summary_line(t))
        w = find_witness(t)
        if w:
            print(f"witness: epochs {w[0].epoch} and {w[1].epoch} see the same input word and route differently")
        return 0
    bad: List[str] = []
    for n in S:
        t = run_named(n)
        print(summary_line(t))
        bad += check_invariants(t)
        if a.dump:
            os.makedirs(a.dump, exist_ok=True)
            with open(os.path.join(a.dump, f"{n}.txt"), "w") as f:
                f.write(S[n]["note"] + "\n" + table(t) + "\n" + summary_line(t) + "\n")
            with open(os.path.join(a.dump, f"{n}.trace.json"), "w") as f:
                json.dump({"name": n, "note": S[n]["note"],
                           "vectors": [{"epoch": r.epoch, "s": hex(r.s_before), "x": hex(r.x), "ns": hex(r.s_after),
                                        "y": hex(r.y)} for r in t.rows]}, f)
    print()
    okb = behaviour_checks()
    print()
    ok = cadence_test() and okb
    if bad:
        print("\nINVARIANT FAILURES:")
        for b in bad[:40]:
            print("  ", b)
    print("\nall scenario invariants hold" if not bad else f"\n{len(bad)} invariant failures")
    return 0 if (ok and not bad) else 1


if __name__ == "__main__":
    sys.exit(main())
