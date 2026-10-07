"""Generate the test vectors of the TAP draft "Stateful Circuit Consumers".

Writes, next to this file:
  replay-vectors.json        beats of the example circuit, state strings and word forms, record sequences

Every circuit result comes from TAP-02's reference evaluator (reference.py, MIT, unmodified). It is looked for in
$TAP02_REFERENCE_DIR, then ../tap-02 (the layout of the TAPs repository, assets/tap-02/), then
chips/vendor/tap-20 (the layout of the Covenant repository, a copy of the same file made before TAP-20 was
renumbered TAP-02). The state helpers and the replay check come from replay_reference.py next to this file.

Run:  python3 make_replay_vectors.py        (Python 3.11 or later; from any directory)
Deterministic: rerun to reproduce the file byte for byte.
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
import replay_reference as C       # noqa: E402


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

# The names of the example's bits, as in shift-toggle.pins.json of the Circuit Pin Manifest draft. They are
# used only for the informative `decoded` member of each beat.
FIELDS = {
    "inputs": [("d", 0, 1, "bool"), ("en", 1, 1, "bool")],
    "outputs": [("oldest_n", 0, 1, "bool"), ("phase_next", 1, 1, "bool")],
    "state": [("hist", 0, 8, "bits"), ("phase", 8, 1, "bool")],
}


def decode(vector: str, data: bytes) -> dict:
    """Each field's raw value (a decimal string) and, for a 1-bit bool field, its value."""
    out = {}
    for name, offset, width, encoding in FIELDS[vector]:
        raw = sum(1 << k for k in range(width)
                  if ((offset + k) >> 3) < len(data) and (data[(offset + k) >> 3] >> ((offset + k) & 7)) & 1)
        out[name] = {"raw": str(raw), "value": bool(raw)} if encoding == "bool" else {"raw": str(raw)}
    return out


def beat(state: bytes, inputs: bytes):
    """One beat on packed strings, read as the deployed evaluator reads them (TAP-02 section 5)."""
    ns, out = R.beat(CIRCUIT, R.unpack(state, N_STATE), R.unpack(inputs, N_IN))
    return R.pack(ns), R.pack(out)


INPUT_SEQUENCE = [(1, 1), (0, 0), (1, 1), (1, 0), (0, 1), (0, 0), (1, 0), (1, 1), (0, 0), (1, 1), (0, 0), (1, 0)]


def replay_vectors() -> dict:
    beats, state = [], bytes((N_STATE + 7) // 8)
    for n, (d, en) in enumerate(INPUT_SEQUENCE, 1):
        inputs = R.pack([d, en])
        after, outputs = beat(state, inputs)
        beats.append({"n": n, "source": 1, "stateBefore": hx(state), "inputs": hx(inputs), "outputs": hx(outputs),
                      "stateAfter": hx(after), "stateAfterWord": hx(C.state_word(after)),
                      "decoded": {"inputs": decode("inputs", inputs),
                                  "outputs": decode("outputs", outputs),
                                  "stateAfter": decode("state", after)}})
        state = after

    # the same beat (beat 3, whose state before has bit 8 set) asked for with other byte strings for the
    # same state: TAP-02 section 5
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
            ("the word form: the state string and 30 zero bytes", C.state_word(s3), True),
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
        w = C.state_word(s)
        assert C.state_string(w, n_state) == s and C.is_canonical(s, n_state)
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
        assert not C.is_canonical(b, c["nState"])
        if len(b) == 32:
            try:
                C.state_string(b, c["nState"])
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
        return C.replay(beat, N_IN, N_OUT, N_STATE, bytes(2),
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

    info = C.scan(NETLIST)
    return {
        "format": "tap-replay-vectors/1",
        "note": "Generated by make_replay_vectors.py with the TAP-02 reference evaluator. Hex strings are packed as "
                "in TAP-02 section 5. In `decoded`, fields are named as in shift-toggle.pins.json, the example "
                "manifest of the Circuit Pin Manifest draft.",
        "circuit": {"name": "shift-toggle", "nIn": N_IN, "nOut": N_OUT, "nState": N_STATE,
                    "gateCount": info["nNand"] + info["nLatch"], "latchesFirst": info["latchesFirst"],
                    "netlist": hx(NETLIST), "netlistHash": C.netlist_hash(NETLIST)},
        "initialState": hx(bytes(2)),
        "beats": beats,
        "sameBeatOtherStrings": calls,
        "wordForm": words,
        "notCanonical": not_canonical,
        "records": {"valid": good, "invalid": invalid},
    }


def main() -> None:
    print("TAP-02 reference:", os.path.join(REFERENCE_DIR, "reference.py"), "sha256",
          hashlib.sha256(open(os.path.join(REFERENCE_DIR, "reference.py"), "rb").read()).hexdigest())
    assert C.scan(NETLIST) == {"nNand": 5, "nLatch": 9, "nRef": 0, "bytes": 71, "latchesFirst": True}
    data = dump(replay_vectors())
    with open(os.path.join(HERE, "replay-vectors.json"), "wb") as fh:
        fh.write(data)
    print("wrote replay-vectors.json", len(data), "bytes, sha256 0x" + hashlib.sha256(data).hexdigest())
    print("netlist", hx(NETLIST))
    print("netlistHash", C.netlist_hash(NETLIST))


if __name__ == "__main__":
    main()
