"""Generate vectors.json from reference.py. Deterministic; rerun to reproduce byte-for-byte."""
import hashlib
import json
from pathlib import Path

import reference as R

HERE = Path(__file__).parent
CPU_A = bytes.fromhex("00000000000000000000000000000000000000aa")   # placeholder processor address used only in vectors


def nand(a, b): return R.Element(R.NAND, [a, b])
def latch(d): return R.Element(R.LATCH, [d])
def ref(cpu, cid, ins, n_out): return R.Element(R.REF, ins, cpu, cid, n_out)


def truth_table(c):
    rows = []
    for v in range(1 << c.n_in):
        bits = [(v >> i) & 1 for i in range(c.n_in)]
        _, out = R.beat(c, [], bits)
        rows.append({"inputs": R.pack(bits).hex(), "outputs": R.pack(out).hex()})
    return rows


def sequence(c, inputs_seq):
    st, rows = [0] * c.n_state, []
    for bits in inputs_seq:
        ns, out = R.beat(c, st, bits)
        rows.append({"state": R.pack(st).hex(), "inputs": R.pack(bits).hex(),
                     "newState": R.pack(ns).hex(), "outputs": R.pack(out).hex()})
        st = ns
    return rows


# toggle flip-flop: signal 2 = en, 3 = q (LATCH, d = 7), 7 = q XOR en
TOGGLE = [latch(7), nand(3, 2), nand(3, 4), nand(2, 4), nand(5, 6)]
toggle_bytes = R.encode(TOGGLE)
subs = {(CPU_A, 1): R.load(toggle_bytes, 1, 1)}
resolve = lambda cpu, cid: subs.get((cpu, cid))  # noqa: E731

pop_bytes = bytes.fromhex((HERE / "popcount8_3151.hex").read_text().strip().removeprefix("0x"))

valid = []


def add(name, note, els_or_bytes, n_in, n_out, source, seq=None, refs=None):
    data = els_or_bytes if isinstance(els_or_bytes, bytes) else R.encode(els_or_bytes)
    c = R.load(data, n_in, n_out, resolve)
    assert R.encode(R.decode(data, n_in)) == data
    v = {"name": name, "note": note, "source": source, "nIn": n_in, "nOut": n_out,
         "nState": c.n_state, "netlist": "0x" + data.hex(), "refs": refs or []}
    if seq is None:
        v["truthTable"] = truth_table(c)
    else:
        v["beats"] = sequence(c, seq)
    valid.append(v)
    return c


add("nand", "one NAND gate", [nand(2, 3)], 2, 1, "constructed")
add("constants", "outputs NOT x and constant 1 (NAND with signal 0)", [nand(2, 1), nand(0, 2)], 1, 2, "constructed")
pc = add("popcount8_3151", "on-chain bytes of circuit #3151 on processor 0xb1024b89886B9a34Aa4ff5F31C411D708b20a14C; "
         "outputs are the popcount of the 8 inputs, LSB first", pop_bytes, 8, 4, "on-chain")
for v in range(256):
    out = R.beat(pc, [], [(v >> i) & 1 for i in range(8)])[1]
    assert sum(o << i for i, o in enumerate(out)) == v.bit_count()
en = [[1], [1], [0], [1], [0], [0], [1], [1]]
add("toggle", "LATCH whose d refers forward: q' = q XOR en; output is q XOR en", TOGGLE, 1, 1, "constructed", en)
add("ref_with_state",
    "LATCH (state bit 0, d = signal 4) then REF to the toggle circuit (state bit 1) then NAND(3, 4); "
    "pins state order and REF semantics",
    [latch(4), ref(CPU_A, 1, [2], 1), nand(3, 4)], 1, 1, "constructed", en,
    refs=[{"cpu": "0x" + CPU_A.hex(), "id": 1, "nIn": 1, "nOut": 1, "netlist": "0x" + toggle_bytes.hex()}])

ill = [
    ("unknown_opcode", "03000002000003", 2, 1),
    ("truncated_record", "0000000200", 2, 1),
    ("nand_forward_reference", "00000002000005" + "00000002000003", 2, 1),
    ("nOut_zero", "00000002000003", 2, 0),
    ("output_is_an_input", "", 1, 1),
    ("more_outputs_than_elements", "00000002000003", 2, 2),
    ("ref_arity_mismatch", "02" + CPU_A.hex() + (1).to_bytes(8, "big").hex() + "0201" + "000002000003", 2, 1),
    ("ref_target_not_registered", "02" + CPU_A.hex() + (9).to_bytes(8, "big").hex() + "0101" + "000002", 1, 1),
]
illformed = []
for name, hx, n_in, n_out in ill:
    try:
        R.load(bytes.fromhex(hx), n_in, n_out, resolve)
        raise SystemExit(f"{name} was accepted")
    except R.IllFormed as e:
        illformed.append({"name": name, "nIn": n_in, "nOut": n_out, "netlist": "0x" + hx, "reason": str(e),
                          "refs": [{"cpu": "0x" + CPU_A.hex(), "id": 1, "nIn": 1, "nOut": 1,
                                    "netlist": "0x" + toggle_bytes.hex()}]})

# packing edge cases, as the deployed evaluator treats them (NetlistVM._getBit): extra bits and bytes ignored,
# missing bytes read as 0; outputs are always ceil(nOut/8) bytes with unused bits 0
nand_c = R.load(R.encode([nand(2, 3)]), 2, 1)
edges = []
for label, raw in [("standard", "03"), ("padding bits set", "ff"), ("one extra byte", "03aa"),
                   ("empty (all inputs read as 0)", ""), ("short: only padding differs", "fc")]:
    _, out = R.beat(nand_c, [], R.unpack(bytes.fromhex(raw), 2))
    edges.append({"case": label, "inputs": raw, "outputs": R.pack(out).hex()})

doc = {"format": "tap-netlist-vectors/1",
       "packing": "bit i of a vector is bit (i mod 8) of byte floor(i / 8); LSB first",
       "chainVerified": False,
       "valid": valid, "illFormed": illformed,
       "packingEdgeCases": {"circuit": "nand", "cases": edges}}
text = json.dumps(doc, indent=1, sort_keys=True) + "\n"
(HERE / "vectors.json").write_text(text)
print(len(valid), "valid,", len(illformed), "ill-formed; sha256", hashlib.sha256(text.encode()).hexdigest())
