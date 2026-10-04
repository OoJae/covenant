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


# ----------------------------------------------------------------------------- revision 2
# Everything below draws from its own generator, so the sections above stay byte-identical.

REF_ENV = dict(capT=48, capV=0, allowCumBps=1875, ceilMax=440, relMax=128, floorRel=2, floorMin=1)


def _route_vec(env: km.Envelope, fields: dict, inflow: int, reserve0: int, cum: int, paid: int,
               graduated: bool, note: str = ""):
    word = km.pack_output(fields)
    r = km.route_tax(env, word, inflow, reserve0, cum, paid, graduated)
    assert r.allow + r.buy_share + r.to_reserve == inflow and r.release <= reserve0
    v = {
        "envelope": asdict(env), "word": s(word),
        "bytes": "0x" + km.word_to_bytes(word, km.OUT_BITS).hex(), "graduated": graduated,
        "inflow": s(inflow), "reserve0": s(reserve0), "cumInflow": s(cum), "allowPaidCum": s(paid),
        "expect": {"clamp": r.clamp, "allow": s(r.allow), "buyShare": s(r.buy_share),
                   "release": s(r.release), "buyDecided": s(r.buy_decided),
                   "toReserve": s(r.to_reserve), "reserveAfter": s(r.reserve_after),
                   "shares": list(r.shares), "rel": r.rel}}
    if note:
        v["note"] = note
    return v


def routing_boundary_vectors():
    """Directed cases at the edges the random routing vectors miss."""
    ref = km.Envelope(**REF_ENV)
    e17 = 10 ** 17
    cm = km.exp8(ref.ceilMax)                      # 33776997205278720
    out = []

    def w(tb, ta, tr, rel=2, ceil=1023, th=0):
        return {"T_BUY": tb, "T_HOLD": th, "T_ALLOW": ta, "T_RES": tr, "REL": rel, "CEIL": ceil}

    # the chip's own CEIL acts before K2C and is not a clamp
    out.append(_route_vec(ref, w(160, 32, 64, ceil=432), 5 * e17, 0, 6 * e17, 0, False, "chip CEIL below ceilMax: cut, no clamp"))
    out.append(_route_vec(ref, w(144, 48, 64, ceil=440), 10 * e17, 0, 10 * e17, 0, False, "chip CEIL equal to ceilMax: cut, no clamp"))
    # K2C at the equality point and one unit above it
    at = cm * 256 // 48
    while at * 48 // 256 < cm:
        at += 1
    assert at * 48 // 256 == cm
    out.append(_route_vec(ref, w(144, 48, 64), at, 0, at, 0, False, "allow == exp8(ceilMax): no clamp"))
    above = at
    while above * 48 // 256 == cm:
        above += 1
    out.append(_route_vec(ref, w(144, 48, 64), above, 0, above, 0, False, "allow one step above exp8(ceilMax): K2C"))
    # CEIL == 0 is a ceiling of zero, not "none"
    out.append(_route_vec(ref, w(144, 48, 64, ceil=0), e17, 0, e17, 0, False, "CEIL 0 means no allowance at all"))
    # K2L: the room is floored at zero when more was paid than the cap allows
    out.append(_route_vec(ref, w(144, 48, 64), 10 ** 16, 0, 10 * e17, 2 * e17, False, "allowPaidCum above the cap: room 0, K2L"))
    out.append(_route_vec(ref, w(192, 0, 64), 10 ** 16, 0, 10 * e17, 2 * e17, False, "same books, chip asks for none: no clamp"))
    out.append(_route_vec(ref, w(144, 48, 64), 10 ** 16, 0, 10 ** 16, 10 ** 30, False, "allowPaidCum far above cumInflow"))
    # K5 at the floor edge: floorMin is a code, compared with lg8(reserve0)
    for fm in (1, 9, 13, 400, 425):
        env = km.Envelope(**{**REF_ENV, "floorMin": fm})
        edge = km.exp8(fm)
        for r0 in sorted({0, 1, max(0, edge - 1), edge, edge + 1}):
            out.append(_route_vec(env, w(192, 0, 64, rel=0), 0, r0, 10 ** 18, 0, False, f"floorMin {fm}, reserve0 {r0}, REL 0"))
            out.append(_route_vec(env, w(192, 0, 64, rel=2), 0, r0, 10 ** 18, 0, False, f"floorMin {fm}, reserve0 {r0}, REL at the floor"))
    # share groups: every share <= 256 and the sum exactly 256; nothing modulo 256 or 512
    for tb, th, ta, tr in ((255, 0, 0, 0), (257, 0, 0, 0), (256, 0, 0, 256), (0, 0, 0, 0), (128, 128, 128, 128),
                           (511, 1, 0, 0), (256, 256, 256, 256), (0, 0, 256, 0), (0, 256, 0, 0), (300, 0, 0, 468)):
        out.append(_route_vec(ref, w(tb, ta, tr, th=th), e17, e17, e17, 0, False, f"shares ({tb},{th},{ta},{tr})"))
    # exactly at capT, relMax; one above
    out.append(_route_vec(ref, w(208, 48, 0, rel=128), e17, e17, e17, 0, False, "T_ALLOW == capT, REL == relMax"))
    out.append(_route_vec(ref, w(207, 49, 0, rel=129), e17, e17, e17, 0, False, "one above each: K2 and K3"))
    # zero inflow, zero reserve
    out.append(_route_vec(ref, w(160, 32, 64), 0, 0, 0, 0, False, "nothing at all"))
    # the widest amounts the kernel can hold
    big = km.AMOUNT_MAX
    out.append(_route_vec(ref, w(144, 48, 64, rel=128), big, big, big, 0, False, "2^128 - 1 everywhere"))
    out.append(_route_vec(km.Envelope(capT=128, allowCumBps=5000, ceilMax=1023, relMax=256, floorRel=1, floorMin=1),
                          w(128, 128, 0, rel=256), big, big, big, 0, False, "2^128 - 1, loosest envelope the factory accepts"))
    return out


def routing_graduated_vectors(rng: random.Random):
    """Kernel v1 after graduation: no allowance; the T_ALLOW share joins the reserve; no K2, K2C, K2L."""
    out = []
    envs = [km.Envelope(**REF_ENV), km.Envelope(),
            km.Envelope(capT=128, allowCumBps=5000, ceilMax=1023, relMax=256, floorRel=1, floorMin=1)]
    for i in range(120):
        env = envs[i % len(envs)]
        kind = rng.random()
        if kind < 0.7:
            tb, th, ta, tr = good_shares(rng)
        elif kind < 0.85:
            tb, th, ta, tr = (rng.randint(0, 511) for _ in range(4))
        else:
            tb, th, ta, tr = 0, 0, 256, 0
        fields = {"T_BUY": tb, "T_HOLD": th, "T_ALLOW": ta, "T_RES": tr,
                  "V_BUY": rng.randint(0, 511), "V_HOLD": rng.randint(0, 511),
                  "V_ALLOW": rng.randint(0, 511), "V_RES": rng.randint(0, 511),
                  "REL": rng.choice([0, 1, 2, 64, 128, 256, rng.randint(0, 511)]),
                  "CEIL": rng.choice([1023, 0, rng.randint(0, 1023)]),
                  "MODE": rng.randint(0, 7), "TIER": rng.randint(0, 3),
                  "FLAGS": rng.randint(0, 255), "AUX": rng.randint(0, 255)}
        inflow = rng.choice([0, 1, 255, 10 ** 21, 10 ** 24, rng.getrandbits(rng.randint(1, 100))])
        reserve0 = rng.choice([0, 1, 10 ** 20, 10 ** 24, rng.getrandbits(rng.randint(1, 100))])
        cum = rng.getrandbits(rng.randint(1, 100)) + inflow
        paid = rng.choice([0, rng.getrandbits(90)])
        v = _route_vec(env, fields, inflow, reserve0, cum, paid, True)
        assert v["expect"]["allow"] == "0" and v["expect"]["clamp"] & (km.K2 | km.K2C | km.K2L) == 0
        out.append(v)
    return out


def buy_vectors(rng: random.Random):
    """Buy sizing. Curves are states an IGNIX curve can be in: a fresh curve moved by net buys."""
    C, D = 800_000_000 * 10 ** 18, 200_000_000 * 10 ** 18
    T0 = C * C // (C - D)

    def curve_state(graduation: int, raised_net: int):
        E0 = graduation * (T0 - C) // C
        vq = E0 + raised_net
        vt = km.ceil_div(E0 * T0, vq)
        return vq, vt, T0 - vt

    cap, mng, out_, buy, v2 = [], [], [], [], []
    for _ in range(60):
        q = rng.choice([0, 1, 10 ** 15, 28333333333333333333, 113 * 10 ** 18, rng.getrandbits(rng.randint(1, 120))])
        f = rng.choice([200, 25, 0, rng.randint(0, 2000)])
        tbuy, tsell = rng.choice([(300, 300), (100, 100), (0, 0), (1000, 1000), (rng.randint(0, 1000), rng.randint(0, 1000))])
        capT = rng.choice([0, 48, 64, 128, 256, rng.randint(0, 256)])
        cap.append({"quoteReserve": s(q), "roundTripFeeBps": f, "taxBuyBps": tbuy, "taxSellBps": tsell, "capT": capT,
                    "cap": s(km.impact_cap(q, f, tbuy, tsell, capT))})
    grads = [85 * 10 ** 18, 8000 * 10 ** 6, 10 ** 12]
    for i in range(80):
        g = grads[i % len(grads)]
        raised = rng.choice([0, 1, g // 1000, g // 2, g - 1, rng.randint(0, g)])
        vq, vt, sold = curve_state(g, raised)
        fee, tax = 100, rng.choice([300, 100, 0, 1000, rng.randint(0, 1000)])
        m = km.max_non_graduating_buy(vq, vt, sold, C, fee, tax)
        if m:
            assert km.curve_out(vq, vt, fee, tax, m) < C - sold                    # leaves at least one unit
            assert km.curve_out(vq, vt, fee, tax, m + 1) >= C - sold               # one wei more would cross
        mng.append({"vQuote": s(vq), "vToken": s(vt), "sold": s(sold), "sellable": s(C),
                    "buyFeeBps": fee, "taxBuyBps": tax, "max": s(m)})
        qin = rng.choice([0, 1, 10 ** 12, 10 ** 15, 5 * 10 ** 17, m // 2 if m else 0, m])
        if qin <= m:
            out_.append({"vQuote": s(vq), "vToken": s(vt), "buyFeeBps": fee, "taxBuyBps": tax,
                         "quoteIn": s(qin), "tokensOut": s(km.curve_out(vq, vt, fee, tax, qin))})
        decided = rng.choice([0, 1, 10 ** 13, 10 ** 16, 10 ** 18, 50 * 10 ** 18, rng.getrandbits(rng.randint(1, 100))])
        capT = rng.choice([48, 64, 0, 128])
        tsell = rng.choice([tax, 300, 0])
        amount, mout, shrunk = km.curve_buy(decided, vq, vt, sold, C, fee, 100, tax, tsell, capT)
        buy.append({"decided": s(decided), "vQuote": s(vq), "vToken": s(vt), "sold": s(sold), "sellable": s(C),
                    "buyFeeBps": fee, "sellFeeBps": 100, "taxBuyBps": tax, "taxSellBps": tsell, "capT": capT,
                    "amount": s(amount), "minTokensOut": s(mout), "shrunk": shrunk})
    # states the Manager cannot be in must not revert either
    for vq, vt, sold, sellable in ((1, 1, 0, 1), (10 ** 18, 10 ** 18, 5, 5), (10 ** 18, 10 ** 18, 0, 2 * 10 ** 18), (1, 10 ** 30, 0, 10 ** 29)):
        mng.append({"vQuote": s(vq), "vToken": s(vt), "sold": s(sold), "sellable": s(sellable),
                    "buyFeeBps": 100, "taxBuyBps": 300, "max": s(km.max_non_graduating_buy(vq, vt, sold, sellable, 100, 300))})
    for _ in range(60):
        rin = rng.choice([0, 85 * 10 ** 18, rng.getrandbits(rng.randint(1, 112))])
        rout = rng.choice([0, 200_000_000 * 10 ** 18, rng.getrandbits(rng.randint(1, 112))])
        ain = rng.choice([0, 1, 10 ** 15, 10 ** 18, rng.getrandbits(rng.randint(1, 100))])
        tax = rng.choice([300, 0, 1000, 10000, rng.randint(0, 1000)])
        v2.append({"amountIn": s(ain), "reserveIn": s(rin), "reserveOut": s(rout), "taxBuyBps": tax,
                   "netOut": s(km.v2_net_out(ain, rin, rout, tax))})
    return {"impactCap": cap, "maxNonGraduatingBuy": mng, "curveOut": out_, "curveBuy": buy, "v2NetOut": v2}


def edge_vectors():
    return {
        "lock": [{"locked": s(a), "totalSupply": s(t), "code": km.lock_code(a, t)}
                 for a, t in ((0, 0), (5, 0), (10 ** 27, 10 ** 27), (2 * 10 ** 27, 10 ** 27), (km.AMOUNT_MAX, 10 ** 27), (1, km.AMOUNT_MAX))],
        "prog": [{"sold": s(a), "sellable": s(b), "graduated": g, "code": km.prog_code(a, b, g)}
                 for a, b, g in ((0, 0, False), (0, 0, True), (5, 0, False), (10, 10, False), (11, 10, False), (km.AMOUNT_MAX, km.AMOUNT_MAX, False))],
        "lg8": [{"x": s(x), "code": km.lg8(x)} for x in (km.AMOUNT_MAX, km.AMOUNT_MAX - 1, 1 << 127, (1 << 127) - 1, 1 << 200, (1 << 256) - 1)],
        "fallbackGraduated": [
            (lambda e, a: {"envelope": asdict(e), "fbAllow": a, "word": s(km.fallback_word(e, a)),
                           "expect": _route_vec(e, km.unpack_output(km.fallback_word(e, a)), 10 ** 24, 10 ** 23, 10 ** 25, 0, True)["expect"]})(
                km.Envelope(**REF_ENV), 8)],
    }


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
    rng2 = random.Random(SEED + 2)
    doc["format"] = "covenant-golden/2"
    doc["revision2"] = {
        "routingBoundary": routing_boundary_vectors(),
        "routingGraduated": routing_graduated_vectors(rng2),
        "buy": buy_vectors(rng2),
        "edges": edge_vectors(),
    }
    path = os.environ.get("COVENANT_VECTORS_OUT") or os.path.join(HERE, "vectors.json")
    with open(path, "w") as f:
        json.dump(doc, f, indent=1, sort_keys=True)
        f.write("\n")
    print("wrote", path, {k: (len(v) if isinstance(v, list) else "-") for k, v in doc.items()})
    r2 = doc["revision2"]
    print("revision2:", {"routingBoundary": len(r2["routingBoundary"]), "routingGraduated": len(r2["routingGraduated"]),
                         **{"buy." + k: len(v) for k, v in r2["buy"].items()},
                         **{"edges." + k: len(v) for k, v in r2["edges"].items()}})


if __name__ == "__main__":
    main()
