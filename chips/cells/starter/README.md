# Starter: the smallest useful vault chip

The template behind `chips/kit/kit.sh new`. It does one thing a constant chip cannot do: it remembers. Two latches
hold an allowance tier that only ever goes up, so the share of tax paid as allowance only ever goes down.

| Output | Value |
|---|---|
| `T_BUY` | 192/256 (75%) of every epoch's tax is bought and locked |
| `T_ALLOW` | 32, 16, 8 or 0 by tier (12.5%, 6.25%, 3.1%, 0) |
| `T_RES` | `64 - T_ALLOW`, released at `REL` = 4/256 of the reserve per settle into buy-and-lock |
| `V_*` | all revenue to the reserve (kernel v2 only; kernel v1 ignores it) |
| `CEIL` | 440: the chip never asks for more than 0.0338 OKB of allowance in one settle |
| `TIER`, `FLAGS` bit 0 | telemetry: the tier after the beat, and whether it stepped up |

The tier is the larger of the old tier and the tier that this beat's `TAXCUM` (cumulative tax, as an lg8 code) has
earned: 1 from code 478 (0.94 OKB), 2 from 505 (9.2 OKB), 3 from 531 (92 OKB). `GRAD` earns tier 3 at once, because
`TAXCUM` restarts in token units at graduation and kernel v1 pays no allowance after it anyway.

Anyone can raise `TAXCUM` by sending OKB to the token's vault (chips/INTERFACE.md section 5). That OKB is routed like
tax and not returned, and it can only push the allowance down.

## Numbers

| | |
|---|---|
| Gates | 178 NAND + 2 LATCH = 180, 1,254 bytes, depth 17 |
| keccak256 | `0xac8a37a27bf4f86d790b03d543d161d8ba20c66d4458b44e9f6edebe05f4ffe4` |
| manifestHash | `0x2e6238e68dda7326985c3e5a4649784bf3df5939e99074ddb558a144c192bdc2` (SHA-256 of `out/starter.tape-pins.json`) |
| Proofs | 18 of 18 (core == bytes and eight properties, each with Yosys SAT and with z3, every state and every input) |
| Tape-out | 0.00622 OKB at block 72,524,201 (`kit.sh quote`): 180 transistors at 0.00002 OKB, two mint fees of 0.00066 OKB, the 0.0013 OKB tape-out fee |
| Step gas on a fork | TapeOut 483,737 of the 669,600 a settle gives it; sealed evaluator 43,969 of 76,400 |

## Properties (`starter_props.v`, proved on the netlist bytes)

| Property | Statement |
|---|---|
| `p_tshares_256`, `p_vshares_256` | each share group sums to exactly 256 |
| `p_ratchet` | the tier never decreases, over two chained beats with any inputs |
| `p_never_loosens` | whatever the next input word, the next beat's `T_ALLOW` is at most this beat's |
| `p_allow_by_tier` | `T_ALLOW` is 32, 16, 8, 0 for tiers 0 to 3, and `T_BUY` is always 192 |
| `p_grad_no_allow` | once `GRAD` is seen the tier is 3 and `T_ALLOW` is 0, on this beat and the next |
| `p_reference_envelope` | `T_ALLOW <= 48`, `2 <= REL <= 128`, `CEIL <= 440`: no clamp of the reference envelope can fire |
| `p_telemetry` | `TIER` shows the new tier, `FLAGS` bit 0 says it stepped up, `MODE` and `AUX` are 0 |

The properties are only as strong as what they state. A chip with the ratchet removed (`tier = earned`) fails
`p_ratchet`, `p_never_loosens` and `p_grad_no_allow` with counterexamples, which is how you know they are not vacuous.

## Envelope

`chip.json` carries the envelope the Starter is meant to run under: the reference envelope with `capT 32`,
`allowCumBps 1250` (32/256) and `relMax 16`, so the envelope promises no more than the chip asks for.
`kit.sh envelope` proves for every state and input that none of `K1T`, `K2`, `K2C`, `K2L`, `K3`, `K5` can fire
under it.

## Files

| File | What |
|---|---|
| `starter_core.v` | the core: `core(s, x) -> (ns, y)` |
| `starter_props.v` | the properties above |
| `chip.json` | kit config: sources, properties, state fields for the pin manifest, telemetry meanings, envelope |
| `out/starter.{tap,hex,manifest.json,map.json}` | netlist bytes, hex for tape-out, tapc manifest, gate map |
| `out/starter.proofs.json` | proof report, tied to the keccak256 |
| `out/starter.tape-pins.json` | the pin manifest (publish it as `.well-known/tape-pins.json`; its SHA-256 is the manifestHash) |
| `out/starter.build.json`, `quote.json`, `envelope-report.json`, `fork.json` | what each kit command found |

`out/starter.fork.json` and `out/starter.envelope-report.json` use the kit's fork outsider
`0xe766dd64fe4f5f49f7f413596355081e16f2d9ec` (the last 20 bytes of keccak256("covenant kit outsider"); an
impersonated address on a local fork, not a wallet anyone uses) as launcher. Nothing in them happened on X Layer.
