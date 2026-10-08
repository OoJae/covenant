# Build your own vault chip

Anyone can design a Covenant vault chip, tape it out through the Fab, give it a kernel and launch a token on it,
without asking the team. None of the contracts on that path (Fab, KernelFactory, Lens, KeeperTank) has an owner, an
allow-list or a switch. This page is the short path, with `chips/kit/kit.sh`.

The kit targets kernel v1 (a token quoted in OKB, `KernelFactory` `0xAAA7…03ad`). A kernel v2 (a token quoted in USD₮0,
`KernelFactoryV2` `0x231c…82c1`) runs the same chips through a fixed code shift, but the kit does not plan or rehearse
it. `contracts/core-v2/script/LaunchChipV2.s.sol` takes any netlist (`NETLIST_HEX`); `deploy/launch-kernel-v2.sh`
signs only the Flow Governor. See `contracts/core-v2/NOTES.md`.

The interface your chip implements is `chips/INTERFACE.md` (revision 2): 96 input bits the kernel builds from chain
state once per epoch, 112 output bits that say how to route that epoch's tax, 1 to 256 latches of your own state,
NAND and LATCH records only, at most 3,400 gates.

## What you need

- The chip toolchain, once: `make -C chips/rtl venv` (Python 3.12 with Yosys/ABC as `yowasp-yosys` and Z3).
- [Foundry](https://getfoundry.sh) (`cast`, `anvil`) and `jq` for the fork rehearsal and the signing script.
- Node 26 for `tools/launch-check`, the last check before the token launch.
- A wallet with OKB on X Layer: the **launcher**. It signs everything and must be the wallet that creates the token.
  The plan script signs with `cast send --account <name>` (a key in cast's keystore, added with
  `cast wallet import <name> --interactive`) or with any other `cast send` signer options in `SIGN`, such as `--ledger`.

## Six commands

```sh
chips/kit/kit.sh new mychip                       # chips/cells/mychip/ from the Starter template
# edit chips/cells/mychip/mychip_core.v, mychip_props.v and chip.json
chips/kit/kit.sh build    chips/cells/mychip      # synthesise, prove, pin manifest, manifestHash
chips/kit/kit.sh quote    chips/cells/mychip      # what the tape-out costs right now (eth_call only)
chips/kit/kit.sh envelope chips/cells/mychip --launcher 0xYOU   # check your envelope; which clamps can fire
chips/kit/kit.sh fork     chips/cells/mychip      # the whole launch on a local fork (add --launcher 0xYOU to rehearse as you)
chips/kit/kit.sh plan     chips/cells/mychip --launcher 0xYOU   # the transactions you sign, as a script
```

| Command | What it does | Touches |
|---|---|---|
| `new` | Copies the [Starter](../chips/cells/starter/README.md) (180 gates, a fixed split with a one-way allowance ratchet) under your name | your disk |
| `build` | Yosys + ABC to TAP-20 NAND/LATCH bytes, checked against the shape the Fab enforces; proves core == bytes and every 1-bit output of your properties module, with Yosys SAT and with Z3, for every state and input; writes the pin manifest `<name>.tape-pins.json` (draft "Circuit Pin Manifest", profile `covenant-v1`) and its SHA-256, the `manifestHash` | your disk |
| `quote` | `Fab.quote` plus TapeOut's three prices, the remaining transistor supply and your chip's KeeperTank allowance | `eth_call` on X Layer |
| `envelope` | Writes the envelope from `chip.json` and your flags, checks it rule by rule against the factory (section 7), asks `KernelFactory.predict` the same on chain (with the flagship's chip id, since yours does not exist yet), prints what the envelope guarantees, and proves with Z3, for every state and input, which clamps (`K1T`, `K2`, `K2C`, `K2L`, `K3`, `K5`) your chip can trigger | `eth_call` on X Layer |
| `fork` | Starts anvil on a free local port, impersonates a keyless outsider, runs the exact plan script against the fork (tape-out, kernel, hand-over, `Lens.preflight`), reads everything back, steps the taped-out chip six times on the fork and routes the answers with the kernel model, then stops anvil | a local fork only |
| `plan` | Writes `<name>.plan.sh`: the three `cast send` transactions, each after a "yes" prompt, and the preflight; a step its state file records as done is skipped on a re-run, and a state file from another netlist or envelope stops it; before the first signature it asks `KernelFactory.predict` whether the envelope is accepted, and it stops after any transaction the launcher did not sign; then the deployment and expected-values files for `tools/launch-check` and the IGNIX launch settings | your disk |

Reproduce the two runs below with `chips/kit/kit.sh fork chips/cells/starter` and, after
`chips/kit/kit.sh build chips/cells/glutton/glutton.kit.json`, `chips/kit/kit.sh fork chips/cells/glutton/glutton.kit.json`.
Tests of the kit (`make -C chips/rtl venv` installs pytest): `chips/.venv-fg/bin/python -m pytest chips/kit/test_kit.py` (`NETWORK=1` adds `eth_call` checks that
the live factory refuses each of 19 rule-breaking envelopes with the same `BadEnvelope` code as the kit, and accepts
the boundary cases).

The kit never reads a key and never sends a transaction to X Layer. `plan.sh` sends, when **you** run it with your
own signer (`ACCOUNT=<cast keystore name>` or `SIGN="--ledger"`).

## What it costs

Read with `kit.sh quote` at block 72,524,201 (2026-10-06); prices are TapeOut's and are read again when you sign.

| Chip | Transistors | Tape-out | KeeperTank allowance (85% of the mint price) |
|---|---|---|---|
| Glutton (hostile demo) | 114 | 0.0049 OKB | 0.001938 OKB |
| Starter | 180 | 0.00622 OKB | 0.00306 OKB |
| Flow Governor (flagship) | 1,952 | 0.04166 OKB | 0.033184 OKB |
| Largest chip the Fab accepts | 3,400 | 0.07062 OKB | 0.0578 OKB |

Tape-out = 0.00002 OKB per transistor + 0.00066 OKB per mint call (one for NAND, one for LATCH) + 0.0013 OKB tape-out
fee. Gas measured on the fork for the Starter: tape-out 1,250,047, create 323,734, hand-over 75,264 (Glutton:
960,430, 323,548, 75,264). The IGNIX launch costs what IGNIX charges at ignix.bot; the kit does not cover it.

Settles cost gas every epoch. Anyone may call `KeeperTank.settleAndRefund(kernel)`, which refunds the caller from your
chip's allowance until it is spent; `KeeperTank.topUp(chipId)` adds to it. The refund is paid only from OKB the tank
holds, and the tank is shared by every chip: your tape-out's 85% reaches it when someone calls `Splitter.pull()`
(anyone may). On 2026-10-06 (block 72,526,013) the tank held 0 OKB: until a `pull()` a settle runs but refunds nothing. `pull()` was
first called later that day (block 72,559,111); on 2026-10-08 the tank held 0.0446 OKB. On a
fork, a settle that bought on the curve used 949,291 gas; at X Layer's 0.02 gwei that is about 0.000019 OKB, so the
Starter's 0.00306 OKB covers on the order of 160 such settles (about 40 hours at one per 15-minute epoch). Do not
count on anyone else to settle your kernel: if nobody settles, the tax waits in the vault.

## What the kernel bounds, for any chip

The envelope is fixed in the kernel's bytecode when you create it. With the factory's limits (INTERFACE.md section 7),
on every kernel the factory creates, however hostile the chip:

1. At most `min(capT / 256, allowCumBps / 10000)`, and never more than half, of the OKB that reaches the kernel can
   become allowance, at most `exp8(ceilMax)` per settle, only to the allowance payee, and nothing after graduation.
2. Everything else can only be bought and locked, burned, or wait in the reserve.
3. A reserve at or above `exp8(floorMin)` is offered to the buy leg at `floorRel / 256` per settle or faster.
4. If neither evaluator answers, the fallback word applies within 30 days.

Glutton asks for the whole tax, the whole reserve and no ceiling on every beat. On the fork it was taped out from an
outsider address, accepted by the Fab and the factory, and passed preflight (both evaluators ran and agreed). Under the
reference envelope `kit.sh envelope` proves it triggers `K2` and `K3` (and `K2C` on a large epoch) and can never
trigger `K2L`; routed by the kernel model, its six fork settles paid 18.75% of a 0.05 OKB epoch and 0.0338 OKB of
each larger one. The Starter under its own envelope triggers no clamp at all, proved for every state and input.

The envelope, not the chip, is what a holder has to read. Make it as tight as your chip: the Starter never asks for
more than 32/256, so its envelope says `capT 32`.

## What is not checked, and not audited

- **Nothing here is audited**: not the Covenant contracts, not TapeOut, not IGNIX, not this kit.
- Proofs cover the properties you wrote, no more. A property that states too little proves too little. The kit's
  `envelope` analysis covers every state your latches can hold, including states the chip never reaches from zero,
  so a "can fire" may be a state that never occurs; a "never" holds regardless.
- The Fab records your `manifestHash` as given and does not check it. Publish the manifest file so readers can.
- The kernel never reads the telemetry outputs (`MODE`, `TIER`, `FLAGS`, `AUX`); they mean something only if your
  proofs tie them to the routing.
- The fork run is a rehearsal: no token exists there, so the six settles it shows are the chip's real on-chain answers
  routed by the Python kernel model (`chips/golden/kernel_model.py`, which the Solidity kernel matches on the golden
  vectors), not real settles. `tools/launch-check` is not run by the kit: it needs the exact launch transaction from
  ignix.bot, which only exists when you launch. In one review run, on a fork where IGNIX's platform signer was
  replaced by a test key, a kit-made Starter kernel passed `launch-check` (34 of 34) and `simulate.ts`, and the
  `bind` and `settleAndRefund` commands the plan prints ran from unrelated addresses.
- Owners outside Covenant keep their powers (INTERFACE.md section 13): TapeOut's 3-of-5 Safe can upgrade its
  processor logic (the kernel then uses the sealed evaluator), IGNIX's owner can pause buys and claims or upgrade
  `IgnixManager`.
- Economics are yours. A chip inside every bound can still route badly.

## Credits

The chip format is TAP-20 and chips run on TapeOut's processor (`Circuits.step`); the sealed evaluator is a port of
TapeOut's MIT-licensed `NetlistVM`. The Fab and the KernelFactory use OpenZeppelin Contracts v5 (MIT). Synthesis is
Yosys and ABC through `yowasp-yosys`; proofs use Yosys SAT and Z3; the fork runs on Foundry's anvil. Tokens launch on
IGNIX. Sources and licences: `docs/THIRD_PARTY.md`.
