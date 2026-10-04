# tapc: what was measured

Everything here was measured on 2026-10-04 on one machine (macOS, Darwin 27.0.0, arm64, 10 cores, 16 GB) with
the pinned packages of `requirements.txt` (Yosys 0.69 git sha1 9f75ca1f9 from `yowasp-yosys==0.69.0.0.post1233`,
`wasmtime==47.0.1`, `z3-solver==5.1.0.0`, Python 3.12.13). Where something was not measured it says so.

Benchmarks named `fgish` and `mulAxB` are throwaway cores written only to exercise the toolchain; they are not
in the repository and they are not chip designs. `fgish` has the shape of a vault chip (96 inputs, 112 outputs,
64 latches) and a mix of adders, comparators, a case table and a mode state machine.

## 1. Does the liberty-based NAND mapping work in the wasm build?

**Not with two cells. Yes with three.**

- The two-cell liberty that the project's design notes proposed (INV and NAND2, both area 1) is refused by ABC.
  ABC prints `Library with only 2 cell classes cannot be used.`, then `There is no Liberty library available.`,
  and Yosys stops with `ERROR: Can't open ABC output file`. The message comes from ABC's `read_lib`; no native
  ABC was at hand to confirm that a native build refuses it too.
  `tests/test_synth.py::test_a_two_cell_liberty_is_refused_by_abc` records it.
- Adding any third cell class fixes it. Library `nand` is INV + NAND2 (area 1 each) + BUF (area 1000, so the
  mapper never wants one; the packer treats a BUF as an alias, zero records).
- The custom ABC script is accepted as written: Yosys wraps it with `read_lib` in front and `write_blif` behind.
- `write_blif -gates` gives one `.gate CELL A=.. B=.. Y=..` line per cell, plus `.names $false`,
  `.names $true / 1`, `.names $undef` and `.names src dst / 1 1` for wire-to-wire connections. The packer
  resolves all of these.

**12-bit adder (x[11:0] + x[23:12], 13 outputs). The hand-built ripple figure is 104.**

| Configuration | NAND records |
|---|---|
| `nand-area`: INV + NAND2 (+BUF), script `strash; ifraig; dc2; dc2; dch -f; map -a; topo` (the configuration first planned) | 138 (56 INV + 82 NAND2) |
| `g-nand`: the fallback `abc -g NAND` | 139 |
| `g-nand-ripple`: the same with a ripple-carry `$lcu` | 138 |
| `auto`: macro-cell library + ripple-carry `$lcu` + merging in the packer | **104** |

Where the 34 gates go, measured on the adder:

- XOR. With only INV and NAND2 the mapper builds each XOR as a tree (its output shows five- and six-gate
  groups). The four-NAND XOR reuses one NAND twice, which a tree cannot express. Giving the mapper an XOR2 cell
  priced at 4 brings the adder from 138 to 107-110.
- The adder structure. Yosys's default carry logic is Brent-Kung, which spends gates to save depth, and depth
  costs nothing on chain. Replacing it with a ripple chain brings 107-110 down to 104. (With the plain library
  the same replacement changes almost nothing after ABC's optimisation: 139 against 138.) On the vault-shaped
  `fgish` core the ripple chain is worth about 2% (1,666 against 1,637).

What `auto` does instead:

1. A liberty library in which every cell is priced at its true cost in NAND records: INV 1, NAND2 1, AND2 2,
   OR2 3, NOR2 4, XOR2 4, XNOR2 5, ANDN2 3, ORN2 2, NAND3 3, AO21 3, AOI21 4, OAI21 4, OA21 5, MUX2 4 (library
   `rich`; `tapc/cells.py`). So the area ABC minimises is the transistor count.
2. A technology-mapping rule that replaces Yosys's Brent-Kung `$lcu` with a ripple chain.
3. The packer expands every cell into NAND records and merges identical ones. That is where the half adder
   (5) and the full adder (9) come from: the XOR and the carry share NANDs.
4. No single ABC script wins on every design, and one run costs about two seconds, so `auto` runs twelve
   and keeps the smallest (ties go to the earlier recipe, so the result is deterministic).

**NAND records by recipe** (bold = smallest; `auto` picks it):

| Design | Latches | nand-area | g-nand | g-nand-ripple | compress | area | keep | xor-area | compress2 | dc2-compress | compress-remap | dc2x4 | keep-dch | resyn2x2 | compress-nodch | nf | auto |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| add12 | 0 | 138 | 139 | 138 | **104** | **104** | **104** | **104** | **104** | **104** | **104** | **104** | **104** | **104** | **104** | **104** | 104 |
| sub12 (12-bit subtract with borrow) | 0 | 137 | 139 | 138 | 129 | 128 | **117** | 127 | 129 | 128 | 122 | 128 | **117** | 128 | 129 | 118 | 117 |
| cmp12 (a < b) | 0 | 78 | 91 | 79 | 75 | 77 | 80 | 77 | 75 | 77 | 77 | 77 | 79 | 73 | **69** | 79 | 69 |
| max10 | 0 | 124 | 127 | 117 | 118 | 92 | 119 | 92 | 118 | 92 | 107 | **90** | 118 | 117 | 128 | 92 | 90 |
| mux12 (2:1, 12 bits) | 0 | 37 | 37 | 37 | **37** | **37** | **37** | **37** | **37** | **37** | **37** | **37** | **37** | **37** | **37** | **37** | 37 |
| shr12 (12-bit right shift by 0..15) | 0 | 143 | 165 | 165 | 137 | 137 | **133** | 143 | 137 | 137 | 137 | 137 | **133** | 137 | 153 | 137 | 133 |
| satcnt8 (8-bit saturating counter) | 8 | 61 | 62 | 60 | **52** | 55 | 73 | 56 | 54 | 56 | **52** | 55 | 59 | 62 | **52** | 64 | 52 |
| mul8 (8 x 8) | 0 | 687 | 686 | 685 | 644 | 647 | 790 | 667 | 644 | **628** | 653 | 646 | 659 | 637 | 671 | 685 | 628 |
| probe (chips/probe) | 9 | 115 | 118 | 120 | 116 | 118 | 138 | 115 | **109** | 120 | 115 | 116 | 124 | 125 | 115 | 124 | 109 |
| mul16x8 | 0 | 1362 | 1361 | 1367 | 1279 | 1259 | 1494 | 1291 | 1279 | **1238** | 1281 | 1252 | 1275 | 1241 | 1319 | 1342 | 1238 |
| mul16x12 | 0 | 2127 | 2139 | 2136 | 2048 | 1967 | 2449 | 2025 | 2048 | **1944** | 2071 | 1967 | 2025 | 1967 | 2133 | 2090 | 1944 |
| fgish | 64 | 1696 | 1740 | 1718 | 1651 | 1660 | 2450 | 1668 | **1637** | 1643 | 1642 | 1659 | 1727 | 1653 | 1738 | 1726 | 1637 |

Against the figures built gate by gate during the design pass: ADD12 104 (same), SUB12 118 (117 here), CMP12 75
(69), MAX10 95 (90), MUX12 37 (same), MUL8 about 632 (628). On arithmetic blocks the gain over the plain
library is 10 to 25%; on mixed control logic (`fgish`) it is 3.5%.

Things that did not work, so that nobody tries them again:

- A library with majority and three-input XOR cells (`arith`) made multipliers worse (702 against 647 on mul8).
  It is defined but not in the portfolio.
- `mfs2` after `map` returned an unmapped network (295 "gates" for the adder). Not used.
- ABC's other area mapper, `amap`, was tried in two recipes on nine designs and never beat the portfolio's
  best (it tied on three), so it is not in the portfolio.

One more trap, found the hard way: Yosys's `proc` turns a `case` lookup table into a ROM cell (`$memrd_v2`).
Synthesis must map it back to logic (`memory_map`), the SAT pass cannot model it at all ("No SAT model
available for cell"), and the SMT-LIB backend leaves its contents unconstrained, which showed up as a z3
counterexample that did not exist. `tapc synth` now runs the memory passes and `tapc prove` elaborates with
`proc -norom` and refuses any design that still holds a register, latch, memory or free constant.
`tests/test_synth.py::test_case_tables_are_logic_not_roms` covers it.

## 2. Synthesis time for a roughly 2,000-gate design

The first Yosys run on a machine compiles the 63 MB wasm module: 14.2 s, cached afterwards (166 MB under
`chips/.venv/cache/yowasp`). Every later Yosys start costs about 0.85 s.

| Design | Gates | Bytes | One recipe | `auto`, 12 recipes on 4 jobs | `auto` on 1 job |
|---|---|---|---|---|---|
| probe | 118 | 799 | 1.1 s | 4.3 s | |
| mul16x8 | 1,238 | 8,666 | 1.2 to 1.5 s | 4.9 s | |
| fgish | 1,701 | 11,715 | 1.9 to 2.5 s | 5.4 s | 19.6 s |
| mul16x12 | 1,944 | 13,608 | 1.1 to 1.7 s | 5.3 s | |
| mul16x16 | 2,773 | 19,411 | 1.3 to 2.0 s | 6.2 s | |
| mul20x16 | 3,413 | 23,891 | 1.2 to 2.5 s | 6.9 s | |

So about 1.5 s per recipe and 5 to 7 s for the whole portfolio at 2,000 to 3,400 gates. Roughly half of each
recipe's time is the wasm start.

For the record, the real Flow Governor core that the chip work stream wrote (`chips/rtl/fg_core.v`) rebuilds
with this toolchain to 1,889 NAND + 64 LATCH = 1,953 gates, 13,479 bytes, in 8.5 s, byte-identical to their
committed `chips/out/fg.tap` from a different directory and a different virtual environment.

## 3. SAT equivalence time at that size

RTL core against netlist bytes, every (s, x). "Yosys" is the miter plus the built-in SAT pass (MiniSat); "z3" is
the independent path (word-level SMT-LIB of the RTL against a formula built from the bytes). Times include the
Yosys start.

| Design | Gates | Free bits | Yosys SAT | z3 |
|---|---|---|---|---|
| probe | 118 | 11 | 1.1 s | 1.5 s |
| add12 | 104 | 24 | 1.6 s | 1.6 s |
| fgish | 1,701 | 160 | 10.3 s | 18.1 s |
| Flow Governor (`chips/out/fg.tap`, the chip work stream's real core) | 1,953 | 160 | 39.3 s (57.9 s in their own run, with other proofs in parallel) | 74.8 s (their run) |
| mul8 | 628 | 16 | 20.8 s | 14.5 s |
| mul16x8 | 1,238 | 24 | no verdict in 900 s | no verdict in 900 s |

Adders, comparators, multiplexers and state machines at 2,000 gates and 160 free bits take seconds to about a
minute. Multipliers are the known hard case for SAT and grow fast: an 8 x 8 takes 20 s and a 16 x 8 gave no
verdict in 15 minutes with either engine. A chip that needs a wide multiplier should check that block by
exhaustive simulation and keep it out of the miter: all 16,777,216 inputs of the 16 x 8 netlist were checked
against a Python model in 3.0 s with the bit-sliced simulator.

**Yosys's own time limit does not work in the wasm build.** `sat -timeout 900` never fired (WebAssembly has no
signals): the solver was still running at 1,020 s. `tapc prove` therefore enforces the limit itself by stopping
the Yosys process, reports the proof as `timeout`, and starts a fresh process for the proofs queued behind it.
The limit is per proof, not per batch (`tests/test_synth.py::test_proof_time_limits_are_enforced` and
`test_time_limit_is_per_proof_not_per_batch`). z3's limit works as documented.

Properties are much cheaper than equivalence. Each of the probe's properties takes under 0.2 s after the Yosys
start. The Flow Governor's 32 wrapper properties, given to `prove_properties` as one list, were all proven in
one Yosys process in 17.9 s (0.24 to 0.6 s each), and by z3 in 56 s. Proving them one process per property costs
2 to 7 s each instead, because every process pays the Yosys start and the elaboration of the netlist again.

Every proof path was checked for vacuity: a netlist with one NAND input changed is refuted with a
counterexample by both engines, the counterexample is replayed through the simulator and really differs, and a
deliberately false property is refuted by both engines (`tests/test_synth.py`).

## 4. Is the output byte-deterministic?

**Yes, on this machine.** The same sources give the same `.tap`, `.hex`, `.manifest.json` and `.map.json`,
byte for byte:

- across repeated runs (`tests/test_synth.py::test_build_is_byte_deterministic`,
  `tests/test_probe.py::test_rebuild_reproduces_the_committed_bytes`);
- across build directories and across 1, 4 and 6 parallel jobs (`fgish`: keccak `0x7f7cfb34...2ec4` every time;
  even the intermediate BLIF files are identical);
- across two virtual environments with the same pinned wheel (the Flow Governor, section 2).

Not tested: another operating system or CPU. The argument that it should hold is that Yosys and ABC run as one
fixed WebAssembly module, whose execution does not depend on the host, and that none of the ABC commands used
has a time limit or a random seed. Until someone builds on Linux and compares the keccak, treat cross-platform
reproducibility as likely, not established.

What goes into the bytes: the Verilog sources, the recipe table in `tapc/synth.py`, the cell table in
`tapc/cells.py`, the packer, and the pinned wheel. Changing any of them can change the keccak; the manifest
records the recipe, the Yosys version and the SHA-256 of each source.

## 5. Multicall3 batch size under the 50M eth_call cap

`step` calls per `aggregate3` eth_call that succeed, found by probing (the largest k that works; k + 1 fails):

| Circuit | Gates | Gas per step (eth_estimateGas) | Steps per eth_call | Where |
|---|---|---|---|---|
| probe | 118 | 323,972 | 64 (tapc's own ceiling) | local fork |
| fgish | 1,701 | 4,061,611 | 12 | local fork, eth_call given 50M gas |
| mul16x12 (`eval`) | 1,944 | 4,517,847 | 11 | local fork |
| `0x8dff4c46...6ef5` #2 | 2,463 | 5,691,051 | **8** (9 fails) | public RPC |
| mul16x16 (`eval`) | 2,773 | 6,418,115 | 7 | local fork |
| `0x933FC3AA...Db5a` #1 (Trivium) | 3,035 | 7,222,444 | **7** (8 fails) | public RPC |
| mul20x16 (`eval`) | 3,413 | 7,887,457 | 6 | local fork |
| `0xAa13ae45...AF21` #3 | 4,863 | 11,508,536 | **4** | public RPC |

So for a 2,000 to 3,400-gate chip the batch is **11 down to 6**. `floor(50,000,000 / (2,310 x gates + 25,000))`
reproduces all eight rows; it is a fit to these points, nothing more. The figure from eth_estimateGas is a
little above the gas actually used, which is why 7 x 7.22M = 50.6M still passes. `tapc difftest` does not rely
on any of this: it probes the node at the start, and if a batch still fails it halves it and retries.

Other limits, re-measured on `https://rpc.xlayer.tech`: a JSON-RPC batch of 10 calls is accepted and a batch of
11 is rejected with `-32014 too many RPC calls in batch request`; 8 requests in flight were never throttled
(0 HTTP retries in every run).

## 6. difftest throughput on the public RPC

2,000 vectors against Trivium (3,035 gates, 288 state bits) on `https://rpc.xlayer.tech`: 11.6 s on chain,
**10,318 vectors per minute**, 40 HTTP requests, 0 retries, 2,000 of 2,000 identical. Settings: 7 steps per
eth_call, 10 eth_calls per JSON-RPC batch, 8 requests in flight.

A 10,000-vector run on a chip of that size therefore takes about one minute, plus about 15 s of start-up reads
(each single call to the public RPC takes 1.2 to 1.5 s). The design notes had guessed five minutes.

On a local anvil fork the same test runs at 23,000 (3,413 gates) to 600,000 (probe) vectors per minute.

The simulator is not the bottleneck: 10,000 vectors through a 3,035-gate netlist take 91 ms bit-sliced (about
110,000 vectors per second); one scalar beat takes 0.27 ms.

## 7. Facts read from the chain that others may need

Read on a local anvil fork of X Layer at block 72,372,765, against the real factory
`0x1f09DAeFA827f02CBb40967cc91b259763760761`, and on the public RPC:

- `deployFee()` = 0.0066 OKB (creating a processor). `protocolFee()` = 0.00066 OKB, charged once per `mint`
  call, so twice per chip (one call for NAND, one for LATCH). `TAPEOUT_FEE()` = 0.0013 OKB.
- Tape-out gas, measured with the real contracts on the fork:

  | Netlist | Gates | Bytes | `tapeout` gas |
  |---|---|---|---|
  | probe | 118 | 799 | 567,908 |
  | fgish | 1,701 | 11,715 | 5,026,164 |
  | mul16x12 | 1,944 | 13,608 | 5,781,786 |
  | mul16x16 | 2,773 | 19,411 | 8,153,063 |
  | mul20x16 | 3,413 | 23,891 | 9,985,082 |

  That is about `242,000 + 408 x bytes`, or `231,000 + 2,858 x gates` for NAND-heavy netlists. The earlier
  guess (212k + 2,900 per gate) was close. `mint` costs 157,600 gas for NAND and 86,400 for LATCH.
- `step` gas is 2,311 to 2,388 per gate (fork, 1,701 to 3,413 gates), in line with the 2,310 to 2,370 measured
  earlier on live circuits.
- **A mint recipient with code reverts.** `Transistors.mint` goes through the ERC-1155 acceptance check. On the
  fork, anvil's default account `0xf39F...2266` reverted with `ERC1155InvalidReceiver` because on X Layer that
  address carries an EIP-7702 delegation (its code is `0xef0100...`). The wallet that mints must have no code,
  or implement `IERC1155Receiver`. `tapc fork-tapeout` therefore uses an impersonated throwaway address.
- The circuit implementation behind the beacon was `0x977f217887e085d298cb3819cdad5a0ee35f29b2`, runtime code
  12,562 bytes, keccak `0x7a15c353205e5245f40f5f5524542a982a4bb3b9a28476e4f10845163f941b30`, at the start and
  at the end of every run. `tapc difftest` records both in its evidence file.
- Live comparison (public RPC, read-only): 36 of 36, 36 of 36, 80 of 80 and 2,000 of 2,000 vectors identical on
  the circuits in section 5. The contract reads state and inputs leniently exactly as TAP-20 section 5 says
  (padding bits, an extra byte, short and empty strings), and `eval` reverts on a circuit with latches.

## 8. Limits of the toolchain as it stands

- Flat netlists only in `pack`, `unpack` and `prove`. `netlist` and `sim` handle REF (needed for TAP-20's own
  vectors); nothing produces it.
- An `x` (don't care) in RTL is read as 0 by both proof paths, and an undefined net is an error in the packer.
  Cores must define every bit.
- Verilog `` `include `` is not supported: `tapc synth` copies the listed source files into its build directory
  and runs Yosys there (the wasm sandbox cannot see `/tmp` of the host on Linux). List every file.
- `block` in `<name>.map.json` is filled only with `tapc synth --hier`, which maps each module separately and
  costs gates (53 against 60 NAND on the small test core). Without it every gate still has `level` and `cone`
  (which output and next-state fields it can influence), computed from the bytes.
- An output that is also used inside the chip costs one extra NAND (outputs must be the last signals, and a
  NAND can only read backwards). The probe pays 5 of these; the minimum for any chip is one record per output.
