# Covenant

**Your token's tax, routed by a chip anyone can read and nobody can change.**

Covenant is an entry to the TapeOut Genesis Transistor Hackathon (organiser: IGNIX; chain: X Layer, id 196).

Live site (no wallet needed): https://oojae.github.io/covenant/

## What it is

An IGNIX token can send all of its trading tax to one address through the Directed vault. Covenant makes that address a small contract, the **kernel**, bound to one taped-out TapeOut circuit, the token's **chip**.

Once per epoch anyone may call `settle()`. The kernel then:

1. claims the accrued tax from the token's vault;
2. builds a 96-bit input word from chain state (no caller supplies an input);
3. steps the chip, passing the latch state it stored after the previous epoch;
4. stores the new state and a full record of the epoch;
5. executes the chip's 112-bit output as routes: buy-and-lock, allowance, reserve.

The chip decides. The kernel limits what any decision can do: each route is clipped to bounds fixed when the kernel is created, and a chip's output can never make `settle()` revert.

TapeOut stores no state for sequential circuits; a consumer contract has to keep it. The kernel is that consumer.

## Why a circuit and not Solidity

- **A stranger's logic is safe to run.** A chip cannot call another contract, write storage or use more gas than its gate count allows. The kernel bounds what it can take and how long it can hold funds.
- **Properties are proven, not sampled.** A chip is a pure function of a few hundred bits, so a solver can check a property for every state and every input.
- **Every epoch can be replayed.** `step` is a free read call. Anyone can feed it the recorded state and inputs and compare the recorded outputs, without a wallet.

## Status

Updated as each part lands. Nothing below is claimed until it is marked done.

| Part | State |
|---|---|
| Chip interface v1 (`chips/INTERFACE.md`) | Frozen |
| Reference model and golden vectors (`chips/golden/`) | Done |
| IGNIX fork probes (`contracts/probes/`): 112 fork tests of how the live Directed vault, curve and graduation treat a contract recipient | Done; findings in `contracts/probes/FINDINGS.md` |
| Circuit reader (`packages/`, `web/`): reads any TapeOut circuit from X Layer, draws it, runs a beat in the browser and checks it against the chain | Working; no kernel pages yet |
| Chip toolchain (`chips/tools/tapc`): Verilog to NAND and LATCH records, TAP-20 packer and simulator, proofs by Yosys SAT and z3, differential test against a chain | Done; 96 tests |
| Probe circuit (`chips/probe`): 118 gates, proven on every state and input | Built; not taped out yet |
| Flagship chip, the Flow Governor (`chips/rtl`, `chips/model`, `chips/props`): 1,889 NAND + 64 LATCH, 98 properties proven for every state and input | Built and proven; constants under review, will be rebuilt before tape-out |
| Keeper and paid compile endpoint (`services/`) | Built and tested; not deployed |
| Issuance contracts (processor creator and payees) | In progress |
| Kernel v1, sealed evaluator, Fab | In progress |
| Mainnet deployments | None yet |

Adoption today is zero.

## The interface

`chips/INTERFACE.md` is the contract between the kernel, the chips, the tools and the dashboard:

- chip shape: 96 inputs, 112 outputs, 1 to 256 latches, NAND and LATCH records only, at most 3,400 gates;
- amounts reach a chip as a 10-bit log code in steps of 1/8 octave; shares come back as 1/256ths and are applied to exact amounts;
- the input and output word layouts, the envelope of limits, and the routing rules with their clamp bits.

All arithmetic is defined by `chips/golden/kernel_model.py`. Solidity, Python and TypeScript implementations must match `chips/golden/vectors.json` bit for bit.

```
python3 chips/golden/kernel_model.py     # self-check
python3 chips/golden/gen_vectors.py      # rewrites vectors.json; the file must not change
```

Python 3.12 is the tested version.

## Layout

```
chips/        INTERFACE.md, golden/ (reference model and vectors), chip sources and tools
contracts/    Solidity (Foundry); vendor/ holds the verified TapeOut and IGNIX sources used as references
packages/     TypeScript libraries (TAP-20 simulator, chain access, die-shot renderer)
web/          dashboard
services/     keeper and compile endpoint
docs/         prior art, third-party notices, team wallets
```

## Trust

- Nothing on the tax path has an owner, an upgrade path or a pause.
- TapeOut's factory is not sealed: its owner, a 3-of-5 Safe, can upgrade processor logic. The kernel therefore carries a sealed evaluator, a Solidity port of the same one-beat semantics over a netlist snapshot, and uses it whenever the TapeOut implementation or the stored netlist differs from the values pinned at kernel creation.
- IgnixManager is upgradeable by its owner.
- The keeper only provides liveness: anyone can call `settle()`.
- Unaudited.

## Team wallets and trading

Every team wallet is listed in `docs/WALLETS.md`. No team wallet buys, sells or swaps any IGNIX token, sends funds into a kernel, or trades transistors.

## Prior art and third-party code

`docs/PRIOR_ART.md` credits the entries we studied and states where Covenant differs. No code from another entry is used. `docs/THIRD_PARTY.md` lists the vendored and reused sources.

## Licence

MIT. Vendored sources keep their own notices.
