"""Reference model of the Covenant kernel arithmetic (interface v1).

This file is the single source of truth for:
  * the lg8 / exp8 log code,
  * the bit layout of the 96-bit input word and the 112-bit output word,
  * how a kernel turns a chip's output word into routed amounts (clamps K1..K5).

The Solidity kernel, the TypeScript dashboard and the chip test benches must agree
with it bit for bit. `gen_vectors.py` turns it into `vectors.json`.

Integers only. No floats anywhere.
"""
from __future__ import annotations

from dataclasses import dataclass, field, asdict
from typing import Dict, Tuple

# --------------------------------------------------------------------------- log code

LG8_MAX = 1023


def lg8(x: int) -> int:
    """10-bit log code, 1/8-octave steps. lg8(0) = 0, lg8(1) = 1."""
    if x < 0:
        raise ValueError("negative amount")
    if x == 0:
        return 0
    e = x.bit_length() - 1                      # floor(log2 x)
    m = (x >> (e - 3)) & 7 if e >= 3 else (x << (3 - e)) & 7
    return min(LG8_MAX, 8 * e + m + 1)


def exp8(c: int) -> int:
    """Floor inverse of lg8: the smallest amount whose code is c (0 for c = 0)."""
    if not 0 <= c <= LG8_MAX:
        raise ValueError("code out of range")
    if c == 0:
        return 0
    return ((8 + ((c - 1) & 7)) << ((c - 1) >> 3)) >> 3


# --------------------------------------------------------------------------- word layouts
# (name, offset, width); bit 0 is the least significant bit of the word.

IN_BITS = 96
OUT_BITS = 112

INPUT_FIELDS = [
    ("TAX", 0, 10),      # lg8(fresh inflow of the regime asset recognised by this settle)
    ("TAXCUM", 10, 10),  # lg8(cumulative inflow in the current regime, this settle included)
    ("REV", 20, 10),     # lg8(revenue since the last step)            kernel v1: 0
    ("REVCUM", 30, 10),  # lg8(cumulative revenue)                     kernel v1: 0
    ("RES", 40, 10),     # lg8(reserve of the regime asset before this settle's routing)
    ("ESC", 50, 10),     # lg8(holder escrow)                          kernel v1: 0
    ("PROG", 60, 8),     # curve progress: min(254, sold*255//sellable); 255 once graduated
    ("LOCK", 68, 8),     # 255 * (tokens locked or burned by the kernel) // totalSupply
    ("DT", 76, 4),       # epochs since the last persisted step, at least 1, saturating at 15
    ("GRAD", 80, 1),     # 1 once graduated
    ("ZERO", 81, 15),    # always zero
]

OUTPUT_FIELDS = [
    ("T_BUY", 0, 9),     # shares of fresh tax, each 0..256
    ("T_HOLD", 9, 9),
    ("T_ALLOW", 18, 9),
    ("T_RES", 27, 9),
    ("V_BUY", 36, 9),    # shares of fresh revenue (kernel v1 ignores this group)
    ("V_HOLD", 45, 9),
    ("V_ALLOW", 54, 9),
    ("V_RES", 63, 9),
    ("REL", 72, 9),      # share (0..256) of the pre-settle reserve released into buy-and-lock
    ("CEIL", 81, 10),    # lg8 ceiling on this settle's allowance amount; 1023 = none
    ("MODE", 91, 3),     # telemetry
    ("TIER", 94, 2),     # telemetry
    ("FLAGS", 96, 8),    # telemetry
    ("AUX", 104, 8),     # telemetry
]


def pack_fields(layout, values: Dict[str, int], nbits: int) -> int:
    word = 0
    for name, off, width in layout:
        v = values.get(name, 0)
        if not 0 <= v < (1 << width):
            raise ValueError(f"{name}={v} does not fit {width} bits")
        word |= v << off
    assert word < (1 << nbits)
    return word


def unpack_fields(layout, word: int) -> Dict[str, int]:
    return {name: (word >> off) & ((1 << width) - 1) for name, off, width in layout}


def word_to_bytes(word: int, nbits: int) -> bytes:
    """TAP-20 packing: bit i lives in byte i//8 at value 2**(i%8). Little-endian bytes."""
    return word.to_bytes((nbits + 7) // 8, "little")


def bytes_to_word(b: bytes) -> int:
    return int.from_bytes(b, "little")


def pack_input(values: Dict[str, int]) -> int:
    return pack_fields(INPUT_FIELDS, values, IN_BITS)


def unpack_output(word: int) -> Dict[str, int]:
    return unpack_fields(OUTPUT_FIELDS, word)


def pack_output(values: Dict[str, int]) -> int:
    return pack_fields(OUTPUT_FIELDS, values, OUT_BITS)


# --------------------------------------------------------------------------- envelope and clamps

K1T = 1 << 0   # tax share group malformed -> treated as 100% reserve
K1V = 1 << 1   # revenue share group malformed (kernel v2)
K2 = 1 << 2    # tax allowance share above capT -> clipped, excess to reserve
K2C = 1 << 3   # allowance amount above the envelope ceiling -> clipped
K2L = 1 << 4   # allowance above the lifetime cap (allowCumBps of cumulative inflow) -> clipped
K3 = 1 << 5    # REL above relMax -> clipped
K5 = 1 << 6    # REL below the reserve floor while the reserve is above floorMin -> raised
K2V = 1 << 7   # revenue allowance share above capV (kernel v2)


@dataclass
class Envelope:
    capT: int = 64            # max T_ALLOW, 0..256
    capV: int = 128           # max V_ALLOW, 0..255 (kernel v2)
    allowCumBps: int = 2500   # lifetime allowance <= allowCumBps/10000 of cumulative inflow; <= 9999
    ceilMax: int = 1023       # lg8 code; max allowance per settle; 1023 = none
    relMax: int = 128         # max REL, 0..256
    floorRel: int = 2         # min REL while lg8(reserve) >= floorMin; 1..relMax
    floorMin: int = 400       # lg8 code; the floor applies at or above this reserve code


@dataclass
class Routed:
    clamp: int
    allow: int          # credited to the allowance payee
    buy_share: int      # part of fresh inflow sent to buy-and-lock
    release: int        # part of the pre-settle reserve sent to buy-and-lock
    buy_decided: int    # buy_share + release
    to_reserve: int     # part of fresh inflow that stays (hold + reserve + clipped excess + dust)
    reserve_after: int  # if the whole decided buy executes
    shares: Tuple[int, int, int, int] = field(default=(0, 0, 0, 0))  # effective (buy, hold, allow, res)
    rel: int = 0        # effective REL


def route_tax(env: Envelope, out_word: int, inflow: int, reserve0: int,
              cum_inflow: int, allow_paid_cum: int) -> Routed:
    """Routing of the regime asset for one settle.

    cum_inflow already includes `inflow`. allow_paid_cum is the allowance credited so far.
    A failed or shrunk buy leg does not change these numbers: the unexecuted part simply
    stays in the reserve (reserve_after assumes full execution).
    """
    o = unpack_output(out_word)
    clamp = 0
    tb, th, ta, tr = o["T_BUY"], o["T_HOLD"], o["T_ALLOW"], o["T_RES"]
    if max(tb, th, ta, tr) > 256 or tb + th + ta + tr != 256:
        tb, th, ta, tr = 0, 0, 0, 256
        clamp |= K1T
    if ta > env.capT:
        tr += ta - env.capT        # the excess stays in reserve
        ta = env.capT
        clamp |= K2

    allow = inflow * ta // 256
    if o["CEIL"] != LG8_MAX:       # the chip's own ceiling is not a clamp
        allow = min(allow, exp8(o["CEIL"]))
    if env.ceilMax != LG8_MAX and allow > exp8(env.ceilMax):
        allow = exp8(env.ceilMax)
        clamp |= K2C
    room = cum_inflow * env.allowCumBps // 10000 - allow_paid_cum
    if room < 0:
        room = 0
    if allow > room:
        allow = room
        clamp |= K2L

    buy_share = inflow * tb // 256
    to_reserve = inflow - allow - buy_share

    rel = o["REL"]
    if rel > env.relMax:
        rel = env.relMax
        clamp |= K3
    if lg8(reserve0) >= env.floorMin and rel < env.floorRel:
        rel = env.floorRel
        clamp |= K5
    release = reserve0 * rel // 256

    return Routed(
        clamp=clamp, allow=allow, buy_share=buy_share, release=release,
        buy_decided=buy_share + release, to_reserve=to_reserve,
        reserve_after=reserve0 - release + to_reserve,
        shares=(tb, th, ta, tr), rel=rel,
    )


def fallback_word(env: Envelope, fb_allow: int) -> int:
    """Output word the kernel uses when the evaluator has failed past the grace period."""
    assert 0 <= fb_allow <= env.capT
    return pack_output({"T_BUY": 256 - fb_allow, "T_ALLOW": fb_allow, "REL": env.relMax, "CEIL": LG8_MAX})


def prog_code(sold: int, sellable: int, graduated: bool) -> int:
    if graduated:
        return 255
    if sellable == 0:
        return 0
    return min(254, sold * 255 // sellable)


def lock_code(locked_or_burned: int, total_supply: int) -> int:
    if total_supply == 0:
        return 0
    return min(255, locked_or_burned * 255 // total_supply)


def dt_code(epoch_now: int, last_epoch: int) -> int:
    d = epoch_now - last_epoch
    if d < 1:
        raise ValueError("settle needs a new epoch")
    return min(15, d)


def state_to_bytes32(bits: int, n_state: int) -> bytes:
    """Kernel storage form of a chip state: the TAP-20 byte string, right-padded to 32 bytes."""
    raw = bits.to_bytes((n_state + 7) // 8, "little")
    return raw + bytes(32 - len(raw))


if __name__ == "__main__":
    assert lg8(1) == 1 and lg8(10 ** 18) == 478 and lg8(10 ** 6) == 160
    assert all(exp8(lg8(x)) <= x for x in range(1, 5000))
    print("kernel_model self-check ok")
    print(asdict(Envelope()))
