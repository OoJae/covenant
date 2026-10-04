"""Read-only access to TapeOut processor contracts over JSON-RPC (urllib only, no web3).

Nothing here can send a transaction: the only methods used are eth_call, eth_estimateGas, eth_chainId,
eth_blockNumber, eth_getStorageAt and eth_getCode. No keys are read or needed.

Public X Layer RPC limits this module respects (measured, see chips/tools/NOTES.md):
  * a JSON-RPC batch holds at most 10 requests;
  * eth_call is capped at 50,000,000 gas;
  * at most 8 requests in flight.
"""
from __future__ import annotations

import json
import threading
import time
import urllib.error
import urllib.request
from typing import Optional, Sequence
from urllib.parse import urlsplit

from .netlist import keccak256

XLAYER_RPCS = ("https://rpc.xlayer.tech", "https://xlayerrpc.okx.com")
XLAYER_CHAIN_ID = 196
MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11"
GAS_CAP = 50_000_000
MAX_RPC_BATCH = 10
MAX_CONCURRENCY = 8

# keccak256(signature)[:4]; checked against tapc.netlist.keccak256 in the tests
SEL_CIRCUIT_INFO = bytes.fromhex("084d60f1")      # circuitInfo(uint256)
SEL_NETLIST = bytes.fromhex("3fc4be56")           # netlist(uint256)
SEL_EVAL = bytes.fromhex("934d06ea")              # eval(uint256,bytes)
SEL_STEP = bytes.fromhex("e8281a1a")              # step(uint256,bytes,bytes)
SEL_NEXT_ID = bytes.fromhex("61b8ce8c")           # nextId()
SEL_AGGREGATE3 = bytes.fromhex("82ad56cb")        # aggregate3((address,bool,bytes)[])
SEL_IMPLEMENTATION = bytes.fromhex("5c60da1b")    # implementation()
# ERC-1967 beacon slot: bytes32(uint256(keccak256("eip1967.proxy.beacon")) - 1)
BEACON_SLOT = "0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50"


class RpcError(RuntimeError):
    def __init__(self, message: str, code: Optional[int] = None, data=None):
        super().__init__(message)
        self.code = code
        self.data = data


def selector(signature: str) -> bytes:
    return keccak256(signature.encode("ascii"))[:4]


def rpc_host(url: str) -> str:
    """scheme://host[:port] only: never log a path or query that might carry an API key."""
    p = urlsplit(url)
    host = p.hostname or ""
    if p.port:
        host += f":{p.port}"
    return f"{p.scheme}://{host}"


# ------------------------------------------------------------------------------------------------ ABI

def _word(v: int) -> bytes:
    return v.to_bytes(32, "big")


def _pad(b: bytes) -> bytes:
    return b + bytes(-len(b) % 32)


def _addr(a: str) -> bytes:
    h = a[2:] if a.startswith(("0x", "0X")) else a
    if len(h) != 40:
        raise ValueError(f"bad address {a!r}")
    return bytes.fromhex(h)


def enc_uint_call(sel: bytes, v: int) -> bytes:
    return sel + _word(v)


def enc_eval(cid: int, inputs: bytes) -> bytes:
    return SEL_EVAL + _word(cid) + _word(0x40) + _word(len(inputs)) + _pad(inputs)


def enc_step(cid: int, state: bytes, inputs: bytes) -> bytes:
    off2 = 0x60 + 32 + len(_pad(state))
    return (SEL_STEP + _word(cid) + _word(0x60) + _word(off2)
            + _word(len(state)) + _pad(state) + _word(len(inputs)) + _pad(inputs))


def enc_aggregate3(calls: Sequence) -> bytes:
    """calls: [(target address, allow_failure, calldata)]."""
    heads, tails = [], []
    off = 32 * len(calls)
    for target, allow, data in calls:
        t = bytes(12) + _addr(target) + _word(1 if allow else 0) + _word(0x60) + _word(len(data)) + _pad(data)
        heads.append(_word(off))
        tails.append(t)
        off += len(t)
    return SEL_AGGREGATE3 + _word(0x20) + _word(len(calls)) + b"".join(heads) + b"".join(tails)


def _rd(data: bytes, off: int) -> int:
    if off + 32 > len(data):
        raise RpcError("ABI: read past the end of the return data")
    return int.from_bytes(data[off:off + 32], "big")


def dec_bytes(data: bytes, off: int) -> bytes:
    n = _rd(data, off)
    if off + 32 + n > len(data):
        raise RpcError("ABI: bytes value runs past the end of the return data")
    return data[off + 32:off + 32 + n]


def dec_bytes_return(data: bytes) -> bytes:
    """Return data of a function returning a single `bytes`."""
    return dec_bytes(data, _rd(data, 0))


def dec_step_return(data: bytes) -> tuple:
    """(newState, outputs)."""
    return dec_bytes(data, _rd(data, 0)), dec_bytes(data, _rd(data, 32))


def dec_aggregate3_return(data: bytes) -> list:
    """[(success, returnData)]."""
    base = _rd(data, 0)
    n = _rd(data, base)
    start = base + 32
    out = []
    for i in range(n):
        t = start + _rd(data, start + 32 * i)
        ok = _rd(data, t) != 0
        out.append((ok, dec_bytes(data, t + _rd(data, t + 32))))
    return out


def revert_reason(data: bytes) -> str:
    """Error(string) payload, if that is what the bytes are."""
    if len(data) >= 68 and data[:4] == bytes.fromhex("08c379a0"):
        try:
            return dec_bytes(data[4:], _rd(data[4:], 0)).decode("utf-8", "replace")
        except RpcError:
            pass
    return "0x" + data.hex()[:80]


# ------------------------------------------------------------------------------------------------ JSON-RPC client

class Rpc:
    """A small JSON-RPC client: batching (at most `max_batch` per HTTP request), a concurrency cap, retries with
    backoff, and failover across URLs."""

    def __init__(self, urls=XLAYER_RPCS, max_concurrency: int = MAX_CONCURRENCY, max_batch: int = MAX_RPC_BATCH,
                 timeout: float = 60.0, retries: int = 5, gas_cap: int = GAS_CAP):
        self.urls = [urls] if isinstance(urls, str) else list(urls)
        if not self.urls:
            raise ValueError("no RPC url")
        self.max_batch = max_batch
        self.timeout = timeout
        self.retries = retries
        self.gas_cap = gas_cap
        self.max_concurrency = max_concurrency
        self._sem = threading.Semaphore(max_concurrency)
        self._lock = threading.Lock()
        self._id = 0
        self._active = 0
        self.http_requests = 0
        self.rpc_calls = 0
        self.retried = 0

    @property
    def host(self) -> str:
        return rpc_host(self.urls[self._active])

    def _next_id(self) -> int:
        with self._lock:
            self._id += 1
            return self._id

    def _post(self, payload) -> object:
        body = json.dumps(payload).encode("utf-8")
        last: Optional[Exception] = None
        for attempt in range(self.retries + 1):
            url = self.urls[self._active]
            if attempt and attempt % 2 == 0 and len(self.urls) > 1:      # two failures in a row: fail over
                with self._lock:
                    self._active = (self._active + 1) % len(self.urls)
                url = self.urls[self._active]
            req = urllib.request.Request(url, data=body, method="POST", headers={
                "Content-Type": "application/json", "Accept": "application/json",
                "User-Agent": "tapc-difftest/0.1 (read-only eth_call)"})
            try:
                with self._sem:
                    with self._lock:
                        self.http_requests += 1
                    with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                        raw = resp.read()
                doc = json.loads(raw)
                if isinstance(payload, list) and not isinstance(doc, list):
                    # a batch-level error (for example "too many RPC calls in batch request")
                    err = doc.get("error", {}) if isinstance(doc, dict) else {}
                    raise RpcError(f"batch rejected: {err.get('message', doc)}", err.get("code"))
                return doc
            except urllib.error.HTTPError as e:
                last = RpcError(f"HTTP {e.code} from {rpc_host(url)}", e.code)
                if e.code not in (408, 425, 429, 500, 502, 503, 504):
                    raise last from e
            except (urllib.error.URLError, TimeoutError, ConnectionError, json.JSONDecodeError, OSError) as e:
                last = RpcError(f"{type(e).__name__} talking to {rpc_host(url)}: {e}")
            with self._lock:
                self.retried += 1
            time.sleep(min(8.0, 0.4 * (2 ** attempt)))
        raise last if last else RpcError("request failed")

    def call(self, method: str, params: list):
        with self._lock:
            self.rpc_calls += 1
        doc = self._post({"jsonrpc": "2.0", "id": self._next_id(), "method": method, "params": params})
        if "error" in doc:
            e = doc["error"]
            raise RpcError(f"{method}: {e.get('message')}", e.get("code"), e.get("data"))
        return doc.get("result")

    def batch(self, requests: Sequence) -> list:
        """requests: [(method, params)], at most max_batch. Returns a list of ("ok", result) / ("err", RpcError)
        in request order."""
        if len(requests) > self.max_batch:
            raise ValueError(f"batch of {len(requests)} exceeds the limit of {self.max_batch}")
        if not requests:
            return []
        ids = [self._next_id() for _ in requests]
        with self._lock:
            self.rpc_calls += len(requests)
        doc = self._post([{"jsonrpc": "2.0", "id": i, "method": m, "params": p} for i, (m, p) in zip(ids, requests)])
        by_id = {d.get("id"): d for d in doc if isinstance(d, dict)}
        out = []
        for i in ids:
            d = by_id.get(i)
            if d is None:
                out.append(("err", RpcError("no response for a batched request")))
            elif "error" in d:
                e = d["error"]
                out.append(("err", RpcError(str(e.get("message")), e.get("code"), e.get("data"))))
            else:
                out.append(("ok", d.get("result")))
        return out

    # -- typed helpers
    def call_obj(self, to: str, data: bytes, gas: Optional[int] = None) -> dict:
        obj = {"to": to, "data": "0x" + data.hex()}
        g = self.gas_cap if gas is None else gas
        if g:
            obj["gas"] = hex(g)
        return obj

    def eth_call(self, to: str, data: bytes, block: str = "latest", gas: Optional[int] = None) -> bytes:
        return bytes.fromhex(self.call("eth_call", [self.call_obj(to, data, gas), block])[2:])

    def chain_id(self) -> int:
        return int(self.call("eth_chainId", []), 16)

    def block_number(self) -> int:
        return int(self.call("eth_blockNumber", []), 16)

    def estimate_gas(self, to: str, data: bytes) -> int:
        return int(self.call("eth_estimateGas", [{"to": to, "data": "0x" + data.hex()}]), 16)


# ------------------------------------------------------------------------------------------------ TapeOut reads

def circuit_info(rpc: Rpc, cpu: str, cid: int, block: str = "latest") -> dict:
    r = rpc.eth_call(cpu, enc_uint_call(SEL_CIRCUIT_INFO, cid), block, gas=5_000_000)
    if len(r) < 128:
        raise RpcError(f"circuitInfo({cid}) returned {len(r)} bytes")
    return {"nIn": _rd(r, 0), "nOut": _rd(r, 32), "nState": _rd(r, 64), "gateCount": _rd(r, 96)}


def fetch_netlist(rpc: Rpc, cpu: str, cid: int, block: str = "latest") -> bytes:
    return dec_bytes_return(rpc.eth_call(cpu, enc_uint_call(SEL_NETLIST, cid), block))


def implementation_of(rpc: Rpc, cpu: str, block: str = "latest") -> dict:
    """The circuit implementation behind a processor's beacon and the keccak of its runtime code (TAP-20
    section 7, requirement 3). Best effort: returns {} fields as None when a read fails."""
    out = {"beacon": None, "implementation": None, "codeHash": None, "codeBytes": None}
    try:
        slot = rpc.call("eth_getStorageAt", [cpu, BEACON_SLOT, block])
        beacon = "0x" + slot[-40:]
        if int(beacon, 16) == 0:
            return out
        out["beacon"] = beacon
        impl = rpc.eth_call(beacon, SEL_IMPLEMENTATION, block, gas=1_000_000)
        out["implementation"] = "0x" + impl[-20:].hex()
        code = bytes.fromhex(rpc.call("eth_getCode", [out["implementation"], block])[2:])
        out["codeBytes"] = len(code)
        out["codeHash"] = "0x" + keccak256(code).hex()
    except (RpcError, ValueError, TypeError):
        pass
    return out
