"""Reference implementation for the TAP draft "Stateful Circuit Consumers".

MIT licence. Pure Python 3.11+, no dependencies.

What is here, by section of the draft:
  is_canonical(), state_word(), state_string()   the state string and its word form          (section 3)
  replay()                                       the reader's check of a consumer's records  (section 5.3)
  netlist_hash(), scan()                         the netlist hash pinned under section 6.1, and whether a
                                                 netlist is latches-first (section 3.3)

One beat itself is TAP-02's: replay() takes it as a function, and make_replay_vectors.py passes the reference
evaluator of TAP-02 (assets/tap-02/reference.py).

keccak256() is Keccak-f[1600] with the original Keccak padding byte 0x01 (the hash Ethereum uses, not NIST
SHA3-256). It follows the structure of the Keccak team's public-domain CompactFIPS202.py. The same code is in
pins_reference.py of the Circuit Pin Manifest draft, so that each draft's assets stand alone.
"""
from __future__ import annotations


class Invalid(ValueError):
    """The bytes are not a well-formed netlist record sequence."""


# ------------------------------------------------------------------------------------------------ hashes

def _rol(a: int, n: int) -> int:
    return ((a << n) | (a >> (64 - n))) & 0xFFFFFFFFFFFFFFFF if n else a


def _keccak_f(lanes: list) -> None:
    r = 1
    for _ in range(24):
        c = [lanes[x][0] ^ lanes[x][1] ^ lanes[x][2] ^ lanes[x][3] ^ lanes[x][4] for x in range(5)]
        d = [c[(x + 4) % 5] ^ _rol(c[(x + 1) % 5], 1) for x in range(5)]
        for x in range(5):
            for y in range(5):
                lanes[x][y] ^= d[x]
        x, y, cur = 1, 0, lanes[1][0]
        for t in range(24):
            x, y = y, (2 * x + 3 * y) % 5
            cur, lanes[x][y] = lanes[x][y], _rol(cur, ((t + 1) * (t + 2) // 2) % 64)
        for y in range(5):
            row = [lanes[x][y] for x in range(5)]
            for x in range(5):
                lanes[x][y] = row[x] ^ (~row[(x + 1) % 5] & row[(x + 2) % 5] & 0xFFFFFFFFFFFFFFFF)
        for j in range(7):
            r = ((r << 1) ^ ((r >> 7) * 0x71)) & 0xFF
            if r & 2:
                lanes[0][0] ^= 1 << ((1 << j) - 1)


def keccak256(data: bytes) -> bytes:
    rate = 136
    msg = bytearray(data) + b"\x01"
    msg += bytes(-len(msg) % rate)
    msg[-1] |= 0x80
    lanes = [[0] * 5 for _ in range(5)]
    for off in range(0, len(msg), rate):
        for i in range(rate // 8):
            lanes[i % 5][i // 5] ^= int.from_bytes(msg[off + 8 * i:off + 8 * i + 8], "little")
        _keccak_f(lanes)
    return b"".join(lanes[i % 5][i // 5].to_bytes(8, "little") for i in range(4))


def netlist_hash(netlist: bytes) -> str:
    """keccak256 of the netlist bytes, the `netlistHash` a consumer pins (section 6.1)."""
    return "0x" + keccak256(netlist).hex()


# ------------------------------------------------------------------------------------------------ netlists

def scan(netlist: bytes) -> dict:
    """Counts of a TAP-02 netlist from its bytes alone, and whether it is latches-first (section 3.3)."""
    p, nand, latch, ref, seen_nand, latches_first = 0, 0, 0, 0, False, True
    while p < len(netlist):
        op = netlist[p]
        if op == 0x00:
            size, nand, seen_nand = 7, nand + 1, True
        elif op == 0x01:
            size, latch = 4, latch + 1
            latches_first = latches_first and not seen_nand
        elif op == 0x02:
            if p + 31 > len(netlist):
                raise Invalid("truncated record")
            size, ref, latches_first = 31 + 3 * netlist[p + 29], ref + 1, False
        else:
            raise Invalid(f"unknown opcode 0x{op:02x}")
        if p + size > len(netlist):
            raise Invalid("truncated record")
        p += size
    return {"nNand": nand, "nLatch": latch, "nRef": ref, "bytes": len(netlist), "latchesFirst": latches_first}


# ------------------------------------------------------------------------------------------------ state (3)

def is_canonical(data: bytes, n: int) -> bool:
    """True when data is exactly ceil(n / 8) bytes and its bits at positions n and above are 0."""
    return len(data) == (n + 7) // 8 and (n % 8 == 0 or data[-1] >> (n % 8) == 0)


def state_word(state: bytes) -> bytes:
    """Word form of a state string of at most 32 bytes: the string, then zero bytes up to 32."""
    if len(state) > 32:
        raise ValueError("a state string longer than 32 bytes has no word form")
    return state + bytes(32 - len(state))


def state_string(word: bytes, n_state: int) -> bytes:
    """The state string held by a word. Raises ValueError unless every bit at n_state and above is 0."""
    if len(word) != 32 or n_state > 256:
        raise ValueError("a word is 32 bytes and holds at most 256 state bits")
    s = word[:(n_state + 7) // 8]
    if any(word[len(s):]) or not is_canonical(s, n_state):
        raise ValueError("non-zero bits beyond nState")
    return s


# ------------------------------------------------------------------------------------------------ replay (5.3)

def replay(beat, n_in: int, n_out: int, n_state: int, initial: bytes, records: list):
    """Check a consumer's records against the replay rule (section 5.3).

    beat(state_string, input_string) -> (new_state_string, output_string) is one TAP-02 beat of the bound
    circuit. Each record is (source, inputs, outputs, state_after), all byte strings; source 0 is a record
    without a beat. Returns None when every record holds, else (record number, reason). Record numbers start
    at 1.
    """
    if not is_canonical(initial, n_state):
        return 0, "the initial state is not a canonical state string"
    state = initial
    for n, (source, inputs, outputs, after) in enumerate(records, 1):
        if not is_canonical(after, n_state):
            return n, "stateAfter is not a canonical state string"
        if source == 0:
            if after != state:
                return n, "a record without a beat changed the state"
        else:
            if not is_canonical(inputs, n_in):
                return n, "inputs is not a canonical input string"
            new_state, out = beat(state, inputs)
            if new_state != after:
                return n, "stateAfter is not the new state of the beat"
            if out != outputs:
                return n, "outputs is not the output of the beat"
        state = after
    return None
