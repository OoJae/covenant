"""Synthesis smoke tests: Verilog -> NAND netlist -> simulation equals a Python model on ALL inputs, and RTL
versus netlist equivalence is proven by both engines. These run Yosys (about one second per invocation)."""
import dataclasses
import json
import random
import re
import subprocess
import time

import pytest

from conftest import RTL, TOOLS
from tapc import netlist as N
from tapc import pack, prove, sim, synth, unpack, yosys

TAPC = str(TOOLS / "bin" / "tapc")
TIMINGS = {}


@pytest.fixture(scope="module")
def add12(build_root):
    t0 = time.perf_counter()
    r = synth.synthesize([str(RTL / "add12_core.v")], "add12", out_dir=str(build_root / "add12"), recipe="auto")
    TIMINGS["add12 synth (auto portfolio)"] = time.perf_counter() - t0
    return r


@pytest.fixture(scope="module")
def cnt4(build_root):
    return synth.synthesize([str(RTL / "cnt4_core.v")], "cnt4", out_dir=str(build_root / "cnt4"), recipe="auto")


def mutate(nl, k=None):
    """Swap one NAND input for another signal: a netlist that differs from the original somewhere."""
    els = list(nl.elements)
    idx = [i for i, e in enumerate(els) if e.op == N.NAND]
    for i in idx if k is None else [idx[k]]:
        e = els[i]
        for alt in range(2, e.first_out):
            if alt not in e.ins:
                trial = list(els)
                trial[i] = dataclasses.replace(e, ins=(e.ins[0], alt))
                m = N.check(N.encode(trial), nl.n_in, nl.n_out)
                if nl.n_state + nl.n_in <= 12:
                    n = 1 << (nl.n_state + nl.n_in)
                    st = [v & ((1 << nl.n_state) - 1) for v in range(n)]
                    xi = [(v >> nl.n_state) for v in range(n)]
                else:
                    rng = random.Random(1)
                    st = [rng.getrandbits(nl.n_state) if nl.n_state else 0 for _ in range(4096)]
                    xi = [rng.getrandbits(nl.n_in) for _ in range(4096)]
                if sim.step_many_int(m, st, xi) != sim.step_many_int(nl, st, xi):
                    return m
    raise AssertionError("no observable mutation found")


# ---------------------------------------------------------------------------------------------- 12-bit adder

def test_adder_gate_count_matches_the_hand_built_ripple(add12):
    """9 NANDs per full adder, 5 for the half adder at bit 0: 5 + 11 * 9 = 104."""
    m = add12.packed.manifest
    assert (m["nIn"], m["nOut"], m["nState"], m["nLatch"]) == (24, 13, 0, 0)
    assert m["nNand"] == 104, add12.summary()
    assert m["bytes"] == 7 * 104 and m["gateCount"] == 104
    assert m["build"]["yosys"].startswith("Yosys 0.69") and m["build"]["sources"][0]["file"] == "add12_core.v"
    assert all(r.ok for r in add12.results), add12.summary()


def test_adder_equals_python_model_on_all_inputs(add12):
    nl = add12.packed.netlist
    planes, n = sim.exhaustive_planes(24)                       # all 16,777,216 input vectors, bit-sliced
    _, out = sim.step_planes(nl, [], planes, n)
    a, b = planes[:12], planes[12:]
    carry, want = 0, []
    for i in range(12):                                         # the same sum computed on bit planes
        want.append(a[i] ^ b[i] ^ carry)
        carry = (a[i] & b[i]) | (carry & (a[i] ^ b[i]))
    want.append(carry)
    assert out == want
    for v in (0, 1, 0xFFF, 0xFFF000, 0xFFFFFF, 0x123456, 0xABCDEF):      # and a few through the scalar path
        got = int.from_bytes(sim.step(nl, None, None, b"", v.to_bytes(3, "little"))[1], "little")
        assert got == (v & 0xFFF) + (v >> 12)


def test_adder_equivalence_is_proven_by_both_engines(add12, build_root):
    src = [str(RTL / "add12_core.v")]
    a = prove.equiv_yosys(src, "add12_core", add12.packed.netlist, work=str(build_root / "add12" / "eq_y"))
    b = prove.equiv_z3(src, "add12_core", add12.packed.netlist, work=str(build_root / "add12" / "eq_z"))
    assert a.ok and a.engine == "yosys-sat", a.line()
    assert b.ok and b.engine == "z3", b.line()
    TIMINGS["add12 equivalence, yosys sat"] = a.seconds
    TIMINGS["add12 equivalence, z3"] = b.seconds


def test_adder_mutant_is_refuted_with_a_real_counterexample(add12, build_root):
    nl = add12.packed.netlist
    bad = mutate(nl, k=40)
    src = [str(RTL / "add12_core.v")]
    for f, tag in ((prove.equiv_yosys, "y"), (prove.equiv_z3, "z")):
        r = f(src, "add12_core", bad, work=str(build_root / "add12" / f"mut_{tag}"))
        assert r.status == prove.FAILED, r.line()
        x = r.counterexample["x"]
        got = int.from_bytes(sim.step(bad, None, None, b"", x.to_bytes(3, "little"))[1], "little")
        assert got != (x & 0xFFF) + (x >> 12)                   # the counterexample really breaks the mutant
        good = int.from_bytes(sim.step(nl, None, None, b"", x.to_bytes(3, "little"))[1], "little")
        assert good == (x & 0xFFF) + (x >> 12)


def test_baseline_recipes_work_but_cost_more(add12, build_root):
    """The plain INV + NAND2 liberty (plus BUF) and `abc -g NAND` both give correct but larger adders."""
    r = synth.synthesize([str(RTL / "add12_core.v")], "add12", out_dir=None, build_dir=str(build_root / "add12_base"),
                         recipe="nand-area,g-nand,g-nand-ripple,nand-ripple")
    counts = {x.recipe: x.n_nand for x in r.results}
    assert all(x.ok for x in r.results), r.summary()
    planes, n = sim.exhaustive_planes(24)
    want = sim.step_planes(add12.packed.netlist, [], planes, n)
    for x in r.results:
        assert sim.step_planes(x.packed.netlist, [], planes, n) == want            # all 2^24 inputs
        assert prove.equiv_netlists_z3(x.packed.netlist, add12.packed.netlist, 24, 13).ok
    assert min(counts.values()) > 104
    TIMINGS["add12 NAND counts: " + ", ".join(f"{k} {v}" for k, v in counts.items())] = 0.0


def test_a_two_cell_liberty_is_refused_by_abc(build_root):
    """Recorded fact about the pinned wheel: ABC's read_lib refuses a library with fewer than three cell
    classes, which is why the 'nand' library carries a BUF that the mapper never uses."""
    work = build_root / "two_cell"
    work.mkdir()
    (work / "a.v").write_text((RTL / "add12_core.v").read_text())
    (work / "two.lib").write_text("""library(two) {
  cell(INV) { area : 1; pin(A) { direction : input; } pin(Y) { direction : output; function : "!A"; } }
  cell(NAND2) { area : 1; pin(A) { direction : input; } pin(B) { direction : input; }
                pin(Y) { direction : output; function : "!(A*B)"; } }
}
""")
    (work / "s.abc").write_text("strash; map -a; topo\n")
    run = yosys.run_script("read_verilog a.v\nhierarchy -top add12_core\nproc; opt; techmap; opt\n"
                           "abc -liberty two.lib -script s.abc\nwrite_blif -gates out.blif\n", str(work), check=False)
    assert run.returncode != 0
    assert "Library with only 2 cell classes cannot be used" in run.stdout + run.log


# ---------------------------------------------------------------------------------------------- 4-bit counter

def cnt4_model(s, x):
    total = s + (x & 1)
    return total & 15, (total & 15) | ((total >> 4) << 4)


def test_counter_equals_python_model_on_all_states_and_inputs(cnt4):
    nl = cnt4.packed.netlist
    m = cnt4.packed.manifest
    assert (m["nIn"], m["nOut"], m["nState"], m["nLatch"]) == (1, 5, 4, 4)
    assert nl.latches_first and m["nNand"] <= 30, cnt4.summary()
    for s in range(16):
        for x in range(2):
            ns, y = sim.step(nl, None, None, bytes([s]), bytes([x]))
            assert (ns[0], y[0]) == cnt4_model(s, x), (s, x)
    # a run of 40 enabled beats from zero wraps twice
    beats = sim.run_beats(nl, [b"\x01"] * 40)
    assert [int(b["newState"], 16) for b in beats] == [(i + 1) % 16 for i in range(40)]
    assert [int(b["outputs"], 16) >> 4 for b in beats] == [1 if (i + 1) % 16 == 0 else 0 for i in range(40)]


def test_counter_equivalence_and_mutants(cnt4, build_root):
    nl = cnt4.packed.netlist
    src = [str(RTL / "cnt4_core.v")]
    w = build_root / "cnt4"
    assert prove.equiv_yosys(src, "cnt4_core", nl, work=str(w / "eq_y")).ok
    assert prove.equiv_z3(src, "cnt4_core", nl, work=str(w / "eq_z")).ok
    bad = mutate(nl)
    for f, tag in ((prove.equiv_yosys, "y"), (prove.equiv_z3, "z")):
        r = f(src, "cnt4_core", bad, work=str(w / f"mut_{tag}"))
        assert r.status == prove.FAILED and set(r.counterexample) >= {"s", "x"}, r.line()
        s, x = r.counterexample["s"], r.counterexample["x"]
        ns, y = sim.step(bad, None, None, bytes([s]), bytes([x]))
        assert (ns[0], y[0]) != cnt4_model(s, x)
        assert prove.counterexample_vectors(r, bad) == (bytes([s]), bytes([x]))
    # a netlist with a different shape is an error, not a pass
    other = N.check(N.encode([N.nand(2, 2)] * 5), 1, 5)
    assert prove.equiv_yosys(src, "cnt4_core", other, work=str(w / "shape_y")).status == prove.ERROR
    assert prove.equiv_z3(src, "cnt4_core", other, work=str(w / "shape_z")).status == prove.ERROR


def test_wrapper_properties_both_engines(cnt4, build_root):
    nl = cnt4.packed.netlist
    src = [str(RTL / "cnt4_props.v")]
    sigs = prove.wrapper_outputs(src, "cnt4_props", str(build_root / "cnt4" / "ports"), nl, tap_module="cnt4_tap")
    assert sigs == ["p_hold", "p_inc", "p_wrap", "p_never_zero"]
    for engine in ("yosys", "z3"):
        res = prove.prove_properties(src, "cnt4_props", sigs, tap=nl, tap_module="cnt4_tap",
                                     work=str(build_root / "cnt4" / f"prop_{engine}"), engine=engine)
        status = {r.name.split(".")[1]: r for r in res}
        assert [status[s].status for s in sigs] == [prove.PROVED] * 3 + [prove.FAILED], [r.line() for r in res]
        cex = status["p_never_zero"].counterexample
        s, x = cex.get("s", 0), cex.get("x", 0)
        assert cnt4_model(s, x)[0] == 0                         # the counterexample really gives ns == 0
    # a signal that does not exist, and one that is not 1 bit, are errors
    res = prove.prove_properties(src, "cnt4_props", ["p_missing"], tap=nl, tap_module="cnt4_tap",
                                 work=str(build_root / "cnt4" / "prop_bad"))
    assert res[0].status == prove.ERROR


def test_z3_predicates_from_bytes(cnt4):
    import z3
    nl = cnt4.packed.netlist

    def spec(c):
        s, en = c.bv(c.s), c.x[0]
        return z3.And(c.bv(c.ns) == s + z3.If(en, z3.BitVecVal(1, 4), z3.BitVecVal(0, 4)),
                      c.bv(c.y[0:4]) == c.bv(c.ns), c.y[4] == z3.And(en, s == 15))

    res = prove.check_z3(nl, {"spec": spec, "false_claim": lambda c: c.bv(c.ns) != 0,
                              "not_bool": lambda c: c.bv(c.ns)})
    by = {r.name: r for r in res}
    assert by["spec"].ok
    assert by["false_claim"].status == prove.FAILED
    cex = by["false_claim"].counterexample
    assert cnt4_model(cex["s"], cex["x"])[0] == 0
    assert by["not_bool"].status == prove.ERROR
    # two netlists of the same function are equivalent; a mutant is not
    assert prove.equiv_netlists_z3(nl, nl, 1, 5).ok
    assert prove.equiv_netlists_z3(nl, mutate(nl), 1, 5).status == prove.FAILED


def test_unpack_round_trip_through_yosys(cnt4, build_root):
    """bytes -> Verilog -> Yosys/ABC -> bytes again: the second netlist computes the same beat."""
    nl = cnt4.packed.netlist
    v = build_root / "cnt4" / "rt_core.v"
    v.write_text(unpack.to_verilog(nl, module="rt_core"))
    r = synth.synthesize([str(v)], "rt", out_dir=None, build_dir=str(build_root / "cnt4_rt"), recipe="rich-compress")
    assert (r.packed.netlist.n_in, r.packed.netlist.n_out, r.packed.netlist.n_state) == (1, 5, 4)
    assert prove.equiv_netlists_z3(nl, r.packed.netlist, 1, 5).ok
    assert prove.equiv_yosys([str(v)], "rt_core", nl, work=str(build_root / "cnt4_rt" / "eq")).ok


# ---------------------------------------------------------------------------------------------- build properties

def test_build_is_byte_deterministic(cnt4, add12, build_root):
    for name, first in (("cnt4", cnt4), ("add12", add12)):
        again = synth.synthesize([str(RTL / f"{name}_core.v")], name, out_dir=str(build_root / f"{name}_again"),
                                 recipe="auto")
        assert again.packed.data == first.packed.data
        assert again.recipe == first.recipe
        assert [(r.recipe, r.keccak256) for r in again.results] == [(r.recipe, r.keccak256) for r in first.results]
        for kind in ("tap", "hex", "manifest", "map"):
            assert open(again.paths[kind], "rb").read() == open(first.paths[kind], "rb").read(), kind


def test_hier_mode_keeps_instance_names(build_root):
    src = [str(RTL / "hier_core.v")]
    flat = synth.synthesize(src, "hier", out_dir=None, build_dir=str(build_root / "hier_flat"), recipe="rich-compress")
    hier = synth.synthesize(src, "hier", out_dir=None, build_dir=str(build_root / "hier_hier"), recipe="rich-compress",
                            hier=True)
    for r in (flat, hier):
        nl = r.packed.netlist
        assert (nl.n_in, nl.n_out, nl.n_state) == (8, 6, 1)
        st, xi = [v & 1 for v in range(512)], [v >> 1 for v in range(512)]
        ns, y = sim.step_many_int(nl, st, xi)
        for s, x, a, b in zip(st, xi, ns, y):
            lo, hi = x & 15, x >> 4
            assert (a, b) == (s ^ (lo < hi), (lo + hi) | ((lo < hi) << 5))
        assert prove.equiv_yosys(src, "hier_core", nl, work=str(build_root / f"hier_eq_{r is hier}")).ok
    assert {rec["block"] for rec in flat.packed.map["records"]} == {None}
    blocks = {rec["block"] for rec in hier.packed.map["records"]}
    assert {"u_add", "u_cmp"} <= blocks, blocks
    assert hier.packed.manifest["build"]["hier"] is True
    TIMINGS[f"hier core: flat {flat.packed.netlist.n_nand} NAND, hier {hier.packed.netlist.n_nand} NAND"] = 0.0


LOG8DT = [0, 0, 8, 13, 16, 19, 21, 22, 24, 25, 27, 28, 29, 30, 30, 31]


def test_case_tables_are_logic_not_roms(build_root):
    """Regression: a `case` lookup table must be synthesised to gates, and both proof paths must see it as
    logic. (With plain `proc` it becomes a $memrd_v2 ROM: the SAT pass then stops with "No SAT model available"
    and the SMT-LIB path reports a counterexample that does not exist.)"""
    src = [str(RTL / "lut_core.v")]
    r = synth.synthesize(src, "lut", out_dir=None, build_dir=str(build_root / "lut"), recipe="rich-compress,rich-area")
    nl = r.packed.netlist
    assert (nl.n_in, nl.n_out, nl.n_state) == (5, 6, 6)
    st = [v & 63 for v in range(1 << 11)]
    xi = [v >> 6 for v in range(1 << 11)]
    ns, y = sim.step_many_int(nl, st, xi)
    for s, x, a, b in zip(st, xi, ns, y):
        want = (LOG8DT[x & 15] + (s if x & 16 else 0)) & 63
        assert (a, b) == (want, want), (s, x)
    a = prove.equiv_yosys(src, "lut_core", nl, work=str(build_root / "lut" / "eq_y"))
    b = prove.equiv_z3(src, "lut_core", nl, work=str(build_root / "lut" / "eq_z"))
    assert a.ok and b.ok, (a.line(), b.line())
    for f, tag in ((prove.equiv_yosys, "y"), (prove.equiv_z3, "z")):      # and a real difference is still found
        bad = f(src, "lut_core", mutate(nl), work=str(build_root / "lut" / f"mut_{tag}"))
        assert bad.status == prove.FAILED, bad.line()


def test_z3_path_refuses_a_design_with_state(build_root):
    """A register in the 'RTL' would be a free variable in the query: report an error, never a verdict."""
    v = build_root / "reg_core.v"
    v.write_text("module reg_core(input [0:0] x, output [0:0] y);\n  reg q = 1'b0;\n"
                 "  wire clk = x[0];\n  always @(posedge clk) q <= ~q;\n  assign y = q;\nendmodule\n")
    nl = N.check(N.encode([N.nand(2, 2)]), 1, 1)
    r = prove.equiv_z3([str(v)], "reg_core", nl, work=str(build_root / "reg_z"))
    assert r.status == prove.ERROR and "not combinational" in r.detail, r.line()
    r = prove.equiv_yosys([str(v)], "reg_core", nl, work=str(build_root / "reg_y"))
    assert r.status == prove.ERROR and "not combinational" in r.detail, r.line()
    lat = build_root / "lat_core.v"
    lat.write_text((RTL / "bad_latch_core.v").read_text())
    nl2 = N.check(N.encode([N.nand(2, 3)]), 2, 1)
    for f, tag in ((prove.equiv_yosys, "y"), (prove.equiv_z3, "z")):
        r = f([str(lat)], "bad_latch_core", nl2, work=str(build_root / f"lat_{tag}"))
        assert r.status == prove.ERROR, r.line()


def test_proof_time_limits_are_enforced(build_root, monkeypatch):
    """Yosys's own `sat -timeout` never fires in the wasm build, so tapc stops the process itself. A proof that
    runs out of time is reported as `timeout` (never as proved), and the proofs queued behind it still run."""
    monkeypatch.setattr(prove, "GRACE", 4)
    t0 = time.perf_counter()
    res = prove.prove_properties([str(RTL / "slow_props.v")], "slow_props", ["p_fast1", "p_slow", "p_fast2"],
                                 work=str(build_root / "slow"), timeout=3)
    assert [r.status for r in res] == [prove.PROVED, prove.TIMEOUT, prove.PROVED], [r.line() for r in res]
    assert not res[1].ok and time.perf_counter() - t0 < 40
    assert res[0].seconds < 3 and res[2].seconds < 3               # per-proof times come from the Yosys log
    r = synth.synthesize([str(RTL / "mul8_core.v")], "mul8", out_dir=None, build_dir=str(build_root / "mul8"),
                         recipe="rich-area")
    assert 600 < r.packed.netlist.n_nand < 700
    eq = prove.equiv_yosys([str(RTL / "mul8_core.v")], "mul8_core", r.packed.netlist,
                           work=str(build_root / "mul8" / "eq"), timeout=2)
    assert eq.status == prove.TIMEOUT and "no verdict within 2 s" in eq.detail, eq.line()
    # the multiplier itself is right: all 65,536 inputs
    planes, n = sim.exhaustive_planes(16)
    _, out = sim.step_planes(r.packed.netlist, [], planes, n)
    assert sim.from_planes(out, n) == [(v & 255) * (v >> 8) for v in range(1 << 16)]


def test_time_limit_is_per_proof_not_per_batch(build_root, monkeypatch):
    """Unit test of the batching logic with a scripted Yosys: when the process is stopped because the batch as a
    whole used up its budget, the proof in progress is not a timeout; it and the rest run again."""
    ok = ("Import proof-constraint: \\{sig} = 1'1\nSAT proof finished - no model found: SUCCESS!\n")
    calls = []

    def fake_run(script, cwd, tag="yosys", timeout=None, check=True, timestamps=False):
        todo = re.findall(r"log TAPC-BEGIN (p\d+)\nsat -prove (\S+) ", script)
        calls.append([t for t, _ in todo])
        if len(calls) == 1:                         # p0 done at 3 s; p1 began at 9.5 s; killed at 10 s
            log = (f"[00003.000000] TAPC-BEGIN p0\n[00003.100000] " + ok.format(sig="a").replace("\n", "\n[00003.200000] ", 1)
                   + "[00003.500000] TAPC-END p0\n[00009.500000] TAPC-BEGIN p1\n[00009.600000] Solving..\n")
            return yosys.YosysRun(-9, log, 10.0)
        if len(calls) == 2:                         # p1 has its whole time now and really hangs
            log = "[00001.000000] TAPC-BEGIN p1\n[00001.100000] Solving..\n"
            return yosys.YosysRun(-9, log, 10.0)
        log = "".join(f"[0000{k}.000000] TAPC-BEGIN {t}\n[0000{k}.100000] " + ok.format(sig=sig).replace("\n", f"\n[0000{k}.200000] ", 1)
                      + f"[0000{k}.900000] TAPC-END {t}\n" for k, (t, sig) in enumerate(todo, 1))
        return yosys.YosysRun(0, log, 3.0)

    monkeypatch.setattr(prove.yosys, "run_script", fake_run)
    monkeypatch.setattr(prove, "GRACE", 2)
    src = build_root / "fake_props.v"
    src.write_text("module w(input x, output a, output b, output c); endmodule\n")
    res = prove.prove_properties([str(src)], "w", ["a", "b", "c"], work=str(build_root / "fake"), timeout=8)
    assert calls == [["p0", "p1", "p2"], ["p1", "p2"], ["p2"]]
    assert [r.status for r in res] == [prove.PROVED, prove.TIMEOUT, prove.PROVED], [r.line() for r in res]
    assert abs(res[0].seconds - 0.5) < 1e-6 and abs(res[2].seconds - 0.9) < 1e-6


def test_invalid_cores_are_refused(build_root):
    with pytest.raises(synth.SynthError):
        synth.synthesize([str(RTL / "bad_clocked.v")], "bad_clocked", out_dir=None,
                         build_dir=str(build_root / "bad1"), recipe="rich-compress")
    with pytest.raises(synth.SynthError):
        synth.synthesize([str(RTL / "bad_latch_core.v")], "bad_latch", out_dir=None,
                         build_dir=str(build_root / "bad2"), recipe="rich-compress")
    with pytest.raises(synth.SynthError, match="unknown recipe"):
        synth.synthesize([str(RTL / "cnt4_core.v")], "cnt4", out_dir=None, recipe="nope")
    with pytest.raises(synth.SynthError, match="above the limit"):
        synth.synthesize([str(RTL / "add12_core.v")], "add12", out_dir=None, build_dir=str(build_root / "bad3"),
                         recipe="rich-compress", max_bytes=100)
    with pytest.raises(pack.PackError, match="--nout"):
        pack.pack_blif_file(str(build_root / "bad3" / "rich-compress" / "add12.blif"), n_out=112)


def test_cli_end_to_end(build_root):
    out = build_root / "cli"

    def run(*args, ok=True):
        p = subprocess.run([TAPC, *args], capture_output=True, text=True)
        assert (p.returncode == 0) == ok, p.stdout + p.stderr
        return p.stdout

    text = run("synth", str(RTL / "cnt4_core.v"), "--out", str(out), "--recipe", "rich-compress")
    assert "keccak256 0x" in text
    tap = str(out / "cnt4.tap")
    info = json.loads(run("info", tap))
    assert info["wellFormed"] and info["latchesFirst"] and (info["nIn"], info["nOut"], info["nState"]) == (1, 5, 4)
    assert json.loads(run("info", str(out / "cnt4.hex"), "--nin", "1", "--nout", "5"))["keccak256"] == info["keccak256"]
    beats = json.loads(run("sim", tap, "--state", "0x0e", "--inputs", "01", "--inputs", "01", "--inputs", "00"))
    assert [b["newState"] for b in beats] == ["0x0f", "0x00", "0x00"]
    assert [b["outputs"] for b in beats] == ["0x0f", "0x10", "0x00"]
    assert "wire n" in run("unpack", tap, "--module", "cnt4_tap")
    assert "LATCH d=" in run("unpack", tap, "--list")
    blif_path = str(out / "build" / "rich-compress" / "cnt4.blif")
    run("pack", blif_path, "--out", str(out / "repack"), "--nin", "1", "--nout", "5")
    assert (out / "repack" / "cnt4.tap").read_bytes() == (out / "cnt4.tap").read_bytes()
    text = run("prove", "all", "--rtl", str(RTL / "cnt4_core.v"), "--top", "cnt4_core", "--tap", tap,
               "--props-v", str(RTL / "cnt4_props.v"), "--props-top", "cnt4_props", "--tap-module", "cnt4_tap",
               "--signal", "p_hold", "--signal", "p_inc", "--signal", "p_wrap",
               "--work", str(out / "prove"), "--report", str(out / "proofs.json"))
    assert "8/8 proved" in text
    rep = json.loads((out / "proofs.json").read_text())
    assert rep["ok"] and rep["keccak256"] == info["keccak256"] and len(rep["proofs"]) == 8
    assert all("seconds" not in p for p in rep["proofs"])                 # the report is reproducible
    text = run("prove", "prop", "--rtl", str(RTL / "cnt4_props.v"), "--top", "cnt4_props", "--tap", tap,
               "--tap-module", "cnt4_tap", "--signal", "p_never_zero", "--work", str(out / "prove2"), ok=False)
    assert "FAILED" in text and "counterexample" in text
    assert not json.loads(run("info", "0x03000002000003", "--nin", "2", "--nout", "1", ok=False))["wellFormed"]


def test_zz_report_measurements(add12, cnt4):
    """Not a check: prints what the smoke tests measured (shown with -s or -rA)."""
    print("\nmeasured in this run:")
    for k, v in TIMINGS.items():
        print(f"  {k}" + (f": {v:.2f} s" if v else ""))
    print("  " + add12.summary().replace("\n", "\n  "))
    print("  " + cnt4.summary().replace("\n", "\n  "))
