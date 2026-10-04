"""tapc: the Covenant chip toolchain.

Verilog -> TAP-20 netlist bytes (synth, pack), bytes -> Verilog (unpack), simulation (sim), proofs over every
state and input (prove) and comparison with the chain (difftest).

Run as `chips/tools/bin/tapc ...` or `PYTHONPATH=chips/tools chips/.venv/bin/python -m tapc ...`.
"""
__version__ = "0.1.0"
