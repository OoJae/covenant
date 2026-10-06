# Covenant issuance contracts

The first irreversible mainnet step of Covenant: three immutable contracts that create the `Covenant` (`CVNT`)
processor on TapeOut (X Layer, chain 196) and split its mint proceeds. No owner, no upgrade path, no pause.

| Contract | What it does |
|---|---|
| `Splitter` | Its constructor deploys the two contracts below, writes their addresses into the processor's on-chain story and calls TapeOut's `createCPU`. It reverts unless TapeOut's factory is unsealed, TapeOut's fees are the ones the story states, and the processor carries exactly the story, name and symbol it was given. It is the processor's immutable `creator`, so it is the only address TapeOut pays. `pull()` splits everything 85 / 15. |
| `KeeperTank` | Receives 85%. Refunds the gas of `settleAndRefund(kernel)` out of the allowance of the chip that kernel holds: 85% of the mint price of the transistors the chip burned, plus top-ups. |
| `TeamRegistry` | Append-only list of team wallets: the deployer, then wallets that a listed wallet invited and that declared themselves. Not a payee. |

The maintainer wallet receives 15%. It is the deployer, `0x84cE7bAe1b788C7aD985D57721cA428b401aE34D`.
Nothing is reserved for IGNIX: the organiser asked that no share of the proceeds go to an IGNIX-controlled
escrow, so the earlier 25% launchpad escrow (`LaunchpadSocket`) is gone (NOTES.md, section 9).
Design notes, verified facts, the review findings and open assumptions are in [NOTES.md](NOTES.md).

Everything below is run from this directory (`contracts/issuance`).

## 1. Install and build

Dependencies go into `lib/`, which is gitignored. Nothing is installed globally.

```sh
forge install --no-git foundry-rs/forge-std@v1.17.0 OpenZeppelin/openzeppelin-contracts@v5.4.0
forge build --sizes --skip test --skip script
```

Toolchain: Foundry 1.8.3, solc 0.8.28, `evm_version = "cancun"`, optimizer 200 runs, no via-IR.
TapeOut's verified sources are read from `../vendor/tapeout-xlayer` (never modified).
The size table also lists the small helper contracts of the test tree; the three that are deployed are
`Splitter`, `KeeperTank` and `TeamRegistry`.

## 2. Tests

```sh
# everything: 264 tests (unit, fuzz, invariant, review and fork tests; the fork tests need an X Layer RPC)
forge test

# no network needed: 204 tests
forge test --no-match-path "*.fork.t.sol"

# fork tests only (60), against the real TapeOut factory at block 72,370,000.
# -vv prints the full story, its first 600 characters and the deployment gas.
forge test --match-path "*.fork.t.sol" -vv

# use the fallback RPC
XLAYER_RPC_URL=https://xlayerrpc.okx.com forge test --match-path "*.fork.t.sol"

# the wrapper script/ignite.sh: its refusals and the forge commands it runs (no chain, no key, no network)
bash test/shell/ignite.test.sh

# what script/Ignite.s.sol prints, with the real forge, in a simulation (needs an X Layer RPC; nothing is sent)
bash test/shell/ignite-output.test.sh
```

The fork block is pinned in `test/fork/XLayerFork.sol` (`FORK_BLOCK`). The fork tests pick the RPC from
`XLAYER_RPC_URL` (default `https://rpc.xlayer.tech`) and fall back to `https://xlayerrpc.okx.com` by themselves.
Every file named `*.fork.t.sol` is a fork test, in `test/fork` and in `test/review`.

The suite runs with `isolate = true` (see `foundry.toml`): every top-level call a test makes is executed as a
real transaction, so gas numbers include the 21,000 base cost and calldata, like a receipt.

`test/review` holds the tests the two reviewers wrote, adapted to the code as it is now. Where a test showed a
defect it now shows the repair, and says so in its comment.

## 3. Simulations and rehearsals (nothing is sent to X Layer)

### Ignite, simulated

```sh
script/ignite.sh
```

With no argument the wrapper only simulates: no key is touched and nothing is sent. It first refuses to run
unless the source the story will point at is committed and public (section 4 lists the checks), then it
takes `COMMIT` from `git rev-parse HEAD`, sets `MAINTAINER` to the deployer and runs

```sh
forge script script/Ignite.s.sol:Ignite --rpc-url https://rpc.xlayer.tech --sender 0x84cE7bAe1b788C7aD985D57721cA428b401aE34D
```

Before the creation is simulated the script prints every planned address, the whole story and, on their own,
the first 600 characters of the story (all that TapeOut's own site shows). It stops with an error if the
story on-chain differs from that planned story by one byte, if any address differs from the plan, or if any
wiring check fails. It also refuses if `MAINTAINER` is missing or is not the deploying account, and if the
chain is not 196.

To use the other public RPC: `XLAYER_RPC_URL=https://xlayerrpc.okx.com script/ignite.sh`.

### TapeoutProbe, simulated (after the processor exists)

```sh
CIRCUITS=<circuits> \
NETLIST_HEX=$(cat ../../chips/probe/probe.hex) \
N_IN=2 N_OUT=10 \
forge script script/TapeoutProbe.s.sol:TapeoutProbe --rpc-url https://rpc.xlayer.tech \
  --sender 0x84cE7bAe1b788C7aD985D57721cA428b401aE34D
```

`chips/probe/probe.hex` is the probe circuit: 799 bytes, 109 NAND and 9 LATCH, 2 inputs, 10 outputs.
The script counts the NAND and LATCH records of the netlist, mints exactly what the sender does not already
hold (one mint call per transistor type, each paying `mintPrice * amount + protocolFee`), tapes out with
0.0013 OKB and prints the circuit id.

Simulations leave files under `broadcast/*/196/dry-run/` and `cache/`; both are gitignored.

### A complete rehearsal on a local fork (optional)

Real transactions, real receipts, on a private copy of X Layer. No key: anvil impersonates the deployer.
The fork gets chain id 31337, so the records forge writes go to `broadcast/*/31337/`, which is gitignored,
and nothing here can be mistaken for a mainnet deployment.

```sh
# terminal 1
anvil --fork-url https://rpc.xlayer.tech --chain-id 31337 --port 8545 --auto-impersonate

# terminal 2
DEPLOYER=0x84cE7bAe1b788C7aD985D57721cA428b401aE34D

REHEARSAL=true MAINTAINER=$DEPLOYER COMMIT=$(git rev-parse HEAD) \
forge script script/Ignite.s.sol:Ignite --rpc-url http://127.0.0.1:8545 \
  --sender $DEPLOYER --unlocked --broadcast --slow

CIRCUITS=<circuits printed by the run above> \
NETLIST_HEX=$(cat ../../chips/probe/probe.hex) \
N_IN=2 N_OUT=10 \
forge script script/TapeoutProbe.s.sol:TapeoutProbe --rpc-url http://127.0.0.1:8545 \
  --sender $DEPLOYER --unlocked --broadcast --slow
```

`REHEARSAL=true` is what lets the Ignite script run on a chain id other than 196. Without it the script
refuses; `script/ignite.sh` always removes it. (An anvil fork without `--chain-id` keeps chain id 196 and
needs no flag, but then forge writes `broadcast/*/196/run-latest.json`, a record that looks like a mainnet
one. Delete it afterwards.)

## 4. Commands the human runs (these send mainnet transactions and cannot be undone)

> **Everything in this section is for the person who holds the deployer key. Nobody else, and no automated
> agent, runs these.**

One-time: import the deployer key into a Foundry keystore (prompts for the key and a password; nothing is
written to this repository).

```sh
cast wallet import covenant-deployer --interactive
cast wallet address --account covenant-deployer        # must print 0x84cE7bAe1b788C7aD985D57721cA428b401aE34D
```

Before signing:

1. The deployer must be a plain externally owned account. TapeOut mints transistors with an ERC-1155
   acceptance check, so an account that carries code (for example an EIP-7702 delegation) cannot mint unless
   that code implements `onERC1155Received`. Check: `cast code 0x84cE7bAe1b788C7aD985D57721cA428b401aE34D
   --rpc-url https://rpc.xlayer.tech` prints `0x`.
2. Commit the exact source and push it to `origin/main`. The story names that commit forever.
3. Run `script/ignite.sh` and read what it prints: the planned addresses, the story, and the first 600
   characters of the story. The three contract addresses in the story depend on the deployer's address and
   nonce, so do not send any other transaction from the deployer between this and the broadcast. (If you do,
   the contracts still work and the story still names the right addresses; it will just not be the text you
   read. The broadcast run prints it again.)
4. Sign off the story string and the 85 / 15 shares. They are immutable afterwards.

### Ignite (creates the processor: irreversible)

```sh
script/ignite.sh               # the simulation: read it
script/ignite.sh --broadcast   # simulates again, then sends the creation transaction
```

`script/ignite.sh` is the only thing to run. It refuses:

1. if `git status --porcelain -- contracts/issuance` is not empty (anything modified, staged or untracked);
2. if `contracts/issuance/src/Splitter.sol` is not tracked by git, or if any other `.sol` file under `src/`
   or `script/` is not (an ignored source file is missing from the commit while `git status` stays clean);
3. if `HEAD` is not an ancestor of `origin/main` after a fetch (the story points at this commit, so it must
   be public);
4. any argument other than `--broadcast`;
5. with `--broadcast`, an RPC that is not an `https` one (a fork on this machine reports chain id 196 too,
   and is not X Layer).

Only with `--broadcast` does it run, after the simulation,

```sh
forge script script/Ignite.s.sol:Ignite --rpc-url https://rpc.xlayer.tech \
  --account covenant-deployer --sender 0x84cE7bAe1b788C7aD985D57721cA428b401aE34D --broadcast --slow
```

which asks for the keystore password. Ctrl-C at that prompt sends nothing.

Cost: 0.0066 OKB deploy fee plus about 3.81M gas (about 0.000076 OKB at a 0.02 gwei base fee).
The receipt and all addresses are saved to `broadcast/Ignite.s.sol/196/run-latest.json`. Commit that file.
Never run `script/ignite.sh --broadcast` a second time: it would create a second processor. (While the record
is uncommitted the wrapper refuses anyway, because the project then differs from `HEAD`.)

At the deployer's nonce 0 the Splitter would be `0xfd73b7Bc92cDa68ec57799987fd3449BA5daDD88`, the registry
`0x6f1a330b7FfAc901205704EACA8e46ee4091F3A2` and the tank `0xAfed3eC2196BDc8F5a933D8f280c945f0D2D826e`.
The Transistors and Circuits addresses are created by TapeOut's factory and are final only in the receipt.

**Done on 2026-10-06**, at the deployer's nonce 1 (block 72,519,781), so the live addresses are: Splitter
`0xB87101F7426BA9175E0a944d3e763dC69B19867f`, TeamRegistry `0x7d1799Ec41b1Eb42Fd0D3f8Dc5326bc4c7c18699`, KeeperTank
`0xb89BCe53822a99503A937C22974F1224D9Ab6352`, Transistors `0xC372dc307eFE4B551c866A79F582D692A373960A`, Circuits
`0xaC90A95bd11eb67A2dD83Ab7ecc0Ea9B521dEF0b` (`deployments/xlayer.json`).

Check the result from a terminal (free calls):

```sh
RPC=https://rpc.xlayer.tech
SPLITTER=0xB87101F7426BA9175E0a944d3e763dC69B19867f        # the live Splitter
TRANSISTORS=$(cast call $SPLITTER "TRANSISTORS()(address)" --rpc-url $RPC)
CIRCUITS=$(cast call $SPLITTER "CIRCUITS()(address)" --rpc-url $RPC)
REGISTRY=$(cast call $SPLITTER "REGISTRY()(address)" --rpc-url $RPC)

cast call 0x1f09DAeFA827f02CBb40967cc91b259763760761 "isCPU(address)(bool)" $CIRCUITS --rpc-url $RPC   # true
cast call $TRANSISTORS "creator()(address)" --rpc-url $RPC                  # must be the Splitter
cast call $TRANSISTORS "story()(string)" --rpc-url $RPC                     # the story you signed off
cast call $REGISTRY "at(uint256)(address,string,uint256)" 0 --rpc-url $RPC  # the deployer, "deployer"
```

### TapeoutProbe (burns transistors: irreversible)

```sh
CIRCUITS=<circuits> \
NETLIST_HEX=$(cat ../../chips/probe/probe.hex) \
N_IN=2 N_OUT=10 \
forge script script/TapeoutProbe.s.sol:TapeoutProbe --rpc-url https://rpc.xlayer.tech \
  --account covenant-deployer --sender 0x84cE7bAe1b788C7aD985D57721cA428b401aE34D --broadcast --slow
```

Three transactions: `mint(0, 109)` with 0.00284 OKB, `mint(1, 9)` with 0.00084 OKB and `tapeout` with
0.0013 OKB. Cost: 0.00498 OKB plus about 812,000 gas. If it is the first tape-out on the processor the circuit
id is 1 (done: the probe is circuit 1, tape-out transaction `0x9e75ed66…ce572fa`). Before sending, `cast keccak $(cat ../../chips/probe/probe.hex)` must print
`0xbe0a646df5b58df69e5dc50f492dcc5bdcffa440c3188b8b786ff506cb181325`.

### Verify the sources on OKLink

Templates, not yet run: the contracts exist, but no source has been submitted to OKLink (`docs/VERIFY.md` and
`deploy/verify-explorers.sh` prepare the submissions). Use the live addresses above. If OKLink asks for a key, add
`--verifier-api-key <key>`.

```sh
OKLINK=https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER
DEPLOYER=0x84cE7bAe1b788C7aD985D57721cA428b401aE34D

forge verify-contract <splitter> src/Splitter.sol:Splitter --chain 196 --verifier oklink --verifier-url $OKLINK --watch \
  --constructor-args $(cast abi-encode "constructor(address,address,bytes20)" \
    0x1f09DAeFA827f02CBb40967cc91b259763760761 $DEPLOYER 0x<commit hash>)

forge verify-contract <tank> src/KeeperTank.sol:KeeperTank --chain 196 --verifier oklink --verifier-url $OKLINK --watch

forge verify-contract <registry> src/TeamRegistry.sol:TeamRegistry --chain 196 --verifier oklink --verifier-url $OKLINK --watch \
  --constructor-args $(cast abi-encode "constructor(address)" $DEPLOYER)
```

### Afterwards

```sh
# The deployer is entry 0 of the registry from the creation block on. Every other team wallet is listed in
# two steps: a listed wallet invites it, then it declares itself, once (role: at most 64 bytes).
cast send <registry> "invite(address)" <wallet> --rpc-url https://rpc.xlayer.tech --account covenant-deployer
cast send <registry> "declare(string)" "keeper" --rpc-url https://rpc.xlayer.tech --account <that wallet's keystore>

# anyone, any time: pay out whatever mint proceeds have accrued
cast send <splitter> "pull()" --rpc-url https://rpc.xlayer.tech --account covenant-deployer
```

## 5. What other packages need to know

Read-only surface (all getters are free calls):

| Contract | Getters |
|---|---|
| `Splitter` | `TRANSISTORS()`, `CIRCUITS()`, `TANK()`, `MAINTAINER()`, `REGISTRY()`, `maintainerOwed()`, `SUPPLY()`, `PRICE()`, `TANK_BPS()` (8500), `MAINTAINER_BPS()` (1500), `MAINTAINER_GAS()`, `NAME()`, `SYMBOL()` |
| `KeeperTank` | `SPLITTER()`, `circuits()`, `transistors()`, `mintPrice()`, `burnedOf(chipId)`, `allowanceOf(chipId)`, `remainingOf(chipId)`, `toppedUp(chipId)`, `spent(chipId)`, `ALLOWANCE_BPS()` (8500), `MAX_TIP()`, `OVERHEAD()`, `OVERHEAD_REPEAT()`, `RECEIVE_MIN_GAS()` |
| `TeamRegistry` | `isTeam(address)`, `isInvited(address)`, `count()`, `at(i)` returns `(wallet, role, timestamp)`, `MAX_ROLE_BYTES()` |

State-changing functions: `Splitter.pull()`, `Splitter.claimMaintainer()`, `KeeperTank.settleAndRefund(kernel)`,
`KeeperTank.topUp(chipId)` (payable), `TeamRegistry.invite(wallet)`, `TeamRegistry.declare(role)`.

Events: `Splitter.Ignited(transistors, circuits, tank, registry, maintainer) / Pulled(toTank, toMaintainer) /
MaintainerCredited / MaintainerClaimed`, `KeeperTank.Initialised / Refunded / ToppedUp / Funded`,
`TeamRegistry.Invited / Declared`.

`TeamRegistry`: `isTeam(wallet)` is true for the deployer from the creation block and for any other wallet once
it has declared itself; `isInvited(wallet)` is true once a listed wallet has invited it. `at(0)` is the
deployer with the role `deployer`. A wallet that was not invited cannot be listed; nothing is ever removed.

The story (`Transistors.story()`) is 1,366 bytes of printable ASCII. Its first 556 characters hold no address
and no URL. The commit at its end is 40 lower-case hex characters without `0x`.

For whoever writes the kernel (`src/interfaces/IKernelMin.sol` is frozen forever by the tank):

- `chipId()` and `settle()` must exist with exactly those signatures, and the kernel must hold the chip NFT.
- `settle()` must **revert** when it has nothing to do. The tank refunds every `settle()` that returns.
- To top up its own allowance by plain transfer a kernel must forward at least 200,000 gas
  (`RECEIVE_MIN_GAS`); with less the tank reverts. `topUp(chipId)` has no such floor.
- A contract that mints transistors (a Fab) must implement `onERC1155Received`.
- Gas the EVM gives back for storage that `settle()` clears (EIP-3529) is still counted by the tank: the
  chip's allowance then pays the caller for gas the caller was never charged. A storage reentrancy guard
  costs the allowance about 2,800 gas per settlement this way; a transient one costs nothing.

For whoever writes the keeper:

- Call `KeeperTank.settleAndRefund(kernel)`, not `kernel.settle()`. The refund is
  `min(gas counted * min(tx.gasprice, basefee + 0.001 gwei), remainingOf(chipId), tank balance)`.
- Do not tip more than 0.001 gwei; the excess is not refunded.
- If the tank's balance is below a chip's remaining allowance, call `Splitter.pull()` first.
- The tank counts 602 gas less than a transaction is charged, and none of its calldata: about 1,000 gas per
  settlement in all, and 17,100 more on the very first refund of a chip. That is what a keeper is short when
  `settle()` clears no storage. When it does, the EVM gives the keeper that gas back while the tank counts it
  all the same (about 2,800 gas for each IGNIX claim or buy, which pass a storage reentrancy guard; up to one
  fifth of the transaction for a kernel that clears storage on purpose), and the keeper can end up refunded
  more than the transaction cost. What bounds every refund is the chip's own prepaid allowance.
- X Layer's L1 data fee is zero today; if it is ever switched on, the tank cannot see it and does not
  refund it.
