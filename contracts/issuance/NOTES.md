# Issuance contracts: notes

Working notes for `contracts/issuance`: what was decided and why, what was verified and with which command,
what is still assumed, and how to run everything. Commands are in [README.md](README.md).

Scope: `Splitter`, `KeeperTank`, `TeamRegistry`, the scripts `Ignite` and `TapeoutProbe`, the wrapper
`script/ignite.sh`, and their tests. Binding documents: `docs/PLAN.md` sections 5 to 7, the review decisions
of 2026-10-04 and the removal of the launchpad share on 2026-10-06 (both in section 9 below).

Status: **deployed on X Layer on 2026-10-06** by the person holding the deployer key, from commit `9e99885`, in
transaction `0x9b4c9a6c…d5479f` (block 72,519,781, 3,810,435 gas). It was sent at the deployer's nonce 1, not 0, so
the live addresses differ from the nonce-0 plan of the rehearsal in section 5: Splitter
`0xB87101F7426BA9175E0a944d3e763dC69B19867f`, TeamRegistry `0x7d1799Ec41b1Eb42Fd0D3f8Dc5326bc4c7c18699`, KeeperTank
`0xb89BCe53822a99503A937C22974F1224D9Ab6352`, Transistors `0xC372dc307eFE4B551c866A79F582D692A373960A`, Circuits
`0xaC90A95bd11eb67A2dD83Ab7ecc0Ea9B521dEF0b` (`deployments/xlayer.json`, `issuance`). The story on chain is 1,366 bytes
and names the Splitter, the tank, the registry, the maintainer and the commit. `pull()` was first called on 2026-10-06 (block 72,559,111): 0.07225 OKB to the tank, 0.01275 OKB to the maintainer.
The registry lists the deployer, the keeper and the Architect wallet.

## 1. Layout

```
src/Splitter.sol            creates the processor, splits proceeds 85 / 15
src/KeeperTank.sol          prepaid settlement gas per chip
src/TeamRegistry.sol        append-only list of team wallets, rooted in the deployer
src/interfaces/IKernelMin.sol   FROZEN: the two functions the tank calls on a kernel
src/interfaces/ITapeOut.sol     the parts of TapeOut's factory, Transistors and Circuits used here
src/interfaces/IOwnable.sol     owner(): only the Ignite script uses it, to print who owns TapeOut's factory
src/lib/NetlistScan.sol     counts the transistors a netlist burns (top-level NAND and LATCH only)
src/lib/Native.sol          OKB transfer that never copies return data
script/ignite.sh            the one command the human runs: checks git, simulates, broadcasts on request
script/Ignite.s.sol         deploys the Splitter
script/TapeoutProbe.s.sol   mints what a netlist needs and tapes it out
script/lib/Story.sol        the story template rebuilt without any code from src/ (scripts and tests)
test/unit                   unit and fuzz tests on small mocks (no network)
test/invariant              stateful fuzzing with an independent ledger (no network)
test/fork                   the same flows against the real factory at a pinned block
test/review                 the two reviewers' tests, adapted (files named *.fork.t.sol need the network)
test/shell                  tests of script/ignite.sh and of what Ignite prints
test/fixtures               the approved story text (head and tail) and the probe netlist
test/mocks, test/utils      mocks, hostile counterparts, TapeOut's NetlistVM as an oracle
```

## 2. Decisions

### Toolchain

- solc 0.8.28 exact, `evm_version = cancun`, optimizer 200 runs, legacy pipeline (no via-IR).
- OpenZeppelin Contracts v5.4.0 (`Strings`, `ReentrancyGuardTransient`), forge-std v1.17.0. Both installed
  with `forge install --no-git` into `lib/` (gitignored).
- `.gitignore` ignores `/lib/`, `/out/` and `/cache/` with a leading slash: only the folders at the root of
  the project. The pattern `lib/` it had at first also ignored `src/lib` and `script/lib`, so `Native.sol`,
  `NetlistScan.sol` and `Story.sol` would never have reached the repository the story points at.
- `isolate = true`: every top-level call in a test is its own transaction. The tank's refund figures are
  statements about whole transactions (base cost, calldata, EIP-3529 refunds, transient storage), so they
  are tested on whole transactions.
- `dynamic_test_linking = false`: tests deploy with plain `new`. With forge's default (true) a deployment made
  by a test is routed through a cheatcode and its gas misses the creation transaction's calldata.
- TapeOut's vendored `Transistors.sol` does not compile under the legacy pipeline (stack too deep in
  `initialize`), so the non-fork tests use small mocks (`test/mocks/MockTapeOut.sol`) and only TapeOut's
  `NetlistVM` library is compiled, as an oracle for the netlist scan and as the burn rule of the mock.
  Everything TapeOut-specific is tested for real on the fork.
- `ignored_warnings_from = ["test/review/SplitterAttack.t.sol"]`: that one review test forces OKB into a
  contract with SELFDESTRUCT on purpose, and solc warns wherever the opcode appears. Nothing under `src/` or
  `script/` uses it (`test_runtimeBytecode_hasNoDangerousOpcodes` walks the deployed bytecode of the Splitter
  and the registry).

### The story

- The text is fixed: `test/fixtures/story.head.txt` (556 characters) followed by `test/fixtures/story.tail.txt`
  (617 characters) with five placeholders: `{S}` splitter, `{T}` tank, `{A}` maintainer, `{R}` registry,
  `{C}` commit. 1,366 bytes once filled in. This is the third approved text (2026-10-06): it names no
  IgnixManager and no escrow, and the tank sentence states the allowance (85% of the mint price of the
  transistors a chip burned, plus top-ups).
- TapeOut's own site shows the first 600 characters of a story, replaces every `0x` followed by six or more
  hex digits with a "hidden address" notice and rewrites every URL. So the head stands alone: it holds no
  address and no URL, and says what a buyer must know (supply, price, the split, the trust statement). The
  first 600 characters are the 556 of the head and "DETAILS: TapeOut's own fees are extra and no".
- Addresses are EIP-55 checksummed (`Strings.toChecksumHexString`). The commit is 40 lower-case hex characters
  without `0x` (the Splitter's own `_hex`), the way git prints it; with a prefix the site would hide it.
- No free text enters the story. The repository URL `https://github.com/OoJae/covenant` is part of the fixed
  text; the constructor takes no string. The only text a deployer supplies is the commit, as `bytes20`.
- The same text exists three times, and the tests hold the three against each other: the Splitter's
  constants, `script/lib/Story.sol` (typed sentence by sentence, addresses by Foundry's `vm.toString`), and
  the two fixture files (pinned by their keccak256 in `test/unit/Story.t.sol`).

### Splitter

- Constructor `(factory, maintainer, commit)`. Order: `TeamRegistry(msg.sender)`, then `KeeperTank`, with
  `new` (the Splitter's nonces 1 and 2; it creates nothing else); story built on-chain;
  `createCPU{value: msg.value}("Covenant", "CVNT", story, 67_108_864, 20_000_000_000_000)`; checks;
  `tank.init(circuits, transistors)`.
- What the constructor enforces after `createCPU`, each with its own revert:
  `FactorySealed` if `factory.isSealed()` (the story says TapeOut's owner can upgrade processor logic; the
  check comes after `createCPU`, so a factory that seals itself while creating is caught too);
  `TapeOutFeesChanged` unless the factory's and the clone's `protocolFee()` are 0.00066 OKB and
  `TAPEOUT_FEE()` is 0.0013 OKB; `ProcessorMismatch` unless `creator == this`, `supplyCap == SUPPLY`,
  `mintPrice == PRICE`, the Transistors/Circuits pair point at each other, `factory.isCPU(circuits)`, and
  `story()`, `cpuName()` and `cpuSymbol()` read back equal to what was passed (`Strings.equal`: same length
  and same keccak256).
- Before `createCPU`: `ZeroMaintainer`, `ZeroCommit`, `WrongDeployFee` (`msg.value` must equal `deployFee()`).
- `msg.sender` of the constructor, the account that sends the creation transaction, becomes entry 0 of the
  registry.
- Getters are upper-case because they are immutables: `TRANSISTORS()`, `CIRCUITS()`, `TANK()`, `MAINTAINER()`,
  `REGISTRY()`.
- `pull()` splits `balance - maintainerOwed`. A maintainer share that could not be pushed stays in the
  Splitter's balance and must not be split again.
- Shares: `TANK_BPS = 8500`, `MAINTAINER_BPS = 1500`. The maintainer's share is rounded down and the tank
  gets the rest, so the tank is never below 85% and is above it by less than 1 wei per pull.
  `Pulled(toTank, toMaintainer)`; `Ignited(transistors, circuits, tank, registry, maintainer)`.
- With nothing to split `pull()` returns without calling anyone and without an event.
- `withdraw()` on Transistors is wrapped in `try/catch {}` that swallows every failure, not only
  "nothing owed": whatever TapeOut's logic becomes, money already in the Splitter can always be split.
- All OKB transfers go through `Native.send` (assembly `call` with zero-length return buffer). Solidity's
  `(bool ok,) = to.call{...}("")` may copy return data; a payee must not be able to make the Splitter pay for
  a large buffer.
- Maintainer push: 50,000 gas (`MAINTAINER_GAS`), enough for an EOA or a Safe (a Safe's receive costs about
  6,600). If the push fails the share is credited to `maintainerOwed`.
- `PUSH_MIN_GAS = 90,000`: `pull()` reverts if less gas is left when the push starts. Without it a caller
  could choose a gas limit that leaves the push too little gas; a maintainer wallet that reverts cheaply when
  it sees too little gas would then be credited instead of paid, at the caller's whim.
- `claimMaintainer()` is permissionless and pays only the maintainer, with all available gas. A maintainer
  contract that cannot make calls itself can still be paid.

### KeeperTank

- `ALLOWANCE_BPS = 8500`, equal to the Splitter's `TANK_BPS`: every allowance that comes from burned
  transistors is fully backed once their proceeds have been pulled (85% of their price reaches the tank).
- `init` is called once by the Splitter's constructor. `circuits`, `transistors` and `mintPrice` are storage,
  not immutables, because the tank must exist (to be named in the story) before the processor does.
- `burnedOf` scans `Circuits.netlist(chipId)` with `NetlistScan.burnOf` and returns NAND + LATCH. The first
  `settleAndRefund` for a chip stores the count (as count + 1, so that zero means "not stored"). After that
  a logic upgrade by TapeOut cannot change that chip's allowance.
- `settleAndRefund` order: `g0 = gasleft()`, `chipId()`, `ownerOf(chipId) == kernel`, burn count (stored on
  first use, inside the measured window so the scan is refunded), `kernel.settle()`, then everything else is
  read after the kernel call (a kernel may top up or pull during `settle()`).
- `kernel.settle()` is called in assembly: no return data is copied on success; on failure the revert data
  is re-thrown unchanged.
- Refund: `min(used * price, remaining, balance)`, `price = min(tx.gasprice, block.basefee + MAX_TIP)`.
  State is written and the event emitted before the transfer. If the transfer fails everything reverts.
- `MAX_TIP = 0.001 gwei`. A tip that is refunded costs the caller nothing, so the cap is also how much faster
  than at the base fee any caller can use up a chip's allowance: 5% at X Layer's 0.02 gwei base fee. (It was
  0.01 gwei, half the base fee: any caller could drain an allowance 1.5 times as fast for free.)
- `receive()`: the Splitter and addresses without code are never probed. A contract is probed with two
  staticcalls that cannot revert the transfer and never copy more than 32 bytes: `chipId()` capped at 50,000
  gas, `ownerOf(chipId)` capped at 100,000 gas.

### TeamRegistry

- `constructor(founder)` lists `founder` as entry 0 with the role `deployer` and emits `Declared(founder, 0,
  "deployer")`. The Splitter passes `msg.sender`.
- `invite(wallet)`: only a listed wallet (`NotListed` otherwise); sets `isInvited[wallet]`; emits
  `Invited(wallet, by)`. An invited wallet that has not declared cannot invite. An invitation cannot be
  withdrawn. Inviting a wallet twice, or one that is already listed, changes no state (the event is emitted
  again) and does not let a listed wallet declare a second time.
- `declare(role)`: `AlreadyDeclared` if the caller is listed, then `NotInvited` unless it was invited, then
  `RoleTooLong` above 64 bytes (bytes, not characters). Records `msg.sender`, the block timestamp and the
  role; emits `Declared(wallet, index, role)`. An empty role is allowed; role bytes are not validated.
- No owner, nothing editable, nothing removable. `at(i)` out of range panics (0x32).

### The deployment script and its wrapper

- `script/Ignite.s.sol` reads `MAINTAINER` (required), `COMMIT` (required, 40 hex characters) and `REHEARSAL`
  (optional). It refuses a chain id other than 196 unless `REHEARSAL=true`, a zero commit, a missing factory
  (no code at its address), and a `MAINTAINER` that is not the deploying account. It reads the deploying account with an
  empty `startBroadcast` / `stopBroadcast` pair, so that every refusal happens outside the one broadcast.
- Before the creation it computes the plan: the Splitter at `CREATE(deployer, nonce)`, the registry and the
  tank at the Splitter's nonces 1 and 2, the Transistors and Circuits clones at the factory's next two
  nonces, and the story for those addresses. It prints all five addresses, the story, and the first 600
  characters of the story on their own. After the creation it requires that the story on-chain equals the
  planned story and that all five addresses equal the plan, then repeats the wiring checks.
- forge executes a script completely, and shows its output, before it sends anything. So everything above is
  on screen before a transaction leaves, with or without `--broadcast`.
- `script/ignite.sh` is the only thing the human runs. It refuses unless `git status --porcelain --
  contracts/issuance` is empty, `src/Splitter.sol` and every other `.sol` under `src/` and `script/` are
  tracked, and `HEAD` is an ancestor of `origin/main` after a fetch. It sets `COMMIT` from `git rev-parse
  HEAD` and `MAINTAINER` to the deployer whatever the environment holds, removes `REHEARSAL`, runs the
  simulation, and only with `--broadcast` runs the same script with `--account covenant-deployer --sender
  <deployer> --broadcast --slow`. With `--broadcast` it also refuses an RPC that is not `https`: a local
  fork reports chain id 196 as well. The check on the other `.sol` files and the one on the RPC go beyond
  what was asked; the first is the check that would have caught the `.gitignore` mistake above.

## 3. Deviations from the task specification

Each one is deliberate. None removes anything that was asked for.

1. **OVERHEAD is two constants, selected by a transient flag.**
   The specification asks for one constant that includes the 21,000 base cost. A contract that settles N
   kernels in one transaction pays the base cost once and would be granted it N times. So the first
   `settleAndRefund` of a transaction gets `OVERHEAD = 34,000` (base cost included) and every later one in the
   same transaction gets `OVERHEAD_REPEAT = 10,500`. The flag is one `bool transient`; it clears itself at the
   end of the transaction and is rolled back if the call reverts.
2. **Calldata is not counted in OVERHEAD.** A direct call carries 192 to 580 gas of calldata, a call through
   another contract carries none of its own, and the tank cannot tell. Counting it could over-refund.
3. **`receive()` reverts for a contract sender that forwards less than 200,000 gas** (`RECEIVE_MIN_GAS`).
   The specification says a transfer that cannot be attributed is unattributed backing. With too little gas
   a probe can fail for lack of it. A probe that burns all its gas leaves too little to finish, and the
   transfer reverts by itself; but one that fails cheaply (a `chipId()` that checks its gas, say) would let
   the transfer through without crediting the kernel's chip, and anyone able to choose the gas of such a
   transfer could do that to a kernel on purpose. With the floor the outcome does not depend on how a probe
   fails. The Splitter and addresses without code are unaffected, and `topUp(chipId)` has no floor.
4. **Constructor checks in the Splitter** beyond the review decisions: `commit` non-zero, `creator == this`,
   `supplyCap == SUPPLY`, `mintPrice == PRICE`, the Transistors/Circuits pair point at each other,
   `factory.isCPU(circuits)`, and the clone's own `protocolFee()` (in addition to the factory's).
   The factory is upgradeable; if it ever stops doing what its verified source does, creation reverts instead
   of producing a processor whose story is false.
5. (Gone with the `LaunchpadSocket` on 2026-10-06, section 9: the socket's two extra checks.)
6. **`claimMaintainer()` can be called by anyone** (the specification does not say who). The money can only
   go to the maintainer.
7. **`pull()` with nothing to split emits no event.**
8. **TapeoutProbe mints only the shortfall** (`needed - already held`), so re-running it after a failed
   tape-out does not buy the transistors twice. From an account that holds none, that is exactly the needed
   amount.
9. **Tank share bound:** "within 1 wei of exact" holds for the maintainer's share. The tank takes the dust of
   that one rounding, so it is less than 1 wei above exact. (With the socket there were two roundings and the
   tank could be up to 2 wei above; since 2026-10-06 this is no longer a deviation.)
10. **The `isSealed()` check runs after `createCPU`, not before.** The decision asks for a revert when the
    factory is sealed; reading it once creation is done also covers a factory that seals itself while it
    creates. On the real factory the two are the same.
11. **`script/ignite.sh` checks every `.sol` file under `src/` and `script/`, not only `Splitter.sol`**,
    drops `REHEARSAL` and any `COMMIT` or `MAINTAINER` found in the environment, and with `--broadcast`
    accepts only an `https` RPC (section 2).

## 4. What bounds a refund, precisely

`paid = min(counted * price, remaining allowance, tank balance)`, `price = min(tx.gasprice, basefee + 0.001 gwei)`.

`counted` = gas measured from the first line of `settleAndRefund` to the end of the kernel call, plus
`OVERHEAD` or `OVERHEAD_REPEAT`. What the measurement misses, measured on this bytecode
(`test/unit/TankOverhead.t.sol`, pinned to the gas unit):

| Term | Gas |
|---|---|
| transaction base cost | 21,000 |
| calldata of a direct call (not counted) | 192 to 580 |
| SSTORE `spent[chipId]`, warm, first change in the transaction | 2,900 (20,000 the first time ever for a chip; 100 if already changed in this transaction) |
| CALL with value to a warm address, callee runs no code | 6,800 (9,000 + 100 - 2,300 stipend handed back) |
| LOG4 with 64 bytes of data | 2,387 |
| reentrancy guard (TLOAD + 2 TSTORE) | 300 |
| dispatch, decoding, arithmetic, event memory | 1,215 |

Steady state: 34,602 + calldata is missed, 34,000 is counted. So `counted` never exceeds the gas a transaction
**consumes** when a refund is paid, and it is 602 gas + calldata (about 1,034 gas) below it. The very first
refund of a chip misses 17,100 more, once. Repeat call in one transaction: 10,802 missed, 10,500 counted.

When nothing is paid (`paid == 0`) neither the SSTORE nor the CALL happens, so the `gasUsed` field of the
`Refunded` event overstates the gas by up to about 9,700. No money moves in that case.

**A caller can be refunded more than its transaction cost.** What a transaction consumes is not what its
sender is charged: at the end of a transaction the EVM gives gas back for storage that was cleared
(EIP-3529, at most one fifth of the gas consumed). A contract cannot observe that. When storage is cleared
inside `settle()`, the tank has counted the gas and the caller gets it back from the EVM as well:

- a storage reentrancy guard (set to "entered", then back) gives back 2,800 gas each time it is passed. An
  IGNIX claim (`claimFor` on a vault) and an IGNIX buy (`buyTo` on IgnixManager) each pass one: 2,800 gas
  measured for each at block 72,370,000 (`test/review/HonestRefunds.fork.t.sol`). With one of them in
  `settle()` the caller ends about 1,800 gas ahead per settlement instead of about 1,000 short
  (`test_review_refund_oneClassicReentrancyGuard_callerReceivesMoreThanItPaid`,
  `test_review_refund_realIgnixBuyInsideSettle_callerReceivesMoreThanItPaid`);
- a kernel that sets and clears storage on purpose can make `counted` exceed the gas charged by up to a
  quarter, in the same transaction (`test_caveat_storageRefundsEarnedInsideSettle`) or from one settlement to
  the next (`test_review_refund_flipFlopKernel_callerProfitsAQuarterOnEveryOtherSettlement`).

This is not a hostile-kernel-only effect, and nothing here says that a keeper is always short or never ahead.
**The bound that always holds is the chip's own allowance**: 85% of what was paid for the transistors it
burned plus what was topped up for it, prepaid; a refund never touches another chip's
(`test_caveat_isBoundedByWhatTheAttackerPaidIn`, the invariant campaign). The story says exactly that:
"refunds the gas of a chip's settlements, up to that chip's prepaid allowance (85% of the mint price of the
transistors it burned, plus top-ups)".

## 5. Verified facts

Chain and protocol (read on 2026-10-05, RPC `https://rpc.xlayer.tech` unless stated; rows marked 2026-10-06
re-read then):

| Fact | Command | Result |
|---|---|---|
| Chain id | `cast chain-id --rpc-url $RPC` | 196 |
| Node software | `cast client --rpc-url $RPC` | `reth/v1.10.2-5101851/x86_64-unknown-linux-gnu/xlayer/v0.1.0` |
| Base fee, tip | `cast block latest --rpc-url $RPC`, `cast rpc eth_maxPriorityFeePerGas` | 0.02 gwei, 1 wei |
| Block gas limit | `cast block latest --rpc-url $RPC` | 210,000,000 |
| L1 data fee | `eth_getTransactionReceipt` of a recent transaction | OP-Stack receipt fields present; `l1Fee` 0, `l1BaseFeeScalar` 0, `l1BlobBaseFeeScalar` 0 |
| Cancun opcodes exist | `eth_call` of initcode `0x602a5f5d5f5c5f5260205ff3` (TSTORE/TLOAD) and `0x602a5f5260205f60205e60206020f3` (MCOPY) | both return `…2a` |
| EIP-7702 is live | `cast code 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --rpc-url $RPC` | `0xef0100…` (a delegation designator) |
| Both RPCs serve state at an old block | `cast call $FACTORY 'deployFee()(uint256)' --block 72000000` on both | 6600000000000000 |
| `deployFee` (2026-10-06) | `cast call $FACTORY 'deployFee()(uint256)'` | 0.0066 OKB |
| `protocolFee` (2026-10-06) | `cast call $FACTORY 'protocolFee()(uint256)'` | 0.00066 OKB |
| Factory unsealed (2026-10-06) | `cast call $FACTORY 'isSealed()(bool)'` | false |
| Factory owner (2026-10-06) | `cast call $FACTORY 'owner()(address)'` | `0xB3D85b42A045c1A88D800CAD0F55d2566a4D3138` |
| Processors | `cast call $FACTORY 'cpuCount()(uint256)'` | 275 at block 72,370,000; 283 at block 72,513,929 (2026-10-06) |
| Factory nonce (2026-10-06) | `cast nonce $FACTORY` | 569 (so the next clones are `0xC372dc30…73960A` and `0xaC90A95b…1dEF0b`; it was 553 on 2026-10-05: others create processors, and these two addresses are not in the story) |
| `TAPEOUT_FEE` | `cast call <any Circuits> 'TAPEOUT_FEE()(uint256)'` | 0.0013 OKB |
| The deployer (2026-10-06) | `cast nonce`, `cast balance`, `cast code` of `0x84cE7bAe1b788C7aD985D57721cA428b401aE34D` | nonce 0, 0.573 OKB, no code |

`$FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761`. (IgnixManager, `0x96B51c57e5346D0C0198899243cf851D1E23C309`,
is no longer part of the issuance; two review tests still measure what a kernel's IGNIX buy does inside
`settle()`.)

About these contracts, as they are in this directory on 2026-10-06:

| Fact | How | Result |
|---|---|---|
| The live node executes the Splitter's constructor end to end | `eth_estimateGas` on `https://rpc.xlayer.tech` (creation data, 14,337 bytes, value 0.0066 OKB, from the deployer); no transaction sent | 3,841,820 (the fallback RPC did not resolve from this machine on 2026-10-06; it gave the same figure as the primary on 2026-10-05) |
| ... and rejects one wei too much | same with value + 1 | reverts with `0x159849d8` = `WrongDeployFee()` |
| Deployment gas, fork test | `forge test --match-test test_fork_ignite_gas -vv` | 3,811,257 (whole transaction, base cost and calldata included; 4,333,550 with the socket) |
| Deployment gas, real receipt on a local anvil fork, from the real deployer at nonce 0 | rehearsal below | 3,810,411; 0.0000762 OKB at 0.02 gwei |
| Story | `forge test --match-test test_fork_ignite_storyIsByteForByteTheTemplate -vv` | 1,366 bytes, equal to the template byte for byte |
| Story of the rehearsal against the approved text | the two fixture files filled in by bash with addresses from `cast to-check-sum-address`, compared with `cmp` | equal byte for byte |
| What TapeOut's site would show of it | its first 600 characters hold no `0x` and no `http` (tests, and the rehearsal's story) | nothing that the site hides (`0x` followed by hex digits) or rewrites (URLs). The site's own sanitising function was run on the 2026-10-05 story; it is not in this repository and was not re-run |
| forge's isolate-mode gas equals receipts | anvil fork of 2026-10-05, `cast send … settleAndRefund` at 0.02 gwei + 1 wei, on the tank as it was then (it differs from today's only in the value of `ALLOWANCE_BPS`) | steady state: receipt 73,695, counted 72,661 (the same two numbers `test_review_refund_maxTip_noLongerDrainsTheAllowanceHalfAgainFaster` prints on the fork, also on 2026-10-06); first refund of the 118-transistor chip: 167,848 and 149,714 |
| A tip above the cap is not refunded | same fork, with tips of 0.001 gwei and 0.01 gwei | both refunded at 0.021 gwei per unit of gas counted |
| EIP-3529 refund of an IGNIX claim and of an IGNIX buy | `forge test --match-contract HonestRefundsForkTest -vv` | 2,800 gas each |
| Sizes | `forge build --sizes --skip test --skip script` | see section 7 |
| Selectors | `cast sig` | `chipId()` 0x0351e494, `settle()` 0x11da60b4, `settleAndRefund(address)` 0x55b281c7 |
| Scan cost for a 2,184-transistor netlist | `forge test --match-test test_flagshipSizedNetlist_gas -vv` | 437,899 gas, once per chip |
| Kernel to tank plain transfer, whole transaction, real processor | `forge test --match-test test_fork_receive_attributesAKernelsTransferToItsChip -vv` | 72,083 gas |
| Minting transistors to an account with code needs `onERC1155Received` | TapeoutProbe from a 7702-delegated account on an anvil fork (first version) | `ERC1155InvalidReceiver` |
| The wrapper's simulation path, with the real forge, on the live chain (2026-10-06) | `script/ignite.sh` in a throwaway clone whose `origin` is a local bare repository; read-only | the three planned addresses above, a 1,366-byte story, "SIMULATION COMPLETE", nothing sent |

**The rehearsal** (2026-10-06, the code as it is here). `anvil --fork-url https://rpc.xlayer.tech
--fork-block-number 72513549 --chain-id 31337 --auto-impersonate` on `127.0.0.1`, in a private copy of this
directory; the deployer `0x84cE7bAe1b788C7aD985D57721cA428b401aE34D` impersonated at its real nonce 0 with its
real balance (0.573 OKB), `MAINTAINER` equal to it, `REHEARSAL=true`, `COMMIT` a sample (the repository's
`HEAD` at the time, `de6d4c4f200801b51d3e2634a02cf147a52de12b`), `--unlocked`, no key.

| Step | Result |
|---|---|
| Ignite | one transaction, status 1, 3,810,411 gas. Splitter `0xfd73b7Bc92cDa68ec57799987fd3449BA5daDD88`, registry `0x6f1a330b7FfAc901205704EACA8e46ee4091F3A2`, tank `0xAfed3eC2196BDc8F5a933D8f280c945f0D2D826e`, Transistors `0xC372dc307eFE4B551c866A79F582D692A373960A`, Circuits `0xaC90A95bd11eb67A2dD83Ab7ecc0Ea9B521dEF0b`: all five as planned before the creation. The Splitter's nonce afterwards is 3 (it created the registry and the tank, nothing else); `SOCKET()` does not exist |
| Story | 1,366 bytes, keccak `0xc6824a382fbfe69b315a056aa271f4294ae9b0713cd9091b4a9b80906116f4fc`, equal byte for byte to the fixtures filled in by `cast` |
| Registry after it | `count()` 1; `at(0)` = the deployer, `deployer` |
| TapeoutProbe with `chips/probe/probe.hex`, 2 in, 10 out | three transactions: `mint(0, 109)` 157,599 gas, `mint(1, 9)` 86,434 gas, `tapeout` 567,908 gas; 0.00498 OKB sent; circuit id 1, `circuitInfo` (2, 10, 9, 118), stored netlist keccak `0xbe0a646d…181325`, `step(1, 0xfe00, 0x01)` = (`0xff01`, `0xff01`); the tank's `allowanceOf(1)` = 2,006,000,000,000,000 wei |
| `pull()`, sent by a third account | 68,117 gas; proceeds 2,360,000,000,000,000 wei (118 transistors); tank +2,006,000,000,000,000 (85%, exactly the probe chip's allowance), maintainer +354,000,000,000,000 (15%), to the wei; `Pulled(2006000000000000, 354000000000000)`; nothing left in the Splitter or owed by TapeOut |
| Registry | a stranger's `declare` reverts `NotInvited`; `invite` by the deployer 47,427 gas; `declare` by the invited wallet 99,293 gas |
| The script's refusals, with the real `forge script` | no `MAINTAINER`; `MAINTAINER` another address; no `COMMIT`; a short `COMMIT`; chain 31337 without `REHEARSAL`: each fails before anything is simulated |

The forks ran on `127.0.0.1`; their `broadcast/` and `cache/` records are in the private copy, not here.

Tooling quirks found on the way (forge 1.8.3):

- In isolate mode a forked block's base fee reads as 0 inside a transaction until `vm.fee` is called
  (`block_base_fee_per_gas = 0` in the config wins). `test/fork/XLayerFork.sol` re-applies it.
- In an invariant campaign forge funds the sender of each call for gas when `tx.gasprice` is non-zero, and
  it picks senders from addresses it has seen, contracts included. The Splitter once showed up with OKB from
  nowhere that way. The suite excludes the system's contracts as senders and resets the gas price.
- `vm.parseBytes` does not accept an upper-case `0X` prefix; the scripts accept `0x` or no prefix.
- The environment is shared by every test of a run and `vm.setEnv` cannot unset. So exactly one test reads
  and sets `MAINTAINER`, `COMMIT` and `REHEARSAL` (`test_fork_script_ignite_fromEnvironment`), step by step;
  every other test calls `ignite(maintainer, commit, rehearsal)` with explicit arguments.
- If a call reverts between `vm.startBroadcast()` and `vm.stopBroadcast()` the broadcast stays on. The Ignite
  script therefore refuses everything before its one broadcast.
- `vm.expectCall` does not see calls to the console. What the script prints is tested from outside, with the
  real forge (`test/shell/ignite-output.test.sh`).
- `vm.setEvmVersion("prague")` lets `test/review/Delegated7702.t.sol` run under the Prague rules (EIP-7702)
  while everything stays compiled for Cancun.
- `forge lint` flags a mapping write that is followed by its event (`missing-events-access-control`). The two
  such lines, in `TeamRegistry`, carry a `forge-lint: disable-next-line` with the reason. (A third, a balance
  compared with zero, went with the socket.)

## 6. Tests

`forge test`: 264 tests in 23 suites. Without the network (`--no-match-path "*.fork.t.sol"`): 204 (unit and
fuzz 165, review 38, and 1 invariant campaign with 3 invariants). Fork (`--match-path "*.fork.t.sol"`): 60
(`test/fork` 34, `test/review` 26). Two shell tests besides: `test/shell/ignite.test.sh` (122 checks) and
`test/shell/ignite-output.test.sh` (21 checks). (Before the socket was removed: 317, 247 and 70 tests, 22
output checks; the difference is the socket's own tests, listed in section 9.)

- **Fork** (`test/fork`): real factory, block 72,370,000. Processor creation and every getter; story byte for
  byte and its first 600 characters; registry rooted in the sender of the creation; mint by a random user;
  `pull()` 85 / 15, dust, second pull; fuzzed split conservation; tape-out of the 3-NAND netlist, chip to a
  mock kernel, `settleAndRefund` until exhausted; price cap; REF-only circuit burns nothing and has no
  allowance (and evaluates like the circuit it references); kernel top-up through `receive()` at exactly the
  gas floor; reverting maintainer; re-entrant and gas-burning kernels; what a TapeOut logic upgrade can and
  cannot do to an allowance; both scripts, the Ignite plan against what the creation produces, each of its
  refusals, and the real probe circuit through TapeoutProbe, from a fresh account and after a run that got
  only as far as its first mint.
- **Unit and fuzz** (`test/unit`): constructor reverts, among them a sealed factory, a factory that seals
  itself while creating, and five sabotage cases for a stored story, name or symbol that differs; the story
  (`Story.t.sol`: the approved files byte for byte for any maintainer, nonce and commit; the first 600
  characters contain SUPPLY, PRICE, 85%, 15% and TRUST and neither `0x` nor `http`; printable ASCII; the
  commit as 40 bare hex characters; each of the four addresses checksummed, once; the allowance sentence
  against `ALLOWANCE_BPS`; no escrow, socket or IgnixManager named); split conservation for any balance and
  any sequence; a tank that refused would make `pull()` revert as a whole; maintainer fallback under any accept/refuse pattern; hostile maintainers (re-entry, gas
  burning, 100 kB revert data, gas starvation); refund formula for any base fee, tip, workload, top-up and
  balance; hostile kernels and callers; batching; the OVERHEAD constants; `receive()` attribution matrix;
  netlist scan against TapeOut's `NetlistVM.burnOf` on random well-formed netlists, truncation at every
  offset, unknown opcodes, arbitrary bytes; the registry (every revert, and any sequence of invitations and declarations
  among five wallets against the rule written out independently).
- **Review** (`test/review`): the two reviewers' tests, adapted. Attacks on the constructor (prefunded
  addresses, a factory that calls back, a reverted creation), on `pull()` (gas sweeps one gas unit at a time,
  call depth, forced balance, a hostile Transistors, drift) and on the registry; EIP-7702 delegated maintainers; the real
  deployer at nonce 0; a real Safe as maintainer; each sentence of the story against the chain.
- **Invariant** (`test/invariant`): 128 runs of 100 random actions (mint, pull, tape out, settle, top up,
  kernel transfer, donations, maintainer on/off, claim) checked against an independent ledger: every wei of
  proceeds is accounted for; shares stay 85 / 15 with dust only to the tank; the tank's balance equals
  inflows minus refunds; no chip spends more than its allowance (85% of its burned transistors' price plus
  top-ups); refunds never exceed gas counted at the capped price. Runs with `fail_on_revert = true`.
- **Shell** (`test/shell`): `ignite.test.sh` builds a throwaway repository with a bare `origin` and a stub
  `forge` for each of 24 scenarios: what the wrapper runs with and without `--broadcast`, what it puts in
  `COMMIT` and `MAINTAINER`, and every refusal. `ignite-output.test.sh` runs the real `forge script` in a
  simulation and compares what it prints with the approved text filled in by `cast`.
- **Mutation pass** (one-off, not part of `forge test`): section 8.
- **Coverage** (`forge coverage --no-match-path "*.fork.t.sol" --no-match-contract IssuanceInvariantTest
  --report summary`; it builds without the optimizer, so the tests that pin gas numbers fail there and are
  meaningless for it): every line, statement, branch and function of `src/` is executed (2026-10-06). The
  `TransferFailed` revert after the tank transfer in `Splitter.pull()` is reached only with the tank's code
  replaced (`test_pull_ifTheTankRefused_revertsAsAWhole`): the real tank's receive hook runs within the 2,300
  gas stipend of a value transfer (`test_receive_fromTheSplitter_runsOnTheStipendAlone`), so that transfer
  cannot fail.

## 7. Sizes

`forge build --sizes --skip test --skip script` (limits: 24,576 runtime, 49,152 initcode):

| Contract | Runtime | Initcode |
|---|---|---|
| Splitter | 1,893 | 14,241 |
| KeeperTank | 3,883 | 3,940 |
| TeamRegistry | 1,861 | 2,649 |

The Splitter's initcode contains the creation code of the other two and the story text. Its creation
transaction carries 14,337 bytes (initcode plus three constructor arguments). With the socket it was 2,107 /
16,174 and 16,302 bytes.

## 8. Mutation pass

**On the first version** (2026-10-04): a hand-written list of 63 one-line mutants of `src/`, all killed. The
review then ran a wider list and found survivors; the reviewers' tests that kill them are in `test/review`
(`MutantKillers.t.sol`: `claimMaintainer()` with a gas cap, a lower `PUSH_MIN_GAS`, `sweep()` with a fixed gas
amount, `bind` through `tx.origin`; the last two went with the socket on 2026-10-06).

**On the lines changed for the review decisions** (2026-10-05): 180 mutants, each one deliberate bug, applied
one at a time to a private copy of the project; the sources here were never touched. For a Solidity mutant
the test contracts that target the file were run, and the full suite (fork tests and invariant campaign
included) if nothing failed there; a mutant counts as survived only if the full suite passes.

| File | Mutants | What was mutated |
|---|---|---|
| `src/Splitter.sol` | 55 | every story constant (percentages, supply, price, fees, date, wording, the trailing space of the head, the final full stop, a `0x` before the commit, the case of the URL); the order of the pieces and of the addresses; a non-checksummed address; `_hex` (case, nibble order, last byte, mirrored byte); the commit and the maintainer handed to the story; the `isSealed` check dropped, flipped, or read only before `createCPU`; each of the three read-backs dropped, flipped, reduced to a length comparison or compared with the wrong thing; name and symbol swapped in `createCPU`; who is passed to the registry (the Splitter, the maintainer, `tx.origin`, the factory); six of the checks that were already there |
| `src/TeamRegistry.sol` | 27 | the founder not marked, not listed, listed as the creator, with another role, with a block number for a timestamp, without its event or with a wrong one; `invite` open to anyone, flipped, open to invited wallets, checking the wrong wallet, restricted to the founder, not recording, recording the inviter, listing directly, without its event or with swapped arguments; `declare` without invitation, flipped, checking `tx.origin`, redeclaring, the two checks in the other order, the role limit, `isTeam` never set, the event index |
| `src/LaunchpadSocket.sol` | 18 + 1 | `NothingToProve` dropped, flipped, looking at `msg.value`, checked after the sweep; the first sweep not made; the empty-sweep return dropped or flipped; a failed payment not reverting; 2,300 or 50,000 gas instead of all; a call without value; paying the caller; the beneficiary not stored; no `Swept`; four of the checks that were already there. And `bind` without `payable` |
| `src/KeeperTank.sol` | 4 | `MAX_TIP` back to 0.01 gwei, 0.002 gwei, zero; the cap computed as half the base fee whatever the constant |
| `script/Ignite.s.sol` | 30 + 12 | the chain check dropped, flipped, blind to the flag; `run()` always or never a rehearsal; any maintainer, a flipped comparison, only the zero address refused, `MAINTAINER` optional; the deployer taken to be the caller; the plan's nonces and the factory's two clones swapped; a wrong story in the plan; the story comparison dropped or reduced to a length; the address comparison dropped, and each of its six terms dropped; another value or another commit in the creation; the check that the factory and the manager have code dropped or weakened. And 12 on what it prints: the story, its first 600 characters, each planned address, the commit, the order |
| `script/lib/Story.sol` | 5 | a percentage, the commit prefix, the 600, a shortened sentence, the short-story case |
| `script/ignite.sh` | 28 | each refusal dropped or weakened (untracked files, ignored source files, the fetch, the ancestry test and its direction, the RPC of a broadcast), a short or foreign `COMMIT`, an environment that wins, `REHEARSAL` passing through, a broadcast without being asked or without a simulation or without `--sender`, lax arguments, `set -e` dropped, another deployer, RPC or keystore |

**Result: 179 killed, none survived.** The remaining one does not compile against the tests and so cannot be
run: `bind` without `payable` (the tests send OKB with `bind`).

By file: Splitter 55 of 55, TeamRegistry 27 of 27, LaunchpadSocket 18 of 18 (and the one that does not
compile), KeeperTank 4 of 4, Ignite 42 of 42 (30 by `forge test`, 12 by the output test), Story.sol 5 of 5,
`ignite.sh` 28 of 28.

Three things the first run of this pass showed, and what was added:

- "COMMIT is origin/main, not HEAD" survived the wrapper's tests: where `origin/main` is ahead of `HEAD` the
  test only checked that the wrapper ran. It now checks the commit handed to forge.
- "untracked files are not looked at" died only because the test's untracked file was a `.sol` file under
  `src/`, which the second check catches. A scenario with an untracked file that is not source was added.
- A print statement cannot fail a `forge test` (`vm.expectCall` does not see the console). So the twelve
  mutants of what the script prints are run against `test/shell/ignite-output.test.sh`, which was written
  for them.

**Outside the changed lines** (2026-10-05). A third reviewer's list (195 mutants of the first version; that
review was not finished) left 29 survivors. Re-run against the current suite, six of them are now killed: the gas cap on
`claimMaintainer()`, `PUSH_MIN_GAS` at 60,000, `sweep()` with 2,300 gas, `Native.send` copying return data,
the Ignite script without its check that the factory and the manager have code, and TapeoutProbe computing the
LATCH shortfall from the NAND balance. 23 still survive, all in lines this change set did not touch:

- `KeeperTank` (7): the gas cap of the `ownerOf` probe raised to 5,000,000; `receive()` probing and
  gas-flooring addresses without code too; a failed `ownerOf` probe not checked; `_staticWord` accepting a
  short answer, or copying the whole answer into memory; the allowance, or the tank's balance, read before the
  kernel call instead of after it. These are gaps in the tests of `receive()` and of what `settleAndRefund`
  reads after `settle()`; they belong to the review of `KeeperTank` that is still owed.
- `Splitter` (5): the factory's own `protocolFee()` not checked (the mock copies it into the clone, which is
  checked); `PUSH_MIN_GAS` at 75,000 (the constant has slack for a maintainer with code); a zero maintainer
  share still pushed (dust only); the two `TransferFailed` reverts after the tank and socket transfers
  (unreachable, see Coverage in section 6).
- `Ignite` (7): the wiring checks it repeats after the creation (creator, `isCPU`, supply, price, tank wiring,
  socket wiring, no overpaid fee). The constructor enforces the first four, so the script's copies cannot
  fail; the other three read contracts that do not exist before the creation.
- `TapeoutProbe` (4): its supply-cap and tape-out-fee checks before sending, and its two checks afterwards.

Among the mutants that a single test kills, four show why that test exists: the `isSealed` check moved before
`createCPU` (`test_creation_reverts_ifTheFactorySealsItselfWhileCreating`), and the story, name and symbol
read-backs reduced to a comparison of lengths (the three sabotage cases that keep the length).

Since 2026-10-06 three of those 23 no longer exist or no longer survive: the socket's `TransferFailed` and the
script's socket-wiring check went with the socket, and the tank's `TransferFailed` is killed (S15 below). The
other 20 were not re-run; they are all in lines the 2026-10-06 change did not touch.

**On the lines changed for removing the socket** (2026-10-06): 66 mutants, the same method (each applied
alone to one of four private copies; the test contracts that target the file, then the full suite with
`--fail-fast` if nothing failed, then `test/shell/ignite-output.test.sh` for a mutant of what the script
prints; the sources here were never touched).

| File | Mutants | What was mutated |
|---|---|---|
| `src/Splitter.sol` | 42 | `TANK_BPS` 8499, 6000, 10000; `MAINTAINER_BPS` 1501, 1499, 2500, 0; in `pull()` the maintainer given the tank's share, its share rounded up, the tank's share rounded down (dust left in the Splitter), one wei kept back from the tank, a second maintainer share withheld (a phantom third payee), the tank sent the maintainer's amount, the tank's share sent to the maintainer, the tank transfer not checked, `Pulled` with swapped or wrong arguments; in the constructor the tank created before the registry, a third contract created (the socket's nonce still taken), the story given tank and registry swapped, maintainer and registry swapped, the deployer as maintainer, the deployer as registry, another commit, `Ignited` with tank and registry swapped or the deployer as maintainer, a zero maintainer silently replaced by the deployer; in the story 60% for the tank, 25% for the maintainer, the tank's purpose dropped, the head's trailing space dropped, the IgnixManager sentence put back, 60% in the allowance sentence, "plus top-ups" dropped, "Maintainer:", "; Team", `0x` before the commit, the final full stop dropped, two pieces swapped, the maintainer or the registry not checksummed, a piece repeated instead of the full stop |
| `src/KeeperTank.sol` | 4 | `ALLOWANCE_BPS` 8499, 8501 (one basis point unbacked), 6000, 10000 |
| `script/Ignite.s.sol` | 10 + 4 | the factory-code check dropped; another commit in the creation; the plan's two nonces swapped; the tank planned at the socket's old nonce 3; the planned story with tank and registry swapped; each of the five address terms of the comparison with the plan dropped. And 4 on what it prints: the planned tank not printed or printed as the registry, the created tank not printed, the planned registry printed as the tank |
| `script/lib/Story.sol` | 6 | 60% for the tank, 25% for the maintainer, 60% in the allowance sentence, the space before the bracket, maintainer and registry swapped, the IgnixManager sentence put back |

**Result: 65 killed on the first run, 1 survived, closed with a test: 66 of 66.** The survivor was S15, the
tank transfer in `pull()` without its `TransferFailed` check: the real tank cannot refuse the Splitter, so no
test reached that revert. `test_pull_ifTheTankRefused_revertsAsAWhole` now etches a refusing contract over the
tank and requires that `pull()` revert as a whole. Not run, because they are equivalent: the script creating
the Splitter, or planning the story, with the deployer instead of `MAINTAINER` (the script refuses unless the
two are equal), and the maintainer's share computed as `amount * (BPS - TANK_BPS) / BPS` (the same number).

## 9. Review findings and what was done

Two independent reviewers examined the first version on 2026-10-04 (one through the Splitter, the socket and
the registry; one through the story, sentence by sentence against the chain). Nothing that loses funds was
found. What was found, and what was decided:

| Finding | What was done |
|---|---|
| TapeOut's site shows only the first 600 characters of a story, hides every `0x` address and rewrites URLs. The first story put the splitter's address there and its trust statement near the end. | The story is restructured: a head of 579 characters (556 since 2026-10-06) that stands alone, without address or URL, then the details (section 2). |
| The repository URL was free text from `REPO_URL`: a zero-width space, a line break or any sentence went into the immutable story and passed the script's own check. | The URL is fixed text. The constructor takes no string; `EmptyRepoUrl` is gone. |
| The story said the factory was unsealed and its owner could upgrade, and nothing read `isSealed()`. Created after a seal, the processor would have carried a false sentence forever. | The constructor reverts with `FactorySealed`. |
| The constructor did not read back the story, the name or the symbol: a factory storing a cut story and another name passed every check. | All three are read back; any difference reverts with `ProcessorMismatch`. |
| "(refunds settlement gas per chip, never more than the gas spent)" is not true of the gas a caller is charged: EIP-3529 gives gas back for storage cleared inside `settle()`, 2,800 gas for each IGNIX claim or buy, and the caller ends ahead. The NatSpec and these notes said a keeper was never ahead. | The story says "up to that chip's prepaid allowance". The NatSpec, section 4 and the README say what is true. No logic change. |
| `MAX_TIP` was half of X Layer's base fee: any caller could have its tip refunded and drain a chip's allowance 1.5 times as fast, for free. | `MAX_TIP = 0.001 gwei` (5%). |
| "No key can change these payees or shares" was not literally true: TapeOut's owner can upgrade the Transistors logic and redirect proceeds before they reach the Splitter. | The story says "no key can change the splitter's payees or shares" and, in the head, "TapeOut's owner can upgrade processor logic". |
| "the team pays list price": the maintainer is the minting wallet and gets 15% of its own mints back. | The sentence is gone. |
| "Team wallets self-declare in registry": the registry was empty at creation and any stranger could list itself as team, before the team, forever. | The registry has a root: the deployer is entry 0 from the creation block; a listed wallet invites, the invited wallet declares itself. |
| `bind` was one-shot and did not check that the beneficiary could receive OKB: a bind to a guarded vault, to the registry, or to the processor's own contracts locked 25% of all proceeds forever. | `bind` is payable and makes the first sweep itself; a failed payment reverts the bind, which can be repeated. (The socket is gone since 2026-10-06, last row.) |
| A sweep of an empty escrow called the beneficiary and emitted `Swept(…, 0)`. | It returns without a call or an event. (Gone with the socket, last row.) |
| The Ignite script accepted any maintainer and any text, and printed the story only after the creation. | It refuses a maintainer that is not the deployer and a chain that is not 196, prints the plan first and compares the result with it. `script/ignite.sh` adds the git checks. |
| `.gitignore` had `lib/`, which also ignores `src/lib` and `script/lib`. | `/lib/`, `/out/`, `/cache/`. |
| Mutants that survived the first suite (a gas cap on `claimMaintainer()`, a lower `PUSH_MIN_GAS`, a fixed gas amount in `sweep()`, `tx.origin` in `bind`). | The reviewers' tests that kill them are in `test/review`. |
| 2026-10-06, not a review finding: the hackathon organiser (IGNIX) answered our question: "Please do not allocate the 25% of Transistor Mint proceeds to an IGNIX-controlled escrow. There is no need to reserve or transfer proceeds to IGNIX." | The `LaunchpadSocket` is removed, with everything that existed only for it: the IgnixManager constructor argument (constructor `(factory, maintainer, commit)`, no manager address anywhere in the deploy path), `SOCKET()`, `SOCKET_BPS`, the socket's argument in `Ignited` and `Pulled`, `MockManager`, the beneficiary mocks and the socket's tests (44 offline, 10 fork). Shares 85% tank, 15% maintainer, rounding dust to the tank; `KeeperTank.ALLOWANCE_BPS` 8500, equal to `TANK_BPS`, so every allowance from burns stays fully backed once proceeds are pulled. Third approved story: head 556 characters, tail 617, 1,366 bytes filled in. Every other constructor check is unchanged. Deployment gas 4.33M to 3.81M. Mutation pass, coverage and a rehearsal from the real deployer: sections 5, 6 and 8. |

Not part of the two finished reviews, and still owed: an independent review of `KeeperTank`, and one of the
change sets of 2026-10-05 and 2026-10-06.

## 10. How to run everything

All commands are in README.md. In short, from `contracts/issuance`:

```sh
forge install --no-git foundry-rs/forge-std@v1.17.0 OpenZeppelin/openzeppelin-contracts@v5.4.0
forge build --sizes --skip test --skip script     # sizes
forge fmt --check && forge lint                   # both clean
forge test                                        # 264 tests; fork tests need the X Layer RPC
forge test --no-match-path "*.fork.t.sol"         # offline part, 204 tests
forge test --match-path "*.fork.t.sol" -vv        # fork part, 60 tests; prints the story and the deployment gas
bash test/shell/ignite.test.sh                    # the wrapper, without any chain
bash test/shell/ignite-output.test.sh             # what Ignite prints, simulated on the live chain
```

The simulation and the broadcast: `script/ignite.sh` and `script/ignite.sh --broadcast` (README sections 3
and 4). Commands that send mainnet transactions are for the human who holds the key.

## 11. Open assumptions and risks

1. **Gas schedule.** `OVERHEAD`, `OVERHEAD_REPEAT`, `MAINTAINER_GAS`, `PUSH_MIN_GAS` and `RECEIVE_MIN_GAS`
   are constants for the gas schedule X Layer runs today. If a later fork lowers the 21,000 base cost (for
   example EIP-2780), `OVERHEAD` would over-count by up to the difference per transaction; if it raises the
   cost of storage or logs, the tank counts a little less of what a caller pays. `MAX_TIP` is 5% of today's
   base fee of 0.02 gwei; if the base fee falls, the same 0.001 gwei is a larger share of it. Nothing can be
   adjusted after deployment.
2. **TapeOut can upgrade processor logic** (stated in the part of the story its site shows). An upgrade can
   redirect mint proceeds before they reach the Splitter (`test/review/StoryClaims.fork.t.sol`). For the tank
   it means: a chip whose burn count is already stored keeps its allowance; a chip never settled is read
   through the new logic (`test_fork_tapeOutLogicUpgrade_cannotInflateAnAllowanceAlreadyFixed`). `withdraw()`
   and `ownerOf()` are also behind that upgrade key.
3. **"TapeOut's owner can upgrade processor logic" is checked through `isSealed()` only.** If TapeOut's owner
   renounced ownership without sealing, `isSealed()` would stay false and creation would go through while
   nobody could upgrade any more. The story would then overstate a risk, not hide one.
4. **Kernels.** The tank assumes `settle()` reverts when it does nothing. A kernel that returns instead lets
   anyone drain that chip's allowance at no profit to themselves. A kernel that clears storage in `settle()`
   lets its caller be refunded gas it was never charged, out of that chip's allowance (section 4). A kernel
   that pays the tank by plain transfer must forward at least 200,000 gas.
5. **L1 data fee.** X Layer is an OP-Stack chain. Its L1 fee scalars are zero today (receipts show
   `l1Fee = 0`). If they are ever raised, that fee is charged on top of execution gas and the tank, which
   cannot see it, does not refund it.
6. **Unbacked allowances before a pull.** A chip's allowance exists as soon as it is taped out; the money
   arrives with the next `pull()`. Refunds are capped by the tank's balance; anyone can call `pull()`.
7. **Unattributed backing is locked.** 85% of the price of transistors that are minted and never burned,
   rounding dust and plain donations stay in the tank with no way out. That is the design. (With the socket
   gone this share grew from 60% to 85%: more of the proceeds of transistors that are never burned stay in the
   tank for good, and none of them reaches anyone else.)
8. **The registry trusts its listed wallets.** A listed wallet can invite any wallet, and an invitation
   cannot be withdrawn. The list is as trustworthy as the least careful wallet on it, starting with the
   deployer. Role text is free: 64 bytes that are not validated.
9. **OKLink verification** was a template until the contracts existed. It was run on 2026-10-07: the three
   contracts are verified on OKLink and on Sourcify (`docs/VERIFY.md`, section 2).
10. **Addresses in the story depend on the deployer's nonce.** With nonce 0 they are the ones in section 5.
    Any transaction from the deployer before the broadcast changes them; the script then prints, and the
    processor carries, the story for the new addresses. `script/ignite.sh --broadcast` run twice would create
    two processors; nothing in the script prevents that except the uncommitted broadcast record, which makes
    the wrapper refuse until it is committed.
11. **`deployFee` or `protocolFee` can change**, and the factory can be sealed, between simulation and
    broadcast. The constructor then reverts (`WrongDeployFee`, `TapeOutFeesChanged`, `FactorySealed`) and only
    gas is lost.
12. **The maintainer address is forever.** A maintainer contract that can never receive OKB leaves its 15%
    in the Splitter (credited, claimable only towards that address). The approved maintainer is the deployer,
    an externally owned account; an EIP-7702 delegation it might add later is covered by
    `test/review/Delegated7702.t.sol`.
13. **`script/ignite.sh` takes `--account covenant-deployer` on trust.** Its broadcast path was never run by
    the agent that wrote it: that needs the key. What was run is its simulation path with the real forge, its
    refusals, the exact forge command of the broadcast path against a stub, and the same Ignite script with
    `--unlocked` on local forks.
