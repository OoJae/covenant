"""tapc.difftest and tapc.chain against a local fake JSON-RPC node (no network).

The fake node decodes the calldata with its own ABI code, evaluates `step` with TAP-20's reference
implementation (not tapc.sim) and enforces the limits measured on the public X Layer RPC: a JSON-RPC batch of
more than 10 is rejected, and an eth_call that would run more `step` calls than fit under the gas cap fails as
a whole. So this checks the encoding, the batching, the splitting and the comparison end to end."""
import json
import random
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from tapc import chain, difftest, sim
from tapc import netlist as N

CPU = "0x" + "c1" * 20
BEACON = "0x" + "be" * 20
IMPL = "0x" + "17" * 20
CID = 3


def w(v):
    return v.to_bytes(32, "big")


def pad(b):
    return b + bytes(-len(b) % 32)


def rd(b, off):
    return int.from_bytes(b[off:off + 32], "big")


def rd_bytes(b, off):
    n = rd(b, off)
    return b[off + 32:off + 32 + n]


def enc_bytes_tuple(items):
    """ABI for a tuple of dynamic `bytes` values."""
    head, tail = b"", b""
    off = 32 * len(items)
    for it in items:
        head += w(off)
        t = w(len(it)) + pad(it)
        tail += t
        off += len(t)
    return head + tail


class FakeNode:
    def __init__(self, R, nl, steps_per_call=7, max_batch=10, corrupt=None, revert_inputs=None, flaky=0,
                 throttle=0):
        self.R, self.nl = R, nl
        self.circ = R.load(nl.data, nl.n_in, nl.n_out)
        self.steps_per_call = steps_per_call
        self.max_batch = max_batch
        self.corrupt = corrupt or set()            # {(state_hex, inputs_hex)}: flip output bit 0
        self.revert_inputs = revert_inputs or set()
        self.flaky = flaky                         # fail this many HTTP requests with 503 first
        self.throttle = throttle                   # answer this many aggregate3 calls with a rate-limit error
        self.lock = threading.Lock()
        self.in_flight = self.max_in_flight = 0
        self.max_batch_seen = self.max_steps_seen = 0
        self.steps = self.http = 0
        self.block = 1000
        self.code = bytes(range(200))

    # -- contract behaviour
    def step(self, data):
        body = data[4:]
        cid = rd(body, 0)
        if cid != CID:
            return False, bytes.fromhex("08c379a0") + enc_bytes_tuple([b"no circuit"])
        state, inputs = rd_bytes(body, rd(body, 32)), rd_bytes(body, rd(body, 64))
        if inputs.hex() in self.revert_inputs:
            return False, b""
        ns, out = self.R.beat(self.circ, self.R.unpack(state, self.nl.n_state), self.R.unpack(inputs, self.nl.n_in))
        ns_b, out_b = self.R.pack(ns), bytearray(self.R.pack(out))
        if (state.hex(), inputs.hex()) in self.corrupt:
            out_b[0] ^= 1
        with self.lock:
            self.steps += 1
        return True, enc_bytes_tuple([ns_b, bytes(out_b)])

    def call_cpu(self, data):
        sel = data[:4]
        if sel == chain.SEL_CIRCUIT_INFO:
            if rd(data, 4) != CID:
                return False, b""
            return True, w(self.nl.n_in) + w(self.nl.n_out) + w(self.nl.n_state) + w(self.nl.gate_count)
        if sel == chain.SEL_NETLIST:
            return True, enc_bytes_tuple([self.nl.data])
        if sel == chain.SEL_STEP:
            return self.step(data)
        if sel == chain.SEL_EVAL:
            body = data[4:]
            if self.nl.n_state:
                return False, bytes.fromhex("08c379a0") + enc_bytes_tuple([b"has latch: use step"])
            inputs = rd_bytes(body, rd(body, 32))
            _, out = self.R.beat(self.circ, [], self.R.unpack(inputs, self.nl.n_in))
            with self.lock:
                self.steps += 1
            return True, enc_bytes_tuple([self.R.pack(out)])
        return False, b""

    def aggregate3(self, data):
        body = data[4:]
        base = rd(body, 0)
        n = rd(body, base)
        with self.lock:
            self.max_steps_seen = max(self.max_steps_seen, n)
        if n > self.steps_per_call:
            raise RuntimeError("out of gas")
        start = base + 32
        results = []
        for i in range(n):
            t = start + rd(body, start + 32 * i)
            target = "0x" + body[t + 12:t + 32].hex()
            allow = rd(body, t + 32)
            call = rd_bytes(body, t + rd(body, t + 64))
            ok, ret = self.call_cpu(call) if target == CPU else (False, b"")
            if not ok and not allow:
                raise RuntimeError("execution reverted: Multicall3: call failed")
            results.append((ok, ret))
        heads, tails, off = b"", b"", 32 * n
        for ok, ret in results:
            t = w(1 if ok else 0) + w(0x40) + w(len(ret)) + pad(ret)
            heads += w(off)
            tails += t
            off += len(t)
        return w(0x20) + w(n) + heads + tails

    # -- JSON-RPC
    def handle(self, req):
        m, p = req["method"], req.get("params", [])
        try:
            if m == "eth_chainId":
                res = hex(196)
            elif m == "eth_blockNumber":
                with self.lock:
                    self.block += 1
                    res = hex(self.block)
            elif m == "eth_getStorageAt":
                res = "0x" + bytes(12).hex() + BEACON[2:] if p[1] == chain.BEACON_SLOT else "0x" + "00" * 32
            elif m == "eth_getCode":
                res = "0x" + self.code.hex()
            elif m == "web3_clientVersion":
                res = "fake-node/1.0"
            elif m == "eth_estimateGas":
                res = hex(7_000_000)
            elif m == "eth_call":
                to, data = p[0]["to"].lower(), bytes.fromhex(p[0]["data"][2:])
                if int(p[0].get("gas", "0x0"), 16) > 50_000_000:
                    raise RuntimeError("gas above the cap")
                if to == chain.MULTICALL3.lower():
                    with self.lock:
                        limited = self.throttle > 0
                        if limited:
                            self.throttle -= 1
                    if limited:
                        return {"jsonrpc": "2.0", "id": req["id"],
                                "error": {"code": -32005, "message": "rate limit exceeded"}}
                    res = "0x" + self.aggregate3(data).hex()
                elif to == BEACON:
                    res = "0x" + bytes(12).hex() + IMPL[2:]
                elif to == CPU:
                    ok, ret = self.call_cpu(data)
                    if not ok:
                        raise RuntimeError("execution reverted")
                    res = "0x" + ret.hex()
                else:
                    res = "0x"
            else:
                return {"jsonrpc": "2.0", "id": req["id"], "error": {"code": -32601, "message": "method not found"}}
            return {"jsonrpc": "2.0", "id": req["id"], "result": res}
        except RuntimeError as e:
            return {"jsonrpc": "2.0", "id": req["id"], "error": {"code": -32000, "message": str(e)}}

    def serve(self):
        node = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                with node.lock:
                    node.http += 1
                    node.in_flight += 1
                    node.max_in_flight = max(node.max_in_flight, node.in_flight)
                    fail = node.flaky > 0
                    if fail:
                        node.flaky -= 1
                try:
                    if fail:
                        self.send_response(503)
                        self.end_headers()
                        return
                    if isinstance(body, list):
                        node.max_batch_seen = max(node.max_batch_seen, len(body))
                        if len(body) > node.max_batch:
                            out = {"jsonrpc": "2.0", "id": None,
                                   "error": {"code": -32014, "message": "too many RPC calls in batch request"}}
                        else:
                            out = [node.handle(r) for r in body]
                    else:
                        out = node.handle(body)
                    raw = json.dumps(out).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(raw)))
                    self.end_headers()
                    self.wfile.write(raw)
                finally:
                    with node.lock:
                        node.in_flight -= 1

        srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        return srv, f"http://127.0.0.1:{srv.server_address[1]}"


def seq_netlist(seed=4, n_in=11, n_elems=160):
    """A random sequential netlist with latches first (like a packed chip)."""
    rng = random.Random(seed)
    n_latch = 13
    base = 2 + n_in
    recs = [None] * n_latch
    nxt = base + n_latch
    for _ in range(n_elems):
        recs.append(N.nand(rng.randrange(2, nxt), rng.randrange(2, nxt)))
        nxt += 1
    for i in range(n_latch):
        recs[i] = N.latch(rng.randrange(base + n_latch, nxt))
    return N.check(N.encode(recs), n_in, 9)


@pytest.fixture()
def node(reference):
    made = []

    def make(nl, **kw):
        fake = FakeNode(reference, nl, **kw)
        srv, url = fake.serve()
        made.append(srv)
        return fake, url
    yield make
    for srv in made:
        srv.shutdown()
        srv.server_close()


# ---------------------------------------------------------------------------------------------- ABI

def test_abi_round_trip():
    state, inputs = bytes(range(37)), b"\x01\x02\x03"
    data = chain.enc_step(9, state, inputs)
    assert data[:4] == chain.SEL_STEP and (len(data) - 4) % 32 == 0
    body = data[4:]
    assert rd(body, 0) == 9 and rd_bytes(body, rd(body, 32)) == state and rd_bytes(body, rd(body, 64)) == inputs
    ev = chain.enc_eval(4, inputs)[4:]
    assert rd(ev, 0) == 4 and rd_bytes(ev, rd(ev, 32)) == inputs
    ret = enc_bytes_tuple([b"\xaa" * 33, b"\x07"])
    assert chain.dec_step_return(ret) == (b"\xaa" * 33, b"\x07")
    assert chain.dec_bytes_return(enc_bytes_tuple([b"hello"])) == b"hello"
    assert chain.dec_step_return(enc_bytes_tuple([b"", b""])) == (b"", b"")
    with pytest.raises(chain.RpcError):
        chain.dec_step_return(ret[:-40])
    assert chain.revert_reason(bytes.fromhex("08c379a0") + enc_bytes_tuple([b"no circuit"])) == "no circuit"
    assert chain.rpc_host("https://user:secret@rpc.example.org:8545/v2/API-KEY?x=1") == "https://rpc.example.org:8545"


def test_aggregate3_encoding_is_understood_by_an_independent_decoder(reference, node):
    nl = seq_netlist()
    fake, _ = node(nl)
    calls = [(CPU, True, chain.enc_step(CID, bytes([i, 0]), bytes([i, 1]))) for i in range(5)]
    ret = fake.aggregate3(chain.enc_aggregate3(calls))
    items = chain.dec_aggregate3_return(ret)
    assert len(items) == 5 and all(ok for ok, _ in items)
    for i, (_, r) in enumerate(items):
        assert chain.dec_step_return(r) == sim.step(nl, None, None, bytes([i, 0]), bytes([i, 1]))


# ---------------------------------------------------------------------------------------------- vectors

def test_vectors_are_deterministic_and_mixed():
    nl = seq_netlist()
    a = difftest.make_vectors(nl, 1000, seed=1)
    b = difftest.make_vectors(nl, 1000, seed=1)
    c = difftest.make_vectors(nl, 1000, seed=2)
    assert a == b and a != c and len(a) == 1000
    kinds = {k: sum(1 for v in a if v.kind == k) for k in ("uniform", "walk", "boundary")}
    assert kinds == {"uniform": 400, "walk": 300, "boundary": 300}
    assert all(0 <= v.state < 1 << nl.n_state and 0 <= v.inputs < 1 << nl.n_in for v in a)
    bound = [(v.state, v.inputs) for v in a if v.kind == "boundary"]
    ones_s, ones_x = (1 << nl.n_state) - 1, (1 << nl.n_in) - 1
    for corner in ((0, 0), (ones_s, ones_x), (0, ones_x), (ones_s, 0)):
        assert corner in bound
    assert all((0, 1 << i) in bound for i in range(nl.n_in))               # one-hot inputs from the zero state
    # walks really are walks: every walk starts at the zero state and each beat continues the previous one
    walks = [v for v in a if v.kind == "walk"]
    n_walks = -(-300 // 64)
    assert all(v.state == 0 for v in walks[:n_walks])
    for k in range(n_walks, len(walks)):
        prev = walks[k - n_walks]
        (ns,), _ = sim.step_many_int(nl, [prev.state], [prev.inputs])
        assert walks[k].state == ns
    assert len({v.state for v in walks}) > 100                              # and they leave the zero state


def test_vectors_use_manifest_fields():
    nl = seq_netlist()
    manifest = {"fields": {"inputs": [{"name": "amt", "lsb": 0, "width": 10}],
                           "state": [{"name": "avg", "lsb": 0, "width": 12}]}}
    assert difftest._fields(11, manifest["fields"]["inputs"]) == [(0, 10), (10, 1)]
    assert difftest._fields(20, None) == [(0, 8), (8, 8), (16, 4)]
    v = difftest.make_vectors(nl, 2000, seed=3, manifest=manifest)
    amt = {x.inputs & 1023 for x in v if x.kind == "boundary"}
    assert {0, 1, 1022, 1023, 511, 512} <= amt
    avg = {x.state & 4095 for x in v if x.kind == "boundary"}
    assert {0, 1, 4094, 4095, 2047, 2048} <= avg


def test_combinational_circuits_get_no_walks(vectors):
    v = next(x for x in vectors["valid"] if x["name"] == "popcount8_3151")
    nl = N.check(N.from_hex(v["netlist"]), 8, 4)
    vec = difftest.make_vectors(nl, 500, seed=1)
    assert {x.kind for x in vec} == {"uniform", "boundary"} and all(x.state == 0 for x in vec)
    exp = difftest.expected(nl, vec)
    assert all(int.from_bytes(o, "little") == bin(x.inputs).count("1") for x, (_, o) in zip(vec, exp))


# ---------------------------------------------------------------------------------------------- end to end

def test_difftest_matches_and_respects_the_rpc_limits(node, tmp_path):
    nl = seq_netlist()
    fake, url = node(nl, steps_per_call=7)
    out = tmp_path / "ev.jsonl"
    r = difftest.run(url, CPU, CID, n=1500, seed=1, out_path=str(out), local_tap=nl.data)
    assert r.ok and (r.n, r.matched, r.mismatched, r.errors) == (1500, 1500, 0, 0)
    assert r.per_call == 7                                     # found by probing: 7 pass, 8 fail
    assert fake.max_batch_seen <= 10 and fake.max_in_flight <= 8
    assert fake.max_steps_seen == 8                            # only the calibration probe ever went over
    assert fake.steps >= 1500
    rows = [json.loads(line) for line in out.read_text().splitlines()]
    head, body, tail = rows[0], rows[1:-1], rows[-1]
    assert head["type"] == "header" and head["format"] == "tapc-difftest/1" and head["chainId"] == 196
    assert head["netlistKeccak256"] == "0x" + N.keccak256(nl.data).hex() and head["localNetlistMatches"] is True
    assert head["function"] == "step" and head["callsPerEthCall"] == 7 and head["rpc"] == url
    assert head["clientVersion"] == "fake-node/1.0" and head["environment"] == "live node"
    assert head["implementation"] == IMPL and head["implementationCodeHash"] == "0x" + N.keccak256(fake.code).hex()
    assert len(body) == 1500 and [b["i"] for b in body] == list(range(1500)) and all(b["ok"] for b in body)
    assert tail["type"] == "summary" and tail["ok"] and tail["matched"] == 1500 and tail["implementationUnchanged"]
    # the evidence replays offline from the netlist alone
    assert difftest.replay_evidence(str(out), nl.data) == {"vectors": 1500, "bad": 0, "ok": True}
    with pytest.raises(ValueError, match="keccak"):
        difftest.replay_evidence(str(out), nl.data + b"\x00\x00\x00\x02\x00\x00\x02")


def test_difftest_reports_a_single_wrong_bit(node, tmp_path):
    nl = seq_netlist()
    vec = difftest.make_vectors(nl, 300, seed=5)
    target = vec[123]
    key = (sim.int_to_bytes(target.state, nl.n_state).hex(), sim.int_to_bytes(target.inputs, nl.n_in).hex())
    fake, url = node(nl, corrupt={key})
    r = difftest.run(url, CPU, CID, n=300, seed=5, out_path=str(tmp_path / "ev.jsonl"), per_call=5)
    assert not r.ok and (r.matched, r.mismatched, r.errors) == (299, 1, 0)
    row = r.first_mismatches[0]
    assert row["i"] == 123 and (row["state"], row["inputs"]) == key
    assert bytes.fromhex(row["chainOutputs"])[0] ^ bytes.fromhex(row["simOutputs"])[0] == 1
    assert row["chainOutputs"][2:] == row["simOutputs"][2:] and row["chainNewState"] == row["simNewState"]
    assert difftest.replay_evidence(str(tmp_path / "ev.jsonl"), nl.data)["bad"] == 1


def test_difftest_splits_when_the_gas_cap_is_lower_than_assumed(node, tmp_path):
    nl = seq_netlist()
    fake, url = node(nl, steps_per_call=3)
    r = difftest.run(url, CPU, CID, n=200, seed=1, out_path=str(tmp_path / "ev.jsonl"), per_call=10)
    assert r.ok and r.matched == 200                           # 10 per call fails; halves of 5 fail; 2 and 3 pass
    assert r.header["chunkSplits"] > 0


def test_difftest_survives_reverts_and_flaky_http(node, tmp_path):
    nl = seq_netlist()
    vec = difftest.make_vectors(nl, 120, seed=9)
    bad_inputs = sim.int_to_bytes(vec[17].inputs, nl.n_in).hex()
    n_bad = sum(1 for v in vec if sim.int_to_bytes(v.inputs, nl.n_in).hex() == bad_inputs)
    fake, url = node(nl, revert_inputs={bad_inputs}, flaky=3)
    r = difftest.run(url, CPU, CID, n=120, seed=9, out_path=str(tmp_path / "ev.jsonl"), per_call=4)
    assert not r.ok and r.errors == n_bad and r.mismatched == 0 and r.matched == 120 - n_bad
    assert r.header["httpRetries"] >= 3


def test_difftest_waits_when_the_node_rate_limits(node, tmp_path):
    nl = seq_netlist()
    fake, url = node(nl, throttle=3)
    r = difftest.run(url, CPU, CID, n=100, seed=1, out_path=str(tmp_path / "ev.jsonl"), per_call=5)
    assert r.ok and r.matched == 100
    assert r.header["throttledChunks"] == 3 and r.header["chunkSplits"] == 0     # waited, did not split


def test_difftest_uses_eval_for_a_circuit_without_state(node, vectors, tmp_path):
    v = next(x for x in vectors["valid"] if x["name"] == "popcount8_3151")
    nl = N.check(N.from_hex(v["netlist"]), 8, 4)
    fake, url = node(nl)
    r = difftest.run(url, CPU, CID, n=256, seed=1, out_path=str(tmp_path / "ev.jsonl"))
    assert r.ok and r.header["function"] == "eval" and r.matched == 256
    r = difftest.run(url, CPU, CID, n=64, seed=1, out_path=str(tmp_path / "ev2.jsonl"), force_step=True)
    assert r.ok and r.header["function"] == "step"


def test_difftest_refuses_a_wrong_circuit_id_and_a_differing_local_netlist(node, tmp_path):
    nl = seq_netlist()
    fake, url = node(nl)
    with pytest.raises(chain.RpcError):
        difftest.run(url, CPU, CID + 1, n=10, out_path=str(tmp_path / "x.jsonl"))
    other = seq_netlist(seed=5)
    r = difftest.run(url, CPU, CID, n=20, out_path=str(tmp_path / "y.jsonl"), local_tap=other.data, per_call=5)
    assert r.header["localNetlistMatches"] is False            # the CLI turns this into a non-zero exit


def test_fork_tapeout_refuses_anything_but_a_local_anvil(node):
    """The rehearsal command sends (fork-only) transactions, so its interlocks are tested: a remote URL is
    refused before any request is made, and a local node that is not anvil is refused too."""
    from tapc import rehearse
    nl = seq_netlist()
    for url in ("https://rpc.xlayer.tech", "https://xlayerrpc.okx.com", "http://10.0.0.5:8545", "http://example.org"):
        with pytest.raises(rehearse.RehearsalError, match="not a local node"):
            rehearse.fork_tapeout(url, nl.data, nl.n_in, nl.n_out)
    fake, url = node(nl)
    before = fake.http
    with pytest.raises(rehearse.RehearsalError, match="not anvil"):
        rehearse.fork_tapeout(url, nl.data, nl.n_in, nl.n_out)
    assert fake.http == before + 1                      # one anvil_nodeInfo probe, nothing else
    with pytest.raises(N.IllFormed):                    # bytes our own checker rejects are never sent anywhere
        rehearse.fork_tapeout(url, b"\x03", 1, 1)
    assert fake.http == before + 1


def test_cli_exit_status(node, tmp_path):
    import subprocess
    from conftest import TOOLS
    nl = seq_netlist()
    vec = difftest.make_vectors(nl, 60, seed=1)
    key = (sim.int_to_bytes(vec[7].state, nl.n_state).hex(), sim.int_to_bytes(vec[7].inputs, nl.n_in).hex())
    good, url_good = node(nl)
    bad, url_bad = node(nl, corrupt={key})
    tapc = str(TOOLS / "bin" / "tapc")
    base = ["difftest", "--cpu", CPU, "--id", str(CID), "--n", "60", "--seed", "1"]
    p = subprocess.run([tapc, *base, "--rpc", url_good, "--out", str(tmp_path / "g.jsonl")], capture_output=True, text=True)
    assert p.returncode == 0 and "60/60 vectors identical" in p.stdout, p.stdout + p.stderr
    p = subprocess.run([tapc, *base, "--rpc", url_bad, "--out", str(tmp_path / "b.jsonl")], capture_output=True, text=True)
    assert p.returncode == 1 and "59/60 vectors identical, 1 mismatched" in p.stdout and "MISMATCH" in p.stdout
    tap = tmp_path / "other.tap"
    tap.write_bytes(seq_netlist(seed=6).data)
    p = subprocess.run([tapc, *base, "--rpc", url_good, "--tap", str(tap), "--out", str(tmp_path / "t.jsonl")],
                       capture_output=True, text=True)
    assert p.returncode == 1 and "LOCAL NETLIST DIFFERS" in p.stdout, p.stdout + p.stderr
