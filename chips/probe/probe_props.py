"""Properties of the probe netlist for z3, built straight from the TAP-20 bytes (`tapc prove z3`).

Each prop_* function receives a tapc.prove.Z3Circuit `c`:
    c.s, c.x     lists of free z3 Bools: state before the beat, inputs (bit 0 first)
    c.ns, c.y    lists of z3 Bool terms: state after the beat, outputs
    c.bv(bits)   unsigned bit-vector from a list of Bools
and returns a z3 Bool term that must hold for every (s, x).

prop_full_spec is the complete behaviour of the chip written a third time (after probe_core.v and model.py):
if it is valid, the bytes compute exactly the epoch meter and nothing else.
"""
import z3


def _parts(c):
    count, flag = c.bv(c.s[0:8]), c.s[8]
    en, clr = c.x[0], c.x[1]
    count1, flag1 = c.bv(c.ns[0:8]), c.ns[8]
    return count, flag, en, clr, count1, flag1


def prop_flag_sticky(c):
    _, flag, _, _, _, flag1 = _parts(c)
    return z3.Implies(flag, flag1)


def prop_saturated_implies_flag(c):
    _, _, _, _, count1, flag1 = _parts(c)
    return z3.Implies(count1 == 255, flag1)


def prop_never_wraps(c):
    count, _, _, clr, count1, _ = _parts(c)
    return z3.Implies(z3.Not(clr), z3.UGE(count1, count))


def prop_full_spec(c):
    count, flag, en, clr, count1, flag1 = _parts(c)
    want_count = z3.If(clr, z3.BitVecVal(0, 8),
                       z3.If(z3.And(en, count != 255), count + 1, count))
    want_flag = z3.Or(flag, want_count == 255)
    parity = z3.BoolVal(False)
    for i in range(8):
        parity = z3.Xor(parity, z3.Extract(i, i, want_count) == 1)
    return z3.And(count1 == want_count,
                  flag1 == want_flag,
                  c.bv(c.y[0:8]) == want_count,
                  c.y[8] == want_flag,
                  c.y[9] == parity)
