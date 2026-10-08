# Covenant

**Your token's tax, routed by a chip anyone can read and nobody can change.**

Covenant is an entry to the TapeOut Genesis Transistor Hackathon (IGNIX × X Layer × TapeOut; chain: X Layer, id 196).

An IGNIX token sends its trading tax to a kernel, a contract with no owner. Once per 15-minute epoch anyone can call `settle()`. The kernel asks one taped-out TapeOut circuit, the token's chip, how to split the tax, and carries out that split inside limits fixed when the kernel was created.

**Status: live on X Layer, unaudited, adoption zero.** The only tokens bound to Covenant's kernels are the two the team launched itself. Nobody has bought either, so every settle so far has routed 0 (details under the table).

| What | Where |
|---|---|
| Site, no wallet needed | https://oojae.github.io/covenant/ |
| Judge guide: eight checks, about five minutes, in the page or in a terminal | https://oojae.github.io/covenant/#/judge |
| Demo film, 2 min 20 s | https://github.com/OoJae/covenant/releases/tag/demo-2026-10-08 (GitHub serves release files as downloads, not in a player: [720p, 26 MB](https://github.com/OoJae/covenant/releases/download/demo-2026-10-08/covenant-demo-720p.mp4), [1080p60, 220 MB](https://github.com/OoJae/covenant/releases/download/demo-2026-10-08/covenant-demo-1080p60.mp4)) |
| Copy of the site stored on X Layer (TapeOut DeWEB) | https://1-2-283.tapekit.org/ |
| Processor `Covenant` / `CVNT`, TapeOut processor #283 | [`0xaC90A95bd11eb67A2dD83Ab7ecc0Ea9B521dEF0b`](https://www.oklink.com/x-layer/evm/address/0xaC90A95bd11eb67A2dD83Ab7ecc0Ea9B521dEF0b) |
| Deployment wallet | [`0x84cE7bAe1b788C7aD985D57721cA428b401aE34D`](https://www.oklink.com/x-layer/evm/address/0x84cE7bAe1b788C7aD985D57721cA428b401aE34D) |
| Chips (circuit ids on the processor) | 2 and 5: the Flow Governor, 1,888 NAND + 64 latches, one held by each kernel. 1, 3 and 4: a probe and two hostile demo chips. Tape-out transactions below |
| Kernel v1: token `CVREF`, quoted in OKB, chip 2 | `0xB722a4bDE4EfEe08Be938E2103d7a44C498dd356` ([vault page](https://oojae.github.io/covenant/#/k/0xB722a4bDE4EfEe08Be938E2103d7a44C498dd356)) |
| Kernel v2: token `ARCH`, quoted in USD₮0, chip 5 | `0xd50A7cb21f4ef91f795730Fe8c45EaA5E500dD75` ([vault page](https://oojae.github.io/covenant/#/k/0xd50A7cb21f4ef91f795730Fe8c45EaA5E500dD75)) |
| Covenant Architect: compiles a vault chip from a preset. A free route, and a paid route at 0.50 USD₮0 by x402 (OKX.AI agent #14683, in review) | `https://architect-production-ffbe.up.railway.app` ([how to call it](#try-it)) |
| Every deployed address and transaction, read back from the chain | [`deployments/xlayer.json`](deployments/xlayer.json) |

**Check it in five minutes, no wallet.** Open the [judge guide](https://oojae.github.io/covenant/#/judge) and press "Run the eight checks": each check reads X Layer from your browser and shows the terminal command that asks the same question. Or paste the block under [Check it yourself](#check-it-yourself). To go further (compile a chip, settle a kernel yourself, see where a trade's tax would go), see [Try it](#try-it). Who can still change what is under [Trust](#trust).

**Where it stands (2026-10-08, 09:32 UTC, block 72,682,896).** Unaudited. Adoption is zero: `CVREF` and `ARCH` are the team's own tokens, launched with first buy 0, and no team wallet buys, sells or holds either. Nobody else has bought them: IGNIX's curve has sold none of either (`sold` is 0 for both in `IgnixManager.tokens`, and the manager still holds the whole supply). So no tax has arrived. Kernel v1 had recorded 136 settles and kernel v2 137, one in every epoch since the keeper's first settles at 23:35 UTC on 2026-10-06. Every one has inflow 0 and no flag, and the chip's mode after each is IDLE. What the chip does with real tax is shown by the two `step` calls under [Check it yourself](#check-it-yourself), by the proofs and by the fork tests, not by live flows.

The processor was created by the Splitter's deployment transaction [`0x9b4c9a6c…95d5479f`](https://www.oklink.com/x-layer/evm/tx/0x9b4c9a6ccb5553318f4deff26f037b8830acb047e06069fa539fbe9795d5479f) (block 72,519,781, 2026-10-06). The deployment wallet taped out its five circuits the same day:

| Circuit | What it is | Held by | Tape-out transaction |
|---|---|---|---|
| 1 | Probe, 118 gates. Its container stores the copy of the site | the deployer | [`0x9e75ed66…9ce572fa`](https://www.oklink.com/x-layer/evm/tx/0x9e75ed66ef52052282da8682644815fc1457768b02eeb6edb77c9ac39ce572fa) |
| 2 | **Flow Governor**, 1,888 NAND + 64 LATCH | kernel v1 `0xB722…d356` | [`0xd431a326…33a5774e`](https://www.oklink.com/x-layer/evm/tx/0xd431a326622b5602622528856298e970800bbcfe16935086496ee23033a5774e) |
| 3 | Glutton, a hostile demo chip | the deployer; never bound to a kernel | [`0x968c8030…95ca3c36`](https://www.oklink.com/x-layer/evm/tx/0x968c8030932d59878b0773dc81a5ffadc24d851d09c9e8def1ae5a0a95ca3c36) |
| 4 | Glutton512, a hostile demo chip | the deployer; never bound to a kernel | [`0xf8a6f70d…ada55588`](https://www.oklink.com/x-layer/evm/tx/0xf8a6f70dae0c8cd419db727679cf836d8c38153a9cb97f6dcb8426f9ada55588) |
| 5 | The Flow Governor again, the same netlist bytes as circuit 2 | kernel v2 `0xd50A…dD75` | [`0xc4f91690…2245ffef`](https://www.oklink.com/x-layer/evm/tx/0xc4f91690e8240afa7e0c765bdaec348e6d0e4649a565d2d1812ec55d2245ffef) |

The site is built from `main` by the Pages workflow. The copy on X Layer is served from probe circuit 1's container through TapeOut's gateway. It needs a browser (a service worker reads every file from the chain, so `curl` gets only the gateway's loader page) and took about 15 seconds to show its first page when measured on 2026-10-08. It is a fixed snapshot of commit `09b9178`, published on 2026-10-07: the same site as GitHub Pages at that commit, with both kernels. Its name `1.2.283.tape` is paid until 2026-11-05 18:30 UTC; after that the gateway stops serving it until the name is renewed, and the files stay on chain (`tools/deweb/NOTES.md`). `node tools/deweb/verify.ts --site 1-2-283` checks it against a local build (run `pnpm --filter web build` first, or pass `--no-local`), a second RPC node and the gateway.

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

- **A stranger's logic runs inside fixed bounds.** A chip cannot call another contract, write storage or use more gas than its gate count allows. The kernel bounds what it can take and how long it can hold funds.
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
| Covenant Architect, paid compile endpoint (x402, 0.50 USD₮0, paid to the agent wallet) | `https://architect-production-ffbe.up.railway.app/v1/architect/chip`; OKX.AI agent #14683, submitted for review on 2026-10-06 |
| Site mirror on TapeOut's DeWEB (`1.2.283.tape`, snapshot of commit `09b9178`) | container `0x911350102b2D81a1E8A816638D429a16b80B8Ee2`, https://1-2-283.tapekit.org/ |

The processor's five circuits, their holders and their tape-out transactions are in the table at the top.

Both tokens were launched on 2026-10-06 by the deployer with first buy 0, each checked with `tools/launch-check` and simulated on a fork from the exact transaction before it was signed, and bound to their kernels the same night:

| Token | Address | Quote | Kernel |
|---|---|---|---|
| Covenant Reference, `CVREF` | `0xc562E9b465E0Fa8d403Ed603cb8783342347EEEE` | OKB | v1 `0xB722a4bDE4EfEe08Be938E2103d7a44C498dd356` (chip 2) |
| Covenant Architect, `ARCH` | `0x7F53a5906F0C5Cd21C124f1Cc2a1A5BD9817EEEE` | USD₮0 | v2 `0xd50A7cb21f4ef91f795730Fe8c45EaA5E500dD75` (chip 5) |

No team wallet holds or trades either token. Flows are whatever outside traders bring, and so far that is nothing: on 2026-10-08 (09:32 UTC) IGNIX's curve had sold none of either token, both tax vaults were empty, and every recorded settle (136 on kernel v1, 137 on kernel v2) had inflow 0.

`Splitter.pull()` was called on 2026-10-06 (block 72,559,111, tx `0xbf9a9253…fa5e`): it sent 0.07225 OKB to the KeeperTank and 0.01275 OKB to the maintainer, for the 4,250 transistors minted. The tank has refunded the keeper's settles since, about 0.0001 OKB each (4.8 million gas at 0.021 gwei).

A chip's refunds stop at its allowance: 0.033184 OKB for each Flow Governor (1,952 transistors × 0.00002 OKB × 85%), about 328 settles at that cost, 3.4 days at one settle per epoch. On 2026-10-08 (09:32 UTC) the tank held 0.0446 OKB, and chips 2 and 5 had 0.0194 and 0.0193 OKB of allowance left: about 190 more refunded settles each, so the refunds run out around 09:00 UTC on 2026-10-10 unless someone adds to a chip's allowance with `KeeperTank.topUp(chipId)` (anyone may). After that the keeper pays its own gas from its wallet, which held 0.0310 OKB that day: about 150 more epochs for both kernels, to late on 2026-10-11 (UTC) at that gas price. If the keeper stops, nothing is lost on chain: anyone can still call `settle()`, and tax waits in the token's vault until someone does. This reads what is left for chip 2 (use 5 for kernel v2):

```sh
cast call 0xb89BCe53822a99503A937C22974F1224D9Ab6352 "remainingOf(uint256)(uint256)" 2 --rpc-url https://rpc.xlayer.tech
```

## Check it yourself

No wallet; each line is a free read call. You need Foundry's `cast` ([getfoundry.sh](https://getfoundry.sh)); with cast 1.8.3 the whole block takes under a minute over the public RPC. It pastes as it is into bash and into zsh: its first line lets macOS's default zsh accept the `#` lines.

```sh
setopt interactivecomments 2>/dev/null || true
RPC=https://rpc.xlayer.tech
CIRCUITS=0xaC90A95bd11eb67A2dD83Ab7ecc0Ea9B521dEF0b

# 1. Covenant is a processor of the TapeOut factory: prints true
cast call 0x1f09DAeFA827f02CBb40967cc91b259763760761 "isCPU(address)(bool)" $CIRCUITS --rpc-url $RPC

# 2. The chip is not decorative: one input word, two latch states the chip can reach, two different routes
X=0x39a906000099010000100000
cast call $CIRCUITS "step(uint256,bytes,bytes)(bytes,bytes)" 2 0x18e1040906000001 $X --rpc-url $RPC
#   prints 0x0ce1440905004001 0xa0008000020000008002604b060b   CRUISE: buy 160/256, allowance 32, reserve 64
cast call $CIRCUITS "step(uint256,bytes,bytes)(bytes,bytes)" 2 0x00e1840904008001 $X --rpc-url $RPC
#   prints 0xf4e0c40bc300c101 0x00010000000000008022605b0e11   DEFEND: buy 256/256, release 34

# 3. The kernel holds the chip, and both evaluators run it within the gas a settle gives them
cast call $CIRCUITS "ownerOf(uint256)(address)" 2 --rpc-url $RPC
cast call 0xEe63Eb34f4B7A16A188d3D14075b9bB6A8aA5ea2 \
  "preflight(address)((bool,bool,bool,bool,uint256,uint256,uint256,uint256,uint256))" \
  0xB722a4bDE4EfEe08Be938E2103d7a44C498dd356 --rpc-url $RPC
#   prints 0xB722a4bDE4EfEe08Be938E2103d7a44C498dd356, then a tuple that starts false, true, true, true

# 4. Kernel v2: its kernel holds chip 5, the same netlist keccak as chip 2. Its factory pins USD₮0 and a 33-bit shift,
#    and both evaluators run the chip within the gas a v2 settle gives them
cast call $CIRCUITS "ownerOf(uint256)(address)" 5 --rpc-url $RPC
cast call $CIRCUITS "netlist(uint256)(bytes)" 5 --rpc-url $RPC | cast keccak
cast call 0x231c0174ebb69789813f6ecb625b4626e69a82c1 "quoteShift()(uint256)" --rpc-url $RPC
cast call 0x3ebe9e9cbc67d6a008c55d20294357521d28b049 \
  "preflight(address)((bool,bool,bool,bool,uint256,uint256,uint256,uint256,uint256))" \
  0xd50A7cb21f4ef91f795730Fe8c45EaA5E500dD75 --rpc-url $RPC
#   prints 0xd50A7cb21f4ef91f795730Fe8c45EaA5E500dD75, the keccak 0xe548…43b4, 33, then a tuple that starts false, true, true, true
```

Each `preflight` tuple is `sealedModeNow, tapeoutRan, sealedRan, agree`, then five gas figures. The leading `false` is not a failure: it says the next settle does not start on the sealed evaluator. The three `true` say TapeOut's step ran, the sealed step ran, and the two agree.

Without Foundry, check 1 is one JSON-RPC call. Its result ends in `1` (true):

```sh
curl -s -X POST https://rpc.xlayer.tech -H 'content-type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":"0x1f09DAeFA827f02CBb40967cc91b259763760761","data":"0x5f5a364f000000000000000000000000aC90A95bd11eb67A2dD83Ab7ecc0Ea9B521dEF0b"},"latest"]}'
```

The two states come from `chips/out/fg.witness.json`. Both were reached from a cold start by input words the kernel itself would assemble, so neither is made up. The judge guide runs the same calls in the page and checks them against a simulation of the netlist in the browser.

To check that the deployed bytecode is this repository's source, run `deploy/verify-bytecode.sh` (it builds each package at the commit `deployments/xlayer.json` records and compares it with the chain; read-only). What it covers and its latest recorded result are in [docs/VERIFY.md](docs/VERIFY.md).

## Try it

Everything here works without the team, and the team's wallets do none of it: no team wallet buys, sells or swaps an IGNIX token, sends funds into a kernel or pays the Architect.

**Compile a chip, free.** The Covenant Architect compiles a vault chip from a preset:

```sh
curl -s -X POST https://architect-production-ffbe.up.railway.app/v1/architect/compile \
  -H 'Content-Type: application/json' -d '{"preset":"flow-governor","params":{}}' | jq -r .manifest.keccak256
```

The answer has `netlistHex`, `manifest`, `proofs` and `cost`; the `jq` filter prints one field of it (drop the pipe to see everything, about 76 kB). For this stock request `manifest.keccak256` is `0xe548…43b4`, the netlist of chips 2 and 5 (answered in under 2 seconds on 2026-10-08). The free route allows 10 requests a minute per IP address. `/v1/architect/chip` is the same compile behind an x402 payment of 0.50 USD₮0, paid to the agent wallet. On 2026-10-08 that wallet held 0 USD₮0.

**Settle a kernel yourself.** Anyone may call `settle()`, once per epoch. The keeper usually gets there first: over the 40 settles of each kernel before 09:32 UTC on 2026-10-08 it landed 3 to 33 seconds after the epoch began (median 21 s), and a second settle in the same epoch reverts with `EpochNotElapsed()`. So a call of yours succeeds only if it is the first of its epoch, for example when the keeper has stopped. Sent through the tank, the caller's gas is refunded while the chip's allowance lasts:

```sh
cast send 0xb89BCe53822a99503A937C22974F1224D9Ab6352 "settleAndRefund(address)" 0xB722a4bDE4EfEe08Be938E2103d7a44C498dd356 \
  --rpc-url https://rpc.xlayer.tech --account YOUR_KEYSTORE_NAME
```

This is the only command in this README that sends a transaction; it needs a wallet of yours with a little OKB. A settle of the Flow Governor used about 4.8 million gas on 2026-10-08, about 0.0001 OKB at 0.021 gwei. The transaction has to carry a larger gas limit than it uses: `eth_estimateGas` answered 10.7 million for this call (simulated at an epoch boundary from an address that holds nothing; not sent). `settle()` sent to the kernel directly does the same without the refund. The v2 kernel is `0xd50A7cb21f4ef91f795730Fe8c45EaA5E500dD75`.

**See a settle that routes tax.** Every settle recorded so far is idle: no tax has arrived, because nobody outside the team has traded `CVREF` or `ARCH`, and the team's wallets never do. Both tokens are on IGNIX's bonding curve, where anyone else can trade them: [CVREF](https://ignix.bot/launch?token=0xc562E9b465E0Fa8d403Ed603cb8783342347EEEE) against OKB and [ARCH](https://ignix.bot/launch?token=0x7F53a5906F0C5Cd21C124f1Cc2a1A5BD9817EEEE) against USD₮0, each with a 3% tax on buys and on sells (`taxBuyBps` and `taxSellBps` are 300 in `IgnixManager.tokens`). IGNIX's page lists the tax as "Creator 100%" through a Directed Vault. That vault's recipient is the kernel: the same page shows it under "Recipient address", and `RECIPIENT()` on the vault answers it. A trade's tax waits in the token's vault ("Tax waiting in the vault" on the vault page) until the next settle claims and routes it. That settle's row under "Every settle" then carries the amounts, and its number opens the audit of that settle. Trading costs real OKB or USD₮0 and IGNIX's own 1% fee, and these two tokens exist only to demonstrate the kernel. This describes the mechanism; it is not a suggestion to buy them.

**Bring your own chip and token.** [docs/BUILD_YOUR_CHIP.md](docs/BUILD_YOUR_CHIP.md): six `chips/kit/kit.sh` commands from a template to a proven netlist, a rehearsal on a local fork, and the transactions you would sign yourself (kernel v1).

## Run it from a clone

You need git (a full clone: `deploy/verify-bytecode.sh` reads older commits and stops on a shallow one), Node 26 with pnpm 11, Foundry 1.8 or later (`cast`, `forge`, `anvil`) and python3 (3.12 for the chip toolchain). `tools/deweb/verify.ts` also needs Chrome, Edge or Chromium. None of these commands needs a wallet or sends a transaction.

```sh
git clone https://github.com/OoJae/covenant
cd covenant
pnpm install
pnpm --filter web build
pnpm --filter web test:offline
pnpm --filter web verify:live
pnpm --filter web verify:kernel
deploy/verify-bytecode.sh
node tools/deweb/verify.ts --site 1-2-283
node tools/audit-team/audit-team.ts --deployment deployments/xlayer.json --quiet
```

What each one showed in one run on 2026-10-08, from a fresh clone on an arm64 Mac with Node 26.0.0, pnpm 11.1.2 and Foundry 1.8.3, over the public RPC:

| Command | Result | Time |
|---|---|---|
| `pnpm --filter web build` | typecheck, build into `web/dist`, size budget ok | 7 s |
| `pnpm --filter web test:offline` | 189 passed, 20 skipped (they need the network or a fork) | 3 s |
| `pnpm --filter web verify:live` | ALL MATCH: the site's simulator against `Circuits.step` on its example circuits | 12 s |
| `pnpm --filter web verify:kernel` | all MATCH: every settle record of both kernels (129 and 131 that morning), recomputed by the site's simulator and by the Lens on both evaluators | 6.5 min, about 1.5 s per record; each kernel gains 96 records a day |
| `pnpm --filter web verify:kernel --last 20` | all MATCH: the same check on record 1 and the last 20 records of each kernel | 69 s (a later run that day, in the working tree) |
| `deploy/verify-bytecode.sh` | 18 of 18 Covenant rows MATCH | 3 min; it clones forge-std and OpenZeppelin from GitHub |
| `node tools/deweb/verify.ts --site 1-2-283` | VERDICT: MATCH; it compares with `web/dist`, so build first | 2.5 min |
| `node tools/audit-team/audit-team.ts …` | VERDICT: CLEAN at block 72,678,434: 416 transactions and 2 user operations. Its 125 warnings were the DeWEB publish transactions, to three contracts the tool's address list has named since (see [Team wallets and trading](#team-wallets-and-trading)) | 24 min, and longer every day: it reads every block since 2026-10-06 in 100-block `eth_getLogs` chunks. A later run reuses the answers it has cached |

The contract suites install their pinned libraries first; the commands are in `contracts/issuance/README.md`, `contracts/evaluator/README.md`, `contracts/core/NOTES.md` and `contracts/core-v2/NOTES.md`. Offline, the same day, with the libraries already in place: core 280 passed (29 fork tests skipped), core-v2 166 passed (23 skipped), issuance 204, evaluator 100, each in about a minute. The chip proofs, `make -C chips/rtl prove && make -C chips/rtl mutants`, need the Python 3.12 venv `chips/.venv-fg` (`make -C chips/rtl venv` creates it and installs `yowasp-yosys` and `z3-solver`). With the venv in place they took about 90 seconds: 98 of 98 proved, ten mutants caught.

## Asset issuance

The processor's five parameters are immutable from its first block:

| Field | Value |
|---|---|
| Name, symbol | `Covenant`, `CVNT` |
| Supply | 67,108,864 transistors (2^26); NAND and LATCH share the cap |
| Price | 0.00002 OKB each, fixed; TapeOut's own fees are extra |
| Creator and payee | the Splitter contract, never a team wallet |

The Splitter is the only address TapeOut pays. Anyone can call `pull()`. It splits everything **85% to the KeeperTank** and **15% to the maintainer** (the deployer), and no key can change the payees or shares. The KeeperTank refunds the gas of each chip's settlements up to that chip's allowance: 85% of the mint price of the transistors the chip burned. So a vault's transistors prepay its own upkeep, once someone has called `pull()` (first called on 2026-10-06; see above). The processor's on-chain story states all of this, the addresses and the source commit, and the Splitter reverts unless the story on-chain is exactly that text. No presale, no team allocation, no per-wallet cap.

## Status

Nothing below is claimed until it is marked done. Adoption today is zero.

| Part | State |
|---|---|
| Chip interface, revision 2 (`chips/INTERFACE.md`), reference model and golden vectors (`chips/golden/`) | Done |
| IGNIX fork probes (`contracts/probes/`): how the live Directed vault, curve and graduation treat a contract recipient, with native OKB and with a USD₮0 quote | Done; 129 tests in 14 suites; findings in `contracts/probes/FINDINGS.md` |
| Chip toolchain (`chips/tools/tapc`): Verilog to NAND and LATCH records, TAP-02 (formerly TAP-20) packer and simulator, proofs by Yosys SAT and z3 on the netlist bytes | Done |
| Flow Governor (`chips/rtl`, `chips/model`, `chips/props`): netlist proven equal to the RTL (two-sided) and to the Python model, 65 properties proven for every state and input (98 results; one lifetime-cap property by argument plus 200,000 random settles, one a reachability witness), ten broken mutants each caught | Live: circuit 2, held by the v1 kernel; circuit 5 (the same bytes), held by the v2 kernel |
| Issuance contracts (`contracts/issuance`): Splitter, KeeperTank, TeamRegistry | Live; 264 tests (204 offline, 60 on an X Layer fork) |
| Sealed evaluator and Fab (`contracts/evaluator`) | Live; 157 tests (100 hermetic, 57 on an X Layer fork) |
| Kernel v1, KernelFactory, Lens (`contracts/core`) | Live; 309 tests (280 offline, 29 fork tests against the live IGNIX and TapeOut contracts). Bound to `CVREF` since 2026-10-06 |
| Kernel v2, USD₮0 quote (`contracts/core-v2`, [chips/INTERFACE-V2.md](chips/INTERFACE-V2.md)): x402 revenue paid to the kernel is routed by the chip as tax on the curve; after graduation the chip does not see it and a fixed rule buys the token with it and sends it to 0xdEaD | Live since 2026-10-06: KernelFactoryV2, LensV2, and the v2 kernel holding chip 5, bound to `ARCH` since 2026-10-06. 189 tests (166 offline, 23 fork tests on live IGNIX with a USD₮0-quoted token), 8,808 recorded settles compared bit for bit with the Python model (8,940 more on a second seed), two internal reviews, not an audit, that found no defect in the kernel code; each finding was addressed (`contracts/core-v2/NOTES.md` section 10). The Architect's revenue is not pointed at it: `PAY_TO` stays on the agent wallet until IGNIX confirms in writing that revenue-funded contract buys are allowed and the OKX.AI review is finished |
| Site (`web/`, `packages/`): chip demo, vault, epoch audit, hostile chip, judge guide, trust model | Live on GitHub Pages; both kernels' pages show their token, envelope, chip state and every settle (all with inflow 0 so far). The DeWEB mirror is the snapshot of commit `09b9178` (2026-10-07), checked byte for byte through the gateway |
| Covenant Architect (`services/architect`): compile endpoint, free route and x402 paid route | Live (Railway, built from `main`; `services/architect` has had no code change since commit `8678740`; live x402 mode, `PAY_TO` the agent wallet, which held 0 USD₮0 on 2026-10-08); 91 tests (3 of them opt-in against the real toolchain); OKX.AI agent 14683 submitted for review |
| Launch check and team audit (`tools/`) | Done; the team audit's latest run was CLEAN at block 72,682,367 (2026-10-08 09:23 UTC: after the token launches, the binds, `Splitter.pull()` and 273 keeper settles) |
| Reference token `CVREF`, the Architect token `ARCH`, and the keeper (`services/keeper`, 109 tests) | Live: both launched and bound on 2026-10-06; the keeper runs on Railway and settles both kernels every 15-minute epoch, its gas refunded by the KeeperTank (0.07225 OKB after `Splitter.pull()`) while each chip's allowance lasts: to about 2026-10-10 at the gas price of 2026-10-08, see [Live on X Layer](#live-on-x-layer) |
| Reproducible-build check (`deploy/verify-bytecode.sh`, [docs/VERIFY.md](docs/VERIFY.md)): each Covenant contract rebuilt at its recorded commit and compared with chain 196 | Done; what it covers and the latest result: [docs/VERIFY.md](docs/VERIFY.md). All eleven contracts' sources are verified on OKLink and Sourcify (2026-10-07); OKLink shows both kernel addresses as proxies of the verified Kernel and KernelV2 |
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
packages/     TypeScript libraries (TAP-02 simulator, chain access, die-shot renderer)
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

Every team wallet is listed in `docs/WALLETS.md`: the deployer, the keeper and the Covenant Architect's agent wallet. The on-chain TeamRegistry lists all three: the deployer (entry 0), the keeper (entry 1) and the Architect wallet (entry 2). No team wallet buys, sells or swaps any IGNIX token, sends funds into a kernel, or trades transistors (the Architect wallet receives x402 payments and is the v2 kernel's allowance payee; both are payments to it). `tools/audit-team` lists every transaction those wallets have sent and checks it against those rules, with no explorer in between; its latest run, on 2026-10-08 at block 72,682,367 (09:23 UTC), examined 152 deployer transactions, 274 keeper transactions (its declaration and 273 settles) and 2 user operations of the Architect wallet (its OKX.AI registration and its declaration), and found no rule broken and no USD₮0 leaving any team wallet, so none has paid the Architect's paid route either. It gave 125 warnings, none a flag: they are the deployer's 125 DeWEB publish transactions, the ones `deployments/xlayer.json` lists under `site.txs`, and their targets (TapeOut's DeWEB contracts) were not in the tool's list of known addresses at that run; `tools/audit-team/addresses.json` names them now. What the chain shows without the tool, on the same day: IGNIX's curve has sold none of either token and the IgnixManager holds the whole supply of both; both kernels and both tax vaults hold nothing and every recorded settle has inflow 0; the Architect wallet holds 0 USD₮0.

## Prior art and third-party code

`docs/PRIOR_ART.md` credits the entries we studied and states where Covenant differs. No code from another entry is used. `docs/THIRD_PARTY.md` lists the vendored and reused sources.

## Licence

MIT. Vendored sources keep their own notices.
