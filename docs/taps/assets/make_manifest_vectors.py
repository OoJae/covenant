"""Generate the test vectors of the TAP draft "Circuit Pin Manifest".

Writes, next to this file:
  shift-toggle.pins.json     a circuit manifest for the example circuit below
  manifest-vectors.json      valid and invalid manifests, binding, profile conformance and codec cases

Every circuit result comes from TAP-02's reference evaluator (reference.py, MIT, unmodified). It is looked for in
$TAP02_REFERENCE_DIR, then ../tap-02 (the layout of the TAPs repository, assets/tap-02/), then
chips/vendor/tap-20 (the layout of the Covenant repository, a copy of the same file made before TAP-20 was
renumbered TAP-02). Everything else comes from pins_reference.py next to this file.

Run:  python3 make_manifest_vectors.py        (Python 3.11 or later; from any directory)
Deterministic: rerun to reproduce the two files byte for byte.
"""
from __future__ import annotations

import hashlib
import json
import os
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))


def find_reference() -> str:
    """The directory holding TAP-02's reference.py, in the order the docstring gives."""
    env = os.environ.get("TAP02_REFERENCE_DIR")
    if env:
        if not os.path.isfile(os.path.join(env, "reference.py")):
            sys.exit(f"TAP02_REFERENCE_DIR={env} holds no reference.py")
        return os.path.abspath(env)
    for d in (os.path.join(HERE, "..", "tap-02"), os.path.join(HERE, "..", "..", "..", "chips", "vendor", "tap-20")):
        if os.path.isfile(os.path.join(d, "reference.py")):
            return os.path.abspath(d)
    sys.exit("TAP-02 reference.py not found in ../tap-02 or chips/vendor/tap-20; set TAP02_REFERENCE_DIR")


REFERENCE_DIR = find_reference()
sys.path.insert(0, REFERENCE_DIR)
sys.path.insert(0, HERE)

import reference as R              # noqa: E402  (TAP-02 reference implementation)
import pins_reference as P         # noqa: E402


def hx(b: bytes) -> str:
    return "0x" + b.hex()


def dump(doc) -> bytes:
    return (json.dumps(doc, indent=2, ensure_ascii=True) + "\n").encode("ascii")


# ------------------------------------------------------------------------------------------------ example circuit
# shift-toggle: nIn = 2, nOut = 2, nState = 9, latches-first, 9 LATCH + 5 NAND = 71 bytes.
#
#   signal  0, 1     constants 0 and 1
#   signal  2        input 0  d
#   signal  3        input 1  en
#   signal  4..11    LATCH records 0..7 = state bits 0..7 = hist[0..7]; hist[0] takes d, hist[k] takes hist[k-1]
#   signal  12       LATCH record 8     = state bit 8      = phase; takes signal 17 (a forward reference)
#   signal  13       NAND(phase, en)
#   signal  14       NAND(phase, 13)
#   signal  15       NAND(en, 13)
#   signal  16       NAND(hist[7], hist[7])   output 0  oldest_n   = NOT hist[7]
#   signal  17       NAND(14, 15)             output 1  phase_next = phase XOR en

def nand(a, b):
    return R.Element(R.NAND, [a, b])


def latch(d):
    return R.Element(R.LATCH, [d])


N_IN, N_OUT = 2, 2
ELEMENTS = [latch(2)] + [latch(4 + k) for k in range(7)] + [latch(17),
            nand(12, 3), nand(12, 13), nand(3, 13), nand(11, 11), nand(14, 15)]
NETLIST = R.encode(ELEMENTS)
CIRCUIT = R.load(NETLIST, N_IN, N_OUT)
N_STATE = CIRCUIT.n_state

# The same function with one NAND placed before the last LATCH record: well-formed, not latches-first.
# State bit 8 is still the ninth LATCH in record order (TAP-02 section 4), now record 9 and signal 13.
NOT_LATCHES_FIRST = R.encode([latch(2)] + [latch(4 + k) for k in range(7)] + [
    nand(11, 11), latch(18), nand(13, 3), nand(13, 14), nand(3, 14), nand(11, 11), nand(15, 16)])


def example_manifest() -> dict:
    return {
        "tapepins": "0.1",
        "name": "shift-toggle",
        "description": "Example circuit of the TAP drafts: an 8-bit shift register and a toggle.",
        "circuit": {"netlistHash": P.netlist_hash(NETLIST)},
        "nIn": N_IN,
        "nOut": N_OUT,
        "nState": N_STATE,
        "inputs": [
            {"name": "d", "offset": 0, "width": 1, "encoding": "bool",
             "description": "Bit shifted into the history by this beat."},
            {"name": "en", "offset": 1, "width": 1, "encoding": "bool",
             "description": "When true, this beat flips the phase."},
        ],
        "outputs": [
            {"name": "oldest_n", "offset": 0, "width": 1, "encoding": "bool",
             "description": "Inverse of the oldest history bit before this beat."},
            {"name": "phase_next", "offset": 1, "width": 1, "encoding": "bool",
             "description": "The phase after this beat."},
        ],
        "state": [
            {"name": "hist", "offset": 0, "width": 8, "encoding": "bits",
             "description": "The last eight values of d. Bit 0 is the newest."},
            {"name": "phase", "offset": 8, "width": 1, "encoding": "bool",
             "description": "Flips on every beat that has en set."},
        ],
    }


# ------------------------------------------------------------------------------------------------ manifest vectors

def manifest_vectors(manifest: dict, manifest_bytes: bytes) -> dict:
    files = [{"file": "shift-toggle.pins.json", "kind": "circuit manifest", "sha256": P.sha256(manifest_bytes)}]
    covenant = os.path.join(HERE, "covenant-v1.pins.json")
    profile = profile_bytes = None
    if os.path.isfile(covenant):
        profile_bytes = open(covenant, "rb").read()
        profile = P.parse(profile_bytes)
        assert not P.validate(profile)
        files.append({"file": "covenant-v1.pins.json", "kind": "profile", "sha256": P.sha256(profile_bytes)})

    # ---- files that are not manifests at all (section 3.1)
    base = '{"tapepins":"0.1","nIn":1,"nOut":1,"inputs":[],"outputs":[]}'
    not_files = [
        ("starts with a byte order mark", b"\xef\xbb\xbf" + base.encode()),
        ("not valid UTF-8", base.encode()[:-1] + b"\xff}"),
        ("the top-level value is an array", b"[" + base.encode() + b"]"),
        ("a member name is repeated", base[:-1].encode() + b',"nIn":2}'),
        ("a member name is repeated, written once with an escape", base[:-1].encode() + b',"n\\u0049n":2}'),
        ("a member is named constructor", base[:-1].encode() + b',"constructor":{}}'),
        ("a number is written with a fraction", base.replace('"nIn":1', '"nIn":1.0').encode()),
        ("a number is written with an exponent", base.replace('"nOut":1', '"nOut":1e0').encode()),
        ("an integer is beyond 2^53 - 1", base[:-1].encode() + b',"x":9007199254740992}'),
        ("a string has an unpaired surrogate", base[:-1].encode() + b',"name":"\\ud800"}'),
        ("larger than 65,536 bytes", (base[:-1] + ',"description":"' + "a" * 65_536 + '"}').encode()),
    ]
    invalid_files = []
    for note, data in not_files:
        try:
            P.parse(data)
            raise AssertionError(note)
        except P.Invalid:
            pass
        invalid_files.append({"note": note, "bytes": hx(data)} if len(data) < 400 else
                             {"note": note, "sha256": P.sha256(data), "length": len(data),
                              "howToBuild": "the base file with a description member of 65,536 letters a"})
    assert P.parse(base.encode()) and not P.validate(P.parse(base.encode()))

    # ---- files that parse but break a rule of sections 3 to 5
    def variant(**changes):
        m = json.loads(json.dumps(manifest))
        for k, v in changes.items():
            if v is None:
                m.pop(k, None)
            else:
                m[k] = v
        return m

    def with_field(vec, index, **changes):
        m = json.loads(json.dumps(manifest))
        for k, v in changes.items():
            if v is None:
                m[vec][index].pop(k, None)
            else:
                m[vec][index][k] = v
        return m

    f = lambda **kw: {"name": "x", "offset": 0, "width": 4, **kw}       # noqa: E731
    one = lambda field: variant(circuit=None, nState=None, state=None, nIn=8, inputs=[field])   # noqa: E731
    broken = [
        ("the version is not of the form 0.N", variant(tapepins="1.0")),
        ("nOut is 0", variant(nOut=0)),
        ("a circuit manifest without nState", variant(nState=None)),
        ("a circuit manifest without state", variant(state=None)),
        ("a circuit manifest with a shape", variant(shape={"flat": True})),
        ("netlistHash has upper-case hex digits", variant(circuit={"netlistHash": manifest["circuit"]["netlistHash"].upper().replace("0X", "0x")})),
        ("a profile that defines state fields without fixing nState", variant(circuit=None, nState=None)),
        ("a field reaches beyond its vector (state bits 8..8 of 9, widened to 2)", with_field("state", 1, width=2, encoding="bits")),
        ("two fields overlap", with_field("state", 1, offset=7)),
        ("fields are not in offset order", variant(inputs=list(reversed(manifest["inputs"])))),
        ("two fields of one vector share a name", with_field("inputs", 1, name="d")),
        ("a field name starts with a digit", with_field("inputs", 0, name="0d")),
        ("a field of width 0", with_field("inputs", 0, width=0)),
        ("a bool field wider than 1 bit", one(f(encoding="bool"))),
        ("an enum field without values", one(f(encoding="enum"))),
        ("an enum value the field cannot hold", one(f(encoding="enum", values={"16": "sixteen"}))),
        ("a values key with a leading zero", one(f(encoding="enum", values={"01": "one"}))),
        ("a flags field whose bits has the wrong length", one(f(encoding="flags", bits=["a", "b", None]))),
        ("a log field without mantissaBits", one(f(encoding="log"))),
        ("max is above what the field can hold", one(f(encoding="uint", max=16))),
        ("min is above max", one(f(encoding="int", min=3, max=-3))),
        ("a scale with a zero denominator", one(f(encoding="uint", scale=[1, 0]))),
        ("mantissaBits on a uint field", one(f(encoding="uint", mantissaBits=3))),
        ("a profile with nState and a state range", variant(circuit=None, shape={"nStateMin": 1, "nStateMax": 9})),
    ]
    invalid = []
    for note, m in broken:
        problems = P.validate(P.parse(dump(m)))
        assert problems, note
        invalid.append({"note": note, "manifest": m})
    still_valid = [
        ("a member this TAP does not define is ignored", variant(x_tool={"name": "example"})),
        ("an encoding this TAP does not define is read as bits", one(f(encoding="gray", mantissaBits=3))),
        ("fields need not cover every bit", variant(state=manifest["state"][1:])),
        ("a profile: no circuit, state fields with nState fixed", variant(circuit=None)),
    ]
    valid = []
    for note, m in still_valid:
        assert not P.validate(P.parse(dump(m))), note
        valid.append({"note": note, "manifest": m})

    # ---- binding (section 4)
    other = R.encode(ELEMENTS[:-1] + [nand(15, 14)])                    # the same function, other bytes
    ref_circuit = R.encode([R.Element(R.REF, [2], bytes.fromhex("00" * 19 + "aa"), 1, 1), nand(3, 3)])
    ref_manifest = {"tapepins": "0.1", "circuit": {"netlistHash": P.netlist_hash(ref_circuit)}, "nIn": 1, "nOut": 1,
                    "nState": 1, "inputs": [], "outputs": [], "state": []}
    binding = []
    for note, m, nl, counts, chain, expect in (
            ("the example circuit", manifest, NETLIST, (N_IN, N_OUT, N_STATE), 196, "ok"),
            ("the same netlist taped out on another chain: a flat netlist binds anywhere", manifest, NETLIST, (N_IN, N_OUT, N_STATE), 56, "ok"),
            ("another netlist with the same function", manifest, other, (N_IN, N_OUT, N_STATE), 196, "manifest-mismatch"),
            ("the same netlist bytes taped out with nIn = 3", manifest, NETLIST, (3, N_OUT, N_STATE), 196, "manifest-mismatch"),
            ("a netlist with a REF record and a manifest without chainId", ref_manifest, ref_circuit, (1, 1, 1), 196, "manifest-mismatch"),
            ("the same, with chainId 196, read on chain 196", {**ref_manifest, "circuit": {**ref_manifest["circuit"], "chainId": 196}}, ref_circuit, (1, 1, 1), 196, "ok"),
            ("the same, with chainId 196, read on chain 8453", {**ref_manifest, "circuit": {**ref_manifest["circuit"], "chainId": 196}}, ref_circuit, (1, 1, 1), 8453, "manifest-mismatch")):
        assert not P.validate(m), note
        got = "manifest-mismatch" if P.check_binding(m, nl, *counts, chain) else "ok"
        assert got == expect, note
        binding.append({"note": note, "manifest": "shift-toggle.pins.json" if m is manifest else m,
                        "netlist": hx(nl), "nIn": counts[0], "nOut": counts[1], "nState": counts[2],
                        "chainId": chain, "expect": expect})

    # ---- profile conformance (section 6), with a small profile made for the purpose
    prof = {"tapepins": "0.1", "name": "shift-toggle-io",
            "description": "Example profile: the pins of shift-toggle, with any state of 1 to 16 bits.",
            "nIn": 2, "nOut": 2, "shape": {"nStateMin": 1, "nStateMax": 16, "flat": True, "latchesFirst": True, "maxGates": 64},
            "inputs": manifest["inputs"],
            "outputs": [manifest["outputs"][0], {**manifest["outputs"][1], "encoding": "bits"}]}
    prof_bytes = dump(prof)
    assert not P.validate(P.parse(prof_bytes))
    claim = variant(profile={"name": prof["name"], "sha256": P.sha256(prof_bytes)})
    conformance = []
    for note, m, nl, expect in (
            ("the example manifest claims the profile; the profile leaves output 1 as bits and the manifest reads it as bool", claim, NETLIST, "ok"),
            ("the profile digest in the claim is wrong", variant(profile={"name": prof["name"], "sha256": "0x" + "11" * 32}), NETLIST, "no"),
            ("an input field is at another offset", {**claim, "inputs": [{**claim["inputs"][0], "name": "en"}, {**claim["inputs"][1], "name": "d"}]}, NETLIST, "no"),
            ("an input field has another encoding", {**claim, "inputs": [{**claim["inputs"][0], "encoding": "uint"}, claim["inputs"][1]]}, NETLIST, "no"),
            ("nState is outside the profile's range", {**claim, "nState": 17, "state": []}, NETLIST, "no"),
            ("a netlist with the same pins, state and function that is not latches-first",
             {**claim, "circuit": {"netlistHash": P.netlist_hash(NOT_LATCHES_FIRST)}}, NOT_LATCHES_FIRST, "no")):
        assert not P.validate(m), note
        if m["nState"] == N_STATE:
            assert not P.check_binding(m, nl, N_IN, N_OUT, N_STATE), note
        problems = P.conforms(m, prof, prof_bytes) + P.check_shape(prof, nl)
        assert ("ok" if not problems else "no") == expect, (note, problems)
        conformance.append({"note": note, "manifest": m, "netlist": hx(nl), "expect": expect})
    if profile is not None:                            # nothing claims the Covenant profile here; it must be a profile
        assert "circuit" not in profile and P.conforms(manifest, profile) != []

    # ---- codec (section 5): one made-up 48-bit vector with every encoding
    layout = [
        {"name": "count", "offset": 0, "width": 6, "encoding": "uint", "min": 0, "max": 40, "unit": "items"},
        {"name": "delta", "offset": 6, "width": 5, "encoding": "int", "min": -10, "max": 10},
        {"name": "ready", "offset": 11, "width": 1, "encoding": "bool"},
        {"name": "mode", "offset": 12, "width": 2, "encoding": "enum", "values": {"0": "idle", "1": "run", "3": "halt"}},
        {"name": "alarms", "offset": 14, "width": 4, "encoding": "flags", "bits": ["low", "high", None, "stale"]},
        {"name": "amount", "offset": 18, "width": 10, "encoding": "log", "mantissaBits": 3, "values": {"1023": "none"}},
        {"name": "share", "offset": 28, "width": 9, "encoding": "uint", "max": 256, "scale": [1, 256]},
        {"name": "pad", "offset": 37, "width": 3, "encoding": "zero"},
        {"name": "tag", "offset": 41, "width": 7, "encoding": "bits"},
    ]
    assert not P.validate({"tapepins": "0.1", "nIn": 48, "nOut": 1, "inputs": layout, "outputs": []})
    codec = []
    for note, values in (
            ("every field", {"count": 40, "delta": -3, "ready": True, "mode": "halt", "alarms": ["low", "stale"],
                             "amount": 10 ** 18, "share": 64, "tag": 0x55}),
            ("fields that are not given are zero", {"delta": 10, "mode": "run"}),
            ("the smallest and largest amounts", {"amount": 1, "share": 256, "delta": -10}),
            ("an amount beyond the code saturates at the largest code, which this field labels", {"amount": 1 << 200})):
        data = P.encode_vector(layout, 48, values)
        shown = {k: (str(v) if isinstance(v, int) and not isinstance(v, bool) else v) for k, v in values.items()}
        codec.append({"note": note, "values": shown, "bytes": hx(data), "decoded": P.decode_vector(layout, data)})
    raw_cases = []
    for note, data in (("bit 40, which no field covers, is set: no field changes", bytes([0, 0, 0, 0, 0, 1])),
                       ("mode holds 2, which the enum does not define; pad is not zero; count is above its max",
                        bytes([0x3F, 0x20, 0, 0, 0x20, 0])),
                       ("a string shorter than the vector: missing bytes read as zero", bytes([0x25]))):
        raw_cases.append({"note": note, "bytes": hx(data), "decoded": P.decode_vector(layout, data)})
    refused = []
    for note, values in (("count above its max", {"count": 41}), ("delta below its min", {"delta": -11}),
                         ("a label the enum does not have", {"mode": "sleep"}),
                         ("a flag the field does not have", {"alarms": ["mid"]}),
                         ("a non-zero value for a zero field", {"pad": 1}),
                         ("a value wider than the field", {"tag": 128}),
                         ("a negative amount", {"amount": -1}), ("a field that does not exist", {"nothing": 1})):
        try:
            P.encode_vector(layout, 48, values)
            raise AssertionError(note)
        except ValueError:
            refused.append({"note": note, "values": values})
    logs = [{"mantissaBits": k, "width": w, "amount": str(x), "code": P.log_code(x, k, w),
             "floor": str(P.log_floor(P.log_code(x, k, w), k))}
            for k, w in ((0, 8), (3, 10), (4, 12)) for x in (0, 1, 2, 3, 7, 8, 9, 1000, 10 ** 18, (1 << 255) + 12345)]

    return {
        "format": "tap-pin-manifest-vectors/1",
        "note": "Generated by make_manifest_vectors.py with pins_reference.py. A manifest given inline is written "
                "to a file as any JSON text of that value.",
        "files": files,
        "notManifestFiles": invalid_files,
        "invalidManifests": invalid,
        "validManifests": valid,
        "binding": binding,
        "conformance": {"profile": prof, "profileSha256": P.sha256(prof_bytes),
                        "profileFile": "the profile serialised with two-space indentation and a final newline, "
                                       "as make_manifest_vectors.py writes JSON", "cases": conformance},
        "codec": {"n": 48, "fields": layout, "encode": codec, "decode": raw_cases, "refused": refused},
        "log": logs,
    }


def main() -> None:
    print("TAP-02 reference:", os.path.join(REFERENCE_DIR, "reference.py"), "sha256",
          hashlib.sha256(open(os.path.join(REFERENCE_DIR, "reference.py"), "rb").read()).hexdigest())
    manifest = example_manifest()
    manifest_bytes = dump(manifest)
    assert not P.validate(P.parse(manifest_bytes))
    assert not P.check_binding(manifest, NETLIST, N_IN, N_OUT, N_STATE)
    assert P.scan(NETLIST) == {"nNand": 5, "nLatch": 9, "nRef": 0, "bytes": 71, "latchesFirst": True}
    other = R.load(NOT_LATCHES_FIRST, N_IN, N_OUT)     # well-formed, same state layout, same function
    assert other.n_state == N_STATE and not P.scan(NOT_LATCHES_FIRST)["latchesFirst"]
    for s in range(1 << N_STATE):
        for x in range(1 << N_IN):
            sb, xb = [(s >> i) & 1 for i in range(N_STATE)], [(x >> i) & 1 for i in range(N_IN)]
            assert R.beat(other, sb, xb) == R.beat(CIRCUIT, sb, xb)
    out = {"shift-toggle.pins.json": manifest_bytes,
           "manifest-vectors.json": dump(manifest_vectors(manifest, manifest_bytes))}
    for name, data in out.items():
        with open(os.path.join(HERE, name), "wb") as fh:
            fh.write(data)
        print("wrote", name, len(data), "bytes, sha256", P.sha256(data))
    print("netlist", hx(NETLIST))
    print("netlistHash", P.netlist_hash(NETLIST))


if __name__ == "__main__":
    main()
