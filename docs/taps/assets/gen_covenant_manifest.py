"""Generate covenant-v1.pins.json, the pin manifest (a profile) of Covenant interface v1, and
covenant-v1.vectors.json, codec vectors for it.

Sources, in this order of authority:
  chips/golden/kernel_model.py   field names, offsets and widths (INPUT_FIELDS, OUTPUT_FIELDS), IN_BITS,
                                 OUT_BITS, LG8_MAX, and every code function (lg8, exp8, prog_code, ...)
  chips/INTERFACE.md             section 2 (chip shape) and the tables of sections 5 and 6
  chips/golden/vectors.json      golden vectors, used only to check the generic codec

No layout number is typed in this file. A number that the model does not export as a constant (the unit
share, the progress scale) is recovered by calling the model and asserted, so a change in the model makes
this script fail instead of writing a stale manifest. Text is typed here; numbers inside text are formatted
from values taken from the model.

Run:  ~/.local/bin/python3.12 docs/taps/assets/gen_covenant_manifest.py        (Python 3.11 or later)
Deterministic: the same sources give the same bytes.
"""
from __future__ import annotations

import json
import os
import re
import sys

sys.dont_write_bytecode = True      # this script only reads from other directories of the repository
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "chips", "golden"))
sys.path.insert(0, HERE)

import kernel_model as km          # noqa: E402
import pins_reference as P         # noqa: E402

MANTISSA_BITS = 3                  # checked against km.lg8 and km.exp8 in check_codes()


# ------------------------------------------------------------------------------------------------ model probes

def check_codes() -> None:
    """The model's lg8 / exp8 are the `log` encoding with MANTISSA_BITS, saturating at LG8_MAX."""
    width = km.LG8_MAX.bit_length()
    assert (1 << width) - 1 == km.LG8_MAX
    xs = list(range(0, 4096)) + [1 << e for e in range(0, 140)] + [(1 << e) - 1 for e in range(1, 140)]
    xs += [10 ** d for d in range(0, 40)]
    assert all(P.log_code(x, MANTISSA_BITS, width) == km.lg8(x) for x in xs)
    assert all(P.log_floor(c, MANTISSA_BITS) == km.exp8(c) for c in range(km.LG8_MAX + 1))


def unit_share() -> int:
    """The value of a share field that means "all of it". The model routes shares as x * share // unit and
    treats a tax group as well-formed only when its four shares sum to the unit."""
    width = dict((n, w) for n, _, w in km.OUTPUT_FIELDS)["T_BUY"]
    env = km.Envelope(capT=(1 << width) - 1, allowCumBps=9999, relMax=(1 << width) - 1, floorRel=1, floorMin=km.LG8_MAX)
    units = [u for u in range(1, 1 << width)
             if km.route_tax(env, km.pack_output({"T_BUY": u, "CEIL": km.LG8_MAX}), 10 ** 6, 0, 10 ** 6, 0).clamp == 0]
    assert len(units) == 1, units
    unit = units[0]
    r = km.route_tax(env, km.pack_output({"T_BUY": unit, "REL": unit, "CEIL": km.LG8_MAX}), 10 ** 6, 10 ** 6, 10 ** 6, 0)
    assert (r.buy_share, r.release) == (10 ** 6, 10 ** 6)          # unit share of inflow and of reserve is all of it
    over = km.route_tax(env, km.pack_output({"T_BUY": unit + 1, "CEIL": km.LG8_MAX}), 10 ** 6, 0, 10 ** 6, 0)
    assert over.clamp & km.K1T
    return unit


def scale_of(code_fn) -> int:
    """The multiplier M of a model code of the form min(cap, a * M // b), where cap is the code of a == b."""
    samples = ((0, 9), (1, 2), (1, 3), (5, 7), (123, 1000), (999, 1000), (1, 1), (10 ** 20, 3 * 10 ** 20))
    candidates = [m for m in range(1, 1 << 12)
                  if all(code_fn(a, b) == min(code_fn(b, b), a * m // b) for a, b in samples)]
    assert len(candidates) == 1, candidates
    return candidates[0]


# ------------------------------------------------------------------------------------------------ INTERFACE.md

def interface_text() -> str:
    with open(os.path.join(ROOT, "chips", "INTERFACE.md"), "r", encoding="utf-8") as f:
        return f.read()


def section(text: str, number: int) -> str:
    m = re.search(rf"^## {number}\. .*?$(.*?)(?=^## \d+\. |\Z)", text, re.S | re.M)
    assert m, f"INTERFACE.md has no section {number}"
    return m.group(1)


def shape_from_interface(text: str) -> dict:
    s = section(text, 2)

    def one(pattern):
        m = re.search(pattern, s)
        assert m, f"INTERFACE.md section 2: /{pattern}/ not found"
        return [int(g) for g in m.groups()]

    n_in, n_out = one(r"`nIn = (\d+)`, `nOut = (\d+)`")
    assert (n_in, n_out) == (km.IN_BITS, km.OUT_BITS), "INTERFACE.md and kernel_model.py disagree on nIn / nOut"
    lo, hi = one(r"`(\d+) <= nState <= (\d+)`")
    (gates,) = one(r"`nNand \+ nLatch <= (\d+)`")
    nand_bytes, latch_bytes, max_bytes = one(r"`(\d+)\*nNand \+ (\d+)\*nLatch <= (\d+)` bytes")
    assert (nand_bytes, latch_bytes) == (7, 4), "TAP-20 record lengths are 7 (NAND) and 4 (LATCH)"
    assert re.search(r"NAND \(`0x00`\) and LATCH \(`0x01`\) only\. No REF\.", s), "flat-netlist sentence not found"
    assert re.search(r"are LATCH records and no LATCH follows them", s), "latches-first sentence not found"
    return {"nStateMin": lo, "nStateMax": hi, "flat": True, "latchesFirst": True,
            "maxGates": gates, "maxNetlistBytes": max_bytes}


def check_tables(text: str) -> None:
    """The bit ranges printed in INTERFACE.md sections 5 and 6 are the model's layouts."""
    for number, layout, nbits in ((5, km.INPUT_FIELDS, km.IN_BITS), (6, km.OUTPUT_FIELDS, km.OUT_BITS)):
        rows = re.findall(r"^\|\s*(\d+)(?:-(\d+))?\s*\|([^|]*)\|", section(text, number), re.M)
        covered, by_name = 0, {n: (o, w) for n, o, w in layout}
        for lo, hi, cell in rows:
            lo, hi = int(lo), int(hi or lo)
            names = re.findall(r"`(\w+)`", cell)
            if names:
                first, last = by_name[names[0]], by_name[names[-1]]
                assert first[0] == lo and last[0] + last[1] - 1 == hi, f"section {number}: {names} != bits {lo}-{hi}"
                assert sum(by_name[n][1] for n in names) == hi - lo + 1
            else:                                              # the unnamed row: the model calls it ZERO
                assert by_name["ZERO"] == (lo, hi - lo + 1), f"section {number}: unnamed bits {lo}-{hi}"
            covered += hi - lo + 1
        assert covered == nbits == sum(w for _, _, w in layout), f"section {number} does not cover {nbits} bits"


# ------------------------------------------------------------------------------------------------ the profile

def build() -> dict:
    check_codes()
    text = interface_text()
    check_tables(text)
    unit = unit_share()
    prog_scale = scale_of(lambda a, b: km.prog_code(a, b, False))
    lock_scale = scale_of(lambda a, b: km.lock_code(a, b))
    prog_grad = km.prog_code(0, 1, True)
    prog_top = km.prog_code(1, 1, False)
    dt_min, dt_max = km.dt_code(1, 0), km.dt_code(1 << 20, 0)
    assert dt_max == (1 << dict((n, w) for n, _, w in km.INPUT_FIELDS)["DT"]) - 1

    amount = {"encoding": "log", "mantissaBits": MANTISSA_BITS, "unit": "base units of the regime asset"}
    share = {"encoding": "uint", "min": 0, "max": unit, "scale": [1, unit]}
    telemetry = {"encoding": "bits", "description": "Telemetry. Defined by each chip; the kernel does not act on it."}
    v1_zero = " Kernel v1 always writes 0."
    v1_ignores = " Kernel v1 ignores it."

    inputs = {
        "TAX": {**amount, "description": "Fresh inflow of the regime asset recognised by this settle."},
        "TAXCUM": {**amount, "description": "Cumulative inflow in the current regime, this settle included. "
                                            "Restarts at graduation."},
        "REV": {**amount, "description": "Revenue since the last step." + v1_zero},
        "REVCUM": {**amount, "description": "Cumulative revenue." + v1_zero},
        "RES": {**amount, "description": "Reserve of the regime asset before this settle's routing."},
        "ESC": {**amount, "description": "Holder escrow." + v1_zero},
        "PROG": {"encoding": "uint", "scale": [1, prog_scale], "values": {str(prog_grad): "graduated"},
                 "unit": "of the sellable supply",
                 "description": f"Curve progress: tokens sold times {prog_scale} divided by the sellable supply, "
                                f"rounded down, at most {prog_top} while on the curve; {prog_grad} once graduated."},
        "LOCK": {"encoding": "uint", "scale": [1, lock_scale], "unit": "of the total supply",
                 "description": f"Tokens locked or burned by the kernel times {lock_scale} divided by the total "
                                "supply, rounded down."},
        "DT": {"encoding": "uint", "min": dt_min, "max": dt_max, "unit": "epochs",
               "values": {str(dt_max): f"{dt_max} or more"},
               "description": "Epochs since the last persisted step."},
        "GRAD": {"encoding": "bool", "description": "True once the token has graduated from the curve."},
        "ZERO": {"encoding": "zero", "description": "Always 0. A chip must ignore these bits."},
    }
    outputs = {
        "T_BUY": {**share, "unit": "of the fresh tax", "description": "Share of fresh tax to buy-and-lock."},
        "T_HOLD": {**share, "unit": "of the fresh tax", "description": "Holder share of fresh tax. Kernel v1 adds it "
                                                                       "to the reserve."},
        "T_ALLOW": {**share, "unit": "of the fresh tax", "description": "Allowance share of fresh tax."},
        "T_RES": {**share, "unit": "of the fresh tax", "description": "Reserve share of fresh tax."},
        "V_BUY": {**share, "unit": "of the fresh revenue", "description": "Share of fresh revenue to buy-and-lock."
                                                                          + v1_ignores},
        "V_HOLD": {**share, "unit": "of the fresh revenue", "description": "Holder share of fresh revenue."
                                                                           + v1_ignores},
        "V_ALLOW": {**share, "unit": "of the fresh revenue", "description": "Allowance share of fresh revenue."
                                                                            + v1_ignores},
        "V_RES": {**share, "unit": "of the fresh revenue", "description": "Reserve share of fresh revenue."
                                                                          + v1_ignores},
        "REL": {**share, "unit": "of the pre-settle reserve",
                "description": "Share of the pre-settle reserve released into buy-and-lock."},
        "CEIL": {**amount, "values": {str(km.LG8_MAX): "none"},
                 "description": "Ceiling on this settle's allowance amount."},
        "MODE": telemetry, "TIER": telemetry, "FLAGS": telemetry, "AUX": telemetry,
    }

    def fields(layout, notes):
        assert [n for n, _, _ in layout] == list(notes), "annotations and model field names differ"
        out = []
        for name, offset, width in layout:
            f = {"name": name, "offset": offset, "width": width}
            f.update({k: notes[name][k] for k in ("encoding", "mantissaBits", "min", "max", "scale", "values",
                                                  "unit", "description") if k in notes[name]})
            out.append(f)
        return out

    return {
        "tapepins": "0.1",
        "name": "covenant-v1",
        "description": (
            "Covenant vault chip, interface v1. Once per epoch a kernel contract assembles the input bits from "
            "chain state, runs one beat, and routes one asset (the regime asset: the chain's native coin while "
            "the token is on its curve, the token itself after graduation) by the output bits, inside fixed "
            f"limits. The four T_ shares must sum to {unit}, and so must the four V_ shares; a group that does "
            "not is treated as: all of it to the reserve. Amounts reach the chip only as log codes. "
            "Each chip defines its own state fields."),
        "nIn": km.IN_BITS,
        "nOut": km.OUT_BITS,
        "shape": shape_from_interface(text),
        "inputs": fields(km.INPUT_FIELDS, inputs),
        "outputs": fields(km.OUTPUT_FIELDS, outputs),
    }


# ------------------------------------------------------------------------------------------------ checks, vectors

def check_golden(doc: dict) -> dict:
    """The generic codec, driven by the generated manifest, reproduces the Covenant golden vectors."""
    with open(os.path.join(ROOT, "chips", "golden", "vectors.json"), "r", encoding="utf-8") as f:
        g = json.load(f)
    n_in = n_out = 0
    for v in g["inputs"]:
        buf = bytearray(len(bytes.fromhex(v["bytes"][2:])))
        for fld in doc["inputs"]:
            P.put_bits(buf, fld["offset"], fld["width"], v["fields"][fld["name"]])
        assert "0x" + bytes(buf).hex() == v["bytes"], "input word differs from the golden vector"
        dec = P.decode_vector(doc["inputs"], bytes(buf))
        assert all(int(dec[k]["raw"]) == x for k, x in v["fields"].items())
        n_in += 1
    for v in g["outputs"]:
        dec = P.decode_vector(doc["outputs"], bytes.fromhex(v["bytes"][2:]))
        assert all(int(dec[k]["raw"]) == x for k, x in v["fields"].items()), "output fields differ from the golden vector"
        n_out += 1
    for v in g["lg8"]:
        assert P.log_code(int(v["x"]), MANTISSA_BITS, km.LG8_MAX.bit_length()) == v["code"]
    for v in g["exp8"]:
        assert P.log_floor(v["code"], MANTISSA_BITS) == int(v["x"])
    for v in g["state"]:
        s = int(v["bits"]).to_bytes((v["nState"] + 7) // 8, "little")
        assert "0x" + P.state_word(s).hex() == v["bytes32"] and P.state_string(P.state_word(s), v["nState"]) == s
    return {"inputs": n_in, "outputs": n_out, "lg8": len(g["lg8"]), "exp8": len(g["exp8"]), "state": len(g["state"])}


def vectors(doc: dict, digest: str) -> dict:
    """A few worked codec cases. Amounts are in the smallest unit of the asset (wei for OKB)."""
    cases_in = [
        {"TAX": 10 ** 16, "TAXCUM": 5 * 10 ** 17, "RES": 6 * 10 ** 16, "PROG": 12, "LOCK": 1, "DT": 1, "GRAD": False},
        {"TAX": 0, "TAXCUM": 5 * 10 ** 17, "RES": 6 * 10 ** 16, "PROG": km.prog_code(0, 1, True), "LOCK": 3,
         "DT": km.dt_code(1 << 20, 0), "GRAD": True},
    ]
    unit = doc["outputs"][0]["max"]
    cases_out = [
        km.pack_output({"T_BUY": unit // 2, "T_HOLD": 0, "T_ALLOW": unit // 8, "T_RES": unit - unit // 2 - unit // 8,
                        "V_RES": unit, "REL": 2, "CEIL": km.lg8(10 ** 15), "MODE": 1}),
        km.pack_output({"T_RES": unit, "V_RES": unit, "REL": 0, "CEIL": km.LG8_MAX}),
        km.fallback_word(km.Envelope(), 32),
    ]
    out = {"format": "tap-pin-manifest-codec-vectors/1", "manifest": "covenant-v1.pins.json", "sha256": digest,
           "note": "Generated by gen_covenant_manifest.py from the Covenant reference model. In `values`, a log "
                   "field takes an amount and the codec writes its code; `decoded` is what decode_vector returns.",
           "log": [{"mantissaBits": MANTISSA_BITS, "width": km.LG8_MAX.bit_length(), "amount": str(x),
                    "code": km.lg8(x), "floor": str(km.exp8(km.lg8(x)))}
                   for x in (0, 1, 2, 3, 10 ** 6, 10 ** 15, 10 ** 16, 10 ** 18, 10 ** 27, 1 << 127, 1 << 128)],
           "inputs": [], "outputs": []}
    for values in cases_in:
        data = P.encode_vector(doc["inputs"], doc["nIn"], values)
        model = km.pack_input({k: (km.lg8(v) if k in ("TAX", "TAXCUM", "RES") else int(v)) for k, v in values.items()})
        assert data == km.word_to_bytes(model, km.IN_BITS)
        out["inputs"].append({"values": {k: (str(v) if isinstance(v, int) and not isinstance(v, bool) else v)
                                         for k, v in values.items()},
                              "bytes": "0x" + data.hex(), "decoded": P.decode_vector(doc["inputs"], data)})
    for word in cases_out:
        data = km.word_to_bytes(word, km.OUT_BITS)
        dec = P.decode_vector(doc["outputs"], data)
        assert {k: int(v["raw"]) for k, v in dec.items()} == km.unpack_output(word)
        out["outputs"].append({"bytes": "0x" + data.hex(), "decoded": dec})
    return out


def dump(doc) -> bytes:
    return (json.dumps(doc, indent=2, ensure_ascii=True) + "\n").encode("ascii")


def main() -> None:
    doc = build()
    data = dump(doc)
    problems = P.validate(P.parse(data))
    assert not problems, problems
    assert "circuit" not in doc and "state" not in doc
    counts = check_golden(doc)
    digest = P.sha256(data)
    with open(os.path.join(HERE, "covenant-v1.pins.json"), "wb") as f:
        f.write(data)
    with open(os.path.join(HERE, "covenant-v1.vectors.json"), "wb") as f:
        f.write(dump(vectors(doc, digest)))
    print("wrote covenant-v1.pins.json", len(data), "bytes, sha256", digest)
    print("wrote covenant-v1.vectors.json")
    print("golden vectors reproduced:", counts)


if __name__ == "__main__":
    main()
