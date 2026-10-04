"""The probe circuit (chips/probe): the committed artefacts are consistent, correct and reproducible."""
import json
import subprocess
import sys

import pytest

from conftest import PROBE
from tapc import netlist as N
from tapc import pack, prove, sim, synth

sys.path.insert(0, str(PROBE))
import model as M  # noqa: E402  (chips/probe/model.py, the behavioural model)


@pytest.fixture(scope="module")
def tap():
    return (PROBE / "probe.tap").read_bytes()


@pytest.fixture(scope="module")
def manifest():
    return json.loads((PROBE / "probe.manifest.json").read_text())


@pytest.fixture(scope="module")
def nl(tap, manifest):
    return N.check(tap, manifest["nIn"], manifest["nOut"])


def test_artefacts_agree_with_each_other(tap, manifest, nl):
    kk = "0x" + N.keccak256(tap).hex()
    assert manifest["keccak256"] == kk
    assert (PROBE / "probe.hex").read_text() == "0x" + tap.hex() + "\n"
    assert json.loads((PROBE / "probe.map.json").read_text())["keccak256"] == kk
    assert (manifest["nIn"], manifest["nOut"], manifest["nState"]) == (M.N_IN, M.N_OUT, M.N_STATE) == (2, 10, 9)
    assert (manifest["nNand"], manifest["nLatch"], manifest["bytes"]) == (nl.n_nand, nl.n_latch, len(tap))
    assert len(tap) == 7 * nl.n_nand + 4 * nl.n_latch
    assert nl.latches_first and nl.is_flat and nl.n_latch == 9
    assert nl.gate_count < 150                                   # the size budget for this circuit
    assert N.live_count(nl) == nl.gate_count                     # no dead element
    assert [i["name"] for i in manifest["inputs"]] == ["en", "clr"]
    assert [o["name"] for o in manifest["outputs"]] == [f"count[{i}]" for i in range(8)] + ["flag", "parity"]
    assert [l["name"] for l in manifest["latches"]] == [f"count[{i}]" for i in range(8)] + ["flag"]
    assert [l["record"] for l in manifest["latches"]] == list(range(9))
    assert manifest["tapeout"] == {"nIn": 2, "nOut": 10, "burnNand": nl.n_nand, "burnLatch": nl.n_latch}


def test_readme_states_the_exact_numbers(manifest):
    text = (PROBE / "README.md").read_text()
    for fact in (manifest["keccak256"], f"{manifest['nNand']} NAND", f"{manifest['nLatch']} LATCH",
                 f"{manifest['bytes']} bytes", f"{manifest['gateCount']} gates"):
        assert fact in text, fact


def test_netlist_equals_the_behavioural_model_on_every_state_and_input(nl):
    states = [s for s in range(512) for _ in range(4)]
    inputs = [x for _ in range(512) for x in range(4)]
    ns, y = sim.step_many_int(nl, states, inputs)
    for s, x, a, b in zip(states, inputs, ns, y):
        assert (a, b) == M.beat(s, x), (s, x)


def test_reference_implementation_agrees(nl, reference):
    c = reference.load(nl.data, 2, 10)
    for s in range(512):
        for x in range(4):
            ns, y = reference.beat(c, [(s >> i) & 1 for i in range(9)], [(x >> i) & 1 for i in range(2)])
            assert (sum(b << i for i, b in enumerate(ns)), sum(b << i for i, b in enumerate(y))) == M.beat(s, x)


def test_vectors_file_is_current_and_passes(nl):
    r = subprocess.run([sys.executable, str(PROBE / "gen_vectors.py"), "--check"], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    doc = json.loads((PROBE / "probe.vectors.json").read_text())
    assert len(doc["beats"]) == 285 and len(doc["exhaustive"]) == 2048
    state = b""
    for b in doc["beats"]:                                       # the walk chains from the zero state
        assert bytes.fromhex(b["state"]) == (state or b"\x00\x00")
        ns, out = sim.step(nl, None, None, state, bytes.fromhex(b["inputs"]))
        assert (ns.hex(), out.hex()) == (b["newState"], b["outputs"])
        state = ns
    got = sim.step_many(nl, [bytes.fromhex(r[0]) for r in doc["exhaustive"]], [bytes.fromhex(r[1]) for r in doc["exhaustive"]])
    assert [(a.hex(), b.hex()) for a, b in got] == [(r[2], r[3]) for r in doc["exhaustive"]]


def test_behaviour_story(nl):
    """Count to saturation from zero: the flag sets exactly when 255 is reached, clr clears only the count."""
    beats = sim.run_beats(nl, [b"\x01"] * 257)
    counts = [int.from_bytes(bytes.fromhex(b["outputs"]), "little") & 0xFF for b in beats]
    flags = [(int.from_bytes(bytes.fromhex(b["outputs"]), "little") >> 8) & 1 for b in beats]
    assert counts == list(range(1, 256)) + [255, 255]
    assert flags == [0] * 254 + [1, 1, 1]
    after_clr = sim.run_beats(nl, [b"\x02", b"\x01", b"\x03"], state=bytes.fromhex(beats[-1]["newState"]))
    assert [b["outputs"] for b in after_clr] == ["0001", "0103", "0001"]        # count 0, flag 1; count 1; clr wins


def test_proof_report_is_complete(manifest):
    rep = json.loads((PROBE / "probe.proofs.json").read_text())
    assert rep["ok"] and rep["keccak256"] == manifest["keccak256"]
    names = {(p["name"], p["engine"]) for p in rep["proofs"]}
    assert len(rep["proofs"]) == len(names) == 22 and all(p["status"] == "proved" for p in rep["proofs"])
    assert {("probe_core == netlist", "yosys-sat"), ("probe_core == netlist", "z3"), ("full_spec", "z3")} <= names


def test_committed_netlist_is_proven_equal_to_the_rtl(nl, build_root):
    src = [str(PROBE / "probe_core.v")]
    assert prove.equiv_yosys(src, "probe_core", nl, work=str(build_root / "probe" / "y")).ok
    assert prove.equiv_z3(src, "probe_core", nl, work=str(build_root / "probe" / "z")).ok
    res = prove.check_z3(nl, prove.load_predicates(str(PROBE / "probe_props.py")))
    assert [r.name for r in res] == ["flag_sticky", "full_spec", "never_wraps", "saturated_implies_flag"]
    assert all(r.ok for r in res), [r.line() for r in res]


def test_rebuild_reproduces_the_committed_bytes(tap, build_root):
    out = build_root / "probe_rebuild"
    r = synth.synthesize([str(PROBE / "probe_core.v")], "probe", out_dir=str(out),
                         pins=pack.load_pins(str(PROBE / "probe.pins.json")))
    assert r.packed.data == tap, "a rebuild no longer gives the committed netlist: " + r.summary()
    for f in ("probe.tap", "probe.hex", "probe.manifest.json", "probe.map.json"):
        assert (out / f).read_bytes() == (PROBE / f).read_bytes(), f
