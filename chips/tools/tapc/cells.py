"""The NAND builder and the cell library the packer understands.

A TapeOut circuit is made of two-input NAND records only (plus LATCH), so every cell of every mapping library
is expanded here into NAND(a, b) nodes. The expansion is hash-consed and constant-folded, which means:

  * INV(a) is NAND(a, a): one record;
  * two cells that need the same NAND share it (this is how a 5-NAND half adder and a 9-NAND full adder fall
    out of XOR2 + NAND2 cells);
  * constants never cost a record: NAND(0, x) = 1, NAND(1, x) = INV(x), INV(INV(x)) = x, NAND(x, INV(x)) = 1.

The same table generates the liberty file handed to ABC, with `area` = the number of NAND records the cell
costs when its inputs are unrelated signals. So the area ABC minimises is the transistor count (an upper bound
on it: sharing between cells is only found here, after mapping).
"""
from __future__ import annotations

from dataclasses import dataclass
from itertools import product
from typing import Callable, Optional, Sequence

C0, C1 = 0, 1          # builder node ids of the two constants


class Builder:
    """Hash-consed DAG of two-input NAND nodes over leaves (constants, input pins, state bits)."""

    def __init__(self):
        self.fa = [-1, -1]             # fanin a per node (-1 for leaves)
        self.fb = [-1, -1]             # fanin b per node
        self.leaf_name = {C0: "0", C1: "1"}
        self._hash: dict = {}
        self.origin: dict = {}         # NAND node -> name of the net whose driver first needed it
        self._ctx: Optional[str] = None

    # -- construction -----------------------------------------------------------------------------------
    def leaf(self, name: str) -> int:
        self.fa.append(-1)
        self.fb.append(-1)
        n = len(self.fa) - 1
        self.leaf_name[n] = name
        return n

    def is_nand(self, n: int) -> bool:
        return self.fa[n] >= 0

    def is_inv(self, n: int) -> bool:
        return self.fa[n] >= 0 and self.fa[n] == self.fb[n]

    def set_context(self, net: Optional[str]) -> None:
        self._ctx = net

    def _new(self, a: int, b: int) -> int:
        key = (a, b)
        n = self._hash.get(key)
        if n is None:
            self.fa.append(a)
            self.fb.append(b)
            n = len(self.fa) - 1
            self._hash[key] = n
            if self._ctx is not None:
                self.origin[n] = self._ctx
        return n

    def inv(self, a: int) -> int:
        if a == C0:
            return C1
        if a == C1:
            return C0
        if self.fa[a] >= 0 and self.fa[a] == self.fb[a]:      # INV(INV(z)) = z
            return self.fa[a]
        return self._new(a, a)

    def nand(self, a: int, b: int) -> int:
        if a > b:
            a, b = b, a
        if a == C0:
            return C1                                          # NAND(0, x) = 1
        if a == C1:
            return self.inv(b)                                 # NAND(1, x) = INV(x)
        if a == b:
            return self.inv(a)
        if (self.fa[a] == b and self.fb[a] == b) or (self.fa[b] == a and self.fb[b] == a):
            return C1                                          # NAND(x, INV(x)) = 1
        return self._new(a, b)

    def raw_nand(self, a: int, b: int) -> int:
        """A NAND node with no simplification (used only for output drivers that must exist as a record)."""
        if a > b:
            a, b = b, a
        return self._new(a, b)

    # -- derived operators ------------------------------------------------------------------------------
    def and2(self, a, b):
        return self.inv(self.nand(a, b))

    def or2(self, a, b):
        return self.nand(self.inv(a), self.inv(b))

    def nor2(self, a, b):
        return self.inv(self.or2(a, b))

    def xor2(self, a, b):
        t = self.nand(a, b)
        return self.nand(self.nand(a, t), self.nand(b, t))

    def xnor2(self, a, b):
        return self.inv(self.xor2(a, b))

    def mux2(self, a, b, s):
        """s ? b : a"""
        return self.nand(self.nand(a, self.inv(s)), self.nand(b, s))

    def and_n(self, xs: Sequence[int]) -> int:
        xs = list(xs)
        if not xs:
            return C1
        while len(xs) > 1:
            xs = [self.and2(xs[i], xs[i + 1]) if i + 1 < len(xs) else xs[i] for i in range(0, len(xs), 2)]
        return xs[0]

    def or_n(self, xs: Sequence[int]) -> int:
        xs = list(xs)
        if not xs:
            return C0
        while len(xs) > 1:
            xs = [self.or2(xs[i], xs[i + 1]) if i + 1 < len(xs) else xs[i] for i in range(0, len(xs), 2)]
        return xs[0]

    def cover(self, ins: Sequence[int], cover: Sequence) -> int:
        """A BLIF single-output cover (.names) as NAND nodes: sum of products, NAND-NAND form."""
        if not cover:
            return C0
        kinds = {o for _, o in cover}
        if len(kinds) != 1:
            raise ValueError("a .names cover must be all on-set or all off-set")
        cubes = []
        for pat, _ in cover:
            lits = [ins[i] if c == "1" else self.inv(ins[i]) for i, c in enumerate(pat) if c != "-"]
            cubes.append(self.and_n(lits))
        f = self.or_n(cubes)
        return f if kinds == {"1"} else self.inv(f)

    # -- evaluation (for tests) -------------------------------------------------------------------------
    def evaluate(self, node: int, values: dict) -> int:
        """Value of `node` given leaf values {leaf id: 0/1}. Iterative."""
        memo = {C0: 0, C1: 1}
        memo.update(values)
        stack = [node]
        while stack:
            n = stack[-1]
            if n in memo:
                stack.pop()
                continue
            a, b = self.fa[n], self.fb[n]
            if a < 0:
                raise KeyError(f"no value for leaf {self.leaf_name.get(n, n)}")
            if a in memo and b in memo:
                memo[n] = 1 - (memo[a] & memo[b])
                stack.pop()
            else:
                if a not in memo:
                    stack.append(a)
                if b not in memo:
                    stack.append(b)
        return memo[node]


@dataclass(frozen=True)
class Cell:
    name: str
    pins: tuple                 # input pin names
    out: str                    # output pin name
    function: str               # liberty boolean function of the output
    expand: Callable            # (builder, *input nodes) -> node
    truth: Callable             # (*bits) -> bit, the intended function (checked against expand in tests)
    liberty_area: Optional[float] = None   # override; default = NAND records of the expansion

    def area(self) -> int:
        """NAND records this cell costs when its inputs are unrelated signals."""
        b = Builder()
        leaves = [b.leaf(p) for p in self.pins]
        before = len(b.fa)
        self.expand(b, *leaves)
        return len(b.fa) - before


def _c(name, pins, function, expand, truth, liberty_area=None, out="Y"):
    return Cell(name, tuple(pins), out, function, expand, truth, liberty_area)


# Liberty cells. Pin order is (A, B, C, S); output is Y.
LIBERTY_CELLS = {c.name: c for c in [
    # BUF costs nothing in the netlist (it is an alias) but is priced high so the mapper never wants one.
    _c("BUF",   "A",   "A",                 lambda b, a: a,                          lambda a: a, liberty_area=1000),
    _c("INV",   "A",   "!A",                lambda b, a: b.inv(a),                   lambda a: 1 - a),
    _c("NAND2", "AB",  "!(A*B)",            lambda b, a, c: b.nand(a, c),            lambda a, c: 1 - (a & c)),
    _c("AND2",  "AB",  "(A*B)",             lambda b, a, c: b.and2(a, c),            lambda a, c: a & c),
    _c("OR2",   "AB",  "(A+B)",             lambda b, a, c: b.or2(a, c),             lambda a, c: a | c),
    _c("NOR2",  "AB",  "!(A+B)",            lambda b, a, c: b.nor2(a, c),            lambda a, c: 1 - (a | c)),
    _c("XOR2",  "AB",  "(A^B)",             lambda b, a, c: b.xor2(a, c),            lambda a, c: a ^ c),
    _c("XNOR2", "AB",  "!(A^B)",            lambda b, a, c: b.xnor2(a, c),           lambda a, c: 1 - (a ^ c)),
    # A*!B and A+!B: one inverter cheaper than the generic forms when B's complement is not otherwise needed
    _c("ANDN2", "AB",  "(A*!B)",            lambda b, a, c: b.inv(b.nand(a, b.inv(c))),  lambda a, c: a & (1 - c)),
    _c("ORN2",  "AB",  "(A+!B)",            lambda b, a, c: b.nand(b.inv(a), c),     lambda a, c: a | (1 - c)),
    _c("NAND3", "ABC", "!(A*B*C)",          lambda b, a, c, d: b.nand(b.and2(a, c), d),
       lambda a, c, d: 1 - (a & c & d)),
    _c("AO21",  "ABC", "((A*B)+C)",         lambda b, a, c, d: b.nand(b.nand(a, c), b.inv(d)),
       lambda a, c, d: (a & c) | d),
    _c("AOI21", "ABC", "!((A*B)+C)",        lambda b, a, c, d: b.inv(b.nand(b.nand(a, c), b.inv(d))),
       lambda a, c, d: 1 - ((a & c) | d)),
    _c("OAI21", "ABC", "!((A+B)*C)",        lambda b, a, c, d: b.nand(b.or2(a, c), d),
       lambda a, c, d: 1 - ((a | c) & d)),
    _c("OA21",  "ABC", "((A+B)*C)",         lambda b, a, c, d: b.inv(b.nand(b.or2(a, c), d)),
       lambda a, c, d: (a | c) & d),
    # S ? B : A
    _c("MUX2",  "ABS", "((A*!S)+(B*S))",    lambda b, a, c, s: b.mux2(a, c, s),      lambda a, c, s: c if s else a),
    # majority and three-input parity, written so that they share NANDs with XOR2(A, B) of the same operands
    _c("MAJ3",  "ABC", "((A*B)+(C*(A^B)))", lambda b, a, c, d: b.nand(b.nand(a, c), b.nand(d, b.xor2(a, c))),
       lambda a, c, d: 1 if a + c + d >= 2 else 0),
    _c("XOR3",  "ABC", "(A^B^C)",           lambda b, a, c, d: b.xor2(b.xor2(a, c), d),
       lambda a, c, d: a ^ c ^ d),
]}

# Yosys internal gate cells, as written by `write_blif -icells` after `abc -g ...`.
YOSYS_CELLS = {c.name: c for c in [
    _c("$_BUF_",    "A",   "A",       lambda b, a: a,                       lambda a: a),
    _c("$_NOT_",    "A",   "!A",      lambda b, a: b.inv(a),                lambda a: 1 - a),
    _c("$_NAND_",   "AB",  "!(A*B)",  lambda b, a, c: b.nand(a, c),         lambda a, c: 1 - (a & c)),
    _c("$_AND_",    "AB",  "(A*B)",   lambda b, a, c: b.and2(a, c),         lambda a, c: a & c),
    _c("$_OR_",     "AB",  "(A+B)",   lambda b, a, c: b.or2(a, c),          lambda a, c: a | c),
    _c("$_NOR_",    "AB",  "!(A+B)",  lambda b, a, c: b.nor2(a, c),         lambda a, c: 1 - (a | c)),
    _c("$_XOR_",    "AB",  "(A^B)",   lambda b, a, c: b.xor2(a, c),         lambda a, c: a ^ c),
    _c("$_XNOR_",   "AB",  "!(A^B)",  lambda b, a, c: b.xnor2(a, c),        lambda a, c: 1 - (a ^ c)),
    _c("$_ANDNOT_", "AB",  "(A*!B)",  lambda b, a, c: b.inv(b.nand(a, b.inv(c))), lambda a, c: a & (1 - c)),
    _c("$_ORNOT_",  "AB",  "(A+!B)",  lambda b, a, c: b.nand(b.inv(a), c),  lambda a, c: a | (1 - c)),
    _c("$_MUX_",    "ABS", "mux",     lambda b, a, c, s: b.mux2(a, c, s),   lambda a, c, s: c if s else a),
]}

ALL_CELLS = {**LIBERTY_CELLS, **YOSYS_CELLS}

# Named libraries. "nand" is the plain one the task asked to try first (INV + NAND2, with the BUF that ABC
# needs as a third cell class); the others add macro cells whose area is their true NAND cost.
LIBRARIES = {
    "nand": ["BUF", "INV", "NAND2"],
    "xor": ["BUF", "INV", "NAND2", "XOR2", "XNOR2"],
    "basic": ["BUF", "INV", "NAND2", "AND2", "OR2", "NOR2", "XOR2", "XNOR2"],
    "rich": ["BUF", "INV", "NAND2", "AND2", "OR2", "NOR2", "XOR2", "XNOR2", "ANDN2", "ORN2", "NAND3",
             "AO21", "AOI21", "OAI21", "OA21", "MUX2"],
    "arith": ["BUF", "INV", "NAND2", "AND2", "OR2", "NOR2", "XOR2", "XNOR2", "ANDN2", "ORN2", "NAND3",
              "AO21", "AOI21", "OAI21", "OA21", "MUX2", "MAJ3", "XOR3"],
}


def liberty_text(library: str = "nand") -> str:
    """The liberty file for one of the named libraries. Deterministic text."""
    names = LIBRARIES[library]
    lines = [
        f"/* tapc cell library '{library}': every cell is priced in TAP-20 NAND records. Generated by tapc. */",
        f"library(tap20_{library}) {{",
        "  delay_model : table_lookup;",
        '  time_unit : "1ns";',
        '  voltage_unit : "1V";',
        '  current_unit : "1mA";',
        "  capacitive_load_unit(1, pf);",
    ]
    for n in names:
        c = LIBERTY_CELLS[n]
        area = c.liberty_area if c.liberty_area is not None else c.area()
        lines.append(f"  cell({c.name}) {{")
        lines.append(f"    area : {area};")
        for p in c.pins:
            lines.append(f"    pin({p}) {{ direction : input; capacitance : 1; }}")
        lines.append(f'    pin({c.out}) {{ direction : output; function : "{c.function}"; }}')
        lines.append("  }")
    lines.append("}")
    return "\n".join(lines) + "\n"


def check_cells() -> list:
    """Self-check: every expansion computes the cell's function. Returns [(name, pins, area)]."""
    report = []
    for c in ALL_CELLS.values():
        b = Builder()
        leaves = [b.leaf(p) for p in c.pins]
        node = c.expand(b, *leaves)
        for bits in product((0, 1), repeat=len(leaves)):
            got = b.evaluate(node, dict(zip(leaves, bits)))
            if got != c.truth(*bits):
                raise AssertionError(f"cell {c.name}: expansion is wrong for inputs {bits}")
        report.append((c.name, len(c.pins), c.area()))
    return report
