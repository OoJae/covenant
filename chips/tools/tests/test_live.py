"""LIVE check against X Layer mainnet (chain 196): tapc.sim equals on-chain `step`, bit for bit.

Read-only: eth_call and a few other read methods, no transaction, no key. Skip offline with

    ../.venv/bin/python -m pytest -m "not live"

The two circuits are the largest sequential ones found on X Layer when the project started:
  0xAa13ae45b0B2D52f210Ad7Ef12997113a0ebAF21 #3   4,863 gates, 243 state bits, 33,312 bytes
  0x933FC3AA0c387CB8B6B1D22a2Ec3E2B5eeCfDb5a #1   3,035 gates, 288 state bits (Trivium)
"""
import json
import random

import pytest

from tapc import chain, difftest, sim
from tapc import netlist as N

pytestmark = pytest.mark.live

CIRCUITS = [
    ("0xAa13ae45b0B2D52f210Ad7Ef12997113a0ebAF21", 3, {"nState": 243, "gateCount": 4863}),
    ("0x933FC3AA0c387CB8B6B1D22a2Ec3E2B5eeCfDb5a", 1, {"nState": 288, "gateCount": 3035}),
]
N_VECTORS = 36


@pytest.fixture(scope="module")
def rpc():
    r = chain.Rpc(list(chain.XLAYER_RPCS), timeout=60, retries=3)
    try:
        cid = r.chain_id()
    except chain.RpcError as e:
        pytest.skip(f"X Layer RPC unreachable: {e}")
    assert cid == chain.XLAYER_CHAIN_ID
    return r


@pytest.mark.parametrize("cpu,cid,want", CIRCUITS, ids=["cpu-Aa13-circuit-3", "trivium-circuit-1"])
def test_sim_matches_on_chain_step(rpc, cpu, cid, want, tmp_path):
    out = tmp_path / "evidence.jsonl"
    r = difftest.run(list(chain.XLAYER_RPCS), cpu, cid, n=N_VECTORS, seed=1, out_path=str(out))
    h = r.header
    print(f"\n{cpu} #{cid}: {r.matched}/{r.n} identical; nIn {h['nIn']} nOut {h['nOut']} nState {h['nState']} "
          f"gates {h['gateCount']} bytes {h['netlistBytes']}; {h['callsPerEthCall']} steps per eth_call "
          f"(estimate {h['gasPerCallEstimate']} gas per step); block {h['blockStart']}; "
          f"implementation {h['implementation']} code hash {h['implementationCodeHash']}")
    assert r.ok, r.first_mismatches
    assert (r.n, r.matched, r.mismatched, r.errors) == (N_VECTORS, N_VECTORS, 0, 0)
    assert h["chainId"] == 196 and h["function"] == "step"
    assert h["nState"] == want["nState"] and h["gateCount"] == want["gateCount"]
    assert h["nRef"] == 0 and h["netlistBytes"] == 7 * h["nNand"] + 4 * h["nLatch"]
    assert set(h["kinds"]) == {"uniform", "walk", "boundary"}
    rows = [json.loads(line) for line in out.read_text().splitlines()]
    assert len(rows) == N_VECTORS + 2 and all(x["ok"] for x in rows[1:-1])
    # outputs and new state come back as exactly ceil(n/8) bytes
    assert all(len(x["chainNewState"]) == 2 * ((h["nState"] + 7) // 8) for x in rows[1:-1])
    assert all(len(x["chainOutputs"]) == 2 * ((h["nOut"] + 7) // 8) for x in rows[1:-1])


def test_on_chain_netlist_and_lenient_reads(rpc):
    """The stored bytes decode, re-encode identically and are latches-first; and the contract reads state and
    inputs leniently exactly as tapc.sim does (padding bits and an extra byte ignored, short strings read as 0)."""
    cpu, cid, want = CIRCUITS[1]
    info = chain.circuit_info(rpc, cpu, cid)
    data = chain.fetch_netlist(rpc, cpu, cid)
    nl = N.check(data, info["nIn"], info["nOut"])
    assert N.encode(nl.elements) == data
    assert (nl.n_state, nl.gate_count) == (info["nState"], info["gateCount"]) == (want["nState"], want["gateCount"])
    assert nl.latches_first and nl.is_flat
    rng = random.Random(11)
    state = bytes(rng.getrandbits(8) for _ in range((nl.n_state + 7) // 8))
    inputs = bytearray(rng.getrandbits(8) for _ in range((nl.n_in + 7) // 8))
    inputs[-1] |= (0xFF << (nl.n_in % 8)) & 0xFF if nl.n_in % 8 else 0          # garbage in the padding bits
    variants = [
        (state, bytes(inputs)),
        (state + b"\xa5\x5a", bytes(inputs) + b"\xff"),                         # extra bytes
        (state[:5], bytes(inputs[:3])),                                         # short: the rest reads as 0
        (b"", b""),                                                             # empty: all zero
    ]
    calls = [(cpu, False, chain.enc_step(cid, s, x)) for s, x in variants]
    ret = chain.dec_aggregate3_return(rpc.eth_call(chain.MULTICALL3, chain.enc_aggregate3(calls)))
    assert len(ret) == len(variants)
    for (s, x), (ok, r) in zip(variants, ret):
        assert ok
        assert chain.dec_step_return(r) == sim.step(nl, None, None, s, x)
    # one call without Multicall3 in the path
    direct = chain.dec_step_return(rpc.eth_call(cpu, chain.enc_step(cid, state, bytes(inputs))))
    assert direct == sim.step(nl, None, None, state, bytes(inputs))
    # eval refuses a circuit with state, as TAP-20 section 6 says
    with pytest.raises(chain.RpcError):
        rpc.eth_call(cpu, chain.enc_eval(cid, bytes(inputs)))
