"""Generate chips/golden/vectors_v2.json for kernel v2. Deterministic (fixed seed).

    python3 chips/golden/gen_vectors_v2.py

A fresh differential on another seed (write elsewhere; the shipped files are the default seed's):

    V2_SEED=424242017 COVENANT_VECTORS_V2_OUT=/tmp/v.json COVENANT_SETTLES_V2_OUT=/tmp/s.jsonl \
        python3 chips/golden/gen_vectors_v2.py

Sections:
  shift       the quote shift and how it was derived (kernel_model_v2)
  lg8s        lg8(x << s) for amounts and shifts
  exp8s       exp8(c) >> s for every code, for the shifts kernel v2 uses
  routing     route_tax_v2 on random and boundary cases, both regimes, several shifts
  settles     random event sequences on the test world of contracts/core-v2 (world_v2.py) with the
              expected record, books and balances after every settle (the differential test). They are
              written one per line to vectors_v2_settles.jsonl; vectors_v2.json holds their count and hash.

vectors.json (kernel v1) is not read for anything but the shift-0 self-check and is never written.
Every integer is a decimal string.
"""
from __future__ import annotations

import hashlib
import json
import os
import random
from dataclasses import asdict

import kernel_model as km
import kernel_model_v2 as km2
import world_v2 as wv

SEED = int(os.environ.get("V2_SEED", "20261006"))  # the shipped files use the default; another seed for a fresh run
HERE = os.path.dirname(os.path.abspath(__file__))
T0 = 1_791_000_000                     # contracts/core-v2/test/BaseV2.t.sol warps here before building a world


def s(x: int) -> str:
    return str(x)


def b12(word: int) -> int:
    """bytes12 of an input word, read as a big-endian integer (what uint96(bytes12) gives in Solidity)."""
    return int.from_bytes(km.word_to_bytes(word, km.IN_BITS), "big")


def b14(word: int) -> int:
    return int.from_bytes(km.word_to_bytes(word, km.OUT_BITS), "big")


def b32(bits: int, n_state: int) -> int:
    return int.from_bytes(km.state_to_bytes32(bits, n_state), "big")


# ----------------------------------------------------------------------------- codes

def lg8s_vectors(rng: random.Random):
    xs = set(range(0, 40))
    for e in range(0, 129):
        for d in (-1, 0, 1):
            if (1 << e) + d >= 0:
                xs.add((1 << e) + d)
    for dec in range(0, 39):
        xs.add(10 ** dec)
    for usd in (1, 500_000, 1_000_000, 3_000_000, 8_000 * 10 ** 6, 1_048_575, 1_048_576, 3_932_160):
        xs.update({usd - 1, usd, usd + 1})
    for _ in range(200):
        xs.add(rng.getrandbits(rng.randint(1, 128)))
    out = []
    for x in sorted(xs):
        x = min(x, km.AMOUNT_MAX)
        for sh in (0, km2.QUOTE_SHIFT, rng.randint(0, km2.MAX_SHIFT)):
            out.append({"x": s(x), "s": sh, "code": km2.lg8s(x, sh)})
    return out


def exp8s_vectors():
    return [{"code": c, "s": sh, "x": s(km2.exp8s(c, sh))}
            for sh in (km2.QUOTE_SHIFT, 20, km2.MAX_SHIFT) for c in range(0, km.LG8_MAX + 1)]


# ----------------------------------------------------------------------------- routing

def good_shares(rng):
    a = rng.randint(0, 256)
    b = rng.randint(0, 256 - a)
    c = rng.randint(0, 256 - a - b)
    return a, b, c, 256 - a - b - c


def _route(env: km.Envelope, fields: dict, inflow: int, reserve0: int, cum: int, paid: int, grad: bool, sh: int,
           note: str = ""):
    word = km.pack_output(fields)
    r = km2.route_tax_v2(env, word, inflow, reserve0, cum, paid, grad, sh)
    assert r.allow + r.buy_share + r.to_reserve == inflow and r.release <= reserve0
    if grad:
        assert r.allow == 0
    v = {"envelope": asdict(env), "word": s(word), "graduated": grad, "shift": sh,
         "inflow": s(inflow), "reserve0": s(reserve0), "cumInflow": s(cum), "allowPaidCum": s(paid),
         "expect": {"clamp": r.clamp, "allow": s(r.allow), "buyShare": s(r.buy_share), "release": s(r.release),
                    "buyDecided": s(r.buy_decided), "toReserve": s(r.to_reserve),
                    "reserveAfter": s(r.reserve_after), "shares": list(r.shares), "rel": r.rel}}
    if note:
        v["note"] = note
    return v


REF = dict(capT=48, capV=0, allowCumBps=1875, ceilMax=440, relMax=128, floorRel=2, floorMin=1)


def routing_vectors(rng: random.Random):
    out = []
    envs = [km.Envelope(**REF), km.Envelope(), km.Envelope(capT=0, allowCumBps=0),
            km.Envelope(capT=128, allowCumBps=5000, ceilMax=1023, relMax=256, floorRel=1, floorMin=1),
            km.Envelope(capT=64, allowCumBps=2500, ceilMax=300, relMax=128, floorRel=2, floorMin=425)]
    for i in range(3000):
        env = envs[i % len(envs)] if i < 1500 else km.Envelope(
            capT=rng.randint(0, 128), capV=rng.randint(0, 255), allowCumBps=rng.randint(0, 5000),
            ceilMax=rng.choice([1023, rng.randint(0, 1023), rng.randint(250, 480)]),
            relMax=(rm := rng.randint(1, 256)), floorRel=rng.randint(1, rm), floorMin=rng.randint(1, 425))
        kind = rng.random()
        if kind < 0.65:
            tb, th, ta, tr = good_shares(rng)
        elif kind < 0.85:
            tb, th, ta, tr = (rng.randint(0, 511) for _ in range(4))
        else:
            tb, th, ta, tr = 0, 0, 256, 0
        fields = {"T_BUY": tb, "T_HOLD": th, "T_ALLOW": ta, "T_RES": tr,
                  "V_BUY": rng.randint(0, 511), "V_HOLD": rng.randint(0, 511),
                  "V_ALLOW": rng.randint(0, 511), "V_RES": rng.randint(0, 511),
                  "REL": rng.choice([0, 0, 1, 2, 32, 64, 128, 256, rng.randint(0, 511)]),
                  "CEIL": rng.choice([1023, 1023, rng.randint(0, 1023), rng.randint(255, 480)]),
                  "MODE": rng.randint(0, 7), "TIER": rng.randint(0, 3),
                  "FLAGS": rng.randint(0, 255), "AUX": rng.randint(0, 255)}
        grad = rng.random() < 0.25
        sh = 0 if grad else rng.choice([km2.QUOTE_SHIFT] * 6 + [0, rng.randint(0, km2.MAX_SHIFT)])
        # USD₮0-sized amounts on the curve, token-sized after graduation, and anything at all
        if grad:
            inflow = rng.choice([0, 1, 10 ** 21, 10 ** 24, rng.getrandbits(rng.randint(1, 100))])
            reserve0 = rng.choice([0, 1, 10 ** 22, rng.getrandbits(rng.randint(1, 100))])
        else:
            inflow = rng.choice([0, 1, 500_000, 3 * 10 ** 6, 10 ** 8, 10 ** 10, rng.getrandbits(rng.randint(1, 60)),
                                 rng.getrandbits(rng.randint(1, 128))])
            reserve0 = rng.choice([0, 1, 1_048_575, 1_048_576, 10 ** 7, rng.getrandbits(rng.randint(1, 48)),
                                   rng.getrandbits(rng.randint(1, 128))])
        inflow, reserve0 = min(inflow, km.AMOUNT_MAX), min(reserve0, km.AMOUNT_MAX)
        cum = min(km.AMOUNT_MAX, inflow + rng.getrandbits(rng.randint(1, 64)))
        cap = cum * env.allowCumBps // 10000
        paid = rng.choice([0, cap, rng.randint(0, cap) if cap else 0, cap + 5])
        out.append(_route(env, fields, inflow, reserve0, cum, paid, grad, sh))
    return out


def routing_boundary_vectors():
    """Where the shift matters: the chip's CEIL and ceilMax around the 2^33 boundary, floorMin at the
    shifted threshold, zero amounts, the widest amounts."""
    out = []
    ref = km.Envelope(**REF)
    sh = km2.QUOTE_SHIFT

    def w(tb, ta, tr, rel=2, ceil=1023, th=0):
        return {"T_BUY": tb, "T_HOLD": th, "T_ALLOW": ta, "T_RES": tr, "REL": rel, "CEIL": ceil}

    # every chip ceiling from 250 to 300 (exp8(c) >> 33 is 0 below 265) and ceilMax the same
    for c in range(250, 301):
        out.append(_route(ref, w(128, 48, 80, ceil=c), 10 ** 9, 0, 10 ** 10, 0, False, sh, f"CEIL {c}"))
        env = km.Envelope(**{**REF, "ceilMax": c})
        out.append(_route(env, w(128, 48, 80), 10 ** 9, 0, 10 ** 10, 0, False, sh, f"ceilMax {c}"))
    # allow exactly at and one unit above the shifted ceilMax (440 -> 3,932,160)
    cm = km2.exp8s(440, sh)
    at = -(-cm * 256 // 48)
    while at * 48 // 256 < cm:
        at += 1
    out.append(_route(ref, w(144, 48, 64), at, 0, at, 0, False, sh, "allow == exp8(ceilMax) >> 33: no clamp"))
    above = at
    while above * 48 // 256 == cm:
        above += 1
    out.append(_route(ref, w(144, 48, 64), above, 0, above, 0, False, sh, "one unit above: K2C"))
    # the floor threshold in USD₮0 for every floorMin up to 425, at the edge
    for fm in (1, 2, 100, 264, 265, 266, 300, 400, 424, 425):
        env = km.Envelope(**{**REF, "floorMin": fm})
        edge = -(-km.exp8(fm) // (1 << sh)) if fm > 0 else 0   # smallest reserve whose shifted code >= fm
        for r0 in sorted({0, 1, max(0, edge - 1), edge, edge + 1}):
            out.append(_route(env, w(192, 0, 64, rel=0), 0, r0, 10 ** 12, 0, False, sh, f"floorMin {fm}, reserve0 {r0}"))
    # the same envelope after graduation: no shift
    for fm in (1, 425):
        env = km.Envelope(**{**REF, "floorMin": fm})
        for r0 in (0, 1, km.exp8(fm) - 1, km.exp8(fm)):
            out.append(_route(env, w(192, 0, 64, rel=0), 0, r0, 10 ** 24, 0, True, 0, f"graduated floorMin {fm}"))
    big = km.AMOUNT_MAX
    out.append(_route(ref, w(144, 48, 64, rel=128), big, big, big, 0, False, sh, "2^128 - 1 everywhere"))
    out.append(_route(ref, w(160, 32, 64), 0, 0, 0, 0, False, sh, "nothing at all"))
    return out


# ----------------------------------------------------------------------------- settle sequences

E_WARP, E_CURVE_BUY, E_CURVE_SELL, E_V2_BUY, E_V2_SELL, E_REVENUE, E_DONATE_VAULT, E_CLAIM_FOR = range(8)
E_GIFT, E_SETTLE, E_EVAL_MODE, E_VAULT_PAUSE, E_BUY_PAUSE, E_WITHDRAW, E_BURN_LOCKED, E_GRADUATE = range(8, 16)
E_SETTLE_REVERT = 16
REVERT_CODES = {"EpochNotElapsed": 1, "StepFailed": 2}
# One settle's expectation (DiffSettlesV2.t.sol reads it in this order): n, epoch, time, clampBits, flags,
# inputs, outputs, stateAfter (bytes12/14/32 as big-endian integers), inflow, reserveBefore, allow, buyDecided,
# buyExecuted, tokensOut, quoteIn, cumInflow, allowPaidCum, then the books and balances after the settle:
# reserve, totalCredits(USDT0), totalCredits(token), lockedTokens, burnedTokens, USDT0 and token balances of
# the kernel, token balance of 0xdEaD, USDT0 and token balances of the vault, graduated, the payee's credit.
EXPECT_WIDTH = 29
N_TRADERS = 4

ENV_PRESETS = [
    dict(capT=48, capV=0, allowCumBps=1875, ceilMax=440, relMax=128, floorRel=2, floorMin=1,
         epochLen=900, fallbackEpochs=16, fbAllow=8),                                    # the reference envelope
    dict(capT=64, capV=128, allowCumBps=2500, ceilMax=1023, relMax=128, floorRel=2, floorMin=400,
         epochLen=900, fallbackEpochs=4, fbAllow=32),
    dict(capT=128, capV=0, allowCumBps=5000, ceilMax=1023, relMax=256, floorRel=1, floorMin=1,
         epochLen=900, fallbackEpochs=2, fbAllow=128),                                   # the loosest accepted
    dict(capT=32, capV=0, allowCumBps=500, ceilMax=420, relMax=64, floorRel=8, floorMin=425,
         epochLen=600, fallbackEpochs=3, fbAllow=0),
]


def random_word(rng: random.Random) -> int:
    kind = rng.random()
    if kind < 0.6:
        tb, th, ta, tr = good_shares(rng)
    elif kind < 0.8:
        tb, th, ta, tr = (rng.randint(0, 511) for _ in range(4))
    else:
        tb, th, ta, tr = rng.choice([(0, 0, 256, 0), (256, 0, 0, 0), (0, 0, 0, 256), (0, 256, 0, 0)])
    return km.pack_output({"T_BUY": tb, "T_HOLD": th, "T_ALLOW": ta, "T_RES": tr,
                           "V_BUY": rng.randint(0, 511), "V_HOLD": rng.randint(0, 511),
                           "V_ALLOW": rng.randint(0, 511), "V_RES": rng.randint(0, 511),
                           "REL": rng.choice([0, 1, 2, 16, 64, 128, 256, rng.randint(0, 511)]),
                           "CEIL": rng.choice([1023, 1023, rng.randint(250, 480), rng.randint(0, 1023)]),
                           "MODE": rng.randint(0, 7), "TIER": rng.randint(0, 3),
                           "FLAGS": rng.randint(0, 255), "AUX": rng.randint(0, 255)})


class SeqBuilder:
    def __init__(self, rng: random.Random, fg: bool):
        self.rng = rng
        self.fg = fg
        r = rng.random()
        self.shift = km2.QUOTE_SHIFT if (fg or r < 0.8) else (0 if r < 0.9 else rng.randint(1, km2.MAX_SHIFT))
        self.tax = 300 if fg else rng.choice([300, 300, 300, 100, 1000, 50])
        self.graduation = rng.choice([8_000 * 10 ** 6, 8_000 * 10 ** 6, 400 * 10 ** 6, 60 * 10 ** 6])
        self.env_i = 0 if fg else rng.randrange(len(ENV_PRESETS))
        e = ENV_PRESETS[self.env_i]
        self.env = wv.EnvV2(**e)
        if fg:
            self.chip = wv.FlowGovernorChip()
            self.words = []
            self.n_state = 64
        else:
            self.words = [random_word(rng) for _ in range(rng.randint(1, 7))]
            self.n_state = rng.choice([8, 64, 256])
            self.chip = wv.ScriptChip(self.n_state, self.words)
        self.w = wv.World(self.tax, self.graduation)
        self.k = wv.KernelV2Sim(self.env, self.shift, self.chip, T0, sealed_always=fg)
        self.now = T0
        self.events: list = []
        self.expects: list = []
        self.reverts = 0

    def ev(self, kind, a=0, b=0, c=0):
        self.events += [kind, a, b, c]

    def trader(self, i):
        return f"t{i}"

    def snapshot(self, rec: dict) -> list:
        k, w = self.k, self.w
        snap = [rec["n"], rec["epoch"], rec["time"], rec["clampBits"], rec["flags"], b12(rec["inputs"]),
                b14(rec["outputs"]), b32(rec["stateAfter"], self.n_state), rec["inflow"], rec["reserveBefore"],
                rec["allow"], rec["buyDecided"], rec["buyExecuted"], rec["tokensOut"], rec["quoteIn"],
                rec["cumInflow"], rec["allowPaidCum"], k.reserve, k.total_credits["usdt"],
                k.total_credits["token"], k.locked, k.burned, w.usdt.of(wv.KERNEL), w.token.of(wv.KERNEL),
                w.token.of(wv.DEAD), w.usdt.of(wv.VAULT), w.token.of(wv.VAULT), 1 if k.graduated else 0,
                k.credits.get((wv.PAYEE, "usdt"), 0)]
        assert len(snap) == EXPECT_WIDTH
        return snap

    def settle(self):
        try:
            rec = self.k.settle(self.w, self.now)
        except wv.Revert as e:
            self.ev(E_SETTLE_REVERT, REVERT_CODES[str(e)])
            self.reverts += 1
            return
        self.ev(E_SETTLE, len(self.expects))
        self.expects.append(self.snapshot(rec))

    def step(self):
        rng, w, k = self.rng, self.w, self.k
        r = rng.random()
        grad = w.graduated
        if r < 0.30:
            # time, then a settle most of the time
            secs = rng.choice([self.env.epochLen] * 5 + [2 * self.env.epochLen, rng.randint(1, 4 * self.env.epochLen),
                                                           17 * self.env.epochLen])
            self.now += secs
            self.ev(E_WARP, secs)
            if rng.random() < 0.85:
                self.settle()
        elif r < 0.33:
            self.settle()                      # often too early: EpochNotElapsed
        elif r < 0.50:
            i = rng.randrange(N_TRADERS)
            if not grad:
                if w.buy_paused:
                    return
                amt = rng.choice([rng.randint(1, 10 ** 6), rng.randint(10 ** 6, 10 ** 8), rng.randint(10 ** 8, 10 ** 9)])
                if self.graduation <= 60 * 10 ** 6:
                    amt = rng.randint(1, 10 ** 7)
                left_cost = w.cost_to_graduate()
                if amt >= left_cost:           # leave the graduation to the GRADUATE event
                    return
                w.usdt.mint(self.trader(i), amt)
                w.curve_buy(self.trader(i), self.trader(i), amt, 0)
                self.ev(E_CURVE_BUY, i, amt)
            else:
                amt = rng.randint(1, max(1, w.r_usd // 20))
                w.usdt.mint(self.trader(i), amt)
                w.swap(self.trader(i), True, amt, self.trader(i), 0)
                self.ev(E_V2_BUY, i, amt)
        elif r < 0.58:
            i = rng.randrange(N_TRADERS)
            bal = w.token.of(self.trader(i))
            if bal == 0:
                return
            amt = rng.randint(1, bal)
            if not grad:
                w.curve_sell(self.trader(i), amt)
                self.ev(E_CURVE_SELL, i, amt)
            else:
                amt = min(amt, w.r_tok // 20)
                if amt == 0:
                    return
                try:
                    st = (dict(w.usdt.bal), dict(w.token.bal), w.r_tok, w.r_usd)
                    w.swap(self.trader(i), False, amt, self.trader(i), 0)
                except wv.Revert:
                    w.usdt.bal, w.token.bal, w.r_tok, w.r_usd = st
                    return
                self.ev(E_V2_SELL, i, amt)
        elif r < 0.68:
            # revenue from an unrelated payer: $0.50 calls, or larger sums
            amt = rng.choice([500_000, 500_000 * rng.randint(1, 40), rng.randint(1, 10 ** 9), 10_000])
            w.usdt.mint(wv.PAYER, amt)
            w.usdt.move(wv.PAYER, wv.KERNEL, amt)
            self.ev(E_REVENUE, amt)
        elif r < 0.70:
            amt = rng.randint(1, 10 ** 7)
            w.usdt.mint(wv.PAYER, amt)
            w.usdt.move(wv.PAYER, wv.VAULT, amt)
            self.ev(E_DONATE_VAULT, amt)
        elif r < 0.73:
            asset = rng.choice(["usdt", "token"])
            if w.vault_paused:
                return
            try:
                w.claim(asset)
            except wv.Revert:
                return
            self.ev(E_CLAIM_FOR, 0 if asset == "usdt" else 1)
        elif r < 0.75:
            if not grad:
                return
            i = rng.randrange(N_TRADERS)
            bal = w.token.of(self.trader(i))
            if bal == 0:
                return
            amt = rng.randint(1, bal)
            w.token.move(self.trader(i), wv.KERNEL, amt)
            self.ev(E_GIFT, i, amt)
        elif r < 0.78 and not self.fg:
            m = rng.choice([wv.EVAL_OK, wv.EVAL_OK, wv.EVAL_TAPEOUT_DEAD, wv.EVAL_BOTH_DEAD])
            k.eval_mode = m
            self.ev(E_EVAL_MODE, m)
        elif r < 0.80:
            w.vault_paused = not w.vault_paused
            self.ev(E_VAULT_PAUSE, 1 if w.vault_paused else 0)
        elif r < 0.82:
            w.buy_paused = not w.buy_paused
            self.ev(E_BUY_PAUSE, 1 if w.buy_paused else 0)
        elif r < 0.86:
            asset = "usdt"
            k.withdraw(w, wv.PAYEE, asset)
            self.ev(E_WITHDRAW, 0)
        elif r < 0.88:
            if not k.graduated:
                return
            k.burn_locked(w)
            self.ev(E_BURN_LOCKED)
        elif r < 0.90:
            if grad or w.buy_paused:
                return
            cost = w.cost_to_graduate()
            extra = rng.randint(0, 10 ** 7)
            w.usdt.mint(wv.WHALE, cost + extra)
            w.curve_buy(wv.WHALE, wv.WHALE, cost + extra, 0)
            assert w.graduated
            self.ev(E_GRADUATE, cost + extra)

    def build(self, n_events: int) -> dict:
        while len(self.events) < 4 * n_events:
            self.step()
        # the last settle: past any grace period, everything working
        self.ev(E_EVAL_MODE, wv.EVAL_OK)
        self.k.eval_mode = wv.EVAL_OK
        self.now += self.env.epochLen
        self.ev(E_WARP, self.env.epochLen)
        self.settle()
        # head: fg, shift, tax bps, graduation target, envelope preset, nState, number of words, the words
        head = [1 if self.fg else 0, self.shift, self.tax, self.graduation, self.env_i, self.n_state,
                len(self.words)] + [b14(x) for x in self.words]
        return {
            "head": [s(x) for x in head], "settled": len(self.expects), "reverted": self.reverts,
            "events": [s(x) for x in self.events],
            "expects": [s(x) for e in self.expects for x in e],          # EXPECT_WIDTH values per settle
        }


def settle_sequences(rng: random.Random, n_script: int, n_fg: int):
    seqs = []
    for i in range(n_script):
        seqs.append(SeqBuilder(random.Random(rng.getrandbits(64)), False).build(rng.randint(40, 90)))
    for i in range(n_fg):
        seqs.append(SeqBuilder(random.Random(rng.getrandbits(64)), True).build(rng.randint(60, 110)))
    return seqs


def main():
    rng = random.Random(SEED)
    doc = {
        "format": "covenant-golden-v2/1",
        "seed": SEED,
        "shift": {"quoteShift": km2.QUOTE_SHIFT, "codeShift": km2.CODE_SHIFT, "quoteDecimals": km2.QUOTE_DECIMALS,
                  "referenceRateMicro": s(km2.REFERENCE_RATE_MICRO), "maxShift": km2.MAX_SHIFT},
        "envPresets": ENV_PRESETS,
        "lg8s": lg8s_vectors(rng),
        "exp8s": exp8s_vectors(),
        "routing": routing_vectors(rng),
        "routingBoundary": routing_boundary_vectors(),
    }
    seqs = settle_sequences(rng, int(os.environ.get("V2_SCRIPT_SEQS", "480")), int(os.environ.get("V2_FG_SEQS", "40")))
    # The sequences go to a JSON Lines companion, one sequence per line, so that the Solidity differential can
    # read them one line at a time (a single 6 MB JSON document is too slow to query from forge thousands of
    # times). vectors_v2.json records how many there are and the companion's SHA-256.
    lines = [json.dumps(q, sort_keys=True, separators=(",", ":")) for q in seqs]
    settles_text = "\n".join(lines) + "\n"
    settles_path = os.environ.get("COVENANT_SETTLES_V2_OUT") or os.path.join(HERE, "vectors_v2_settles.jsonl")
    with open(settles_path, "w") as f:
        f.write(settles_text)
    doc["settlesFile"] = "vectors_v2_settles.jsonl"
    doc["settlesSha256"] = hashlib.sha256(settles_text.encode()).hexdigest()
    doc["settleSequences"] = len(seqs)
    doc["expectWidth"] = EXPECT_WIDTH
    n_settles = sum(q["settled"] for q in seqs)
    doc["settleCount"] = n_settles
    doc["settleReverts"] = sum(q["reverted"] for q in seqs)
    n_events = sum(len(q["events"]) // 4 for q in seqs)
    path = os.environ.get("COVENANT_VECTORS_V2_OUT") or os.path.join(HERE, "vectors_v2.json")
    text = json.dumps(doc, sort_keys=True, separators=(",", ":"))
    with open(path, "w") as f:
        f.write(text + "\n")
    grads = sum(1 for q in seqs for j in range(q["settled"]) if q["expects"][j * EXPECT_WIDTH + 27] == "1")
    print("wrote", path, f"{len(text):,} bytes, sha256 {hashlib.sha256((text + chr(10)).encode()).hexdigest()}")
    print("wrote", settles_path, f"{len(settles_text):,} bytes, sha256 {doc['settlesSha256']}")
    print({k: len(v) for k, v in doc.items() if isinstance(v, list)})
    print(f"settles: {len(seqs)} sequences ({sum(1 for q in seqs if q['head'][0] == '1')} on the Flow Governor), "
          f"{n_events} events, {n_settles} recorded settles ({grads} in the graduated regime), "
          f"{doc['settleReverts']} settles expected to revert")


if __name__ == "__main__":
    main()
