"""Glutton under the reference envelope: which clamps fire, and what is actually routed.

    chips/.venv-fg/bin/python chips/cells/glutton/demo.py            # summary on three flows
    chips/.venv-fg/bin/python chips/cells/glutton/demo.py -v         # per-epoch table

The chip bytes (glutton.tap, glutton512.tap) are evaluated with the TAP-20 evaluator of chips/rtl/test_fg.py
inside the revision-2 kernel model of chips/model/scenarios.py (clamps by chips/golden/kernel_model.route_tax,
buys sized on the simulated curve, the tax of the kernel's own buys returning as inflow). The Flow Governor is
run on the same flows for comparison. This is a shadow-run: no chain, no wallet.
"""
from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CHIPS = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(CHIPS, "model"))
sys.path.insert(0, os.path.join(CHIPS, "rtl"))

import flow_governor as fg  # noqa: E402
import scenarios as sc  # noqa: E402
import test_fg  # noqa: E402
from flow_governor import km  # noqa: E402

CLAMP_NAMES = [(km.K1T, "K1T"), (km.K1V, "K1V"), (km.K2, "K2"), (km.K2C, "K2C"), (km.K2L, "K2L"), (km.K3, "K3"),
               (km.K5, "K5"), (km.K2V, "K2V")]


def clamp_str(bits: int) -> str:
    return "+".join(n for b, n in CLAMP_NAMES if bits & b) or "-"


def chip_step(tap_path: str):
    """step(s, x) -> (ns, y) for a one-latch chip, from its TAP-20 bytes."""
    with open(tap_path, "rb") as f:
        data = f.read()
    recs = test_fg.parse_tap(data, 96)
    latch_d = [r[1] for r in recs if r[0] == "L"]
    assert len(latch_d) == 1

    def step(s: int, x: int):
        sig = [0, 1] + [(x >> i) & 1 for i in range(96)]
        for r in recs:
            sig.append(1 ^ (sig[r[1]] & sig[r[2]]) if r[0] == "N" else (s & 1))
        y = 0
        for j, b in enumerate(sig[len(sig) - 112:]):
            y |= b << j
        return sig[latch_d[0]], y
    return step


def unpack1(s: int):
    return {"HEARTBEAT": s & 1}


def run(name: str, flows, step) -> sc.Trace:
    """The revision-2 kernel model around a chip: echo and execution limits included."""
    t = sc.run(name, flows, step=step, env=fg.envelope(), mode=sc.REV2)
    for row in t.rows:
        row.st = {}                       # the latch fields of the Flow Governor mean nothing for another chip
    return t


def table(t: sc.Trace, limit: int = 24) -> str:
    L = [f"{'ep':>3} {'inflow':>10} | demanded: {'T_ALLOW':>7} {'T_BUY':>5} {'REL':>3} {'CEIL':>4} | "
         f"{'clampBits':>10} | effective: {'allow sh':>8} {'REL':>3} | {'allowance':>10} {'bought':>10} {'reserve':>10}"]
    for r in t.rows[:limit]:
        o = r.o
        L.append(f"{r.epoch:>3} {sc.fmt_amt(r.inflow):>10} |           {o['T_ALLOW']:>7} {o['T_BUY']:>5} {o['REL']:>3} "
                 f"{o['CEIL']:>4} | {clamp_str(r.routed.clamp):>10} |            {r.routed.shares[2]:>8} {r.routed.rel:>3} | "
                 f"{sc.fmt_amt(r.routed.allow):>10} {sc.fmt_amt(r.buy_executed):>10} {sc.fmt_amt(r.reserve_after):>10}")
    return "\n".join(L)


def main(argv=None) -> int:
    verbose = "-v" in (argv or sys.argv[1:])
    env = fg.envelope()
    print("reference envelope:", {k: getattr(env, k) for k in ("capT", "allowCumBps", "ceilMax", "relMax", "floorRel", "floorMin")})
    S = sc.scenarios()
    chips = [("glutton", chip_step(os.path.join(HERE, "glutton.tap"))),
             ("glutton512", chip_step(os.path.join(HERE, "glutton512.tap"))),
             ("flow-governor", fg.step)]
    flows = {
        "steady (0.005 OKB of tax per epoch, 60 epochs)": S["steady"]["flows"][:60],
        "whale (one epoch with 3 OKB of tax)": S["whale"]["flows"],
        "noisy-dollars (the reference token's likely life)": S["noisy-dollars"]["flows"][:300],
    }
    for label, fl in flows.items():
        print(f"\n== {label}")
        print(f"{'chip':<14} {'clamp bits seen':<16} {'allowance':>10} {'of tax':>7} {'of inflow':>9} {'bought':>10} "
              f"{'of tax':>7} {'left in reserve':>15} {'of tax':>7}")
        for name, step in chips:
            t = run(name, fl, step)
            k = t.kernel
            tax = max(1, k.market.outside_q)                 # what outside trading paid
            net = k.q_exec - k.q_echo                        # bought, net of the tax the kernel's own buys paid back
            seen = sorted({clamp_str(r.routed.clamp) for r in t.rows})
            print(f"{name:<14} {','.join(seen):<16} {sc.fmt_amt(t.total_allow):>10} {100 * t.total_allow / tax:>6.2f}% "
                  f"{100 * t.total_allow / max(1, t.total_in):>8.2f}% {sc.fmt_amt(net):>10} {100 * net / tax:>6.2f}% "
                  f"{sc.fmt_amt(t.rows[-1].reserve_after):>15} {100 * (tax - t.total_allow - net) / tax:>6.2f}%")
            if verbose and name != "flow-governor":
                print(table(t))
            # what the envelope promises, checked on every row
            for r in t.rows:
                assert r.routed.allow <= r.inflow * env.capT // 256, "allowance above capT"
                assert r.routed.allow <= km.exp8(env.ceilMax), "allowance above the envelope ceiling"
                assert r.routed.rel <= env.relMax and (r.reserve_before == 0 or r.routed.rel >= env.floorRel)
                assert r.routed.allow + r.routed.buy_share + r.routed.to_reserve == r.inflow
            assert not sc.check_books(t), "books"
            assert t.total_allow * 10000 <= t.total_in * env.allowCumBps, "lifetime cap"
            if name == "glutton":
                assert all(r.routed.clamp & km.K2 and r.routed.clamp & km.K3 for r in t.rows)
                assert not any(r.routed.clamp & (km.K1T | km.K5 | km.K2L) for r in t.rows)
            if name == "glutton512":
                assert all(r.routed.clamp & km.K1T and r.routed.clamp & km.K3 for r in t.rows)
                assert t.total_allow == 0
            if name == "flow-governor":
                assert t.max_clamp == 0
    print("\nGlutton demands the whole tax as allowance and the whole reserve every beat. Under the reference envelope:")
    print("  K2  clips its allowance share from 256 to capT = 48 (18.75% of inflow); the rest stays in the reserve;")
    print("      inflow includes the 3% buy tax of the kernel's own buys, which comes round again, so against the tax")
    print("      that outside trading paid the allowance can reach 18.75 / (1 - 0.03 * 0.8125) = 19.2%, never more;")
    print("  K2C clips the allowance amount to exp8(ceilMax) = 0.0338 OKB per settle when the inflow is large;")
    print("  K3  clips its release from 256 to relMax = 128 (half the reserve per settle), and a release can only buy and lock;")
    print("  K2L never fires (allowCumBps = 1875 is exactly capT / 256);  K5 never fires (it asks for more than the floor).")
    print("Glutton-512 sends a share group that sums to 512: K1T turns it into 100% reserve, so its allowance is zero;")
    print("the state still advances and the reserve still leaves through the clipped release.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
