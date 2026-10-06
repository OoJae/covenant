"""tapc architect: the compile step behind Covenant Architect (protocol covenant-architect/1).

Fast tests check the request and parameter validation in-process and through the command line. The slow ones run
the whole pipeline (Yosys, z3, worker processes): the stock chip byte for byte, determinism, the time budget, a
proof that fails, the hostile preset, and the service's own adapter (Node) against the real command.

    cd chips/tools && ../.venv/bin/python -m pytest tests/test_architect.py
"""
import json
import os
import random
import shutil
import signal
import subprocess
import sys
import time

import pytest

from conftest import CHIPS, TOOLS
from tapc import architect as A

ROOT = CHIPS.parent
OUT = CHIPS / "out"
GLUTTON = CHIPS / "cells" / "glutton"
SERVICE = ROOT / "services" / "architect"
STOCK_KECCAK = "0xe548768a1adafa7331faacfd029e1a829b00af3f7d769657f3b234ccdd7143b4"
PINS_SHA256 = "0xfe8b7a49a7d0f9a75d0684b88587648284fc586f936035f8831cb6d34060e209"
CUSTOM = {"M1": "430", "M2": 460, "AL0": 40, "AL1": 24, "AL2": 12, "AL3": 4, "capT": 40, "allowCumBps": 1600,
          "fbAllow": 4, "CEIL0": 432, "ceilMax": 432, "RC": 72, "RESMIN_Q": 399}


def request(preset="flow-governor", params=None, **extra) -> dict:
    doc = {"protocol": A.PROTOCOL, "op": "compile", "preset": preset, "params": {} if params is None else params}
    doc.update(extra)
    return doc


def run(req, *args, timeout=300, **popen):
    """Run `python -m tapc.architect` like the service does: request on stdin, answer on stdout.
    Returns (exit code, parsed answer or None, stderr, seconds)."""
    raw = req if isinstance(req, (bytes, str)) else json.dumps(req)
    raw = raw.encode() if isinstance(raw, str) else raw
    env = dict(os.environ, PYTHONPATH=str(TOOLS))
    t = time.monotonic()
    p = subprocess.run([sys.executable, "-m", "tapc.architect", *args], input=raw, capture_output=True, env=env,
                       timeout=timeout, **popen)
    seconds = time.monotonic() - t
    out = p.stdout.decode()
    answer = None
    if out.strip():
        assert out.count("\n") == 1 and out.endswith("\n"), "stdout holds exactly one JSON document"
        answer = json.loads(out)
    return p.returncode, answer, p.stderr.decode(), seconds


def statuses(answer) -> dict:
    out = {}
    for r in answer["proofs"]:
        out[r["status"]] = out.get(r["status"], 0) + 1
    return out


def leftover(work) -> list:
    """Processes still running for a request: those whose command line names its work directory (the proof
    workers) and those whose current directory lies inside it (the Yosys processes the workers start)."""
    work = os.path.realpath(str(work))
    found = set()
    p = subprocess.run(["pgrep", "-f", work], capture_output=True, text=True)
    found |= {int(v) for v in p.stdout.split()}
    p = subprocess.run(["lsof", "-a", "-d", "cwd", "-F", "pn"], capture_output=True, text=True)
    pid = None
    for line in p.stdout.splitlines():
        if line.startswith("p"):
            pid = int(line[1:])
        elif line.startswith("n") and os.path.realpath(line[1:]).startswith(work):
            found.add(pid)
    found.discard(os.getpid())
    return sorted(found)


# ============================================================================================== fast: the request

def test_the_recipe_is_the_one_recorded_in_the_committed_manifest():
    from tapc import synth
    assert json.loads((OUT / "fg.manifest.json").read_text())["build"]["recipe"] == A.RECIPE
    assert A.RECIPE in synth.RECIPES


@pytest.mark.parametrize("raw, code, stage", [
    (b"not json", "bad_request", "request"),
    (b"[1, 2]", "bad_request", "request"),
    (b"\xff\xfe", "bad_request", "request"),
    (json.dumps(request(protocol="covenant-architect/2")), "unsupported_protocol", "request"),
    (json.dumps(request(op="prove")), "unsupported_op", "request"),
    (json.dumps(request(preset=7)), "bad_request", "request"),
    (json.dumps(request(preset="Flow Governor")), "bad_request", "request"),
    (json.dumps(request(preset="flow-gov")), "unknown_preset", "validate"),
    (json.dumps(request(params=[1])), "invalid_params", "validate"),
    (json.dumps(request(params="M1=430")), "invalid_params", "validate"),
    (json.dumps(request("glutton", {"capT": 48})), "invalid_params", "validate"),
])
def test_request_rejections_through_the_command_line(raw, code, stage):
    rc, answer, err, _ = run(raw)
    assert rc == A.EXIT_REJECTED
    assert answer["ok"] is False
    assert answer["error"]["code"] == code
    assert answer["error"]["stage"] == stage
    assert isinstance(answer["error"]["message"], str) and answer["error"]["message"]
    assert isinstance(answer["error"]["diagnostics"], list)
    assert "rejected" in err                                    # logs go to stderr


def test_unknown_preset_names_the_presets():
    _, answer, _, _ = run(request("flow-govenor"))
    d = answer["error"]["diagnostics"][0]
    assert d["path"] == "preset" and "flow-governor" in d["hint"] and "glutton" in d["hint"]


def test_null_or_missing_params_mean_none():
    assert A.parse_request(json.dumps(request(params=None)).encode())[1] == {}
    doc = request()
    del doc["params"]
    assert A.parse_request(json.dumps(doc).encode()) == ("flow-governor", {})


def test_work_directories_of_killed_requests_are_swept(tmp_path):
    old, new, other = tmp_path / (A.WORK_PREFIX + "old"), tmp_path / (A.WORK_PREFIX + "new"), tmp_path / "other"
    for d in (old, new, other):
        d.mkdir()
        (d / "f").write_text("x")
    past = time.time() - A.STALE_SECONDS - 60
    os.utime(old, (past, past))
    os.utime(other, (past, past))
    A.sweep_stale_workdirs(str(tmp_path))
    assert not old.exists() and new.exists() and other.exists()


def test_flags_are_checked():
    assert run(request(), "--budget", "1")[0] == 2
    assert run(request(), "--jobs", "0")[0] == 2


# ============================================================================================== fast: parameters

def reject(params) -> list:
    with pytest.raises(A.Reject) as e:
        A.validate_flow_governor(params)
    assert e.value.code == "invalid_params" and e.value.stage == "validate"
    return e.value.diagnostics


@pytest.mark.parametrize("params, code, path, text", [
    # type
    ({"M1": True}, "type", "params.M1", "boolean"),
    ({"M1": 1.5}, "type", "params.M1", "whole number"),
    ({"M1": "abc"}, "type", "params.M1", "string"),
    ({"M1": None}, "type", "params.M1", "null"),
    ({"M1": {"v": 1}}, "type", "params.M1", "object"),
    ({"M1": [430]}, "type", "params.M1", "array"),
    # range (bit width of the localparam, factory limits of INTERFACE.md section 7)
    ({"AL0": 64, "capT": 64}, "range", "params.AL0", "between 0 and 63"),
    ({"M3": 1024}, "range", "params.M3", "between 0 and 1023"),
    ({"RC": -1}, "range", "params.RC", "between 0 and 255"),
    ({"capT": 129}, "range", "params.capT", "between 0 and 128"),
    ({"allowCumBps": 5001}, "range", "params.allowCumBps", "between 0 and 5000"),
    ({"relMax": 0}, "range", "params.relMax", "between 1 and 256"),
    ({"floorMin": 0}, "range", "params.floorMin", "between 1 and 425"),
    ({"floorMin": 426}, "range", "params.floorMin", "between 1 and 425"),
    ({"epochLen": 299}, "range", "params.epochLen", "between 300 and 86400"),
    ({"fallbackEpochs": 1}, "range", "params.fallbackEpochs", "between 2 and 65535"),
    # names
    ({"floorrel": 2}, "unknown_param", "params.floorrel", "not a parameter"),
    ({"bogus": 1}, "unknown_param", "params.bogus", "not a parameter"),
    ({"SURGE_TH": 9}, "fixed", "params.SURGE_TH", "fixed at 8"),
    ({"DD_TH": 20}, "fixed", "params.DD_TH", "fixed at 16"),
    ({"DRYN": 9}, "fixed", "params.DRYN", "P4"),
    ({"CDN": 5}, "fixed", "params.CDN", "P4"),
    ({"TRN": 3}, "fixed", "params.TRN", "RTL"),
    ({"TR_MIN": 30}, "fixed", "params.TR_MIN", "fixed at 32"),
    ({"TR_MAX": 60}, "fixed", "params.TR_MAX", "fixed at 64"),
    ({"LEAK": 3}, "fixed", "params.LEAK", "RTL"),
    ({"capV": 1}, "fixed", "params.capV", "revenue"),
    ({"buyEnabled": False}, "fixed", "params.buyEnabled", "buys"),
    ({"FLOOR_T": 520}, "derived", "params.FLOOR_T", "FLOOR_Q + TOKEN_SHIFT"),
    ({"RESMIN_T": 560}, "derived", "params.RESMIN_T", "RESMIN_Q + TOKEN_SHIFT"),
    ({"TOKEN_SHIFT": 170}, "derived", "params.TOKEN_SHIFT", "reference token"),
    ({"taxBuyBps": 200}, "fixed", "params.taxBuyBps", "reference token"),
    # relations of gen_params.py (check_constraints, check_envelope, check_reference)
    ({"M1": 460}, "relation", "params.M1", "M1 < M2 < M3"),
    ({"M3": 452}, "relation", "params.M3", "M1 < M2 < M3"),
    ({"AL1": 50}, "relation", "params.AL1", "AL0 >= AL1 >= AL2 >= AL3"),
    ({"AL0": 40}, "relation", "params.AL0", "must equal the envelope's capT"),
    ({"capT": 40}, "relation", "params.capT", "must equal the envelope's capT"),
    ({"AL0": 56, "capT": 56}, "relation", "params.capT", "at least capT * 10000 / 256 = 2188"),
    ({"allowCumBps": 1874}, "relation", "params.allowCumBps", "lifetime cap"),
    ({"AL3": 4}, "relation", "params.AL3", "fbAllow (8) must be at most AL3 (4)"),
    ({"fbAllow": 9}, "relation", "params.fbAllow", "at most AL3"),
    ({"CEIL0": 400}, "relation", "params.CEIL0", "must equal the envelope's ceilMax"),
    ({"ceilMax": 1023}, "relation", "params.ceilMax", "must equal the envelope's ceilMax"),
    ({"CEIL0": 20, "ceilMax": 20}, "relation", "params.CEIL0", "at least 24"),
    ({"RC": 209}, "relation", "params.RC", "RC + AL0 must be at most 256"),
    ({"relMax": 256}, "relation", "params.relMax", "relMax must be 128"),
    ({"floorRel": 3}, "relation", "params.floorRel", "at most the chip's leak"),
    ({"epochLen": 20000, "floorRel": 1}, "relation", "params.epochLen", "halve within 30 days"),
    ({"epochLen": 86400}, "relation", "params.epochLen", "halve within 30 days"),
    ({"fallbackEpochs": 2881}, "relation", "params.fallbackEpochs", "within 30 days"),
    ({"FLOOR_Q": 824}, "relation", "params.FLOOR_Q", "below 1024"),
    ({"FLOOR_Q": 12}, "relation", "params.FLOOR_Q", "converted to tokens"),
    ({"RESMIN_Q": 855}, "relation", "params.RESMIN_Q", "fit 10 bits"),
    ({"RESMIN_Q": 12}, "relation", "params.RESMIN_Q", "converted to tokens"),
])
def test_every_parameter_rejection(params, code, path, text):
    diags = reject(params)
    assert diags[0]["code"] == code, diags
    assert diags[0]["path"] == path, diags
    assert text in diags[0]["message"], diags
    assert set(diags[0]) <= {"code", "path", "message", "hint"}


def test_hints_say_what_to_send():
    assert reject({"AL0": 40})[0]["hint"] == "set capT to 40"
    assert reject({"capT": 40})[0]["hint"] == "set AL0 to 40"
    assert reject({"AL0": 56, "capT": 56})[0]["hint"] == "set allowCumBps to 2188 or more"
    assert reject({"fallbackEpochs": 2881})[0]["hint"] == "use fallbackEpochs <= 2880 for epochLen 900"
    assert reject({"floorrel": 2})[0]["hint"].startswith("did you mean 'floorRel'?")
    assert reject({"FLOOR_Q": 12})[0]["hint"] == "nearest values that convert exactly: 13"
    assert reject({"DRYN": 9})[0]["hint"] == "leave DRYN out (or send 8)"


def test_every_diagnostic_is_reported_at_once():
    diags = reject({"AL0": 64, "M2": "x", "DRYN": 9, "FLOOR_T": 1, "foo": 1})
    assert [d["path"] for d in diags] == ["params.AL0", "params.DRYN", "params.FLOOR_T", "params.M2", "params.foo"]


def test_numbers_as_strings_and_integral_floats_are_accepted():
    doc, over = A.validate_flow_governor({"M1": " 430 ", "M2": 460.0, "AL0": "+40", "capT": 40, "SURGE_TH": "8"})
    assert over == {"AL0": 40, "M1": 430, "M2": 460, "capT": 40}
    assert doc["chip"]["M1"] == 430 and doc["chip"]["SURGE_TH"] == 8 and doc["envelope"]["capT"] == 40


def test_a_valid_override_gives_a_document_gen_params_accepts():
    gp = A.gen_params()
    doc, over = A.validate_flow_governor(CUSTOM)
    gp.check_constraints(doc)
    gp.check_envelope(doc)
    assert gp.check_reference(doc)["shift"] == 169
    assert doc["chip"]["RESMIN_T"] == 399 + 169 and doc["chip"]["FLOOR_T"] == 346 + 169
    assert "localparam [9:0] FG_M1 = 10'd430;" in gp.render(doc)
    assert "localparam [8:0] ENV_CAPT = 9'd40;" in gp.render(doc)
    ref = A.reference_doc()
    stock, none = A.validate_flow_governor({})
    assert none == {} and stock == ref
    assert gp.render(stock) == (CHIPS / "rtl" / "fg_params.vh").read_text()


def test_validation_never_crashes_and_restates_every_gen_params_relation():
    """Random combinations: only Reject comes out, and no rejection is left to the gen_params.py backstop (which
    would mean a relation without a path and a hint)."""
    rng = random.Random(7)
    names = list(A.FG_TUNABLE)
    accepted = 0
    for _ in range(3000):
        p = {}
        for n in rng.sample(names, rng.randint(1, 8)):
            s = A.FG_TUNABLE[n]
            p[n] = rng.choice([rng.randint(s.lo, s.hi), rng.randint(s.lo - 2, s.hi + 2), str(rng.randint(s.lo, s.hi))])
        if "AL0" in p and rng.random() < 0.7:
            p["capT"] = p["AL0"]
        try:
            A.validate_flow_governor(p)
            accepted += 1
        except A.Reject as e:
            assert all(d["path"] != "params" for d in e.diagnostics), (p, e.diagnostics)
    assert accepted > 0


# ============================================================================================== fast: cost

def test_cost_is_transistors_times_the_mint_price_plus_tapeouts_fees(monkeypatch):
    monkeypatch.delenv("TAPC_TRANSISTOR_PRICE_WEI", raising=False)
    m = json.loads((OUT / "fg.manifest.json").read_text())
    c = A.cost_of(m)
    assert c["transistors"] == 1952 and c["mintCalls"] == 2
    assert c["transistorCostOKB"] == "0.03904"                  # chips/rtl/NOTES.md section 2
    assert c["totalOKB"] == "0.04166"                           # + 2 x 0.00066 + 0.0013
    assert int(c["totalWei"]) == 1952 * 20 * 10 ** 12 + 2 * 660 * 10 ** 12 + 1300 * 10 ** 12
    assert c["gas"]["stepBound"] == 4_626_690 and c["gas"]["kernelStepBudget"] == 5_326_400
    assert "TapeOut's current fees" in c["fees"]
    monkeypatch.setenv("TAPC_TRANSISTOR_PRICE_WEI", "30000000000000")
    assert A.cost_of(m)["transistorCostOKB"] == "0.05856"
    monkeypatch.setenv("TAPC_TRANSISTOR_PRICE_WEI", "0.00003")
    with pytest.raises(A.Fault):
        A.cost_of(m)
    assert A.okb(10 ** 18) == "1" and A.okb(1) == "0.000000000000000001"


def test_the_proof_jobs_cover_the_property_wrappers(tmp_path):
    """The signal lists read from the sources equal what Yosys reports as the wrappers' 1-bit outputs."""
    from tapc import prove as tp
    tap = (OUT / "fg.tap").read_bytes()
    sigs = tp.wrapper_outputs([str(CHIPS / "rtl" / "fg_params.vh"), A.FG_PROPS_V], "fg_props", str(tmp_path / "p"),
                              tap, 96, 112, tap_module="fg_tap")
    assert A.wrapper_signals(A.FG_PROPS_V, "fg_props") == sigs
    assert [n for n, _ in tp.load_predicates(A.FG_PROPS_PY)] == A.byte_predicates(A.FG_PROPS_PY)
    jobs = A.fg_jobs(str(tmp_path), "fg.tap", "p.json", ["a", "b"], "vh")
    assert [j.key for j in jobs] == ["pins", "buyer-yosys", "buyer-z3", "eq-yosys", "eq-z3", "rest-yosys", "rest-z3"]
    groups = [{c.group for c in j.checks} for j in jobs]
    assert groups[1] == groups[2] == {"P1", "P2", "P3", "P4"}
    assert groups[3] == groups[4] == {"EQ"}
    assert groups[5] == groups[6] == {"P5", "P6", "PX"}
    assert sum(len(j.checks) for j in jobs) == len(sigs) + len(A.byte_predicates(A.FG_PROPS_PY)) + 1 + 2


# ============================================================================================== slow: the pipeline

@pytest.fixture(scope="module")
def stock():
    return run(request(), "--jobs", "4")


def test_stock_flow_governor_reproduces_the_committed_chip(stock):
    rc, answer, err, seconds = stock
    assert rc == 0, err
    assert answer["ok"] is True
    assert set(answer) == {"ok", "netlistHex", "manifest", "proofs", "cost"}
    data = bytes.fromhex(answer["netlistHex"][2:])
    assert data == (OUT / "fg.tap").read_bytes()
    assert answer["netlistHex"][2:] in (OUT / "fg.hex").read_text()
    assert len(data) <= A.MAX_NETLIST_BYTES

    manifest = dict(answer["manifest"])
    arch = manifest.pop("architect")
    assert manifest == json.loads((OUT / "fg.manifest.json").read_text())
    assert manifest["keccak256"] == STOCK_KECCAK
    assert arch["preset"] == "flow-governor" and arch["params"] == {} and arch["recipe"] == A.RECIPE
    assert arch["constants"] == {k: v for k, v in A.reference_doc().items() if k in ("chip", "envelope")}
    pins = arch["pinManifest"]
    assert pins["content"].encode() == (OUT / "fg.pins.json").read_bytes()
    assert pins["sha256"] == PINS_SHA256 and pins["bytes"] == 12487
    assert answer["cost"]["totalOKB"] == "0.04166"
    assert seconds < 110, f"{seconds:.1f} s"


def test_stock_proofs_buyer_groups_first_then_eq(stock):
    _, answer, _, _ = stock
    rows = answer["proofs"]
    assert not [r for r in rows if r["status"] == "failed"]
    by = {}
    for r in rows:
        by.setdefault(r["group"], []).append(r)
        assert set(r) >= {"id", "group", "title", "check", "engine", "status", "detail"}
    for g in ("P1", "P2", "P3", "P4", "P5", "P6", "PX"):
        assert by[g] and all(r["status"] == "proved" for r in by[g]), g
    eq = {r["id"]: r["status"] for r in by["EQ"]}
    assert eq["EQ.rtl_equals_bytes.yosys"] == "proved"
    assert eq["EQ.rtl_equals_bytes.z3"] in ("proved", "timeout")
    assert "P2.k2l_lifetime_cap.argument" in {r["id"] for r in by["P2"]}
    assert [r["status"] for r in by["P7"]] == ["skipped"]
    order = [r["group"] for r in rows]
    assert max(order.index(g) for g in ("P1", "P2", "P3", "P4")) < order.index("EQ") < order.index("P5")
    assert len({r["id"] for r in rows}) == len(rows)


@pytest.fixture(scope="module")
def custom_twice():
    return [run(request(params=CUSTOM), "--budget", "20", "--jobs", "4") for _ in range(2)]


def test_same_request_same_bytes(custom_twice, stock):
    (rc1, a1, e1, _), (rc2, a2, e2, _) = custom_twice
    assert rc1 == 0 and rc2 == 0, e1 + e2
    assert a1["netlistHex"] == a2["netlistHex"]
    assert json.dumps(a1["manifest"]) == json.dumps(a2["manifest"])
    assert a1["netlistHex"] != stock[1]["netlistHex"]
    m = a1["manifest"]
    assert m["architect"]["params"] == {"AL0": 40, "AL1": 24, "AL2": 12, "AL3": 4, "CEIL0": 432, "M1": 430, "M2": 460,
                                        "RC": 72, "RESMIN_Q": 399, "allowCumBps": 1600, "capT": 40, "ceilMax": 432,
                                        "fbAllow": 4}
    assert m["architect"]["constants"]["envelope"]["capT"] == 40
    assert "The allowance tier steps up at codes 430, 460 and 479" in m["architect"]["pinManifest"]["content"]


def test_custom_envelope_is_proven_clamp_free(custom_twice):
    _, answer, _, _ = custom_twice[0]
    for r in answer["proofs"]:
        if r["group"] in ("P1", "P2", "P3", "P4"):
            assert r["status"] == "proved", r
    assert any(r["status"] == "proved" for r in answer["proofs"] if r["group"] == "EQ")


def test_a_proof_without_a_verdict_in_the_budget_is_a_timeout_and_the_answer_is_ok(tmp_path):
    keep = tmp_path / "work"
    rc, answer, err, seconds = run(request(), "--budget", "6", "--keep", str(keep))
    assert rc == 0, err
    assert answer["ok"] is True
    st = statuses(answer)
    assert st.get("timeout", 0) > 0 and st.get("failed", 0) == 0, st
    assert seconds < 6 + 4, f"{seconds:.1f} s"
    for r in answer["proofs"]:
        if r["status"] == "timeout":
            assert r["detail"]
    time.sleep(1)
    assert not leftover(str(keep)), "every worker process and its Yosys are gone"


def test_sigterm_stops_every_worker(tmp_path):
    keep = tmp_path / "work"
    env = dict(os.environ, PYTHONPATH=str(TOOLS))
    p = subprocess.Popen([sys.executable, "-m", "tapc.architect", "--keep", str(keep)], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    p.stdin.write(json.dumps(request()).encode())
    p.stdin.close()
    t = time.monotonic()
    while not (keep / "eq-z3.job.json").exists() and time.monotonic() - t < 60:
        time.sleep(0.2)
    assert (keep / "eq-z3.job.json").exists()
    p.send_signal(signal.SIGTERM)
    assert p.wait(timeout=20) == 128 + signal.SIGTERM
    assert p.stdout.read() == b"", "no answer on stdout"
    time.sleep(1)
    assert not leftover(str(keep))


def test_workers_die_with_the_request_when_the_service_kills_its_process_group(tmp_path):
    """The service runs the command in its own process group and kills the group after TAPC_TIMEOUT_MS. The proof
    workers lead groups of their own (so that a timeout can stop a worker with its Yosys); they notice that their
    parent is gone and stop themselves."""
    keep = tmp_path / "work"
    env = dict(os.environ, PYTHONPATH=str(TOOLS))
    p = subprocess.Popen([sys.executable, "-m", "tapc.architect", "--keep", str(keep)], stdin=subprocess.PIPE,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env, start_new_session=True)
    p.stdin.write(json.dumps(request()).encode())
    p.stdin.close()
    t = time.monotonic()
    while not (keep / "eq-z3.job.json").exists() and time.monotonic() - t < 60:
        time.sleep(0.2)
    assert leftover(str(keep)), "workers are running"
    os.killpg(p.pid, signal.SIGKILL)
    p.wait(timeout=10)
    t = time.monotonic()
    while leftover(str(keep)) and time.monotonic() - t < 10:
        time.sleep(0.5)
    assert not leftover(str(keep))


def test_a_failed_proof_is_a_rejection_with_the_counterexample(tmp_path):
    """Validation keeps this from happening; here it is bypassed: the chip asks for AL0 = 48 at tier 0 and the
    envelope says capT = 40. P2 (K2, allowance cap) must fail, and the answer must be a rejection."""
    doc = A.reference_doc()
    doc["envelope"]["capT"] = 40
    work = tmp_path / "work"
    work.mkdir()
    with pytest.raises(A.Reject) as e:
        A.compile_flow_governor(doc, {"capT": 40}, A.Options(budget=60, jobs=4), str(work), time.monotonic() + 60)
    r = e.value
    assert r.code == "proof_failed" and r.stage == "prove"
    answer = r.answer()
    assert answer["ok"] is False and isinstance(answer["proofs"], list)
    failed = [p for p in answer["proofs"] if p["status"] == "failed"]
    assert failed and {p["id"] for p in failed} <= {"P2.p2_allow_cap.yosys", "P2.p2_k2_allowance_cap.z3"}, failed
    assert failed[0]["counterexample"] and failed[0]["detail"].startswith("counterexample:")
    assert r.diagnostics[0]["path"] == f"proofs.{failed[0]['id']}"
    assert any(p["status"] == "skipped" for p in answer["proofs"]), "the remaining jobs were stopped"
    time.sleep(1)
    assert not leftover(str(work))


def test_glutton_reproduces_the_committed_hostile_chip():
    rc, answer, err, seconds = run(request("glutton"))
    assert rc == 0, err
    assert bytes.fromhex(answer["netlistHex"][2:]) == (GLUTTON / "glutton.tap").read_bytes()
    m = dict(answer["manifest"])
    arch = m.pop("architect")
    committed = json.loads((GLUTTON / "glutton.manifest.json").read_text())
    assert {k: v for k, v in m.items() if k != "build"} == {k: v for k, v in committed.items() if k != "build"}
    assert arch["hostile"] is True and "NOT clamp-free" in arch["note"]
    assert [r["status"] for r in answer["proofs"]] == ["proved"] * 10
    assert {r["check"] for r in answer["proofs"]} == {"p_demands_everything", "p_group_256", "p_heartbeat",
                                                      "p_ignores_inputs", "rtl_equals_bytes"}
    assert answer["cost"]["transistors"] == 114 and answer["cost"]["totalOKB"] == "0.0049"
    assert seconds < 30


# ============================================================================================== slow: the service

def test_service_adapter_against_the_real_toolchain():
    """services/architect's adapter (src/toolchain.ts) and HTTP app, with TAPC_CMD = this command."""
    node = shutil.which("node")
    if node is None or not (SERVICE / "node_modules").is_dir():
        pytest.skip("node or services/architect/node_modules is missing")
    env = dict(os.environ, TAPC_E2E_CMD=f"{sys.executable} -m tapc.architect", TAPC_E2E_CWD=str(TOOLS))
    env.pop("PYTHONPATH", None)          # the command must find tapc from TAPC_CWD alone, as configured
    p = subprocess.run([node, "--test", "--test-reporter=tap", "test/toolchain-real.test.ts"], cwd=SERVICE, env=env, capture_output=True,
                       text=True, timeout=400)
    out = p.stdout + p.stderr
    assert p.returncode == 0, out[-6000:]
    assert "# pass 3" in out and "# skipped 0" in out, out[-3000:]
