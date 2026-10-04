# Glutton: the hostile demo chip

Glutton asks for everything on every beat, whatever the inputs are. It exists to show what the kernel's envelope does to a chip written by a stranger: the worst a chip can take is the envelope disclosed at launch, and the worst it can stall is nothing.

(This file replaces the placeholder the toolchain work stream left here while `chips/INTERFACE.md` was being written. The chips are built with the toolchain in `chips/tools` by `make -C chips/rtl glutton`; nothing in `chips/Makefile` touches them.)

Two variants, both interface v1 (96 inputs, 112 outputs, 1 latch, flat NAND/LATCH):

| | `glutton` | `glutton512` |
|---|---|---|
| Tax shares (buy, hold, allow, reserve) | 0, 0, **256**, 0 | **256**, 0, **256**, 0 (sums to 512) |
| Revenue shares | 0, 0, 256, 0 | 256, 0, 256, 0 |
| `REL` | 256 (the whole reserve) | 256 |
| `CEIL` | 1023 (no ceiling) | 1023 |
| Gates | 113 NAND + 1 LATCH = 114 | 113 NAND + 1 LATCH = 114 |
| Bytes | 795 | 795 |
| keccak256 | `0x3278542c10a5aa6e8fe993fc12cfb3a0c9d240450eae569bd431367094519582` | `0xcfb1f51e727184bdb9850cfa6ed4e8ff53806a50d248fa5417439e6ac0b9d4e4` |

The single latch is a heartbeat: it toggles every beat and is shown in `AUX` bit 0. It is there because the interface requires at least one latch; it changes nothing else. 112 of the 113 NAND records are the output bits: every output must be its own record, even a constant (`NAND(1, 1)` for 0, `NAND(0, 0)` for 1), so no chip with this interface can be smaller than 112 NAND plus its latches. The last record is the heartbeat inverter.

## What the kernel does with it

Run `demo.py`. It evaluates the bytes, routes them with `chips/golden/kernel_model.route_tax` under the reference envelope (`capT 48`, `allowCumBps 1875`, `ceilMax 440`, `relMax 128`, `floorRel 2`, `floorMin 1`) and prints the clamp bits and the amounts.

**`glutton`: clampBits = `K2 | K3` = 36 on every settle, `K2 | K2C | K3` = 44 on a very large one.**

| Clamp | What it does here |
|---|---|
| `K1T` | Does not fire: the share group is well formed |
| `K2` | Clips the allowance share from 256 to `capT` = 48 (18.75%). The other 81.25% stays in the reserve |
| `K2C` | Fires only when 18.75% of the inflow exceeds `exp8(440)` = 0.0338 OKB: the allowance is cut to that amount |
| `K2L` | Never fires: 1875/10000 equals 48/256, so the lifetime cap cannot bind once `K2` has acted |
| `K3` | Clips the release from 256 to `relMax` = 128: half the reserve per settle, and a release can only buy and lock |
| `K5` | Does not fire: Glutton asks for more than the floor |

What is actually routed, from `demo.py`:

| Flow | Chip | Clamp bits | Allowance | Bought and locked | Left in reserve |
|---|---|---|---|---|---|
| Steady, 0.005 OKB per epoch, 60 epochs | glutton | `K2+K3` | 18.75% | 78.54% | 2.7% (half of it leaves every settle) |
| | glutton512 | `K1T+K3` | 0% | 96.67% | 3.3% |
| | flow-governor | none | 8.33% | 71.65% | 20.0% |
| One epoch with 3 OKB of tax among ordinary ones | glutton | `K2+K2C+K3` once, else `K2+K3` | 3.64% | 96.12% | 0.2% |
| | glutton512 | `K1T+K3` | 0% | 99.71% | 0.3% |
| | flow-governor | none | 0.90% | 72.26% | 26.8% |

So Glutton gets exactly the cap and nothing more, and it cannot keep the rest: the reserve it is forced to leave behind is bought and locked at half per settle.

**`glutton512`: clampBits = `K1T | K3` = 33 on every settle.** A share group that does not sum to 256 is treated as 100% reserve. The allowance is zero. The kernel does not revert, the state still advances, and the reserve still leaves through the clipped release. (The revenue group is malformed the same way and would set `K1V` on kernel v2.)

The Flow Governor on the same flows sets no clamp bit at all. That is what "the chip decides" means in this project: `clampBits == 0` on every epoch, proven for every state and input.

## Files

| File | What |
|---|---|
| `glutton_core.v`, `glutton512_core.v` | The two cores: constants and one inverter |
| `glutton.pins.json` | Field names of the interface words, for the manifest |
| `glutton.tap`, `.hex`, `.manifest.json`, `.map.json` (and `glutton512.*`) | Netlist bytes, hex for `tapeout()`, manifest, gate map |
| `glutton_props.v` | Properties on the bytes: demands everything, group sum 256 (or 512), heartbeat, ignores every input |
| `glutton.proofs.json`, `glutton512.proofs.json` | Core == bytes and the properties, Yosys SAT and z3: 10 of 10 proved each |
| `demo.py` | The shadow-run above |
| `glutton.difftest.jsonl`, `glutton512.difftest.jsonl` | 300 on-chain `step` calls each on a local fork, all equal to the simulator |

## Reproduce

```
make -C chips/rtl glutton      # synthesise, prove, run the demo
make -C chips/rtl fork         # local anvil fork: tape out all three chips, difftest, step gas
chips/.venv-fg/bin/python chips/cells/glutton/demo.py -v     # per-epoch table
```

On the local fork (block 72373000, `chips/out/fg.fork.json`): tape-out of Glutton costs 530,264 gas and one `step` costs 379,203 gas (`eth_estimateGas`). Transistors burned: 113 NAND and 1 LATCH.

## Shadow-running Glutton on the reference token

`step` is a free read call and the kernel records every settle, so anyone can ask "what would Glutton have done with this token's real flows?" without a wallet. `RES` and `TAXCUM` depend on the chip's own past decisions, so a shadow-run replays amounts, not recorded input words: start from the recorded inflows, rebuild each input word with the kernel arithmetic, step the Glutton bytes and route the answer (`demo.py` does exactly this with `scenarios.Kernel`).
