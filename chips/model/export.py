"""Write the Flow Governor artefacts that other parts of the project read.

    chips/.venv-fg/bin/python chips/model/export.py

  chips/out/fg.fields.json     latch / field map for the website (latch table, die shot) and the tools
  chips/out/fg.vectors.json    beats (state, inputs, newState, outputs) from the MODEL, in the TAP-20 vectors
                               shape; `tapc sim chips/out/fg.tap --check chips/out/fg.vectors.json` replays them
                               on the bytes, and the kernel tests can replay them through `step`
  chips/out/scenarios/*.txt    per-epoch tables of every scenario (model + revision-2 kernel: echo and
                               execution limits included)
  chips/out/scenarios/*.trace.json   the same runs as (s, x, ns, y) plus the routed amounts
  chips/out/fg.scenarios.json  the totals of every scenario under the revision-2 kernel and under the idealised
                               one (no echo, every buy executes in full), side by side
"""
from __future__ import annotations

import json
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CHIPS = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import flow_governor as fg  # noqa: E402
import scenarios as sc  # noqa: E402


def hb(v: int, nbits: int) -> str:
    return v.to_bytes((nbits + 7) // 8, "little").hex()


def stringify(v):
    """Amounts exceed 2^53: write every integer above that as a decimal string."""
    if isinstance(v, dict):
        return {k: stringify(x) for k, x in v.items()}
    if isinstance(v, int) and not isinstance(v, bool) and abs(v) >= 1 << 53:
        return str(v)
    if isinstance(v, float):
        return round(v, 4)
    return v


def main() -> int:
    out = os.path.join(CHIPS, "out")
    os.makedirs(os.path.join(out, "scenarios"), exist_ok=True)

    with open(os.path.join(out, "fg.fields.json"), "w", encoding="utf-8") as f:
        json.dump(fg.fields_json(), f, indent=1)
        f.write("\n")

    beats = []
    both = {}
    S = sc.scenarios()
    for name, sdef in S.items():
        t = sc.run_named(name, mode=sc.REV2)
        both[name] = {"note": sdef["note"], "revision2": stringify(sc.summary(t)),
                      "idealised": stringify(sc.summary(sc.run_named(name, mode=sc.IDEAL)))}
        with open(os.path.join(out, "scenarios", f"{name}.txt"), "w", encoding="utf-8") as f:
            f.write(sdef["note"] + "\n\n" + sc.table(t) + "\n\n" + sc.summary_line(t) + "\n")
        with open(os.path.join(out, "scenarios", f"{name}.trace.json"), "w", encoding="utf-8") as f:
            json.dump({"name": name, "note": sdef["note"], "kernel": t.mode.label, "envelope": fg.ENV,
                       "summary": both[name]["revision2"],
                       "rows": [{"epoch": r.epoch, "dt": r.dt, "grad": r.grad, "inflow": str(r.inflow),
                                 "echo": str(r.echo), "recordFlags": r.flags,
                                 "state": hb(r.s_before, 64), "inputs": hb(r.x, 96),
                                 "newState": hb(r.s_after, 64), "outputs": hb(r.y, 112),
                                 "mode": None if r.flags & sc.F_FALLBACK else fg.MODE_NAMES[r.o["MODE"]],
                                 "tier": None if r.flags & sc.F_FALLBACK else r.o["TIER"],
                                 "shares": [r.o["T_BUY"], r.o["T_HOLD"], r.o["T_ALLOW"], r.o["T_RES"]],
                                 "rel": r.o["REL"], "ceil": r.o["CEIL"],
                                 "flags": "fallback word" if r.flags & sc.F_FALLBACK else fg.flags_str(r.o["FLAGS"]),
                                 "clampBits": r.routed.clamp, "allow": str(r.routed.allow),
                                 "buyDecided": str(r.routed.buy_decided), "buyExecuted": str(r.buy_executed),
                                 "tokensOut": str(r.tokens_out), "nativeIn": str(r.native_in),
                                 "reserveBefore": str(r.reserve_before), "reserveAfter": str(r.reserve_after)}
                                for r in t.rows]}, f)
        for r in t.rows:
            if r.flags & sc.F_FALLBACK:
                continue                       # the chip was not stepped in a fallback settle
            beats.append({"kind": f"scenario:{name}", "state": hb(r.s_before, 64), "inputs": hb(r.x, 96),
                          "newState": hb(r.s_after, 64), "outputs": hb(r.y, 112)})
    with open(os.path.join(out, "fg.scenarios.json"), "w", encoding="utf-8") as f:
        json.dump({"format": "covenant-scenarios/1", "chip": fg.P["name"],
                   "source": "chips/model/scenarios.py",
                   "kernels": {"revision2": "kernel v1 as in chips/INTERFACE.md revision 2: the tax of the kernel's own "
                                            "buys returns as inflow, buys are sized on a simulated curve and pair",
                               "idealised": "no echo, every decided buy executes in full"},
                   "amounts": "integers as decimal strings: wei of OKB on the curve, token base units after graduation",
                   "scenarios": both}, f, indent=1)
        f.write("\n")
    rng = random.Random(20261004)
    for _ in range(2000):
        s, x = rng.getrandbits(64), rng.getrandbits(96)
        ns, y = fg.step(s, x)
        beats.append({"kind": "uniform", "state": hb(s, 64), "inputs": hb(x, 96), "newState": hb(ns, 64),
                      "outputs": hb(y, 112)})
    with open(os.path.join(out, "fg.vectors.json"), "w", encoding="utf-8") as f:
        json.dump({"format": "covenant-chip-vectors/1", "chip": fg.P["name"], "nIn": 96, "nOut": 112, "nState": 64,
                   "source": "chips/model/flow_governor.py (the model, not the netlist)",
                   "packing": "hex of the TAP-20 byte string: bit i of a vector is bit (i mod 8) of byte i / 8",
                   "beats": beats}, f)
        f.write("\n")
    print(f"wrote fg.fields.json, fg.scenarios.json, fg.vectors.json ({len(beats)} beats) and {len(S)} scenario "
          f"tables under {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
