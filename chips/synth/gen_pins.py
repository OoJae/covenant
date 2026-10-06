"""Generate chips/out/fg.pins.json: the pin manifest of the Flow Governor.

    chips/.venv-fg/bin/python chips/synth/gen_pins.py            # write chips/out/fg.pins.json, print its SHA-256
    chips/.venv-fg/bin/python chips/synth/gen_pins.py --check    # exit 1 if the committed file is not what this
                                                                 # script would write for the committed netlist

The file is a circuit manifest in the format of the draft standard "Circuit Pin Manifest" (docs/taps): the names,
bit positions and encodings of the chip's 96 input bits, 112 output bits and 64 latch bits, bound to one netlist
by keccak256 of its bytes and by nIn, nOut and nState. It is meant to be published as the file
`.well-known/tape-pins.json` of the chip's own container. Its SHA-256 is the `manifestHash` handed to the Fab at
tape-out (chips/INTERFACE.md section 11), so a reader can tell this manifest from a replaced one.

Where every part comes from (nothing about the layout is typed here):

  inputs, outputs   the generic Covenant profile docs/taps/assets/covenant-v1.pins.json, field for field. The
                    profile is claimed by its SHA-256. The four telemetry outputs, which the profile leaves as
                    uninterpreted bits, get this chip's meaning (mode names, tier, flag names, drawdown depth);
  state             STATE_FIELDS of chips/model/flow_governor.py: the same 14 fields, in the same order, as the
                    table in chips/model/FLOW_GOVERNOR.md section 6 (checked below against that table);
  binding           keccak256 of chips/out/fg.tap, and the pin counts the netlist was packed with.

Before the file is written it is checked with the reference implementation of the draft (docs/taps/assets/
pins_reference.py): strict parse, every rule of the format, that it describes exactly this netlist, that it
implements the profile, and that the netlist has the profile's shape. The generic codec driven by the manifest
is then run against the chip model on real vectors (states, input words, output words). The JSON Schema of the
draft is applied too when the `jsonschema` package is installed.

The same sources give the same bytes.
"""
from __future__ import annotations

import json
import os
import random
import re
import sys

sys.dont_write_bytecode = True      # this script imports from directories it does not own
HERE = os.path.dirname(os.path.abspath(__file__))
CHIPS = os.path.dirname(HERE)
ROOT = os.path.dirname(CHIPS)
TAPS = os.path.join(ROOT, "docs", "taps", "assets")
sys.path.insert(0, os.path.join(CHIPS, "model"))
sys.path.insert(0, os.path.join(CHIPS, "tools"))
sys.path.insert(0, TAPS)

import flow_governor as fg  # noqa: E402
from flow_governor import km  # noqa: E402
import pins_reference as PR  # noqa: E402

TAP = os.path.join(CHIPS, "out", "fg.tap")
OUT = os.path.join(CHIPS, "out", "fg.pins.json")
PROFILE = os.path.join(TAPS, "covenant-v1.pins.json")
SCHEMA = os.path.join(TAPS, "pin-manifest.schema.json")
TAPC_PINS = os.path.join(HERE, "fg.pins.json")           # the tapc-pins/1 file `tapc synth --pins` reads
DOC = os.path.join(CHIPS, "model", "FLOW_GOVERNOR.md")

P = fg.P
SPAN = km.LG8_MAX - P["FLOOR_Q"]            # codes above the floor that fit the code range (invariant P4)

# What this chip adds to a field of the profile. `description` replaces the profile's (descriptions and units
# are not compared when a manifest claims a profile); everything else in a profile field is kept as it is.
IGNORED = " The Flow Governor ignores this field."
INPUT_NOTES = {
    "TAX": " The Flow Governor turns it into a rate per epoch with DT and measures it above a floor "
           f"(code {P['FLOOR_Q']} on the curve, code {P['FLOOR_T']} after graduation).",
    "TAXCUM": f" The allowance tier steps up at codes {P['M1']}, {P['M2']} and {P['M3']} (curve regime only).",
    "REV": IGNORED, "REVCUM": IGNORED, "ESC": IGNORED, "PROG": IGNORED, "LOCK": IGNORED,
    "RES": f" A DEFEND window opens only at or above code {P['RESMIN_Q']} (code {P['RESMIN_T']} after graduation).",
    "DT": " The Flow Governor reads 0 as 1 and advances every timer by this number.",
    "GRAD": " On the first beat that sees it the Flow Governor drops its averages and timers and seeds them again "
            "in token units; from then on it asks for no allowance.",
    "ZERO": "",
}
OUTPUT_NOTES = {
    "T_BUY": "", "T_ALLOW": f" At most {P['AL0']}, by tier; 0 while defending and after graduation.",
    "T_HOLD": " Always 0 in the Flow Governor.", "T_RES": "",
    "V_BUY": " Always 0 in the Flow Governor.", "V_HOLD": " Always 0 in the Flow Governor.",
    "V_ALLOW": " Always 0 in the Flow Governor.", "V_RES": " Always 256 in the Flow Governor.",
    "REL": f" {P['LEAK']} per elapsed epoch in every mode; a tranche of {P['TR_MIN']} to {2 * P['TR_MAX']} while "
           "defending.",
    "CEIL": f" Code {P['CEIL0']} less {P['CEIL_STEP']} per tier; never 1023.",
}
TELEMETRY = {
    "MODE": {"encoding": "enum", "values": {str(i): fg.MODE_NAMES[i] for i in range(5)},
             "description": "Mode after this beat; equal to the MODE latch. With a settle every epoch it names the "
                            "routing of this settle."},
    "TIER": {"encoding": "uint", "min": 0, "max": 3,
             "description": "Allowance tier after this beat; equal to the TIER latch. It never decreases."},
    "FLAGS": {"encoding": "flags", "bits": [n for n, _, _ in fg.FLAG_BITS],
              "description": "surge: the reading is at least twice the recent peak. dip: it is at most half the "
                             "average. quiet: it is at or below the floor. release: this beat routes as DEFEND and "
                             "releases a tranche. regime: graduation is seen in this beat. tierup: the tier stepped "
                             "up. cooldown: the chip is in REST after this beat. warm: cold start or warm-up."},
    "AUX": {"encoding": "uint", "unit": "codes",
            "description": "Drawdown depth: codes by which the average sits below its decaying peak, at most 255."},
}
# Encoding of each latch field. Bounds are those of the inductive invariant (property P4): a state the kernel
# can hold never leaves them. Descriptions come from the model.
STATE_ENCODING = {
    "A": {"encoding": "uint", "max": 4 * SPAN, "scale": [1, 4], "unit": "codes above the floor"},
    "PK": {"encoding": "uint", "max": SPAN, "unit": "codes above the floor"},
    "PKDIV": {"encoding": "uint", "unit": "epochs"},
    "MODE": {"encoding": "enum", "values": {str(i): fg.MODE_NAMES[i] for i in range(5)}},
    "TIER": {"encoding": "uint", "min": 0, "max": 3},
    "GSEEN": {"encoding": "bool"},
    "WARM": {"encoding": "uint", "unit": "epochs"},
    "LIVE": {"encoding": "uint", "max": P["DRYN"], "unit": "epochs"},
    "SUR": {"encoding": "uint"},
    "TR": {"encoding": "uint", "unit": "epochs"},
    "CD": {"encoding": "uint", "max": P["CDN"] - 1, "unit": "epochs"},
    "NBANK": {"encoding": "uint"},
    "NDEF": {"encoding": "uint"},
    "CLOCK": {"encoding": "uint", "unit": "epochs"},
}
FIELD_KEYS = ("encoding", "mantissaBits", "min", "max", "scale", "values", "bits", "unit", "description")


def _read(path: str) -> bytes:
    with open(path, "rb") as f:
        return f.read()


def build(netlist: bytes, profile_bytes: bytes) -> dict:
    profile = PR.parse(profile_bytes)
    assert not PR.validate(profile) and "circuit" not in profile, "the profile file is not a valid profile"
    info = PR.scan(netlist)
    assert info["nRef"] == 0 and info["latchesFirst"] and info["nLatch"] == fg.N_STATE

    def from_profile(vec: str, notes: dict, layout) -> list:
        out = []
        assert [f["name"] for f in profile[vec]] == [n for n, _, _ in layout], "profile and kernel model disagree"
        for pf, (name, off, width) in zip(profile[vec], layout):
            assert (pf["offset"], pf["width"]) == (off, width), name
            f = dict(pf)
            if name in TELEMETRY:
                assert pf["encoding"] == "bits", "a telemetry field the profile already interprets"
                f = {"name": name, "offset": off, "width": width, **TELEMETRY[name]}
            else:
                f["description"] = pf["description"] + notes[name]
            out.append({k: f[k] for k in ("name", "offset", "width", *FIELD_KEYS) if k in f})
        return out

    state = []
    for name, off, width, meaning in fg.STATE_FIELDS:
        state.append({"name": name, "offset": off, "width": width, **STATE_ENCODING[name],
                      "description": meaning + "."})
        state[-1] = {k: state[-1][k] for k in ("name", "offset", "width", *FIELD_KEYS) if k in state[-1]}
    assert sum(f["width"] for f in state) == fg.N_STATE == info["nLatch"], "the state fields must name every latch"

    return {
        "tapepins": "0.1",
        "name": P["name"],
        "description": (
            "Flow Governor, a Covenant vault chip (interface v1). Once per epoch a kernel contract builds the 96 "
            "input bits from chain state and runs one beat. The chip keeps a moving average of tax per epoch and "
            "the recent peak of that average in its 64 latches, and answers with the shares that route this "
            "epoch's tax: an immediate buy-and-lock, an allowance that steps down for good as cumulative tax "
            "passes three milestones, and a reserve. It banks more when the rate jumps to twice the recent peak, "
            "releases the reserve in tranches after a drawdown or a drought and pays no allowance while doing "
            "so. The reset state is all zeros. The four telemetry outputs are proven to follow the latches and "
            "the routing; the kernel does not act on them."),
        "circuit": {"netlistHash": PR.netlist_hash(netlist)},
        "profile": {"name": profile["name"], "sha256": PR.sha256(profile_bytes)},
        "nIn": profile["nIn"],
        "nOut": profile["nOut"],
        "nState": info["nLatch"],
        "inputs": from_profile("inputs", INPUT_NOTES, km.INPUT_FIELDS),
        "outputs": from_profile("outputs", OUTPUT_NOTES, km.OUTPUT_FIELDS),
        "state": state,
    }


def dump(doc: dict) -> bytes:
    return (json.dumps(doc, indent=2, ensure_ascii=True) + "\n").encode("ascii")


# ------------------------------------------------------------------------------------------------ checks
def check_format(data: bytes, netlist: bytes, profile_bytes: bytes) -> list:
    """Everything the reference implementation of the draft can check. Returns the lines of a short report."""
    doc = PR.parse(data)                                             # section 3.1: strict file rules
    profile = PR.parse(profile_bytes)
    problems = (PR.validate(doc)                                     # sections 3 to 5
                + PR.check_binding(doc, netlist, km.IN_BITS, km.OUT_BITS, fg.N_STATE, chain_id=196)   # section 4
                + PR.conforms(doc, profile, profile_bytes)           # section 6.3, with the profile digest
                + PR.check_shape(profile, netlist))                  # section 6.2
    assert not problems, problems
    assert "circuit" in doc and "shape" not in doc and len(data) <= PR.MAX_FILE_BYTES
    lines = ["reference validator: valid circuit manifest; describes the netlist (keccak256, nIn, nOut, nState); "
             f"implements profile {doc['profile']['name']} {doc['profile']['sha256']}; netlist has the profile's shape"]
    try:
        import jsonschema
    except ImportError:
        lines.append("JSON Schema: not applied (the jsonschema package is not installed in this environment)")
    else:
        with open(SCHEMA, "r", encoding="utf-8") as f:
            jsonschema.Draft202012Validator(json.load(f)).validate(json.loads(data))
        from importlib.metadata import version
        lines.append(f"JSON Schema (jsonschema {version('jsonschema')}, draft 2020-12): valid")
    return lines


def check_against_sources(doc: dict) -> list:
    """The manifest says what the model, the toolchain's pins file and the public description say."""
    # 1. the tapc-pins/1 file the netlist was packed with
    with open(TAPC_PINS, "r", encoding="utf-8") as f:
        tp = json.load(f)
    for vec in ("inputs", "outputs", "state"):
        assert [(f["name"], f["lsb"], f["width"]) for f in tp[vec]] == \
               [(f["name"], f["offset"], f["width"]) for f in doc[vec]], f"{vec}: differs from chips/synth/fg.pins.json"
    # 2. the latch table of FLOW_GOVERNOR.md section 6: same names, same bits
    with open(DOC, "r", encoding="utf-8") as f:
        text = f.read()
    sec = re.search(r"^## 6\. .*?$(.*?)(?=^## \d+\. )", text, re.S | re.M).group(1)
    rows = re.findall(r"^\|\s*(\d+)(?:-(\d+))?\s*\|\s*`(\w+)`\s*\|", sec, re.M)
    table = [(n, int(lo), int(hi or lo) - int(lo) + 1) for lo, hi, n in rows]
    assert table == [(f["name"], f["offset"], f["width"]) for f in doc["state"]], \
        "FLOW_GOVERNOR.md section 6 and the manifest name the latch bits differently"
    # 3. the generic codec driven by the manifest decodes what the model packs
    rng = random.Random(20261005)
    n = 0
    for _ in range(2000):
        s, x = rng.getrandbits(64), rng.getrandbits(96)
        ns, y = fg.step(s, x)
        for bits, layout in ((s, fg.unpack_state(s)), (ns, fg.unpack_state(ns))):
            dec = PR.decode_vector(doc["state"], bits.to_bytes(8, "little"))
            assert {k: int(v["raw"]) for k, v in dec.items()} == layout
        dec = PR.decode_vector(doc["outputs"], km.word_to_bytes(y, km.OUT_BITS))
        assert {k: int(v["raw"]) for k, v in dec.items()} == km.unpack_output(y)
        dec = PR.decode_vector(doc["inputs"], km.word_to_bytes(x, km.IN_BITS))
        assert {k: int(v["raw"]) for k, v in dec.items()} == km.unpack_fields(km.INPUT_FIELDS, x)
        n += 1
    # 4. on reachable states nothing is undefined or out of range: a walk from reset with kernel-shaped words
    s, seen = 0, 0
    for i in range(20000):
        grad = 1 if i > 12000 else 0
        base = (P["FLOOR_T"] if grad else P["FLOOR_Q"]) + rng.choice([0, 20, 60, 120])
        x = km.pack_input({"TAX": rng.choice([0, 0, min(1023, base + rng.randint(-10, 40)), rng.getrandbits(10)]),
                           "TAXCUM": min(1023, 300 + i // 20), "RES": rng.choice([0, 380, 420, 600, 700]),
                           "DT": rng.choice([1, 1, 1, 2, 5, 15]), "GRAD": grad})
        s, y = fg.step(s, x)
        for vec, data in (("state", s.to_bytes(8, "little")), ("outputs", km.word_to_bytes(y, km.OUT_BITS))):
            for name, v in PR.decode_vector(doc[vec], data).items():
                assert v.get("inRange", True) and v.get("label", "") is not None and not v.get("unnamed"), (vec, name, v)
        seen += 1
    return [f"codec: {n} random beats decode to the model's fields (state before and after, inputs, outputs); "
            f"{seen} beats on a walk from reset show no undefined enum value and no out-of-range field",
            "names and bits equal chips/synth/fg.pins.json (what the netlist was packed with) and the latch table of "
            "FLOW_GOVERNOR.md section 6"]


def main() -> int:
    netlist, profile_bytes = _read(TAP), _read(PROFILE)
    doc = build(netlist, profile_bytes)
    data = dump(doc)
    report = check_format(data, netlist, profile_bytes) + check_against_sources(doc)
    with open(os.path.join(CHIPS, "out", "fg.manifest.json"), "r", encoding="utf-8") as f:
        built = json.load(f)                                           # what `tapc synth` wrote for the same bytes
    assert built["keccak256"] == doc["circuit"]["netlistHash"], "fg.manifest.json is of another netlist"
    assert (built["nIn"], built["nOut"], built["nState"]) == (doc["nIn"], doc["nOut"], doc["nState"])
    digest = PR.sha256(data)
    if "--check" in sys.argv:
        if not os.path.exists(OUT) or _read(OUT) != data:
            print("chips/out/fg.pins.json is stale: run python chips/synth/gen_pins.py")
            return 1
        print(f"chips/out/fg.pins.json is current: {len(data)} bytes, sha256 {digest}")
        return 0
    with open(OUT, "wb") as f:
        f.write(data)
    print(f"wrote {os.path.relpath(OUT, ROOT)}: {len(data)} bytes, {len(doc['inputs'])} input fields, "
          f"{len(doc['outputs'])} output fields, {len(doc['state'])} state fields over {doc['nState']} latches")
    print(f"  netlistHash  {doc['circuit']['netlistHash']}")
    print(f"  profile      {doc['profile']['name']} {doc['profile']['sha256']}")
    for line in report:
        print("  " + line)
    print(f"  sha256       {digest}    <- the manifestHash for tape-out")
    return 0


if __name__ == "__main__":
    sys.exit(main())
