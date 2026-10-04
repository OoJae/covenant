"""TAP-20 netlists: decode, encode, well-formedness, counts and keccak256.

Implements TAP-20 "Circuit Netlist Format and Evaluation Semantics" (draft, updated 2026-09-30), sections 2 and 3.
Written from the specification text; checked against the MIT reference implementation vendored at
chips/vendor/tap-20/reference.py and against X Layer mainnet (see tests).

Record encoding (all integers big-endian, u24 = 3 bytes):

    0x00 NAND   a:u24 b:u24                                       7 bytes, produces 1 signal
    0x01 LATCH  d:u24                                             4 bytes, produces 1 signal
    0x02 REF    cpu:20 bytes  id:u64  nIns:u8  nOuts:u8  ins:u24 x nIns   31 + 3*nIns bytes, produces nOuts

Signals: 0 = constant 0, 1 = constant 1, 2 .. 2+nIn-1 = inputs, then one per element output in record order.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable, Optional

TAP_VERSION = "TAP-20 draft (updated 2026-09-30)"

NAND, LATCH, REF = 0x00, 0x01, 0x02
OP_NAMES = {NAND: "NAND", LATCH: "LATCH", REF: "REF"}

MAX_SIGNALS = 1 << 24          # section 3, condition 8 (and the u24 index space)
MAX_PINS = 1 << 16             # section 3, condition 2
MAX_STATE = 1 << 24            # section 3, conditions 6 and 7
MAX_GATES = (1 << 32) - 1      # section 3, condition 7

# Section 7, requirement 1: bound gates and REF depth before evaluating untrusted netlists.
DEFAULT_MAX_REF_DEPTH = 16
DEFAULT_MAX_EVAL_GATES = 1 << 22


class IllFormed(ValueError):
    """The netlist is not well-formed. `condition` is the TAP-20 section 3 condition number (1..8)."""

    def __init__(self, message: str, condition: int = 0):
        super().__init__(message)
        self.condition = condition


@dataclass(frozen=True)
class Element:
    """One decoded record."""
    op: int
    ins: tuple                       # NAND: (a, b); LATCH: (d,); REF: ins
    cpu: bytes = b""                 # REF only, 20 bytes
    cid: int = 0                     # REF only, circuit id
    n_out: int = 1                   # signals produced
    first_out: int = 0               # index of the first signal this element produces
    offset: int = 0                  # byte offset of the record in the netlist


@dataclass
class Netlist:
    """A checked, well-formed netlist."""
    data: bytes
    n_in: int
    n_out: int
    elements: list
    n_signals: int
    n_nand: int = 0                  # top-level NAND records (what tapeout burns of token id 0)
    n_latch: int = 0                 # top-level LATCH records (what tapeout burns of token id 1)
    n_ref: int = 0
    n_state: int = 0                 # total state bits, including REF sub-circuits
    gate_count: int = 0              # NAND + LATCH including REF sub-circuits (circuitInfo.gateCount)
    state_base: list = field(default_factory=list)   # per element: index of its first state bit
    subs: dict = field(default_factory=dict)         # (cpu, cid) -> Netlist, for REF
    ref_depth: int = 0                               # 0 for a flat netlist, 1 + deepest REF target otherwise

    @property
    def n_bytes(self) -> int:
        return len(self.data)

    @property
    def is_flat(self) -> bool:
        return self.n_ref == 0

    @property
    def latches_first(self) -> bool:
        """True when records 0..nLatch-1 are exactly the LATCH records (kernel interface rule; state bit i is
        then record i). Vacuously true for a combinational netlist."""
        return all(e.op == LATCH for e in self.elements[: self.n_latch]) and self.n_ref == 0

    def output_signals(self) -> range:
        return range(self.n_signals - self.n_out, self.n_signals)

    def keccak256(self) -> bytes:
        return keccak256(self.data)

    def counts(self) -> dict:
        return {
            "nIn": self.n_in, "nOut": self.n_out, "nState": self.n_state,
            "nNand": self.n_nand, "nLatch": self.n_latch, "nRef": self.n_ref,
            "gateCount": self.gate_count, "signals": self.n_signals, "bytes": len(self.data),
            "keccak256": "0x" + self.keccak256().hex(),
        }


# ------------------------------------------------------------------------------------------------ decode / encode

def decode(data: bytes, n_in: int) -> list:
    """Decode records. Raises IllFormed (condition 1) on an unknown opcode or a truncated record.

    Record lengths are checked before anything is read (section 7, requirement 2); nothing is allocated in
    proportion to a count field.
    """
    data = bytes(data)
    n = len(data)
    p = 0
    nxt = 2 + n_in
    els = []
    while p < n:
        start = p
        op = data[p]
        if op == NAND:
            if p + 7 > n:
                raise IllFormed(f"truncated NAND record at byte {start}", 1)
            e = Element(NAND, (int.from_bytes(data[p + 1:p + 4], "big"), int.from_bytes(data[p + 4:p + 7], "big")),
                        first_out=nxt, offset=start)
            p += 7
        elif op == LATCH:
            if p + 4 > n:
                raise IllFormed(f"truncated LATCH record at byte {start}", 1)
            e = Element(LATCH, (int.from_bytes(data[p + 1:p + 4], "big"),), first_out=nxt, offset=start)
            p += 4
        elif op == REF:
            if p + 31 > n:
                raise IllFormed(f"truncated REF record at byte {start}", 1)
            cpu = data[p + 1:p + 21]
            cid = int.from_bytes(data[p + 21:p + 29], "big")
            n_ins, n_outs = data[p + 29], data[p + 30]
            end = p + 31 + 3 * n_ins
            if end > n:
                raise IllFormed(f"truncated REF record at byte {start}", 1)
            ins = tuple(int.from_bytes(data[q:q + 3], "big") for q in range(p + 31, end, 3))
            e = Element(REF, ins, cpu, cid, n_outs, first_out=nxt, offset=start)
            p = end
        else:
            raise IllFormed(f"unknown opcode 0x{op:02x} at byte {start}", 1)
        nxt += e.n_out
        els.append(e)
    return els


def encode(elements) -> bytes:
    """Encode records. Accepts Element objects or (op, ins[, cpu, cid, n_out]) tuples."""
    out = bytearray()
    for e in elements:
        if isinstance(e, Element):
            op, ins, cpu, cid, n_out = e.op, e.ins, e.cpu, e.cid, e.n_out
        else:
            op, ins = e[0], e[1]
            cpu, cid, n_out = (e[2], e[3], e[4]) if len(e) > 2 else (b"", 0, 1)
        if op == NAND:
            if len(ins) != 2:
                raise ValueError("NAND takes two inputs")
        elif op == LATCH:
            if len(ins) != 1:
                raise ValueError("LATCH takes one input")
        elif op == REF:
            if len(cpu) != 20 or not (0 <= cid < 1 << 64) or len(ins) > 255 or not (0 <= n_out <= 255):
                raise ValueError("REF fields out of range")
        else:
            raise ValueError(f"unknown opcode {op}")
        out.append(op)
        if op == REF:
            out += bytes(cpu) + cid.to_bytes(8, "big") + bytes([len(ins), n_out])
        for s in ins:
            if not (0 <= s < MAX_SIGNALS):
                raise ValueError(f"signal index {s} does not fit in u24")
            out += s.to_bytes(3, "big")
    return bytes(out)


def nand(a: int, b: int) -> tuple:
    return (NAND, (a, b))


def latch(d: int) -> tuple:
    return (LATCH, (d,))


def ref(cpu: bytes, cid: int, ins, n_out: int) -> tuple:
    return (REF, tuple(ins), bytes(cpu), cid, n_out)


# ------------------------------------------------------------------------------------------------ well-formedness

Resolver = Callable[[bytes, int], Optional["Netlist"]]


def check(data: bytes, n_in: int, n_out: int, resolve: Optional[Resolver] = None,
          max_ref_depth: int = DEFAULT_MAX_REF_DEPTH) -> Netlist:
    """Decode and check TAP-20 section 3, conditions 1 to 8. Returns a Netlist or raises IllFormed.

    `resolve(cpu, cid)` returns the already-checked Netlist of a REF target, or None when (cpu, cid) is not a
    circuit of a registered processor. Without a resolver every REF is rejected.

    `max_ref_depth` is a tool bound, not part of well-formedness (tapeout has no nesting limit): TAP-20
    section 7 requires tools to bound the REF depth before evaluating. Exceeding it raises IllFormed with
    condition 0.
    """
    data = bytes(data)
    if not isinstance(n_in, int) or not isinstance(n_out, int) or isinstance(n_in, bool) or isinstance(n_out, bool):
        raise IllFormed("nIn and nOut must be integers", 2)
    if n_in < 0 or n_in > MAX_PINS:
        raise IllFormed(f"nIn {n_in} out of range 0..65536", 2)
    if n_out < 1:
        raise IllFormed("no outputs (nOut = 0)", 2)
    if n_out > MAX_PINS:
        raise IllFormed(f"nOut {n_out} out of range 1..65536", 2)

    els = decode(data, n_in)                                           # condition 1
    produced = sum(e.n_out for e in els)
    n_sig = 2 + n_in + produced
    if n_sig > MAX_SIGNALS:
        raise IllFormed("more than 2^24 signals", 8)                   # condition 8
    if produced < n_out:
        raise IllFormed("too few signals for outputs", 3)              # condition 3

    nl = Netlist(data, n_in, n_out, els, n_sig)
    state = 0
    sub_gates = 0
    for e in els:
        nl.state_base.append(state)
        if e.op == NAND:
            if e.ins[0] >= e.first_out or e.ins[1] >= e.first_out:
                raise IllFormed(f"NAND at signal {e.first_out} refers to a future signal", 4)
            nl.n_nand += 1
        elif e.op == LATCH:
            if e.ins[0] >= n_sig:
                raise IllFormed(f"LATCH at signal {e.first_out}: d = {e.ins[0]} out of range", 5)
            nl.n_latch += 1
            state += 1
        else:
            for s in e.ins:
                if s >= e.first_out:
                    raise IllFormed(f"REF at signal {e.first_out} refers to a future signal", 4)
            if resolve is None:
                raise IllFormed("REF without a resolver: target not a registered processor", 6)
            sub = resolve(e.cpu, e.cid)
            if sub is None:
                raise IllFormed("REF target is not a circuit of a registered processor", 6)
            if sub.n_in != len(e.ins) or sub.n_out != e.n_out:
                raise IllFormed("REF pin mismatch with the target circuit", 6)
            if sub.n_state > MAX_STATE:
                raise IllFormed("REF size", 6)
            nl.subs[(e.cpu, e.cid)] = sub
            nl.n_ref += 1
            nl.ref_depth = max(nl.ref_depth, 1 + sub.ref_depth)
            state += sub.n_state
            sub_gates += sub.gate_count
    nl.n_state = state
    nl.gate_count = sub_gates + nl.n_nand + nl.n_latch
    if nl.n_state > MAX_STATE or nl.gate_count > MAX_GATES:
        raise IllFormed("size overflow", 7)                            # condition 7
    if nl.ref_depth > max_ref_depth:
        raise IllFormed(f"REF nesting {nl.ref_depth} deeper than the tool bound {max_ref_depth}", 0)
    return nl


# Chip shapes. "covenant-v1" mirrors chips/INTERFACE.md section 2 as read on 2026-10-04; that file wins if the
# two ever disagree (it is what the Fab contract enforces).
SHAPES = {
    "covenant-v1": {"nIn": 96, "nOut": 112, "minState": 1, "maxState": 256, "maxGates": 3400, "maxBytes": 24000},
}


def shape_violations(nl: Netlist, shape: str = "covenant-v1") -> list:
    """Reasons why a checked netlist does not have the given chip shape ([] when it does)."""
    sh = SHAPES[shape]
    out = []
    if nl.n_in != sh["nIn"]:
        out.append(f"nIn is {nl.n_in}, must be {sh['nIn']}")
    if nl.n_out != sh["nOut"]:
        out.append(f"nOut is {nl.n_out}, must be {sh['nOut']}")
    if nl.n_ref:
        out.append(f"{nl.n_ref} REF record(s): only NAND and LATCH are allowed")
    if not (sh["minState"] <= nl.n_state <= sh["maxState"]):
        out.append(f"nState is {nl.n_state}, must be {sh['minState']}..{sh['maxState']}")
    if not nl.latches_first:
        out.append("LATCH records must be records 0..nState-1, with no LATCH after them")
    if nl.n_nand + nl.n_latch > sh["maxGates"]:
        out.append(f"{nl.n_nand + nl.n_latch} gates, more than {sh['maxGates']}")
    if len(nl.data) > sh["maxBytes"]:
        out.append(f"{len(nl.data)} bytes, more than {sh['maxBytes']} (one SSTORE2 chunk)")
    return out


def is_well_formed(data: bytes, n_in: int, n_out: int, resolve: Optional[Resolver] = None) -> bool:
    try:
        check(data, n_in, n_out, resolve)
        return True
    except IllFormed:
        return False


def burn_of(data: bytes) -> tuple:
    """(nNand, nLatch) of the top-level records: the transistors `tapeout` burns. Byte scan, no recursion."""
    n_nand = n_latch = 0
    p, n = 0, len(data)
    while p < n:
        op = data[p]
        if op == NAND:
            n_nand += 1
            p += 7
        elif op == LATCH:
            n_latch += 1
            p += 4
        elif op == REF:
            if p + 31 > n:
                raise IllFormed("truncated REF record", 1)
            p += 31 + 3 * data[p + 29]
        else:
            raise IllFormed(f"unknown opcode 0x{op:02x} at byte {p}", 1)
    if p != n:
        raise IllFormed("truncated record", 1)
    return n_nand, n_latch


def depth_of(nl: Netlist) -> int:
    """Longest combinational path in NAND gates, ending at an output pin or at a LATCH d input. Flat netlists
    only (same definition as NetlistVM.depthOf for a netlist without REF)."""
    if not nl.is_flat:
        raise ValueError("depth_of handles flat netlists only")
    d = [0] * nl.n_signals
    for e in nl.elements:
        if e.op == NAND:
            a, b = e.ins
            d[e.first_out] = 1 + (d[a] if d[a] > d[b] else d[b])
    best = max((d[i] for i in nl.output_signals()), default=0)
    for e in nl.elements:
        if e.op == LATCH and d[e.ins[0]] > best:
            best = d[e.ins[0]]
    return best


def levels_of(nl: Netlist) -> list:
    """Per-signal logic level (constants, inputs and LATCH outputs are level 0). Flat netlists only."""
    d = [0] * nl.n_signals
    for e in nl.elements:
        if e.op == NAND:
            a, b = e.ins
            d[e.first_out] = 1 + (d[a] if d[a] > d[b] else d[b])
    return d


def live_count(nl: Netlist) -> int:
    """Number of top-level elements whose output reaches an output pin (through any path, including LATCH d).
    Flat netlists only. A netlist straight out of `tapc pack` has live_count == nNand + nLatch."""
    if not nl.is_flat:
        raise ValueError("live_count handles flat netlists only")
    base = 2 + nl.n_in
    live = bytearray(nl.n_signals)
    stack = list(nl.output_signals())
    for s in stack:
        live[s] = 1
    while stack:
        s = stack.pop()
        if s < base:
            continue
        for t in nl.elements[s - base].ins:
            if not live[t]:
                live[t] = 1
                stack.append(t)
    return sum(live[base:])


# ------------------------------------------------------------------------------------------------ hex helpers

def from_hex(text: str) -> bytes:
    t = "".join(text.split())
    if t.startswith(("0x", "0X")):
        t = t[2:]
    return bytes.fromhex(t)


def to_hex(data: bytes) -> str:
    return "0x" + bytes(data).hex()


def read_netlist_file(path: str) -> bytes:
    """Read raw bytes from a .tap file, or hex from a .hex / text file (with or without 0x)."""
    with open(path, "rb") as f:
        raw = f.read()
    if str(path).endswith(".tap"):
        return raw
    stripped = raw.strip()
    try:
        text = stripped.decode("ascii")
    except UnicodeDecodeError:
        return raw
    body = text[2:] if text[:2] in ("0x", "0X") else text
    if body and len(body) % 2 == 0 and all(c in "0123456789abcdefABCDEF" for c in body):
        return bytes.fromhex(body)
    return raw


# ------------------------------------------------------------------------------------------------ keccak256

_KECCAK_RC = (
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
)
_KECCAK_ROT = (
    (0, 36, 3, 41, 18),
    (1, 44, 10, 45, 2),
    (62, 6, 43, 15, 61),
    (28, 55, 25, 21, 56),
    (27, 20, 39, 8, 14),
)
_M64 = (1 << 64) - 1


def _keccak_f(a: list) -> None:
    """Keccak-f[1600] on a 5x5 list of 64-bit lanes, a[x][y]."""
    for rc in _KECCAK_RC:
        c = [a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4] for x in range(5)]
        for x in range(5):
            t = c[(x + 1) % 5]
            dd = c[(x - 1) % 5] ^ (((t << 1) | (t >> 63)) & _M64)
            col = a[x]
            for y in range(5):
                col[y] ^= dd
        b = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                r = _KECCAK_ROT[x][y]
                v = a[x][y]
                b[y][(2 * x + 3 * y) % 5] = ((v << r) | (v >> (64 - r))) & _M64 if r else v
        for x in range(5):
            for y in range(5):
                a[x][y] = b[x][y] ^ ((~b[(x + 1) % 5][y]) & b[(x + 2) % 5][y])
        a[0][0] ^= rc


def keccak256(data: bytes) -> bytes:
    """Ethereum keccak256 (original Keccak padding 0x01, not SHA3's 0x06). Pure Python, no dependencies."""
    rate = 136
    msg = bytearray(data)
    msg.append(0x01)
    while len(msg) % rate:
        msg.append(0x00)
    msg[-1] |= 0x80
    a = [[0] * 5 for _ in range(5)]
    for off in range(0, len(msg), rate):
        block = msg[off:off + rate]
        for i in range(rate // 8):
            a[i % 5][i // 5] ^= int.from_bytes(block[8 * i:8 * i + 8], "little")
        _keccak_f(a)
    out = bytearray()
    for i in range(4):
        out += a[i % 5][i // 5].to_bytes(8, "little")
    return bytes(out)
