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

Run `demo.py`. It evaluates the bytes inside the revision-2 kernel model of `chips/model/scenarios.py` (clamps by `chips/golden/kernel_model.route_tax`, buys sized on the simulated curve, the tax of the kernel's own buys returning as inflow) under the reference envelope (`capT 48`, `allowCumBps 1875`, `ceilMax 440`, `relMax 128`, `floorRel 2`, `floorMin 1`) and prints the clamp bits and the amounts.

**`glutton`: clampBits = `K2 | K3` = 36 on every settle, `K2 | K2C | K3` = 44 on a very large one.**

| Clamp | What it does here |
|---|---|
| `K1T` | Does not fire: the share group is well formed |
| `K2` | Clips the allowance share from 256 to `capT` = 48 (18.75% of inflow). The other 81.25% stays in the reserve |
| `K2C` | Fires only when 18.75% of the inflow exceeds `exp8(440)` = 0.0338 OKB: the allowance is cut to that amount |
| `K2L` | Never fires: 1875/10000 equals 48/256, so the lifetime cap cannot bind once `K2` has acted |
| `K3` | Clips the release from 256 to `relMax` = 128: half the reserve per settle, and a release can only buy and lock |
| `K5` | Does not fire: Glutton asks for more than the floor |

What is actually routed, from `demo.py`. Percentages are of the tax that outside trading paid; "bought" is net of the 3% buy tax that the kernel's own buys send round again; "left" is the reserve at the end plus what still waits in the vault:

| Flow | Chip | Clamp bits | Allowance | Bought and locked | Left |
|---|---|---|---|---|---|
| Steady, 0.005 OKB per epoch, 60 epochs | glutton | `K2+K3` | 19.19% | 77.99% | 2.8% (half of the reserve leaves every settle) |
| | glutton512 | `K1T+K3` | 0% | 96.51% | 3.5% |
| | flow-governor | none | 8.50% | 71.00% | 20.5% |
| One epoch with 3 OKB of tax among ordinary ones | glutton | `K2+K2C+K3` once, else `K2+K3` | 4.20% | 95.56% | 0.2% |
| | glutton512 | `K1T+K3` | 0% | 99.70% | 0.3% |
| | flow-governor | none | 0.95% | 69.64% | 29.4% |
| Sparse dollar-sized buys, 300 epochs | glutton | `K2+K3` | 19.21% | 79.78% | 1.0% |
| | glutton512 | `K1T+K3` | 0% | 98.74% | 1.3% |
| | flow-governor | none | 10.33% | 84.73% | 4.9% |

So Glutton gets exactly the cap and nothing more, and it cannot keep the rest: the reserve it is forced to leave behind is bought and locked at half per settle.

**Why 19.2% and not 18.75%.** The cap is 48/256 of inflow, and it holds on every settle (`demo.py` asserts it). But inflow is not only the tax traders paid: every OKB the kernel spends on the curve pays the 3% buy tax into the kernel's own vault, and that comes back as inflow one settle later. Glutton takes 18.75% of that too. Against the tax outside trading paid, a chip that always takes the cap therefore ends at 18.75 / (1 - 0.03 x 0.8125) = 19.2%. That is the most any chip can take under this envelope with a 3% buy tax; the lifetime cap `K2L` counts the same inflow and never fires.

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

`step` is a free read call and the kernel records every settle, so anyone can ask "what would Glutton have done with this token's real flows?" without a wallet. `RES`, `TAXCUM` and even `TAX` depend on the chip's own past decisions (what it bought comes back as tax), so a shadow-run replays the tax of outside trading, not recorded input words: rebuild each input word with the kernel arithmetic, step the Glutton bytes, route the answer and move the simulated curve (`demo.py` does exactly this with `scenarios.run`).

## Through the chip kit

`glutton.kit.json` lets `chips/kit/kit.sh` (docs/BUILD_YOUR_CHIP.md) treat Glutton like any outsider's chip:

```
chips/kit/kit.sh build    chips/cells/glutton/glutton.kit.json   # same 795 bytes, keccak256 0x3278...9582, 10/10 proved
chips/kit/kit.sh envelope chips/cells/glutton/glutton.kit.json --launcher <address>
chips/kit/kit.sh fork     chips/cells/glutton/glutton.kit.json   # tape-out, kernel, hand-over, preflight on a local fork
```

On a fork at block 72,524,440 a keyless outsider address taped it out through the Fab (0.0049 OKB, 960,430 gas), the
factory created its kernel with the reference envelope, and `Lens.preflight` passed: both evaluators ran within the
gas a settle gives them (TapeOut 339,363 of 497,200; sealed 33,633 of 63,000) and agreed. `kit.sh envelope` proves,
for every state and input, that under the reference envelope it can trigger `K2`, `K3` and (on a large epoch) `K2C`,
and never `K1T`, `K2L` or `K5`. Outputs go to `chips/cells/glutton/out/`.

The kit writes a new pin manifest (`out/glutton.tape-pins.json`, profile `covenant-v1`, SHA-256 `0xde65...a3d5`). It
is not the manifest Glutton was taped out with on mainnet: chip 3 records `0x12d9...c7ea`, the SHA-256 of
`glutton.pins.json`. The netlist bytes are the same.
