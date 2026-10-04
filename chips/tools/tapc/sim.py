"""TAP-20 one-beat evaluator (section 4) and bit packing (section 5).

Two entry points:

    step(netlist, nIn, nOut, state_bits, input_bits) -> (new_state, outputs)
        One beat on packed byte strings, exactly like the contract's `step`: inputs and state are read
        leniently (missing bytes read as 0, extra bytes and padding bits ignored); the two results are exactly
        ceil(n/8) bytes with the unused high bits zero.

    step_many(netlist, states, inputs) -> list of (new_state, outputs)
        The same beat on many vectors at once. Signals are Python integers with one bit per vector
        ("bit-sliced"), so a NAND over 10,000 vectors is one big-integer AND and one XOR.

Bit i of a vector is bit (i mod 8) of byte floor(i / 8): least significant bit first. As an integer, a vector
is therefore int.from_bytes(packed, "little"), and bit i of the vector is bit i of the integer.
"""
from __future__ import annotations

from typing import Optional, Sequence, Union

from .netlist import (DEFAULT_MAX_EVAL_GATES, DEFAULT_MAX_REF_DEPTH, LATCH, NAND, IllFormed, Netlist,
                      Resolver, check)

BytesLike = Union[bytes, bytearray, memoryview]


# ------------------------------------------------------------------------------------------------ bit packing

def pack_bits(bits: Sequence[int]) -> bytes:
    """Pack a bit list LSB-first into exactly ceil(n/8) bytes."""
    out = bytearray((len(bits) + 7) // 8)
    for i, v in enumerate(bits):
        if v:
            out[i >> 3] |= 1 << (i & 7)
    return bytes(out)


def unpack_bits(data: BytesLike, n: int) -> list:
    """Read n bits leniently, as NetlistVM._getBit does: a missing byte reads as 0; anything past bit n-1 is
    ignored."""
    m = len(data)
    return [(data[i >> 3] >> (i & 7)) & 1 if (i >> 3) < m else 0 for i in range(n)]


def bytes_to_int(data: BytesLike, n: int) -> int:
    """Lenient read of an n-bit vector as an integer (bit i of the vector = bit i of the result)."""
    return int.from_bytes(bytes(data), "little") & ((1 << n) - 1)


def int_to_bytes(value: int, n: int) -> bytes:
    """Exactly ceil(n/8) bytes, unused high bits zero."""
    return (value & ((1 << n) - 1)).to_bytes((n + 7) // 8, "little")


def _as_netlist(netlist, n_in, n_out, resolve) -> Netlist:
    if isinstance(netlist, Netlist):
        if n_in is not None and n_in != netlist.n_in or n_out is not None and n_out != netlist.n_out:
            raise ValueError("nIn/nOut do not match the checked netlist")
        return netlist
    return check(bytes(netlist), n_in, n_out, resolve)


def _bound(nl: Netlist, max_gates: int) -> None:
    if nl.gate_count > max_gates:
        raise IllFormed(f"gate count {nl.gate_count} exceeds the evaluation bound {max_gates}", 7)


# ------------------------------------------------------------------------------------------------ the beat

def _run(nl: Netlist, state: Sequence[int], inputs: Sequence[int], mask: int, depth: int) -> tuple:
    """One beat on bit planes. `state` and `inputs` hold one integer per bit position; each integer carries
    that bit for every vector (mask has one bit set per vector). Returns (new_state_planes, output_planes)."""
    if depth > DEFAULT_MAX_REF_DEPTH:
        raise IllFormed("REF nesting too deep", 6)
    sig = [0, mask]
    sig.extend(inputs)
    new_state = list(state)
    latch_d = []
    append = sig.append
    for e, base in zip(nl.elements, nl.state_base):
        op = e.op
        if op == NAND:
            a, b = e.ins
            append(mask ^ (sig[a] & sig[b]))
        elif op == LATCH:
            append(state[base])                       # the value stored at the previous beat
            latch_d.append((base, e.ins[0]))
        else:                                         # REF: one beat of the sub-circuit on its block of state
            sub = nl.subs[(e.cpu, e.cid)]
            ns, outs = _run(sub, state[base:base + sub.n_state], [sig[s] for s in e.ins], mask, depth + 1)
            new_state[base:base + sub.n_state] = ns
            sig.extend(outs)
    for base, d in latch_d:                           # after all elements: each LATCH takes s[d] of this beat
        new_state[base] = sig[d]
    return new_state, sig[len(sig) - nl.n_out:]


def beat(nl: Netlist, state: Sequence[int], inputs: Sequence[int]) -> tuple:
    """One beat on bit lists (TAP-20 section 4). Returns (new_state, outputs) as lists of 0/1."""
    if len(state) != nl.n_state or len(inputs) != nl.n_in:
        raise ValueError("state/inputs length does not match the netlist")
    return _run(nl, state, inputs, 1, 0)


def step(netlist, n_in: Optional[int], n_out: Optional[int], state_bits: BytesLike, input_bits: BytesLike,
         resolve: Optional[Resolver] = None, max_gates: int = DEFAULT_MAX_EVAL_GATES) -> tuple:
    """One beat on packed bytes. `netlist` is raw TAP-20 bytes (checked here) or an already checked Netlist.

    Returns (new_state, outputs): exactly ceil(nState/8) and ceil(nOut/8) bytes, LSB-first.
    """
    nl = _as_netlist(netlist, n_in, n_out, resolve)
    _bound(nl, max_gates)
    ns, out = _run(nl, unpack_bits(state_bits, nl.n_state), unpack_bits(input_bits, nl.n_in), 1, 0)
    return pack_bits(ns), pack_bits(out)


def evaluate(netlist, n_in: Optional[int], n_out: Optional[int], input_bits: BytesLike,
             resolve: Optional[Resolver] = None) -> bytes:
    """Like the contract's `eval`: outputs only; refuses a circuit with state."""
    nl = _as_netlist(netlist, n_in, n_out, resolve)
    if nl.n_state:
        raise ValueError("has latch: use step")
    return step(nl, None, None, b"", input_bits)[1]


# ------------------------------------------------------------------------------------------------ bit-sliced mode

def to_planes(values: Sequence[int], n_bits: int) -> list:
    """Transpose V vectors of n_bits (given as integers) into n_bits planes of V bits. Vector v is bit v of
    every plane. Uses string columns so the work happens in C."""
    v = len(values)
    if n_bits == 0:
        return []
    if v == 0:
        return [0] * n_bits
    fmt = f"0{n_bits}b"
    lim = 1 << n_bits
    rows = [format(x & (lim - 1), fmt) for x in reversed(values)]      # row strings, MSB first
    cols = ["".join(c) for c in zip(*rows)]                            # column j holds bit n_bits-1-j
    return [int(cols[n_bits - 1 - i], 2) for i in range(n_bits)]


def from_planes(planes: Sequence[int], n_vectors: int) -> list:
    """Inverse of to_planes: n planes of V bits -> V integers of n bits."""
    n_bits = len(planes)
    if n_vectors == 0:
        return []
    if n_bits == 0:
        return [0] * n_vectors
    fmt = f"0{n_vectors}b"
    rows = [format(p, fmt) for p in reversed(planes)]                  # row for bit n-1 first; MSB = vector V-1
    cols = ["".join(c) for c in zip(*rows)]                            # column j is vector V-1-j, MSB first
    return [int(cols[n_vectors - 1 - v], 2) for v in range(n_vectors)]


def step_planes(nl: Netlist, state_planes: Sequence[int], input_planes: Sequence[int], n_vectors: int) -> tuple:
    """One beat on bit planes (see to_planes). Returns (new_state_planes, output_planes)."""
    if len(state_planes) != nl.n_state or len(input_planes) != nl.n_in:
        raise ValueError("plane count does not match the netlist")
    return _run(nl, state_planes, input_planes, (1 << n_vectors) - 1, 0)


def step_many_int(nl: Netlist, states: Sequence[int], inputs: Sequence[int]) -> tuple:
    """Bit-sliced beat on integer vectors. Returns (new_states, outputs) as two lists of integers."""
    if len(states) != len(inputs):
        raise ValueError("states and inputs must have the same length")
    v = len(states)
    ns, out = step_planes(nl, to_planes(states, nl.n_state), to_planes(inputs, nl.n_in), v)
    return from_planes(ns, v), from_planes(out, v)


def step_many(netlist, states: Sequence, inputs: Sequence, n_in: Optional[int] = None,
              n_out: Optional[int] = None, resolve: Optional[Resolver] = None,
              max_gates: int = DEFAULT_MAX_EVAL_GATES) -> list:
    """Bit-sliced beat on many vectors. Each state / input is packed bytes (read leniently) or an integer.
    Returns a list of (new_state_bytes, output_bytes), one pair per vector, packed as `step` packs them."""
    nl = _as_netlist(netlist, n_in, n_out, resolve)
    _bound(nl, max_gates)
    st = [x if isinstance(x, int) else bytes_to_int(x, nl.n_state) for x in states]
    xi = [x if isinstance(x, int) else bytes_to_int(x, nl.n_in) for x in inputs]
    ns, out = step_many_int(nl, st, xi)
    return [(int_to_bytes(a, nl.n_state), int_to_bytes(b, nl.n_out)) for a, b in zip(ns, out)]


def run_beats(netlist, inputs_seq: Sequence, state: Union[BytesLike, int] = b"", n_in: Optional[int] = None,
              n_out: Optional[int] = None, resolve: Optional[Resolver] = None) -> list:
    """Chain beats from `state` (default all-zero). Returns one dict per beat in the TAP-20 vectors.json
    'beats' shape: state, inputs, newState, outputs as hex strings without 0x."""
    nl = _as_netlist(netlist, n_in, n_out, resolve)
    st = state if isinstance(state, int) else bytes_to_int(state, nl.n_state)
    rows = []
    for x in inputs_seq:
        xi = x if isinstance(x, int) else bytes_to_int(x, nl.n_in)
        (ns,), (out,) = step_many_int(nl, [st], [xi])
        rows.append({"state": int_to_bytes(st, nl.n_state).hex(), "inputs": int_to_bytes(xi, nl.n_in).hex(),
                     "newState": int_to_bytes(ns, nl.n_state).hex(), "outputs": int_to_bytes(out, nl.n_out).hex()})
        st = ns
    return rows


def exhaustive_planes(n_bits: int) -> tuple:
    """Planes enumerating all 2^n_bits vectors: plane i has bit v set iff bit i of v is set. Returns
    (planes, n_vectors). Vector v is simply the integer v."""
    v = 1 << n_bits
    planes = []
    for i in range(n_bits):
        half = 1 << i                                 # pattern: `half` zeros then `half` ones, repeated
        unit = ((1 << half) - 1) << half
        period = 2 * half
        reps = v // period
        # replicate `unit` (width `period`) `reps` times by doubling
        p, width, count = unit, period, 1
        while count < reps:
            p |= p << width
            width *= 2
            count *= 2
        planes.append(p)
    return planes, v
