"""Flow Governor: bit-exact behavioural model of chips/rtl/fg_core.v.

    step(s, x) -> (ns, y)

`s` is the 64-bit latch state, `x` the 96-bit input word, `ns` the next state and `y` the
112-bit output word, all as Python integers with bit 0 = least significant bit (the TAP-20
packing of chips/INTERFACE.md section 3). Word layouts and the log code come from
chips/golden/kernel_model.py; nothing of the kernel arithmetic is re-implemented here.

Constants come from chips/rtl/fg_params.json (the same file generates fg_params.vh).

Integers only. Every intermediate is written at its hardware width so that the RTL can mirror
this file line by line. The plain-language description is chips/model/FLOW_GOVERNOR.md.

`step` is kept to plain integer code on purpose: chips/props/model_equiv.py executes its source
symbolically and proves the result equal to the netlist bytes for every (s, x). A construct that
chips/props/symexec.py does not model makes that proof stop, not pass.
"""
from __future__ import annotations

import json
import os
import sys
from typing import Dict, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
CHIPS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(CHIPS, "golden"))

import kernel_model as km  # noqa: E402

PARAMS_PATH = os.path.join(CHIPS, "rtl", "fg_params.json")


def load_params(path: str = PARAMS_PATH) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


PARAMS = load_params()
P = PARAMS["chip"]
ENV = PARAMS["envelope"]

N_STATE = 64

# ----------------------------------------------------------------------------- state layout
# (name, offset, width, meaning). State bit i is LATCH record i of the netlist.
STATE_FIELDS = [
    ("A", 0, 12, "Average tax rate per epoch, in quarter-codes above the regime floor (0 = at the floor)"),
    ("PK", 12, 10, "Decaying peak of the average, in codes above the regime floor"),
    ("PKDIV", 22, 2, "Peak-decay prescaler: the peak loses one code every 4 elapsed epochs"),
    ("MODE", 24, 3, "0 IDLE, 1 CRUISE, 2 BANK, 3 DEFEND, 4 REST"),
    ("TIER", 27, 2, "Allowance ratchet tier 0..3; never decreases"),
    ("GSEEN", 29, 1, "Graduation already seen (the re-seed happens once)"),
    ("WARM", 30, 2, "Warm-up epochs left after a cold start (no surge classification, average jumps up)"),
    ("LIVE", 32, 4, "Epochs of patience left before a drought is declared; 0 = cold (average is stale)"),
    ("SUR", 36, 2, "Surge meter 0..3: +1 per surge epoch, -1 per other epoch; BANK starts at 2, ends at 0"),
    ("TR", 38, 2, "Tranche epochs left in the open DEFEND window"),
    ("CD", 40, 3, "Cooldown epochs left in REST"),
    ("NBANK", 43, 5, "Lifetime count of BANK episodes (saturates at 31); telemetry only"),
    ("NDEF", 48, 6, "Lifetime count of DEFEND windows opened (saturates at 63); telemetry only"),
    ("CLOCK", 54, 10, "Elapsed epochs modulo 1024 (advances by DT on every step); telemetry only"),
]
assert sum(w for _, _, w, _ in STATE_FIELDS) == N_STATE
assert [o for _, o, _, _ in STATE_FIELDS] == [sum(w for _, _, w, _ in STATE_FIELDS[:i]) for i in range(len(STATE_FIELDS))]

MODE_NAMES = ["IDLE", "CRUISE", "BANK", "DEFEND", "REST", "?5", "?6", "?7"]
IDLE, CRUISE, BANK, DEFEND, REST = 0, 1, 2, 3, 4

FLAG_BITS = [
    ("surge", 0, "this reading is at least twice the recent peak of the average"),
    ("dip", 1, "this reading is at most half the average"),
    ("quiet", 2, "this reading is at or below the regime floor"),
    ("release", 3, "a reserve tranche is released in this step (DEFEND routing)"),
    ("regime", 4, "graduation seen in this step: averages re-seeded"),
    ("tierup", 5, "the allowance tier stepped up in this step"),
    ("cooldown", 6, "the chip is in REST after this step (cooling down after a DEFEND window)"),
    ("warm", 7, "cold start or warm-up: the average is being seeded"),
]


def unpack_state(s: int) -> Dict[str, int]:
    return {n: (s >> o) & ((1 << w) - 1) for n, o, w, _ in STATE_FIELDS}


def pack_state(f: Dict[str, int]) -> int:
    s = 0
    for n, o, w, _ in STATE_FIELDS:
        v = f.get(n, 0)
        if not 0 <= v < (1 << w):
            raise ValueError(f"{n}={v} does not fit {w} bits")
        s |= v << o
    return s


def _satsub(a: int, b: int) -> int:
    return a - b if a > b else 0


# ----------------------------------------------------------------------------- the chip
def step(s: int, x: int, p: dict = P) -> Tuple[int, int]:
    """One beat. Total: defined for every 64-bit s and every 96-bit x."""
    # ---- state
    A = s & 0xFFF
    PK = (s >> 12) & 0x3FF
    PKDIV = (s >> 22) & 3
    MODE = (s >> 24) & 7
    TIER = (s >> 27) & 3
    GSEEN = (s >> 29) & 1
    WARM = (s >> 30) & 3
    LIVE = (s >> 32) & 15
    SUR = (s >> 36) & 3
    TR = (s >> 38) & 3
    CD = (s >> 40) & 7
    NBANK = (s >> 43) & 31
    NDEF = (s >> 48) & 63
    CLOCK = (s >> 54) & 1023

    # ---- inputs actually used (REV, REVCUM, ESC, PROG, LOCK and bits 81..95 are ignored)
    TAX = x & 1023
    TAXCUM = (x >> 10) & 1023
    RES = (x >> 40) & 1023
    DT = (x >> 76) & 15
    GRAD = (x >> 80) & 1

    dt = DT if DT != 0 else 1                      # the kernel never sends 0; treat it as 1

    # ---- graduation: the tax unit changes, so everything measured in the old unit is dropped
    ge = GRAD & (GSEEN ^ 1)
    if ge:
        A = PK = PKDIV = MODE = WARM = LIVE = SUR = TR = CD = 0

    floor = p["FLOOR_T"] if GRAD else p["FLOOR_Q"]
    resmin = p["RESMIN_T"] if GRAD else p["RESMIN_Q"]

    # ---- reading: tax rate per epoch, in codes above the floor
    K = floor + p["LOG8DT"][dt]                    # 10 bits
    l = _satsub(TAX, K)                            # 10 bits
    live = l != 0
    cold = LIVE == 0
    seed = cold and live
    warm = seed or WARM != 0

    d = 4 * l - A                                  # signed, 13 bits
    g = l - PK                                     # signed, 11 bits
    surge = (not cold) and (WARM == 0) and g >= p["SURGE_TH"]
    xsurge = surge and g >= p["XSURGE_TH"]         # extreme: counts double, so BANK starts at once
    dip = (not cold) and d <= -4 * p["DIP_TH"]     # reading at most half the average

    # ---- average: climbs a fraction of the gap, falls at most SLEW_Q quarter-codes per epoch
    sh_dt = 2 if dt == 1 else (1 if dt <= 3 else 0)
    sh = 0 if (warm and d >= 0) else sh_dt
    st = d >> sh                                   # arithmetic shift (floor)
    lim = p["SLEW_Q"] * dt                         # 8 bits
    stp = st if st >= -lim else -lim
    A1 = 4 * l if seed else A + stp                # stays within 0..4095
    assert 0 <= A1 <= 4095

    # ---- decaying peak of the average, drawdown depth
    pdsum = PKDIV + dt                             # 5 bits
    dec = pdsum >> 2
    PKDIV1 = pdsum & 3
    pkd = _satsub(PK, dec)
    a1c = A1 >> 2
    PK1 = l if seed else max(a1c, pkd)
    dd = PK1 - a1c                                 # 0..1023

    # ---- timers and meters (all advance by dt)
    LIVE1 = p["DRYN"] if live else _satsub(LIVE, dt)
    drought = LIVE1 == 0
    WARM1 = p["WARMN"] if seed else _satsub(WARM, dt)
    SUR1 = min(3, SUR + dt + (1 if xsurge else 0)) if surge else _satsub(SUR, dt)

    # ---- allowance ratchet (quote regime only)
    tm = 3 if TAXCUM >= p["M3"] else 2 if TAXCUM >= p["M2"] else 1 if TAXCUM >= p["M1"] else 0
    TIER1 = TIER if GRAD else max(TIER, tm)

    can = RES >= resmin

    # ---- mode. A step covers dt epochs, so a DEFEND window or a cooldown may end inside it.
    in_def = MODE == DEFEND
    in_rest = MODE == REST
    in_bank = MODE == BANK
    trn = min(dt, TR)                              # tranche epochs of the open window covered by this step
    over = dt - trn                                # epochs of this step beyond the open window
    def_go = in_def and TR != 0 and can and not surge
    rest_start = in_def and not def_go             # window finished earlier, reserve exhausted, or surge
    rest_cont = in_rest and CD >= dt               # the whole step lies inside the cooldown
    bank_stay = in_bank and SUR1 != 0
    base = not (in_def or rest_cont or bank_stay)
    slack = (dt - CD) if in_rest else 1            # epochs since the cooldown ended (1..15)
    bank_enter = base and surge and SUR1 >= p["SUR_ON"]
    fade = in_bank and dip                         # the surge that was banked has faded
    trig = dd >= p["DD_TH"] or drought or fade
    def_enter = base and (not bank_enter) and trig and can and not ge   # never on the re-seed step
    nen = min(slack, p["TRN"] - 1)                 # tranche epochs credited when a window opens (1..3)
    is_def = def_go or def_enter                   # this step routes as DEFEND
    ntr = nen if def_enter else (trn if def_go else 0)

    TR1 = 0
    CD1 = 0
    if def_enter:
        MODE1 = DEFEND
        TR1 = p["TRN"] - nen
    elif def_go and over == 0:
        MODE1 = DEFEND
        TR1 = TR - trn
    elif def_go:
        MODE1 = REST
        CD1 = _satsub(p["CDN"], over)
    elif rest_start:
        MODE1 = REST
        CD1 = _satsub(p["CDN"], dt)
    elif rest_cont:
        MODE1 = REST
        CD1 = CD - dt
    elif bank_stay or bank_enter:
        MODE1 = BANK
    else:
        MODE1 = IDLE if drought else CRUISE
    is_bank = MODE1 == BANK

    # ---- shares of fresh tax (1/256ths). T_HOLD is always 0: kernel v1 has no holder route.
    al_t = (p["AL0"], p["AL1"], p["AL2"], p["AL3"])[TIER1]
    al = 0 if GRAD else al_t
    if is_def:
        allow, res = 0, 0
    elif is_bank:
        gg = min(max(g - p["SURGE_TH"], 0), p["RB_SPAN"])
        allow, res = al >> 1, p["RB_MIN"] + p["RB_GAIN"] * gg
    else:
        allow, res = al, p["RC"]
    buy = 256 - allow - res

    # ---- reserve release (1/256ths of the pre-settle reserve)
    if is_def:
        r = min(max(2 * dd, p["TR_MIN"]), p["TR_MAX"])
        rel = 2 * r if ntr >= 2 else r
    else:
        rel = p["LEAK"] * dt

    ceil = p["CEIL0"] - p["CEIL_STEP"] * TIER1

    # ---- telemetry
    NBANK1 = min(31, NBANK + (1 if bank_enter else 0))
    NDEF1 = min(63, NDEF + (1 if def_enter else 0))
    CLOCK1 = (CLOCK + dt) & 1023
    GSEEN1 = GSEEN | GRAD
    flags = ((1 if surge else 0) | (1 if dip else 0) << 1 | (0 if live else 1) << 2
             | (1 if is_def else 0) << 3 | ge << 4 | (1 if TIER1 != TIER else 0) << 5
             | (1 if MODE1 == REST else 0) << 6 | (1 if warm else 0) << 7)
    aux = min(dd, 255)

    ns = (A1 | PK1 << 12 | PKDIV1 << 22 | MODE1 << 24 | TIER1 << 27 | GSEEN1 << 29 | WARM1 << 30
          | LIVE1 << 32 | SUR1 << 36 | TR1 << 38 | CD1 << 40 | NBANK1 << 43 | NDEF1 << 48 | CLOCK1 << 54)
    y = km.pack_output({
        "T_BUY": buy, "T_HOLD": 0, "T_ALLOW": allow, "T_RES": res,
        "V_BUY": 0, "V_HOLD": 0, "V_ALLOW": 0, "V_RES": 256,
        "REL": rel, "CEIL": ceil, "MODE": MODE1, "TIER": TIER1, "FLAGS": flags, "AUX": aux})
    return ns, y


# ----------------------------------------------------------------------------- helpers
def envelope() -> km.Envelope:
    """The reference-token envelope as a kernel_model.Envelope."""
    return km.Envelope(capT=ENV["capT"], capV=ENV["capV"], allowCumBps=ENV["allowCumBps"],
                       ceilMax=ENV["ceilMax"], relMax=ENV["relMax"], floorRel=ENV["floorRel"],
                       floorMin=ENV["floorMin"])


def flags_str(flags: int) -> str:
    return ",".join(n for n, b, _ in FLAG_BITS if (flags >> b) & 1) or "-"


def fields_json() -> dict:
    """Latch / field map consumed by the website (die shot, latch table) and the tools."""
    return {
        "chip": P["name"], "version": P["version"],
        "nIn": 96, "nOut": 112, "nState": N_STATE,
        "state": [{"name": n, "offset": o, "width": w, "meaning": m} for n, o, w, m in STATE_FIELDS],
        "stateBits": [{"bit": o + i, "field": n, "index": i, "row": (o + i) // 8, "col": (o + i) % 8}
                      for n, o, w, _ in STATE_FIELDS for i in range(w)],
        "modes": {str(i): MODE_NAMES[i] for i in range(5)},
        "flags": [{"name": n, "bit": b, "meaning": m} for n, b, m in FLAG_BITS],
        "aux": "drawdown depth: codes by which the average sits below its decaying peak, saturating at 255",
        "inputsUsed": ["TAX", "TAXCUM", "RES", "DT", "GRAD"],
        "inputsIgnored": ["REV", "REVCUM", "ESC", "PROG", "LOCK", "ZERO"],
        "input": [{"name": n, "offset": o, "width": w} for n, o, w in km.INPUT_FIELDS],
        "output": [{"name": n, "offset": o, "width": w} for n, o, w in km.OUTPUT_FIELDS],
        "params": P, "envelope": ENV, "reference": PARAMS["reference"],
    }


if __name__ == "__main__":
    import random
    rng = random.Random(1)
    for _ in range(200000):
        s = rng.getrandbits(64)
        x = rng.getrandbits(96)
        ns, y = step(s, x)
        o = km.unpack_output(y)
        assert o["T_BUY"] + o["T_HOLD"] + o["T_ALLOW"] + o["T_RES"] == 256
        assert o["V_BUY"] + o["V_HOLD"] + o["V_ALLOW"] + o["V_RES"] == 256
        assert o["T_ALLOW"] <= ENV["capT"] and ENV["floorRel"] <= o["REL"] <= ENV["relMax"]
        assert o["CEIL"] <= ENV["ceilMax"]
        assert 0 <= ns < (1 << 64)
    print("flow_governor self-check ok (200000 random (s, x): share sums, caps, floor, ceiling)")
