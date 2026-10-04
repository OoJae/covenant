"""Tape-out rehearsal on a LOCAL anvil fork. Never on a real chain.

    anvil --fork-url https://rpc.xlayer.tech --port 28545          (in another terminal)
    tapc fork-tapeout --rpc http://127.0.0.1:28545 chips/probe/probe.tap

On the fork it creates a throwaway processor through the real TapeOut factory, mints exactly the transistors the
netlist burns, calls the real `tapeout(bytes,uint32,uint32)` and reads the circuit back. The point is to learn,
before anyone signs anything, that the deployed contract accepts these exact bytes, what the gas is, and (with
`tapc difftest --rpc <fork url>`) that the deployed evaluator computes what tapc.sim computes.

Three interlocks keep this away from mainnet:
  1. the RPC host must be 127.0.0.1, localhost or ::1;
  2. the node must answer `anvil_nodeInfo` (only anvil does);
  3. transactions are sent unsigned with eth_sendTransaction from an address that anvil impersonates
     (anvil_impersonateAccount, funded with anvil_setBalance). A real node has neither method and holds no
     unlocked account, so it could not accept them. tapc never reads or handles a private key.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional
from urllib.parse import urlsplit

from . import chain
from .netlist import check

XLAYER_FACTORY = "0x1f09DAeFA827f02CBb40967cc91b259763760761"


class RehearsalError(RuntimeError):
    pass


@dataclass
class Rehearsal:
    rpc: str
    chain_id: int
    fork_block: int
    account: str
    factory: str
    cpu: str = ""
    transistors: str = ""
    circuit_id: int = 0
    deploy_fee: int = 0
    protocol_fee: int = 0
    tapeout_fee: int = 0
    mint_price: int = 0
    gas: dict = field(default_factory=dict)
    value: dict = field(default_factory=dict)
    netlist_matches: bool = False
    circuit_info: dict = field(default_factory=dict)

    def as_dict(self) -> dict:
        return dict(self.__dict__)


def _w(v: int) -> bytes:
    return v.to_bytes(32, "big")


def _pad(b: bytes) -> bytes:
    return b + bytes(-len(b) % 32)


def _enc_create_cpu(name: str, symbol: str, story: str, supply: int, price: int) -> bytes:
    parts = [s.encode("utf-8") for s in (name, symbol, story)]
    head, tail, off = b"", b"", 5 * 32
    for p in parts:
        head += _w(off)
        t = _w(len(p)) + _pad(p)
        tail += t
        off += len(t)
    return chain.selector("createCPU(string,string,string,uint256,uint256)") + head + _w(supply) + _w(price) + tail


def _enc_tapeout(netlist: bytes, n_in: int, n_out: int) -> bytes:
    return (chain.selector("tapeout(bytes,uint32,uint32)") + _w(0x60) + _w(n_in) + _w(n_out)
            + _w(len(netlist)) + _pad(netlist))


def require_local_anvil(rpc: chain.Rpc, url: str) -> dict:
    host = (urlsplit(url).hostname or "").lower()
    if host not in ("127.0.0.1", "localhost", "::1"):
        raise RehearsalError(f"refusing: {chain.rpc_host(url)} is not a local node. fork-tapeout only talks to an "
                             f"anvil fork on this machine")
    try:
        info = rpc.call("anvil_nodeInfo", [])
    except chain.RpcError as e:
        raise RehearsalError(f"refusing: the node at {chain.rpc_host(url)} is not anvil ({e})") from e
    if not isinstance(info, dict):
        raise RehearsalError("refusing: unexpected anvil_nodeInfo answer")
    return info


def _send(rpc: chain.Rpc, frm: str, to: str, data: bytes, value: int = 0) -> dict:
    tx = {"from": frm, "to": to, "data": "0x" + data.hex(), "value": hex(value)}
    h = rpc.call("eth_sendTransaction", [tx])
    receipt = rpc.call("eth_getTransactionReceipt", [h])
    if receipt is None:
        rpc.call("evm_mine", [])
        receipt = rpc.call("eth_getTransactionReceipt", [h])
    if receipt is None or int(receipt.get("status", "0x0"), 16) != 1:
        raise RehearsalError(f"transaction to {to} failed on the fork: {receipt}")
    return receipt


def _uint(rpc: chain.Rpc, to: str, signature: str) -> int:
    return int.from_bytes(rpc.eth_call(to, chain.selector(signature), gas=2_000_000), "big")


def fork_tapeout(url: str, netlist: bytes, n_in: int, n_out: int, factory: str = XLAYER_FACTORY,
                 name: str = "tapc fork rehearsal", symbol: str = "REHEARSE", supply: int = 1 << 20,
                 mint_price: int = 20_000_000_000_000, cpu: Optional[str] = None, say=None) -> Rehearsal:
    """Create a throwaway processor on a local anvil fork (or reuse `cpu`) and tape `netlist` out on it."""
    say = say or (lambda m: None)
    nl = check(netlist, n_in, n_out)                      # never send bytes our own checker rejects
    rpc = chain.Rpc(url, max_concurrency=1, timeout=120, retries=1, gas_cap=0)
    require_local_anvil(rpc, url)
    # A throwaway address with no key anywhere: anvil impersonates it. (Anvil's own default accounts are not
    # usable on an X Layer fork: on the real chain they carry EIP-7702 delegations, so they have code and the
    # ERC-1155 mint reverts with ERC1155InvalidReceiver.)
    me = "0x" + chain.keccak256(b"tapc fork rehearsal account")[-20:].hex()
    if rpc.call("eth_getCode", [me, "latest"]) not in ("0x", "0x0"):
        raise RehearsalError(f"the rehearsal address {me} has code on this fork")
    rpc.call("anvil_setBalance", [me, hex(100 * 10 ** 18)])
    rpc.call("anvil_impersonateAccount", [me])
    r = Rehearsal(chain.rpc_host(url), rpc.chain_id(), rpc.block_number(), me, factory)
    if cpu is None:
        r.deploy_fee = _uint(rpc, factory, "deployFee()")
        r.protocol_fee = _uint(rpc, factory, "protocolFee()")
        rc = _send(rpc, me, factory, _enc_create_cpu(name, symbol, "local fork rehearsal; not on any real chain",
                                                     supply, mint_price), r.deploy_fee)
        topic = "0x" + chain.keccak256(b"CPUCreated(address,address,address,string,uint256,uint256)").hex()
        log = next((lg for lg in rc["logs"] if lg["topics"][0] == topic), None)
        if log is None:
            raise RehearsalError("createCPU emitted no CPUCreated event")
        r.cpu = "0x" + log["topics"][1][-40:]
        r.transistors = "0x" + log["topics"][2][-40:]
        r.gas["createCPU"] = int(rc["gasUsed"], 16)
        r.value["createCPU"] = r.deploy_fee
        say(f"created throwaway processor {r.cpu} (transistors {r.transistors}) on the fork")
    else:
        r.cpu = cpu
        r.transistors = "0x" + rpc.eth_call(cpu, chain.selector("transistors()"), gas=2_000_000)[-20:].hex()
        r.protocol_fee = _uint(rpc, r.transistors, "protocolFee()")
    r.mint_price = _uint(rpc, r.transistors, "mintPrice()")
    r.tapeout_fee = _uint(rpc, r.cpu, "TAPEOUT_FEE()")
    mint_sel = chain.selector("mint(uint256,uint256)")
    for token_id, amount, label in ((0, nl.n_nand, "mintNand"), (1, nl.n_latch, "mintLatch")):
        if amount:
            cost = r.mint_price * amount + r.protocol_fee
            rc = _send(rpc, me, r.transistors, mint_sel + _w(token_id) + _w(amount), cost)
            r.gas[label] = int(rc["gasUsed"], 16)
            r.value[label] = cost
    rc = _send(rpc, me, r.cpu, _enc_tapeout(netlist, n_in, n_out), r.tapeout_fee)
    r.gas["tapeout"] = int(rc["gasUsed"], 16)
    r.value["tapeout"] = r.tapeout_fee
    r.circuit_id = _uint(rpc, r.cpu, "nextId()")
    r.circuit_info = chain.circuit_info(rpc, r.cpu, r.circuit_id)
    r.netlist_matches = chain.fetch_netlist(rpc, r.cpu, r.circuit_id) == netlist
    say(f"taped out circuit #{r.circuit_id}: {r.gas['tapeout']:,} gas; stored bytes "
        f"{'equal' if r.netlist_matches else 'DIFFER FROM'} the local netlist")
    return r
