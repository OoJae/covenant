# chips: the toolchain (`tapc`) and the probe circuit

`tapc` turns a Verilog core into the bytes of a TapeOut circuit, simulates those bytes, proves things about
them for every state and input, and compares them with the chain.

| Path | What |
|---|---|
| `tools/tapc/` | the Python package |
| `tools/bin/tapc` | wrapper script (uses `chips/.venv`) |
| `tools/tests/` | test-suite (96 tests, a little over 3 minutes with the live check) |
| `tools/NOTES.md` | everything that was measured: gate counts by recipe, timings, RPC limits, fees and gas |
| `tools/requirements.txt` | pinned packages |
| `vendor/tap-20/` | TAP-20 text, reference evaluator and vectors (TapeOutProtocol, MIT / CC0), unmodified |
| `probe/` | the first circuit: the epoch meter (109 NAND + 9 LATCH), with proofs, vectors and a fork rehearsal |
| `Makefile` | `venv`, `test`, `test-offline`, `probe`, `probe-check` |

`INTERFACE.md`, `golden/`, `rtl/`, `model/`, `props/`, `synth/`, `out/` and `cells/glutton/` belong to the
kernel-interface and chip work streams; `rtl/Makefile` is their entry point.

Nothing in the toolchain sends a transaction to a real chain or reads a key. Chain access is read-only
(`eth_call` and a few other read methods).

## Install

Python 3.12 is required (the TAP-20 reference needs 3.11+; the system `python3` on the build machine is 3.9
and must not be used).

```
make -C chips venv
```

which is:

```
~/.local/bin/python3.12 -m venv chips/.venv
chips/.venv/bin/python -m pip install -r chips/tools/requirements.txt
```

Pinned: `yowasp-yosys==0.69.0.0.post1233` (Yosys 0.69 + ABC as WebAssembly), `z3-solver==5.1.0.0`,
`pytest==9.1.1`. The first Yosys run compiles the wasm module (about 14 s) and caches it in
`chips/.venv/cache/yowasp`.

Run the tool either way:

```
chips/tools/bin/tapc <command> ...
PYTHONPATH=chips/tools chips/.venv/bin/python -m tapc <command> ...
```

## The core convention

A chip is written as one pure combinational Verilog module, a function `core(s, x) -> (ns, y)`:

```verilog
module cnt4_core(input [3:0] s, input [0:0] x, output [3:0] ns, output [4:0] y);
  wire [4:0] sum = {1'b0, s} + {4'b0, x[0]};
  assign ns = sum[3:0];           // next state
  assign y  = {sum[4], sum[3:0]}; // outputs
endmodule
```

`s` is the state before the beat, `x` the inputs, `ns` the state after it, `y` the outputs. A chip without
state has no `s` and `ns`. No clock, no `reg` that holds a value, no `x` or `z`: every bit defined for every
input. The packer turns each `(s[i], ns[i])` pair into LATCH record `i`.

Because one beat is a pure function, every proof is a single combinational query with `s` and `x` free: it
covers every state, reachable or not, with no unrolling.

## Commands

```
# Verilog -> netlist. Writes fg.tap, fg.hex, fg.manifest.json, fg.map.json into --out.
tapc synth chips/rtl/fg_core.v --name fg --out chips/out --pins fg.pins.json \
     --nin 96 --nout 112 --max-bytes 24000 --shape covenant-v1

# counts, keccak256, well-formedness; also for a circuit on chain
tapc info chips/probe/probe.tap
tapc info --cpu 0x933FC3AA0c387CB8B6B1D22a2Ec3E2B5eeCfDb5a --id 1 --save trivium.tap

# one or more beats (each starts from the previous new state), or check a vector file
tapc sim chips/probe/probe.tap --state 0xfe00 --inputs 01 --inputs 01
tapc sim chips/probe/probe.tap --check chips/probe/probe.vectors.json

# bytes -> structural Verilog (one beat as a combinational module), or a record listing
tapc unpack chips/probe/probe.tap --module probe_tap -o probe_tap.v
tapc unpack chips/probe/probe.tap --list

# a BLIF you produced yourself -> bytes
tapc pack build/fg.blif --nin 96 --nout 112 --state s:ns --out build

# proofs over every (s, x)
tapc prove equiv --rtl chips/probe/probe_core.v --top probe_core --tap chips/probe/probe.tap
tapc prove prop  --rtl chips/probe/probe_props.v --top probe_props --tap chips/probe/probe.tap \
     --tap-module probe_tap --signal p_flag_sticky --engine both
tapc prove z3    chips/probe/probe.tap --props chips/probe/probe_props.py
tapc prove all   --rtl chips/probe/probe_core.v --top probe_core --tap chips/probe/probe.tap \
     --props-v chips/probe/probe_props.v --props-top probe_props --tap-module probe_tap \
     --props-py chips/probe/probe_props.py --report chips/probe/probe.proofs.json

# chain versus simulator. Exit status is non-zero on any mismatch.
tapc difftest --rpc https://rpc.xlayer.tech --cpu <processor> --id <circuit> --n 10000 --seed 1 \
     --tap chips/out/fg.tap --out fg.difftest.jsonl

# tape-out rehearsal on a LOCAL anvil fork (refuses any other node)
anvil --fork-url https://rpc.xlayer.tech --port 28545 &
tapc fork-tapeout --rpc http://127.0.0.1:28545 chips/probe/probe.tap
tapc difftest --rpc http://127.0.0.1:28545 --cpu <fork processor> --id 1 --n 10000 --tap chips/probe/probe.tap
```

`nIn` and `nOut` are read from `<name>.manifest.json` next to the netlist; pass `--nin` / `--nout` otherwise.

### synth

Yosys elaborates and optimises the core, ABC maps it onto a library in which every cell is priced in NAND
records, and the packer expands the cells. `--recipe auto` (the default) runs twelve mapping recipes and keeps
the smallest netlist; ties go to the earlier recipe, so the build is deterministic. `--recipe <name>` runs one;
`tapc/synth.py` lists them. `--hier` maps each Verilog module on its own so that the map keeps instance names
(it costs gates). `--shape covenant-v1` checks the chip shape of `chips/INTERFACE.md` section 2 and fails if it
does not fit. List every source file: `` `include `` is not followed.

### prove

| Subcommand | Claim | How |
|---|---|---|
| `equiv` | the RTL core equals the netlist bytes | Yosys miter + SAT, and z3 on a formula built straight from the bytes against the word-level RTL |
| `prop` | a 1-bit output of a wrapper module is always 1 | the wrapper has free `s` and `x` and instantiates the unpacked netlist; Yosys SAT, or z3 with `--engine z3` |
| `z3` | Python predicates `prop_*(c)` hold | `c.s`, `c.x` are free; `c.ns`, `c.y` are z3 terms built from the bytes |
| `all` | all of the above, one report | writes `<name>.proofs.json` (no timings in it, so it is reproducible) |

A failed proof prints a counterexample (`s=0x.., x=0x..`) that `tapc sim --state .. --inputs ..` replays.
A design that is not a pure function (a register, a latch, a memory) is an error, never a verdict.

### difftest

For every vector the expected result comes from `tapc.sim` and the observed one from the processor contract.
`step` calls are grouped with Multicall3 `aggregate3` to stay under the 50M-gas `eth_call` cap; the batch size
is found by probing the node, and a batch that fails is halved and retried. JSON-RPC batches hold at most 10
calls and at most 8 requests are in flight. The vector mix is 40% uniform random, 30% random walks from the
zero state, 30% field boundaries (fields come from the manifest when one is given). `--tap` also checks that
the on-chain bytes equal the local file. The evidence file is JSONL: a header (chain id, block, netlist keccak,
implementation address and code hash, and whether the node is a local fork), one line per vector, a summary.

## What `synth` and `pack` write

| File | Content |
|---|---|
| `<name>.tap` | the raw netlist bytes |
| `<name>.hex` | the same as `0x...`, the `netlist` argument of `tapeout` |
| `<name>.manifest.json` | `nIn`, `nOut`, `nState`, `nNand`, `nLatch`, `bytes`, `keccak256`; every input, output and latch with its name, bit position and signal index; the build inputs (recipe, Yosys version, SHA-256 of each source) |
| `<name>.map.json` | one entry per record for a die-shot renderer: `op`, signal indices, `level` (NAND depth), `cone` (which output / next-state fields it can influence, as indices into `groups`), `block` (the Verilog instance it came from; only with `--hier`, otherwise `null`), and `out` / `name` for output and latch records |

Field names come from a pins file (`--pins`):

```json
{"inputs":  [{"name": "en", "lsb": 0, "width": 1}, {"name": "clr", "lsb": 1, "width": 1}],
 "outputs": [{"name": "count", "lsb": 0, "width": 8}, {"name": "flag", "lsb": 8, "width": 1}],
 "state":   [{"name": "count", "lsb": 0, "width": 8}, {"name": "flag", "lsb": 8, "width": 1}]}
```

### Netlist layout

1. LATCH records first. Record `i` is state bit `i`, which is bit `i` of port `s`. Its `d` is whatever drives
   bit `i` of `ns`; it may point forward, or straight at an input, another latch or a constant.
2. Then the NAND records, in a fixed topological order.
3. The last `nOut` records are the outputs, `y[0]` first. A driver that feeds only later outputs and latches is
   placed there as it is. One that is also used inside the chip is repeated once. An output wired to an input
   or a state bit gets a two-NAND buffer (one if its complement already exists). A constant output is one
   record. Nothing is padded.
4. INV is `NAND(a, a)`. Constants are signals 0 and 1. Identical NANDs are merged. Logic that reaches neither
   an output nor a latch is dropped.

## Measured (2026-10-04, this machine; details in `tools/NOTES.md`)

| | |
|---|---|
| 12-bit adder, `auto` | **104 NAND**, the hand-built ripple figure (5 + 11 x 9) |
| 12-bit adder, plain INV + NAND2 library | 138 NAND; `abc -g NAND` 139 |
| 4-bit counter with enable and wrap flag | 20 NAND + 4 LATCH |
| probe | 109 NAND + 9 LATCH, 799 bytes |
| a vault-shaped test core (96 in, 112 out, 64 latches) | 1,637 NAND + 64 LATCH, 11,715 bytes |
| synthesis, 12 recipes, 1,700 to 3,400 gates | 5 to 7 s (about 1.5 s per recipe) |
| equivalence proof, adder | 1.6 s (Yosys SAT), 1.6 s (z3) |
| equivalence proof, 1,701-gate core with 160 free bits | 10.3 s (Yosys SAT), 18.1 s (z3) |
| simulator | 10,000 vectors through 3,035 gates in 91 ms |
| difftest on the public RPC, 3,035-gate circuit | 10,318 vectors per minute |
| steps per Multicall3 eth_call under the 50M cap | 11 at 1,944 gates, 8 at 2,463, 7 at 3,035, 6 at 3,413 |
| rebuild | byte-identical across runs, directories, job counts and two virtual environments |

A two-cell liberty file (INV and NAND2 only) is refused by ABC ("Library with only 2 cell classes cannot be
used"); the plain library therefore carries a BUF cell that the mapper never uses.

## Tests

```
make -C chips test            # everything, including the live X Layer check (read-only)
make -C chips test-offline    # without the network
```

or `cd chips/tools && ../.venv/bin/python -m pytest [-m "not live"]`.

| File | Checks |
|---|---|
| `test_netlist.py` | keccak256 (known answers and `cast keccak`), encoding, every TAP-20 section 3 condition |
| `test_tap20_vectors.py` | TAP-20's `vectors.json`: valid, ill-formed and packing edge cases |
| `test_reference_fuzz.py` | 4,000 random netlists (NAND, LATCH, REF, nested REF) and 4,000 damaged ones against TAP-20's reference evaluator; size limits |
| `test_cells.py` | every cell expansion against its truth table; liberty areas |
| `test_pack.py` | layout rules, 400 random BLIF models checked on every (s, x), unpack round trip |
| `test_synth.py` | adder on all 2^24 inputs, counter on all (s, x), equivalence by both engines, mutants refuted, properties, determinism, CLI |
| `test_difftest_offline.py` | difftest against a local fake node that enforces the batch and gas limits and can lie |
| `test_probe.py` | the committed probe: consistency, model on every (s, x), proofs, byte-identical rebuild |
| `test_live.py` | `tapc.sim` against on-chain `step` on X Layer for two circuits (4,863 and 3,035 gates) |
