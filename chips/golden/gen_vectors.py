"""Generate chips/golden/vectors.json from kernel_model.py. Deterministic (fixed seed).

Run:  python3 chips/golden/gen_vectors.py
All integers that may exceed 2**53 are written as decimal strings.
"""
from __future__ import annotations

import json
import os
import random
from dataclasses import asdict

import kernel_model as km

SEED = 20261004
HERE = os.path.dirname(os.path.abspath(__file__))


def s(x: int) -> str:
    return str(x)


def lg8_vectors(rng: random.Random):
    xs = set(range(0, 70))
    for e in range(0, 129):
        for d in (-1, 0, 1):
            v = (1 << e) + d
            if v >= 0:
                xs.add(v)
        for m in range(8, 16):                      # every bucket boundary of this octave
            v = (m << e) >> 3
            xs.update({v, max(0, v - 1), v + 1})
    for dec in range(0, 39):
        xs.add(10 ** dec)
    for _ in range(600):
        xs.add(rng.getrandbits(rng.randint(1, 128)))
    return [{"x": s(x), "code": km.lg8(x)} for x in sorted(xs)]


def exp8_vectors():
    return [{"code": c, "x": s(km.exp8(c))} for c in range(0, km.LG8_MAX + 1)]


def input_vectors(rng: random.Random):
    out = []
    specials = [
        {},                                                    # all zero
        {n: (1 << w) - 1 for n, _, w in km.INPUT_FIELDS if n != "ZERO"},   # all ones
        {"TAX": 425, "TAXCUM": 465, "RES": 437, "PROG": 12, "LOCK": 1, "DT": 1, "GRAD": 0},
        {"TAX": 0, "TAXCUM": 465, "RES": 437, "DT": 15, "GRAD": 1, "PROG": 255},
    ]
    for f in specials:
        w = km.pack_input(f)
        out.append({"fields": {n: f.get(n, 0) for n, _, _ in km.INPUT_FIELDS},
                    "word": s(w), "bytes": "0x" + km.word_to_bytes(w, km.IN_BITS).hex()})
    for _ in range(60):
        f = {n: rng.getrandbits(wd) for n, _, wd in km.INPUT_FIELDS if n != "ZERO"}
        f["ZERO"] = 0
        w = km.pack_input(f)
        out.append({"fields": f, "word": s(w), "bytes": "0x" + km.word_to_bytes(w, km.IN_BITS).hex()})
    return out


def output_vectors(rng: random.Random):
    out = []
    for _ in range(60):
        w = rng.getrandbits(km.OUT_BITS)
        out.append({"word": s(w), "bytes": "0x" + km.word_to_bytes(w, km.OUT_BITS).hex(),
                    "fields": km.unpack_output(w)})
    return out


def good_shares(rng: random.Random):
    a = rng.randint(0, 256)
    b = rng.randint(0, 256 - a)
    c = rng.randint(0, 256 - a - b)
    return a, b, c, 256 - a - b - c


def routing_vectors(rng: random.Random):
    out = []
    envs = [
        km.Envelope(),
        km.Envelope(capT=0, allowCumBps=0),
        km.Envelope(capT=256, capV=255, allowCumBps=9999, ceilMax=1023, relMax=256, floorRel=1, floorMin=0),
        km.Envelope(capT=48, allowCumBps=1875, ceilMax=440, relMax=128, floorRel=2, floorMin=425),
    ]
    for i in range(400):
        env = envs[i % len(envs)] if i < 200 else km.Envelope(
            capT=rng.randint(0, 256), capV=rng.randint(0, 255), allowCumBps=rng.randint(0, 9999),
            ceilMax=rng.choice([1023, rng.randint(0, 1023)]), relMax=(rm := rng.randint(1, 256)),
            floorRel=rng.randint(1, rm), floorMin=rng.randint(0, 425))
        kind = rng.random()
        if kind < 0.65:
            tb, th, ta, tr = good_shares(rng)
        elif kind < 0.85:                                   # malformed group
            tb, th, ta, tr = (rng.randint(0, 511) for _ in range(4))
        else:                                               # hostile: everything to allowance
            tb, th, ta, tr = 0, 0, 256, 0
        word = km.pack_output({
            "T_BUY": tb, "T_HOLD": th, "T_ALLOW": ta, "T_RES": tr,
            "V_BUY": rng.randint(0, 511), "V_HOLD": rng.randint(0, 511),
            "V_ALLOW": rng.randint(0, 511), "V_RES": rng.randint(0, 511),
            "REL": rng.choice([0, 0, 1, 2, 32, 64, 128, 256, rng.randint(0, 511)]),
            "CEIL": rng.choice([1023, 1023, rng.randint(0, 1023)]),
            "MODE": rng.randint(0, 7), "TIER": rng.randint(0, 3),
            "FLAGS": rng.randint(0, 255), "AUX": rng.randint(0, 255)})
        inflow = rng.choice([0, 0, 1, 255, 256, 10 ** 15, 10 ** 16, 5 * 10 ** 16, rng.getrandbits(rng.randint(1, 96))])
        reserve0 = rng.choice([0, 1, 10 ** 14, 10 ** 16, 10 ** 17, rng.getrandbits(rng.randint(1, 96))])
        prior = rng.getrandbits(rng.randint(1, 96))
        cum = prior + inflow
        paid = rng.choice([0, cum * env.allowCumBps // 10000, rng.randint(0, cum * env.allowCumBps // 10000)])
        r = km.route_tax(env, word, inflow, reserve0, cum, paid)
        assert r.allow + r.buy_share + r.to_reserve == inflow
        assert r.release <= reserve0 and r.allow >= 0 and r.to_reserve >= 0
        out.append({
            "envelope": asdict(env), "word": s(word),
            "bytes": "0x" + km.word_to_bytes(word, km.OUT_BITS).hex(),
            "inflow": s(inflow), "reserve0": s(reserve0), "cumInflow": s(cum), "allowPaidCum": s(paid),
            "expect": {"clamp": r.clamp, "allow": s(r.allow), "buyShare": s(r.buy_share),
                       "release": s(r.release), "buyDecided": s(r.buy_decided),
                       "toReserve": s(r.to_reserve), "reserveAfter": s(r.reserve_after),
                       "shares": list(r.shares), "rel": r.rel}})
    return out


def misc_vectors(rng: random.Random):
    prog = []
    for _ in range(40):
        sellable = rng.choice([0, 1, 800_000_000 * 10 ** 18, rng.getrandbits(100) + 1])
        sold = rng.randint(0, sellable) if sellable else 0
        for g in (False, True):
            prog.append({"sold": s(sold), "sellable": s(sellable), "graduated": g,
                         "code": km.prog_code(sold, sellable, g)})
    lock = []
    for _ in range(30):
        total = 10 ** 27
        locked = rng.choice([0, 1, total // 255, total // 2, total, rng.randint(0, total)])
        lock.append({"locked": s(locked), "totalSupply": s(total), "code": km.lock_code(locked, total)})
    dt = [{"epochNow": a + d, "lastEpoch": a, "code": km.dt_code(a + d, a)}
          for a in (0, 7, 1000) for d in (1, 2, 14, 15, 16, 500)]
    st = []
    for n_state in (1, 8, 64, 65, 255, 256):
        bits = rng.getrandbits(n_state)
        st.append({"nState": n_state, "bits": s(bits), "bytes32": "0x" + km.state_to_bytes32(bits, n_state).hex()})
    fb = [{"envelope": asdict(e), "fbAllow": a, "word": s(km.fallback_word(e, a)),
           "bytes": "0x" + km.word_to_bytes(km.fallback_word(e, a), km.OUT_BITS).hex()}
          for e, a in ((km.Envelope(), 0), (km.Envelope(), 32), (km.Envelope(capT=256, relMax=256), 256))]
    return {"prog": prog, "lock": lock, "dt": dt, "state": st, "fallback": fb}


def main():
    rng = random.Random(SEED)
    doc = {
        "format": "covenant-golden/1",
        "seed": SEED,
        "layout": {
            "inBits": km.IN_BITS, "outBits": km.OUT_BITS,
            "input": [{"name": n, "offset": o, "width": w} for n, o, w in km.INPUT_FIELDS],
            "output": [{"name": n, "offset": o, "width": w} for n, o, w in km.OUTPUT_FIELDS],
            "clampBits": {"K1T": km.K1T, "K1V": km.K1V, "K2": km.K2, "K2C": km.K2C,
                          "K2L": km.K2L, "K3": km.K3, "K5": km.K5, "K2V": km.K2V},
        },
        "lg8": lg8_vectors(rng),
        "exp8": exp8_vectors(),
        "inputs": input_vectors(rng),
        "outputs": output_vectors(rng),
        "routing": routing_vectors(rng),
        **misc_vectors(rng),
    }
    path = os.path.join(HERE, "vectors.json")
    with open(path, "w") as f:
        json.dump(doc, f, indent=1, sort_keys=True)
        f.write("\n")
    print("wrote", path, {k: (len(v) if isinstance(v, list) else "-") for k, v in doc.items()})


if __name__ == "__main__":
    main()
