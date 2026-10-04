"""tapc.netlist: keccak256, encode/decode, TAP-20 section 3 well-formedness."""
import random
import shutil
import subprocess

import pytest

from tapc import chain
from tapc import netlist as N


# ---------------------------------------------------------------------------------------------- keccak256

KNOWN = {
    b"": "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
    b"abc": "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45",
    b"The quick brown fox jumps over the lazy dog":
        "4d741b6f1eb29cb2a9b9911c82f56fa8d73b04959d3d9d222895df6c0b28aa15",
}


@pytest.mark.parametrize("msg,want", list(KNOWN.items()))
def test_keccak_known_answers(msg, want):
    assert N.keccak256(msg).hex() == want


def test_keccak_block_boundaries_against_cast():
    """Lengths around the 136-byte rate, and the largest live netlist size, against Foundry's `cast keccak`."""
    cast = shutil.which("cast")
    if not cast:
        pytest.skip("cast (Foundry) not installed; the known-answer test above still ran")
    rng = random.Random(20)
    for n in (1, 55, 56, 135, 136, 137, 271, 272, 273, 799, 4095, 24000, 33312):
        data = bytes(rng.getrandbits(8) for _ in range(n))
        out = subprocess.run([cast, "keccak", "0x" + data.hex()], capture_output=True, text=True, check=True)
        assert out.stdout.strip() == "0x" + N.keccak256(data).hex(), n


def test_function_selectors_are_keccak_of_the_signatures():
    assert chain.selector("circuitInfo(uint256)") == chain.SEL_CIRCUIT_INFO
    assert chain.selector("netlist(uint256)") == chain.SEL_NETLIST
    assert chain.selector("eval(uint256,bytes)") == chain.SEL_EVAL
    assert chain.selector("step(uint256,bytes,bytes)") == chain.SEL_STEP
    assert chain.selector("nextId()") == chain.SEL_NEXT_ID
    assert chain.selector("aggregate3((address,bool,bytes)[])") == chain.SEL_AGGREGATE3
    assert chain.selector("implementation()") == chain.SEL_IMPLEMENTATION
    slot = int.from_bytes(N.keccak256(b"eip1967.proxy.beacon"), "big") - 1
    assert hex(slot) == chain.BEACON_SLOT


# ---------------------------------------------------------------------------------------------- encode / decode

def test_record_lengths():
    assert len(N.encode([N.nand(2, 3)])) == 7
    assert len(N.encode([N.latch(5)])) == 4
    cpu = bytes(range(20))
    for k in (0, 1, 7, 255):
        assert len(N.encode([N.ref(cpu, 9, [2] * k, 3)])) == 31 + 3 * k


def test_encode_matches_spec_bytes():
    assert N.encode([N.nand(2, 3)]).hex() == "00000002000003"
    assert N.encode([N.latch(7)]).hex() == "01000007"
    cpu = bytes.fromhex("00" * 19 + "aa")
    assert N.encode([N.ref(cpu, 1, [2], 1)]).hex() == "02" + cpu.hex() + "0000000000000001" + "0101" + "000002"


def test_decode_encode_round_trip_random():
    rng = random.Random(3)
    cpu = bytes(rng.getrandbits(8) for _ in range(20))
    for _ in range(300):
        n_in = rng.randrange(0, 9)
        recs = []
        for _ in range(rng.randrange(1, 40)):
            k = rng.random()
            if k < 0.6:
                recs.append(N.nand(rng.randrange(1 << 24), rng.randrange(1 << 24)))
            elif k < 0.85:
                recs.append(N.latch(rng.randrange(1 << 24)))
            else:
                recs.append(N.ref(cpu, rng.getrandbits(64), [rng.randrange(1 << 24) for _ in range(rng.randrange(0, 6))],
                                  rng.randrange(0, 256)))
        data = N.encode(recs)
        els = N.decode(data, n_in)
        assert N.encode(els) == data
        nxt = 2 + n_in
        for e in els:
            assert e.first_out == nxt
            nxt += e.n_out


def test_encode_rejects_bad_fields():
    with pytest.raises(ValueError):
        N.encode([(N.NAND, (1 << 24, 0))])
    with pytest.raises(ValueError):
        N.encode([(N.NAND, (1,))])
    with pytest.raises(ValueError):
        N.encode([(N.REF, tuple([2] * 256), bytes(20), 1, 1)])
    with pytest.raises(ValueError):
        N.encode([(7, (1, 2))])


# ---------------------------------------------------------------------------------------------- section 3

def _cond(data, n_in, n_out, resolve=None):
    with pytest.raises(N.IllFormed) as e:
        N.check(data, n_in, n_out, resolve)
    return e.value.condition


def test_condition_1_opcode_and_truncation():
    assert _cond(bytes.fromhex("03000002000003"), 2, 1) == 1
    full = N.encode([N.nand(2, 3)])
    for cut in range(1, len(full)):
        assert _cond(full[:cut], 2, 1) == 1
    lt = N.encode([N.latch(2)])
    for cut in range(1, len(lt)):
        assert _cond(lt[:cut], 2, 1) == 1
    rf = N.encode([N.ref(bytes(20), 1, [2, 3], 1)])
    for cut in range(1, len(rf)):
        assert _cond(rf[:cut], 2, 1, lambda c, i: None) == 1


def test_condition_2_pin_limits():
    one = N.encode([N.nand(0, 1)])
    assert _cond(one, 0, 0) == 2
    assert _cond(one, 65537, 1) == 2
    assert _cond(one, 0, 65537) == 2
    assert _cond(one, -1, 1) == 2
    assert N.check(one, 65536, 1).n_signals == 2 + 65536 + 1
    assert N.check(one, 0, 1).n_in == 0                      # nIn may be 0


def test_condition_3_outputs_are_element_signals():
    assert _cond(b"", 1, 1) == 3
    assert _cond(N.encode([N.nand(2, 3)]), 2, 2) == 3
    assert N.check(N.encode([N.nand(2, 3), N.nand(2, 4)]), 2, 2).n_out == 2


def test_condition_4_nand_and_ref_refer_backwards_only():
    # the first NAND produces signal 4; referring to 4 (itself) or 5 (later) is ill-formed
    assert _cond(N.encode([N.nand(2, 4)]), 2, 1) == 4
    assert _cond(N.encode([N.nand(5, 2), N.nand(2, 3)]), 2, 1) == 4
    assert N.check(N.encode([N.nand(2, 3), N.nand(4, 4)]), 2, 1).n_nand == 2
    sub = N.check(N.encode([N.nand(2, 2)]), 1, 1)
    assert _cond(N.encode([N.ref(bytes(20), 1, [3], 1)]), 1, 1, lambda c, i: sub) == 4


def test_condition_5_latch_d_may_point_forward_but_must_exist():
    assert N.check(N.encode([N.latch(3), N.nand(2, 2)]), 0, 1).n_state == 1     # d = 3 is the NAND after it
    assert N.check(N.encode([N.latch(2)]), 0, 1).n_state == 1                   # d = its own output
    assert _cond(N.encode([N.latch(4), N.nand(2, 2)]), 0, 1) == 5               # signals are 0..3
    assert N.check(N.encode([N.latch(0), N.latch(1)]), 0, 1).n_latch == 2       # constants are fine


def test_condition_6_ref_target():
    sub = N.check(N.encode([N.nand(2, 3)]), 2, 1)
    cpu = bytes(20)
    ok = N.encode([N.ref(cpu, 1, [2, 3], 1)])
    assert N.check(ok, 2, 1, lambda c, i: sub).gate_count == 1
    assert _cond(ok, 2, 1) == 6                                          # no registry at all
    assert _cond(ok, 2, 1, lambda c, i: None) == 6                       # not a registered circuit
    assert _cond(N.encode([N.ref(cpu, 1, [2], 1)]), 2, 1, lambda c, i: sub) == 6         # nIns mismatch
    assert _cond(N.encode([N.ref(cpu, 1, [2, 3], 2)]), 2, 1, lambda c, i: sub) == 6      # nOuts mismatch


def test_ref_state_layout_and_gate_count():
    toggle = N.check(N.encode([N.latch(7), N.nand(3, 2), N.nand(3, 4), N.nand(2, 4), N.nand(5, 6)]), 1, 1)
    cpu = bytes(19) + b"\xaa"
    top = N.check(N.encode([N.latch(4), N.ref(cpu, 1, [2], 1), N.nand(3, 4)]), 1, 1, lambda c, i: toggle)
    assert (top.n_nand, top.n_latch, top.n_ref) == (1, 1, 1)
    assert top.n_state == 2 and top.state_base == [0, 1, 2]
    assert top.gate_count == 2 + toggle.gate_count == 7                  # circuitInfo.gateCount counts through REF
    assert N.burn_of(top.data) == (1, 1)                                 # tapeout burns the top level only
    assert not top.latches_first


def test_ref_depth_is_bounded():
    """TAP-20 section 7, requirement 1: a tool bound, not a well-formedness condition (condition 0)."""
    cpu = bytes(20)
    table = {0: N.check(N.encode([N.nand(2, 2)]), 1, 1)}

    def resolve(c, i):
        return table.get(i)
    for level in range(1, 6):                        # circuit `level` is a REF to circuit `level - 1`
        table[level] = N.check(N.encode([N.ref(cpu, level - 1, [2], 1)]), 1, 1, resolve)
        assert table[level].ref_depth == level and table[level].gate_count == 1
    data = N.encode([N.ref(cpu, 5, [2], 1)])
    assert N.check(data, 1, 1, resolve).ref_depth == 6
    with pytest.raises(N.IllFormed) as e:
        N.check(data, 1, 1, resolve, max_ref_depth=5)
    assert e.value.condition == 0


def test_counts_and_helpers():
    data = N.encode([N.latch(5), N.latch(2), N.nand(3, 4), N.nand(5, 5)])
    nl = N.check(data, 1, 1)
    c = nl.counts()
    assert (c["nNand"], c["nLatch"], c["nState"], c["gateCount"], c["bytes"], c["signals"]) == (2, 2, 2, 4, 22, 7)
    assert c["keccak256"] == "0x" + N.keccak256(data).hex()
    assert nl.latches_first and nl.is_flat
    assert N.depth_of(nl) == 2 and N.live_count(nl) == 4
    assert list(nl.output_signals()) == [6]
    assert N.burn_of(data) == (2, 2)
    late = N.check(N.encode([N.nand(2, 2), N.latch(3)]), 1, 1)
    assert not late.latches_first


def test_hex_helpers(tmp_path):
    data = N.encode([N.nand(2, 3), N.latch(4)])
    assert N.from_hex(N.to_hex(data)) == data
    assert N.from_hex(" 0x00 00\n0002000003") == bytes.fromhex("00000002000003")
    tap = tmp_path / "a.tap"
    tap.write_bytes(data)
    hx = tmp_path / "a.hex"
    hx.write_text(N.to_hex(data) + "\n")
    assert N.read_netlist_file(str(tap)) == data
    assert N.read_netlist_file(str(hx)) == data
    # a .tap file whose bytes happen to be ASCII hex digits is still raw bytes
    odd = tmp_path / "b.tap"
    odd.write_bytes(b"0011")
    assert N.read_netlist_file(str(odd)) == b"0011"
