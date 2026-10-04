"""BLIF -> TAP-20 packing: layout rules, function preserved, and the unpack round trip (no Yosys needed here)."""
import itertools
import json
import random
import re

import pytest

from tapc import blif, cells, pack, sim, unpack
from tapc import netlist as N


# ---------------------------------------------------------------------------------------------- an independent BLIF evaluator

def eval_blif(model, values):
    """Evaluate every net of a parsed BLIF model from {input net: 0/1}. Uses each cell's truth function
    (cells.Cell.truth), never the NAND expansion the packer uses."""
    driver = {}
    for g in model.gates:
        c = cells.ALL_CELLS[g.cell]
        driver[g.pins[c.out]] = ("gate", g, c)
    for nm in model.names:
        driver[nm.output] = ("names", nm)
    for src, dst in model.conns:
        driver[dst] = ("conn", src)
    memo = dict(values)

    def get(net):
        stack = [net]
        while stack:
            n = stack[-1]
            if n in memo:
                stack.pop()
                continue
            d = driver[n]
            deps = ([d[1].pins[p] for p in d[2].pins] if d[0] == "gate" else list(d[1].inputs) if d[0] == "names" else [d[1]])
            todo = [x for x in deps if x not in memo]
            if todo:
                stack.extend(todo)
                continue
            if d[0] == "gate":
                memo[n] = d[2].truth(*[memo[x] for x in deps])
            elif d[0] == "conn":
                memo[n] = memo[d[1]]
            else:
                nm = d[1]
                hit = any(all(c == "-" or int(c) == memo[i] for c, i in zip(pat, nm.inputs)) for pat, _ in nm.cover)
                on_set = not nm.cover or nm.cover[0][1] == "1"
                memo[n] = int(hit) if on_set else int(not hit)
            stack.pop()
        return memo[net]
    return get


def check_function(model, p):
    """Packed netlist == BLIF on every (s, x)."""
    nl = p.netlist
    S, NI, NO = nl.n_state, nl.n_in, nl.n_out
    s_nets = blif.port_bits(model.inputs, "s")
    x_nets = blif.port_bits(model.inputs, "x")
    ns_nets = blif.port_bits(model.outputs, "ns")
    y_nets = blif.port_bits(model.outputs, "y")
    combos = list(itertools.product(range(1 << S), range(1 << NI)))
    got_ns, got_y = sim.step_many_int(nl, [c[0] for c in combos], [c[1] for c in combos])
    for (s, x), g_ns, g_y in zip(combos, got_ns, got_y):
        vals = {n: (s >> i) & 1 for i, n in enumerate(s_nets)}
        vals.update({n: (x >> i) & 1 for i, n in enumerate(x_nets)})
        get = eval_blif(model, vals)
        assert g_ns == sum(get(n) << i for i, n in enumerate(ns_nets)), (s, x)
        assert g_y == sum(get(n) << j for j, n in enumerate(y_nets)), (s, x)


def check_layout(p):
    """The documented layout rules."""
    nl = p.netlist
    S, NO = nl.n_state, nl.n_out
    base = 2 + nl.n_in
    assert nl.latches_first and nl.is_flat
    assert all(e.op == N.LATCH for e in nl.elements[:S]) and all(e.op == N.NAND for e in nl.elements[S:])
    assert nl.n_nand >= NO                                    # every output is its own NAND record
    assert p.manifest["nNand"] == nl.n_nand and p.manifest["nLatch"] == S == p.manifest["nState"]
    assert p.manifest["bytes"] == len(p.data) == 7 * nl.n_nand + 4 * S
    assert p.manifest["keccak256"] == "0x" + N.keccak256(p.data).hex()
    # nothing is dead: every NAND reaches an output pin or a latch d
    live = bytearray(nl.n_signals)
    stack = list(nl.output_signals()) + [e.ins[0] for e in nl.elements[:S]]
    while stack:
        s = stack.pop()
        if live[s]:
            continue
        live[s] = 1
        if s >= base and nl.elements[s - base].op == N.NAND:
            stack.extend(nl.elements[s - base].ins)
    assert all(live[e.first_out] for e in nl.elements if e.op == N.NAND)
    # the body holds no two identical NANDs and no double inverter
    body = nl.elements[S:len(nl.elements) - NO]
    keys = [tuple(sorted(e.ins)) for e in body]
    assert len(set(keys)) == len(keys)
    inv_of = {e.first_out: e.ins[0] for e in body if e.ins[0] == e.ins[1]}
    assert not any(e.ins[0] == e.ins[1] and e.ins[0] in inv_of for e in body)
    # no constant operand survives in the body
    assert not any(i < 2 for e in body for i in e.ins)


def verilog_to_bytes(text, n_in, n_state):
    """Rebuild TAP-20 bytes from `tapc unpack` output (test-only reader of that exact format)."""
    def sig(tok):
        if tok == "1'b0":
            return 0
        if tok == "1'b1":
            return 1
        m = re.fullmatch(r"x\[(\d+)\]", tok)
        if m:
            return 2 + int(m.group(1))
        m = re.fullmatch(r"s\[(\d+)\]", tok)
        if m:
            return 2 + n_in + int(m.group(1))
        return int(re.fullmatch(r"n(\d+)", tok).group(1))
    nands, d_of, outs = [], {}, {}
    for line in text.splitlines():
        m = re.fullmatch(r"\s*wire (n\d+); assign \1 = ~\((\S+) & (\S+)\);", line)
        if m:
            nands.append((sig(m.group(1)), sig(m.group(2)), sig(m.group(3))))
            continue
        m = re.fullmatch(r"\s*assign ns\[(\d+)\] = (\S+);", line)
        if m:
            d_of[int(m.group(1))] = sig(m.group(2))
            continue
        m = re.fullmatch(r"\s*assign y\[(\d+)\] = (\S+);", line)
        if m:
            outs[int(m.group(1))] = sig(m.group(2))
    recs = [N.latch(d_of[i]) for i in range(n_state)]
    nxt = 2 + n_in + n_state
    for s, a, b in nands:
        assert s == nxt
        recs.append(N.nand(a, b))
        nxt += 1
    assert [outs[j] for j in range(len(outs))] == list(range(nxt - len(outs), nxt))
    return N.encode(recs)


# ---------------------------------------------------------------------------------------------- hand-written cases

ALIASES = """
.model t_core
.inputs s[0] s[1] x[0] x[1]
.outputs ns[0] ns[1] y[0] y[1] y[2] y[3] y[4] y[5]
.names $false
.names $true
1
.names $undef
.gate NAND2 A=x[0] B=x[1] Y=n1
.gate INV A=n1 Y=n2
.names x[0] y[0]
1 1
.names s[1] y[1]
1 1
.names $false y[2]
1 1
.names $true y[3]
1 1
.names n1 y[4]
1 1
.names n2 y[5]
1 1
.names x[1] ns[0]
1 1
.names n2 ns[1]
1 1
.end
"""


def test_aliases_constants_and_native_outputs():
    model = blif.parse(ALIASES)
    p = pack.pack_model(model)
    assert p.name == "t"
    nl = p.netlist
    check_layout(p)
    check_function(model, p)
    lay = p.manifest["layout"]
    # y0 and y1 are wires from an input / a state bit: one shared-able inverter each plus the output record
    # y2, y3 are constants: one record each. y4 = NAND(x0, x1) feeds only y5 = INV(y4), which is a later pin,
    # so both sit in the output region with no duplicate.
    assert (lay["outputBuffers"], lay["outputConstants"], lay["outputDuplicates"]) == (2, 2, 0)
    assert nl.n_nand == 8 and nl.n_latch == 2
    out0 = nl.n_signals - 6
    recs = [(e.op, e.ins) for e in nl.elements]
    assert recs[0] == (N.LATCH, (3,))                         # ns[0] = x[1]: d points straight at the input
    assert recs[1] == (N.LATCH, (out0 + 5,))                  # ns[1] = y[5]: d points forward into the outputs
    assert recs[-4] == (N.NAND, (1, 1)) and recs[-3] == (N.NAND, (0, 0))          # constants 0 and 1
    assert recs[-2] == (N.NAND, (2, 3))                       # y4 = NAND(x0, x1), in place
    assert recs[-1] == (N.NAND, (out0 + 4, out0 + 4))         # y5 = INV(y4), reading the output before it
    assert p.stats["undefUsed"] == 0


DUPLICATES = """
.model d_core
.inputs x[0] x[1] x[2]
.outputs y[0] y[1] y[2] y[3]
.gate NAND2 A=x[0] B=x[1] Y=a
.gate NAND2 A=a B=x[2] Y=b
.gate INV A=b Y=c
.names c y[0]
1 1
.names b y[1]
1 1
.names a y[2]
1 1
.names a y[3]
1 1
.end
"""


def test_duplicates_only_when_unavoidable():
    """c (pin 0) reads b (pin 1): b cannot sit after its reader, so b stays in the body and is repeated once.
    a feeds b in the body, so it is repeated at pins 2 and 3. c itself is in place."""
    model = blif.parse(DUPLICATES)
    p = pack.pack_model(model)
    check_layout(p)
    check_function(model, p)
    nl = p.netlist
    assert nl.n_nand == 2 + 4                                 # body: a, b; outputs: c, b', a', a''
    assert p.manifest["layout"]["outputDuplicates"] == 3
    assert [e.ins for e in nl.elements] == [(2, 3), (4, 5), (6, 6), (4, 5), (2, 3), (2, 3)]


def test_forward_order_needs_no_duplicate():
    text = DUPLICATES.replace(".names c y[0]", ".names a y[0]").replace(".names a y[2]", ".names c y[2]") \
                     .replace(".names a y[3]\n1 1\n", ".names x[0] y[3]\n0 1\n")
    model = blif.parse(text)                                  # y0 = a, y1 = b, y2 = c, y3 = NOT x0
    p = pack.pack_model(model)
    check_layout(p)
    check_function(model, p)
    assert p.netlist.n_nand == 4 and p.manifest["layout"]["outputDuplicates"] == 0
    assert [e.ins for e in p.netlist.elements] == [(2, 3), (4, 5), (6, 6), (2, 2)]


def test_names_forms_from_plain_write_blif():
    """What `abc -g NAND` + write_blif (no -gates) produces, plus off-set covers and .conn."""
    text = """
.model n_core
.inputs x[0] x[1] x[2]
.outputs y[0] y[1] y[2] y[3] y[4]
.names x[0] x[1] t
0- 1
-0 1
.names t u
0 1
.names x[2] x[1] x[0] m
1-0 1
-11 1
.names x[0] x[1] x[2] off
11- 0
--1 0
.conn u y[0]
.names t y[1]
1 1
.names m y[2]
1 1
.names off y[3]
1 1
.subckt $_XOR_ A=x[0] B=x[2] Y=y[4]
.end
"""
    model = blif.parse(text)
    p = pack.pack_model(model)
    check_layout(p)
    check_function(model, p)
    planes, n = sim.exhaustive_planes(3)
    _, out = sim.step_planes(p.netlist, [], planes, n)
    vals = sim.from_planes(out, n)
    for v in range(8):
        x0, x1, x2 = v & 1, (v >> 1) & 1, (v >> 2) & 1
        want = [x0 & x1, 1 - (x0 & x1), (x1 if x0 else x2), 1 - ((x0 & x1) | x2), x0 ^ x2]
        assert vals[v] == sum(b << j for j, b in enumerate(want)), v


def test_pin_names_and_manifest(tmp_path):
    model = blif.parse(ALIASES)
    pins = {"inputs": [{"name": "en", "lsb": 0, "width": 1}],
            "outputs": [{"name": "word", "lsb": 0, "width": 4}, {"name": "ok", "lsb": 5, "width": 1}],
            "state": [{"name": "st", "lsb": 0, "width": 2}]}
    p = pack.pack_model(model, name="demo", pins=pins)
    m = p.manifest
    assert [i["name"] for i in m["inputs"]] == ["en", "x[1]"]
    assert [o["name"] for o in m["outputs"]] == ["word[0]", "word[1]", "word[2]", "word[3]", "y[4]", "ok"]
    assert [l["name"] for l in m["latches"]] == ["st[0]", "st[1]"]
    assert [(l["bit"], l["record"], l["signal"]) for l in m["latches"]] == [(0, 0, 4), (1, 1, 5)]
    assert [o["signal"] for o in m["outputs"]] == list(p.netlist.output_signals())
    assert m["tapeout"] == {"nIn": 2, "nOut": 6, "burnNand": 8, "burnLatch": 2}
    paths = pack.write_outputs(p, str(tmp_path))
    assert open(paths["tap"], "rb").read() == p.data
    assert open(paths["hex"]).read() == "0x" + p.data.hex() + "\n"
    assert json.load(open(paths["manifest"])) == m
    mp = json.load(open(paths["map"]))
    assert mp["format"] == "tapc-map/1" and mp["keccak256"] == m["keccak256"]
    assert len(mp["records"]) == p.netlist.n_nand + p.netlist.n_latch
    assert [r["op"] for r in mp["records"][:2]] == ["LATCH", "LATCH"]
    assert [r.get("out") for r in mp["records"][-6:]] == [0, 1, 2, 3, 4, 5]
    assert mp["records"][-1]["name"] == "ok" and mp["records"][0]["name"] == "st[0]"
    assert set(mp["groups"]) <= {"ns.st", "y.word", "y.ok", "y.y"}
    for r in mp["records"]:
        assert r["block"] is None                             # a flat ABC netlist carries no instance names
        assert all(0 <= g < len(mp["groups"]) for g in r["cone"])
    with pytest.raises(pack.PackError, match="named twice"):
        pack.pack_model(model, pins={"inputs": [{"name": "a", "lsb": 0, "width": 2}, {"name": "b", "lsb": 1, "width": 1}]})
    with pytest.raises(pack.PackError, match="does not fit"):
        pack.pack_model(model, pins={"outputs": [{"name": "a", "lsb": 4, "width": 3}]})


def test_block_names_are_recovered_from_hierarchical_nets():
    text = """
.model h_core
.inputs x[0] x[1]
.outputs y[0] y[1]
.gate NAND2 A=x[0] B=x[1] Y=u_add.$abc$12$new_n3
.gate INV A=u_add.$abc$12$new_n3 Y=u_top.u_cmp.$abc$40$new_n9
.gate NAND2 A=u_top.u_cmp.$abc$40$new_n9 B=x[0] Y=$abc$77$new_n5
.names u_top.u_cmp.$abc$40$new_n9 y[0]
1 1
.names $abc$77$new_n5 y[1]
1 1
.end
"""
    p = pack.pack_model(blif.parse(text))
    # records: n3 in the body, then the two outputs in place (n9 feeds only the later pin)
    assert [r["block"] for r in p.map["records"]] == ["u_add", "u_top.u_cmp", None]
    assert p.map["blocks"] == ["u_add", "u_top.u_cmp"]
    assert [r["level"] for r in p.map["records"]] == [1, 2, 3]


def test_errors():
    with pytest.raises(blif.BlifError, match="latch"):
        blif.parse(".model m\n.inputs x[0] c\n.outputs y[0]\n.latch x[0] y[0] re c 0\n.end\n")
    with pytest.raises(pack.PackError, match="unknown cell"):
        pack.pack_blif_text(".model m\n.inputs x[0]\n.outputs y[0]\n.gate DFF D=x[0] Q=y[0]\n.end\n")
    with pytest.raises(pack.PackError, match="unexpected ports"):
        pack.pack_blif_text(".model m\n.inputs x[0] clk\n.outputs y[0]\n.gate INV A=x[0] Y=y[0]\n.end\n")
    with pytest.raises(pack.PackError, match="bits but"):
        pack.pack_blif_text(".model m\n.inputs x[0] s[0] s[1]\n.outputs y[0] ns[0]\n.gate INV A=x[0] Y=y[0]\n"
                            ".gate INV A=s[0] Y=ns[0]\n.end\n")
    with pytest.raises(pack.PackError, match="no driver"):
        pack.pack_blif_text(".model m\n.inputs x[0]\n.outputs y[0]\n.gate INV A=ghost Y=y[0]\n.end\n")
    with pytest.raises(pack.PackError, match="more than one driver"):
        pack.pack_blif_text(".model m\n.inputs x[0]\n.outputs y[0]\n.gate INV A=x[0] Y=y[0]\n.gate INV A=x[0] Y=y[0]\n.end\n")
    with pytest.raises(pack.PackError, match="loop"):
        pack.pack_blif_text(".model m\n.inputs x[0]\n.outputs y[0]\n.gate NAND2 A=x[0] B=b Y=a\n"
                            ".gate INV A=a Y=b\n.names a y[0]\n1 1\n.end\n")
    with pytest.raises(pack.PackError, match="--nin"):
        pack.pack_blif_text(".model m\n.inputs x[0]\n.outputs y[0]\n.gate INV A=x[0] Y=y[0]\n.end\n", n_in=96)
    with pytest.raises(pack.PackError, match="no output port"):
        pack.pack_blif_text(".model m\n.inputs s[0]\n.outputs ns[0]\n.gate INV A=s[0] Y=ns[0]\n.end\n")
    # custom port names
    p = pack.pack_blif_text(".model m\n.inputs a[0] q\n.outputs z[0] qn\n.gate NAND2 A=a[0] B=q Y=z[0]\n"
                            ".names z[0] qn\n1 1\n.end\n", state=("q", "qn"), in_port="a", out_port="z")
    assert (p.netlist.n_in, p.netlist.n_out, p.netlist.n_state, p.netlist.n_nand) == (1, 1, 1, 1)
    with pytest.raises(blif.BlifError, match="not 0.."):
        blif.port_bits(["x[0]", "x[2]"], "x")


def test_undefined_nets_are_an_error_unless_allowed():
    text = (".model u_core\n.inputs x[0]\n.outputs y[0] y[1]\n.names $undef\n.gate INV A=x[0] Y=y[0]\n"
            ".names $undef y[1]\n1 1\n.end\n")
    with pytest.raises(pack.PackError, match="undefined"):
        pack.pack_blif_text(text)
    p = pack.pack_blif_text(text, allow_undef=True)
    assert p.stats["undefUsed"] == 1 and [e.ins for e in p.netlist.elements] == [(2, 2), (1, 1)]
    # an $undef that nothing uses is fine
    assert pack.pack_blif_text(".model m\n.inputs x[0]\n.outputs y[0]\n.names $undef\n.gate INV A=x[0] Y=y[0]\n.end\n")


def test_shape_check():
    recs = [N.latch(100 + i) for i in range(64)] + [N.nand(2 + i % 96, 98 + i % 64) for i in range(200)]
    nl = N.check(N.encode(recs), 96, 112)
    assert N.shape_violations(nl, "covenant-v1") == []
    assert N.shape_violations(N.check(N.encode(recs), 96, 100)) == ["nOut is 100, must be 112"]
    no_state = N.check(N.encode([N.nand(2, 3)] * 112), 96, 112)
    assert N.shape_violations(no_state) == ["nState is 0, must be 1..256"]
    late = N.check(N.encode([N.nand(2, 3)] * 112 + [N.latch(5)]), 96, 112)
    assert any("LATCH records must be" in v for v in N.shape_violations(late))
    big = N.check(N.encode([N.latch(2)] + [N.nand(2, 3)] * 3500), 96, 112)
    v = N.shape_violations(big)
    assert any("gates, more than 3400" in x for x in v) and any("bytes, more than 24000" in x for x in v)
    wide = N.check(N.encode([N.latch(2)] * 257 + [N.nand(2, 3)] * 112), 96, 112)
    assert N.shape_violations(wide) == ["nState is 257, must be 1..256"]


def test_scalar_ports_and_no_inputs():
    p = pack.pack_blif_text(".model c_core\n.inputs s\n.outputs ns y\n.gate INV A=s Y=ns\n.names ns y\n1 1\n.end\n")
    nl = p.netlist
    assert (nl.n_in, nl.n_out, nl.n_state, nl.n_nand) == (0, 1, 1, 1)         # a divide-by-two: 1 NAND, 1 LATCH
    assert [e.ins for e in nl.elements] == [(3,), (2, 2)]
    assert [r["outputs"] for r in sim.run_beats(nl, [b""] * 4)] == ["01", "00", "01", "00"]


# ---------------------------------------------------------------------------------------------- random models

LIB = [c for c in cells.LIBERTY_CELLS.values()]


def random_blif(rng):
    S, NI, NO = rng.randint(0, 4), rng.randint(0, 5), rng.randint(1, 6)
    if S + NI == 0:
        NI = 1
    ins = [f"s[{i}]" for i in range(S)] + [f"x[{i}]" for i in range(NI)]
    outs = [f"ns[{i}]" for i in range(S)] + [f"y[{j}]" for j in range(NO)]
    lines = [".model r_core", ".inputs " + " ".join(ins), ".outputs " + " ".join(outs),
             ".names $false", ".names $true", "1", ".names $undef"]
    nets = list(ins) + ["$false", "$true"]
    free_outs = list(outs)
    rng.shuffle(free_outs)
    n_gates = rng.randint(0, 45)
    for k in range(n_gates):
        # some gates drive an output port directly, as Yosys does; such a net may still feed later gates
        name = free_outs.pop() if free_outs and rng.random() < 0.12 else f"$abc$1$new_n{k}"
        r = rng.random()
        if r < 0.75:
            c = rng.choice(LIB)
            args = " ".join(f"{p}={rng.choice(nets)}" for p in c.pins)
            lines.append(f".gate {c.name} {args} {c.out}={name}")
        elif r < 0.95:
            k_in = rng.randint(1, 3)
            srcs = [rng.choice(nets) for _ in range(k_in)]
            polarity = rng.choice("01")
            cubes = {"".join(rng.choice("01-") for _ in range(k_in)) for _ in range(rng.randint(1, 3))}
            lines.append(f".names {' '.join(srcs)} {name}")
            lines += [f"{c} {polarity}" for c in sorted(cubes)]
        else:
            lines.append(f".conn {rng.choice(nets)} {name}")
        nets.append(name)
    for o in free_outs:                                       # the rest are aliases of anything at all
        src = rng.choice(nets)
        if rng.random() < 0.5:
            lines += [f".names {src} {o}", "1 1"]
        else:
            lines.append(f".conn {src} {o}")
        nets.append(o)
    lines.append(".end")
    return "\n".join(lines) + "\n"


def test_random_models_pack_correctly_and_unpack_round_trips():
    rng = random.Random(2026)
    stats = {"dup": 0, "buf": 0, "const": 0, "latch": 0, "nand": 0}
    for _ in range(400):
        text = random_blif(rng)
        model = blif.parse(text)
        p = pack.pack_model(model)
        check_layout(p)
        check_function(model, p)
        nl = p.netlist
        # unpack -> Verilog -> records -> the same bytes
        v = unpack.to_verilog(nl, module="r_tap")
        assert verilog_to_bytes(v, nl.n_in, nl.n_state) == p.data
        assert pack.pack_model(blif.parse(text)).data == p.data                 # deterministic
        lay = p.manifest["layout"]
        stats["dup"] += lay["outputDuplicates"]
        stats["buf"] += lay["outputBuffers"]
        stats["const"] += lay["outputConstants"]
        stats["latch"] += nl.n_latch
        stats["nand"] += nl.n_nand
    assert min(stats.values()) > 50, stats                   # every layout case was actually exercised


def test_unpack_shapes():
    comb = N.check(N.encode([N.nand(2, 3)]), 2, 1)
    v = unpack.to_verilog(comb, module="m")
    assert "module m(input [1:0] x, output [0:0] y);" in v and " s" not in v.split("\n")[3]
    assert "wire n4; assign n4 = ~(x[0] & x[1]);" in v and "assign y[0] = n4;" in v
    no_in = N.check(N.encode([N.latch(3), N.nand(2, 2)]), 0, 1)
    v = unpack.to_verilog(no_in, module="m")
    assert "module m(input [0:0] s, output [0:0] ns, output [0:0] y);" in v
    assert "assign n3 = ~(s[0] & s[0]);" in v and "assign ns[0] = n3;" in v
    consts = N.check(N.encode([N.nand(0, 1)]), 0, 1)
    assert "~(1'b0 & 1'b1)" in unpack.to_verilog(consts)
    late = N.check(N.encode([N.nand(2, 2), N.latch(3), N.nand(4, 3)]), 1, 1)     # latch not first: still fine
    v = unpack.to_verilog(late)
    assert "assign n5 = ~(s[0] & n3);" in v and "assign ns[0] = n3;" in v
    sub = N.check(N.encode([N.nand(2, 2)]), 1, 1)
    with_ref = N.check(N.encode([N.ref(bytes(20), 1, [2], 1)]), 1, 1, lambda c, i: sub)
    with pytest.raises(unpack.UnpackError):
        unpack.to_verilog(with_ref)
    assert "REF" in unpack.listing(with_ref.data, 1, 1) and "; output 0" in unpack.listing(with_ref.data, 1, 1)
