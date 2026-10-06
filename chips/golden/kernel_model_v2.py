"""Reference model of kernel v2 (chips/INTERFACE-V2.md): kernel v1's arithmetic with a quote asset.

Kernel v2 is the RECIPIENT of an IGNIX Directed vault quoted in USD₮0 (6 decimals). Everything that
is not about the quote asset is kernel v1, and is NOT re-implemented here: lg8, exp8, the word
layouts, the buy sizing and the clamps come from kernel_model.py, which this file does not change.

What kernel v2 adds is one parameter, the code shift `s` (bits):

  * on the curve the chip sees  TAX = lg8(inflow << s), TAXCUM = lg8(cum << s), RES = lg8(reserve0 << s);
  * every amount code that comes back (the chip's CEIL, the envelope's ceilMax) is decoded as
    exp8(code) >> s, and the K5 floor compares lg8(reserve0 << s) with floorMin;
  * after graduation the regime asset is the project token (18 decimals, as in v1) and s = 0.

With s = 0 every function here is exactly its kernel v1 counterpart (checked below against every
routing vector of vectors.json). The Solidity (contracts/core-v2/src/KernelMathV2.sol) must agree
with this file bit for bit; gen_vectors_v2.py turns it into vectors_v2.json.

Integers only. No floats anywhere except in the human-readable derivation printout.
"""
from __future__ import annotations

import json
import os
from typing import Tuple

import kernel_model as km

HERE = os.path.dirname(os.path.abspath(__file__))

# --------------------------------------------------------------------------- the shift

NATIVE_DECIMALS = 18          # wei of OKB: the unit the Flow Governor was calibrated in
QUOTE_DECIMALS = 6            # USD₮0 on X Layer (decimals() == 6, read on chain)
MAX_SHIFT = 40                # KernelFactoryV2.MAX_QUOTE_SHIFT

# Reference rate the shift is derived from, in USD₮0 base units per OKB (micro-USD₮0 per OKB):
# 135.895901 USD₮0 per OKB, the spot price of the canonical Uniswap V3 USD₮0/WOKB 0.05% pool
# (0xe3BE6A0137f1b0602Fc1a4841686f43B340a5082, slot0) at X Layer block 72,530,000
# (2026-10-06 15:03:56 UTC). Any reference rate between 82.3 and 164.6 USD₮0 per OKB gives the
# same shift; contracts/core-v2/NOTES.md section 3 has the derivation.
REFERENCE_RATE_MICRO = 135_895_901


def shift_for_rate(rate_micro: int, quote_decimals: int = QUOTE_DECIMALS) -> int:
    """The integer s that makes one quote base unit read as 2^s wei, closest (in log2) to the rate.

    One base unit of the quote is worth 10^(18 - d) / rate OKB-wei, with rate in whole quote per OKB.
    With rate_micro = rate * 10^6 and d = 6 the ideal multiplier is m = 10^18 / rate_micro.
    s is the nearest integer to log2(m): the s with 2^(s - 1/2) <= m < 2^(s + 1/2), i.e.
    2^(2s - 1) <= m^2 < 2^(2s + 1), decided in integers.
    """
    num = 10 ** (NATIVE_DECIMALS - quote_decimals + 6)   # m = num / rate_micro
    den = rate_micro
    # largest s with 2^(2s-1) * den^2 <= num^2
    s = 0
    while (1 << (2 * (s + 1) - 1)) * den * den <= num * num:
        s += 1
    return s


QUOTE_SHIFT = shift_for_rate(REFERENCE_RATE_MICRO)     # 33
CODE_SHIFT = 8 * QUOTE_SHIFT                           # 264


def lg8s(x: int, s: int) -> int:
    """lg8 of an amount seen through a shift of s bits: lg8(min(x, 2^128 - 1) << s)."""
    if x < 0:
        raise ValueError("negative amount")
    return km.lg8(min(x, km.AMOUNT_MAX) << s)


def exp8s(c: int, s: int) -> int:
    """exp8(c) >> s: the smallest amount of code c in the shifted unit, in base units, rounded down."""
    return km.exp8(c) >> s


# --------------------------------------------------------------------------- routing

def route_tax_v2(env: km.Envelope, out_word: int, inflow: int, reserve0: int,
                 cum_inflow: int, allow_paid_cum: int, graduated: bool = False,
                 shift: int = 0) -> km.Routed:
    """km.route_tax with the code shift. shift = 0 is kernel v1, bit for bit.

    Differences from km.route_tax and nothing else:
      chip ceiling   allow = min(allow, exp8(CEIL) >> shift)        (not a clamp)
      K2C            the envelope ceiling is exp8(ceilMax) >> shift
      K5             lg8(reserve0 << shift) >= floorMin
    """
    if not 0 <= shift <= MAX_SHIFT:
        raise ValueError("shift out of range")
    o = km.unpack_output(out_word)
    clamp = 0
    tb, th, ta, tr = o["T_BUY"], o["T_HOLD"], o["T_ALLOW"], o["T_RES"]
    if max(tb, th, ta, tr) > 256 or tb + th + ta + tr != 256:
        tb, th, ta, tr = 0, 0, 0, 256
        clamp |= km.K1T
    if graduated:
        tr += ta
        ta = 0
        allow = 0
    else:
        if ta > env.capT:
            tr += ta - env.capT
            ta = env.capT
            clamp |= km.K2
        allow = inflow * ta // 256
        if o["CEIL"] != km.LG8_MAX:
            allow = min(allow, exp8s(o["CEIL"], shift))
        if env.ceilMax != km.LG8_MAX and allow > exp8s(env.ceilMax, shift):
            allow = exp8s(env.ceilMax, shift)
            clamp |= km.K2C
        room = cum_inflow * env.allowCumBps // 10000 - allow_paid_cum
        if room < 0:
            room = 0
        if allow > room:
            allow = room
            clamp |= km.K2L

    buy_share = inflow * tb // 256
    to_reserve = inflow - allow - buy_share

    rel = o["REL"]
    if rel > env.relMax:
        rel = env.relMax
        clamp |= km.K3
    if lg8s(reserve0, shift) >= env.floorMin and rel < env.floorRel:
        rel = env.floorRel
        clamp |= km.K5
    release = reserve0 * rel // 256

    return km.Routed(
        clamp=clamp, allow=allow, buy_share=buy_share, release=release,
        buy_decided=buy_share + release, to_reserve=to_reserve,
        reserve_after=reserve0 - release + to_reserve,
        shares=(tb, th, ta, tr), rel=rel,
    )


def input_word_v2(inflow: int, cum: int, reserve0: int, prog: int, lock: int, dt: int,
                  graduated: bool, shift: int) -> int:
    """The 96-bit input word a v2 kernel assembles. REV, REVCUM and ESC are 0: revenue paid to the
    kernel is part of TAX. `shift` is the kernel's quote shift; it is not applied after graduation."""
    s = 0 if graduated else shift
    return km.pack_input({
        "TAX": lg8s(inflow, s), "TAXCUM": lg8s(cum, s), "RES": lg8s(reserve0, s),
        "PROG": prog, "LOCK": lock, "DT": dt, "GRAD": 1 if graduated else 0,
    })


# --------------------------------------------------------------------------- self-check

def _check_shift_identities() -> int:
    """lg8(x << s) == min(1023, lg8(x) + 8s) (x >= 1) and exp8(c + 8s) >> s == exp8(c): exhaustive for
    every x below 2^16 and every s <= MAX_SHIFT, plus every power of two and its neighbours to 2^128."""
    n = 0
    xs = list(range(1, 1 << 16))
    for e in range(16, 129):
        xs += [(1 << e) - 1, 1 << e, (1 << e) + 1, (3 << e) >> 1]
    for s in range(0, MAX_SHIFT + 1):
        for x in xs:
            x = min(x, km.AMOUNT_MAX)
            assert lg8s(x, s) == min(km.LG8_MAX, km.lg8(x) + 8 * s), (x, s)
            n += 1
        assert lg8s(0, s) == 0
        for c in range(1, km.LG8_MAX + 1 - 8 * s):
            assert km.exp8(c + 8 * s) >> s == km.exp8(c), (c, s)
            n += 1
    return n


def _check_v1_equivalence() -> int:
    """With shift 0, route_tax_v2 reproduces every routing expectation of vectors.json."""
    with open(os.path.join(HERE, "vectors.json")) as f:
        doc = json.load(f)
    vecs = list(doc["routing"]) + list(doc["revision2"]["routingBoundary"]) + list(doc["revision2"]["routingGraduated"])
    n = 0
    for v in vecs:
        env = km.Envelope(**v["envelope"])
        args = (env, int(v["word"]), int(v["inflow"]), int(v["reserve0"]), int(v["cumInflow"]),
                int(v["allowPaidCum"]), bool(v.get("graduated", False)))
        r1 = km.route_tax(*args)
        r2 = route_tax_v2(*args, shift=0)
        assert r1 == r2, v
        ex = v["expect"]
        assert (r2.clamp, str(r2.allow), str(r2.buy_decided), str(r2.reserve_after)) == \
            (ex["clamp"], ex["allow"], ex["buyDecided"], ex["reserveAfter"]), v
        n += 1
    return n


def _check_reference_points() -> None:
    assert QUOTE_SHIFT == 33 and CODE_SHIFT == 264
    # the boundaries of the rate band that gives 33 (NOTES.md section 3)
    assert shift_for_rate(82_400_000) == 33 and shift_for_rate(164_500_000) == 33
    assert shift_for_rate(82_300_000) == 34 and shift_for_rate(164_700_000) == 32
    # one OKB of the chip's calibration is 10^18 / 2^33 = 116.415321 USD₮0
    assert (10 ** 18) >> 33 == 116_415_321
    # codes of USD₮0 amounts (Q12 R4b): 1 USD₮0 = 160 + 264, $0.50 = 152 + 264, 8,000 USD₮0 = 263 + 264
    assert lg8s(10 ** 6, 33) == 424 and lg8s(500_000, 33) == 416 and lg8s(8_000 * 10 ** 6, 33) == 527
    # the Flow Governor's thresholds in USD₮0 base units (exp8(code) >> 33)
    assert exp8s(425, 33) == 1 << 20                # M1, floorMin bound: 1.048576 USD₮0
    assert exp8s(440, 33) == 15 << 18               # CEIL0: 3.932160 USD₮0 per settle
    assert exp8s(452, 33) == 11 << 20               # M2: 11.534336 USD₮0
    assert exp8s(479, 33) == 14 << 23               # M3: 117.440512 USD₮0


if __name__ == "__main__":
    _check_reference_points()
    n1 = _check_shift_identities()
    n2 = _check_v1_equivalence()
    print(f"kernel_model_v2 self-check ok: shift {QUOTE_SHIFT} bits = {CODE_SHIFT} codes; "
          f"{n1} identity cases; {n2} v1 routing vectors reproduced with shift 0")
    print(f"reference rate {REFERENCE_RATE_MICRO / 1e6} USD₮0/OKB -> 1 OKB of the chip's calibration "
          f"reads as {(10 ** 18 >> QUOTE_SHIFT) / 1e6} USD₮0")
