# Covenant

**Your token's tax, routed by a chip anyone can read and nobody can change.**

Covenant is an entry to the TapeOut Genesis Transistor Hackathon (organiser: IGNIX; chain: X Layer, id 196).

- Site, no wallet needed: https://oojae.github.io/covenant/ (built from `main`). A mirror on TapeOut's DeWEB is served from probe circuit 1's container: https://1-2-283.tapekit.org/. The mirror is a fixed snapshot of commit `a97b90a`, published before kernel v2 was deployed, so it shows kernel v1 only. Its judge guide also still says every team wallet is listed in the on-chain TeamRegistry; the registry lists only the deployer so far (see [Team wallets and trading](#team-wallets-and-trading)).
- Judge guide, eight checks you can run in the page or in a terminal: https://oojae.github.io/covenant/#/judge
- The flagship kernel (v1, OKB quote): https://oojae.github.io/covenant/#/k/0xB722a4bDE4EfEe08Be938E2103d7a44C498dd356
- The v2 kernel (USD₮0 quote): https://oojae.github.io/covenant/#/k/0xd50A7cb21f4ef91f795730Fe8c45EaA5E500dD75
- Every deployed address, read back from the chain: [`deployments/xlayer.json`](deployments/xlayer.json)

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
- **Properties are proven, not sampled.** A chip is a pure function of a few hundred bits, so a solver can check a property for every state and every input. (For the Flow Governor, 96 of its 98 results are such solver checks. The other two are a reachability witness and a lifetime-cap argument backed by 200,000 random settles: `chips/out/fg.proofs.json`.)
- **Every epoch can be replayed.** `step` is a free read call. Anyone can feed it the recorded state and inputs and compare the recorded outputs, without a wallet.

## Live on X Layer

| What | Address or id |
|---|---|
| Processor `Covenant` / `CVNT` (circuits, ERC-721) | `0xaC90A95bd11eb67A2dD83Ab7ecc0Ea9B521dEF0b` |
| Its transistors (ERC-1155) | `0xC372dc307eFE4B551c866A79F582D692A373960A` |
| Splitter, the processor's creator and only payee | `0xB87101F7426BA9175E0a944d3e763dC69B19867f` |
| KeeperTank (85% of mint proceeds, paid in by `Splitter.pull()`) | `0xb89BCe53822a99503A937C22974F1224D9Ab6352` |
| TeamRegistry | `0x7d1799Ec41b1Eb42Fd0D3f8Dc5326bc4c7c18699` |
| SealedVM (fallback evaluator) | `0x19C248cF463c1E167121e52b77abA7EC68CBE47B` |
| Fab (the way a kernel-eligible chip is taped out) | `0xdCAc8c47aF534dC0cDE30f60056bCe7D63a79aFE` |
| **Kernel v1** (OKB quote): KernelFactory | `0xAAA75144304cF81Cc7cf513F434E00980d1803ad` |
| Kernel implementation | `0x72e6EbdB444831c9511c6D1DBF07A7f68993EDF1` |
| Lens (replay, audit, counterfactual, shadow runs) | `0xEe63Eb34f4B7A16A188d3D14075b9bB6A8aA5ea2` |
| The v1 kernel: chip 2, allowance payee the KeeperTank | `0xB722a4bDE4EfEe08Be938E2103d7a44C498dd356` |
| **Kernel v2** (USD₮0 quote, shift 33 bits): KernelFactoryV2 | `0x231c0174ebb69789813f6ecb625b4626e69a82c1` |
| KernelV2 implementation | `0x0d75d4c11e4770257b2bbf2d1E0Cb78f5B50CAd5` |
| LensV2 | `0x3ebe9e9cbc67d6a008c55d20294357521d28b049` |
| The v2 kernel: chip 5, allowance payee the Architect's agent wallet `0xbe50…6da0` (a team wallet) | `0xd50A7cb21f4ef91f795730Fe8c45EaA5E500dD75` |
| Circuit 1: probe, 118 gates | held by the deployer |
| Circuit 2: **Flow Governor**, 1,888 NAND + 64 LATCH | held by the v1 kernel `0xB722…d356` |
| Circuit 5: the Flow Governor again, the same netlist bytes as circuit 2 | held by the v2 kernel `0xd50A…dD75` |
| Circuits 3 and 4: hostile demo chips (Glutton, Glutton512) | held by the deployer, never bound to a kernel |
| Covenant Architect, paid compile endpoint (x402, 0.50 USD₮0, paid to the agent wallet) | `https://architect-production-ffbe.up.railway.app/v1/architect/chip`; OKX.AI agent #14683, submitted for review on 2026-10-06 |
| Site mirror on TapeOut's DeWEB (`1.2.283.tape`, snapshot of commit `a97b90a`) | container `0x911350102b2D81a1E8A816638D429a16b80B8Ee2`, https://1-2-283.tapekit.org/ |

No token has been launched on either kernel yet. Both kernels hold their chips and wait, unbound (`token()` is the zero address); their pages say so. The v1 kernel waits for the reference token, `CVREF` (Covenant Reference); the v2 kernel waits for a token quoted in USD₮0.

The KeeperTank holds 0 OKB today: nobody has called `Splitter.pull()` yet. TapeOut owes the Splitter 0.085 OKB for the 4,250 transistors minted so far; a `pull()` would send 0.07225 OKB to the tank and 0.01275 OKB to the maintainer. Until then a settle through the tank runs but refunds nothing.

## Check it yourself

No wallet; each line is a free read call.

```sh
RPC=https://rpc.xlayer.tech
CIRCUITS=0xaC90A95bd11eb67A2dD83Ab7ecc0Ea9B521dEF0b

# 1. Covenant is a processor of TapeOut's factory
cast call 0x1f09DAeFA827f02CBb40967cc91b259763760761 "isCPU(address)(bool)" $CIRCUITS --rpc-url $RPC

# 2. The chip is not decorative: one input word, two latch states the chip can reach, two different routes
X=0x39a906000099010000100000
cast call $CIRCUITS "step(uint256,bytes,bytes)(bytes,bytes)" 2 0x18e1040906000001 $X --rpc-url $RPC
#   -> 0x0ce1440905004001 0xa0008000020000008002604b060b   CRUISE: buy 160/256, allowance 32, reserve 64
cast call $CIRCUITS "step(uint256,bytes,bytes)(bytes,bytes)" 2 0x00e1840904008001 $X --rpc-url $RPC
#   -> 0xf4e0c40bc300c101 0x00010000000000008022605b0e11   DEFEND: buy 256/256, release 34

# 3. The kernel holds the chip, and both evaluators run it within the gas a settle gives them
cast call $CIRCUITS "ownerOf(uint256)(address)" 2 --rpc-url $RPC
cast call 0xEe63Eb34f4B7A16A188d3D14075b9bB6A8aA5ea2 \
  "preflight(address)((bool,bool,bool,bool,uint256,uint256,uint256,uint256,uint256))" \
  0xB722a4bDE4EfEe08Be938E2103d7a44C498dd356 --rpc-url $RPC

# 4. Kernel v2: its kernel holds chip 5 (same netlist keccak as chip 2), its factory pins USD₮0 and a 33-bit shift,
#    and both evaluators run the chip within the gas a v2 settle gives them
cast call $CIRCUITS "ownerOf(uint256)(address)" 5 --rpc-url $RPC
cast call $CIRCUITS "netlist(uint256)(bytes)" 5 --rpc-url $RPC | cast keccak    # 0xe548…43b4, as for chip 2
cast call 0x231c0174ebb69789813f6ecb625b4626e69a82c1 "quoteShift()(uint256)" --rpc-url $RPC
cast call 0x3ebe9e9cbc67d6a008c55d20294357521d28b049 \
  "preflight(address)((bool,bool,bool,bool,uint256,uint256,uint256,uint256,uint256))" \
  0xd50A7cb21f4ef91f795730Fe8c45EaA5E500dD75 --rpc-url $RPC
```

The two states come from `chips/out/fg.witness.json`. Both were reached from a cold start by input words the kernel itself would assemble, so neither is made up. The judge guide runs the same calls in the page and checks them against a simulation of the netlist in the browser.

To check that the deployed bytecode is this repository's source, run `deploy/verify-bytecode.sh` (it builds each package at the commit `deployments/xlayer.json` records and compares it with the chain; read-only). What it covers and its latest recorded result are in [docs/VERIFY.md](docs/VERIFY.md).

## Asset issuance

The processor's five parameters are immutable from its first block:

| Field | Value |
|---|---|
| Name, symbol | `Covenant`, `CVNT` |
| Supply | 67,108,864 transistors (2^26); NAND and LATCH share the cap |
| Price | 0.00002 OKB each, fixed; TapeOut's own fees are extra |
| Creator and payee | the Splitter contract, never a team wallet |

The Splitter is the only address TapeOut pays. Anyone can call `pull()`. It splits everything **85% to the KeeperTank** and **15% to the maintainer** (the deployer), and no key can change the payees or shares. The KeeperTank refunds the gas of each chip's settlements up to that chip's allowance: 85% of the mint price of the transistors the chip burned. So a vault's transistors prepay its own upkeep, once someone has called `pull()` (nobody has yet; see above). The processor's on-chain story states all of this, the addresses and the source commit, and the Splitter reverts unless the story on-chain is exactly that text. No presale, no team allocation, no per-wallet cap.

## Status

Nothing below is claimed until it is marked done. Adoption today is zero.

| Part | State |
|---|---|
| Chip interface, revision 2 (`chips/INTERFACE.md`), reference model and golden vectors (`chips/golden/`) | Done |
| IGNIX fork probes (`contracts/probes/`): how the live Directed vault, curve and graduation treat a contract recipient, with native OKB and with a USD₮0 quote | Done; 129 tests in 14 suites; findings in `contracts/probes/FINDINGS.md` |
| Chip toolchain (`chips/tools/tapc`): Verilog to NAND and LATCH records, TAP-20 packer and simulator, proofs by Yosys SAT and z3 on the netlist bytes | Done |
| Flow Governor (`chips/rtl`, `chips/model`, `chips/props`): netlist proven equal to the RTL (two-sided) and to the Python model, 65 properties proven for every state and input (98 results; one lifetime-cap property by argument plus 200,000 random settles, one a reachability witness), ten broken mutants each caught | Live: circuit 2, held by the v1 kernel; circuit 5 (the same bytes), held by the v2 kernel |
| Issuance contracts (`contracts/issuance`): Splitter, KeeperTank, TeamRegistry | Live; 264 tests (204 offline, 60 on an X Layer fork) |
| Sealed evaluator and Fab (`contracts/evaluator`) | Live; 157 tests (100 hermetic, 57 on an X Layer fork) |
| Kernel v1, KernelFactory, Lens (`contracts/core`) | Live; 309 tests (280 offline, 29 fork tests against the live IGNIX and TapeOut contracts). Unbound: no token launched yet |
| Kernel v2, USD₮0 quote (`contracts/core-v2`, [chips/INTERFACE-V2.md](chips/INTERFACE-V2.md)): x402 revenue paid to the kernel is routed by the chip as tax on the curve; after graduation the chip does not see it and a fixed rule buys the token with it and sends it to 0xdEaD | Live since 2026-10-06: KernelFactoryV2, LensV2, and the v2 kernel holding chip 5, unbound (no token launched yet). 189 tests (166 offline, 23 fork tests on live IGNIX with a USD₮0-quoted token), 8,808 recorded settles compared bit for bit with the Python model (8,940 more on a second seed), two internal reviews, not an audit, that found no defect in the kernel code; each finding was addressed (`contracts/core-v2/NOTES.md` section 10). The Architect's revenue is not pointed at it: `PAY_TO` stays on the agent wallet until IGNIX confirms in writing that revenue-funded contract buys are allowed and the OKX.AI review is finished |
| Site (`web/`, `packages/`): chip demo, vault, epoch audit, hostile chip, judge guide, trust model | Live on GitHub Pages, both kernels listed; the kernel pages fill in once a token is bound and settles. The DeWEB mirror is the snapshot of commit `a97b90a` (kernel v1 only) |
| Covenant Architect (`services/architect`): compile endpoint, free route and x402 paid route | Live (Railway, commit `8678740`, live x402 mode, `PAY_TO` the agent wallet); 91 tests (3 of them opt-in against the real toolchain); OKX.AI agent 14683 submitted for review |
| Launch check and team audit (`tools/`) | Done; the team audit was CLEAN at block 72,550,443, after the kernel v2 deployment |
| Reference token `CVREF`, the v2 kernel's token, and the keeper (`services/keeper`, 109 tests) | Not launched; the keeper is not deployed and its wallet has sent no transaction |
| Reproducible-build check (`deploy/verify-bytecode.sh`, [docs/VERIFY.md](docs/VERIFY.md)): each Covenant contract rebuilt at its recorded commit and compared with chain 196 | Done; what it covers and the latest result: [docs/VERIFY.md](docs/VERIFY.md). No source published on OKLink yet |
| Kit for outside chip authors (`chips/kit`, [docs/BUILD_YOUR_CHIP.md](docs/BUILD_YOUR_CHIP.md)): template to proven netlist to the exact tape-out and kernel commands (kernel v1), with a 180-gate Starter chip | Done; tested end to end on a fork |

## The interface

`chips/INTERFACE.md` is the contract between the kernel, the chips, the tools and the dashboard:

- chip shape: 96 inputs, 112 outputs, 1 to 256 latches, NAND and LATCH records only, at most 3,400 gates;
- amounts reach a chip as a 10-bit log code in steps of 1/8 octave; shares come back as 1/256ths and are applied to exact amounts;
- the input and output word layouts, the envelope of limits, and the routing rules with their clamp bits.

All arithmetic is defined by `chips/golden/kernel_model.py`. Solidity, Python and TypeScript implementations must match `chips/golden/vectors.json` bit for bit. What kernel v2 changes (the USD₮0 quote and its 33-bit code shift) is in `chips/INTERFACE-V2.md`, with its own model (`kernel_model_v2.py`) and vectors (`vectors_v2.json`).

```
python3 chips/golden/kernel_model.py     # self-check
python3 chips/golden/gen_vectors.py      # rewrites vectors.json; the file must not change
```

Python 3.12 is the tested version.

## Layout

```
chips/        INTERFACE.md, golden/ (reference model and vectors), chip sources, proofs and tools
contracts/    Solidity (Foundry): issuance, evaluator, core (kernel v1), core-v2 (kernel v2), probes; broadcast/ holds the real deployment records
deploy/       the signing wrappers (rehearse on a fork, then send step by step) and the rehearsal
deployments/  xlayer.json: every deployed address and transaction, read back from the chain
packages/     TypeScript libraries (TAP-20 simulator, chain access, die-shot renderer)
web/          the site
services/     keeper and the Architect compile endpoint
tools/        launch-check (checks the token launch transaction before it is signed), audit-team
docs/         team wallets, checking the deployed code (VERIFY.md), building a chip (BUILD_YOUR_CHIP.md), prior art, third-party notices, assets
```

## Trust

- No Covenant contract on the tax path (kernels, kernel factories, Lenses, Fab, SealedVM, KeeperTank, Splitter) has an owner, an upgrade path or a pause. The platforms and the asset it runs on do:
- TapeOut's factory is not sealed: its owner, a 3-of-5 Safe, can upgrade processor logic. The kernel factory pins the TapeOut circuit implementation and its code hash. Whenever the beacon no longer points there, or TapeOut's `step` fails, a kernel uses the sealed evaluator: a Solidity port of the same one-beat semantics over the netlist snapshot the Fab stored at tape-out.
- IgnixManager is upgradeable by its owner, a 1-of-2 Safe.
- Kernel v2 holds USD₮0. Its owner (`0x4DFF…0bf8`, a 3-of-5 Safe) can block a kernel's address, destroy a blocked kernel's USD₮0 and upgrade the token.
- The allowance payee of the v2 kernel is the Covenant Architect's agent wallet, a team wallet: within that kernel's envelope it can receive at most 18.75% of the inflow on the curve (at most 3.932160 USD₮0 per settle), as a pull credit, and nothing after graduation. The v1 kernel's allowance payee is the KeeperTank.
- The keeper only provides liveness: anyone can call `settle()`.
- Unaudited.

## Team wallets and trading

Every team wallet is listed in `docs/WALLETS.md`: the deployer, the keeper and the Covenant Architect's agent wallet. The on-chain TeamRegistry lists the deployer (entry 0); the keeper has been invited and has not declared itself yet, and the Architect wallet has not been invited yet. No team wallet buys, sells or swaps any IGNIX token, sends funds into a kernel, or trades transistors (the Architect wallet receives x402 payments and is the v2 kernel's allowance payee; both are payments to it). `tools/audit-team` lists every transaction those wallets have sent and checks it against those rules, with no explorer in between; on 2026-10-06 at block 72,550,443 it found 37 deployer transactions, 1 user operation of the Architect wallet, none from the keeper, and no rule broken.

## Prior art and third-party code

`docs/PRIOR_ART.md` credits the entries we studied and states where Covenant differs. No code from another entry is used. `docs/THIRD_PARTY.md` lists the vendored and reused sources.

## Licence

MIT. Vendored sources keep their own notices.
