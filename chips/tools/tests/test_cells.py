"""tapc.cells: every cell expansion computes its function, and the liberty file prices cells in NAND records."""
import itertools
import re

import pytest

from tapc import cells


def test_every_expansion_matches_its_truth_table():
    report = {name: (n_pins, area) for name, n_pins, area in cells.check_cells()}
    assert len(report) == len(cells.ALL_CELLS) >= 29
    # the costs the mapper is told: these are the textbook minimum two-input-NAND counts
    want = {"INV": 1, "NAND2": 1, "AND2": 2, "OR2": 3, "NOR2": 4, "XOR2": 4, "XNOR2": 5, "MUX2": 4, "BUF": 0,
            "ANDN2": 3, "ORN2": 2, "NAND3": 3, "AO21": 3, "AOI21": 4, "OAI21": 4, "OA21": 5, "MAJ3": 6, "XOR3": 8}
    assert {k: report[k][1] for k in want} == want


def test_sharing_gives_the_classic_adders():
    """XOR2 + its neighbours share NANDs after expansion: a half adder is 5 NANDs, a full adder is 9."""
    b = cells.Builder()
    a, c, ci = b.leaf("a"), b.leaf("b"), b.leaf("ci")
    before = len(b.fa)
    s, carry = b.xor2(a, c), b.and2(a, c)
    assert len(b.fa) - before == 5
    b2 = cells.Builder()
    a, c, ci = b2.leaf("a"), b2.leaf("b"), b2.leaf("ci")
    before = len(b2.fa)
    p = b2.xor2(a, c)
    total = b2.xor2(p, ci)
    cout = b2.nand(b2.nand(a, c), b2.nand(p, ci))
    assert len(b2.fa) - before == 9
    for bits in itertools.product((0, 1), repeat=3):
        v = dict(zip((a, c, ci), bits))
        assert b2.evaluate(total, v) == sum(bits) & 1 and b2.evaluate(cout, v) == sum(bits) >> 1


def test_constant_folding_rules():
    b = cells.Builder()
    x, y = b.leaf("x"), b.leaf("y")
    n = len(b.fa)
    assert b.nand(cells.C0, x) == cells.C1 and b.nand(x, cells.C0) == cells.C1
    assert b.inv(cells.C0) == cells.C1 and b.inv(cells.C1) == cells.C0
    nx = b.nand(cells.C1, x)                                  # NAND(1, x) = INV(x): one node
    assert b.is_inv(nx) and b.nand(x, x) == nx and b.inv(x) == nx
    assert b.inv(nx) == x                                     # INV(INV(x)) = x: no node
    assert b.nand(x, nx) == cells.C1                          # NAND(x, INV(x)) = 1
    assert b.nand(x, y) == b.nand(y, x)                       # commutative: one node
    assert b.xor2(x, cells.C0) == x and b.xor2(x, cells.C1) == nx and b.xor2(x, x) == cells.C0
    assert b.mux2(x, y, cells.C0) == x and b.mux2(x, y, cells.C1) == y
    assert b.and_n([]) == cells.C1 and b.or_n([]) == cells.C0 and b.and_n([x]) == x
    # nodes ever created: INV(x), NAND(x, y), and INV(y) as a temporary inside mux2(x, y, 1). A temporary that
    # nothing ends up using is dropped by the packer (test_pack.check_layout asserts no dead record survives).
    assert len(b.fa) - n == 3
    r = b.raw_nand(cells.C1, cells.C1)                        # raw nodes are not folded
    assert b.is_nand(r) and b.evaluate(r, {}) == 0


def test_covers():
    b = cells.Builder()
    ins = [b.leaf(f"i{k}") for k in range(3)]
    cases = [
        ([("1--", "1"), ("-11", "1")], lambda a, c, d: a | (c & d)),
        ([("11-", "0"), ("--1", "0")], lambda a, c, d: 1 - ((a & c) | d)),
        ([("000", "1")], lambda a, c, d: int(a + c + d == 0)),
        ([("---", "1")], lambda a, c, d: 1),
        ([], lambda a, c, d: 0),
    ]
    for cover, f in cases:
        node = b.cover(ins, cover)
        for bits in itertools.product((0, 1), repeat=3):
            assert b.evaluate(node, dict(zip(ins, bits))) == f(*bits), (cover, bits)
    with pytest.raises(ValueError):
        b.cover(ins, [("1--", "1"), ("0--", "0")])


def test_liberty_text_is_deterministic_and_priced_in_nands():
    for lib, names in cells.LIBRARIES.items():
        text = cells.liberty_text(lib)
        assert text == cells.liberty_text(lib)
        found = re.findall(r"cell\((\w+)\) \{\n    area : ([\d.]+);", text)
        assert [n for n, _ in found] == names
        assert len(names) >= 3                                # ABC refuses fewer than three cell classes
        for n, area in found:
            c = cells.LIBERTY_CELLS[n]
            assert float(area) == (c.liberty_area if c.liberty_area is not None else c.area())
        assert text.count("direction : output") == len(names)
    assert set(cells.LIBRARIES["nand"]) == {"BUF", "INV", "NAND2"}
