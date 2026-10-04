"""Generate the test vectors of the TAP drafts "Circuit Pin Manifest" and "Stateful Circuit Consumers".

Writes, next to this file:
  shift-toggle.pins.json     a circuit manifest for the example circuit below
  manifest-vectors.json      valid and invalid manifests, binding, profile conformance and codec cases
  replay-vectors.json        beats of the example circuit, state strings and word forms, record sequences

Every circuit result comes from TAP-20's reference evaluator (reference.py, MIT, unmodified). It is looked
for in $TAP20_REFERENCE_DIR, then ../tap-20 (the layout of the TAPs repository), then chips/vendor/tap-20
(the layout of the Covenant repository).

Run:  ~/.local/bin/python3.12 docs/taps/assets/make_vectors.py        (Python 3.11 or later)
Deterministic: rerun to reproduce the three files byte for byte.
"""
from __future__ import annotations

import json
import os
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
for _d in (os.environ.get("TAP20_REFERENCE_DIR"), os.path.join(HERE, "..", "tap-20"),
           os.path.join(HERE, "..", "..", "..", "chips", "vendor", "tap-20")):
    if _d and os.path.isfile(os.path.join(_d, "reference.py")):
        sys.path.insert(0, os.path.abspath(_d))
        break
else:
    sys.exit("TAP-20 reference.py not found; set TAP20_REFERENCE_DIR")
sys.path.insert(0, HERE)

import reference as R              # noqa: E402  (TAP-20 reference implementation)
import pins_reference as P         # noqa: E402


def hx(b: bytes) -> str:
    return "0x" + b.hex()


def unhex(h: str) -> bytes:
    return bytes.fromhex(h[2:])


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
# State bit 8 is still the ninth LATCH in record order (TAP-20 section 4), now record 9 and signal 13.
NOT_LATCHES_FIRST = R.encode([latch(2)] + [latch(4 + k) for k in range(7)] + [
    nand(11, 11), latch(18), nand(13, 3), nand(13, 14), nand(3, 14), nand(11, 11), nand(15, 16)])


def beat(state: bytes, inputs: bytes):
    """One beat on packed strings, read as the deployed evaluator reads them (TAP-20 section 5)."""
    ns, out = R.beat(CIRCUIT, R.unpack(state, N_STATE), R.unpack(inputs, N_IN))
    return R.pack(ns), R.pack(out)


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


# ------------------------------------------------------------------------------------------------ replay vectors

INPUT_SEQUENCE = [(1, 1), (0, 0), (1, 1), (1, 0), (0, 1), (0, 0), (1, 0), (1, 1), (0, 0), (1, 1), (0, 0), (1, 0)]


def replay_vectors(manifest: dict) -> dict:
    beats, state = [], bytes((N_STATE + 7) // 8)
    for n, (d, en) in enumerate(INPUT_SEQUENCE, 1):
        inputs = R.pack([d, en])
        after, outputs = beat(state, inputs)
        beats.append({"n": n, "source": 1, "stateBefore": hx(state), "inputs": hx(inputs), "outputs": hx(outputs),
                      "stateAfter": hx(after), "stateAfterWord": hx(P.state_word(after)),
                      "decoded": {"inputs": P.decode_vector(manifest["inputs"], inputs),
                                  "outputs": P.decode_vector(manifest["outputs"], outputs),
                                  "stateAfter": P.decode_vector(manifest["state"], after)}})
        state = after

    # the same beat (beat 3, whose state before has bit 8 set) asked for with other byte strings for the
    # same state: TAP-20 section 5
    b3 = beats[2]
    s3, i3 = unhex(b3["stateBefore"]), unhex(b3["inputs"])
    assert s3[1] == 1
    want = (b3["stateAfter"], b3["outputs"])
    garbage = bytearray(b"\xff" * 32)
    for i in range(N_STATE):
        if not (s3[i >> 3] >> (i & 7)) & 1:
            garbage[i >> 3] &= ~(1 << (i & 7)) & 0xFF
    calls = []
    for note, st, canonical in (
            ("the state string", s3, True),
            ("the word form: the state string and 30 zero bytes", P.state_word(s3), True),
            ("the state string followed by 6 bytes of other data: bytes beyond the state are ignored", s3 + b"\xaa" * 6, False),
            ("a word with every bit from bit 9 upward set: bits beyond nState are ignored", bytes(garbage), False)):
        got = beat(st, i3)
        assert (hx(got[0]), hx(got[1])) == want
        calls.append({"note": note, "state": hx(st), "inputs": b3["inputs"], "newState": want[0], "outputs": want[1],
                      "isStateStringOrWord": canonical})
    short = beat(s3[:1], i3)                           # the missing second byte reads as zero: another state
    assert (hx(short[0]), hx(short[1])) != want
    calls.append({"note": "the first byte of the state string only: bit 8 (phase) reads as 0, so this is a beat "
                          "from another state and its result differs", "state": hx(s3[:1]),
                  "inputs": b3["inputs"], "newState": hx(short[0]), "outputs": hx(short[1]),
                  "isStateStringOrWord": False})

    words = []
    for n_state, bits in ((1, [1]), (8, [1, 0, 1, 1, 0, 0, 0, 1]), (9, [0] * 8 + [1]),
                          (64, [(i * 7 + 3) % 5 % 2 for i in range(64)]), (255, [1] * 255), (256, [i % 3 == 0 for i in range(256)])):
        s = R.pack([int(b) for b in bits])
        w = P.state_word(s)
        assert P.state_string(w, n_state) == s and P.is_canonical(s, n_state)
        words.append({"nState": n_state, "stateString": hx(s), "word": hx(w),
                      "setBits": [i for i, b in enumerate(bits) if b][:12]})
    not_canonical = [
        {"note": "bit 9 is set in a 9-bit state", "nState": 9, "bytes": "0x0002"},
        {"note": "one byte where a 9-bit state needs two", "nState": 9, "bytes": "0x01"},
        {"note": "three bytes where a 9-bit state needs two", "nState": 9, "bytes": "0x010000"},
        {"note": "a word whose bytes after the state string are not zero", "nState": 9,
         "bytes": "0x0101" + "00" * 29 + "01"},
    ]
    for c in not_canonical:
        b = unhex(c["bytes"])
        assert not P.is_canonical(b, c["nState"])
        if len(b) == 32:
            try:
                P.state_string(b, c["nState"])
                raise AssertionError("accepted a non-canonical word")
            except ValueError:
                pass

    # record sequences (section 5): source 1 = step on the bound processor, 2 = another evaluator of the same
    # netlist, 0 = a record without a beat
    def rec(source, b):
        return {"source": source, "inputs": b["inputs"], "outputs": b["outputs"], "stateAfter": b["stateAfter"]}

    idle = {"source": 0, "inputs": "0x03", "outputs": "0x00", "stateAfter": beats[2]["stateAfter"]}
    good = [rec(1, beats[0]), rec(1, beats[1]), rec(1, beats[2]), idle]
    state = unhex(idle["stateAfter"])
    for d, en in INPUT_SEQUENCE[3:6]:                  # the sequence goes on from the unchanged state
        inputs = R.pack([d, en])
        after, outputs = beat(state, inputs)
        good.append({"source": 2, "inputs": hx(inputs), "outputs": hx(outputs), "stateAfter": hx(after)})
        state = after

    def check(records):
        return P.replay(beat, N_IN, N_OUT, N_STATE, bytes(2),
                        [(r["source"], *(unhex(r[k]) for k in ("inputs", "outputs", "stateAfter"))) for r in records])

    assert check(good) is None

    def altered(index, **changes):
        out = [dict(r) for r in good]
        out[index].update(changes)
        return out

    def xor(h, index, mask):
        b = bytearray(unhex(h))
        b[index] ^= mask
        return hx(bytes(b))

    bad = [
        ("stateAfter of record 3 has one bit flipped", altered(2, stateAfter=xor(good[2]["stateAfter"], 0, 0x04))),
        ("outputs of record 2 are not the circuit's", altered(1, outputs=xor(good[1]["outputs"], 0, 0x01))),
        ("record 4 has no beat but changes the state", altered(3, stateAfter=beats[3]["stateAfter"])),
        ("stateAfter of record 1 has a bit set beyond nState", altered(0, stateAfter=xor(good[0]["stateAfter"], 1, 0x80))),
        ("stateAfter of record 1 is one byte short", altered(0, stateAfter=good[0]["stateAfter"][:4])),
        ("inputs of record 5 have a bit set beyond nIn", altered(4, inputs=xor(good[4]["inputs"], 0, 0x04))),
        ("record 2 is missing, so the next record does not follow from record 1", good[:1] + good[2:]),
    ]
    invalid = []
    for note, records in bad:
        res = check(records)
        assert res is not None, note
        invalid.append({"note": note, "records": records, "failsAtRecord": res[0], "reason": res[1]})

    info = P.scan(NETLIST)
    return {
        "format": "tap-replay-vectors/1",
        "note": "Generated by make_vectors.py with the TAP-20 reference evaluator. Hex strings are packed as in "
                "TAP-20 section 5. In `decoded`, fields are read with shift-toggle.pins.json.",
        "circuit": {"name": "shift-toggle", "nIn": N_IN, "nOut": N_OUT, "nState": N_STATE,
                    "gateCount": info["nNand"] + info["nLatch"], "latchesFirst": info["latchesFirst"],
                    "netlist": hx(NETLIST), "netlistHash": P.netlist_hash(NETLIST)},
        "initialState": hx(bytes(2)),
        "beats": beats,
        "sameBeatOtherStrings": calls,
        "wordForm": words,
        "notCanonical": not_canonical,
        "records": {"valid": good, "invalid": invalid},
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
        "note": "Generated by make_vectors.py with pins_reference.py. A manifest given inline is written to a file "
                "as any JSON text of that value.",
        "files": files,
        "notManifestFiles": invalid_files,
        "invalidManifests": invalid,
        "validManifests": valid,
        "binding": binding,
        "conformance": {"profile": prof, "profileSha256": P.sha256(prof_bytes),
                        "profileFile": "the profile serialised with two-space indentation and a final newline, "
                                       "as make_vectors.py writes JSON", "cases": conformance},
        "codec": {"n": 48, "fields": layout, "encode": codec, "decode": raw_cases, "refused": refused},
        "log": logs,
    }


def main() -> None:
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
           "replay-vectors.json": dump(replay_vectors(manifest)),
           "manifest-vectors.json": dump(manifest_vectors(manifest, manifest_bytes))}
    for name, data in out.items():
        with open(os.path.join(HERE, name), "wb") as fh:
            fh.write(data)
        print("wrote", name, len(data), "bytes, sha256", P.sha256(data))
    print("netlist", hx(NETLIST))
    print("netlistHash", P.netlist_hash(NETLIST))


if __name__ == "__main__":
    main()
