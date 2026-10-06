"""tapc architect: the compile step behind Covenant Architect (protocol "covenant-architect/1").

    printf '%s' '{"protocol":"covenant-architect/1","op":"compile","preset":"flow-governor","params":{}}' \\
      | PYTHONPATH=chips/tools chips/.venv/bin/python -m tapc.architect [--budget 100] [--jobs 4] [--keep DIR]

One JSON request on stdin, exactly one JSON answer on stdout, logs on stderr. The contract is written out at the
top of services/architect/src/toolchain.ts:

  success   {"ok":true,"netlistHex":"0x...","manifest":{...},"proofs":[{"id","status","detail",...}],"cost":{...}}
  rejection {"ok":false,"error":{"code","message","stage","diagnostics":[{"code","path","message","hint"}]}}
            (plus "proofs" when a proof failed)
  exit      0 with ok:true, 1 with ok:false. A fault of the toolchain itself (a bug, a crashed solver, a broken
            installation) prints nothing on stdout and exits 70, so the service answers 502 and charges nothing.

Presets

  flow-governor  chips/rtl/fg_core.v with the constants of chips/rtl/fg_params.json. `params` may override a
                 whitelisted subset of the chip constants and of the target envelope (FG_TUNABLE below). Every
                 value is checked for type and range, then against the relations chips/rtl/gen_params.py checks
                 (restated below with a path and a hint, then run through gen_params.py itself), which include
                 the kernel factory's limits of chips/INTERFACE.md section 7.
  glutton        the hostile demo chip of chips/cells/glutton. No params.

Pipeline, in a temporary directory (nothing is written into the repository):

  params -> fg_params.vh (gen_params.render) -> synthesis with ONE fixed recipe (RECIPE, the one recorded in
  chips/out/fg.manifest.json) -> shape check (covenant-v1, at most 24,000 bytes) -> proofs and the pin manifest,
  in parallel worker processes -> cost.

Proofs run against a wall-clock budget (--budget, seconds from the start of the request). The groups that matter
to a buyer are queued first: P1 share groups, P2 clamp-freedom against the requested envelope (with the K2L
argument), P3 ratchets, P4 inductive invariant; then EQ (netlist bytes == RTL, Yosys SAT and z3), then P5, P6 and
the extras. A job that has not finished when the budget runs out is stopped and its checks are reported with
status "timeout": the answer is still ok (the dashboard shows them as unproven). Any "failed" proof stops the
remaining jobs and turns the answer into a rejection with the counterexample.

Same request, same bytes: the netlist and the manifest depend only on the request (and the pinned toolchain).
The stock flow-governor request reproduces chips/out/fg.tap and chips/out/fg.manifest.json byte for byte.
"""
from __future__ import annotations

import sys

sys.dont_write_bytecode = True        # this module imports from chips/ directories it must not write into

import argparse  # noqa: E402
import copy  # noqa: E402
import difflib  # noqa: E402
import importlib.util  # noqa: E402
import json  # noqa: E402
import math  # noqa: E402
import os  # noqa: E402
import re  # noqa: E402
import shutil  # noqa: E402
import signal  # noqa: E402
import subprocess  # noqa: E402
import tempfile  # noqa: E402
import threading  # noqa: E402
import time  # noqa: E402
import traceback  # noqa: E402
from dataclasses import dataclass, field  # noqa: E402
from typing import Optional  # noqa: E402

PROTOCOL = "covenant-architect/1"
MAX_NETLIST_BYTES = 24_000
MAX_REQUEST_BYTES = 1 << 20
SHAPE = "covenant-v1"
RECIPE = "rich-dc2-compress"           # = build.recipe of chips/out/fg.manifest.json (asserted by the tests)
DEFAULT_BUDGET = 100.0                 # seconds; the whole request then ends within about 102 s
DEFAULT_JOBS = 4
EXIT_OK, EXIT_REJECTED, EXIT_FAULT = 0, 1, 70

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHIPS = os.path.dirname(TOOLS)
ROOT = os.path.dirname(CHIPS)
RTL_DIR = os.path.join(CHIPS, "rtl")
PROPS_DIR = os.path.join(CHIPS, "props")
MODEL_DIR = os.path.join(CHIPS, "model")
GOLDEN_DIR = os.path.join(CHIPS, "golden")
SYNTH_DIR = os.path.join(CHIPS, "synth")
GLUTTON_DIR = os.path.join(CHIPS, "cells", "glutton")
TAPS_ASSETS = os.path.join(ROOT, "docs", "taps", "assets")

FG_PARAMS_JSON = os.path.join(RTL_DIR, "fg_params.json")
FG_GEN_PARAMS = os.path.join(RTL_DIR, "gen_params.py")
FG_CORE = os.path.join(RTL_DIR, "fg_core.v")
FG_PINS = os.path.join(SYNTH_DIR, "fg.pins.json")
FG_PROPS_V = os.path.join(PROPS_DIR, "fg_props.v")
FG_PROPS_PY = os.path.join(PROPS_DIR, "fg_props.py")
GL_CORE = os.path.join(GLUTTON_DIR, "glutton_core.v")
GL_PINS = os.path.join(GLUTTON_DIR, "glutton.pins.json")
GL_PROPS_V = os.path.join(GLUTTON_DIR, "glutton_props.v")
PIN_PROFILE = os.path.join(TAPS_ASSETS, "covenant-v1.pins.json")

# TapeOut's current fees (read from the factory 0x1f09DAeFA827f02CBb40967cc91b259763760761 on X Layer on
# 2026-10-04, chips/tools/NOTES.md section 7) and the Covenant processor's mint price per transistor.
UNIT_PRICE_WEI = 20_000_000_000_000            # 0.00002 OKB per transistor (one transistor per NAND or LATCH)
PROTOCOL_FEE_WEI = 660_000_000_000_000         # 0.00066 OKB per mint call: one call for NAND, one for LATCH
TAPEOUT_FEE_WEI = 1_300_000_000_000_000        # 0.0013 OKB per tape-out
WEI_PER_OKB = 10 ** 18

T0 = time.monotonic()


def _log(msg: str) -> None:
    print(f"tapc architect [{time.monotonic() - T0:6.1f} s] {msg}", file=sys.stderr, flush=True)


# ================================================================================================ outcomes

class Reject(Exception):
    """The request is at fault (or the chip it asks for does not hold up): ok:false, HTTP 422, not charged."""

    def __init__(self, code: str, message: str, stage: str, diagnostics: Optional[list] = None,
                 proofs: Optional[list] = None):
        super().__init__(message)
        self.code, self.message, self.stage = code, message, stage
        self.diagnostics = diagnostics or []
        self.proofs = proofs

    def answer(self) -> dict:
        doc = {"ok": False, "error": {"code": self.code, "message": self.message, "stage": self.stage,
                                      "diagnostics": self.diagnostics}}
        if self.proofs is not None:
            doc["proofs"] = self.proofs
        return doc


class Fault(Exception):
    """The toolchain is at fault: nothing on stdout, exit 70, HTTP 502, not charged."""


def _diag(code: str, path: str, message: str, hint: str = "") -> dict:
    d = {"code": code, "path": path, "message": message}
    if hint:
        d["hint"] = hint
    return d


# ================================================================================================ request

PRESET_RE = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}")


def parse_request(raw: bytes) -> tuple:
    """(preset, params) from the stdin bytes, or Reject at stage "request"."""
    if len(raw) > MAX_REQUEST_BYTES:
        raise Reject("bad_request", f"the request is larger than {MAX_REQUEST_BYTES} bytes", "request")
    try:
        req = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as e:
        raise Reject("bad_request", f"the request is not JSON: {e}", "request",
                     [_diag("json", "", "stdin must hold one JSON object",
                            '{"protocol":"covenant-architect/1","op":"compile","preset":"flow-governor","params":{}}')])
    if not isinstance(req, dict):
        raise Reject("bad_request", "the request is not a JSON object", "request")
    if req.get("protocol") != PROTOCOL:
        raise Reject("unsupported_protocol", f"protocol must be {PROTOCOL!r}, got {req.get('protocol')!r}", "request",
                     [_diag("protocol", "protocol", f"this toolchain speaks {PROTOCOL} only")])
    if req.get("op") != "compile":
        raise Reject("unsupported_op", f"op must be 'compile', got {req.get('op')!r}", "request",
                     [_diag("op", "op", "the only operation is compile")])
    preset = req.get("preset")
    if not isinstance(preset, str) or not PRESET_RE.fullmatch(preset):
        raise Reject("bad_request", "preset must be a string matching [a-z0-9][a-z0-9_-]{0,63}", "request",
                     [_diag("type", "preset", f"got {preset!r}", "one of: " + ", ".join(PRESETS))])
    if preset not in PRESETS:
        close = difflib.get_close_matches(preset, list(PRESETS), n=1, cutoff=0.5)
        raise Reject("unknown_preset", f"no preset named {preset!r}", "validate",
                     [_diag("unknown_preset", "preset", f"{preset!r} is not a preset of this toolchain",
                            (f"did you mean {close[0]!r}? " if close else "") + "presets: " + ", ".join(PRESETS))])
    params = req.get("params", {})
    if params is None:
        params = {}
    if not isinstance(params, dict):
        raise Reject("invalid_params", "params must be a JSON object", "validate",
                     [_diag("type", "params", f"got a {_json_type(params)}", 'for example {"M1": 430}')])
    return preset, params


def _json_type(v) -> str:
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "boolean"
    if isinstance(v, (int, float)):
        return "number"
    if isinstance(v, str):
        return "string"
    if isinstance(v, list):
        return "array"
    return "object"


_INT_TEXT = re.compile(r"\s*[+-]?\d{1,15}\s*")


def as_int(v) -> int:
    """A whole number from JSON: an integer, an integral number such as 48.0, or a numeric string such as "48"
    (values that went through OKX's CLI arrive as strings). Raises ValueError with the reason."""
    if isinstance(v, bool):
        raise ValueError("must be a whole number, got a boolean")
    if isinstance(v, int):
        return v
    if isinstance(v, float):
        if math.isfinite(v) and v.is_integer() and abs(v) < 2 ** 53:
            return int(v)
        raise ValueError(f"must be a whole number, got {v!r}")
    if isinstance(v, str):
        if _INT_TEXT.fullmatch(v):
            return int(v)
        raise ValueError(f"must be a whole number, got the string {v!r}")
    raise ValueError(f"must be a whole number, got {'an' if _json_type(v)[0] in 'aeiou' else 'a'} {_json_type(v)}")


# ================================================================================================ flow-governor: validation

@dataclass(frozen=True)
class Param:
    section: str          # "chip" or "envelope" (of fg_params.json)
    lo: int
    hi: int
    meaning: str


# What a buyer may set. Ranges are the bit width of the localparam (gen_params.CHIP_WIDTHS / ENV_WIDTHS)
# intersected with the factory limits of chips/INTERFACE.md section 7; the relations between them come after.
FG_TUNABLE = {
    "M1": Param("chip", 0, 1023, "allowance milestone 1: the TAXCUM code (lg8 of cumulative tax) where tier 1 starts"),
    "M2": Param("chip", 0, 1023, "allowance milestone 2 (tier 2)"),
    "M3": Param("chip", 0, 1023, "allowance milestone 3 (tier 3)"),
    "AL0": Param("chip", 0, 63, "allowance share at tier 0, in 1/256 of fresh tax (equals capT)"),
    "AL1": Param("chip", 0, 63, "allowance share at tier 1"),
    "AL2": Param("chip", 0, 63, "allowance share at tier 2"),
    "AL3": Param("chip", 0, 63, "allowance share at tier 3 (at least fbAllow)"),
    "CEIL0": Param("chip", 0, 1023, "allowance ceiling per settle at tier 0, lg8 code; 8 codes lower per tier (equals ceilMax)"),
    "RC": Param("chip", 0, 255, "reserve share in ordinary flow (CRUISE), in 1/256 of fresh tax"),
    "FLOOR_Q": Param("chip", 0, 1023, "quiet floor before graduation, lg8 code of tax per epoch (FLOOR_T follows)"),
    "RESMIN_Q": Param("chip", 0, 1023, "smallest reserve for a DEFEND window before graduation, lg8 code (RESMIN_T follows)"),
    "capT": Param("envelope", 0, 128, "kernel cap on T_ALLOW (factory: at most 128)"),
    "allowCumBps": Param("envelope", 0, 5000, "lifetime allowance cap in basis points of inflow (factory: at most 5000)"),
    "ceilMax": Param("envelope", 0, 1023, "kernel ceiling on the allowance per settle, lg8 code; 1023 = none"),
    "relMax": Param("envelope", 1, 256, "kernel cap on REL (factory: 1 to 256)"),
    "floorRel": Param("envelope", 1, 256, "kernel floor on REL (factory: 1 to relMax)"),
    "floorMin": Param("envelope", 1, 425, "reserve code from which the floor applies (factory: 1 to 425)"),
    "epochLen": Param("envelope", 300, 86400, "seconds per epoch (factory: 300 to 86400)"),
    "fallbackEpochs": Param("envelope", 2, 65535, "epochs without a step before the fallback word (factory: at least 2)"),
    "fbAllow": Param("envelope", 0, 128, "allowance share of the fallback word (factory: at most capT)"),
}

_PINNED = "pinned by chips/rtl/gen_params.py (check_constraints) for this chip revision"
FG_FIXED = {
    "SURGE_TH": _PINNED + "; a signed-off threshold of the control law",
    "XSURGE_TH": _PINNED + "; a signed-off threshold of the control law",
    "DIP_TH": _PINNED + "; a signed-off threshold of the control law",
    "DD_TH": _PINNED + "; a signed-off threshold of the control law",
    "DRYN": _PINNED + "; the inductive invariant P4 (chips/props/fg_props.v) is written for DRYN 8 and WARMN 3",
    "WARMN": _PINNED + "; the inductive invariant P4 is written for DRYN 8 and WARMN 3",
    "CDN": _PINNED + "; the inductive invariant P4 bounds the cooldown counter by CDN - 1 = 5",
    "TRN": "fixed by the RTL: fg_core.v opens a window with TR1 = 4 - nen",
    "LEAK": "fixed by the RTL: fg_core.v leaks 2 * dt (and the envelope floor floorRel may not exceed it)",
    "SLEW_Q": "fixed by the RTL: fg_core.v limits the fall of the average to 12 * dt",
    "PK_DIV": "fixed by the RTL: the peak prescaler of fg_core.v is two bits",
    "SUR_ON": "fixed by the RTL: fg_core.v enters BANK when the surge meter reaches 2",
    "RB_GAIN": "fixed by the RTL: fg_core.v computes RB_MIN + 4 * gg",
    "RB_MIN": _PINNED, "RB_SPAN": _PINNED,
    "CEIL_STEP": "fixed by the RTL: fg_core.v lowers the ceiling by 8 codes per tier",
    "TR_MIN": _PINNED + "; P6 and the leak bound LEAK * 15 <= TR_MIN rely on it",
    "TR_MAX": _PINNED + "; relMax must equal 2 * TR_MAX",
    "LOG8DT": "derived: round(8 * log2(dt)), checked entry by entry by gen_params.py",
    "name": "the chip's name", "version": "the chip's version",
    "nIn": "the covenant-v1 interface shape", "nOut": "the covenant-v1 interface shape",
    "nState": "the covenant-v1 interface shape (64 latches in this chip)",
    "capV": "kernel v1 has no revenue route; the chip's V_ALLOW is 0",
    "buyEnabled": "the kernel v1 factory refuses an envelope with buys disabled (chips/INTERFACE.md section 7)",
}
FG_DERIVED = {
    "FLOOR_T": ("FLOOR_Q", "FLOOR_Q + TOKEN_SHIFT, the same floor in token units after graduation"),
    "RESMIN_T": ("RESMIN_Q", "RESMIN_Q + TOKEN_SHIFT, the same minimum in token units after graduation"),
    "TOKEN_SHIFT": (None, "derived by gen_params.py from the reference token's curve (pairSupply / graduationQuote)"),
    "REL_CAP": ("relMax", "2 * TR_MAX, the largest release the chip asks for"),
}
FG_REFERENCE = ("taxBuyBps", "taxSellBps", "curveBuyFeeBps", "curveSellFeeBps", "totalSupply", "curveSupply",
                "pairSupply", "graduationQuote")

_GEN = None


def gen_params():
    """chips/rtl/gen_params.py as a module (render and the three check functions)."""
    global _GEN
    if _GEN is None:
        spec = importlib.util.spec_from_file_location("gen_params", FG_GEN_PARAMS)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _GEN = mod
    return _GEN


def reference_doc() -> dict:
    with open(FG_PARAMS_JSON, "r", encoding="utf-8") as f:
        return json.load(f)


def _lg8_ok(km, d: dict, q: int, shift: int) -> bool:
    """gen_params.check_reference: the code of exp8(q) quote, converted at the pair's opening price, is q + shift."""
    return km.lg8(km.exp8(q) * d["D"] // d["raised"]) == q + shift


def validate_flow_governor(params: dict) -> tuple:
    """(doc, overrides): the full fg_params.json document with the overrides applied, and the overrides as
    whole numbers. Raises Reject("invalid_params", stage "validate") with every diagnostic found."""
    gp = gen_params()
    km = gp.km
    ref = reference_doc()
    diags = []
    over = {}
    known = list(FG_TUNABLE) + list(FG_FIXED) + list(FG_DERIVED) + list(FG_REFERENCE)
    for name in sorted(params):
        v = params[name]
        path = f"params.{name}"
        if name in FG_TUNABLE:
            spec = FG_TUNABLE[name]
            try:
                n = as_int(v)
            except ValueError as e:
                diags.append(_diag("type", path, f"{name} {e}", f"{name}: {spec.meaning}"))
                continue
            if not spec.lo <= n <= spec.hi:
                diags.append(_diag("range", path, f"{name} must be between {spec.lo} and {spec.hi}, got {n}",
                                   f"{name}: {spec.meaning}"))
                continue
            over[name] = n
        elif name in FG_FIXED:
            section = "envelope" if name in ref["envelope"] else "chip"
            current = ref[section][name]
            same = v == current
            if not same and isinstance(current, int) and not isinstance(current, bool):
                try:
                    same = as_int(v) == current
                except ValueError:
                    same = False
            if not same:
                diags.append(_diag("fixed", path, f"{name} is fixed at {json.dumps(current)}: {FG_FIXED[name]}",
                                   f"leave {name} out (or send {json.dumps(current)})"))
        elif name in FG_DERIVED:
            src, why = FG_DERIVED[name]
            diags.append(_diag("derived", path, f"{name} cannot be set: it is {why}",
                               f"set {src} instead" if src else "it follows from the reference token"))
        elif name in FG_REFERENCE:
            diags.append(_diag("fixed", path, f"{name} belongs to the reference token, which is fixed for this service",
                               "the token-regime thresholds are derived from it"))
        else:
            close = [k for k in known if k.lower() == name.lower()] or difflib.get_close_matches(name, known, n=1,
                                                                                             cutoff=0.6)
            diags.append(_diag("unknown_param", path, f"{name!r} is not a parameter of flow-governor",
                               (f"did you mean {close[0]!r}? " if close else "")
                               + "tunable: " + ", ".join(FG_TUNABLE)))
    if diags:
        raise Reject("invalid_params", _summary(diags), "validate", diags)

    doc = copy.deepcopy(ref)
    c, e = doc["chip"], doc["envelope"]
    for name, n in over.items():
        doc[FG_TUNABLE[name].section][name] = n
    d = gp.reference(doc)
    shift = d["shift"]
    c["FLOOR_T"] = c["FLOOR_Q"] + shift
    c["RESMIN_T"] = c["RESMIN_Q"] + shift

    def bad(names, message, hint):
        path = next((n for n in names if n in over), names[0])
        diags.append(_diag("relation", f"params.{path}", message, hint))

    if not c["M1"] < c["M2"] < c["M3"]:
        bad(["M1", "M2", "M3"], f"the milestones must increase, M1 < M2 < M3: got {c['M1']}, {c['M2']}, {c['M3']}",
            "each milestone is a TAXCUM code; the tier steps up as cumulative tax passes them")
    if not c["AL0"] >= c["AL1"] >= c["AL2"] >= c["AL3"]:
        bad(["AL0", "AL1", "AL2", "AL3"], "the allowance shares must not grow with the tier, AL0 >= AL1 >= AL2 >= AL3: "
            f"got {c['AL0']}, {c['AL1']}, {c['AL2']}, {c['AL3']}", "a higher tier never pays more (property P3)")
    if c["AL0"] != e["capT"]:
        bad(["capT", "AL0"] if "capT" in over else ["AL0", "capT"],
            f"AL0 ({c['AL0']}) must equal the envelope's capT ({e['capT']}): the envelope is exactly the chip's worst case",
            f"set capT to {c['AL0']}" if "AL0" in over else f"set AL0 to {e['capT']}")
    need = -(-e["capT"] * 10000 // 256)
    if e["allowCumBps"] * 256 < e["capT"] * 10000:
        bad(["allowCumBps", "capT", "AL0"],
            f"allowCumBps ({e['allowCumBps']}) must be at least capT * 10000 / 256 = {need} for capT {e['capT']}: "
            "otherwise the kernel's lifetime cap (K2L) could clip the chip",
            f"set allowCumBps to {need} or more")
    if e["fbAllow"] > c["AL3"]:
        bad(["fbAllow", "AL3"], f"fbAllow ({e['fbAllow']}) must be at most AL3 ({c['AL3']}): the fallback word must not "
            "pay more than the ratchet's last tier", f"set fbAllow to {c['AL3']} or less")
    if e["fbAllow"] > e["capT"]:
        bad(["fbAllow", "capT"], f"factory check: fbAllow ({e['fbAllow']}) must be at most capT ({e['capT']})",
            f"set fbAllow to {min(e['capT'], c['AL3'])} or less")
    if c["CEIL0"] != e["ceilMax"]:
        bad(["ceilMax", "CEIL0"] if "ceilMax" in over else ["CEIL0", "ceilMax"],
            f"CEIL0 ({c['CEIL0']}) must equal the envelope's ceilMax ({e['ceilMax']})",
            f"set ceilMax to {c['CEIL0']}" if "CEIL0" in over else f"set CEIL0 to {e['ceilMax']}")
    if c["CEIL0"] < 3 * c["CEIL_STEP"]:
        bad(["CEIL0", "ceilMax"], f"CEIL0 must be at least {3 * c['CEIL_STEP']}: the ceiling drops by "
            f"{c['CEIL_STEP']} codes per tier over three tiers, got {c['CEIL0']}", f"use {3 * c['CEIL_STEP']} or more")
    if c["RC"] + c["AL0"] > 256:
        bad(["RC", "AL0", "capT"], f"RC + AL0 must be at most 256, got {c['RC']} + {c['AL0']}: the buy share in "
            "CRUISE is 256 - AL0 - RC", f"use RC <= {256 - c['AL0']}")
    if c["RB_MIN"] + c["RB_GAIN"] * c["RB_SPAN"] + (c["AL0"] >> 1) > 256:
        bad(["AL0", "capT"], "RB_MIN + RB_GAIN * RB_SPAN + AL0 / 2 must be at most 256 (the BANK shares)",
            "use a smaller AL0")
    if 2 * c["TR_MAX"] != e["relMax"]:
        bad(["relMax"], f"relMax must be {2 * c['TR_MAX']} (twice TR_MAX, the largest release the chip asks for), "
            f"got {e['relMax']}", f"set relMax to {2 * c['TR_MAX']}")
    if e["floorRel"] > c["LEAK"]:
        bad(["floorRel"], f"floorRel ({e['floorRel']}) must be at most the chip's leak LEAK ({c['LEAK']}): the chip "
            "meets the kernel's floor with its leak", f"use floorRel 1 to {c['LEAK']}")
    if e["floorRel"] > e["relMax"]:
        bad(["floorRel", "relMax"], f"factory check: floorRel ({e['floorRel']}) must be at most relMax ({e['relMax']})",
            "lower floorRel")
    if e["epochLen"] * 178 > gp.THIRTY_DAYS * e["floorRel"]:
        bad(["epochLen", "floorRel"], "factory check: epochLen * 178 <= 2592000 * floorRel (the reserve must halve "
            f"within 30 days at the floor), got epochLen {e['epochLen']} with floorRel {e['floorRel']}",
            f"use epochLen <= {gp.THIRTY_DAYS * e['floorRel'] // 178} for floorRel {e['floorRel']}")
    if e["epochLen"] * e["fallbackEpochs"] > gp.THIRTY_DAYS:
        bad(["fallbackEpochs", "epochLen"], "factory check: epochLen * fallbackEpochs <= 2592000 (the fallback word "
            f"applies within 30 days), got {e['epochLen']} * {e['fallbackEpochs']}",
            f"use fallbackEpochs <= {gp.THIRTY_DAYS // e['epochLen']} for epochLen {e['epochLen']}")
    if c["FLOOR_T"] + max(c["LOG8DT"]) >= 1024:
        bad(["FLOOR_Q"], f"FLOOR_Q + TOKEN_SHIFT + {max(c['LOG8DT'])} must stay below 1024 (FLOOR_T = FLOOR_Q + "
            f"{shift}), got FLOOR_Q {c['FLOOR_Q']}", f"use FLOOR_Q <= {1023 - shift - max(c['LOG8DT'])}")
    elif not _lg8_ok(km, d, c["FLOOR_Q"], shift):
        bad(["FLOOR_Q"], f"FLOOR_T = FLOOR_Q + {shift} is not the code of FLOOR_Q converted to tokens at the pair's "
            f"opening price for FLOOR_Q {c['FLOOR_Q']} (a code is 9% wide, so the conversion lands one code off)",
            _nearest(km, d, c["FLOOR_Q"], shift, 1023 - shift - max(c["LOG8DT"])))
    if c["RESMIN_T"] > 1023:
        bad(["RESMIN_Q"], f"RESMIN_T = RESMIN_Q + {shift} must fit 10 bits, got RESMIN_Q {c['RESMIN_Q']}",
            f"use RESMIN_Q <= {1023 - shift}")
    elif not _lg8_ok(km, d, c["RESMIN_Q"], shift):
        bad(["RESMIN_Q"], f"RESMIN_T = RESMIN_Q + {shift} is not the code of RESMIN_Q converted to tokens at the pair's "
            f"opening price for RESMIN_Q {c['RESMIN_Q']}", _nearest(km, d, c["RESMIN_Q"], shift, 1023 - shift))
    if diags:
        raise Reject("invalid_params", _summary(diags), "validate", diags)

    # The same relations, run by gen_params.py itself on the merged document: the source of truth.
    try:
        gp.check_constraints(doc)
        gp.check_envelope(doc)
        gp.check_reference(doc)
        gp.render(doc)
    except AssertionError as e:
        diags.append(_diag("relation", "params", f"chips/rtl/gen_params.py refuses these constants: {e}"))
        raise Reject("invalid_params", _summary(diags), "validate", diags)
    return doc, dict(sorted(over.items()))


def _nearest(km, d, q: int, shift: int, hi: int) -> str:
    below = next((v for v in range(q - 1, -1, -1) if _lg8_ok(km, d, v, shift)), None)
    above = next((v for v in range(q + 1, hi + 1) if _lg8_ok(km, d, v, shift)), None)
    return "nearest values that convert exactly: " + ", ".join(str(v) for v in (below, above) if v is not None)


def _summary(diags: list) -> str:
    first = diags[0]["message"]
    return first if len(diags) == 1 else f"{first} (and {len(diags) - 1} more)"


# ================================================================================================ cost

def okb(wei: int) -> str:
    whole, frac = divmod(wei, WEI_PER_OKB)
    frac_s = str(frac).rjust(18, "0").rstrip("0")
    return f"{whole}.{frac_s}" if frac_s else str(whole)


def unit_price_wei() -> int:
    raw = os.environ.get("TAPC_TRANSISTOR_PRICE_WEI")
    if raw is None:
        return UNIT_PRICE_WEI
    if not re.fullmatch(r"\d{1,30}", raw):
        raise Fault("TAPC_TRANSISTOR_PRICE_WEI must be a whole number of wei")
    return int(raw)


def cost_of(m: dict) -> dict:
    """Transistors x the processor's mint price, plus TapeOut's mint and tape-out fees (and gas estimates)."""
    price = unit_price_wei()
    gates, nand, latch = m["gateCount"], m["nNand"], m["nLatch"]
    calls = (1 if nand else 0) + (1 if latch else 0)
    transistors = gates * price
    total = transistors + calls * PROTOCOL_FEE_WEI + TAPEOUT_FEE_WEI
    return {
        "transistors": gates, "nNand": nand, "nLatch": latch, "currency": "OKB",
        "unitPriceWei": str(price), "unitPriceOKB": okb(price),
        "transistorCostWei": str(transistors), "transistorCostOKB": okb(transistors),
        "mintCalls": calls, "mintFeeWei": str(PROTOCOL_FEE_WEI), "mintFeesWei": str(calls * PROTOCOL_FEE_WEI),
        "tapeoutFeeWei": str(TAPEOUT_FEE_WEI),
        "totalWei": str(total), "totalOKB": okb(total),
        "fees": ("TapeOut's current fees: protocolFee() 0.00066 OKB per mint call (one for NAND, one for LATCH) and "
                 "TAPEOUT_FEE() 0.0013 OKB, read from the TapeOut factory on X Layer on 2026-10-04. The transistor "
                 "price 0.00002 OKB is the Covenant processor's mint price. Gas is extra; Fab.quote(netlist) on "
                 "chain is authoritative."),
        "gas": {"tapeoutEstimate": 242_000 + 408 * m["bytes"],
                "stepBound": 101_730 + 2_293 * nand + 3_059 * latch,
                "kernelStepBudget": 200_000 + 2_600 * gates + 800 * m["nState"],
                "note": ("tapeoutEstimate is a fit to fork measurements (chips/tools/NOTES.md section 7); stepBound and "
                         "kernelStepBudget are the formulas of chips/INTERFACE.md section 2")},
    }


# ================================================================================================ proof jobs

GROUP_TITLES = {
    "P1": "share groups sum to 256, each share at most 256, no holder share",
    "P2": "clamp-freedom against the requested envelope (K2, K2V, K3, K5, K2C, K2L)",
    "P3": "ratchets: the tier never decreases, allowance and ceiling bounded by it, none after graduation",
    "P4": "inductive state invariant, true at reset",
    "EQ": "netlist bytes == RTL for every state and input",
    "P5": "unused inputs are ignored",
    "P6": "cooldown: only the leak while resting, the counter strictly decreases",
    "PX": "extras: DT = 0 reads as 1, graduation seen once, the graduation step only re-seeds",
    "P7": "reachability witness",
    "GLUTTON": "what the hostile chip does, proven on its bytes",
}
SPACE = "for every 64-bit state and 96-bit input word"
ENGINE_KEY = {"yosys-sat": "yosys", "z3": "z3", "argument + randomized test": "k2l", "tapc.sim": "sim"}


@dataclass
class Check:
    id: str
    group: str
    check: str
    engine: str
    match: str            # the ProofResult name the worker reports for it


@dataclass
class Job:
    key: str
    spec: dict
    checks: list = field(default_factory=list)
    proc: Optional[subprocess.Popen] = None
    started: float = 0.0
    seconds: float = 0.0
    state: str = "queued"     # queued | running | done | timeout | skipped
    result: Optional[dict] = None
    log: str = ""


def _group_of(name: str) -> str:
    return name.split("_", 1)[0].upper()


def wrapper_signals(path: str, top: str) -> list:
    """The 1-bit outputs of a property wrapper, in port order, read from its source."""
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    m = re.search(rf"\bmodule\s+{re.escape(top)}\s*\((.*?)\);", text, re.S)
    if not m:
        raise Fault(f"no module {top} in {path}")
    return re.findall(r"\boutput\s+wire\s+(\w+)", m.group(1))


def byte_predicates(path: str) -> list:
    """Names of the prop_* functions of a predicate file (without the prefix), as tapc.prove.load_predicates
    orders them, read from the source so the parent process need not import z3 or the model."""
    with open(path, "r", encoding="utf-8") as f:
        return sorted(re.findall(r"^def prop_(\w+)\(", f.read(), re.M))


def fg_jobs(work: str, tap: str, params_json: str, sources: list, props_vh: str) -> list:
    """The flow-governor job list, in queue order: the pin manifest, the buyer groups, EQ, the rest."""
    sigs = wrapper_signals(FG_PROPS_V, "fg_props")
    preds = byte_predicates(FG_PROPS_PY)
    buyer = ("P1", "P2", "P3", "P4")
    rest = ("P5", "P6", "PX")

    def props_job(key, groups):
        chosen = [s for s in sigs if _group_of(s) in groups]
        return Job(key, {"kind": "props", "sources": [props_vh, FG_PROPS_V], "top": "fg_props", "signals": chosen,
                         "tap": tap, "tap_module": "fg_tap", "engine": "yosys", "work": os.path.join(work, key)},
                   [Check(f"{_group_of(s)}.{s}.yosys", _group_of(s), s, "yosys-sat", f"fg_props.{s}") for s in chosen])

    def preds_job(key, groups, k2l):
        chosen = [p for p in preds if _group_of(p) in groups]
        checks = [Check(f"{_group_of(p)}.{p}.z3", _group_of(p), p, "z3", f"bytes: {p}") for p in chosen]
        if k2l:
            checks.append(Check("P2.k2l_lifetime_cap.argument", "P2", "k2l_lifetime_cap", "argument + randomized test",
                                "K2L never binds (lifetime cap)"))
        return Job(key, {"kind": "preds", "props_py": FG_PROPS_PY, "names": chosen, "tap": tap,
                         "params": params_json, "k2l": k2l, "work": os.path.join(work, key)}, checks)

    def equiv_job(engine):
        key = f"eq-{engine}"
        eng = "yosys-sat" if engine == "yosys" else "z3"
        return Job(key, {"kind": "equiv", "engine": engine, "sources": sources, "top": "fg_core", "tap": tap,
                         "name": "EQ fg_core == netlist bytes", "work": os.path.join(work, key)},
                   [Check(f"EQ.rtl_equals_bytes.{engine}", "EQ", "rtl_equals_bytes", eng, "EQ fg_core == netlist bytes")])

    pins = Job("pins", {"kind": "pins", "tap": tap, "params": params_json, "work": os.path.join(work, "pins")})
    return [pins,
            props_job("buyer-yosys", buyer), preds_job("buyer-z3", buyer, True),
            equiv_job("yosys"), equiv_job("z3"),
            props_job("rest-yosys", rest), preds_job("rest-z3", rest, False)]


def glutton_jobs(work: str, tap: str, sources: list) -> list:
    sigs = ["p_demands_everything", "p_group_256", "p_heartbeat", "p_ignores_inputs"]
    jobs = []
    for engine, eng in (("yosys", "yosys-sat"), ("z3", "z3")):
        key = f"props-{engine}"
        jobs.append(Job(key, {"kind": "props", "sources": [GL_PROPS_V], "top": "glutton_props", "signals": sigs,
                              "tap": tap, "tap_module": "glutton_tap", "engine": engine,
                              "work": os.path.join(work, key)},
                        [Check(f"GLUTTON.{s}.{engine}", "GLUTTON", s, eng, f"glutton_props.{s}") for s in sigs]))
    for engine, eng in (("yosys", "yosys-sat"), ("z3", "z3")):
        key = f"eq-{engine}"
        jobs.append(Job(key, {"kind": "equiv", "engine": engine, "sources": sources, "top": "glutton_core",
                              "tap": tap, "name": "EQ glutton_core == netlist bytes", "work": os.path.join(work, key)},
                        [Check(f"EQ.rtl_equals_bytes.{engine}", "EQ", "rtl_equals_bytes", eng,
                               "EQ glutton_core == netlist bytes")]))
    return jobs


def _worker_env() -> dict:
    env = dict(os.environ)
    env["PYTHONPATH"] = TOOLS + (os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else "")
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env["PYTHONUNBUFFERED"] = "1"
    return env


def _kill(job: Job) -> None:
    p = job.proc
    if p is None or p.poll() is not None:
        return
    try:
        os.killpg(p.pid, signal.SIGKILL)          # the worker leads its own process group: Yosys goes with it
    except (ProcessLookupError, PermissionError):
        p.kill()
    try:
        p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass


def _tail(path: str, n: int = 4000) -> str:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()[-n:]
    except OSError:
        return ""


def run_jobs(jobs: list, n_jobs: int, deadline: float, work: str) -> None:
    """Run the jobs in worker processes, at most n_jobs at once, in list order. At `deadline` (time.monotonic)
    every job still running is stopped (state "timeout") and every job not started is marked "timeout" as well.
    A job whose result contains a failed proof stops the others (state "skipped")."""
    env = _worker_env()
    queue = list(jobs)
    running: list = []
    try:
        while queue or running:
            now = time.monotonic()
            if now >= deadline:
                for j in running:
                    _kill(j)
                    j.state, j.seconds = "timeout", now - j.started
                for j in queue:
                    j.state = "timeout"
                _log("budget reached: stopped " + (", ".join(j.key for j in running) or "nothing")
                     + (f"; never started: {', '.join(j.key for j in queue)}" if queue else ""))
                return
            while queue and len(running) < n_jobs:
                j = queue.pop(0)
                spec = dict(j.spec)
                spec["timeout"] = max(1, int(deadline - now - 1))
                spec["result"] = os.path.join(work, f"{j.key}.result.json")
                if os.path.exists(spec["result"]):           # left over in a kept directory: never read it
                    os.remove(spec["result"])
                path = os.path.join(work, f"{j.key}.job.json")
                with open(path, "w", encoding="utf-8") as f:
                    json.dump(spec, f)
                j.spec = spec
                j.log = os.path.join(work, f"{j.key}.log")
                with open(j.log, "w", encoding="utf-8") as logf:
                    j.proc = subprocess.Popen([sys.executable, "-m", "tapc.architect", "--worker", path],
                                              stdin=subprocess.DEVNULL, stdout=logf, stderr=subprocess.STDOUT,
                                              cwd=work, env=env, start_new_session=True)
                j.started, j.state = time.monotonic(), "running"
                running.append(j)
            for j in list(running):
                if j.proc.poll() is None:
                    continue
                running.remove(j)
                j.seconds = time.monotonic() - j.started
                try:
                    with open(j.spec["result"], "r", encoding="utf-8") as f:
                        j.result = json.load(f)
                except (OSError, json.JSONDecodeError):
                    raise Fault(f"proof worker {j.key} exited with code {j.proc.returncode} and no result:\n"
                                + _tail(j.log))
                if not j.result.get("ok"):
                    raise Fault(f"proof worker {j.key} failed: {j.result.get('error')}\n{j.result.get('traceback', '')}")
                j.state = "done"
                rows = j.result.get("rows", [])
                n_ok = sum(r["status"] == "proved" for r in rows)
                _log(f"{j.key}: {n_ok}/{len(rows)} proved in {j.seconds:.1f} s" if rows else
                     f"{j.key}: done in {j.seconds:.1f} s")
                if any(r["status"] == "failed" for r in rows):
                    for k in running:
                        _kill(k)
                        k.state = "skipped"
                    for k in queue:
                        k.state = "skipped"
                    _log(f"{j.key}: a proof FAILED; stopped the remaining jobs")
                    return
            time.sleep(0.05)
    finally:
        for j in running:
            _kill(j)


def proof_rows(jobs: list) -> list:
    """The `proofs` array of the answer, in job order, one row per check."""
    rows = []
    for j in jobs:
        got = {}
        for r in (j.result or {}).get("rows", []):
            got.setdefault(r["name"], r)
        for c in j.checks:
            row = {"id": c.id, "group": c.group, "title": GROUP_TITLES.get(c.group, ""), "check": c.check,
                   "engine": c.engine}
            r = got.get(c.match) if j.state == "done" else None
            if r is None and j.state == "done":
                raise Fault(f"proof worker {j.key} did not report {c.match!r}")
            if r is not None:
                status = r["status"]
                if status not in ("proved", "failed", "timeout"):
                    raise Fault(f"{c.id}: the prover returned {status!r}: {r.get('detail', '')}")
                row["status"] = status
                row["seconds"] = round(float(r.get("seconds", 0.0)), 2)
                if status == "proved":
                    row["detail"] = r.get("detail") or f"proved {SPACE} ({c.engine}, on the netlist bytes)"
                elif status == "failed":
                    cex = r.get("counterexample") or {}
                    row["detail"] = "counterexample: " + (", ".join(f"{k}={v}" for k, v in sorted(cex.items()))
                                                          or r.get("detail", "the solver found one"))
                    if cex:
                        row["counterexample"] = cex
                else:
                    row["detail"] = r.get("detail") or "no verdict within the time budget"
            elif j.state == "timeout":
                row["status"], row["seconds"] = "timeout", round(j.seconds, 2)
                row["detail"] = ("stopped at the time budget before a verdict" if j.started
                                 else "not started before the time budget ran out")
            else:
                row["status"] = "skipped"
                row["detail"] = j.spec.get("reason") or "not run: another proof failed first"
            rows.append(row)
    return rows


# ================================================================================================ worker side

def _watch_parent() -> None:
    """Kill this worker's whole process group (it and its Yosys) if the parent disappears, for example when the
    service kills the request's process group after its own time limit."""
    parent = os.getppid()

    def watch():
        while True:
            time.sleep(0.5)
            if os.getppid() != parent:
                os.killpg(os.getpgrp(), signal.SIGKILL)

    threading.Thread(target=watch, daemon=True).start()


def _load_model(params_json: Optional[str]):
    """chips/model/flow_governor.py with the request's constants. The model, the byte-level predicates
    (chips/props/fg_props.py) and the pin-manifest generator (chips/synth/gen_pins.py) all read the constants
    from the dicts flow_governor.P and flow_governor.ENV, so they are updated in place before anything else is
    imported. This happens only in a worker process that serves this one request."""
    for p in (SYNTH_DIR, PROPS_DIR, MODEL_DIR, GOLDEN_DIR, TAPS_ASSETS):
        if p not in sys.path:
            sys.path.insert(0, p)
    import flow_governor as fg
    if params_json:
        with open(params_json, "r", encoding="utf-8") as f:
            doc = json.load(f)
        for live, new in ((fg.P, doc["chip"]), (fg.ENV, doc["envelope"])):
            live.clear()
            live.update(new)
    return fg


def _rows(results) -> list:
    return [{"name": r.name, "status": r.status, "engine": r.engine, "seconds": r.seconds,
             "counterexample": {k: hex(v) for k, v in sorted(r.counterexample.items())}, "detail": r.detail}
            for r in results]


def _worker_job(spec: dict) -> dict:
    from . import netlist as N
    from . import prove as tp
    kind = spec["kind"]
    with open(spec["tap"], "rb") as f:
        data = f.read()
    nl = N.check(data, 96, 112)
    timeout = int(spec["timeout"])
    if kind == "pins":
        _load_model(spec["params"])
        import gen_pins
        import pins_reference as PR
        with open(PIN_PROFILE, "rb") as f:
            profile = f.read()
        doc = gen_pins.build(data, profile)
        text = gen_pins.dump(doc)
        report = gen_pins.check_format(text, data, profile) + gen_pins.check_against_sources(doc)
        return {"pins": {"sha256": PR.sha256(text), "bytes": len(text), "content": text.decode("ascii"),
                         "report": report}}
    if kind == "props":
        rs = tp.prove_properties(spec["sources"], spec["top"], spec["signals"], tap=nl, tap_module=spec["tap_module"],
                                 work=spec["work"], timeout=timeout, engine=spec["engine"])
        return {"rows": _rows(rs)}
    if kind == "preds":
        _load_model(spec["params"])
        preds = dict(tp.load_predicates(spec["props_py"]))
        rs = tp.check_z3(nl, [(n, preds[n]) for n in spec["names"]], timeout=timeout)
        for r in rs:
            r.name = "bytes: " + r.name
        rows = _rows(rs)
        if spec.get("k2l"):
            import prove as fgprove          # chips/props/prove.py: the K2L argument and its randomized test
            row = fgprove.check_k2l()
            rows.append({"name": row["name"], "status": row["status"], "engine": row["engine"],
                         "seconds": row["seconds"], "counterexample": {},
                         "detail": "allowCumBps * 256 >= capT * 10000, so a sum of per-settle floors never exceeds "
                                   "the lifetime cap; " + row["detail"]})
        return {"rows": rows}
    if kind == "equiv":
        f = tp.equiv_yosys if spec["engine"] == "yosys" else tp.equiv_z3
        return {"rows": _rows([f(spec["sources"], spec["top"], nl, work=spec["work"], timeout=timeout,
                                 name=spec["name"])])}
    raise ValueError(f"unknown job kind {kind!r}")


def worker_main(spec_path: str) -> int:
    _watch_parent()
    with open(spec_path, "r", encoding="utf-8") as f:
        spec = json.load(f)
    try:
        out = {"ok": True, **_worker_job(spec)}
    except BaseException as e:            # noqa: BLE001 - the parent turns this into a fault
        out = {"ok": False, "error": f"{type(e).__name__}: {e}", "traceback": traceback.format_exc()}
    tmp = spec["result"] + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(out, f)
    os.replace(tmp, spec["result"])
    return 0


# ================================================================================================ the pipeline

@dataclass
class Options:
    budget: float = DEFAULT_BUDGET
    jobs: int = DEFAULT_JOBS
    keep: Optional[str] = None


def _synthesize(sources: list, name: str, top: str, pins: str, work: str, deadline: float):
    from . import netlist as N
    from . import pack, synth
    t = time.monotonic()
    try:
        r = synth.synthesize(sources, name, out_dir=os.path.join(work, "out"), top=top, recipe=RECIPE,
                             build_dir=os.path.join(work, "build"), pins=pack.load_pins(pins), n_in=96, n_out=112,
                             timeout=max(5.0, deadline - time.monotonic()), jobs=1, max_bytes=MAX_NETLIST_BYTES)
    except synth.SynthError as e:
        if str(e).startswith("netlist is "):
            raise Reject("too_large", str(e), "synth",
                         [_diag("size", "netlist", str(e), "TapeOut takes at most 24,000 bytes per netlist")])
        raise Fault(f"synthesis failed: {e}")
    except pack.PackError as e:
        raise Fault(f"packing failed: {e}")
    m = r.packed.manifest
    _log(f"synth {name}: {m['nNand']} NAND + {m['nLatch']} LATCH, {m['bytes']} bytes, keccak256 {m['keccak256']} "
         f"({time.monotonic() - t:.1f} s, recipe {r.recipe})")
    bad = N.shape_violations(r.packed.netlist, SHAPE)
    if bad:
        raise Reject("shape", f"the netlist does not have the {SHAPE} shape: " + "; ".join(bad), "shape",
                     [_diag("shape", "netlist", v) for v in bad])
    return r


def _finish(preset: str, data: bytes, manifest: dict, jobs: list) -> dict:
    rows = proof_rows(jobs)
    failed = [r for r in rows if r["status"] == "failed"]
    if failed:
        raise Reject("proof_failed", f"{len(failed)} proof(s) failed: " + ", ".join(r["id"] for r in failed), "prove",
                     [_diag("proof_failed", f"proofs.{r['id']}", r["detail"], GROUP_TITLES.get(r["group"], ""))
                      for r in failed], proofs=rows)
    counts = {}
    for r in rows:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    _log(f"{preset}: proofs " + ", ".join(f"{v} {k}" for k, v in sorted(counts.items())))
    return {"ok": True, "netlistHex": "0x" + data.hex(), "manifest": manifest, "proofs": rows, "cost": cost_of(manifest)}


def compile_flow_governor(doc: dict, overrides: dict, opts: Options, work: str, deadline: float) -> dict:
    gp = gen_params()
    src = os.path.join(work, "src")
    os.makedirs(src, exist_ok=True)
    vh = os.path.join(src, "fg_params.vh")               # same basename as the committed file: same manifest
    with open(vh, "w", encoding="utf-8") as f:
        f.write(gp.render(doc))
    params_json = os.path.join(work, "fg_params.json")
    with open(params_json, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=1)
    sources = [vh, FG_CORE]
    r = _synthesize(sources, "fg", "fg_core", FG_PINS, work, deadline)
    tap = r.paths["tap"]
    with open(tap, "rb") as f:
        data = f.read()

    jobs = fg_jobs(work, tap, params_json, sources, vh)
    run_jobs(jobs, opts.jobs, deadline - 1.0, work)
    pins = jobs[0]
    if pins.state == "skipped":                          # stopped because a proof failed: the answer is a rejection
        pin_info = None
    elif pins.state != "done":
        raise Fault("the pin manifest was not built within the time budget")
    else:
        pin_info = pins.result["pins"]
    proofs = jobs[1:]
    witness = Job("p7", {"reason": "not run per request: the witness is generated by the scenario runner for the "
                                   "reference constants (make -C chips/rtl prove); it shows that the chip has state, "
                                   "it bounds nothing"},
                  [Check("P7.witness_and_tour.sim", "P7", "witness_and_tour", "tapc.sim", "")], state="skipped")

    manifest = dict(r.packed.manifest)
    manifest["architect"] = {
        "protocol": PROTOCOL, "preset": "flow-governor", "params": overrides, "recipe": RECIPE, "interface": SHAPE,
        "constants": {"chip": doc["chip"], "envelope": doc["envelope"]},
        "pinManifest": None if pin_info is None else {
            "format": "tapepins 0.1", "sha256": pin_info["sha256"], "bytes": pin_info["bytes"],
            "content": pin_info["content"],
            "note": ("Circuit pin manifest (docs/taps). Publish `content` byte for byte; its SHA-256 is the "
                     "manifestHash for Fab.tapeoutChip(netlist, manifestHash).")},
    }
    return _finish("flow-governor", data, manifest, proofs + [witness])


def compile_glutton(opts: Options, work: str, deadline: float) -> dict:
    sources = [GL_CORE]
    r = _synthesize(sources, "glutton", "glutton_core", GL_PINS, work, deadline)
    tap = r.paths["tap"]
    with open(tap, "rb") as f:
        data = f.read()
    jobs = glutton_jobs(work, tap, sources)
    run_jobs(jobs, opts.jobs, deadline - 1.0, work)
    manifest = dict(r.packed.manifest)
    manifest["architect"] = {
        "protocol": PROTOCOL, "preset": "glutton", "params": {}, "recipe": RECIPE, "interface": SHAPE,
        "hostile": True,
        "note": ("Glutton is the hostile demo chip: on every beat it asks for the whole allowance, the whole reserve "
                 "and no ceiling. It is NOT clamp-free: the kernel's envelope clips it (K2, K3; K2C on a very large "
                 "settle). Its proofs say what it does, not that it is safe. See chips/cells/glutton/README.md."),
        "pinManifest": None,
    }
    return _finish("glutton", data, manifest, jobs)


PRESETS = {"flow-governor": "the Flow Governor vault chip (chips/rtl/fg_core.v)",
           "glutton": "the hostile demo chip (chips/cells/glutton), no params"}
WORK_PREFIX = "tapc-architect-"
STALE_SECONDS = 900          # far longer than any request may run (the service stops one after 280 s at most)


def sweep_stale_workdirs(root: Optional[str] = None) -> None:
    """Remove work directories of earlier requests that were killed outright (SIGKILL from the service after its
    time limit leaves no chance to clean up). Only directories untouched for STALE_SECONDS are removed."""
    root = root or tempfile.gettempdir()
    try:
        names = [n for n in os.listdir(root) if n.startswith(WORK_PREFIX)]
    except OSError:
        return
    now = time.time()
    for n in names:
        path = os.path.join(root, n)
        try:
            if os.path.isdir(path) and now - os.path.getmtime(path) > STALE_SECONDS:
                shutil.rmtree(path, ignore_errors=True)
        except OSError:
            pass


def handle(raw: bytes, opts: Options) -> dict:
    """The whole request: returns the answer (ok true or false). Raises Fault for a toolchain fault."""
    deadline = T0 + opts.budget
    try:
        preset, params = parse_request(raw)
        _log(f"request: preset {preset}, {len(params)} param(s), budget {opts.budget:.0f} s, {opts.jobs} worker(s)")
        if preset == "flow-governor":
            doc, overrides = validate_flow_governor(params)
        else:
            if params:
                diags = [_diag("unknown_param", f"params.{k}", f"{preset} has no parameters", "send params {}")
                         for k in sorted(params)]
                raise Reject("invalid_params", f"{preset} takes no parameters", "validate", diags)
        if not opts.keep:
            sweep_stale_workdirs()
        work = opts.keep or tempfile.mkdtemp(prefix=WORK_PREFIX)
        os.makedirs(work, exist_ok=True)
        try:
            if preset == "flow-governor":
                return compile_flow_governor(doc, overrides, opts, work, deadline)
            return compile_glutton(opts, work, deadline)
        finally:
            if not opts.keep:
                shutil.rmtree(work, ignore_errors=True)
    except Reject as e:
        _log(f"rejected: {e.code} at {e.stage}: {e.message}")
        return e.answer()


def _env_number(name: str, default, kind):
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    try:
        return kind(raw)
    except ValueError:
        raise SystemExit(f"tapc architect: {name}={raw!r} is not a number")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="tapc architect", description=__doc__.split("\n\n")[0],
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--budget", type=float, default=_env_number("TAPC_ARCHITECT_BUDGET", DEFAULT_BUDGET, float),
                   help="wall-clock seconds from the start of the request after which unfinished proofs are stopped "
                        f"and reported as timeout (default {DEFAULT_BUDGET:.0f}, or TAPC_ARCHITECT_BUDGET)")
    p.add_argument("--jobs", type=int, default=_env_number("TAPC_ARCHITECT_JOBS", DEFAULT_JOBS, int),
                   help=f"proof worker processes at once (default {DEFAULT_JOBS}, or TAPC_ARCHITECT_JOBS)")
    p.add_argument("--keep", help="work in this directory and keep it (default: a temporary directory, removed)")
    p.add_argument("--worker", help=argparse.SUPPRESS)
    return p


def main(argv=None) -> int:
    a = build_parser().parse_args(argv)
    if a.worker:
        return worker_main(a.worker)
    if not 5 <= a.budget <= 280:
        print("tapc architect: --budget must be between 5 and 280 seconds", file=sys.stderr)
        return 2
    if not 1 <= a.jobs <= 32:
        print("tapc architect: --jobs must be between 1 and 32", file=sys.stderr)
        return 2
    opts = Options(budget=a.budget, jobs=a.jobs, keep=os.path.abspath(a.keep) if a.keep else None)

    def on_signal(signum, _frame):
        raise SystemExit(128 + signum)        # unwinds through run_jobs, which stops every worker

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    out = sys.stdout
    raw = sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)
    try:
        sys.stdout = sys.stderr               # nothing but the answer may reach stdout
        answer = handle(raw, opts)
    except Fault as e:
        _log(f"FAULT: {e}")
        return EXIT_FAULT
    except Exception:                         # noqa: BLE001 - a bug: say so on stderr, exit 70 (HTTP 502)
        _log("FAULT: unexpected error\n" + traceback.format_exc())
        return EXIT_FAULT
    finally:
        sys.stdout = out
    out.write(json.dumps(answer, separators=(",", ":")) + "\n")
    out.flush()
    _log(f"done in {time.monotonic() - T0:.1f} s: ok={answer['ok']}")
    return EXIT_OK if answer["ok"] else EXIT_REJECTED


if __name__ == "__main__":
    sys.exit(main())
