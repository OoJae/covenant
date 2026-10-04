"""Pack a mapped combinational core (BLIF from Yosys) into TAP-20 netlist bytes.

The chip convention: a pure combinational Verilog module

    module <name>_core(input [S-1:0] s, input [NIN-1:0] x, output [S-1:0] ns, output [NOUT-1:0] y);

where s is the state, x the inputs, ns the next state and y the outputs. A combinational chip has no s / ns
ports. The packer turns the pair (s, ns) into LATCH records.

Layout rules (documented, stable, and checked by the tests):

  1. LATCH records come first. Record i is state bit i, which is bit i of the `s` port; its d is whatever
     drives bit i of `ns` (d may point forward, or straight at an input, another latch or a constant).
  2. Then the NAND records of the body, in a deterministic topological order (depth-first from ns[0], ns[1],
     ..., then y[0], y[1], ...), so NAND inputs only ever refer backwards.
  3. The last nOut records are the outputs, y[0] first. An output whose driver feeds nothing but later outputs
     and latches is simply placed there. Otherwise the driver is repeated once (the same NAND, one extra
     record). An output wired straight to an input pin or a state bit needs a buffer: NAND(t, t) with
     t = NAND(v, v), where t is shared if the design already has it. A constant output costs one record:
     NAND(1, 1) = 0 or NAND(0, 0) = 1. Nothing else is ever padded.
  4. INV(a) is NAND(a, a); constants are signals 0 and 1; aliases cost nothing; identical NANDs are merged;
     logic that reaches no output and no latch is dropped.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from typing import Optional

from . import __version__
from .blif import BlifError, BlifModel, port_bits
from .cells import ALL_CELLS, C0, C1, Builder
from .netlist import LATCH, MAX_SIGNALS, NAND, TAP_VERSION, Netlist, check, depth_of, encode, keccak256, levels_of

MANIFEST_FORMAT = "tapc-manifest/1"
MAP_FORMAT = "tapc-map/1"
PINS_FORMAT = "tapc-pins/1"


class PackError(ValueError):
    pass


@dataclass
class Packed:
    name: str
    data: bytes
    netlist: Netlist
    manifest: dict
    map: dict
    stats: dict = field(default_factory=dict)

    @property
    def hex(self) -> str:
        return "0x" + self.data.hex()


# ------------------------------------------------------------------------------------------------ pin names

def load_pins(path: Optional[str]) -> dict:
    """Read a pins file: {"inputs": [{"name", "lsb", "width"}], "outputs": [...], "state": [...]}."""
    if not path:
        return {}
    with open(path, "r", encoding="utf-8") as f:
        doc = json.load(f)
    return {k: doc.get(k, []) for k in ("inputs", "outputs", "state")}


def _bit_names(fields: list, width: int, prefix: str, what: str) -> list:
    """Per-bit names from a field list; uncovered bits are named '<prefix>[i]'."""
    names: list = [None] * width
    for f in fields or []:
        nm, lsb, w = f["name"], int(f["lsb"]), int(f.get("width", 1))
        if w < 1 or lsb < 0 or lsb + w > width:
            raise PackError(f"pins: {what} field {nm!r} [{lsb}+:{w}] does not fit in {width} bits")
        for k in range(w):
            if names[lsb + k] is not None:
                raise PackError(f"pins: {what} bit {lsb + k} is named twice ({names[lsb + k]!r}, {nm!r})")
            names[lsb + k] = nm if w == 1 else f"{nm}[{k}]"
    return [n if n is not None else f"{prefix}[{i}]" for i, n in enumerate(names)]


def _field_of_bit(fields: list, width: int, prefix: str) -> list:
    """Per-bit field name (the group a bit belongs to); uncovered bits belong to group '<prefix>'."""
    out = [prefix] * width
    for f in fields or []:
        for k in range(int(f.get("width", 1))):
            out[int(f["lsb"]) + k] = f["name"]
    return out


# ------------------------------------------------------------------------------------------------ BLIF -> DAG

def _block_of(net: Optional[str]) -> Optional[str]:
    """The instance path a net came from, when the design was mapped with its hierarchy kept and flattened
    afterwards ('u_avg.$abc$12$new_n7' -> 'u_avg'). None for top-level or anonymous nets."""
    if not net:
        return None
    name = net
    if name.startswith("$flatten"):
        name = name[len("$flatten"):]
    name = name.lstrip("\\")
    path = []
    for part in name.split(".")[:-1]:
        part = part.lstrip("\\")
        if not part or part.startswith("$"):
            break
        path.append(part)
    return ".".join(path) or None


def _build(model: BlifModel, b: Builder, leaf_of: dict, wanted: list, cells: dict) -> dict:
    """Resolve the nets in `wanted` to builder nodes. Returns {net: node} for every net it had to visit."""
    driver: dict = {}

    def add_driver(net, d, line):
        if net in driver or net in leaf_of:
            raise PackError(f"BLIF line {line}: net {net!r} has more than one driver")
        driver[net] = d

    for g in model.gates:
        cell = cells.get(g.cell)
        if cell is None:
            raise PackError(f"BLIF line {g.line}: unknown cell {g.cell!r}. Known cells: {', '.join(sorted(cells))}")
        missing = [p for p in cell.pins + (cell.out,) if p not in g.pins]
        extra = [p for p in g.pins if p not in cell.pins and p != cell.out]
        if missing or extra:
            raise PackError(f"BLIF line {g.line}: cell {g.cell} pins mismatch (missing {missing}, extra {extra})")
        add_driver(g.pins[cell.out], ("gate", g, cell), g.line)
    for nm in model.names:
        add_driver(nm.output, ("names", nm), nm.line)
    for src, dst in model.conns:
        add_driver(dst, ("conn", src), 0)

    node: dict = dict(leaf_of)
    undef_used = []

    def deps(net):
        d = driver.get(net)
        if d is None:
            raise PackError(f"net {net!r} has no driver")
        if d[0] == "gate":
            return [d[1].pins[p] for p in d[2].pins]
        if d[0] == "names":
            return list(d[1].inputs)
        return [d[1]]

    for root in wanted:
        if root in node:
            continue
        stack = [root]
        on_path = set()
        while stack:
            net = stack[-1]
            if net in node:
                stack.pop()
                on_path.discard(net)
                continue
            pending = [n for n in deps(net) if n not in node]
            if pending:
                # A net is revisited with unresolved fanins only when one of its own descendants pushed it
                # again, i.e. when it depends on itself.
                if net in on_path:
                    raise PackError(f"combinational loop through net {net!r}")
                on_path.add(net)
                stack.extend(reversed(pending))
                continue
            d = driver[net]
            b.set_context(net)
            if d[0] == "gate":
                g, cell = d[1], d[2]
                node[net] = cell.expand(b, *[node[g.pins[p]] for p in cell.pins])
            elif d[0] == "names":
                nm = d[1]
                if net == "$undef":
                    undef_used.append(net)
                node[net] = b.cover([node[i] for i in nm.inputs], nm.cover)
            else:
                node[net] = node[d[1]]
            b.set_context(None)
            stack.pop()
            on_path.discard(net)
    node["__undef_used__"] = undef_used          # reported by the caller
    return node


# ------------------------------------------------------------------------------------------------ pack

def pack_model(model: BlifModel, name: Optional[str] = None, state: tuple = ("s", "ns"), in_port: str = "x",
               out_port: str = "y", n_in: Optional[int] = None, n_out: Optional[int] = None,
               pins: Optional[dict] = None, cells: Optional[dict] = None, build_info: Optional[dict] = None,
               allow_undef: bool = False) -> Packed:
    """Pack a parsed BLIF model. See the module docstring for the layout rules.

    A net that Yosys left undefined ($undef: an `x` in the source, or an output nothing drives) is an error
    unless allow_undef is set, in which case it is tied to constant 0."""
    cells = ALL_CELLS if cells is None else cells
    pins = pins or {}
    s_port, ns_port = state
    name = name or (model.name[:-5] if model.name.endswith("_core") else model.name) or "chip"

    s_nets = port_bits(model.inputs, s_port)
    x_nets = port_bits(model.inputs, in_port)
    ns_nets = port_bits(model.outputs, ns_port)
    y_nets = port_bits(model.outputs, out_port)
    other_in = [n for n in model.inputs if n not in set(s_nets) | set(x_nets)]
    other_out = [n for n in model.outputs if n not in set(ns_nets) | set(y_nets)]
    if other_in or other_out:
        raise PackError(f"unexpected ports (a core has only {s_port}, {in_port}, {ns_port}, {out_port}): "
                        f"inputs {other_in[:4]}, outputs {other_out[:4]}")
    if len(s_nets) != len(ns_nets):
        raise PackError(f"state port {s_port} is {len(s_nets)} bits but {ns_port} is {len(ns_nets)} bits")
    S, NI, NO = len(s_nets), len(x_nets), len(y_nets)
    if NO == 0:
        raise PackError(f"no output port {out_port!r}: a circuit needs at least one output")
    if n_in is not None and n_in != NI:
        raise PackError(f"--nin {n_in} but port {in_port} is {NI} bits")
    if n_out is not None and n_out != NO:
        raise PackError(f"--nout {n_out} but port {out_port} is {NO} bits")

    # ---- leaves and logic
    b = Builder()
    leaf_of: dict = {}
    x_node = []
    for i, net in enumerate(x_nets):
        n = b.leaf(f"{in_port}[{i}]")
        leaf_of[net] = n
        x_node.append(n)
    s_node = []
    for i, net in enumerate(s_nets):
        n = b.leaf(f"{s_port}[{i}]")
        leaf_of[net] = n
        s_node.append(n)
    net_node = _build(model, b, leaf_of, ns_nets + y_nets, cells)
    undef_used = net_node.pop("__undef_used__")
    if undef_used and not allow_undef:
        raise PackError("the design uses an undefined value ($undef): an `x` in the source or a bit that nothing "
                        "drives. A chip must define every bit; pass allow_undef to tie such bits to 0")
    ns_drv = [net_node[n] for n in ns_nets]
    y_drv = [net_node[n] for n in y_nets]

    # ---- every output must be produced by its own NAND record: materialise drivers for leaves and constants
    out_node = []
    n_buffered = n_const = 0
    for d in y_drv:
        if d == C0:
            out_node.append(b.raw_nand(C1, C1))
            n_const += 1
        elif d == C1:
            out_node.append(b.raw_nand(C0, C0))
            n_const += 1
        elif not b.is_nand(d):
            t = b.inv(d)
            out_node.append(b.raw_nand(t, t))
            n_buffered += 1
        else:
            out_node.append(d)

    fa, fb = b.fa, b.fb

    # ---- live nodes, in depth-first post-order from ns[0..], then y[0..]  (deterministic topological order)
    order = []
    seen = bytearray(len(fa))
    for root in ns_drv + out_node:
        if seen[root] or fa[root] < 0:
            continue
        stack = [root]
        while stack:
            n = stack[-1]
            if seen[n]:
                stack.pop()
                continue
            a, c = fa[n], fb[n]
            pushed = False
            if fa[a] >= 0 and not seen[a]:
                stack.append(a)
                pushed = True
            if c != a and fa[c] >= 0 and not seen[c]:
                stack.append(c)
                pushed = True
            if not pushed:
                seen[n] = 1
                order.append(n)
                stack.pop()

    # ---- which drivers can live in the output region itself
    out_pins: dict = {}
    for j, n in enumerate(out_node):
        out_pins.setdefault(n, []).append(j)
    consumers: dict = {}
    for n in order:
        a, c = fa[n], fb[n]
        consumers.setdefault(a, []).append(n)
        if c != a:
            consumers.setdefault(c, []).append(n)
    body_free: dict = {}
    for n in reversed(order):                           # consumers are decided before their fanins
        pos = out_pins.get(n)
        body_free[n] = bool(pos) and all(body_free[m] and out_pins[m][0] > pos[0] for m in consumers.get(n, ()))

    # ---- signal numbering
    sig: dict = {C0: 0, C1: 1}
    for i, n in enumerate(x_node):
        sig[n] = 2 + i
    latch_base = 2 + NI
    for i, n in enumerate(s_node):
        sig[n] = latch_base + i
    body = [n for n in order if not body_free[n]]
    nxt = latch_base + S
    for n in body:
        sig[n] = nxt
        nxt += 1
    out_base = nxt
    for n, pos in out_pins.items():
        if body_free[n]:
            sig[n] = out_base + pos[0]
    n_signals = out_base + NO
    if n_signals > MAX_SIGNALS:
        raise PackError("more than 2^24 signals")

    # ---- records
    records = [(LATCH, (sig[d],)) for d in ns_drv]
    records += [(NAND, (sig[fa[n]], sig[fb[n]])) for n in body]
    n_dup = 0
    for j, n in enumerate(out_node):
        records.append((NAND, (sig[fa[n]], sig[fb[n]])))
        if not (body_free[n] and out_pins[n][0] == j):
            n_dup += 1
    data = encode(records)
    nl = check(data, NI, NO)
    if not nl.latches_first or nl.n_state != S:
        raise PackError("internal error: latch layout")

    # ---- names
    in_names = _bit_names(pins.get("inputs"), NI, in_port, "input")
    out_names = _bit_names(pins.get("outputs"), NO, out_port, "output")
    st_names = _bit_names(pins.get("state"), S, s_port, "state")
    kk = "0x" + keccak256(data).hex()

    manifest = {
        "format": MANIFEST_FORMAT,
        "name": name,
        "standard": TAP_VERSION,
        "nIn": NI, "nOut": NO, "nState": S,
        "nNand": nl.n_nand, "nLatch": nl.n_latch, "nRef": 0, "gateCount": nl.gate_count,
        "signals": nl.n_signals, "depth": depth_of(nl),
        "bytes": len(data),
        "keccak256": kk,
        "latchesFirst": True,
        "layout": {
            "const0": 0, "const1": 1, "firstInput": 2, "firstLatch": latch_base, "firstNand": latch_base + S,
            "firstOutput": out_base,
            "outputDuplicates": n_dup, "outputBuffers": n_buffered, "outputConstants": n_const,
        },
        "inputs": [{"bit": i, "name": in_names[i], "signal": 2 + i} for i in range(NI)],
        "outputs": [{"bit": j, "name": out_names[j], "signal": out_base + j} for j in range(NO)],
        "latches": [{"bit": i, "name": st_names[i], "record": i, "signal": latch_base + i, "d": sig[ns_drv[i]]}
                    for i in range(S)],
        "fields": {"inputs": pins.get("inputs") or [], "outputs": pins.get("outputs") or [],
                   "state": pins.get("state") or []},
        "tapeout": {"nIn": NI, "nOut": NO, "burnNand": nl.n_nand, "burnLatch": nl.n_latch},
        "tool": {"tapc": __version__},
    }
    if build_info:
        manifest["build"] = build_info

    chip_map = _make_map(name, kk, nl, b, body, out_node, sig, st_names, out_names,
                         _field_of_bit(pins.get("state"), S, s_port), _field_of_bit(pins.get("outputs"), NO, out_port))
    stats = {
        "cells": model.cell_counts(), "names": len(model.names),
        "nodesBuilt": len(fa) - 2 - NI - S, "live": len(order), "body": len(body),
        "outputDuplicates": n_dup, "outputBuffers": n_buffered, "outputConstants": n_const,
        "undefUsed": len(undef_used),
    }
    return Packed(name, data, nl, manifest, chip_map, stats)


def _make_map(name, kk, nl: Netlist, b: Builder, body, out_node, sig, st_names, out_names, st_field, out_field):
    """Per-record information for a die-shot renderer.

    block: the Verilog instance path the gate came from, when recoverable (the design was mapped with its
           hierarchy kept; see `tapc synth --hier`), else null.
    cone:  the output / next-state fields this gate can influence within the beat, as indices into `groups`
           ("y.<field>" and "ns.<field>"). Always available, because it is computed from the bytes.
    level: NAND depth from the inputs and latches.
    """
    S, NO = nl.n_state, nl.n_out
    base = 2 + nl.n_in
    levels = levels_of(nl)
    groups: list = []
    gidx: dict = {}

    def group(g):
        if g not in gidx:
            gidx[g] = len(groups)
            groups.append(g)
        return gidx[g]

    # cone membership as bitmasks over groups, propagated from the sinks backwards
    mask = [0] * nl.n_signals
    for i, e in enumerate(nl.elements[:S]):
        mask[e.ins[0]] |= 1 << group("ns." + st_field[i])
    for j in range(NO):
        mask[nl.n_signals - NO + j] |= 1 << group("y." + out_field[j])
    for e in reversed(nl.elements):
        if e.op == NAND:
            m = mask[e.first_out]
            if m:
                mask[e.ins[0]] |= m
                mask[e.ins[1]] |= m

    node_of_sig = {sig[n]: n for n in body}
    out_base = nl.n_signals - NO
    blocks: list = []
    bidx: dict = {}
    records = []
    for i, e in enumerate(nl.elements):
        s = e.first_out
        if e.op == LATCH:
            records.append({"op": "LATCH", "sig": s, "d": e.ins[0], "name": st_names[i], "stateBit": i,
                            "block": None, "level": 0, "cone": _bits(mask[s])})
            continue
        if s >= out_base:
            n = out_node[s - out_base]
        else:
            n = node_of_sig.get(s)
        blk = _block_of(b.origin.get(n)) if n is not None else None
        if blk is not None and blk not in bidx:
            bidx[blk] = len(blocks)
            blocks.append(blk)
        rec = {"op": "NAND", "sig": s, "a": e.ins[0], "b": e.ins[1], "block": blk, "level": levels[s],
               "cone": _bits(mask[s])}
        if s >= out_base:
            rec["out"] = s - out_base
            rec["name"] = out_names[s - out_base]
        records.append(rec)
    return {
        "format": MAP_FORMAT, "name": name, "keccak256": kk,
        "nIn": nl.n_in, "nOut": NO, "nState": S, "firstRecordSignal": base,
        "groups": groups, "blocks": blocks, "records": records,
    }


def _bits(m: int) -> list:
    out, i = [], 0
    while m:
        if m & 1:
            out.append(i)
        m >>= 1
        i += 1
    return out


def pack_blif_text(text: str, **kw) -> Packed:
    from .blif import parse
    return pack_model(parse(text), **kw)


def pack_blif_file(path: str, **kw) -> Packed:
    from .blif import parse_file
    try:
        return pack_model(parse_file(path), **kw)
    except BlifError as e:
        raise PackError(f"{path}: {e}") from e


def dumps(doc) -> str:
    """Deterministic JSON text."""
    return json.dumps(doc, indent=1, sort_keys=False) + "\n"


def write_outputs(p: Packed, out_dir: str) -> dict:
    """Write <name>.tap, <name>.hex, <name>.manifest.json and <name>.map.json. Returns {kind: path}."""
    os.makedirs(out_dir, exist_ok=True)
    paths = {k: os.path.join(out_dir, f"{p.name}.{ext}") for k, ext in
             (("tap", "tap"), ("hex", "hex"), ("manifest", "manifest.json"), ("map", "map.json"))}
    with open(paths["tap"], "wb") as f:
        f.write(p.data)
    with open(paths["hex"], "w", encoding="ascii") as f:
        f.write(p.hex + "\n")
    with open(paths["manifest"], "w", encoding="utf-8") as f:
        f.write(dumps(p.manifest))
    with open(paths["map"], "w", encoding="utf-8") as f:
        f.write(json.dumps(p.map, separators=(",", ":")) + "\n")
    return paths
