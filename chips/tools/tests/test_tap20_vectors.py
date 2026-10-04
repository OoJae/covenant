"""Conformance of tapc.netlist / tapc.sim with TAP-20's own vectors.json (valid, ill-formed, packing edges)."""
import hashlib

import pytest

from conftest import VENDOR, make_resolver
from tapc import netlist as N
from tapc import sim

# the SHA-256 that TAP-20 states for vectors.json in its Test Cases section
VECTORS_SHA256 = "1a02f5cf991c130a22dc6cc6ee93d0f8fe0720afed081665fa8b8018aefd203b"

# TAP-20 section 3 condition each ill-formed vector violates
ILL_CONDITION = {
    "unknown_opcode": 1, "truncated_record": 1, "nand_forward_reference": 4, "nOut_zero": 2,
    "output_is_an_input": 3, "more_outputs_than_elements": 3, "ref_arity_mismatch": 6,
    "ref_target_not_registered": 6,
}


def test_vendored_vectors_are_the_published_file():
    assert hashlib.sha256((VENDOR / "vectors.json").read_bytes()).hexdigest() == VECTORS_SHA256


def test_format(vectors):
    assert vectors["format"] == "tap-netlist-vectors/1"
    assert len(vectors["valid"]) == 5 and len(vectors["illFormed"]) == 8
    assert {v["name"] for v in vectors["illFormed"]} == set(ILL_CONDITION)


def test_valid_vectors(vectors):
    n_rows = 0
    for v in vectors["valid"]:
        data = N.from_hex(v["netlist"])
        resolve = make_resolver(v["refs"])
        nl = N.check(data, v["nIn"], v["nOut"], resolve)
        assert nl.n_state == v["nState"], v["name"]
        assert N.encode(nl.elements) == data, v["name"]
        if "truthTable" in v:
            assert len(v["truthTable"]) == 1 << v["nIn"]
            for row in v["truthTable"]:
                ns, out = sim.step(data, v["nIn"], v["nOut"], b"", bytes.fromhex(row["inputs"]), resolve)
                assert (ns, out.hex()) == (b"", row["outputs"]), (v["name"], row)
                assert sim.evaluate(data, v["nIn"], v["nOut"], bytes.fromhex(row["inputs"]), resolve).hex() == row["outputs"]
                n_rows += 1
        else:
            prev = None
            for row in v["beats"]:
                if prev is not None:
                    assert row["state"] == prev                      # the vector is a chained sequence
                ns, out = sim.step(data, v["nIn"], v["nOut"], bytes.fromhex(row["state"]),
                                   bytes.fromhex(row["inputs"]), resolve)
                assert (ns.hex(), out.hex()) == (row["newState"], row["outputs"]), (v["name"], row)
                prev = row["newState"]
                n_rows += 1
            with pytest.raises(ValueError, match="has latch"):
                sim.evaluate(data, v["nIn"], v["nOut"], b"", resolve)
    assert n_rows == 4 + 2 + 256 + 8 + 8


def test_valid_vectors_bit_sliced(vectors):
    """The same vectors through the many-vectors-at-once evaluator."""
    for v in vectors["valid"]:
        nl = N.check(N.from_hex(v["netlist"]), v["nIn"], v["nOut"], make_resolver(v["refs"]))
        rows = v.get("truthTable") or v["beats"]
        got = sim.step_many(nl, [bytes.fromhex(r.get("state", "")) for r in rows],
                            [bytes.fromhex(r["inputs"]) for r in rows])
        for r, (ns, out) in zip(rows, got):
            assert out.hex() == r["outputs"], v["name"]
            assert ns.hex() == r.get("newState", ""), v["name"]
        if "beats" in v:
            assert sim.run_beats(nl, [bytes.fromhex(r["inputs"]) for r in rows]) == rows


def test_popcount_is_a_popcount(vectors):
    v = next(x for x in vectors["valid"] if x["name"] == "popcount8_3151")
    nl = N.check(N.from_hex(v["netlist"]), 8, 4)
    planes, n = sim.exhaustive_planes(8)
    _, out = sim.step_planes(nl, [], planes, n)
    assert sim.from_planes(out, n) == [bin(i).count("1") for i in range(256)]


def test_ill_formed_vectors_are_rejected(vectors):
    for v in vectors["illFormed"]:
        with pytest.raises(N.IllFormed) as e:
            N.check(N.from_hex(v["netlist"]), v["nIn"], v["nOut"], make_resolver(v["refs"]))
        assert e.value.condition == ILL_CONDITION[v["name"]], (v["name"], str(e.value))
        with pytest.raises(N.IllFormed):                             # the evaluator refuses them too
            sim.step(N.from_hex(v["netlist"]), v["nIn"], v["nOut"], b"", b"", make_resolver(v["refs"]))


def test_packing_edge_cases(vectors):
    edge = vectors["packingEdgeCases"]
    v = next(x for x in vectors["valid"] if x["name"] == edge["circuit"])
    data = N.from_hex(v["netlist"])
    assert len(edge["cases"]) == 5
    for c in edge["cases"]:
        ns, out = sim.step(data, v["nIn"], v["nOut"], b"", bytes.fromhex(c["inputs"]))
        assert out.hex() == c["outputs"], c["case"]
        (ns2, out2), = sim.step_many(data, [b""], [bytes.fromhex(c["inputs"])], v["nIn"], v["nOut"])
        assert out2.hex() == c["outputs"], c["case"]


def test_lenient_state_and_exact_output_lengths():
    # 9 state bits, 10 outputs: results are exactly 2 bytes each, with the unused high bits zero
    recs = [N.latch(11 + i) for i in range(9)] + [N.nand(2 + i, 2 + i) for i in range(9)] + [N.nand(1, 1)] * 10
    data = N.encode(recs)
    nl = N.check(data, 0, 10)
    assert nl.n_state == 9
    for state in (b"", b"\xff", b"\xff\xff", b"\xff\xff\xff\xff", b"\x55\xfe"):
        ns, out = sim.step(nl, None, None, state, b"")
        assert len(ns) == 2 and len(out) == 2
        assert ns[1] & 0xFE == 0 and out[1] & 0xFC == 0
        want = (~int.from_bytes(state[:2].ljust(2, b"\0"), "little")) & 0x1FF       # each latch takes NOT of itself
        assert int.from_bytes(ns, "little") == want
