"""Behavioural model of the probe circuit ("epoch meter"), independent of the Verilog and of the netlist.

State (9 bits, bit 0 first):  count = bits 0..7, flag = bit 8.
Inputs (2 bits):              en = bit 0, clr = bit 1.
Outputs (10 bits):            count after the beat = bits 0..7, flag after the beat = bit 8, parity = bit 9.

Integers follow TAP-20 packing: bit i of the vector is bit i of the integer, so the packed bytes are
value.to_bytes(ceil(n/8), "little").
"""

N_IN, N_OUT, N_STATE = 2, 10, 9


def beat(state: int, inputs: int) -> tuple:
    """One beat. Returns (new_state, outputs) as integers."""
    count, flag = state & 0xFF, (state >> 8) & 1
    en, clr = inputs & 1, (inputs >> 1) & 1
    if clr:
        count = 0                       # clr wins over en, and never clears the flag
    elif en and count != 255:
        count += 1                      # saturates at 255: no wrap
    if count == 255:
        flag = 1                        # sticky: nothing ever clears it
    parity = bin(count).count("1") & 1
    new_state = count | (flag << 8)
    return new_state, new_state | (parity << 9)


def pack(value: int, n_bits: int) -> str:
    """Hex of the TAP-20 packed bytes (LSB first), without 0x."""
    return value.to_bytes((n_bits + 7) // 8, "little").hex()
