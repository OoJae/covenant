"""Tests of the chip kit. Offline by default:

    chips/.venv-fg/bin/python -m pytest -q chips/kit/test_kit.py
    NETWORK=1 chips/.venv-fg/bin/python -m pytest -q chips/kit/test_kit.py    # also eth_call the live factory

(`make -C chips/rtl venv` installs pytest into chips/.venv-fg; any Python with the same requirements works.)

The NETWORK tests only make eth_call requests to X Layer.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import kit  # noqa: E402
from tapc import netlist as N  # noqa: E402

STARTER_TAP = os.path.join(kit.STARTER, "out", "starter.tap")
GLUTTON_TAP = os.path.join(kit.CHIPS, "cells", "glutton", "glutton.tap")
FG_TAP = os.path.join(kit.CHIPS, "out", "fg.tap")
A = "0x" + "11" * 20
NETWORK = os.environ.get("NETWORK") == "1"


def ref_env(**kw) -> dict:
    e = dict(kit.REFERENCE_ENVELOPE, launcher=A, allowancePayee=A)
    e.update(kw)
    return {k: e[k] for k, _ in kit.ENV_FIELDS}


# One envelope per factory rule that breaks exactly that rule (BadEnvelope code), and its boundary that passes.
BREAKS = [
    (1, {"launcher": kit.ZERO}, None),
    (2, {"epochLen": 299}, {"epochLen": 300}),
    (2, {"epochLen": 86_401, "fallbackEpochs": 2, "floorRel": 128}, {"epochLen": 86_400, "fallbackEpochs": 2, "floorRel": 128}),
    (3, {"allowancePayee": kit.ZERO}, None),
    (4, {"capT": 129}, {"capT": 128}),
    (5, {"capV": 256}, {"capV": 255}),
    (6, {"allowCumBps": 5001}, {"allowCumBps": 5000}),
    (7, {"ceilMax": 1024}, {"ceilMax": 1023}),
    (8, {"relMax": 0, "floorRel": 0}, None),
    (8, {"relMax": 257}, {"relMax": 256}),
    (9, {"floorRel": 0}, None),
    (9, {"relMax": 4, "floorRel": 5}, {"relMax": 5, "floorRel": 5}),
    (10, {"floorMin": 0}, {"floorMin": 1}),
    (10, {"floorMin": 426}, {"floorMin": 425}),
    (11, {"fallbackEpochs": 1}, {"fallbackEpochs": 2}),
    (12, {"capT": 8, "fbAllow": 9}, {"capT": 9, "fbAllow": 9}),
    (13, {"buyEnabled": False}, None),
    (14, {"epochLen": 3600, "fallbackEpochs": 721, "floorRel": 1}, {"epochLen": 3600, "fallbackEpochs": 720, "floorRel": 1}),
    (15, {"epochLen": 14_562, "floorRel": 1}, {"epochLen": 14_561, "floorRel": 1}),
]


def first_failure(env: dict):
    bad = [c for c, ok, _ in kit.envelope_checks(env) if not ok]
    return bad[0] if bad else None


def test_reference_envelope_passes():
    assert first_failure(ref_env()) is None


@pytest.mark.parametrize("code,breaks,boundary", BREAKS)
def test_each_factory_rule(code, breaks, boundary):
    assert first_failure(ref_env(**breaks)) == code
    if boundary is not None:
        assert first_failure(ref_env(**boundary)) is None


def test_envelope_abi_matches_cast():
    if not shutil.which("cast"):
        pytest.skip("cast is not installed")
    env = ref_env(capT=32, allowCumBps=1250, relMax=16)
    sig = f"create({kit.ENV_TUPLE},uint256,bytes32)"
    salt = "0x" + "ab" * 32
    want = subprocess.run(["cast", "calldata", sig, kit.env_tuple_text(env), "7", salt], capture_output=True,
                          text=True, check=True).stdout.strip()
    got = "0x" + kit.call_data(sig, kit.enc_envelope(env), kit.w(7), bytes.fromhex(salt[2:])).hex()
    assert got == want
    assert kit.dec_envelope(kit.enc_envelope(env)) == {k: (v.lower() if isinstance(v, str) else v) for k, v in env.items()}


def test_clamps_starter_none_under_its_envelope():
    cfg = json.load(open(os.path.join(kit.STARTER, "chip.json")))
    env = ref_env(**cfg["envelope"])
    r = kit.clamp_analysis(N.read_netlist_file(STARTER_TAP), env)
    assert {k: v["verdict"] for k, v in r.items() if k != "_range"} == dict.fromkeys(("K1T", "K2", "K3", "K5", "K2C", "K2L"), "never")
    assert r["_range"] == {"T_ALLOW max (well-formed groups, on the curve)": 32, "REL min": 4, "REL max": 4}


def test_clamps_starter_k2_when_the_envelope_is_too_tight():
    r = kit.clamp_analysis(N.read_netlist_file(STARTER_TAP), ref_env(capT=16, fbAllow=8, allowCumBps=625))
    assert r["K2"]["verdict"] == "can" and r["K2L"]["verdict"] == "never"
    # the example must really ask for more than capT: replay it on the bytes
    ex = r["K2"]["example"]
    ns, out = kit_sim(STARTER_TAP, ex["state"], ex["inputs"])
    assert kit.km.unpack_output(int.from_bytes(out, "little"))["T_ALLOW"] > 16


def test_clamps_glutton_reference():
    r = kit.clamp_analysis(N.read_netlist_file(GLUTTON_TAP), ref_env())
    v = {k: x["verdict"] for k, x in r.items() if k != "_range"}
    assert v == {"K1T": "never", "K2": "can", "K3": "can", "K5": "never", "K2C": "can", "K2L": "never"}


def test_clamps_flow_governor_reference():
    """The Flow Governor is proven clamp-free under the reference envelope by its own proofs (P1..P7); the kit's
    independent analysis must agree."""
    r = kit.clamp_analysis(N.read_netlist_file(FG_TAP), ref_env())
    assert all(x["verdict"] == "never" for k, x in r.items() if k != "_range")


def kit_sim(tap: str, state_hex: str, inputs_hex: str):
    from tapc import sim
    data = N.read_netlist_file(tap)
    nl = N.check(data, 96, 112)
    return sim.step(nl, None, None, bytes.fromhex(state_hex[2:]), bytes.fromhex(inputs_hex[2:]))


def test_pin_manifest_reproduces_committed_starter():
    chip = kit.Chip(kit.STARTER)
    data = N.read_netlist_file(STARTER_TAP)
    nl = N.check(data, 96, 112)
    built = kit.pin_manifest(chip, data, nl.n_state)
    with open(os.path.join(kit.STARTER, "out", "starter.tape-pins.json"), "rb") as f:
        assert f.read() == built
    b = json.load(open(os.path.join(kit.STARTER, "out", "starter.build.json")))
    assert b["manifest"]["sha256"] == "0x" + __import__("hashlib").sha256(built).hexdigest()
    assert b["netlist"]["keccak256"] == kit.keccak_hex(data)


def test_plan_script_renders_and_parses(tmp_path):
    chip = kit.Chip(kit.STARTER)
    b = chip.built()
    env = chip.envelope(A, None)
    text = kit.render_plan(chip, b, kit.load_deployment(), env, "0x" + "00" * 32, 300, 300, "x.sh")
    assert "@@" not in text
    p = tmp_path / "plan.sh"
    p.write_text(text)
    assert subprocess.run(["bash", "-n", str(p)]).returncode == 0
    assert kit.env_tuple_text(env) in text and b["manifest"]["sha256"] in text


@pytest.mark.parametrize("item", ["capV=-1", "allowCumBps=-5", "ceilMax=1.5", "capT=abc", "buyEnabled=yes",
                                  "epochLen=0x100000000"])
def test_envelope_refuses_values_cast_cannot_encode(item):
    """A negative or out-of-range value passes a `<=` rule of the factory but fails in `cast` only when the plan
    script reaches step 2, after the tape-out was paid. The kit refuses it up front."""
    with pytest.raises(kit.KitError):
        kit.Chip(kit.STARTER).envelope(A, None, [item])


def test_plan_script_guards():
    """The plan refuses a state file from another chip or envelope, a transaction not signed by the launcher, and
    an envelope the factory refuses, before it signs anything it should not."""
    chip = kit.Chip(kit.STARTER)
    b = chip.built()
    addrs = kit.load_deployment()
    text = kit.render_plan(chip, b, addrs, chip.envelope(A, None), "0x" + "00" * 32, 300, 300, "x.sh")
    assert text.count("set STATE to a new file") == 2
    assert "not by the launcher" in text
    assert f'"$ENV" {addrs["flagshipChipId"]} $SALT' in text
    assert text.index("KernelFactory.predict refuses") < text.index("tapeoutChip(bytes,bytes32)")
    assert f"{addrs['splitter']} 'pull()'" in text


def test_new_renames_everything(tmp_path):
    dest = tmp_path / "mine"
    assert kit.main(["new", "my_chip", "--dir", str(dest)]) == 0
    files = sorted(os.listdir(dest))
    assert files == ["chip.json", "my_chip_core.v", "my_chip_props.v"]
    text = "".join((dest / f).read_text() for f in files)
    assert "starter" not in text.lower()
    cfg = json.loads((dest / "chip.json").read_text())
    assert cfg["name"] == "my_chip" and cfg["top"] == "my_chip_core" and cfg["props"]["tapModule"] == "my_chip_tap"


@pytest.mark.skipif(not NETWORK, reason="NETWORK=1 to eth_call the live KernelFactory")
@pytest.mark.parametrize("code,breaks,boundary", BREAKS)
def test_factory_agrees_on_chain(code, breaks, boundary):
    rpc = kit.rpc_for(None)
    addrs = kit.load_deployment()
    salt = "0x" + "00" * 32
    r = kit.onchain_envelope_check(rpc, addrs, ref_env(**breaks), addrs["flagshipChipId"], salt)
    assert not r["ok"] and r["revert"] == f"BadEnvelope({code})", r
    if boundary is not None:
        assert kit.onchain_envelope_check(rpc, addrs, ref_env(**boundary), addrs["flagshipChipId"], salt)["ok"]
