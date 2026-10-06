# Flow Governor: what the chip does

The Flow Governor is the flagship Covenant vault chip: 1,888 NAND gates and 64 latches. Its bytes are taped out twice on X Layer, as circuit 2 (held by the v1 kernel) and as circuit 5 (held by the v2 kernel, USD₮0 quote); each copy is immutable. Every epoch the kernel hands it one 96-bit word built from chain state, and it answers with one 112-bit word that says how that epoch's trading tax is routed. This page describes the rule it applies. The rule is the function `step(s, x)` in `chips/model/flow_governor.py`. That function, the Verilog `chips/rtl/fg_core.v` and the gates are proven to be one and the same function for every state and every input (section 9).

All constants are in `chips/rtl/fg_params.json`. Amounts reach the chip as `lg8` codes: one code is 1/8 of an octave (about 9%), so "8 codes" means "twice" and "16 codes" means "four times". The chip never sees wei, only codes; the kernel applies the shares to exact amounts.

Everything here is written against `chips/INTERFACE.md` revision 2.

## 1. In one paragraph

The chip keeps a moving average of tax per epoch and remembers the recent peak of that average. In ordinary flow it sends most of the tax straight to buy-and-lock, a tier-dependent share to the allowance payee, and a quarter to a reserve. When the tax rate jumps to at least twice the recent peak it banks more of it instead of buying into the spike. When the average has fallen to a quarter of its recent peak, when a banked surge fades, or when nothing has arrived for eight epochs, it releases the reserve into buy-and-lock in tranches for up to four epochs, pays no allowance while doing so, then rests for six epochs. The allowance share steps down for good each time cumulative tax passes a milestone. At graduation the tax unit changes from OKB to the project token, so the averages are dropped and re-seeded, and the allowance ends.

## 2. What the chip reads and what it answers

| Read from the input word | Meaning |
|---|---|
| `TAX` | tax that arrived since the last settle (code). It includes the tax the kernel's own buys paid, which comes back through the vault one settle later |
| `TAXCUM` | cumulative tax in the current regime (code), that tax included |
| `RES` | reserve held by the kernel before this settle (code). It includes decided buys that did not execute |
| `DT` | epochs since the last settle in which the chip was stepped, 1 to 15 (0 is read as 1; the kernel sends 15 for 15 or more) |
| `GRAD` | 1 once the token has graduated |

`REV`, `REVCUM`, `ESC`, `PROG`, `LOCK` and bits 81 to 95 are ignored (proven: property P5).

| Answer | Meaning |
|---|---|
| `T_BUY`, `T_ALLOW`, `T_RES` | shares of this settle's tax, in 1/256ths, summing to 256. `T_HOLD` is always 0 |
| `V_*` | always (0, 0, 0, 256): kernel v1 has no revenue |
| `REL` | share of the existing reserve released into buy-and-lock, in 1/256ths |
| `CEIL` | ceiling on this settle's allowance amount (code) |
| `MODE`, `TIER`, `FLAGS`, `AUX` | telemetry: see section 7 |

Kernel v1 has only two destinations for tax: the allowance payee, and buy-and-lock. The reserve is not a third destination. It is tax whose buy is deferred: everything in it leaves through `REL`, and `REL` can only buy and lock (after graduation: send to `0xdEaD`). So the chip decides two things: how much the payee gets, and when the rest is bought.

The chip decides; the kernel executes. A decided buy can be shrunk by the kernel's own limits (one buy per settle, capped against the depth of the curve, never the buy that graduates the token) or refused by IGNIX (a paused Manager). What does not execute stays in the reserve, shows up in `RES`, and is offered again.

## 3. The rule, step by step

Each settle covers `dt` epochs. Every counter below advances by `dt`, not by one, so the rule counts epochs, not settles.

1. **Reading.** The tax rate per epoch is `TAX` minus `8·log2(dt)` codes, measured above a floor. The floor is about 1e13 wei of OKB per epoch before graduation and about 23 tokens per epoch after. A reading at or below the floor is *quiet*; anything above is *live*.
2. **Patience.** A live reading sets a countdown to 8. Each quiet epoch takes one off. At zero the chip is *cold*: a drought is declared and the stored average is considered stale.
3. **Cold start.** The first live reading after reset, after a drought or after graduation *seeds* the average and the peak with that reading. For the next three epochs (warm-up) the average jumps straight up to any higher reading and nothing is classed as a surge. This is why ordinary volume returning after a long silence is not mistaken for a surge.
4. **Average.** Otherwise the average moves a quarter of the way to the reading each epoch, but falls by at most 3 codes per epoch (about 23%, what an arithmetic average loses on an empty epoch). A settle that covers 2 or 3 epochs moves it half the way, 4 or more all the way; the fall limit scales with `dt`.
5. **Peak and drawdown.** The peak follows the average up at once and loses one code every 4 epochs (it halves in 8 hours at 900-second epochs). *Drawdown depth* is how many codes the average sits below the peak.
6. **Surge.** A reading at least 8 codes (2x) above the peak is a surge. A surge meter counts +1 per surge epoch and -1 per other epoch, between 0 and 3. A reading at least 32 codes (16x) above the peak counts double.
7. **Allowance tier.** Before graduation the tier is the number of milestones cumulative tax has passed (about 0.009, 0.099 and 1.009 OKB), and it never goes down. After graduation the tier is frozen.
8. **Mode.** Evaluated in this order:
   - *DEFEND window open*: release one tranche per elapsed epoch until four tranche epochs are used. A surge, or a reserve below the minimum, ends the window early. Then REST.
   - *REST*: six epochs in which nothing but the leak is released. When the cooldown has run out the chip is back in the base case in the same step.
   - *BANK*: stays while the surge meter is above zero.
   - *Base case* (IDLE, CRUISE, or a finished REST or BANK):
     - if the reading is a surge and the meter has reached 2: **BANK**;
     - else if the reserve is at least the minimum (about 0.00042 OKB, or 959 tokens after graduation) and any of these holds: drawdown depth is 16 codes or more (the average is a quarter of its peak), a drought is declared, or a BANK just ended on a reading at most half the average: **DEFEND**, a new window opens;
     - else **CRUISE**, shown as **IDLE** while a drought is declared.
   - Never on the graduation step: that step only re-seeds.
9. **Routes.**

| Mode | Buy now | Allowance | To reserve | Release from reserve |
|---|---|---|---|---|
| IDLE, CRUISE, REST | 192 - AL | AL | 64 | leak: 2 per elapsed epoch |
| BANK | 256 - AL/2 - R | AL/2 | R = 128 to 192, growing 4 per code of surge above 2x, full at 8x | leak |
| DEFEND | 256 | 0 | 0 | tranche: 32, rising to 64 as drawdown depth goes from 16 to 32 codes; doubled when the settle covers two or more tranche epochs |

   `AL` is 48, 32, 16, 8 for tiers 0 to 3 before graduation and 0 after. All numbers are 1/256ths.
10. **Ceiling.** `CEIL` is code 440 minus 8 per tier: the allowance of one settle is at most 0.0338, 0.0169, 0.0084, 0.0042 OKB. What the ceiling cuts stays in the reserve.
11. **Graduation.** On the first step with `GRAD = 1` the chip clears the average, the peak and every timer, keeps the tier and the telemetry counters, and then treats the reading as a cold start in token units. The allowance is zero from then on. (Kernel v1 pays none after graduation whatever a chip asks; this chip does not ask.)

Reset is the all-zero state: IDLE, tier 0, cold.

## 4. Why each part is there

- **The floor and the cold start** keep the chip sensible on tiny flows. A $1 buy at 3% tax is about 2.5e14 wei (code 383), 37 codes above the floor, so it registers as live at any cadence up to 15 epochs. Inflows under about 1e13 wei per epoch never move the average.
- **The fall limit** stops the average collapsing on empty epochs. In the log domain one empty epoch would otherwise move it a quarter of the way to the floor: a factor of 17 for a flow of 1 OKB per epoch.
- **Surge against the peak, not the average**, means a pause never turns ordinary volume into a surge. Checked by a sweep in the scenario runner: for every third code above the floor in both regimes and every pause from 1 to 69 epochs, a return at the old level never enters BANK.
- **The leak** (2/256 of the reserve per epoch, in every mode) is the reason the reserve cannot grow without bound: under steady inflow it settles at 64/2 = 32 epochs of inflow. It also satisfies the kernel's reserve floor on every step, for every reserve.
- **Tranches and cooldown** pace the release so that one settle never asks for more than half the reserve, and a window of releases is followed by six epochs of none.
- **No allowance while defending** ties the payee to the token: it earns in ordinary flow and nothing while the reserve is being spent on support.

**The echo.** The kernel's own buy on the curve pays the 3% buy tax like anyone else. That tax lands in the kernel's own vault and is inflow in the next settle. The chip cannot tell it from outside tax, and does not need to. In ordinary flow it is a 2 to 3% ripple, less than one code. Two places where it shows:

- After outside trading stops, the tax of the chip's own leak and tranche buys keeps arriving. It is a live reading while it is above the floor (3% of a buy of 3.7e14 wei or more), so a drought is declared a little later than with no echo at all, and the tranche buys of a DEFEND window show as a small pulse one epoch later. The drawdown trigger does not depend on it.
- The payee's share is taken from the echo too. Against the tax that outside trading paid, the allowance over a run comes out 0.0 to 0.7 points higher than it would with no echo (section 8 of `chips/rtl/NOTES.md` has the numbers per scenario).

## 5. Constants

| Constant | Value | In plain terms |
|---|---|---|
| `FLOOR_Q` / `FLOOR_T` | code 346 / 515 | 9.9e12 wei per epoch / 23 tokens per epoch |
| `RESMIN_Q` / `RESMIN_T` | code 389 / 558 | 4.2e14 wei / 959 tokens: smallest reserve worth a DEFEND window |
| `TOKEN_SHIFT` | 169 codes | token base units per wei of OKB when the pair opens (see below) |
| `M1`, `M2`, `M3` | codes 425, 452, 479 | 0.0090, 0.0991, 1.0088 OKB of cumulative tax |
| `AL0..AL3` | 48, 32, 16, 8 | 18.75%, 12.5%, 6.25%, 3.125% of fresh tax |
| `CEIL0`, `CEIL_STEP` | 440, 8 | 0.0338 OKB per settle, halving per tier |
| `RC` | 64 | 25% of fresh tax to the reserve in ordinary flow |
| `RB_MIN`, `RB_GAIN`, `RB_SPAN` | 128, 4, 16 | 50% to 75% to the reserve while banking |
| `SURGE_TH`, `XSURGE_TH` | 8, 32 codes | 2x and 16x the recent peak |
| `DD_TH` | 16 codes | average at a quarter of its peak |
| `DIP_TH` | 8 codes | reading at half the average (used for the fade trigger and a flag) |
| `SLEW_Q` | 12 quarter-codes | the average falls at most 3 codes per epoch |
| `PK_DIV` | 4 | the peak loses a code every 4 epochs |
| `DRYN`, `WARMN` | 8, 3 | epochs to a drought; warm-up epochs |
| `TRN`, `CDN` | 4, 6 | tranche epochs per window; cooldown epochs |
| `TR_MIN`, `TR_MAX` | 32, 64 | tranche of 12.5% to 25% of the reserve |
| `LEAK` | 2 | 0.78% of the reserve per epoch |

**The token-regime thresholds** are the OKB ones moved by 169 codes. An IGNIX curve sells 800,000,000 tokens; when it is sold out it has raised 85 OKB, and the Uniswap V2 pair opens with the remaining 200,000,000 tokens against those 85 OKB. That is 2,352,941 token base units per wei of OKB, which is 169.3 codes. `chips/rtl/gen_params.py` derives the number from the curve in integers and refuses to build if `FLOOR_T` or `RESMIN_T` disagree with it. At the opening price the two token thresholds are worth 9.8e12 wei and 4.1e14 wei, the OKB thresholds within one code.

Reference envelope (the kernel's immutable bounds for the reference token): `capT 48`, `allowCumBps 1875`, `ceilMax 440`, `relMax 128`, `floorRel 2`, `floorMin 1`, `epochLen 900`, `fallbackEpochs 16`, `fbAllow 8`. The chip is proven never to touch any of them, and `gen_params.py` checks the envelope against every limit the kernel factory enforces (`chips/INTERFACE.md` section 7).

## 6. The 64 latch bits

State bit `i` is LATCH record `i` of the netlist and bit `i mod 8` of byte `i / 8` of the stored state. Drawn as an 8 by 8 die, bit `i` sits in row `i / 8`, column `i mod 8`. The same table, per bit, is in `chips/out/fg.fields.json`, and as a pin manifest bound to the netlist by its keccak256 in `chips/out/fg.pins.json`.

| Bits | Field | Meaning |
|---|---|---|
| 0-11 | `A` | The average tax rate per epoch, in quarter-codes above the floor. 0 means at the floor |
| 12-21 | `PK` | The decaying peak of the average, in codes above the floor |
| 22-23 | `PKDIV` | Counts epochs to the next one-code decay of the peak (every 4) |
| 24-26 | `MODE` | 0 IDLE, 1 CRUISE, 2 BANK, 3 DEFEND, 4 REST |
| 27-28 | `TIER` | Allowance tier 0 to 3. Never decreases |
| 29 | `GSEEN` | Graduation has been seen; the re-seed happens once |
| 30-31 | `WARM` | Warm-up epochs left after a cold start |
| 32-35 | `LIVE` | Quiet epochs left before a drought is declared. 0 means cold |
| 36-37 | `SUR` | Surge meter, 0 to 3. BANK starts at 2 and ends at 0 |
| 38-39 | `TR` | Tranche epochs left in the open DEFEND window |
| 40-42 | `CD` | Cooldown epochs left in REST |
| 43-47 | `NBANK` | How many BANK episodes have started, up to 31. Telemetry |
| 48-53 | `NDEF` | How many DEFEND windows have opened, up to 63. Telemetry |
| 54-63 | `CLOCK` | Elapsed epochs modulo 1024. Telemetry: it moves on every settle, even with no inflow |

Rows of the die: row 0 is `A[7:0]`; row 1 is `A[11:8]`, `PK[3:0]`; row 2 is `PK[9:4]`, `PKDIV`; row 3 is `MODE`, `TIER`, `GSEEN`, `WARM`; row 4 is `LIVE`, `SUR`, `TR`; row 5 is `CD`, `NBANK`; row 6 is `NDEF`, `CLOCK[1:0]`; row 7 is `CLOCK[9:2]`.

Invariant, proven inductive from reset (P4): `MODE <= 4`; `LIVE <= 8`; `CD <= 5`; `TR` is non-zero only in DEFEND; `CD` is non-zero only in REST; BANK implies `SUR > 0`; warm-up implies recent live flow; the peak is never below the average; the average and the peak stay inside the code range above the floor.

## 7. Telemetry outputs

- `MODE` and `TIER` are the latch values after the step.
- `FLAGS`: bit 0 surge (reading at least 2x the peak); bit 1 dip (reading at most half the average); bit 2 quiet; bit 3 release (this step routes as DEFEND and releases a tranche); bit 4 regime (graduation seen in this step); bit 5 tier-up; bit 6 cooldown (the chip is in REST after this step); bit 7 warm (cold start or warm-up).
- `AUX`: drawdown depth in codes, up to 255.

One nuance: when a settle covers both the last tranche epoch and the start of the cooldown (only possible when epochs were skipped), the step routes as DEFEND (release flag set) while `MODE` already reads REST. With a settle every epoch, `MODE` always names the routing of that settle.

## 8. Cadence

The keeper is meant to settle every epoch, but anyone may settle and anyone may skip. Counters advance by `DT`, so a rule that waits N epochs waits N epochs whatever the number of settles. Three things cannot be made independent of cadence, and are stated rather than hidden: a settle routes all the tax it covers with one share word; the average gets one reading per settle; and the kernel executes one capped buy per settle.

**Definition used by the test** (`chips/model/scenarios.py --cadence`). The reference keeper settles every epoch. Another keeper settles the same flow on another schedule. A common settle point is an epoch at which both settle. The two are equivalent when:

- **E1 tier.** The tier is the same at every common settle point, except that a milestone may be passed one settle apart: never more than one tier apart, at most one such settle point per milestone, the same tier at the end of the run. Cumulative tax includes the echo, and two keepers have bought slightly different amounts by any given epoch, so one of them can be a fraction of an epoch short of a milestone when the other has just passed it.
- **E2 clamps.** Neither run ever sets a clamp bit. Exact.
- **E3 money.** At the end of the run, cumulative allowance differs by at most 2 points of the tax outside trading paid and the cumulative amount bought by at most 6 points, for schedules that skip at most 3 epochs in a row; 4 and 10 points for schedules that skip up to 11.
- **E4 timing.** On flows that are constant between changes and schedules that skip at most 3 epochs in a row: at 85% or more of the common settle points, the mode of the slower keeper equals the mode of the reference keeper at some epoch within k + 2 epochs (IDLE and CRUISE count as one mode).

Measured over 18 flows and 8 schedules (every 2, 3, 4, 6, 8, 12 epochs; skip quiet epochs up to 8; miss 25% at random), with the echo and the kernel's execution limits simulated: E2 holds everywhere; the tiers differ at 2 settle points in all 144 pairs of runs (one milestone in the `surge` flow, passed one settle later by two of the slower keepers); worst allowance difference 1.70 points (fast schedules) and 3.41 points (slow); worst bought difference 5.65 and 9.42 points; worst mode agreement 90.0%. Skipping settles mostly lowers the allowance: across all runs a slower keeper raised it by at most 0.59 points and lowered it by at most 3.41 points.

Three situations are outside the claim. They are measured and printed by the test, not asserted.

**Known limit 1: a spike shorter than the gap between settles** cannot be seen as a spike by the slower keeper. In the `whale` flow (one epoch with 600 times the usual tax) the per-epoch keeper banks it and its drawdown depth peaks at 15 codes, one short of the trigger, while slower keepers pass 16 and open further DEFEND windows. Both keep the money in the reserve and both buy it all; after 60 epochs the amounts bought differ by up to 29 points of the tax paid. Allowance and tier are unaffected (0.39 points, exact).

**Known limit 2: a buy above the kernel's cap.** The kernel executes at most one buy per settle, capped against the depth of the curve (about 0.49 OKB on a fresh curve of the reference token, rising to 1.95 OKB as the curve fills). When the chip's decided buy is above that, a keeper who settles every k epochs executes up to k times less per epoch, and the rest waits in the reserve. In the flows that reach the cap (`ramp`, `milestones`, `steady-large`: 0.65 to 2 OKB of tax per epoch, three to four orders of magnitude above the reference token's expected flow) the amounts bought by the end of the run differ by up to 63 points. E3 is asserted only for pairs of runs in which no buy was shrunk. Allowance, tier and clamps are not affected.

**Known limit 3: the pulse after graduation.** At graduation the OKB the kernel still holds (its reserve and the residual OKB tax, including the 3% the graduating buy paid) becomes the native pot. The kernel spends it on the pair by itself, one capped router buy per settle, and the 3% token tax of those buys arrives as token inflow. The chip sees a pulse whose length is counted in settles, not epochs. In the `graduation` flow the pot is 2.3 OKB, the pulse is 7.5 times the outside token flow for two settles, the chip seeds its peak on it and opens four DEFEND windows while that peak decays. Mode agreement with slower keepers is 83% to 100% there, so E4 is not asserted for that flow; E1 to E3 hold.

**Hostile timing.** A settler who controls the timing can shift a reading by at most a factor of two (a window of almost two epochs counted as one) and can produce one near-empty reading, but not two in a row, because settles must fall in different epochs. BANK needs two surge epochs or one 16x reading, a drought needs eight quiet epochs, and a drawdown needs the average to fall for six or more epochs, so one distorted reading triggers nothing. After more than 15 epochs without a settle the rate is overstated (`DT` saturates); the worst outcome is that the backlog is routed with BANK shares, that is, more of it waits in the reserve.

**After an evaluator outage.** If neither evaluator answers, the kernel reverts for 15 epochs and then routes with its fallback word until one answers again; the chip's state does not move meanwhile. The first step afterwards has `DT = 15` but `TAX` covers only the tax since the last fallback settle, so the rate is under-read once, by up to 31 codes. In the `outage` scenario that reads as a drawdown: one DEFEND window on whatever reserve the fallback left (4 epochs without allowance), then CRUISE again 11 epochs after the evaluator is back. No clamp fires and the tier is kept.

## 9. What is proven

For every one of the 2^64 states and 2^96 input words, on the netlist bytes, by Yosys's SAT solver and again by z3 (`chips/props/`, results in `chips/out/fg.proofs.json`: 96 solver checks and 2 tests):

- **EQ** the bytes compute exactly `fg_core.v`.
- **P1** both share groups sum to 256, no share exceeds 256, the holder share is 0.
- **P2** no kernel clamp can fire: `T_ALLOW <= 48`, `REL <= 128`, `REL >= 2` for every reserve, `CEIL <= 440`.
- **P3** the tier never decreases; the allowance is bounded by the tier's share and the ceiling equals the tier's ceiling; with everything else equal a higher tier never gives a larger allowance or ceiling; after graduation the tier is frozen and the allowance is 0.
- **P4** the invariant of section 6 holds at reset and is preserved by every step.
- **P5** the ignored inputs are ignored.
- **P6** while the whole settle lies inside the cooldown, the release is exactly the leak and the cooldown counter strictly decreases (a settle that also covers epochs after the cooldown may open the next DEFEND window: leftover epochs are credited to the next phase); any release above the leak is a flagged DEFEND tranche, and a DEFEND step routes all fresh tax to buy.
- **P7** the witness below, and one input sequence from reset that visits all five modes.

And for the model itself (`chips/props/model_equiv.py`, results in `chips/out/fg.model.json`):

- **ME** the bytes compute exactly `step(s, x)` of `chips/model/flow_governor.py`, for every state and every input, and `step` never raises. The source of `step` is executed on z3 terms instead of numbers, which turns the Python function itself into a formula, and z3 proves that formula equal to the netlist for each of the 28 fields of the state and the output word (176 bits). A second formula, the same rule written by hand, is proven equal to the netlist as well. So the model on this page, the Verilog and the gates are one function, not three that agree on test vectors.

The lifetime allowance cap (`K2L`) is a statement about amounts, not about the chip. It cannot bind for any chip under this envelope because 1875/10000 equals 48/256 exactly: after the kernel's own cap, the allowance paid so far is at most the floor of 48/256 of cumulative inflow.

Every proof is shown able to fail: ten deliberately broken chips are each rejected by the property they break, and the model proof rejects a formula that is wrong at a single one of the 2^160 points, for every field.

## 10. The witness (check 1 of the judge guide)

Two states the chip reaches from reset, one input word, two different routes. No function of the inputs can do this.

The words are the ones the kernel would assemble by itself in the simplest history there is: 0.01 OKB of tax arrives in the first epoch and nothing is traded afterwards. After the first settle the only inflow is the echo of the kernel's own buys, which fades to about 6e11 wei, far below the chip's floor. From the fifth settle on the kernel assembles the same word `X` for several epochs running.

```
W1 = 0xa9a506000000000000100000     TAX 425, TAXCUM 425, RES 0,   DT 1    0.01 OKB of tax arrived
W2 = 0x7ba906000099010000100000     TAX 379, TAXCUM 426, RES 409, DT 1    the echo of the first buy
W3 = 0x4fa906000099010000100000     TAX 335, TAXCUM 426, RES 409, DT 1    the echo of the second buy
W4 = 0x3aa906000099010000100000     TAX 314, TAXCUM 426, RES 409, DT 1    the echo of the leak, from here on
X  = 0x39a906000099010000100000     TAX 313, TAXCUM 426, RES 409, DT 1

SA = state after W1, W2, W3, W4          = 0x18e1040906000001
SB = state after W1, W2, W3, W4, X, X    = 0x00e1840904008001

step(SA, X) -> CRUISE: buy 160, allowance 32, reserve 64, release 2
step(SB, X) -> DEFEND: buy 256, allowance 0,  reserve 0,  release 34
```

Both states are in CRUISE. They differ in the stored average, peak and countdowns: in SB the average has been falling for two more quiet epochs and sits 14 codes below its peak, so one more quiet epoch takes the drawdown past 16 codes and the same word opens a DEFEND window. On chain, with `CPU` the processor and `ID` the circuit:

```
cast call $CPU 'step(uint256,bytes,bytes)(bytes,bytes)' $ID 0x18e1040906000001 0x39a906000099010000100000
cast call $CPU 'step(uint256,bytes,bytes)(bytes,bytes)' $ID 0x00e1840904008001 0x39a906000099010000100000
```

Expected answers (new state, then the 14 output bytes; the output word is the little-endian integer of those bytes, `T_BUY` in bits 0-8, `T_ALLOW` in bits 18-26, `T_RES` in bits 27-35, `REL` in bits 72-80, `MODE` in bits 91-93):

```
from SA:  0x0ce1440905004001   0xa0008000020000008002604b060b
from SB:  0xf4e0c40bc300c101   0x00010000000000008022605b0e11
```

The words, states and expected answers are in `chips/out/fg.witness.json`, regenerated from the model and the kernel model by `chips/props/witness.py` and checked on the bytes by SAT, by z3, by the simulator and on a fork by `step`.

## 11. Honest limits

- Codes are 9% wide, so "twice" means between about 1.9x and 2.1x. Shares are still applied to exact amounts by the kernel.
- The chip sees tax, not trading. The tax of the kernel's own buys and anything sent to the vault count like any other tax (section 4, the echo). `TAXCUM` therefore reaches a milestone 2 to 3% sooner than the tax of outside trading alone would.
- The chip reads `DT = 15` as 15 epochs. The kernel sends 15 for anything longer, so after a longer gap the rate is overstated, and after an evaluator outage it is understated once (section 8).
- A reserve under about 0.00042 OKB is never released in tranches. It leaves through the leak alone: half of it in 22 hours.
- After a single very large epoch the banked tax is released over one DEFEND window (41% of it) and then by the leak, unless a drawdown or drought opens further windows.
- A decided buy is not an executed buy. Above the kernel's cap, during an IGNIX buy pause, and once the curve is within a few base units of its end, the reserve waits (section 8, known limit 2). The chip keeps offering at its usual pace; it does not speed up to clear a backlog.
- The chip does not read price, progress or locked supply. It reads tax flow and the reserve.
- The chip is immutable. A better rule means a second, disclosed chip, never a patch.
