# Flow Governor and Glutton: notes

Decisions, measured numbers, open questions and how to run everything. Written for whoever signs off the constants and for whoever tapes the chip out. The rule itself is described in plain language in `chips/model/FLOW_GOVERNOR.md`.

Nothing here was sent to mainnet. Chain work was read-only or on a local anvil fork.

## 1. What exists

| Path | What |
|---|---|
| `chips/rtl/fg_params.json` | Every chip constant and the reference envelope. The single source of truth |
| `chips/rtl/fg_params.vh` | Generated from the JSON by `gen_params.py` (which also checks the relations the RTL relies on) |
| `chips/rtl/fg_core.v` | The chip: `fg_core(s[63:0], x[95:0]) -> (ns[63:0], y[111:0])`, pure combinational |
| `chips/rtl/test_fg.py` | RTL == model on the netlist bytes: 600,000 vectors and every scenario trace |
| `chips/rtl/Makefile` | Entry point for everything below |
| `chips/model/flow_governor.py` | Bit-exact behavioural model, built on `chips/golden/kernel_model.py` |
| `chips/model/scenarios.py` | Scenario runner (model + kernel routing), behaviour checks, cadence test |
| `chips/model/export.py` | Writes `fg.fields.json`, `fg.vectors.json` and the per-epoch scenario tables |
| `chips/model/FLOW_GOVERNOR.md` | The control law for the judge guide, the 64 latch bits, the witness |
| `chips/props/fg_props.v`, `fg_props.py` | The properties, as Verilog wrappers and again as z3 predicates on the bytes |
| `chips/props/witness.py`, `prove.py`, `mutants.py` | Witness generator; the script that runs every proof and records times; ten broken chips that the proofs must reject |
| `chips/synth/fg.pins.json`, `fork_test.py` | Field names for the manifest; local-fork tape-out and difftest |
| `chips/cells/glutton/` | The hostile demo chips, their proofs, the clamp demo, a README |
| `chips/out/` | `fg.tap`, `fg.hex`, `fg.manifest.json`, `fg.map.json`, `fg.fields.json`, `fg.proofs.json`, `fg.witness.json`, `fg.vectors.json`, `fg.fork.json`, `fg.difftest.jsonl`, `scenarios/` |

## 2. Final numbers

| | Flow Governor | Limit |
|---|---|---|
| NAND | 1,889 | |
| LATCH | 64 | 256 (target 64) |
| Gates | 1,953 | 3,400 (target about 2,200) |
| Netlist bytes | 13,479 | 24,000 |
| NAND depth | 154 | none |
| keccak256 of the bytes | `0x2fd0e007398296a5845c8a7e3b99d5149d6c02ae670afe373abd191fb2591a89` | |
| `step` gas (fork, `eth_estimateGas`, 18 samples) | 4,604,301 to 4,633,104, mean 4,616,824 | |
| Gas per gate | 2,364 | |
| Tape-out gas (fork) | 5,747,410 | |
| Transistor cost at 0.00002 OKB | 0.03906 OKB, plus 2 x 0.00066 mint fee and 0.0013 tape-out fee | |

Built by `tapc synth --recipe auto` (Yosys 0.69, recipe `rich-dc2-compress` won among twelve; the ABC script is recorded in `fg.manifest.json`). Rebuilding from clean gives the same keccak. The keccak depends on the tapc recipes: if they change before tape-out, rebuild, re-prove and re-run the fork test. Every proof takes the bytes as input, so any final netlist is checkable.

Where the gates go, from the cones in `fg.map.json`: 136 NAND and 21 latches serve only the telemetry latches (`NBANK`, `NDEF`, `CLOCK`); 45 NAND are constant output bits (`T_HOLD` and the revenue group), which the format forces; 21 NAND serve only `FLAGS` and `AUX`. Nothing had to be shed. If gas ever mattered, dropping the telemetry latches would save 157 gates (about 0.37M gas per step).

Glutton and Glutton-512: 113 NAND + 1 LATCH = 114 gates, 795 bytes each; `step` 379,203 gas; tape-out 530,264 gas.

For the kernel work stream: `KernelFactory` gives the evaluator `STEP_BASE + STEP_PER_GATE * gateCount` = 60,000 + 2,600 x 1,953 = 5,137,800 gas for this chip. The measured need through `Circuits.step` is at most about 4.61M (the 4,633,104 estimate less the 21,000 base and calldata), so the guard has about 11% of margin on the TapeOut evaluator. The sealed evaluator was not measured here.

## 3. Decisions, and where they depart from the earlier design

1. **No holder share.** `T_HOLD` is 0 in every mode (proven). Kernel v1 folds a holder share into the reserve, so naming a share "holder" would only mislabel reserve. Of the 64/256 the earlier design gave holders in ordinary flow, 48 now go to the immediate buy and 16 to the reserve: CRUISE was (144 - AL, 64, AL, 48) and is (192 - AL, 0, AL, 64).
2. **No BOOT mode that buys nothing.** The first live reading seeds the average and routes like CRUISE. The earlier design's first four settles bought nothing.
3. **The reserve always leaks.** `REL` is at least 2 per elapsed epoch in every mode and for every reserve. This is what bounds the reserve under steady inflow (32 epochs of inflow) and it satisfies the kernel floor everywhere, so `K5` can never fire. The earlier design had `REL = 0` outside DEFEND.
4. **The average has a floor, a fall limit, and is re-seeded after a drought.** This is the fix for the collapse after long silence. The floor alone was not enough: with a log-domain average one empty epoch moves it a quarter of the way to the floor, a factor of 17 at 1 OKB per epoch (and of thousands without a floor, which is what the earlier design did). Three changes together fix it: the average falls at most 3 codes per epoch; after 8 quiet epochs it is declared stale and the next live reading replaces it; and for 3 epochs after that it jumps up to any higher reading.
5. **A surge is measured against the decaying peak of the average, not the average.** A pause lowers the average but barely lowers the peak, so volume returning at its old level is never a surge. Checked by a sweep (26,979 level and pause combinations, both regimes: zero BANK entries).
6. **The raw two-epoch "dip" trigger was removed.** With realistic noise it fired constantly and kept the chip in DEFEND. DEFEND now opens on three conditions: drawdown (the average is 16 codes below its peak), drought (8 quiet epochs), or fade (a BANK ends on a reading at most half the average). The plan's wording is "on drawdown or drought"; fade is the release of what a surge banked.
7. **A 16x reading is banked at once.** Otherwise a single very large epoch would be bought into at the CRUISE share before the two-epoch confirmation.
8. **Everything counts epochs.** All timers advance by `DT`. A DEFEND window is 4 tranche epochs, not 4 settles; a settle that covers two or more of them releases a double tranche; when a window or a cooldown ends inside a settle, the leftover epochs are credited to the next phase.
9. **No allowance after graduation.** See section 9, item 1: the envelope has one `ceilMax` for two different units.
10. **`PROG` and `LOCK` are not used.** The chip reads tax flow and the reserve only.
11. **Telemetry latches.** `NBANK` and `NDEF` count episodes; `CLOCK` counts elapsed epochs modulo 1024 so that the stored state moves on every settle, including settles with no inflow.

## 4. Constants for sign-off

All in `fg_params.json`. Codes are `lg8` codes; amounts are `exp8(code)`.

### Chip

| Constant | Value | Meaning | Why this value | Evidence |
|---|---|---|---|---|
| `FLOOR_Q` | 346 (9.9e12 wei per epoch) | Readings at or below it are quiet; the average cannot go lower | A $1 buy at 3% tax is code 383. It must count as live even when one settle covers 15 epochs (383 - 31 = 352 > 346) | `subdust`: 1e11 to 8e12 wei never leaves IDLE. `steady-small`: $1 per epoch is CRUISE throughout |
| `FLOOR_T` | 530 (83 tokens per epoch) | The same after graduation | `FLOOR_Q` + 184 codes = 2^23 token units per wei, about 8.4M tokens per OKB, the scale of the curve's graduation price | `graduation`, `graduation-busy` |
| `RESMIN_Q` | 389 (4.2e14 wei) | Smallest reserve for which a DEFEND window opens | The smallest tranche (1/8) is then about ten times the gas of one buy leg (about 4e12 wei at 0.02 gwei) | `dust`: windows open with reserves around 4e14 to 1e15 wei and stop below it |
| `RESMIN_T` | 573 (3,542 tokens) | The same after graduation | `RESMIN_Q` + 184 | `graduation` |
| `M1`, `M2`, `M3` | 425, 452, 479 (0.0090, 0.0991, 1.0088 OKB cumulative) | Allowance milestones | Decades. The first is reachable with about $40 of volume, so the ratchet can be seen live on a dollar-sized token | `milestones`: tier 0, 1, 2, 3 in order; `witness`: tier 1 after one 0.01 OKB epoch |
| `AL0..AL3` | 48, 32, 16, 8 | Allowance share per tier (18.75%, 12.5%, 6.25%, 3.125%) | From the earlier design, with a floor of 8 instead of 0 so that a keeper-tank payee is never cut off entirely | `milestones` |
| `CEIL0`, `CEIL_STEP` | 440, 8 | Allowance ceiling per settle: 0.0338 OKB, halving per tier | A single huge epoch must not pay a huge allowance. It binds only above about 0.18 OKB of tax per settle | `whale`: 3 OKB of tax, allowance cut to 0.0042 OKB by the chip's own ceiling, no clamp |
| `RC` | 64 | Reserve share in ordinary flow | Replaces the old 48 reserve + 64 holder. With the leak it gives a standing reserve of 32 epochs of inflow (8 hours) | `steady*`: settles at 32.0 epochs of inflow |
| `RB_MIN`, `RB_GAIN`, `RB_SPAN` | 128, 4, 16 | Reserve share in BANK: 50% at 2x, 75% from 8x | From the earlier design | `surge`: 192, 168, 152, 140, 128 as the average catches up |
| `SURGE_TH` | 8 codes (2x) | Surge threshold against the peak | From the earlier design, now against the peak | `silence-return`, `pause-return`, pause sweep |
| `XSURGE_TH` | 32 codes (16x) | Counts double: BANK at once | High enough to be rare under ordinary noise, low enough to catch a single very large epoch | `whale`, the mode tour in `fg.witness.json` |
| `DD_TH` | 16 codes (a quarter) | Drawdown trigger | From the earlier design. With the fall limit it needs six epochs of decline | `witness`, `crash`, `drawdown`, `launch` |
| `DIP_TH` | 8 codes (half) | Fade trigger and the dip flag | | `whale`, `surge` |
| `SLEW_Q` | 12 (3 codes per epoch) | Fall limit of the average | An arithmetic average with gain 1/4 loses 3.3 codes on an empty epoch | `drought` |
| `PK_DIV` | 4 | The peak loses a code every 4 epochs (halves in 8 hours) | How long "recent peak" lasts. Sets how long DEFEND windows repeat after a crash: 64x down gives about 32 hours | `crash`: 12 windows in 120 epochs |
| `DRYN` | 8 | Quiet epochs to a drought (2 hours) | From the earlier design | `drought` |
| `WARMN` | 3 | Warm-up epochs after a cold start | Long enough to see a second and third reading before classing anything | `silence-return` |
| `TRN`, `CDN` | 4, 6 | Tranche epochs per window, cooldown epochs | From the earlier design | `drought`: DEFEND 4, REST 6, repeating |
| `TR_MIN`, `TR_MAX` | 32, 64 | Tranche per epoch: 12.5% at 16 codes of drawdown, 25% from 32 | A full window releases 41% to 68%. The earlier design went to 50% per tranche, which emptied the reserve in one hour | `drought`, `drawdown` |
| `LEAK` | 2 | 0.78% of the reserve per epoch, always | Equals the envelope floor. Half-life 22 hours | `steady*`, `drought` tail |
| `LOG8DT` | round(8 log2 dt) | Turns a settle covering `dt` epochs into a per-epoch rate | | cadence test |

### Reference envelope (immutable per kernel)

| Field | Value | Why |
|---|---|---|
| `epochLen` | 900 | Given |
| `capT` | 48 | Equal to `AL0`: the envelope is exactly the chip's worst case. Glutton gets 18.75% and no more |
| `capV` | 0 | Kernel v1 has no revenue; the chip's `V_ALLOW` is 0 |
| `allowCumBps` | 1875 | Exactly 48/256. See "lifetime cap" below |
| `ceilMax` | 440 | Equal to `CEIL0` |
| `relMax` | 128 | Equal to the largest release the chip can ask for (a double tranche of 64) |
| `floorRel` | 2 | Equal to `LEAK` |
| `floorMin` | 1 | The floor applies to every non-empty reserve. The chip meets it for every reserve, so any value works; 1 gives the strongest disclosure. (0 would also flag an empty reserve.) |
| `fallbackEpochs` | 16 | One more than the `DT` saturation. Only matters if `step` itself fails |
| `fbAllow` | 8 | Equal to `AL3`. A larger value would let a dead chip pay more than the ratchet's last tier, which would loosen it |

**The lifetime cap never binds.** After `K2` the kernel has `T_ALLOW <= capT`, so each settle credits at most `floor(inflow_i * 48 / 256)`. A sum of floors is at most the floor of the sum, so the allowance paid through settle n is at most `floor(cum_n * 48 / 256) = floor(cum_n * 1875 / 10000)`, which is the cap. Hence `allow_n <= room_n` for every chip, not only this one. `gen_params.py` asserts `allowCumBps * 256 >= capT * 10000`; `prove.py` drives 200,000 random settles through `route_tax` with the share at the cap (0 hits); every scenario row has `clamp == 0`.

## 5. Latch budget

64 of 64 used. `A` 12, `PK` 10, `PKDIV` 2, `MODE` 3, `TIER` 2, `GSEEN` 1, `WARM` 2, `LIVE` 4, `SUR` 2, `TR` 2, `CD` 3, `NBANK` 5, `NDEF` 6, `CLOCK` 10. Bit positions and the die rows are in `FLOW_GOVERNOR.md` section 6 and `chips/out/fg.fields.json`.

Against the earlier budget: `DIP`, `DW`, `NSUR` and `NREL` are gone; `WARM` is 2 bits instead of 3 and `TR` 2 instead of 3; `LIVE` replaces `DRY` (it counts down, so that the reset state is cold); `NBANK`, `NDEF` and `CLOCK` are the telemetry.

## 6. Proofs

`make -C chips/rtl prove` runs everything and writes `chips/out/fg.proofs.json` with per-proof times. All statements are about the netlist bytes, for every 64-bit state and every 96-bit input.

| Group | What | Yosys SAT | z3 on the Yosys wrapper | z3 on terms built from the bytes |
|---|---|---|---|---|
| EQ | bytes == `fg_core.v` | 58 to 94 s | 75 to 118 s (word-level SMT-LIB of the RTL against the bytes) | |
| P1 | share groups sum to 256, each <= 256, holder share 0 | 5 checks, <= 2.5 s each | 5, <= 1.8 s | 3, <= 0.8 s |
| P2 | `K2`, `K2V`, `K3`, `K5` (also for every reserve), `K2C` | 7, <= 4.3 s | 7, <= 7.6 s | 6, <= 1.0 s |
| P3 | tier never decreases; allowance and ceiling bounded by the tier; a higher tier never loosens (two copies); tier frozen and allowance 0 after graduation | 8, <= 13.2 s | 8, <= 3.1 s | 4, <= 0.9 s |
| P4 | invariant true at reset and inductive; MODE output equals the MODE latch | 3, <= 4.0 s | 3, <= 2.9 s | 3, <= 1.1 s |
| P5 | `REV`, `REVCUM`, `ESC`, `PROG`, `LOCK`, bits 81..95 ignored (two copies) | 11.4 s | 1.5 s | 0.0 s (the bytes do not reference those inputs) |
| P6 | cooldown: only the leak, counter strictly decreasing, stays in REST; a release above the leak is a flagged tranche; DEFEND routes everything to buy | 5, <= 2.9 s | 5, <= 35 s | 2, <= 0.9 s |
| P7 | witness and mode tour (26 concrete steps) | 7 checks, 3.6 s | not available: see below | 0.03 s, plus a replay with `tapc.sim` |
| extras | `DT = 0` reads as 1; graduation seen once; the graduation step only re-seeds | 3, <= 6.3 s | 3, <= 2.9 s | 3, <= 1.4 s |
| K2L | lifetime cap | arithmetic argument and 200,000 random settles | | |

98 of 98 proved. Wall time 75 to 120 s with 8 processes (the range is machine load). Times are per check, including Yosys start-up for the wrapper rows.

**The proofs can fail.** `make -C chips/rtl mutants` builds ten deliberately broken chips (allowance 49 at tier 0, a leak under the floor, a tier that follows `TAXCUM` down, DEFEND on the graduation step, `PROG` leaking into a decision, a share group summing to 255, a tranche during the cooldown, a peak below the average, an allowance after graduation, a ceiling one code above the envelope) and runs the matching properties on their bytes. All ten are caught, each with a counterexample.

Notes on the proof tooling:
- A `case` statement inside a function becomes a ROM cell in Yosys (`proc_rom`). The SAT pass then stops with "No SAT model available for cell $meminit" and the SMT-LIB writer leaves the table unconstrained, which produced a spurious z3 counterexample. `fg_log8dt` is therefore written as a chain of conditionals. The counterexample was replayed on the bytes and on the model before the change: both agreed, the query was wrong.
- The z3 route through Yosys's SMT-LIB writer overflows the wasm stack on the chained witness wrapper (26 copies of the netlist in series). The witness is checked by Yosys SAT on that wrapper and by z3 on the bytes step by step instead.
- z3's Python API is not thread-safe: `prove.py` runs one process per proof.

## 7. RTL == model, netlist == RTL, chain == model

- **Netlist == RTL**: the EQ row above, two engines, every (s, x).
- **RTL == model**: `test_fg.py` evaluates the bytes with a small evaluator written from the vendored `NetlistVM.sol` (independent of tapc) and compares 64 next-state bits and 112 output bits with the model: 200,000 uniform random (s, x), 200,000 boundary-biased (fields drawn around every threshold), 200,000 on random walks from reset with kernel-shaped inputs, and 14,915 scenario settles including the cadence variants. 0 mismatches. A 2,000-vector sample of each set is also run through `tapc.sim`: 0 mismatches. A one-off longer run with another seed (`--n 2000000 --seed 7`, 6,014,915 vectors) also gave 0. The first synthesis matched the model with no fix needed.
- **Model vectors on the bytes**: `tapc sim chips/out/fg.tap --check chips/out/fg.vectors.json`: 8,086 of 8,086.
- **Chain == simulator == model** (`make -C chips/rtl fork`, local anvil fork at block 72,373,000): 16,107 vectors (4,000 uniform, 3,000 walk, 3,000 boundary, 6,086 scenario, 19 tour, 2 witness). All 16,107 on-chain `step` answers equal `tapc.sim` and equal the Python model. `netlist(id)` returned exactly the local bytes. The witness was replayed with two plain `eth_call`s. Implementation `0x977f217887E085D298Cb3819cDAD5A0ee35F29B2`, code hash `0x7a15c353205e5245f40f5f5524542a982a4bb3b9a28476e4f10845163f941b30`.

The free test processor `cpuAt(0)` (`0x839bdD6f...574e`, "OnlyTestXLayer") could not be used: at the pinned block its supply is fully minted (`minted == supplyCap == 100,000`). The fork test creates a throwaway processor through the real factory instead (`createCPU`, 0.0066 OKB), which is the same path the Covenant processor will take, and uses the same beacon implementation. Anvil's first development account also cannot be used: on X Layer it carries code, so the ERC-1155 mint reverts with `ERC1155InvalidReceiver`. The script funds and impersonates a key-less address.

## 8. Scenario findings

`make -C chips/rtl scenarios` prints one line per scenario, the behaviour checks and the cadence test. Per-epoch tables are in `chips/out/scenarios/`. `clampBits` is 0 on every row of every scenario and every cadence.

| Scenario | Outcome |
|---|---|
| `steady`, `steady-small`, `steady-large` | CRUISE throughout. Reserve settles at 32.0 epochs of inflow (35.7 at 2 OKB per epoch, where the ceiling cuts the allowance and the cut stays in the reserve). Worst case for any steady flow: (64 + 48) / 2 = 56 epochs |
| `surge` (16x for 8 epochs) | BANK from the second surge epoch, reserve share 192 falling to 128 as the average catches up; when the surge ends the fade trigger opens DEFEND; three more windows follow while the drawdown lasts. 3.1% left after 80 epochs |
| `drought` | DEFEND after 6 quiet epochs (drawdown), then 4 on, 6 off, until the reserve is under `RESMIN`; then IDLE and the leak. 0.3% of the peak reserve is left after 160 quiet epochs |
| `silence-return` | After 200 quiet epochs the first live settle re-seeds the average; no BANK epoch. The fix asked for in requirement 7 |
| `pause-return` | Pauses of 5, 3 and 7 epochs: no BANK. The 7-epoch pause opens one DEFEND window |
| `dust` ($1 to $4 buys in one epoch of eight) | Mostly IDLE, CRUISE and DEFEND/REST cycles on a reserve of 4e14 to 1e15 wei. 2 BANK epochs in 600. 85% bought, 13% allowance, 2% left |
| `subdust` | Never live. IDLE. Routed at CRUISE shares |
| `noisy`, `noisy-dollars` | See "surprising" below |
| `launch` | The launch epoch seeds the average and is routed at CRUISE shares; the decay that follows opens DEFEND windows |
| `milestones` | Tier 0, 1, 2, 3; allowance 48, 32, 16, 8 |
| `whale` | The 3 OKB epoch is banked at once (reserve share 192), allowance cut to 0.0042 OKB by `CEIL`; fade opens one DEFEND window that releases 41%; the rest leaves by the leak |
| `graduation`, `graduation-busy` | Re-seed on the first token settle, tier kept, allowance 0 afterwards, same behaviour in token units |
| `hostile-timing` | Gaps of 1 to 40 epochs: no clamp, tier never falls |
| `failed-buys` | When 5/6 of every buy fails, the unexecuted part stays in the reserve and is offered again; inflow = allowance + bought + reserve to the wei |
| scale | The `surge` flow multiplied by 16 and by 1,024 gives the identical mode sequence |

**Surprising or worth a second look**

1. **Sparse flows keep the chip in DEFEND and REST most of the time.** In `noisy-dollars` (60% empty epochs, median $1.60 buys) it spends 203 of 800 epochs in DEFEND and 366 in REST. Each burst seeds or lifts the average, the following empty epochs are a drawdown, and a window opens if the reserve is above `RESMIN`. The money outcome is fine (93% bought, 1% left) and this is what the rule says, but the vault page will show DEFEND often on a token with dollar flows. The allowance over the run was 6.0%, below the tier schedule, because DEFEND epochs pay none. If that is not wanted, raise `RESMIN_Q` before tape-out. Sensitivity (same flows, only `RESMIN_Q` changed; DEFEND + REST epochs, and what is left in the reserve at the end):

   | `RESMIN_Q` | `dust` (600 epochs) | `noisy-dollars` (800 epochs) | `witness` (31 epochs) |
   |---|---|---|---|
   | 389 (4.2e14 wei), chosen | 61 + 174, 2.0% left | 203 + 366, 1.0% left | 8 + 12, 3.3% left |
   | 399 (9.9e14 wei) | 20 + 102, 3.3% left | 180 + 354, 1.0% left | 5 + 12, 7.6% left |
   | 409 (2.3e15 wei) | 1 + 6, 5.6% left | 138 + 324, 1.6% left | 1 + 6, 17.3% left |
   | 425 (9.0e15 wei) | 0 + 0, 5.9% left | 64 + 150, 2.8% left | 0 + 0, 19.8% left |

   A higher minimum means fewer windows on small reserves and more left to the slow leak. The allowance and the amount bought barely move (within 1 and 5 points). 389 was kept because it leaves the least behind.
2. **The whale case sits one code under a trigger.** After a single 600x epoch the per-epoch keeper's drawdown depth peaks at 15, one short of `DD_TH`. A keeper that settles every 2 or more epochs sees a broader spike, passes 16 and opens further windows. Same allowance, same tier, but after 60 epochs the amounts bought differ by up to 27 points of inflow. Any threshold has an edge somewhere; this one is documented as the known limit of the cadence claim.
3. **A reserve under `RESMIN` leaves only by the leak**: 0.78% per epoch, half in 22 hours. For the reference token that is about $0.05 at most.
4. **The launch epoch is not banked.** A cold start classes nothing as a surge, so the first epoch's tax is routed at CRUISE shares (56 to 72% to the immediate buy). The kernel skips buys while the anti-snipe tax is on, so that part waits in the reserve anyway.
5. **A flow that keeps growing leaves a growing reserve.** `ramp` and `milestones` end with 28 to 29% in the reserve because they end in BANK; nothing is wrong, the release comes when the growth stops.
6. **Skipping settles lowers the allowance a little** (by up to 3.4 points at every 12 epochs, 1.5 at every 2 to 4), because a slower keeper routes more inflow under DEFEND shares and the ceiling binds more often. It raised it by at most 0.6 points.

**Cadence test.** Definition and results are in `FLOW_GOVERNOR.md` section 8. Tolerances: allowance 2 points and bought 6 points for schedules that skip at most 3 epochs, 4 and 10 for slower ones, mode agreement 85% within k + 2 epochs on piecewise-constant flows. Measured worst cases: 1.51 and 5.51; 3.36 and 9.39; 89.9%. Tier identical and no clamp in every run. The margins on the bought tolerance are thin (5.51 against 6, 9.39 against 10): they are measured numbers, not design targets.

## 9. Found wrong, ambiguous or awkward in `chips/INTERFACE.md`

1. **`ceilMax` is one `lg8` code, but the regime asset changes unit at graduation** (wei of OKB, then token base units). A ceiling of code 440 is 0.034 OKB before graduation and 0.034 of one token after. So a clamp-free chip under a meaningful OKB ceiling can pay no real allowance after graduation. The Flow Governor therefore pays none after graduation (proven), which also suits the reference token, whose payee is the KeeperTank and needs OKB. If a post-graduation allowance is wanted for other tokens, the envelope needs two values (`ceilMaxQuote`, `ceilMaxToken`), or section 7 should say that `ceilMax` applies in the quote regime only.
2. **`K2L` across graduation is not specified.** `TAXCUM` restarts at graduation; the document does not say that `allowPaidCum` restarts too. If it does not, `room` mixes units. It does not affect this chip (no allowance after graduation), but it should be written down: both counters are per regime.
3. **`floorMin = 0` makes `K5` fire on an empty reserve** (`lg8(0) >= 0`), flagging a chip that outputs `REL = 0` when there is nothing to release. Either the factory should require `floorMin >= 1`, or `K5` should apply only when `reserve0 > 0`. The reference envelope uses 1.
4. **`TAX` and `DT` can disagree after a fallback settle.** `DT` counts epochs since the last persisted step, but a fallback settle routes inflow without persisting a step. If `step` works again later, the next `TAX` covers only the inflow since the fallback settle while `DT` covers the whole outage, so the chip under-reads the rate. Harmless, but section 5 should say which is intended.
5. **The first settle.** `dt_code` needs `epochNow > lastEpoch`. If `lastEpoch` starts at the bind epoch, no settle is possible during the first epoch after bind. Fine, but worth one sentence in section 9 of the interface.
6. **A dust guard on the buy leg would strand small reserves.** The chip releases 2/256 of any reserve every epoch. If the kernel skips buys below some amount, a reserve under 128 times that amount never leaves. If such a guard exists it should be tiny or absent.

Nothing in the interface was impossible to satisfy, and the chip does not diverge from it anywhere.

## 10. Open questions

- Sign-off of every constant in section 4, in particular: `AL3 = 8` instead of 0; the milestone decades; `RESMIN_Q` (finding 1); no allowance after graduation; `fallbackEpochs = 16` and `fbAllow = 8`.
- Whether the vault page should show IDLE and CRUISE as one mode. They route identically; IDLE only says a drought is declared.
- The token-regime thresholds assume about 8.4M tokens per OKB. If the curve's graduation price is far from that, `FLOOR_T` and `RESMIN_T` are off by the same factor. They only decide what counts as quiet and what reserve is worth a window.
- Not done: a z3 proof that the Python model equals the bytes for every (s, x). The model is checked against the bytes on 614,915 vectors and against the chain on 16,107; the RTL is proven equal to the bytes.
- Not done: a mainnet difftest. `step` is a pure function of the bytes, so the fork result carries over, but `tapc difftest` should be re-run against the mainnet circuit after tape-out and its evidence committed.

## 11. How to run everything

```
make -C chips/rtl venv        # chips/.venv-fg: Python 3.12, yowasp-yosys 0.69.0.0.post1233, z3-solver 5.1.0.0
make -C chips/rtl all         # params, model, scenarios, synth, test, prove, export, glutton   (about 3 minutes)
make -C chips/rtl fork        # local anvil fork at block 72373000: tape out, difftest, gas    (about 2 minutes)
make -C chips/rtl check       # verify the committed bytes without rebuilding them
```

Single steps:

```
chips/.venv-fg/bin/python chips/rtl/gen_params.py [--check]        # fg_params.json -> fg_params.vh
chips/.venv-fg/bin/python chips/model/flow_governor.py             # model self-check
chips/.venv-fg/bin/python chips/model/scenarios.py                 # all scenarios, behaviour checks, cadence test
chips/.venv-fg/bin/python chips/model/scenarios.py drought -v      # one per-epoch table
chips/.venv-fg/bin/python chips/model/scenarios.py --cadence       # cadence test only
PYTHONPATH=chips/tools chips/.venv-fg/bin/python -m tapc synth chips/rtl/fg_params.vh chips/rtl/fg_core.v \
    --name fg --top fg_core --nin 96 --nout 112 --pins chips/synth/fg.pins.json --out chips/out \
    --build chips/synth/build/fg --max-bytes 24000 --shape covenant-v1
chips/.venv-fg/bin/python chips/rtl/test_fg.py --n 200000          # RTL == model on the bytes
chips/.venv-fg/bin/python chips/props/prove.py                     # every proof, with times
chips/.venv-fg/bin/python chips/props/witness.py                   # the witness, from the model
chips/.venv-fg/bin/python chips/model/export.py                    # fields, vectors, scenario tables
chips/.venv-fg/bin/python chips/cells/glutton/demo.py [-v]         # Glutton under the envelope
chips/.venv-fg/bin/python chips/synth/fork_test.py --block 72373000 --n 10000
```

`fg_params.vh` is passed to Yosys as a source file in front of `fg_core.v`; there is no `` `include ``. The Makefile uses its own environment `chips/.venv-fg` and never touches `chips/.venv`; both pin the same package versions.

To tape out for real: mint 1,889 NAND (id 0) and 64 LATCH (id 1) on the Covenant processor's transistors, then `tapeout(bytes, 96, 112)` with exactly 0.0013 OKB and the contents of `chips/out/fg.hex`; or go through the Fab. Check `keccak256(netlist(id))` against section 2 and replay the witness of `chips/out/fg.witness.json` before the kernel takes the chip.
