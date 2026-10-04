"""Differential test: on-chain `step` / `eval` against tapc.sim, bit for bit.

    tapc difftest --rpc <url> --cpu <processor> --id <circuit> --n 10000 --seed 1

For every vector (state, inputs) the expected (newState, outputs) comes from tapc.sim (bit-sliced, all vectors
in one pass) and the observed pair comes from the processor contract through eth_call. Calls are grouped with
Multicall3 `aggregate3` so that one eth_call carries several `step` calls and stays under the 50M gas cap, and
eth_calls are grouped in JSON-RPC batches of at most 10 with at most 8 requests in flight.

Vector mix (deterministic for a given netlist, n, seed and mix):
  uniform   state and inputs uniformly random;
  walk      random walks from the all-zero state: each beat starts from the state the simulator computed for
            the previous beat (the chain is asked the same question, so every beat is checked on its own);
  boundary  field boundaries: every field (from a manifest, else 8-bit slices) at 0, 1, max, max-1, the top
            bit alone and just below it, plus all-zero, all-one, one-hot and one-cold vectors.

`step` is a pure function of (netlist, state, inputs), so the test needs no archive node and no pinned block;
the block number and the implementation code hash are recorded at the start and at the end instead.

Evidence is a JSONL file: a header line, one line per vector and a summary line. The exit status is non-zero on
any mismatch or on any vector that could not be checked. Works unchanged against an anvil fork URL.
"""
from __future__ import annotations

import json
import os
import random
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from typing import Optional, Sequence

from . import __version__
from . import chain
from .netlist import IllFormed, Netlist, check, keccak256
from .sim import int_to_bytes, step_many_int

EVIDENCE_FORMAT = "tapc-difftest/1"
DEFAULT_MIX = (4, 3, 3)                # uniform : walk : boundary


@dataclass
class Vector:
    kind: str
    state: int
    inputs: int


@dataclass
class DiffResult:
    n: int = 0
    matched: int = 0
    mismatched: int = 0
    errors: int = 0
    seconds: float = 0.0
    chain_seconds: float = 0.0
    per_call: int = 0
    evidence: str = ""
    header: dict = field(default_factory=dict)
    first_mismatches: list = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return self.n > 0 and self.matched == self.n and self.mismatched == 0 and self.errors == 0

    @property
    def vectors_per_minute(self) -> float:
        return 60.0 * self.n / self.chain_seconds if self.chain_seconds > 0 else 0.0


# ------------------------------------------------------------------------------------------------ vectors

def _fields(width: int, manifest_fields: Optional[list]) -> list:
    """[(lsb, width)] covering 0..width-1: manifest fields first, then 8-bit slices over whatever is left."""
    covered = [False] * width
    out = []
    for f in manifest_fields or []:
        lsb, w = int(f["lsb"]), int(f.get("width", 1))
        if 0 <= lsb and lsb + w <= width and w > 0:
            out.append((lsb, w))
            for k in range(lsb, lsb + w):
                covered[k] = True
    i = 0
    while i < width:
        if covered[i]:
            i += 1
            continue
        j = i
        while j < width and not covered[j] and j - i < 8:
            j += 1
        out.append((i, j - i))
        i = j
    return sorted(out)


def _edge_values(w: int) -> list:
    m = (1 << w) - 1
    vals = [0, 1, m, m - 1, 1 << (w - 1), (1 << (w - 1)) - 1]
    return sorted({v & m for v in vals})


def _boundary_value(rng: random.Random, width: int, fields: list, theme: int) -> int:
    if width == 0:
        return 0
    v = 0
    if theme == 0:                                     # every field at 0 or max
        for lsb, w in fields:
            if rng.random() < 0.5:
                v |= ((1 << w) - 1) << lsb
    elif theme == 1:                                   # every field on one of its edges
        for lsb, w in fields:
            v |= rng.choice(_edge_values(w)) << lsb
    else:                                              # one field on an edge, the rest random
        v = rng.getrandbits(width)
        lsb, w = fields[rng.randrange(len(fields))]
        v &= ~(((1 << w) - 1) << lsb)
        v |= rng.choice(_edge_values(w)) << lsb
    return v


def _fixed_patterns(width: int) -> list:
    """All-zero, all-one, alternating, one-hot and one-cold vectors."""
    if width == 0:
        return [0]
    m = (1 << width) - 1
    alt = int("01" * ((width + 1) // 2), 2) & m
    out = [0, m, alt, m ^ alt]
    out += [1 << i for i in range(width)]
    out += [m ^ (1 << i) for i in range(width)]
    return out


def make_vectors(nl: Netlist, n: int, seed: int = 1, mix: Sequence[int] = DEFAULT_MIX,
                 manifest: Optional[dict] = None, walk_len: int = 64) -> list:
    """Deterministic list of n Vector objects."""
    rng = random.Random(seed)
    S, NI = nl.n_state, nl.n_in
    mu, mw, mb = (list(mix) + [0, 0, 0])[:3]
    if S == 0:                                          # no state: walks make no sense
        mu, mw = mu + mw, 0
    total = mu + mw + mb
    if total <= 0:
        raise ValueError("empty mix")
    n_walk = n * mw // total
    n_bound = n * mb // total
    n_uni = n - n_walk - n_bound
    mf = (manifest or {}).get("fields") or {}
    s_fields, x_fields = _fields(S, mf.get("state")), _fields(NI, mf.get("inputs"))
    out = [Vector("uniform", rng.getrandbits(S) if S else 0, rng.getrandbits(NI) if NI else 0)
           for _ in range(n_uni)]

    # boundary: fixed patterns first (at most half of the budget), then themed field edges
    bound = []
    fx_s, fx_x = _fixed_patterns(S), _fixed_patterns(NI)
    ones_s, ones_x = (1 << S) - 1, (1 << NI) - 1
    fixed = [(a, b) for a in fx_s[:4] for b in fx_x[:4]]
    fixed += [(0, b) for b in fx_x[4:]] + [(a, 0) for a in fx_s[4:]]
    fixed += [(ones_s, b) for b in fx_x[4:]] + [(a, ones_x) for a in fx_s[4:]]
    seen = set()
    for a, b in fixed:
        if len(bound) >= n_bound // 2:
            break
        if (a, b) not in seen:
            seen.add((a, b))
            bound.append(Vector("boundary", a, b))
    while len(bound) < n_bound:
        mode = rng.randrange(3)
        if mode == 0:
            a, b = _boundary_value(rng, S, s_fields, rng.randrange(3)), _boundary_value(rng, NI, x_fields, rng.randrange(3))
        elif mode == 1:
            a, b = _boundary_value(rng, S, s_fields, rng.randrange(3)), (rng.getrandbits(NI) if NI else 0)
        else:
            a, b = (rng.getrandbits(S) if S else 0), _boundary_value(rng, NI, x_fields, rng.randrange(3))
        bound.append(Vector("boundary", a, b))
    out += bound

    # walks from the zero state, all walks advanced together (bit-sliced)
    if n_walk:
        n_walks = max(1, -(-n_walk // walk_len))
        states = [0] * n_walks
        made = 0
        while made < n_walk:
            ins = []
            for _ in range(n_walks):
                r = rng.random()
                if r < 0.70 or NI == 0:
                    ins.append(rng.getrandbits(NI) if NI else 0)
                elif r < 0.85:
                    ins.append(_boundary_value(rng, NI, x_fields, rng.randrange(3)))
                else:                                   # sparse inputs keep a walk near its previous state
                    ins.append((rng.getrandbits(NI) & rng.getrandbits(NI) & rng.getrandbits(NI)))
            take = min(n_walks, n_walk - made)
            for k in range(take):
                out.append(Vector("walk", states[k], ins[k]))
            made += take
            states, _ = step_many_int(nl, states, ins)
    return out


def expected(nl: Netlist, vectors: Sequence[Vector]) -> list:
    """[(new_state_bytes, output_bytes)] from the simulator, one pass."""
    ns, out = step_many_int(nl, [v.state for v in vectors], [v.inputs for v in vectors])
    return [(int_to_bytes(a, nl.n_state), int_to_bytes(b, nl.n_out)) for a, b in zip(ns, out)]


# ------------------------------------------------------------------------------------------------ chain side

def _calldata(nl: Netlist, cid: int, v: Vector, use_eval: bool) -> bytes:
    if use_eval:
        return chain.enc_eval(cid, int_to_bytes(v.inputs, nl.n_in))
    return chain.enc_step(cid, int_to_bytes(v.state, nl.n_state), int_to_bytes(v.inputs, nl.n_in))


def _decode(ret: bytes, use_eval: bool) -> tuple:
    if use_eval:
        return b"", chain.dec_bytes_return(ret)
    return chain.dec_step_return(ret)


def _throttled(err) -> bool:
    """True when a JSON-RPC error says "slow down" rather than "this call cannot run"."""
    code = getattr(err, "code", None)
    text = str(err).lower()
    return code in (429, -32005, -32016, -32097) or any(k in text for k in ("rate limit", "too many request",
                                                                           "limit exceeded", "throttl"))


class _Runner:
    def __init__(self, rpc: chain.Rpc, cpu: str, cid: int, nl: Netlist, vectors, use_eval: bool, multicall: str):
        self.rpc, self.cpu, self.cid, self.nl = rpc, cpu, cid, nl
        self.vectors, self.use_eval, self.multicall = vectors, use_eval, multicall
        self.got: list = [None] * len(vectors)          # (new_state, outputs) or ("error", message)
        self.splits = 0
        self.throttled = 0

    def _agg_request(self, idxs) -> tuple:
        calls = [(self.cpu, True, _calldata(self.nl, self.cid, self.vectors[i], self.use_eval)) for i in idxs]
        return ("eth_call", [self.rpc.call_obj(self.multicall, chain.enc_aggregate3(calls)), "latest"])

    def _direct(self, i: int) -> None:
        try:
            ret = self.rpc.eth_call(self.cpu, _calldata(self.nl, self.cid, self.vectors[i], self.use_eval))
            self.got[i] = _decode(ret, self.use_eval)
        except chain.RpcError as e:
            self.got[i] = ("error", str(e))

    def _apply(self, idxs, result_hex) -> list:
        """Store the sub-results of one aggregate3 call; return the indices that failed inside it."""
        failed = []
        try:
            items = chain.dec_aggregate3_return(bytes.fromhex(result_hex[2:]))
            if len(items) != len(idxs):
                return list(idxs)
            for i, (ok, ret) in zip(idxs, items):
                if not ok:
                    failed.append(i)
                    continue
                self.got[i] = _decode(ret, self.use_eval)
        except (chain.RpcError, ValueError):
            return list(idxs)
        return failed

    def _retry(self, idxs) -> None:
        """A chunk failed as a whole (gas cap, timeout): halve it until it goes through."""
        if len(idxs) == 1:
            self._direct(idxs[0])
            return
        self.splits += 1
        mid = len(idxs) // 2
        for part in (idxs[:mid], idxs[mid:]):
            try:
                res = self.rpc.batch([self._agg_request(part)])[0]
            except chain.RpcError as e:
                res = ("err", e)
            if res[0] == "ok":
                for i in self._apply(part, res[1]):
                    self._direct(i)
            else:
                self._retry(part)

    def run_batch(self, chunks) -> None:
        """One HTTP request: up to max_batch aggregate3 eth_calls. A node that says it is rate-limiting gets the
        same request again after a pause; any other failure of a chunk is treated as "too big" and halved."""
        todo = list(chunks)
        for attempt in range(5):
            try:
                results = self.rpc.batch([self._agg_request(c) for c in todo])
            except chain.RpcError as e:
                results = [("err", e)] * len(todo)
            again = []
            for c, res in zip(todo, results):
                if res[0] == "ok":
                    for i in self._apply(c, res[1]):
                        self._direct(i)
                elif _throttled(res[1]) and attempt < 4:
                    again.append(c)
                else:
                    self._retry(list(c))
            if not again:
                return
            self.throttled += len(again)
            time.sleep(1.5 * (attempt + 1))
            todo = again


def calibrate_per_call(rpc: chain.Rpc, cpu: str, cid: int, nl: Netlist, use_eval: bool, gas_cap: int,
                       multicall: str = chain.MULTICALL3, verbose=None, max_per_call: int = 64) -> dict:
    """How many `step` calls fit in one Multicall3 eth_call under the gas cap.

    Estimates one step with eth_estimateGas, then probes the node: the answer is the largest k for which one
    aggregate3 eth_call with k steps (worst-case all-ones vectors) succeeds. Returns {"gasPerStep", "perCall",
    "probes": [(k, ok)]}."""
    v = Vector("probe", (1 << nl.n_state) - 1, (1 << nl.n_in) - 1)
    out = {"gasPerStep": None, "perCall": 1, "probes": []}
    try:
        out["gasPerStep"] = rpc.estimate_gas(cpu, _calldata(nl, cid, v, use_eval))
    except chain.RpcError:
        pass
    guess = max(1, int(gas_cap * 0.92 // out["gasPerStep"])) if out["gasPerStep"] else 4

    def works(k: int) -> bool:
        calls = [(cpu, False, _calldata(nl, cid, v, use_eval))] * k
        try:
            ret = rpc.eth_call(multicall, chain.enc_aggregate3(calls))
            ok = len(chain.dec_aggregate3_return(ret)) == k
        except chain.RpcError:
            ok = False
        out["probes"].append((k, ok))
        if verbose:
            verbose(f"  probe: {k} steps in one eth_call -> {'ok' if ok else 'fails'}")
        return ok

    lo, hi = 0, None                       # lo works (0 trivially), hi fails
    k = min(guess, max_per_call)
    while hi is None and k <= max_per_call:
        if works(k):
            lo = k
            if k == max_per_call:
                break
            k = min(max_per_call, k + max(1, k // 4))
        else:
            hi = k
    while hi is not None and hi - lo > 1:
        mid = (lo + hi) // 2
        if works(mid):
            lo = mid
        else:
            hi = mid
    out["perCall"] = max(1, lo)
    out["firstFailing"] = hi
    return out


# ------------------------------------------------------------------------------------------------ the test

def run(rpc_urls, cpu: str, cid: int, n: int = 10000, seed: int = 1, out_path: Optional[str] = None,
        per_call: Optional[int] = None, mix: Sequence[int] = DEFAULT_MIX, manifest: Optional[dict] = None,
        local_tap: Optional[bytes] = None, force_step: bool = False, gas_cap: int = chain.GAS_CAP,
        concurrency: int = chain.MAX_CONCURRENCY, rpc_batch: int = chain.MAX_RPC_BATCH,
        multicall: str = chain.MULTICALL3, walk_len: int = 64, extra_vectors: Optional[list] = None,
        progress=None, timeout: float = 90.0) -> DiffResult:
    """Run the differential test. See the module docstring."""
    t_all = time.perf_counter()
    say = progress or (lambda msg: None)
    rpc = chain.Rpc(rpc_urls, max_concurrency=max(1, min(concurrency, chain.MAX_CONCURRENCY)),
                    max_batch=max(1, min(rpc_batch, chain.MAX_RPC_BATCH)), timeout=timeout, gas_cap=gas_cap)
    rpc_batch = rpc.max_batch
    chain_id = rpc.chain_id()
    block0 = rpc.block_number()
    info = chain.circuit_info(rpc, cpu, cid)
    data = chain.fetch_netlist(rpc, cpu, cid)
    try:
        nl = check(data, info["nIn"], info["nOut"])
    except IllFormed as e:
        raise chain.RpcError(f"on-chain netlist of {cpu} #{cid} is rejected by tapc.netlist.check: {e}") from e
    if nl.n_state != info["nState"] or nl.gate_count != info["gateCount"]:
        raise chain.RpcError(f"circuitInfo {info} disagrees with the decoded netlist "
                             f"(nState {nl.n_state}, gates {nl.gate_count})")
    impl0 = chain.implementation_of(rpc, cpu)
    try:
        client = str(rpc.call("web3_clientVersion", []))
    except chain.RpcError:
        client = None
    simulated = bool(client) and any(k in client.lower() for k in ("anvil", "hardhat", "ganache"))
    use_eval = nl.n_state == 0 and not force_step
    kk = "0x" + keccak256(data).hex()
    say(f"chain {chain_id} block {block0}{' (LOCAL FORK)' if simulated else ''}  {cpu} #{cid}: nIn {nl.n_in} "
        f"nOut {nl.n_out} nState {nl.n_state} gates {nl.gate_count} bytes {len(data)} keccak {kk}")
    local_match = None
    if local_tap is not None:
        local_match = bytes(local_tap) == data
        say(f"local netlist {'matches' if local_match else 'DIFFERS FROM'} the on-chain bytes")

    vectors = make_vectors(nl, n, seed, mix, manifest, walk_len)
    for ev in extra_vectors or []:
        vectors.append(Vector(ev.get("kind", "extra"), int.from_bytes(bytes.fromhex(ev["state"]), "little"),
                              int.from_bytes(bytes.fromhex(ev["inputs"]), "little")))
    t0 = time.perf_counter()
    exp = expected(nl, vectors)
    sim_seconds = time.perf_counter() - t0

    cal = None
    if per_call is None:
        cal = calibrate_per_call(rpc, cpu, cid, nl, use_eval, gas_cap, multicall, say)
        per_call = cal["perCall"]
        say(f"gas per {'eval' if use_eval else 'step'} {cal['gasPerStep']}; {per_call} calls per Multicall3 eth_call "
            f"under the {gas_cap:,} gas cap")

    header = {
        "type": "header", "format": EVIDENCE_FORMAT, "tool": f"tapc {__version__}",
        "rpc": rpc.host, "clientVersion": client,
        "environment": "LOCAL FORK (simulation, not a real chain)" if simulated else "live node",
        "chainId": chain_id, "blockStart": block0,
        "cpu": cpu, "id": cid, "function": "eval" if use_eval else "step",
        "nIn": nl.n_in, "nOut": nl.n_out, "nState": nl.n_state, "gateCount": nl.gate_count,
        "nNand": nl.n_nand, "nLatch": nl.n_latch, "nRef": nl.n_ref,
        "netlistBytes": len(data), "netlistKeccak256": kk, "localNetlistMatches": local_match,
        "beacon": impl0["beacon"], "implementation": impl0["implementation"], "implementationCodeHash": impl0["codeHash"],
        "seed": seed, "n": len(vectors), "mix": {"uniform": mix[0], "walk": mix[1], "boundary": mix[2]},
        "kinds": {k: sum(1 for v in vectors if v.kind == k) for k in sorted({v.kind for v in vectors})},
        "multicall3": multicall, "callsPerEthCall": per_call, "ethCallsPerHttpRequest": rpc_batch,
        "concurrency": rpc.max_concurrency, "gasCap": gas_cap,
        "gasPerCallEstimate": cal["gasPerStep"] if cal else None,
        "packing": "bit i of a vector is bit (i mod 8) of byte floor(i / 8); LSB first",
        "startedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }

    idx = list(range(len(vectors)))
    chunks = [idx[i:i + per_call] for i in range(0, len(idx), per_call)]
    batches = [chunks[i:i + rpc_batch] for i in range(0, len(chunks), rpc_batch)]
    runner = _Runner(rpc, cpu, cid, nl, vectors, use_eval, multicall)
    done = [0]
    t_chain = time.perf_counter()
    last = [t_chain]

    def work(b):
        runner.run_batch(b)
        done[0] += sum(len(c) for c in b)
        now = time.perf_counter()
        if now - last[0] > 5:
            last[0] = now
            say(f"  {done[0]}/{len(vectors)} vectors  ({60 * done[0] / (now - t_chain):.0f} per minute)")

    with ThreadPoolExecutor(max_workers=max(1, rpc.max_concurrency)) as ex:
        list(ex.map(work, batches))
    chain_seconds = time.perf_counter() - t_chain

    res = DiffResult(n=len(vectors), per_call=per_call, header=header, chain_seconds=chain_seconds)
    lines = []
    for i, (v, e, g) in enumerate(zip(vectors, exp, runner.got)):
        row = {"type": "vector", "i": i, "kind": v.kind,
               "state": int_to_bytes(v.state, nl.n_state).hex(), "inputs": int_to_bytes(v.inputs, nl.n_in).hex()}
        if g is None or (len(g) == 2 and g[0] == "error"):
            res.errors += 1
            row.update({"ok": False, "error": g[1] if g else "not run",
                        "simNewState": e[0].hex(), "simOutputs": e[1].hex()})
        else:
            got_ns, got_out = g
            ok = got_out == e[1] and (use_eval or got_ns == e[0])
            row.update({"chainNewState": got_ns.hex(), "chainOutputs": got_out.hex(), "ok": ok})
            if ok:
                res.matched += 1
            else:
                res.mismatched += 1
                row.update({"simNewState": e[0].hex(), "simOutputs": e[1].hex()})
                if len(res.first_mismatches) < 5:
                    res.first_mismatches.append(row)
        lines.append(row)

    block1 = None
    impl1 = {"codeHash": None, "implementation": None}
    try:
        block1 = rpc.block_number()
        impl1 = chain.implementation_of(rpc, cpu)
    except chain.RpcError:
        pass
    res.seconds = time.perf_counter() - t_all
    summary = {
        "type": "summary", "n": res.n, "matched": res.matched, "mismatched": res.mismatched, "errors": res.errors,
        "ok": res.ok, "seconds": round(res.seconds, 2), "chainSeconds": round(chain_seconds, 2),
        "simSeconds": round(sim_seconds, 3), "vectorsPerMinute": round(res.vectors_per_minute, 1),
        "httpRequests": rpc.http_requests, "rpcCalls": rpc.rpc_calls, "httpRetries": rpc.retried,
        "chunkSplits": runner.splits, "throttledChunks": runner.throttled, "blockEnd": block1,
        "implementationEnd": impl1["implementation"], "implementationCodeHashEnd": impl1["codeHash"],
        "implementationUnchanged": impl1["codeHash"] == impl0["codeHash"],
        "finishedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    if out_path:
        os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(json.dumps(header) + "\n")
            for row in lines:
                f.write(json.dumps(row) + "\n")
            f.write(json.dumps(summary) + "\n")
        res.evidence = out_path
    res.header = {**header, **{k: v for k, v in summary.items() if k != "type"}}
    return res


def replay_evidence(path: str, netlist: Optional[bytes] = None) -> dict:
    """Re-check an evidence file offline: recompute every vector with tapc.sim from the netlist (which must hash
    to the keccak in the header) and compare with the chain's recorded answers."""
    with open(path, "r", encoding="utf-8") as f:
        rows = [json.loads(line) for line in f if line.strip()]
    header = rows[0]
    if netlist is None:
        raise ValueError("replay needs the netlist bytes (fetch them with `tapc info --rpc ... --save`)")
    if "0x" + keccak256(netlist).hex() != header["netlistKeccak256"]:
        raise ValueError("netlist does not hash to the keccak recorded in the evidence header")
    nl = check(netlist, header["nIn"], header["nOut"])
    vec = [r for r in rows if r.get("type") == "vector"]
    st = [int.from_bytes(bytes.fromhex(r["state"]), "little") for r in vec]
    xi = [int.from_bytes(bytes.fromhex(r["inputs"]), "little") for r in vec]
    ns, out = step_many_int(nl, st, xi)
    bad = 0
    for r, a, b in zip(vec, ns, out):
        if "chainOutputs" not in r:
            bad += 1
            continue
        same = r["chainOutputs"] == int_to_bytes(b, nl.n_out).hex() and (
            header["function"] == "eval" or r["chainNewState"] == int_to_bytes(a, nl.n_state).hex())
        if not same:
            bad += 1
    return {"vectors": len(vec), "bad": bad, "ok": bad == 0 and len(vec) > 0}
