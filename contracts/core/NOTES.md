# contracts/core: Kernel v1, KernelFactory, Lens

The immutable recipient of an IGNIX Directed vault. The code conforms to `chips/INTERFACE.md` revision 2
(2026-10-05). It was first written against revision 1; section 7 records what was changed to reach
revision 2.

No contract here has an owner, an upgrade path or a pause. Unaudited.

**Deployed on X Layer** (2026-10-06, built from commit `b54cb86`; `deployments/xlayer.json`, `core` and `flagship`):
KernelFactory `0xAAA75144304cF81Cc7cf513F434E00980d1803ad` (its constructor created the Kernel implementation
`0x72e6EbdB444831c9511c6D1DBF07A7f68993EDF1`), Lens `0xEe63Eb34f4B7A16A188d3D14075b9bB6A8aA5ea2`, and the flagship
kernel `0xB722a4bDE4EfEe08Be938E2103d7a44C498dd356`, which holds chip 2 (the Flow Governor) under the reference
envelope with the KeeperTank as allowance payee. No token has been launched or bound yet. The on-chain runtime sizes
equal the table of section 3 (20,413, 6,312 and 15,135 bytes).

## 1. What is here

| File | Role |
|---|---|
| `src/KernelMath.sol` | `lg8`, `exp8` (binary-search msb, no CLZ), input and output word packing and byte order, `prog`/`lock`/`dt` codes, the fallback word, the routing function with clamps K1T, K2, K2C, K2L, K3, K5 and the regime (no allowance after graduation). Passes every vector of `chips/golden/vectors.json` |
| `src/Kernel.sol` | The kernel. One implementation; one clone per token (`Clones.cloneDeterministicWithImmutableArgs`) |
| `src/KernelFactory.sol` | `create` / `predict` / `isKernel` / `kernelOf` / `pinsLive`. Checks the envelope (INTERFACE section 7) and the chip, fixes the two step-gas amounts of a kernel, and deploys the Kernel implementation in its constructor |
| `src/Lens.sol` | Stateless audit views over the kernels of one factory: `replay`, `replayOn`, `replayRange`, `counterfactual`, `shadowChip`, `shadowSnapshot`, `stateMatters`, `preflight` |
| `src/lib/SafeCall.sol` | Gas-capped low-level calls with bounded return-data copies. `execCatch` also returns a bounded prefix of the revert data |
| `src/lib/TradeMath.sol` | Curve quote, largest non-graduating buy, V2 quote net of tax, impact cap, and `curveBuy`, the size of the kernel's curve buy |
| `src/interfaces/` | `IKernelV1` (INTERFACE section 10: `Record`, `Envelope`, the flags, every function), `IKernelExt` (`Globals` and four views the interface does not have: `globals`, `cumInflow`, `allowPaidCum`, `tokenSupply`), `IEvaluators` (`IFabV1`, `ISealedVM`, `ICircuits`, `IBeacon`), `IIgnix` (the IGNIX and Uniswap V2 surface the kernel touches, from `contracts/probes`) |
| `script/DeployCore.s.sol` | Deploys the KernelFactory and the Lens, with checks before and after |
| `test/mocks/` | `MockManager` (real curve arithmetic, founder round, pauses, graduation, reentrancy lock), `MockToken` (CurveOnly, tax on the pair, `pair()`), `MockVault`, `MockPair` (with Uniswap's lock), `MockRouter`, `MockWOKB`; `MockCircuits`, `MockSealedVM`, `MockFab`, `MockBeacon` and the `ChipModel` chip programs. Every mock has failure switches (revert, revert with chosen bytes, burn gas, wrong lengths, return bomb, lies) |
| `test/fixtures/fg.hex` | A fixed copy of the flagship netlist as the chip tools built it on 2026-10-04: 1,889 NAND + 64 LATCH, 13,479 bytes, keccak256 `0x2fd0e007…b2591a89` |
| `test/golden/` | Golden vectors |
| `test/unit/` | Bind and factory, curve regime, evaluator order and fallback, graduated regime, credits, gas guards, Lens, SafeCall, and the revision-2 behaviours one by one (`Rev2Gaps.t.sol`) |
| `test/fuzz/` | KernelMath properties; TradeMath against the probes' proven `CurveQuote` and against real buys on the mock Manager |
| `test/invariant/` | Handler and invariants over four kernels |
| `test/integration/` | The kernel on the real `SealedVM` (from `contracts/evaluator`) and TapeOut's own `NetlistVM` (vendored, built with via-IR in a harness), with real TAP-20 netlists |
| `test/fork/` | Everything real on an X Layer fork at block 72,369,000, and the deploy script |

Mocks live under `test/`, not `src/`, so that a deployment script sees only deployable contracts.

There is no README in this package; this file is its documentation.

## 2. How to run

```
cd contracts/core
forge install --no-git foundry-rs/forge-std@v1.17.0                # lib/ is git-ignored
forge install --no-git OpenZeppelin/openzeppelin-contracts@v5.7.0

forge build --sizes
forge test                                                         # offline: the fork tests skip
forge test --no-match-path 'test/fork/*'                           # the same without the skipped lines
FOUNDRY_PROFILE=deep forge test --match-path 'test/invariant/*'    # 256 runs x 300 calls
FOUNDRY_PROFILE=deep forge test --match-path 'test/fuzz/*'         # 20,000 runs each
XLAYER_FORK=1 forge test --match-path 'test/fork/*' -vv            # the tests create the fork
forge test --match-path 'test/fork/*' --fork-url https://rpc.xlayer.tech --fork-block-number 72369000 -vv
XLAYER_FORK=1 forge test                                           # everything
```

- solc 0.8.28, `evm_version = "cancun"`, optimizer 200 runs, `via_ir = false` for everything under `src/`,
  `bytecode_hash = "none"`.
- `test/integration/TapeHarness.sol` alone is compiled with via-IR (TapeOut's `NetlistVM` does not compile on
  the legacy pipeline). Tests deploy it with `deployCode` and never import it.
- Remappings `evaluator/=../evaluator/src/` and `tapeout/=../vendor/tapeout-xlayer/src/` are used by tests
  only. Nothing outside `contracts/core` is written.
- The fork tests skip unless the chain id is 196 or `XLAYER_FORK=1` is set. The endpoint is
  `https://rpc.xlayer.tech`, or `XLAYER_RPC_URL` if set. No transaction is ever sent and no key is used. The
  only fork-only change to live state is IGNIX's platform signer (storage slot found with stdstore), replaced
  by a throwaway key so `createToken` can be called.
- `test/golden` reads `../../chips/golden/vectors.json` (read-only `fs_permissions`).
- **The flagship chip in these tests.** `chips/out/fg.hex` is rebuilt by the chip tools, so every test that
  needs a fixed real chip reads the copy `test/fixtures/fg.hex`. Exactly one test reads the live file:
  `test_live_chip_is_a_v1_chip_both_evaluators_agree_and_it_fits_the_step_gas` (`test/integration`, offline).
  It asserts only what any build of the chip must satisfy: it is an interface-v1 chip, both evaluators give
  the same answers on it, and each runs it inside the gas a kernel gives it. It skips if the file is absent.

### Deploying

`script/DeployCore.s.sol` makes two creations: the KernelFactory (whose constructor deploys the Kernel
implementation) and then the Lens, which is given the factory's address. The processor, the Fab and the SealedVM must exist first
(`contracts/evaluator/README.md`).

```
export COVENANT_CIRCUITS=0x...     # the processor's circuit contract
export COVENANT_FAB=0x...          # the Fab deployed for that processor
export COVENANT_SEALED_VM=0x...    # the sealed evaluator
```

The other six inputs default to X Layer's contracts as the fork tests found them at block 72,369,000 and can
be overridden: `COVENANT_MANAGER`, `COVENANT_V2_ROUTER`, `COVENANT_WOKB`, `COVENANT_BEACON`, `COVENANT_IMPL0`,
`COVENANT_IMPL0_HASH`. The last two name the TapeOut circuit implementation the tests ran against; they are
not read from the live beacon.

**1. Simulate.** Sends nothing and needs no key.

```
forge script script/DeployCore.s.sol --rpc-url https://rpc.xlayer.tech
```

The script refuses any chain but 196, an input without code, a code hash that is not the pinned
implementation's, a router or WOKB that is not the Manager's, a router and Manager on different V2 factories,
and a Fab deployed for another processor. After the creations it reads everything back from the factory. It
prints every input, the three new addresses with their code sizes, the step-gas constants, and whether
TapeOut's live implementation is still the pinned one (`pinsLive`). If it is not, the script still deploys
and says that every kernel of this factory will run on the sealed evaluator from its first settle.

**2. Broadcast.** Run by the wallet holder only.

```
forge script script/DeployCore.s.sol --rpc-url https://rpc.xlayer.tech \
  --account <keystore-name> --sender <deployer-address> --broadcast --slow
```

The addresses are printed and saved in `broadcast/DeployCore.s.sol/196/run-latest.json`. Rehearsed against a
local fork of X Layer (`anvil --fork-url`, with a processor, a Fab and a SealedVM created there first), the
two creations used 5,910,278 gas (the KernelFactory, with the Kernel implementation) and 3,037,459 gas (the
Lens); `forge script` estimates 11.6M for the pair, and its estimate carries a margin. Nothing was sent to
X Layer, and the local records were deleted.

**3. Check from a terminal.**

```
RPC=https://rpc.xlayer.tech
cast call <KernelFactory> "pinsLive()(bool)" --rpc-url $RPC
cast call <KernelFactory> "kernelImpl()(address)" --rpc-url $RPC
cast call <KernelFactory> "fab()(address)" --rpc-url $RPC
```

Verification on OKLink follows the pattern of `contracts/evaluator/README.md` (its step 3). It was run on
2026-10-07 for every Covenant contract, on OKLink and on Sourcify (`docs/VERIFY.md`, section 2). The KernelFactory's constructor arguments are the values the script prints under
"inputs", in that order, without the three lines that are only information (the processor's transistor
contract, its circuit count, and the beacon's implementation now); the Kernel implementation and the Lens
have none.

## 3. Results

Last full run: 2026-10-06, forge 1.8.3, solc 0.8.28.

```
$ XLAYER_FORK=1 forge test
Ran 17 test suites: 309 tests passed, 0 failed, 0 skipped
$ forge test                       # no fork: the 29 fork tests skip
Ran 17 test suites: 280 tests passed, 0 failed, 29 skipped
```

| Suite | Tests | What |
|---|---|---|
| `test/golden/Golden.t.sol` | 22 | every vector of the `covenant-golden/2` file. Revision 1's sets: lg8 3,623, exp8 1,024, inputs 64, outputs 60, routing 400, prog 80, lock 30, dt 18, state 6, fallback 3, layout tables, clamp bits. The `revision2` sets: routing edge cases 67, routing after graduation 120, impactCap 60, maxNonGraduatingBuy 84, curveOut 54, curveBuy 80 (through `TradeMath.curveBuy`, the function `Kernel._curveLeg` calls), v2NetOut 60, edge cases of lg8, prog and lock 6 each, the fallback word after graduation 1 |
| `test/fuzz/KernelMath.t.sol` | 17 | 1,000 runs each by default, 20,000 with `FOUNDRY_PROFILE=deep` |
| `test/fuzz/TradeMath.t.sol` | 13 | same; against the probes' `CurveQuote` and real buys on the mock Manager |
| `test/unit/BindFactory.t.sol` | 26 | |
| `test/unit/SettleCurve.t.sol` | 47 | includes two fuzzed sandwich tests |
| `test/unit/Evaluator.t.sol` | 23 | |
| `test/unit/Graduated.t.sol` | 30 | includes a fuzzed V2 sandwich test |
| `test/unit/Credits.t.sol` | 9 | |
| `test/unit/Gas.t.sol` | 23 | gas-limit sweeps across each guard, up to 3,000 points each |
| `test/unit/FailureMatrix.t.sol` | 11 | every combination of the failure switches: 4,320 on the curve, 5,400 after graduation |
| `test/unit/Lens.t.sol` | 23 | |
| `test/unit/Rev2Gaps.t.sol` | 21 | the behaviours revision 2 added, section by section (`test_rev2_<section>_*`) |
| `test/unit/SafeCall.t.sol` | 7 | `execCatch` |
| `test/integration/RealEvaluators.t.sol` | 7 | real SealedVM, TapeOut's NetlistVM, real netlists; the one test on the live chip file |
| `test/invariant/Invariants.t.sol` | 1 | eight invariants in one campaign: 64 runs x 100 calls (6,400 calls, 0 reverts); deep profile 256 runs x 300 calls (76,800 calls, 0 reverts, 10 to 20 minutes) |
| `test/fork/KernelFork.t.sol` | 25 | live IGNIX and TapeOut at block 72,369,000 |
| `test/fork/DeployCore.fork.t.sol` | 4 | the deploy script, inside the fork |

With `FOUNDRY_PROFILE=deep` the 21 fuzz tests of `test/fuzz` ran 20,000 times each and passed (2026-10-05).

Invariants (after every call): no violation recorded by the handler's before/after checks (routes of value,
one settle per epoch, the gas limit never changes an outcome, a held reentrancy lock never changes an outcome,
a funded settle never reverts outside the grace period, `Lens.replay` on both evaluators for every record);
balance covers credits, reserve and locked tokens; only the allowance payee and the sink hold credits; the
allowance payee never holds a credit in the project token; lifetime allowance within `allowCumBps`; records
in strictly increasing epochs; chip NFT and configuration never change; the regime latch is monotone. After
every run (`afterInvariant`): with faults lifted, every credit can be withdrawn, locked tokens reach `0xdEaD`,
the native pot is spent, and the token reserve leaves at the floor rate or faster.

```
$ forge build --sizes
| Kernel        | 20,413 runtime | 20,513 initcode | 4,163 below the 24,576 limit |
| KernelFactory |  6,312 runtime | 28,119 initcode (it deploys the Kernel implementation) |
| Lens          | 15,135 runtime | 15,322 initcode |
```

**Mutation pass over the revision-2 changes.** 128 small changes were made one at a time to a copy of the
sources: KernelMath 4, Kernel 65, KernelFactory 23, Lens 7, TradeMath 8, SafeCall 5, and the deploy script 16
(each new condition deleted, inverted or moved by one, each new argument or constant changed, each guard of
the script removed). Each was run against the offline suites, then the gas sweeps and the failure matrix, the
invariant campaign and the fork suites, stopping at the first failure. Every one makes at least one test fail.
Seven of them needed tests the first round did not have, and those tests were added: the `NativeSwept` amount
after a partial refund, the gas guard of the pair-lock probe, `curveBuy` with an amount that buys nothing,
with nothing decided on a degenerate curve and with fees other than 100 + 100, the swap's minimum output, and
the gas cap of `execCatch` seen from inside the callee. Two changes were not counted because no behaviour can
tell them apart from the code: `>=` for `>` in the drain bound (equality needs `floorRel` 89 or 178 and an
`epochLen` of at least 1,296,000 s, which check 2 refuses), and swapping the two arguments of `_minSettleGas`,
which is symmetric in them. (The three fixes of section 7's last part came after this pass; each has its own
tests.)

## 4. Decisions

**Configuration is bytecode.** A clone's immutable arguments are `abi.encode(Globals, Envelope)`: the Manager,
router, WOKB, factory, Circuits, Fab, SealedVM, beacon, pinned implementation and code hash, snapshot pointer,
netlist hash, chip id, `nState`, `gateCount`, netlist length, the two step-gas amounts, then the envelope. No
storage slot holds configuration and no function writes any. The implementation itself refuses every entry
point (`OnlyClone`).

**Every external dependency is called through `SafeCall`.** Gas-capped, low-level, return data bounded,
decoded by hand. High-level calls are used only in `bind`, where a revert is the right answer. Consequences:
a reverting, lying or gas-burning Manager, vault, token, pair, router, beacon or evaluator becomes a flag;
a 1 MB return blob is not copied; the ABI decoder never runs on a value path.

**Gas.** Each kind of call gets a fixed allowance (`G_VIEW` 100k, `G_NETLIST` 500k, `G_CLAIM` 200k, `G_BUY`
500k, `G_TRANSFER` 200k, `G_SWAP` 700k; TapeOut's step `stepFloor`, the sealed step `sealedFloor`). Before
each call `_needGas` reverts the whole settle unless `gasleft() >= g + g/63 + 20,000`, so the callee always
receives its full allowance and its success or failure is the same for every caller. `settle` also checks the
whole budget once at the top. The budget counts both evaluators, because the costliest settle is one in which
TapeOut's step uses up its gas and fails and the sealed evaluator then answers, and 15 view-sized calls (14
on the longest path, which includes the pair-lock probe after a failed swap, plus one). `minSettleGas()` adds
two 64/63 factors (the clone's call into the implementation, and one calling contract such as the KeeperTank)
and the transaction base cost.

**Step gas.** The factory fixes both amounts when it creates a kernel, from the chip's counts as the Fab
recorded them: `200,000 + 2,600 * gateCount + 800 * nState` for TapeOut's evaluator and
`40,000 + 200 * nNand + 400 * nState` for the sealed one (`nNand = gateCount - nState`). Section 5 has what
each needs for every chip shape measured.

**Inflow is `balance - books`.** `free = balance - credits - (locked tokens, after graduation)`,
`reserve0 = min(reserve, free)`, `inflow = free - reserve0`. The amount a claim reports is never used. The
kernel's own buy tax returns through the vault and is inflow like any other.

**`receive()` accepts the vault only inside the kernel's own claim, and the Manager only inside its own
`buyTo`.** One transient address (`_payer`) is set around those two calls. Chosen over "accept the vault and
the Manager at any time" because: (a) it is the stronger form of "nobody can send money into a kernel that
buys": IGNIX's refund and payout paths (a third party's `claimFor`, a curve sell with the kernel as payee, a
crossing `buyTo` with the kernel as recipient, a router sell to the kernel) all fail; (b) nothing is lost by
it: a refused `claimFor` reverts `TransferFailed` and the tax waits in the vault for the next settle; the
platform's own daily push moves project tokens only and cannot be gated anyway; (c) `receive()` becomes one
`TLOAD` and a compare. The router and WOKB are not accepted at all: the exact-in swap never returns native
OKB (`contracts/probes/FINDINGS.md`, section 7). What cannot be refused: OKB sent to the vault itself, forced
transfers, and tokens sent to the kernel after graduation. All three are routed like tax.

**Locked tokens.** `lockedTokens` is the sum of balance deltas around the kernel's own `buyTo` calls. They
are never inflow and never reserve. Before graduation they cannot move (the token reverts `CurveOnly`, and
the kernel has no `approve`, `sell`, `transfer` or generic call path). After graduation `burnLocked()`,
callable by anyone, sends them to `0xdEaD`. It is separate from `settle` so that a failing transfer can never
block a settlement. `LOCK` counts `lockedTokens + burnedTokens` over the supply read at bind, so it does not
move when they are burned.

**Graduation** is latched by the first settle in which the token itself reports a pair
(`IgnixToken.pair() != address(0)`, read through `SafeCall`). `pair` is the address it reported. A read that
fails, returns fewer than 32 bytes or burns its gas neither sets nor clears the latch; the Manager's
`pairOf` is not consulted. The token becomes the regime asset; `reserve`, `cumInflow` and `allowPaidCum`
restart at zero; the OKB beyond credits is the native pot. Tokens that reached the kernel on the curve
through someone else's `buyTo` are not locked tokens and count as inflow in that first settle.

**No allowance after graduation.** `KernelMath.route` takes the regime. After graduation the `T_ALLOW` share
joins the reserve share, `allow` is 0 and none of K2, K2C, K2L is evaluated; no clamp bit records it. The
same holds for the fallback word. The allowance payee can therefore never hold a credit in the project
token.

**Evaluator order** on every settle. The pins hold when `beacon.implementation()` is the pinned address, its
code hash is the pinned hash, `Circuits.circuitInfo(chipId)` is exactly `(96, 112, nState, gateCount)` and
`keccak256(Circuits.netlist(chipId))` (with the pinned length) is the pinned hash. While they hold, TapeOut's
`step` is asked; if it fails for any reason (revert, out of its gas, an answer of the wrong size or shape)
the sealed evaluator is asked before the beat counts as failed. When they do not hold, the sealed evaluator
is asked directly and TapeOut's is not asked at all. Flag 2 is set exactly when the sealed evaluator's answer
is the one used; a settle in which both failed and the fallback word applied carries flag 1 and not flag 2.
`evaluator()` reports what the next settle would ask first.

**Step failure.** `lastStepEpoch` is the epoch of the last persisted step (0 at bind). A beat fails only if
no evaluator answers. While `epoch - lastStepEpoch < fallbackEpochs` such a settle reverts (`StepFailed`).
Afterwards the same settle applies the fallback word, leaves the state and `lastStepEpoch` alone and sets
flag 1; `DT` keeps counting from the last persisted step.

**Curve buy.** Skipped (flag 16) when the curve cannot be read, while `snipeBpsNow > 0`, while
`founderRound(token).endsAt > now` (read before the call), or when the Manager reverts `FounderOnly` or
`Paused`. `amount = min(buyDecided, impactCap, maxNonGraduatingBuy)` (flag 128 when shrunk); skipped if it
buys zero tokens. `minTokensOut` is the exact quote. `impactCap = vQuote * ((buyFee + sellFee) * 256 +
(taxBuy + taxSell) * (256 - capT)) / (256 * 4 * 10000)`, with the two fees read from the Manager in the same
settle (100 + 100 today, the interface's `F = 200`). The whole sizing is one library function,
`TradeMath.curveBuy`, which the golden test calls directly.

**Native leg after graduation.** `amount = min(pot, impactCap(WOKB reserve, 25, taxBuy, taxSell, capT))`,
`swapExactETHForTokensSupportingFeeOnTransferTokens{value}(minOut, [WOKB, token], 0xdEaD, now)`, `minOut` =
99% of the exact quote net of the buy tax. The fee part is 25 bps, not 60: the pair's liquidity is locked in
IGNIX's V2 locker, which pays the token creator part of the LP fee, so only the part no trader can recover is
counted (IGNIX documents 0.125% per side). The 1% slack exists only so that a one-wei difference in the token's
tax rounding can never block the exit; sandwich protection is the cap. If the Manager cannot be read the cap
uses zero tax (smallest cap) and the minimum output assumes the maximum tax (10%). `Record.nativeIn` is the
OKB the swap really spent, measured by balance; the `NativeSwept` event carries the same number.

**A buy that fails under the callee's reentrancy lock reverts the settle** (`LockHeld`); every other failure
of a buy stays a flag. The epoch is not consumed and nothing else of that settle persists.

- On the curve: `IgnixManager.buyTo` reverts with `ReentrancyGuardReentrantCall()`, recognised like the
  Manager's other errors by its selector, `0x3ee5aeb5`, the first four bytes of the revert data. The live
  Manager returns exactly those four bytes to a `settle()` called from the `receive()` of a contract it is
  paying, for instance the seller in a zero-token `sell`.
- After graduation there are two signs, and either is enough. First, the router's revert data is
  `Error("UniswapV2: LOCKED")`, decoded as a string: selector, offset 32, length 17 and the 17 bytes are
  compared; the padding after them is not, and revert data shorter than the 100 bytes of that encoding is
  never a match. Second, after any failed swap the kernel asks the pair itself by a static call to
  `sync()`: with the lock held it reverts with that same string before doing anything else; without it, it
  fails at its first storage write and returns no data. The second sign is needed because the first can be
  avoided: a flash swap that borrows more WOKB than the kernel's buy brings makes the live router fail
  earlier, on its own arithmetic (`ds-math-sub-underflow`), without ever reaching the pair's lock. The probe
  is made only after a failed swap, costs one view allowance, and can change nothing: a pair whose lock is
  free can only answer "not locked".
- A settle that makes no buy call (nothing to buy, buys disabled, a guard skipped it) is unaffected by either
  lock and writes the record it would write anywhere.

**Flag 32** is set when a buy or burn call fails, and also when it succeeds but moves less than it was sent:
the Manager refunds part of a curve buy, the router does not spend all of the swap's value, or the burn
transfer moves less than the amount. Flag 128 keeps meaning "a cap made the amount smaller than decided".

**Buys must be enabled.** The factory refuses an envelope with `buyEnabled = false` (`BadEnvelope(13)`),
whatever its `sink`. With buys disabled, every amount that would be bought or burned is credited to `sink`
instead, so the sink is a second payee outside the allowance limits of INTERFACE section 7 (guarantee 1): an
independent review showed a sink that is the allowance payee, or any second wallet of the launcher, taking
97.9% of inflow. Tax-funded kernel buys are allowed, so kernel v1 does not need the mode. The kernel's code
for it is unchanged and unreachable through this factory; tests still exercise it on clones made outside
the factory (`_cloneOutsideTheFactory` in `test/Base.t.sol` and `test/fork/ForkBase.sol`).

**Bind** succeeds once, for a token whose Directed vault names this kernel as recipient, with native OKB as
quote, a non-zero tax on at least one side, and the chip NFT in the kernel. Either the token's creator is the
envelope's launcher, and then anyone may call, or the caller is the launcher, so that a token launched from
the wrong wallet can still be bound by the launcher. An untaxed token is refused because it graduates to
Uniswap V4, where this kernel has no exit for native OKB.

**Factory.** The envelope checks are those of INTERFACE section 7, check for check (`BadEnvelope(1..15)`;
13 is "buys disabled").
Beyond the interface: the Fab's snapshot must be an SSTORE2 pointer whose bytes hash to the recorded hash;
`nState` 1..256 and `gateCount` <= 3,400 are re-checked; if the Fab exposes `CIRCUITS()` it must be the
factory's processor; `create` is idempotent (a front-runner changes nothing). The pinned implementation and
code hash are constructor constants, not a reading of the live beacon; `pinsLive()` tells a deploy script
which case it is in.

**Records** are 7 storage slots. The sixth and seventh hold the regime totals after the settle (`cums(n)`),
which make any single record replayable without walking the history; the seventh also holds `nativeIn`.

**Lens** reads only kernels its factory made: it takes the KernelFactory as a constructor argument and every
function that takes a kernel address reverts `NotKernel` unless `factory.isKernel(kernel)`. (An independent
review showed a contract forwarding every call to a real kernel replaying as `ok`; such a contract could
equally lie.) It steps each evaluator with exactly the gas a kernel gives it, so "replays" also means "fits
its gas", by a gas-capped static call whose answer it decodes by hand like the kernel, so a malformed answer
is `ran = false` and never makes a Lens function revert. It routes with the record's own regime. `shadowChip` and `shadowSnapshot` run a chip that is not the
kernel's with the gas TapeOut's evaluator gets for the largest chip the factory accepts. Range functions stop
early when gas runs low and return where to continue.

## 5. Verified facts

Measured on an X Layer fork at block 72,369,000 (`test/fork`, `-vv` prints them):

| What | Gas |
|---|---|
| `settle`, Flow Governor, on the curve: first funded epoch (claim, step, credit, buy) | 5,130,465 |
| `settle`, Flow Governor, largest of 20 settles on the live curve | 5,131,758 |
| `settle`, Flow Governor, first graduated epoch (two claims, step, burn, V2 swap) | 5,165,821 |
| `settle`, Flow Governor, pins not holding: sealed evaluator only | 736,736 |
| `settle`, Flow Governor, TapeOut's step failing at once, sealed evaluator answering | 832,420 |
| `settle`, synthetic 2,200-gate chip: first funded epoch / steady state / sealed | 5,708,635 / 5,583,734 / 779,059 |
| `minSettleGas()`: Flow Governor / 2,200 gates, 64 latches / 3,400 gates, 256 latches | 10,665,941 / 11,390,999 / 15,114,841 |
| `Circuits.step` through the beacon proxy, gas used: Flow Governor / 2,200 gates / 3,400 gates | 4,498,542 / 5,070,369 / 7,883,927 |
| `SealedVM.step`, gas used: same three chips | 326,309 / 366,987 / 574,382 |
| `Circuits.netlist`: Flow Governor (13,479 bytes) / 23,032 bytes (no copy) | 88,677 / 140,355 |
| `tokens` / `snipeBpsNow` / `beacon.implementation` / `circuitInfo` / `token.balanceOf` | 20,430 / 13,774 / 5,287 / 17,959 / 9,908 |
| `IgnixToken.pair()`, the latch read (the Manager's `pairOf`, no longer read: 13,257) | 5,430 |
| `pair.sync()` by static call, lock not held (it uses up its allowance; with the lock held it answers in under 1,000) | 103,023 |

`minSettleGas()` is a budget for the worst case, about twice what a settle uses: it must cover a settle in
which TapeOut's step burns everything it is given and the sealed evaluator then runs. The largest chip the
factory accepts needs a gas limit of 15.1M.

Through the KeeperTank (`contracts/issuance`), figures from the independent review of 2026-10-06, not
measured in this package: a settle whose refund is the first the tank pays for a chip needs about 400,000
gas above `minSettleGas()` (the tank scans the chip's netlist once), and `withdrawCredit` with the tank as
payee needs about 230,500 gas; with less it reverts and the credit stays where it was.

Leg costs (claim, `buyTo`, transfer, router buy) are in `contracts/probes/FINDINGS.md` section 9; the
allowances above are more than three times each.

**Step gas by chip shape.** The least gas each evaluator must be *given* for its `step` to succeed, found by
bisection against the live TapeOut implementation and the real SealedVM, at the all-ones state with all-ones
inputs, after the kernel's four comparisons (`test_fork_step_gas_by_chip_shape_at_all_ones`). "Given" is what
the factory fixes for that chip.

| Shape | Gates | TapeOut needs | given | | Sealed needs | given | |
|---|---|---|---|---|---|---|---|
| 1 latch + 113 NAND | 114 | 353,118 | 497,200 | 71% | 27,917 | 63,000 | 44% |
| 1 latch + 299 NAND | 300 | 778,422 | 980,800 | 79% | 57,091 | 100,200 | 56% |
| 64 latches + 536 NAND | 600 | 1,495,927 | 1,811,200 | 82% | 109,653 | 172,800 | 63% |
| 112 latches, no NAND | 112 | 453,834 | 580,800 | 78% | 40,852 | 84,800 | 48% |
| 256 latches, no NAND | 256 | 884,768 | 1,070,400 | 82% | 80,629 | 142,400 | 56% |
| 64 latches + 2,136 NAND | 2,200 | 5,160,329 | 5,971,200 | 86% | 361,275 | 492,800 | 73% |
| 256 latches + 3,144 NAND | 3,400 | 8,009,642 | 9,244,800 | 86% | 567,958 | 771,200 | 73% |
| Flow Governor (the fixture) | 1,953 | 4,595,209 | 5,329,000 | 86% | 322,521 | 443,400 | 72% |

Every shape leaves 13% or more of TapeOut's amount and 26% or more of the sealed one unused; the test
asserts 10% and 20%. `contracts/evaluator` measures the corners of INTERFACE section 2 on chips built for the
worst data-dependent cost (its README, "What a kernel must give `step`"): the highest ratios there are 87.4%
and 75.5%. `Lens.preflight(kernel)` reports both evaluators against both amounts for any chip before a token
is launched.

Other facts the code relies on, each with a test:

- TAP-20 state is `ceil(nState / 8)` bytes; the kernel passes 32 and requires exactly that many back
  (`test_state_is_stored_right_padded_and_passed_back`, `test_every_malformed_answer_is_a_failure`).
- The live vault reverts `TransferFailed` when the kernel refuses a push
  (`test_fork_third_party_native_claimFor_is_refused_and_tax_waits`).
- The live Manager delivers exactly `TradeMath.curveOut` (`test_fork_curve_epoch_claim_step_buy`), and
  `TradeMath` equals the probes' fork-proven `CurveQuote` on every fuzzed input (`test/fuzz/TradeMath.t.sol`).
- The live router delivers exactly `TradeMath.v2NetOut` to `0xdEaD` during and after the protection window
  (`test_fork_forced_graduation_then_token_regime`, `test_fork_swap_after_the_protection_window`).
- A real TapeOut upgrade (pranked as the factory's owner) flips the kernel to the sealed evaluator and back,
  and the records written under each replay on the other
  (`test_fork_tapeout_upgrade_switches_to_sealed_and_back`).
- With the pins unchanged and the live `step` made to fail, the sealed evaluator answers in the same settle
  (`test_fork_sealed_evaluator_answers_when_the_live_step_fails_under_unchanged_pins`).
- IGNIX's BUY pause skips the buy; its DIVIDEND pause fails the claim only
  (`test_fork_ignix_buy_pause_skips_the_buy`, `test_fork_ignix_dividend_pause_fails_the_claim_only`).
- The live Manager's lock: a `settle()` called from the `receive()` of the seller in a zero-token
  `IgnixManager.sell` reverts with `LockHeld`, the epoch is not consumed, and the same settle outside the
  callback buys. The Manager's revert data is exactly `0x3ee5aeb5`. The lock can be taken through any live
  token, not only the kernel's own
  (`test_fork_settle_from_inside_a_manager_call_reverts_and_keeps_the_epoch`,
  `test_fork_the_managers_lock_can_be_held_through_any_live_token`).
- The live pair's lock: a `settle()` called from `uniswapV2Call` during a flash swap reverts with `LockHeld`
  for a loan of 1 wei of WOKB (the router passes on `UniswapV2: LOCKED`) and for a loan of 10 WOKB (the router
  fails with `ds-math-sub-underflow` and the probe finds the lock); the same settle outside the callback
  swaps (`test_fork_settle_from_inside_a_flash_swap_reverts_and_keeps_the_epoch`). Outside any callback the
  probe says "not locked" (`test_fork_pair_lock_probe_outside_a_callback`).

Where the inflow rules of INTERFACE section 8.1 and the requirements of section 9.4 are tested:

| Rule | Test |
|---|---|
| a third party calls `claimFor` before settle on the curve | `test_inflow_thirdPartyClaimForBeforeSettle_onCurve`, fork: `test_fork_third_party_native_claimFor_is_refused_and_tax_waits` |
| tokens pushed after graduation without any claim by the kernel | `test_inflow_tokensPushedAfterGraduationWithoutClaim`, `test_tokens_sent_straight_to_the_kernel_are_inflow_too`, fork: end of `test_fork_forced_graduation_then_token_regime` |
| a claim reverts but the balance already arrived | `test_inflow_claimRevertsButBalanceAlreadyArrived`, `test_token_claim_failure_is_a_flag_and_arrived_tokens_are_routed` |
| locked tokens are not re-counted at graduation | `test_inflow_lockedTokensAreNotRecountedAtGraduation` |
| inflow is `balance - accounted` | `test_inflow_is_balance_minus_accounted_not_the_claim_amount` |
| no fallback, no `token0()` / `token1()` / `fee()` | `test_kernel_has_no_fallback_and_answers_no_pool_probe`, fork: `test_fork_kernel_does_not_look_like_a_pool` |
| no token exit before graduation | `test_bought_tokens_cannot_leave_before_graduation`, `test_burnLocked_only_after_graduation` |

## 6. Open assumptions

- The IGNIX token and the Directed vault are not verified on OKLink. The kernel never trusts their return
  values (balances are measured), but it does assume `balanceOf`, `transfer`, `pair()` and `claim(asset)` keep
  their selectors. The token is not upgradeable.
- `V2_ROUTER02` trades on the pair the token reports (same factory and init code hash; true on the fork). If
  it did not, the swap would fail for every caller and the native pot would wait.
- The creator's share of V2 LP fees is at most half of the 0.25% that goes to LPs. If IGNIX ever rebated more
  than that, the 25 bps in the native leg's cap would be too high.
- TapeOut's step cost stays below what a kernel gives it. An upgrade changes it only together with the code
  hash, and then the sealed evaluator is asked directly; and if TapeOut's step ever fails for lack of gas
  under unchanged pins, the sealed evaluator answers in the same settle.
- The lock rule cannot tell a held lock from a Manager that always answers `ReentrancyGuardReentrantCall()`
  to `buyTo`. An IgnixManager upgraded to do that would make every curve settle that has a buy to make
  revert for as long as it did so, instead of flagging the buy and going on; the tax would wait in the vault.
  The same holds for a pair whose `sync()` always reverts with `UniswapV2: LOCKED`; a Uniswap V2 pair is not
  upgradeable.
- No token with a Directed vault and native OKB as quote had graduated on X Layer at the fork block
  (`contracts/probes/FINDINGS.md`, section 1). The graduated regime is tested on the fork by graduating a
  token launched there through the live Manager (`test_fork_forced_graduation_then_token_regime`), not on
  one that graduated on the chain.
- All gas figures are from Foundry's EVM at one pinned block.

## 7. What was changed for revision 2

Each row names the item of INTERFACE section 14, what was changed and where, and the tests that hold it.
Rows marked "none" already behaved as revision 2 says.

| Revision 2 (section 14) | Change | Tests |
|---|---|---|
| Inflow defined by balance; `PROG`, `LOCK`, `DT`, `GRAD` on failure paths | none | section 5; `test_golden_rev2_edges_lg8_prog_lock`, `test_golden_rev2_routing_boundary` |
| No allowance after graduation | `KernelMath.route` takes the regime: after graduation the `T_ALLOW` share joins the reserve share and K2, K2C, K2L are not evaluated. `Kernel.settle` passes it; `Lens._checkRecord`, `_cfOne` and `_shadowOne` route with the record's regime | `test_golden_rev2_routing_graduated`, `test_golden_rev2_fallback_graduated`, `testFuzz_route_graduated_pays_no_allowance`, `test_rev2_8_2_*`, `test_no_token_allowance_ever_accrues`, `test_lens_across_graduation`, invariant `_inv_no_token_allowance` |
| Envelope limits | `KernelFactory._checkEnvelope`: `epochLen` 300..86400, `capT <= 128`, `allowCumBps <= 5000`, `floorMin` 1..425, and `epochLen * 178 <= 2592000 * floorRel` (`BadEnvelope(15)`) | `test_envelope_checks`, `test_envelope_edges_that_must_pass`, `test_drain_bound_halves_the_reserve_within_30_days_and_one_epoch`, `test_rev2_7_*` |
| A buy that fails under the callee's reentrancy lock reverts the settle | `Kernel._execCurveBuy` reverts `LockHeld` on the Manager's `0x3ee5aeb5`. `Kernel._swap` (new, the router call moved out of `_nativeLeg`) reads up to 100 bytes of revert data with `SafeCall.execCatch` (new) and reverts `LockHeld` if `_lockedError` decodes `UniswapV2: LOCKED` or `_pairLockHeld` finds the pair's lock held. `N_VIEWS` 14 to 15 for the probe | `test_rev2_8_6_*` (12 tests: both attacks on mocks, any loan size, each sign alone, gas sweeps under each lock, settles without a buy call), `test_swap_revert_data_is_decoded_as_a_string`, `test_pair_lock_probe_*`, `test/unit/SafeCall.t.sol`, the six fork tests about the two locks, invariant actions `settleInsideManager` and `settleInsidePair` |
| `receive()` gated to the kernel's own claim and buy | none | `test_receive_refuses_*`, `test_fork_plain_transfers_are_refused` |
| State is a byte string; a wrong-sized answer is a failure | none | `test_state_is_stored_right_padded_and_passed_back`, `test_every_malformed_answer_is_a_failure` |
| Buy sizing | The curve buy's sizing moved, unchanged, into `TradeMath.curveBuy` so that the golden test runs the code the kernel runs. `F` is still `buyFeeBps + sellFeeBps` as the Manager reports them | `test_golden_rev2_impactCap`, `_maxNonGraduatingBuy`, `_curveOut`, `_curveBuy`, `_v2NetOut`; `testFuzz_curveBuy*`; `test_impact_cap_uses_the_fees_the_manager_reports` |
| Graduation | The latch reads `IgnixToken.pair()` and stores what it returned; `IgnixManager.pairOf` is no longer read | `test_latch_reads_the_token_and_ignores_the_managers_pairOf`, `test_token_pair_unreadable_keeps_the_curve_regime_without_reverting`, `test_latch_is_never_cleared`, `test_rev2_9_2_*` |
| ABI | `Record.nativeIn` (the record's seventh slot), returned by `records(n)`. Flag 32 also when a buy or burn moved less than it was sent. `bind` also accepts the launcher as caller for a token another wallet created. Every function of section 10 is declared in `IKernelV1` | `test_rev2_10_*`, `test_bind_by_the_launcher_*`, `test_swap_that_spends_less_than_it_was_sent_is_flagged`, `test_refund_from_the_manager_inside_own_buy_is_accepted_and_accounted`, `test_native_pot_is_drained_to_zero_over_time` |
| Fab: `manifestHash`, `tapeoutChipTo` | Wording of `IEvaluators.sol` only; the kernel and the factory call `isChip` and `chipInfo`, whose selectors did not change | |
| Sealed evaluator: four comparisons, and asked whenever TapeOut's step fails | The comparisons were there. New in `Kernel.settle`: TapeOut's `step` is asked while the pins hold and the sealed evaluator is asked if it fails; flag 2 means the sealed answer was used | `test/unit/Evaluator.t.sol` (23 tests), the evaluator dimension of `FailureMatrix.t.sol`, `test_replay_a_record_the_sealed_evaluator_answered_after_tapeout_failed`, `test_flow_governor_same_records_when_tapeouts_step_fails`, fork: `test_fork_sealed_evaluator_answers_when_the_live_step_fails_under_unchanged_pins` |
| Gas: the step gas covers every chip shape | `KernelFactory._args` computes `stepFloor` with a latch term and a new `sealedFloor`; `Globals` gained `sealedFloor`; `Kernel._step` gives each evaluator its own amount; `_minSettleGas` and the first check of `settle` count both. `Lens` follows (`Preflight.sealedFloor`, `SHADOW_GAS`) | `test_step_gas_formulas`, `test_each_evaluator_gets_its_own_fixed_gas`, the sweeps of `Gas.t.sol`, `test_first_check_counts_both_evaluators`, `test_minSettleGas_formula`, `test_replay_gives_each_evaluator_its_own_gas`, fork: the table of section 5 |

**What other packages have to follow.** Two shapes changed: `Globals` has a new last field `sealedFloor`
(so the immutable arguments of a clone are one word longer and `globals()` returns one more word), and
`Record` has a new last field `nativeIn` (so `records(n)` returns 14 words). `Lens.Preflight` has a new field
`sealedFloor` after `stepFloor`. Anything that decodes these by hand has to be updated. No selector of
`IKernelMin` or `IKernelV1` changed and the `Settled` event is the same.

**Where the code goes beyond what the interface says.** INTERFACE revision 2 as it stands on 2026-10-06
describes the lock rule with both signs (8.6), the step-gas margins (2), the drain bound (7, guarantee 3),
the launcher row (7), `evaluator()` and flag 32 (10) and the lock case of 8.3 as this code does. What is left:

- Section 9.3 still describes kernels with buys disabled ("With `buyEnabled` false, every amount the tables
  above send to a buy or a burn is credited to `sink` instead ..."), and the `Envelope` comments of section 7
  still describe `sink` as a payee. This factory refuses such envelopes.

**Fixes after the independent review of 2026-10-06** (it found no defect in Kernel, KernelMath, TradeMath,
SafeCall, Fab or SealedVM; 24,007 settle attempts against an independent model, 0 mismatches):

| Fix | Change | Tests |
|---|---|---|
| Buys disabled refused | `KernelFactory._checkEnvelope`: `if (!e.buyEnabled) revert BadEnvelope(13)` | `test_envelope_checks` (sink zero, a third address, the allowance payee, the launcher); every buys-disabled test now runs on a clone made outside the factory |
| The Lens reads its factory's kernels only | `Lens` takes the factory in its constructor (`FACTORY`); modifier `onlyKernel` on every function that takes a kernel; `DeployCore.s.sol` passes it and reads it back | `test_every_entry_point_refuses_a_kernel_the_factory_did_not_make` (a forwarding fake kernel and an empty address, ten entry points), the deploy-script fork tests |
| A malformed answer cannot revert the Lens | `Lens._step`: `SafeCall.staticRead` with 256 bytes at most, decoded by hand as in `Kernel._step` | `test_a_malformed_answer_is_reported_and_never_reverts` (nine failure modes, both evaluators: `replayOn`, `preflight`, `stateMatters`, `shadowChip`, `shadowSnapshot`) |
