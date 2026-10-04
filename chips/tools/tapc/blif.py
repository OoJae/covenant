"""Parser for the BLIF that Yosys writes for a mapped combinational core.

Handles what `write_blif` and `write_blif -gates` emit:

    .model NAME
    .inputs  a b[0] b[1] ...        (continuation lines end with a backslash)
    .outputs y[0] ...
    .names $false                   constant 0 (no cover lines)
    .names $true  / 1               constant 1
    .names $undef                   undefined; treated as constant 0 and reported
    .names src dst / 1 1            buffer (how Yosys writes a wire-to-wire connection)
    .names a b y / <cover>          a truth-table cell (what `abc -g NAND` + plain write_blif gives)
    .gate CELL A=n1 B=n2 Y=n3       a liberty cell (write_blif -gates)
    .subckt CELL A=n1 ...           same thing, generic form
    .conn src dst                   non-standard connection (write_blif -conn)
    .cname / .attr / .param         ignored, except that .cname names the preceding gate
    .end

.latch is rejected: a chip core is a pure combinational function; the packer adds the LATCH records.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional


class BlifError(ValueError):
    pass


@dataclass
class Gate:
    cell: str                       # cell type, e.g. NAND2, INV, $_NAND_
    pins: dict                      # formal -> net name
    line: int = 0
    name: Optional[str] = None      # from .cname, when present


@dataclass
class Names:
    inputs: list                    # input net names
    output: str
    cover: list                     # list of (input_pattern, output_char); pattern over '0', '1', '-'
    line: int = 0


@dataclass
class BlifModel:
    name: str = ""
    inputs: list = field(default_factory=list)
    outputs: list = field(default_factory=list)
    gates: list = field(default_factory=list)
    names: list = field(default_factory=list)
    conns: list = field(default_factory=list)       # (src, dst)

    def cell_counts(self) -> dict:
        out: dict = {}
        for g in self.gates:
            out[g.cell] = out.get(g.cell, 0) + 1
        return dict(sorted(out.items()))


def _logical_lines(text: str):
    """Yield (line_number, text) with comments removed and backslash continuations joined."""
    buf, start = "", 0
    for no, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].rstrip()
        if not buf:
            start = no
        if line.endswith("\\"):
            buf += line[:-1] + " "
            continue
        buf += line
        if buf.strip():
            yield start, buf.strip()
        buf = ""
    if buf.strip():
        yield start, buf.strip()


def parse(text: str) -> BlifModel:
    """Parse one BLIF model. Raises BlifError on anything a combinational mapped core should not contain."""
    model: Optional[BlifModel] = None
    current: Optional[Names] = None
    last_gate: Optional[Gate] = None
    ended = False
    for no, line in _logical_lines(text):
        if not line.startswith("."):
            if current is None:
                raise BlifError(f"line {no}: cover line outside a .names block: {line!r}")
            parts = line.split()
            if len(current.inputs) == 0:
                if len(parts) != 1 or parts[0] not in ("0", "1"):
                    raise BlifError(f"line {no}: bad constant cover {line!r}")
                current.cover.append(("", parts[0]))
            else:
                if len(parts) != 2 or len(parts[0]) != len(current.inputs) or parts[1] not in ("0", "1") \
                        or any(c not in "01-" for c in parts[0]):
                    raise BlifError(f"line {no}: bad cover line {line!r}")
                current.cover.append((parts[0], parts[1]))
            continue
        current = None
        tok = line.split()
        key = tok[0]
        if key == ".model":
            if model is not None:
                raise BlifError(f"line {no}: more than one .model; flatten the design before write_blif")
            model = BlifModel(name=tok[1] if len(tok) > 1 else "")
            continue
        if model is None:
            raise BlifError(f"line {no}: {key} before .model")
        if ended:
            raise BlifError(f"line {no}: content after .end (more than one model?)")
        if key == ".inputs":
            model.inputs.extend(tok[1:])
        elif key == ".outputs":
            model.outputs.extend(tok[1:])
        elif key == ".names":
            if len(tok) < 2:
                raise BlifError(f"line {no}: .names without an output")
            current = Names(tok[1:-1], tok[-1], [], no)
            model.names.append(current)
        elif key in (".gate", ".subckt"):
            if len(tok) < 3:
                raise BlifError(f"line {no}: {key} without pins")
            pins = {}
            for item in tok[2:]:
                if "=" not in item:
                    raise BlifError(f"line {no}: bad pin binding {item!r}")
                formal, actual = item.split("=", 1)
                if formal in pins:
                    raise BlifError(f"line {no}: pin {formal} bound twice")
                pins[formal] = actual
            last_gate = Gate(tok[1], pins, no)
            model.gates.append(last_gate)
        elif key == ".conn":
            if len(tok) != 3:
                raise BlifError(f"line {no}: .conn takes two nets")
            model.conns.append((tok[1], tok[2]))
        elif key == ".cname":
            if last_gate is not None and len(tok) > 1:
                last_gate.name = tok[1]
        elif key in (".attr", ".param", ".barbuf", ".default_input_arrival", ".default_output_required"):
            pass
        elif key == ".latch":
            raise BlifError(f"line {no}: .latch found. A chip core must be combinational: "
                            f"module <name>_core(s, x, ns, y); the packer adds the LATCH records")
        elif key == ".end":
            ended = True
        else:
            raise BlifError(f"line {no}: unsupported BLIF construct {key}")
    if model is None:
        raise BlifError("no .model found")
    return model


def parse_file(path: str) -> BlifModel:
    with open(path, "r", encoding="utf-8") as f:
        return parse(f.read())


def split_bit(net: str) -> tuple:
    """'x[12]' -> ('x', 12); 'en' -> ('en', None)."""
    if net.endswith("]") and "[" in net:
        base, _, idx = net[:-1].rpartition("[")
        if idx.isdigit():
            return base, int(idx)
    return net, None


def port_bits(nets: list, port: str) -> list:
    """Nets of a vector port, ordered by bit index. A scalar port named `port` is a 1-bit vector. Raises
    BlifError when indices are not exactly 0..n-1."""
    found = {}
    for n in nets:
        base, idx = split_bit(n)
        if base == port:
            i = 0 if idx is None else idx
            if i in found:
                raise BlifError(f"port {port}: bit {i} appears twice")
            found[i] = n
    if sorted(found) != list(range(len(found))):
        raise BlifError(f"port {port}: bit indices {sorted(found)} are not 0..{len(found) - 1}")
    return [found[i] for i in range(len(found))]
