# Flow Governor and Glutton: notes

Decisions, measured numbers, open questions and how to run everything. Written for whoever signs off the constants and for whoever tapes the chip out. The rule itself is described in plain language in `chips/model/FLOW_GOVERNOR.md`.

This is the build for `chips/INTERFACE.md` revision 2 (2026-10-05). Nothing here was sent to mainnet. Chain work was read-only or on a local anvil fork.

## 1. What exists

| Path | What |
|---|---|
| `chips/rtl/fg_params.json` | Every chip constant, the reference envelope and the reference token's curve. The single source of truth |
| `chips/rtl/gen_params.py`, `fg_params.vh` | The `.vh` is generated from the JSON. The generator first checks the relations the RTL relies on, the envelope against the kernel factory's limits, and the token-regime thresholds against the curve |
| `chips/rtl/fg_core.v` | The chip: `fg_core(s[63:0], x[95:0]) -> (ns[63:0], y[111:0])`, pure combinational |
| `chips/rtl/test_fg.py` | RTL == model on the netlist bytes: 600,000 vectors and every scenario trace |
| `chips/rtl/Makefile` | Entry point for everything below |
| `chips/model/flow_governor.py` | Bit-exact behavioural model, built on `chips/golden/kernel_model.py` |
| `chips/model/scenarios.py` | Scenario runner: the model inside a simulated revision-2 kernel (vault, curve, pair, echo, execution limits, fallback word), behaviour checks, cadence test. `--ideal` gives the kernel without echo and limits, `--compare` both side by side |
| `chips/model/export.py` | Writes `fg.fields.json`, `fg.vectors.json`, `fg.scenarios.json` and the per-epoch scenario tables |
| `chips/model/FLOW_GOVERNOR.md` | The control law for the judge guide, the 64 latch bits, the witness |
| `chips/props/fg_props.v`, `fg_props.py` | The properties, as Verilog wrappers and again as z3 predicates on the bytes |
| `chips/props/witness.py`, `prove.py`, `mutants.py` | Witness generator; the script that runs every proof and records times; ten broken chips that the proofs must reject |
| `chips/props/model_equiv.py`, `symexec.py` | Model == bytes for every (state, input): the model's source executed on z3 terms, and a hand-written twin |
| `chips/synth/fg.pins.json`, `gen_pins.py`, `fork_test.py` | Field names for the packer; generator of the pin manifest; local-fork tape-out and difftest |
| `chips/cells/glutton/` | The hostile demo chips, their proofs, the clamp demo, a README |
| `chips/out/` | `fg.tap`, `fg.hex`, `fg.manifest.json`, `fg.map.json`, `fg.pins.json`, `fg.fields.json`, `fg.proofs.json`, `fg.model.json`, `fg.witness.json`, `fg.vectors.json`, `fg.scenarios.json`, `fg.fork.json`, `fg.difftest.jsonl`, `scenarios/` |

## 2. Final numbers

| | Flow Governor | Limit |
|---|---|---|
| NAND | 1,888 | |
| LATCH | 64 | 256 (target 64) |
| Gates | 1,952 | 3,400 (target about 2,200) |
| Netlist bytes | 13,472 | 24,000 |
| NAND depth | 163 | none |
| keccak256 of the bytes | `0xe548768a1adafa7331faacfd029e1a829b00af3f7d769657f3b234ccdd7143b4` | |
| `step` gas (fork, `eth_estimateGas`, 18 samples) | 4,602,131 to 4,631,070, mean 4,614,966 | |
| Gas per gate | 2,364 | |
| Tape-out gas (fork) | 5,744,729 | |
| Transistor cost at 0.00002 OKB | 0.03904 OKB, plus 2 x 0.00066 mint fee and 0.0013 tape-out fee | |
| Pin manifest (`chips/out/fg.pins.json`, 12,487 bytes), SHA-256 | `0xfe8b7a49a7d0f9a75d0684b88587648284fc586f936035f8831cb6d34060e209` | 65,536 bytes |

Built by `tapc synth --recipe auto` (Yosys 0.69, recipe `rich-dc2-compress` won among twelve; the ABC script is recorded in `fg.manifest.json`). Rebuilding from clean gives the same keccak (three rebuilds while this revision was made). The keccak depends on the tapc recipes: if they change before tape-out, rebuild, re-prove, regenerate the pin manifest and re-run the fork test. Every proof takes the bytes as input, so any final netlist is checkable.

The only source change since the revision-1 build (1,889 NAND, keccak `0x2fd0e007...`) is two constants, `FLOOR_T` and `RESMIN_T` (section 4). `fg_core.v` is unchanged.

Where the gates go, from the cones in `fg.map.json`: 137 NAND and 21 latches serve only the telemetry latches (`NBANK`, `NDEF`, `CLOCK`); 45 NAND are constant output bits (`T_HOLD` and the revenue group), which the format forces; 20 NAND serve only `FLAGS` and `AUX`. Nothing had to be shed. If gas ever mattered, dropping the telemetry latches would save 158 gates (about 0.37M gas per step).

Glutton and Glutton-512: 113 NAND + 1 LATCH = 114 gates, 795 bytes each; `step` 379,203 gas; tape-out 530,264 and 530,216 gas. Their bytes did not change.

**The pin manifest.** `chips/out/fg.pins.json` is a circuit manifest in the format of the draft standard in `docs/taps`: the 11 input fields and 14 output fields of the generic Covenant profile (`covenant-v1`, claimed by its SHA-256 `0x77a721cd...6eb5`), with this chip's meaning for the four telemetry outputs, plus the 14 latch fields of `FLOW_GOVERNOR.md` section 6 covering all 64 latches. It is bound to the netlist by `circuit.netlistHash` (the keccak above), `nIn` 96, `nOut` 112 and `nState` 64. `gen_pins.py` checks it with the draft's reference implementation before writing it (valid; describes this netlist; implements the profile; the netlist has the profile's shape), runs the generic codec against the model, and the draft's JSON Schema accepts it (jsonschema 4.26.0). On the fork it was checked against `netlist(id)` and `circuitInfo(id)` as the chain returns them. **Its SHA-256, in the table above, is the `manifestHash` the chip is to be taped out with** (`chips/INTERFACE.md` section 11). It changes whenever the netlist changes: regenerate it after any rebuild.

**Gas budget.** The kernel gives TapeOut's evaluator `200,000 + 2,600 x gateCount + 800 x nState` = 200,000 + 2,600 x 1,952 + 800 x 64 = 5,326,400 gas for one beat of this chip (`chips/INTERFACE.md` section 2). The estimate at the all-ones state and all-ones inputs is 4,631,070 gas including the 21,000 base and the calldata, the largest of the 18 samples. The interface's stated bound for what `step` needs, `101,730 + 2,293 x nNand + 3,059 x nLatch`, is 4,626,690 for this chip. So the budget has about 13% of margin on the TapeOut evaluator. The sealed evaluator was not measured here.

## 3. Decisions

1. **No holder share.** `T_HOLD` is 0 in every mode (proven). Kernel v1 folds a holder share into the reserve, so naming a share "holder" would only mislabel reserve. CRUISE is (192 - AL, 0, AL, 64): buy, holder, allowance, reserve.
2. **No start-up mode that buys nothing.** The first live reading seeds the average and routes like CRUISE.
3. **The reserve always leaks.** `REL` is at least 2 per elapsed epoch in every mode and for every reserve. This is what bounds the reserve under steady inflow (32 epochs of inflow) and it satisfies the kernel floor everywhere, so `K5` can never fire.
4. **The average has a floor, a fall limit, and is re-seeded after a drought.** A log-domain average collapses after a long silence: one empty epoch moves it a quarter of the way to the floor, a factor of 17 at 1 OKB per epoch, and thousands without a floor. Three things together prevent it: the average falls at most 3 codes per epoch; after 8 quiet epochs it is declared stale and the next live reading replaces it; and for 3 epochs after that it jumps up to any higher reading.
5. **A surge is measured against the decaying peak of the average, not the average.** A pause lowers the average but barely lowers the peak, so volume returning at its old level is never a surge. Checked by a sweep (27,324 level and pause combinations, both regimes: zero BANK entries).
6. **No trigger on a two-epoch dip.** With realistic noise it fires constantly and keeps the chip in DEFEND. DEFEND opens on three conditions: drawdown (the average is 16 codes below its peak), drought (8 quiet epochs), or fade (a BANK ends on a reading at most half the average). Fade is the release of what a surge banked.
7. **A 16x reading is banked at once.** Otherwise a single very large epoch would be bought into at the CRUISE share before the two-epoch confirmation.
8. **Everything counts epochs.** All timers advance by `DT`. A DEFEND window is 4 tranche epochs, not 4 settles; a settle that covers two or more of them releases a double tranche; when a window or a cooldown ends inside a settle, the leftover epochs are credited to the next phase.
9. **No allowance after graduation.** Kernel v1 pays none whatever a chip asks (interface revision 2). The chip asks for none (proven), so its share word says what happens.
10. **`PROG` and `LOCK` are not used.** The chip reads tax flow and the reserve only.
11. **Telemetry latches.** `NBANK` and `NDEF` count episodes; `CLOCK` counts elapsed epochs modulo 1024 so that the stored state moves on every settle, including settles with no inflow.
12. **Nothing was re-tuned for revision 2 except the two token-regime thresholds.** With the echo and the kernel's execution limits simulated, every behaviour the checks ask for still holds where the kernel can execute what the chip decides (section 8). The checks that had to be restated are about the kernel, not about a constant: the list is at the end of section 8.

## 4. Constants for sign-off

All in `fg_params.json`. Codes are `lg8` codes; amounts are `exp8(code)`.

### Chip

| Constant | Value | Meaning | Why this value | Evidence |
|---|---|---|---|---|
| `FLOOR_Q` | 346 (9.9e12 wei per epoch) | Readings at or below it are quiet; the average cannot go lower | A $1 buy at 3% tax is code 383. It must count as live even when one settle covers 15 epochs (383 - 31 = 352 > 346) | `subdust`: 1e11 to 8e12 wei never leaves IDLE. `steady-small`: $1 per epoch is CRUISE throughout |
| `TOKEN_SHIFT` | 169 codes | Token base units per wei of OKB when the pair opens | Derived, not chosen: a sold-out curve has raised 85 OKB and the pair opens with 200,000,000 tokens against them, 2,352,941 base units per wei, 169.3 codes. `gen_params.py` computes it from `reference.pairSupply` and `reference.graduationQuote` in integers | `gen_params.py --show` |
| `FLOOR_T` | 515 (23.06 tokens per epoch) | The floor after graduation | `FLOOR_Q + TOKEN_SHIFT`. Worth 9.8e12 wei at the opening price. **Changed**: it was 530 (83 tokens, 3.5e13 wei), from an assumed 2^23 units per wei | `graduation`, `graduation-busy` |
| `RESMIN_Q` | 389 (4.2e14 wei) | Smallest reserve for which a DEFEND window opens | The smallest tranche (1/8) is then about ten times the gas of one buy leg (about 4e12 wei at 0.02 gwei) | `dust`: windows open with reserves around 4e14 to 1e15 wei and stop below it |
| `RESMIN_T` | 558 (959 tokens) | The same after graduation | `RESMIN_Q + TOKEN_SHIFT`. Worth 4.1e14 wei at the opening price. **Changed**: it was 573 (3,542 tokens, 1.5e15 wei) | `graduation` |
| `M1`, `M2`, `M3` | 425, 452, 479 (0.0090, 0.0991, 1.0088 OKB cumulative) | Allowance milestones | Decades. The first is reachable with about $40 of volume, so the ratchet can be seen live on a dollar-sized token | `milestones`: tier 0, 1, 2, 3 in order; `witness`: tier 1 after one 0.01 OKB epoch |
| `AL0..AL3` | 48, 32, 16, 8 | Allowance share per tier (18.75%, 12.5%, 6.25%, 3.125%) | Halving steps, with a last step of 8 and not 0 so that a keeper-tank payee is never cut off entirely | `milestones` |
| `CEIL0`, `CEIL_STEP` | 440, 8 | Allowance ceiling per settle: 0.0338 OKB, halving per tier | A single huge epoch must not pay a huge allowance. It can bind only at tiers 2 and 3 (below that, cumulative tax is under 0.099 OKB), above about 0.135 OKB of inflow per settle | `whale`: 3 OKB of tax, allowance cut to 0.0042 OKB by the chip's own ceiling, no clamp |
| `RC` | 64 | Reserve share in ordinary flow | With the leak it gives a standing reserve of 32 epochs of inflow (8 hours) | `steady*`: settles at 32.0 epochs of inflow |
| `RB_MIN`, `RB_GAIN`, `RB_SPAN` | 128, 4, 16 | Reserve share in BANK: 50% at 2x, 75% from 8x | Round values, not tuned. At a 2x reading half of the tax is banked, so the immediate buy rises by a third to a half instead of doubling | `surge`: 192, 168, 148, 136, 132, 128 as the average catches up |
| `SURGE_TH` | 8 codes (2x) | Surge threshold against the peak | A round value, not tuned. Far enough above a 9%-wide code and the 3% echo that neither can cross it | `silence-return`, `pause-return`, pause sweep |
| `XSURGE_TH` | 32 codes (16x) | Counts double: BANK at once | High enough to be rare under ordinary noise, low enough to catch a single very large epoch | `whale`, the mode tour in `fg.witness.json` |
| `DD_TH` | 16 codes (a quarter) | Drawdown trigger | A round value, not tuned. With the fall limit it needs six epochs of decline | `witness`, `crash`, `drawdown`, `launch` |
| `DIP_TH` | 8 codes (half) | Fade trigger and the dip flag | The mirror of `SURGE_TH` | `whale`, `surge` |
| `SLEW_Q` | 12 (3 codes per epoch) | Fall limit of the average | An arithmetic average with gain 1/4 loses 3.3 codes on an empty epoch | `drought` |
| `PK_DIV` | 4 | The peak loses a code every 4 epochs (halves in 8 hours) | How long "recent peak" lasts. Sets how long DEFEND windows repeat after a crash: 64x down gives about 32 hours | `crash`: 12 windows in 120 epochs |
| `DRYN` | 8 | Quiet epochs to a drought (2 hours) | A round value, not tuned | `drought` |
| `WARMN` | 3 | Warm-up epochs after a cold start | Long enough to see a second and third reading before classing anything | `silence-return` |
| `TRN`, `CDN` | 4, 6 | Tranche epochs per window, cooldown epochs | Round values, not tuned: an hour of release, an hour and a half of rest | `drought`: DEFEND 4, REST 6, repeating |
| `TR_MIN`, `TR_MAX` | 32, 64 | Tranche per epoch: 12.5% at 16 codes of drawdown, 25% from 32 | A full window releases 41% to 68%. A tranche of 50% would empty the reserve in one hour | `drought`, `drawdown` |
| `LEAK` | 2 | 0.78% of the reserve per epoch, always | Equals the envelope floor. Half-life 22 hours | `steady*`, `drought` tail |
| `LOG8DT` | round(8 log2 dt) | Turns a settle covering `dt` epochs into a per-epoch rate | Checked entry by entry in `gen_params.py`, in integers | cadence test |

### Reference envelope (immutable per kernel)

| Field | Value | Why | Factory limit (`INTERFACE.md` section 7) |
|---|---|---|---|
| `epochLen` | 900 | Given | 300 to 86,400 |
| `capT` | 48 | Equal to `AL0`: the envelope is exactly the chip's worst case. Glutton gets 18.75% of inflow and no more | at most 128 |
| `capV` | 0 | Kernel v1 has no revenue; the chip's `V_ALLOW` is 0 | at most 255 |
| `allowCumBps` | 1875 | Exactly 48/256. See "lifetime cap" below | at most 5,000 |
| `ceilMax` | 440 | Equal to `CEIL0` | at most 1,023 |
| `relMax` | 128 | Equal to the largest release the chip can ask for (a double tranche of 64) | 1 to 256 |
| `floorRel` | 2 | Equal to `LEAK` | 1 to `relMax`, and `epochLen x 178 <= 2,592,000 x floorRel`: 160,200 against 5,184,000 |
| `floorMin` | 1 | The floor applies to every non-empty reserve. The chip meets it for every reserve, so any value works; 1 gives the strongest disclosure | 1 to 425 |
| `fallbackEpochs` | 16 | One more than the `DT` saturation. Only matters if `step` itself fails | at least 2, and `epochLen x fallbackEpochs <= 30 days`: 14,400 s |
| `fbAllow` | 8 | Equal to `AL3`. A larger value would let a dead chip pay more than the ratchet's last tier, which would loosen it | at most `capT` |
| `buyEnabled` | true | The reference kernel buys | (`sink` must be set otherwise) |

Every limit in the last column is asserted by `gen_params.py` (`check_envelope`), so a reference envelope the factory would refuse cannot be built against. The three address fields (`launcher`, `allowancePayee`, `sink`) are deployment-time and not part of the JSON.

**The lifetime cap never binds.** After `K2` the kernel has `T_ALLOW <= capT`, so each settle credits at most `floor(inflow_i * 48 / 256)`. A sum of floors is at most the floor of the sum, so the allowance paid through settle n is at most `floor(cum_n * 48 / 256) = floor(cum_n * 1875 / 10000)`, which is the cap. Hence `allow_n <= room_n` for every chip, not only this one. `gen_params.py` asserts `allowCumBps * 256 >= capT * 10000`; `prove.py` drives 200,000 random settles through `route_tax` with the share at the cap (0 hits); every scenario row has `clamp == 0`.

**The cap is on inflow, and inflow includes the echo.** Against the tax that outside trading paid, a chip that always takes the cap ends at 18.75 / (1 - 0.03 x 0.8125) = 19.2%, not 18.75% (Glutton: 19.19% to 19.21% in the demo). Section 9, item 2.

## 5. Latch budget

64 of 64 used. `A` 12, `PK` 10, `PKDIV` 2, `MODE` 3, `TIER` 2, `GSEEN` 1, `WARM` 2, `LIVE` 4, `SUR` 2, `TR` 2, `CD` 3, `NBANK` 5, `NDEF` 6, `CLOCK` 10. Bit positions and the die rows are in `FLOW_GOVERNOR.md` section 6, `chips/out/fg.fields.json` and the pin manifest. `LIVE` counts down, so that the reset state is cold.

## 6. Proofs

`make -C chips/rtl prove` runs the 98 checks about the RTL and the properties and writes `chips/out/fg.proofs.json`; `make -C chips/rtl modelproof` runs the model proof and writes `chips/out/fg.model.json`. All statements are about the netlist bytes, for every 64-bit state and every 96-bit input. Times are solver times on this machine (10 cores) in the runs made for this build; they move by a fifth or more from run to run.

| Group | What | Yosys SAT | z3 on the Yosys wrapper | z3 on terms built from the bytes |
|---|---|---|---|---|
| EQ | bytes == `fg_core.v` | 46 to 56 s | 53 to 63 s (word-level SMT-LIB of the RTL against the bytes) | |
| P1 | share groups sum to 256, each <= 256, holder share 0 | 5 checks, <= 0.3 s each | 5, <= 1.3 s | 3, <= 0.3 s |
| P2 | `K2`, `K2V`, `K3`, `K5` (also for every reserve), `K2C` | 7, <= 0.3 s | 7, <= 3.0 s | 6, <= 0.4 s |
| P3 | tier never decreases; allowance and ceiling bounded by the tier; a higher tier never loosens (two copies); tier frozen and allowance 0 after graduation | 8, <= 2.4 s | 8, <= 1.3 s | 4, <= 0.3 s |
| P4 | invariant true at reset and inductive; MODE output equals the MODE latch | 3, <= 0.3 s | 3, <= 1.3 s | 3, <= 0.4 s |
| P5 | `REV`, `REVCUM`, `ESC`, `PROG`, `LOCK`, bits 81..95 ignored (two copies) | 6.0 s | 0.8 s | 0.0 s (the bytes do not reference those inputs) |
| P6 | cooldown: only the leak, counter strictly decreasing, stays in REST; a release above the leak is a flagged tranche; DEFEND routes everything to buy | 5, <= 0.3 s | 5, <= 18 s | 2, <= 0.3 s |
| P7 | witness and mode tour (26 concrete steps) | 7 checks, <= 1.4 s | not available: see below | 0.02 s, plus a replay with `tapc.sim` |
| extras | `DT = 0` reads as 1; graduation seen once; the graduation step only re-seeds | 3, <= 1.6 s | 3, <= 1.4 s | 3, <= 0.4 s |
| K2L | lifetime cap | arithmetic argument and 200,000 random settles | | |

98 of 98 pass: 96 solver checks and 2 tests (the witness replay and the K2L argument with its randomized test). The Yosys equivalence check is two-sided since 2026-10-06 (an earlier `-ignore_gold_x` made it one-sided; see section 7). Wall time 53 to 63 s with 6 processes.

**Model == bytes** (`model_equiv.py`, new in this build). The behavioural model used to be tested against the bytes on sampled vectors only. It is now proven equal to them for all 2^160 (state, input) pairs, along two independent routes:

| Route | Formula | Proven equal to the netlist | Also proven | Solver time |
|---|---|---|---|---|
| A | `symexec.py` executes the source of `flow_governor.step` (and of `_satsub`, `kernel_model.pack_output`, `pack_fields`) on z3 terms. The result is the Python function itself as a formula | 28 of 28 fields, 176 of 176 bits | 16 of 16 conditions under which Python would raise are impossible: the model's `assert`, two table indices, a shift count, nine range checks and the final assert of `pack_fields`, and the two returned words fit 64 and 112 bits | 276 to 424 s |
| B | `twin()`: the same rule written by hand as 16-bit z3 terms | 28 of 28 fields, 176 of 176 bits | 29 of 29: the same assert and every field width | 123 to 174 s |

One z3 query per field per route ("some bit of this field differs" is unsatisfiable), 8 processes, 57 to 86 s of wall time for the 101 queries; the slowest single field took 74 s on route A and 30 s on route B. The netlist terms are built straight from the bytes. Both formulas are also compiled back to Python and compared with the real `step` on 630,942 vectors each (200,000 uniform, 200,000 boundary-biased, 200,000 on walks, 30,942 scenario settles): 0 mismatches, and 0 on the 600 of them that z3 itself evaluated. For route A that is a test of the symbolic executor; the proof does not use it.

What route A rests on: z3; the construction of the netlist terms in `tapc.prove`; and `symexec.py`, under 500 lines that give Python's meaning to the constructs `step` uses and refuse every other construct. Its integers cannot wrap: every term is 160 bits wide and carries a bound on its magnitude, and an operation whose result could approach the width raises. Route B shares none of the executor, so a mistake in it would have to coincide with a mistake in a twin written by hand.

**The proofs can fail.**

- What this does and does not show: the properties pin down the envelope (no kernel clamp can fire) and the structural guarantees. The control law itself is pinned only by netlist == RTL and netlist == model. An independent review built 28 further broken chips: 19 were caught by a named property on both engines, the other 9 (wrong constants, a missing reset at graduation, a time bomb on one clock value) only by the two equivalence proofs, which caught all of them.
- `make -C chips/rtl mutants` builds ten deliberately broken chips (allowance 49 at tier 0, a leak under the floor, a tier that follows `TAXCUM` down, DEFEND on the graduation step, `PROG` leaking into a decision, a share group summing to 255, a tranche during the cooldown, a peak below the average, an allowance after graduation, a ceiling one code above the envelope) and runs the matching properties on their bytes. All ten are caught, each with a counterexample.
- The model proof is run against wrong formulas as well. For each of the 28 fields and each route, a formula that differs from the right one in one bit at one randomly chosen point of the 2^160 is refuted, and the counterexample is exactly that point (56 of 56). The model run with one wrong constant (`FLOOR_T`, `RESMIN_Q`, `M2`, `DD_TH`, `XSURGE_TH`, `CDN`, `TR_MAX`, `RC`, each off by one) is refuted on both routes with a counterexample on which the bytes, simulated, give the real model's answer and not the wrong one (16 of 16).

Notes on the proof tooling:
- A `case` statement inside a function becomes a ROM cell in Yosys (`proc_rom`). The SAT pass then stops with "No SAT model available for cell $meminit" and the SMT-LIB writer leaves the table unconstrained, which produced a spurious z3 counterexample. `fg_log8dt` is therefore written as a chain of conditionals.
- The z3 route through Yosys's SMT-LIB writer overflows the wasm stack on the chained witness wrapper (27 copies of the netlist in series). The witness is checked by Yosys SAT on that wrapper and by z3 on the bytes step by step instead.
- z3's Python API is not thread-safe: `prove.py` and `model_equiv.py` run one process per proof.

## 7. RTL == model, netlist == RTL, chain == model

- **Netlist == RTL**: the EQ row above, two engines, every (s, x). Until 2026-10-06 the Yosys half passed `-ignore_gold_x` to `miter`, which turned it into a one-sided check (netlist bits could be 1 where the RTL's were not); the z3 half was always two-sided. The flag is removed; the two-sided Yosys check proves the real netlist in about 4 s and rejects broken netlists that the one-sided check had passed.
- **Netlist == model**: the model proof above, two routes, every (s, x). The sampled comparisons below are kept as tests of the tools, not as the evidence.
- **RTL == model, sampled**: `test_fg.py` evaluates the bytes with a small evaluator written from the vendored `NetlistVM.sol` (independent of tapc) and compares 64 next-state bits and 112 output bits with the model: 200,000 uniform random (s, x), 200,000 boundary-biased (fields drawn around every threshold), 200,000 on random walks from reset with kernel-shaped inputs, and 30,942 scenario settles (every scenario under the revision-2 kernel and under the idealised one, at seven cadences). 630,942 vectors, 0 mismatches. A 2,000-vector sample of each set is also run through `tapc.sim`: 0 mismatches. A one-off longer run with another seed (`--n 2000000 --seed 7`, 6,030,942 vectors) also gave 0.
- **Model vectors on the bytes**: `tapc sim chips/out/fg.tap --check chips/out/fg.vectors.json`: 8,286 of 8,286.
- **Chain == simulator == model** (`make -C chips/rtl fork`, local anvil fork at block 72,373,000): 16,332 vectors (4,000 uniform, 3,000 walk, 3,000 boundary, 6,311 scenario, 19 tour, 2 witness). All 16,332 on-chain `step` answers equal `tapc.sim` and equal the Python model. `netlist(id)` returned exactly the local bytes, and the pin manifest describes the circuit as the fork returns it. The witness was replayed with two plain `eth_call`s. Implementation `0x977f217887E085D298Cb3819cDAD5A0ee35F29B2`, code hash `0x7a15c353205e5245f40f5f5524542a982a4bb3b9a28476e4f10845163f941b30`. Glutton and Glutton-512: 300 of 300 each.

The free test processor `cpuAt(0)` (`0x839bdD6f...574e`) could not be used: at the pinned block its supply is fully minted (`minted == supplyCap == 100,000`). The fork test creates a throwaway processor through the real factory instead (`createCPU`, 0.0066 OKB), which is the same path the Covenant processor will take, and uses the same beacon implementation. Anvil's first development account also cannot be used: on X Layer it carries code, so the ERC-1155 mint reverts with `ERC1155InvalidReceiver`. The script funds and impersonates a key-less address.

## 8. Scenario findings

`make -C chips/rtl scenarios` prints one line per scenario, 32 behaviour checks and the cadence test. Per-epoch tables are in `chips/out/scenarios/`, totals under both kernels in `chips/out/fg.scenarios.json`. `clampBits` is 0 on every row of every scenario and every cadence.

### What the runner simulates

The kernel side is `chips/golden/kernel_model.py` and nothing else: `route_tax(..., graduated=...)`, `dt_code` from the last persisted step, `fallback_word`, `prog_code`, `lock_code`, `curve_buy`, `impact_cap`, `v2_net_out`. One settle follows the order of the interface: regime latch, claims, books by balance, input word, evaluator or fallback word, clamps, effects, legs. Around it the runner simulates what the first version of the runner did not have:

- **The echo.** The kernel's curve buy pays the 3% buy tax into the kernel's own vault; the next settle claims it as inflow. After graduation the router buy that spends the native pot pays its tax in tokens, which is inflow of the token regime.
- **Execution limits.** The curve buy is `kernel_model.curve_buy` on a simulated IGNIX curve of the reference token (fresh at 28.33 OKB of virtual quote, 800,000,000 tokens to sell, graduating at 85 OKB): `min(decided, impact cap, largest non-graduating buy)`. The curve is moved by the scenario's outside trades and by the kernel's own buys. What does not execute stays in the reserve and is offered again.
- **Graduation.** At a scenario's `grad_epoch` an outside buyer takes the rest of the curve. Its tax lands in the vault as OKB. The pair opens with 200,000,000 tokens against the 85 OKB raised. In the first settle that sees the pair, `TAXCUM`, the reserve and the allowance total restart, and the OKB the kernel holds becomes the native pot, which the kernel spends by itself through capped router buys.
- **Evaluator failure.** While the evaluator is down a settle reverts for `fallbackEpochs - 1` epochs, then the fallback word routes; `DT` keeps counting from the last persisted step.

How a scenario's numbers become trades: a scenario lists the tax outside trading pays per epoch. By default that trading is round trips, which leave the curve where it was; `net_buy` is the share that comes from one-way buys (`noisy-dollars` 50%, the first 40 epochs of `launch` 100%, the two graduation flows 50%). The simulated curve and pair reproduce, to the base unit, five numbers measured against the live Manager and router on a fork (`contracts/probes/FINDINGS.md`): a 0.5 OKB curve buy, the largest non-graduating buy, the cost of the whole curve with its refund, the 85 OKB pair, and a 0.5 OKB router buy.

`--ideal` switches both effects off and reproduces the numbers of the revision-1 build line for line (apart from the two graduation flows, which see the new thresholds).

### Outcomes, revision-2 kernel

| Scenario | Outcome |
|---|---|
| `steady`, `steady-small` | CRUISE throughout. The reserve settles at 32.0 epochs of inflow, which is 33.0 and 32.9 epochs of outside tax because inflow now carries the echo. Worst case for any steady flow: (64 + 48) / 2 = 56 epochs |
| `steady-large` (2 OKB of tax per epoch) | Far more than the reference curve can take. Every buy is shrunk to the kernel's cap (0.49 OKB, rising to 1.89 as the curve fills). At epoch 86 the kernel's own buys have brought the curve to 21 base units from its end; from then on its buys are zero (it never graduates a token) and everything but the allowance waits in the reserve. With execution limits off the reserve settles at 35.7 epochs of inflow as before |
| `surge` (16x for 8 epochs) | BANK from the second surge epoch, reserve share 192 falling to 128 as the average catches up; when the surge ends the fade trigger opens DEFEND; five more windows follow while the drawdown lasts. 3.2% left after 80 epochs |
| `drought` | DEFEND after 6 quiet epochs (drawdown), then 4 on, 6 off, until the reserve is under `RESMIN`; then IDLE and the leak. 0.2% of the peak reserve is left after 160 quiet epochs |
| `silence-return` | After 200 quiet epochs the first live settle re-seeds the average; no BANK epoch |
| `pause-return` | Pauses of 5, 3 and 7 epochs: no BANK. The 7-epoch pause opens one DEFEND window |
| `dust` ($1 to $4 buys in one epoch of eight) | Mostly IDLE, CRUISE and DEFEND/REST cycles on a reserve of 4e14 to 1e15 wei. 2 BANK epochs in 600. 85% bought, 13% allowance, 2% left |
| `subdust` | Never live. IDLE. Routed at CRUISE shares |
| `noisy`, `noisy-dollars` | See "worth a second look" below |
| `launch` | The launch epoch seeds the average and is routed at CRUISE shares; its 0.275 OKB buy is under the cap; the one-way launch buying and the kernel's buys sell 81% of the curve's tokens; the decay that follows opens DEFEND windows |
| `milestones` | Tier 0, 1, 2, 3; allowance 48, 32, 16, 8. In the last phase (1 OKB of tax per epoch) 24 buys are shrunk by the cap |
| `whale` | The 3 OKB epoch is banked at once (reserve share 192), allowance cut to 0.0042 OKB by `CEIL`; the 0.70 OKB buy decided in that epoch is shrunk to 0.489 OKB; fade opens one DEFEND window that releases 41%; the rest leaves by the leak |
| `graduation` | In the first graduated settle `TAX` equals `TAXCUM` and `RES` is 0; the chip re-seeds, keeps the tier, asks for no allowance. The native pot (2.275 OKB, of which 2.029 is the tax of the graduating buy) is spent in 3 router buys; their token tax is a pulse 7.5 times the outside flow, see below |
| `graduation-busy` | Graduates in BANK. Same sequence; the pot (2.552 OKB) is small against a busy token flow (0.15% of token inflow) and changes little |
| `hostile-timing` | Gaps of 1 to 40 epochs: no clamp, tier never falls |
| `failed-buys` | Two settles in three the Manager refuses the buy (160 refused buys, flag 16). The amounts stay in the reserve and are offered again; every base unit is accounted for |
| `outage` | The evaluator is down for 40 epochs: 15 reverted settles, then 25 fallback settles (8/256 allowance, half the reserve released, state untouched, no clamp bit). On recovery the rate is under-read once (`DT = 15` against one epoch of tax), one DEFEND window follows, CRUISE again 11 epochs after recovery |
| scale | The `surge` flow at x1/4, x1 and x4 gives the identical mode sequence under the full kernel; at x16 and x1,024 with execution limits off |

### What the echo and the execution limits changed

Idealised kernel on the left of each arrow, revision-2 kernel on the right; one value where they agree. Percentages are of the tax outside trading paid; "bought" is net of the tax the kernel's own buys paid back; "left" is the reserve at the end plus what waits in the vault. For the two graduation flows the row is the token regime.

| Scenario | Allowance % | Bought % | Left % | IDLE / CRUISE / BANK / DEFEND / REST settles | Echo % | Kernel limits |
|---|---|---|---|---|---|---|
| `steady` | 5.01 -> 5.10 | 87.3 -> 87.0 | 7.7 -> 7.9 | 0/400/0/0/0 | 2.7 | - |
| `steady-small` | 13.00 -> 13.14 | 79.3 -> 79.0 | 7.7 -> 7.9 | 0/400/0/0/0 | 2.4 | - |
| `steady-large` | 0.21 | 91.2 -> 10.7 | 8.5 -> 89.1 | 0/400/0/0/0 | 0.3 | 400 buys shrunk, 315 skipped, curve end at epoch 86 |
| `surge` | 4.08 -> 4.34 | 92.8 -> 92.5 | 3.1 -> 3.2 | 0/80/8/24/36 -> 0/81/7/24/36 | 2.9 | - |
| `ramp` | 0.78 | 71.6 -> 71.0 | 27.6 -> 28.2 | 0/77/15/0/0 | 2.2 | - |
| `drawdown` | 4.40 -> 4.46 | 95.6 -> 95.5 | 0.0 | 0/78/0/36/85 | 3.0 | - |
| `crash` | 4.55 -> 4.60 | 95.4 | 0.0 | 0/65/0/48/67 | 2.9 | - |
| `drought` | 8.33 -> 8.52 | 91.6 -> 91.4 | 0.1 -> 0.0 | 107/65/0/18/30 -> 106/65/0/19/30 | 2.8 | - |
| `silence-return` | 7.29 -> 7.45 | 82.7 -> 82.3 | 10.0 -> 10.3 | 147/125/0/18/30 -> 146/125/0/19/30 | 2.5 | - |
| `pause-return` | 7.38 -> 7.54 | 81.7 -> 81.2 | 11.0 -> 11.3 | 0/105/0/4/6 | 2.5 | - |
| `dust` | 13.07 -> 13.17 | 84.9 -> 84.8 | 2.0 | 153/210/2/61/174 -> 155/208/2/61/174 | 2.6 | - |
| `subdust` | 18.75 -> 19.17 | 74.1 -> 73.5 | 7.1 -> 7.3 | 300/0/0/0/0 | 2.3 | - |
| `noisy` | 3.16 -> 3.26 | 92.8 -> 92.6 | 4.1 -> 4.2 | 0/375/42/63/120 -> 0/395/40/57/108 | 2.9 | - |
| `noisy-dollars` | 6.02 -> 6.67 | 93.0 -> 91.7 | 1.0 -> 1.7 | 4/164/63/203/366 -> 4/198/62/176/360 | 2.8 | - |
| `launch` | 2.75 -> 2.76 | 95.4 -> 95.6 | 1.8 -> 1.6 | 0/181/16/53/90 -> 0/133/6/81/120 | 3.0 | - |
| `milestones` | 0.74 | 70.4 -> 62.7 | 28.9 -> 36.6 | 0/102/18/0/0 -> 0/101/19/0/0 | 1.9 | 24 buys shrunk |
| `whale` | 0.90 -> 0.95 | 72.3 -> 69.6 | 26.8 -> 29.4 | 0/89/2/4/6 | 2.2 | 1 buy shrunk |
| `graduation` | 0.00 | 92.4 -> 93.6 | 7.6 -> 6.4 | 0/150/0/16/24 -> 0/110/0/32/48 | 14.8 | 2 pot buys shrunk |
| `graduation-busy` | 0.00 | 93.8 -> 93.9 | 6.2 -> 6.1 | 0/168/12/21/35 -> 0/159/11/25/41 | 0.1 | 2 pot buys shrunk |
| `witness` | 12.50 -> 12.76 | 84.2 -> 83.9 | 3.3 -> 3.4 | 5/6/0/8/12 | 2.6 | - |
| `hostile-timing` | 2.24 -> 2.30 | 90.6 -> 90.3 | 7.1 -> 7.4 | 0/46/2/3/3 | 2.8 | - |
| `failed-buys` | 7.29 -> 7.39 | 83.8 -> 91.0 | 8.9 -> 1.7 | 0/125/0/48/67 | 2.8 | 160 buys refused |
| `outage` | 5.64 -> 5.71 | 87.3 -> 87.0 | 7.1 -> 7.3 | 0/190/0/4/6 | 2.7 | - |

(`failed-buys` is not the same experiment under the two kernels: idealised, two buys in three fail and the third executes half; revision 2, two in three are refused and the third executes in full, because a curve buy cannot fill partly. `outage` is new.)

Read together:

1. **At the reference token's scale the echo is a ripple.** Where no buy is shrunk, 2.2 to 3.0% of the tax outside trading pays comes round again. The allowance rises by 0.00 to 0.65 points of that tax, the amount bought moves by at most 1.4 points, and the standing reserve is 3% higher in units of outside tax (33.0 epochs against 32.0). On the flows that are constant between changes, `graduation` aside, the mode counts are the same or differ by one settle.
2. **Execution limits never bind at that scale.** A decided buy reaches the cap only from about 0.5 OKB per settle: `steady-large`, the last phase of `milestones`, the one epoch of `whale`, and slow keepers on `ramp`. There the chip's decision and the kernel's execution part ways, by design of the kernel: the reserve holds what was not bought. No clamp fires and the books balance to the base unit.
3. **The headline numbers of the revision-1 notes, one by one:**

| Headline | Was | Is |
|---|---|---|
| Standing reserve under steady flow | 32.0 epochs of inflow (35.7 at 2 OKB per epoch) | 32.0 epochs of inflow = 32.9 to 33.0 epochs of outside tax; at 2 OKB per epoch the cap decides, not the leak |
| `surge`: BANK epochs, reserve share | 8 epochs, 192 falling to 128 | 7 epochs from the second surge epoch, 192, 168, 148, 136, 132, 128, 128. (Idealised, a 16x surge sits exactly on the 32-code threshold and banks at once; with the echo in the peak it is one code under and takes the two-epoch route) |
| `surge`: left after 80 epochs | 3.1% | 3.2% |
| `drought`: left of the peak reserve after 160 quiet epochs | 0.3% | 0.2% |
| `drought`: first DEFEND, first IDLE | epoch 66, epoch 114 | epoch 66, epoch 115 |
| `dust`: BANK epochs, bought, allowance, left | 2, 85%, 13%, 2% | 2, 85%, 13%, 2% |
| `noisy-dollars`: DEFEND + REST of 800 epochs | 203 + 366 | 176 + 360 |
| `noisy-dollars`: bought, left, allowance | 93%, 1.0%, 6.0% | 92%, 1.7%, 6.7% |
| `whale`: allowance of the big epoch, window release | 0.0042 OKB, 41% | 0.0042 OKB, 41%; the buy of that epoch is cut from 0.70 to 0.489 OKB |
| `whale`: drawdown depth peak (per-epoch keeper) | 15, one short of the trigger | 15 |
| `ramp`, `milestones`: left in the reserve at the end | 28%, 29% | 28%, 37% (24 shrunk buys) |
| `failed-buys`: conservation | to the wei | to the base unit, in both regimes, with the vault and the native pot in the books |
| Cadence: worst allowance difference, fast and slow | 1.51, 3.36 points | 1.70, 3.41 |
| Cadence: worst bought difference, fast and slow | 5.51, 9.39 points | 5.65, 9.42 (pairs of runs without a shrunk buy) |
| Cadence: worst mode agreement on deterministic flows | 89.9% | 90.0% (`graduation` aside: 83.2%, see below) |
| Cadence: allowance raised at most, lowered at most by a slower keeper | 0.6, 3.4 points | 0.59, 3.41 |
| Cadence: tier at common settle points | identical | identical except 2 settle points in 144 pairs of runs |
| Cadence, `whale`: bought difference after 60 epochs | up to 27 points | up to 29 points |

### Worth a second look

1. **Sparse flows keep the chip in DEFEND and REST most of the time.** In `noisy-dollars` (60% empty epochs, median $1.60 buys) it spends 176 of 800 epochs in DEFEND and 360 in REST. Each burst seeds or lifts the average, the following empty epochs are a drawdown, and a window opens if the reserve is above `RESMIN`. The money outcome is fine (92% bought, 1.7% left) and this is what the rule says, but the vault page will show DEFEND often on a token with dollar flows. The allowance over the run was 6.7%, below the tier schedule, because DEFEND epochs pay none. If that is not wanted, raise `RESMIN_Q` before tape-out. Sensitivity (same flows, only `RESMIN_Q` changed; DEFEND + REST epochs, and what is left at the end):

   | `RESMIN_Q` | `dust` (600 epochs) | `noisy-dollars` (800 epochs) | `witness` (31 epochs) |
   |---|---|---|---|
   | 389 (4.2e14 wei), chosen | 61 + 174, 2.0% left | 176 + 360, 1.7% left | 8 + 12, 3.4% left |
   | 399 (9.9e14 wei) | 21 + 108, 3.4% left | 167 + 360, 1.5% left | 5 + 12, 7.8% left |
   | 409 (2.3e15 wei) | 2 + 6, 5.4% left | 143 + 342, 1.5% left | 1 + 6, 17.7% left |
   | 425 (9.0e15 wei) | 0 + 0, 6.1% left | 67 + 174, 2.9% left | 0 + 0, 20.2% left |

   A higher minimum means fewer windows on small reserves and more left to the slow leak. On `dust` and `noisy-dollars` the allowance and the amount bought barely move (within 1.1 and 5.2 points). 389 was kept because it leaves the least behind on the smallest flows.
2. **The whale case sits one code under a trigger.** After a single 600x epoch the per-epoch keeper's drawdown depth peaks at 15, one short of `DD_TH`. A keeper that settles every 2 or more epochs sees a broader spike, passes 16 and opens further windows. Same allowance, same tier, but after 60 epochs the amounts bought differ by up to 29 points of the tax paid. Any threshold has an edge somewhere; this one is documented as a known limit of the cadence claim.
3. **A reserve under `RESMIN` leaves only by the leak**: 0.78% per epoch, half in 22 hours. For the reference token that is about $0.05 at most.
4. **The launch epoch is not banked.** A cold start classes nothing as a surge, so the first epoch's tax is routed at CRUISE shares (56 to 72% to the immediate buy). If a token is launched with IGNIX's anti-snipe window the kernel skips buys while it is open, and that part waits in the reserve.
5. **After a launch spike the chip defends for longer than without the echo.** In `launch` the peak seeded by the launch epoch is far above ordinary flow, so DEFEND windows repeat while it decays. Idealised, quiet stretches declare a drought and the next burst re-seeds the peak at the ordinary level (53 DEFEND epochs, 16 BANK). With the echo, the tax of the chip's own tranche buys counts as live flow, droughts are declared less often, the old peak lives longer: 81 DEFEND epochs, 6 BANK. Bought, allowance and what is left are within 0.2 points of each other. The page will show DEFEND for about two days after a hot launch.
6. **A flow that keeps growing leaves a growing reserve.** `ramp` and `milestones` end with 28% and 37% in the reserve because they end in BANK and, for `milestones`, under the cap; the release comes when the growth stops.
7. **Skipping settles lowers the allowance a little** (by up to 3.4 points at every 12 epochs, 1.7 at every 2 to 4), because a slower keeper routes more inflow under DEFEND shares and the ceiling binds more often. It raised it by at most 0.6 points.
8. **The first graduated settles carry the tax of the kernel's own router buys.** In `graduation` the pot buys (1.089, 1.103 and 0.083 OKB) put 75,000 tokens of tax into the second and third graduated settle, 7.5 times the outside flow of that scenario. The chip is in warm-up, so its average jumps to the pulse; when the pulse is over the chip reads a drawdown and opens four DEFEND windows in 40 epochs (32 DEFEND epochs against 16 idealised). After graduation a window only decides when reserve tokens are sent to `0xdEaD`, and 93.6% is burned against 92.4%, so nothing is lost; but the mode shown right after graduation is the echo of the kernel's own buys, not of trading. On a token with a busy pair the pulse is negligible (`graduation-busy`: 0.15% of token inflow).
9. **After a buy pause the backlog drains at the chip's usual pace.** In `failed-buys` the reserve peaks at 147 epochs of flow. The chip does not speed up to clear it: it leaks 0.78% per epoch and releases tranches when a trigger fires. That is the rule; a long IGNIX buy pause therefore leaves a large reserve for a day or more.
10. **After an evaluator outage the rate is under-read once** (`outage`): one DEFEND window on a nearly empty reserve, four epochs without allowance, no clamp.

### Checks that were restated for revision 2, and why

No chip constant was changed to make a check pass. Six statements changed because the kernel around the chip changed:

| Check | Was | Is | Why |
|---|---|---|---|
| `steady-large`: reserve bounded | under the kernel | with execution limits off; plus a new check of what the full kernel does (every buy shrunk, curve end at epoch 86, books exact) | The kernel cannot buy 1.75 OKB per epoch on an 85 OKB curve. The bound is a property of the rule, the cap a property of the kernel |
| `silence-return`: the seeded average equals the settled one | equal | seeded exactly at the reading, within one code of where it settles | The settled level includes the echo, which is not there in the first epoch after a silence |
| scale: x1, x16, x1,024 give the same modes | under the kernel | x1/4, x1, x4 under the full kernel; x16 and x1,024 with execution limits off | Above x4 the surge's tranches reach the cap |
| Cadence E1: tier identical at every common settle point | exact | at most one settle point per milestone may differ, by one tier | `TAXCUM` includes the echo, which depends on how much each keeper has bought so far. Measured: 2 settle points in 144 pairs |
| Cadence E3: bought within 6 (10) points | every pair | pairs in which no buy was shrunk or skipped | The cap is per settle: a keeper who settles every k epochs executes up to k times less when the cap binds |
| Cadence E4: mode agreement of 85% | every deterministic flow | every deterministic flow except `graduation` | The pot pulse lasts a number of settles, not of epochs (83.2% to 100% there) |

Ten checks are new: the market model against the fork measurements, the echo being exactly 3% of the previous buy, the cap on `steady-large` and on `whale`, the regime restart, the native pot, scale under the full kernel, and three on the outage.

**Cadence test.** Definition and results are in `FLOW_GOVERNOR.md` section 8. Tolerances: allowance 2 points and bought 6 points for schedules that skip at most 3 epochs, 4 and 10 for slower ones, mode agreement 85% within k + 2 epochs on piecewise-constant flows. Measured worst cases: 1.70 and 5.65; 3.41 and 9.42; 90.0%. No clamp in any run. The margins on the bought tolerance are thin (5.65 against 6, 9.42 against 10): they are measured numbers, not design targets.

### The token-regime thresholds: what changed in the graduation flows

`FLOOR_T` 530 to 515 and `RESMIN_T` 573 to 558, same kernel, same flows:

| Flow | Kernel | Token-regime settles in CRUISE / DEFEND / REST / IDLE, burned | Settles whose output word differs |
|---|---|---|---|
| `graduation` | idealised | 92 / 14 / 24 / 0, 92.31% to 90 / 16 / 24 / 0, 92.41% | 26, all from epoch 137 on |
| `graduation` | revision 2 | 51 / 28 / 42 / 9, 93.47% to 50 / 32 / 48 / 0, 93.59% | 25, all from epoch 137 on |
| `graduation-busy` | both | no change | 0 |

The difference is the tail of the 40 empty epochs near the end of `graduation`: with the minimum at 959 tokens instead of 3,542 the reserve stays worth a window for longer. Under the idealised kernel the last window runs its full four epochs; under the revision-2 kernel one more window opens where the chip used to sit in IDLE with a reserve it would only leak. Flows of 10,000 tokens per epoch and more are far above either floor, so nothing else moves. The old thresholds were 3.6 times too high in OKB terms: a graduated token needed 3.5e13 wei worth of tax per epoch to count as live, against 9.9e12 before graduation.

## 9. Found wrong, ambiguous or awkward in `chips/INTERFACE.md` revision 2 and `chips/golden/kernel_model.py`

The six points raised against revision 1 are settled in revision 2 (no allowance after graduation; both totals restart; `floorMin >= 1`; `DT` against `TAX` after an outage is stated; the first settle is stated; only a zero-token buy is skipped). New:

1. **`clampBits` is not always 0 on a fallback record** (section 8.2 says it is). The fallback word goes through the same clamps. With the reference envelope a fallback settle with more than 1.0809 OKB of inflow sets `K2C` (8): `floor(inflow x 8 / 256)` exceeds `exp8(440)`. With an envelope the factory accepts but with `allowCumBps x 256 < fbAllow x 10000` (for example `capT 128`, `fbAllow 128`, `allowCumBps 1000`) it sets `K2L` (16). Either the sentence should say "0 unless the envelope clipped the fallback allowance", or the kernel should mask the bits on a fallback record. `kernel_model.route_tax` and the kernel agree with each other; only the sentence is off.
2. **The allowance promise is against inflow, and inflow includes the kernel's own buy tax.** Section 7, guarantee 1: "at most `allowCumBps / 10000`, and never more than half, of the OKB that ever arrives". Every OKB the kernel spends on the curve sends `taxBuyBps` of itself round again as inflow, and the allowance is taken from that too. Against the tax that traders paid the bound is `a / (1 - t x (1 - a))` with `a = allowCumBps / 10000` and `t` the buy tax: 19.2% for the reference envelope, and 52.6% at the factory's extremes (`allowCumBps` 5000, 10% buy tax), which is more than half. A holder reads the number as a share of the tax. Suggest stating the bound both ways.
3. **`DT = 15` "should be read as rate unknown"** (section 5). The Flow Governor reads it as 15 epochs. After a gap of more than 15 epochs the rate is overstated (the backlog is routed with BANK shares), after an evaluator outage it is understated once (one DEFEND window, measured in `outage`). Following the advice would be a change of the control law; it was not made. The sentence is advice, not a requirement, and the chip's behaviour is documented in `FLOW_GOVERNOR.md` sections 8 and 11.
4. **The tax of the native-pot router buys is chip-visible inflow.** It follows from section 8.1 (the tax of the kernel's own buys is inflow like any other), but section 9.3 does not spell it out and a chip author needs the size: right after graduation the token regime starts with a pulse of 3% of what the pot buys, one capped buy per settle, and the pot holds the tax of the graduating buy, which can be 2 OKB and more. For this chip see section 8, item 8.
5. **`maxNonGraduatingBuy` leaves at least one base unit, not one** (section 9.1). In `steady-large` the kernel's last buy leaves 21, and the function then returns 0. Wording only.
6. **`kernel_model.py` has no model of one settle.** It has the arithmetic of each step, not their order (latch, claims, books, legs) nor the fallback rule, and `Envelope` has no `fallbackEpochs`, `fbAllow` or `epochLen`. The scenario runner takes the order from the interface text and the three values from `fg_params.json`. It also carries its own mirror of `CurveTrading.buy` for a buy that reaches the end of the curve and of the gross output and tax of a V2 buy, because the model only exposes the kernel's own sizing; where they overlap they are asserted equal to `curve_out` and `v2_net_out` on every call.
7. **`TAXCUM` is not a measure of trading** is said in section 5 for donations. It holds for the echo too: two keepers with different schedules do not have the same `TAXCUM` at the same epoch (cadence E1).

Nothing in revision 2 was impossible to satisfy. The chip diverges from it in one place, item 3, which is advice.

Stale references to the revision-1 netlist in files outside this work stream (not edited): `chips/tools/NOTES.md` sections 2 and 3 (1,889 NAND, 13,479 bytes), `contracts/evaluator/README.md` (the same), and the two kernel test fixtures that pin a copy of the old bytes by keccak `0x2fd0e007...` (`contracts/core/test/fork/ForkBase.sol`, `contracts/core/test/integration/RealEvaluators.t.sol`).

## 10. Open questions

- Sign-off of every constant in section 4, in particular: `AL3 = 8` instead of 0; the milestone decades; `RESMIN_Q` (section 8, item 1); `fallbackEpochs = 16` and `fbAllow = 8`.
- Whether the vault page should show IDLE and CRUISE as one mode. They route identically; IDLE only says a drought is declared.
- Whether the mode shown in the first hours after graduation should be explained on the page (section 8, item 8).
- The token-regime thresholds are right for a token that graduates at 85 OKB with 200,000,000 tokens in the pair, which is what every IGNIX launch read so far does (`contracts/probes/FINDINGS.md`). The graduation amount is a signed launch parameter that the chain does not range-check: a token launched with another amount would have thresholds off by that factor. They only decide what counts as quiet and what reserve is worth a window.
- The pin manifest's SHA-256 is fixed by its bytes. Any edit of a description in `gen_pins.py` or of a latch meaning in `flow_governor.py` changes it. `make check` fails when the committed file is stale; after tape-out nothing may change.
- Not done: a mainnet difftest. `step` is a pure function of the bytes, so the fork result carries over, but `tapc difftest` should be re-run against the mainnet circuit after tape-out and its evidence committed.
- Not done: the sealed evaluator's gas for this chip.

## 11. How to run everything

```
make -C chips/rtl venv        # chips/.venv-fg: Python 3.12, yowasp-yosys 0.69.0.0.post1233, z3-solver 5.1.0.0
make -C chips/rtl all         # params, model, scenarios, synth, pins, test, prove, modelproof, export, glutton   (about 5 minutes)
make -C chips/rtl mutants     # ten broken chips, each must be rejected                                           (about 35 seconds)
make -C chips/rtl fork        # local anvil fork at block 72373000: tape out, difftest, gas, pin manifest         (about 1 minute)
make -C chips/rtl check       # verify the committed bytes without rebuilding them
make -C chips/rtl compare     # every scenario under the idealised kernel and under revision 2
```

Single steps:

```
chips/.venv-fg/bin/python chips/rtl/gen_params.py [--check | --show]   # fg_params.json -> fg_params.vh, with every check
chips/.venv-fg/bin/python chips/model/flow_governor.py             # model self-check
chips/.venv-fg/bin/python chips/model/scenarios.py                 # all scenarios, behaviour checks, cadence test
chips/.venv-fg/bin/python chips/model/scenarios.py drought -v      # one per-epoch table
chips/.venv-fg/bin/python chips/model/scenarios.py --cadence       # cadence test only
chips/.venv-fg/bin/python chips/model/scenarios.py --ideal         # the kernel without echo and execution limits
PYTHONPATH=chips/tools chips/.venv-fg/bin/python -m tapc synth chips/rtl/fg_params.vh chips/rtl/fg_core.v \
    --name fg --top fg_core --nin 96 --nout 112 --pins chips/synth/fg.pins.json --out chips/out \
    --build chips/synth/build/fg --max-bytes 24000 --shape covenant-v1
chips/.venv-fg/bin/python chips/synth/gen_pins.py [--check]        # the pin manifest and its SHA-256
chips/.venv-fg/bin/python docs/taps/assets/pins_reference.py chips/out/fg.pins.json docs/taps/assets/covenant-v1.pins.json
chips/.venv-fg/bin/python chips/rtl/test_fg.py --n 200000          # RTL == model on the bytes, sampled
chips/.venv-fg/bin/python chips/props/prove.py                     # every proof, with times
chips/.venv-fg/bin/python chips/props/model_equiv.py               # model == bytes, every (s, x)
chips/.venv-fg/bin/python chips/props/witness.py                   # the witness, from the model
chips/.venv-fg/bin/python chips/model/export.py                    # fields, vectors, scenario tables
chips/.venv-fg/bin/python chips/cells/glutton/demo.py [-v]         # Glutton under the envelope
chips/.venv-fg/bin/python chips/synth/fork_test.py --block 72373000 --n 10000
```

`fg_params.vh` is passed to Yosys as a source file in front of `fg_core.v`; there is no `` `include ``. The Makefile uses its own environment `chips/.venv-fg` and never touches `chips/.venv`; both pin the same package versions.

To tape out for real, through the Fab: `tapeoutChip(netlist, manifestHash)` with the contents of `chips/out/fg.hex` and the SHA-256 of `chips/out/fg.pins.json` from section 2, and `msg.value` equal to `quote(netlist).cost`. Directly on a processor: mint 1,888 NAND (id 0) and 64 LATCH (id 1) on its transistors, then `tapeout(bytes, 96, 112)` with exactly 0.0013 OKB. Either way, check `keccak256(netlist(id))` against section 2 and replay the witness of `chips/out/fg.witness.json` before the kernel takes the chip.
