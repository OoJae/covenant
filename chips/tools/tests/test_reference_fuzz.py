"""tapc.sim and tapc.netlist against TAP-20's MIT reference implementation (chips/vendor/tap-20/reference.py)
on thousands of random netlists: NAND, LATCH with forward d, REF with state, nested REF."""
import random

import pytest

from tapc import netlist as N
from tapc import sim

CPU = bytes(19) + b"\x5a"
N_FLAT = 2500
N_WITH_REF = 1500
VECTORS_PER_NETLIST = 6


def gen(rng, n_in, n_elems, subs=None, p_latch=0.2, p_ref=0.0):
    """A random well-formed netlist as (records, n_out). `subs` is a list of (cid, n_in, n_out)."""
    recs = []
    nxt = 2 + n_in
    latch_at = []
    for _ in range(n_elems):
        r = rng.random()
        if subs and r < p_ref:
            cid, s_in, s_out = rng.choice(subs)
            recs.append(N.ref(CPU, cid, [rng.randrange(nxt) for _ in range(s_in)], s_out))
            nxt += s_out
        elif r < p_ref + p_latch:
            latch_at.append(len(recs))
            recs.append(None)
            nxt += 1
        else:
            # bias towards recent signals so that deep logic appears, with constants and inputs mixed in
            a = rng.randrange(nxt) if rng.random() < 0.5 else max(0, nxt - 1 - rng.randrange(min(nxt, 6)))
            b = rng.randrange(nxt) if rng.random() < 0.5 else max(0, nxt - 1 - rng.randrange(min(nxt, 6)))
            recs.append(N.nand(a, b))
            nxt += 1
    for i in latch_at:
        recs[i] = N.latch(rng.randrange(nxt))               # d may point anywhere, including forward
    produced = nxt - 2 - n_in
    return recs, rng.randint(1, produced)


def ref_circuit(R, nl):
    """The reference Circuit for a tapc Netlist (loaded independently from the same bytes)."""
    subs = {k: ref_circuit(R, v) for k, v in nl.subs.items()}
    return R.load(nl.data, nl.n_in, nl.n_out, lambda cpu, cid: subs.get((cpu, cid)))


def compare(R, rng, nl, n_vec=VECTORS_PER_NETLIST):
    c = ref_circuit(R, nl)
    assert (c.n_state, c.n_gates, c.n_signals) == (nl.n_state, nl.gate_count, nl.n_signals)
    assert R.encode(R.decode(nl.data, nl.n_in)) == nl.data == N.encode(nl.elements)
    states = [[rng.getrandbits(1) for _ in range(nl.n_state)] for _ in range(n_vec)]
    inputs = [[rng.getrandbits(1) for _ in range(nl.n_in)] for _ in range(n_vec)]
    want = [R.beat(c, s, x) for s, x in zip(states, inputs)]
    for (s, x), (w_ns, w_out) in zip(zip(states, inputs), want):
        ns, out = sim.beat(nl, s, x)                         # scalar, bit lists
        assert (ns, out) == (w_ns, w_out)
        # packed bytes with garbage padding and an extra byte: must be read leniently, like the contract
        junk_s = bytearray(R.pack(s) + b"\xa5")
        junk_x = bytearray(R.pack(x) + b"\x5a")
        if nl.n_state % 8:
            junk_s[len(junk_s) - 2] |= (0xFF << (nl.n_state % 8)) & 0xFF
        if nl.n_in % 8:
            junk_x[len(junk_x) - 2] |= (0xFF << (nl.n_in % 8)) & 0xFF
        ns_b, out_b = sim.step(nl, None, None, bytes(junk_s), bytes(junk_x))
        assert (ns_b, out_b) == (R.pack(w_ns), R.pack(w_out))
    got = sim.step_many(nl, [R.pack(s) for s in states], [R.pack(x) for x in inputs])     # bit-sliced
    assert got == [(R.pack(a), R.pack(b)) for a, b in want]


def test_flat_netlists_against_reference(reference):
    R = reference
    rng = random.Random(0xC0FFEE)
    total_gates = 0
    for _ in range(N_FLAT):
        n_in = rng.choice([0, 0, 1, 2, 3, 5, 8, 13, 17])
        recs, n_out = gen(rng, n_in, rng.randint(1, 90), p_latch=rng.choice([0.0, 0.1, 0.3, 0.6]))
        nl = N.check(N.encode(recs), n_in, n_out)
        total_gates += nl.gate_count
        compare(R, rng, nl)
    assert total_gates > 50_000


def test_netlists_with_ref_against_reference(reference):
    R = reference
    rng = random.Random(0xBEEF)
    table = {}

    def resolve(cpu, cid):
        return table.get((cpu, cid)) if cpu == CPU else None

    seen_state_ref = seen_nested = 0
    for round_ in range(N_WITH_REF // 50):
        table.clear()
        subs = []
        for cid in range(1, 7):                              # level-1 library: flat, some with state
            s_in, n_el = rng.randint(0, 4), rng.randint(1, 12)
            recs, s_out = gen(rng, s_in, n_el, p_latch=rng.choice([0.0, 0.4]))
            table[(CPU, cid)] = N.check(N.encode(recs), s_in, min(s_out, 4))
            subs.append((cid, s_in, min(s_out, 4)))
        for cid in range(7, 11):                             # level-2: circuits that REF level-1 circuits
            s_in = rng.randint(0, 4)
            recs, s_out = gen(rng, s_in, rng.randint(1, 10), subs=subs[:6], p_latch=0.2, p_ref=0.4)
            table[(CPU, cid)] = N.check(N.encode(recs), s_in, min(s_out, 4), resolve)
            subs.append((cid, s_in, min(s_out, 4)))
        for _ in range(50):
            n_in = rng.choice([0, 1, 3, 6])
            recs, n_out = gen(rng, n_in, rng.randint(1, 30), subs=subs, p_latch=0.2, p_ref=0.3)
            nl = N.check(N.encode(recs), n_in, n_out, resolve)
            if nl.n_ref and any(s.n_state for s in nl.subs.values()):
                seen_state_ref += 1
            if nl.ref_depth >= 2:
                seen_nested += 1
            compare(R, rng, nl, n_vec=4)
    assert seen_state_ref > 200 and seen_nested > 200


def test_accept_reject_agrees_with_reference_on_mutations(reference):
    """Random damage to well-formed netlists: both implementations must make the same accept / reject call,
    and agree on the result when they accept."""
    R = reference
    rng = random.Random(77)
    sub = N.check(N.encode([N.latch(5), N.nand(2, 3), N.nand(4, 2)]), 1, 2)
    sub_r = R.load(sub.data, 1, 2)

    def resolve(cpu, cid):
        return sub if (cpu, cid) == (CPU, 1) else None

    def resolve_r(cpu, cid):
        return sub_r if (cpu, cid) == (CPU, 1) else None

    accepted = rejected = 0
    for _ in range(4000):
        n_in = rng.choice([0, 1, 2, 4])
        recs, n_out = gen(rng, n_in, rng.randint(1, 14), subs=[(1, 1, 2)], p_latch=0.25, p_ref=0.15)
        data = bytearray(N.encode(recs))
        kind = rng.randrange(6)
        if kind == 0 and data:
            data[rng.randrange(len(data))] ^= 1 << rng.randrange(8)
        elif kind == 1 and data:
            del data[rng.randrange(len(data)):]
        elif kind == 2:
            data += bytes(rng.getrandbits(8) for _ in range(rng.randint(1, 8)))
        elif kind == 3:
            n_out = rng.choice([0, n_out + rng.randint(1, 40)])
        elif kind == 4:
            n_in = max(0, n_in + rng.choice([-2, -1, 1, 2]))
        data = bytes(data)
        try:
            c = R.load(data, n_in, n_out, resolve_r)
        except R.IllFormed:
            c = None
        try:
            nl = N.check(data, n_in, n_out, resolve)
        except N.IllFormed:
            nl = None
        assert (c is None) == (nl is None), (data.hex(), n_in, n_out)
        if nl is None:
            rejected += 1
            continue
        accepted += 1
        s = [rng.getrandbits(1) for _ in range(nl.n_state)]
        x = [rng.getrandbits(1) for _ in range(nl.n_in)]
        assert sim.beat(nl, s, x) == R.beat(c, s, x)
    assert accepted > 500 and rejected > 500


def test_bit_sliced_equals_scalar_on_wide_batches(reference):
    """10,000 vectors in one pass equal 10,000 scalar beats (on a 400-element netlist with 37 latches)."""
    rng = random.Random(5)
    recs, n_out = gen(rng, 23, 400, p_latch=0.1)
    nl = N.check(N.encode(recs), 23, n_out)
    st = [rng.getrandbits(nl.n_state) for _ in range(10_000)]
    xi = [rng.getrandbits(23) for _ in range(10_000)]
    ns, out = sim.step_many_int(nl, st, xi)
    for k in range(0, 10_000, 7):
        a, b = sim.step(nl, None, None, sim.int_to_bytes(st[k], nl.n_state), sim.int_to_bytes(xi[k], 23))
        assert (int.from_bytes(a, "little"), int.from_bytes(b, "little")) == (ns[k], out[k])
    c = ref_circuit(reference, nl)
    for k in range(0, 10_000, 501):
        w_ns, w_out = reference.beat(c, sim.unpack_bits(sim.int_to_bytes(st[k], nl.n_state), nl.n_state),
                                     sim.unpack_bits(sim.int_to_bytes(xi[k], 23), 23))
        assert sim.pack_bits(w_ns) == sim.int_to_bytes(ns[k], nl.n_state)
        assert sim.pack_bits(w_out) == sim.int_to_bytes(out[k], nl.n_out)


def test_planes_round_trip():
    rng = random.Random(9)
    for n_bits in (1, 7, 8, 9, 64, 243):
        vals = [rng.getrandbits(n_bits) for _ in range(rng.choice([1, 2, 63, 64, 65, 500]))]
        planes = sim.to_planes(vals, n_bits)
        assert len(planes) == n_bits
        assert sim.from_planes(planes, len(vals)) == vals
        for i in (0, n_bits - 1):
            assert planes[i] == sum(((v >> i) & 1) << k for k, v in enumerate(vals))
    assert sim.to_planes([], 5) == [0] * 5 and sim.from_planes([], 0) == [] and sim.to_planes([3, 1], 0) == []
    planes, n = sim.exhaustive_planes(5)
    assert n == 32 and sim.from_planes(planes, n) == list(range(32))


def test_size_bounds_through_ref(reference):
    """Section 3 conditions 7 and 8, and the section 7 evaluation bound, reached with REF fan-out (a netlist of
    a few kilobytes can stand for billions of gates)."""
    table = {}

    def resolve(cpu, cid):
        return table.get((cpu, cid)) if cpu == CPU else None

    # gates: 255 -> 255^2 -> 255^3 -> x259 fits in uint32, x260 does not
    table[(CPU, 1)] = N.check(N.encode([N.nand(0, 0)] * 255), 0, 1)
    table[(CPU, 2)] = N.check(N.encode([N.ref(CPU, 1, [], 1)] * 255), 0, 1, resolve)
    table[(CPU, 3)] = N.check(N.encode([N.ref(CPU, 2, [], 1)] * 255), 0, 1, resolve)
    assert table[(CPU, 3)].gate_count == 255 ** 3
    big = N.check(N.encode([N.ref(CPU, 3, [], 1)] * 259), 0, 1, resolve)
    assert big.gate_count == 259 * 255 ** 3 <= N.MAX_GATES and len(big.data) == 259 * 31
    with pytest.raises(N.IllFormed) as e:
        N.check(N.encode([N.ref(CPU, 3, [], 1)] * 260), 0, 1, resolve)
    assert e.value.condition == 7
    with pytest.raises(N.IllFormed, match="evaluation bound"):          # 8 kB of netlist, 4.29e9 gates: refuse
        sim.step(big, None, None, b"", b"")

    # state: 255 latches -> 255^2 -> 255^3 (below 2^24) -> two of them exceed 2^24
    table[(CPU, 11)] = N.check(N.encode([N.latch(0)] * 255), 0, 1)
    table[(CPU, 12)] = N.check(N.encode([N.ref(CPU, 11, [], 1)] * 255), 0, 1, resolve)
    table[(CPU, 13)] = N.check(N.encode([N.ref(CPU, 12, [], 1)] * 255), 0, 1, resolve)
    assert table[(CPU, 13)].n_state == 255 ** 3 <= N.MAX_STATE
    with pytest.raises(N.IllFormed) as e:
        N.check(N.encode([N.ref(CPU, 13, [], 1)] * 2), 0, 1, resolve)
    assert e.value.condition == 7

    # signals: 65,792 REFs with 255 outputs each; nIn = 254 gives exactly 2^24 signals, nIn = 255 one too many
    table[(CPU, 21)] = N.check(N.encode([N.nand(0, 0)] * 255), 0, 255)
    wide = N.encode([N.ref(CPU, 21, [], 255)] * 65_792)
    assert N.check(wide, 254, 1, resolve).n_signals == N.MAX_SIGNALS
    with pytest.raises(N.IllFormed) as e:
        N.check(wide, 255, 1, resolve)
    assert e.value.condition == 8
    sub_r = reference.load(table[(CPU, 21)].data, 0, 255)
    with pytest.raises(reference.IllFormed):
        reference.load(wide, 255, 1, lambda cpu, cid: sub_r)
    assert reference.load(wide, 254, 1, lambda cpu, cid: sub_r).n_signals == N.MAX_SIGNALS
