# Covenant evaluator: `Fab` and `SealedVM`

A Covenant kernel routes a token's tax by the output of a circuit taped out on TapeOut. TapeOut's processor
logic sits behind beacons that a 3-of-5 Safe can upgrade, so the kernel needs two things that cannot change:

| Contract | What it guarantees |
|---|---|
| `Fab` | Which chips a kernel accepts. It is the only way to make a kernel-eligible chip: it checks the netlist against interface v1 (`chips/INTERFACE.md`, section 2), mints exactly the transistors, tapes the circuit out on our processor, keeps its own copy of the exact netlist bytes, records the chip once, and hands the circuit NFT to the caller. |
| `SealedVM` | How a chip is evaluated. One TAP-20 beat over a flat netlist read from the Fab's copy. For every well-formed flat netlist it returns exactly what TapeOut's `Circuits.step` returns, at about one fourteenth of the gas. |

Both are immutable from their first block: no owner, no upgrade path, no pause, no initialiser. `SealedVM` has
no storage and makes no calls. `Fab` has one mapping, written once per chip.

Unaudited.

**Deployed on X Layer** (2026-10-06, built from commit `b54cb86`; `deployments/xlayer.json`, `evaluator`): SealedVM
`0x19C248cF463c1E167121e52b77abA7EC68CBE47B`, Fab `0xdCAc8c47aF534dC0cDE30f60056bCe7D63a79aFE`. Chips 2, 3, 4 and 5
were taped out through this Fab.

**Status.** Conforms to revision 2 of `chips/INTERFACE.md` (2026-10-05), sections 2, 11 and 12. `SealedVM` is
unchanged since revision 1. The `Fab` was reviewed once by a second agent at revision 1; what that review
found and what was changed afterwards is in NOTES.md, section 6.

## Layout

```
src/SealedVM.sol              the evaluator (ISealedVM, INTERFACE.md section 12)
src/Fab.sol                   the fab (IFabV1, INTERFACE.md section 11)
src/lib/NetlistScan.sol       section 2 of the interface as a pure check; returns (nNand, nLatch)
src/lib/NetlistErrors.sol     the five rejections SealedVM and NetlistScan share
src/lib/SSTORE2.sol           data-contract storage, adapted from TapeOut's library (MIT), same pointer format
src/interfaces/               ISealedVM and IFabV1 as written in INTERFACE.md; ITapeOut (what the Fab calls)
script/DeployEvaluator.s.sol  deployment, with checks before and after
test/                         hermetic suites (no network)
test/fork/                    the same Fab suite and more, on an X Layer fork at block 72,370,000
test/utils/                   netlist builder, section-2 reference checker, TapeOut harnesses, and a variant of
                              TapeOut's circuit logic that stands in for an upgrade (TestCircuits.sol)
test/fixtures/                TAP-20's own test vectors (TapeOutProtocol/TAPs, CC0), unmodified, and fg.hex, a
                              fixed copy of the flagship netlist as the chip tools built it on 2026-10-04
NOTES.md                      decisions, verified facts with commands, open assumptions
```

## Set up

Foundry 1.8 or later. Dependencies are not committed; install them into `lib/` (no git state is touched):

```
cd contracts/evaluator
forge install --root . --no-git --shallow \
  foundry-rs/forge-std@v1.17.0 \
  OpenZeppelin/openzeppelin-contracts@v5.7.0 \
  OpenZeppelin/openzeppelin-contracts-upgradeable@v5.7.0
```

Only `openzeppelin-contracts` is used by the deployed code (`ReentrancyGuardTransient`, `IERC1155Receiver`,
`IERC721Receiver`, `IERC165`). The upgradeable package is needed by the tests alone, to compile TapeOut's
vendored sources (`../vendor/tapeout-xlayer`, read through the `tapeout/` remapping, never edited).

Compiler: solc 0.8.28, `evm_version = "cancun"`, optimizer 200 runs, legacy pipeline. TapeOut's `NetlistVM`
does not compile on the legacy pipeline, so the three test harnesses that wrap or vary it are built with via-IR
under a second compiler profile; the tests deploy them from their artifacts, so the contracts under test are
always the production build.

## Tests

```
forge test                                # everything: 157 tests, one to two minutes
forge test --no-match-contract Fork       # hermetic only: 100 tests, no network
forge test --match-contract Fork -vv      # fork only: 57 tests, prints the gas reports
forge build --sizes
```

Fork tests select X Layer themselves at block 72,370,000 (`test/utils/XLayerFork.sol`). The endpoint is
`https://rpc.xlayer.tech`, or `XLAYER_RPC_URL` if set, with `https://xlayerrpc.okx.com` as fallback. They
never send a transaction. Passing `--fork-url` as well is harmless.

The fuzz seed is fixed (`0xc0ffee`) so runs are reproducible. For other inputs and longer runs:

```
FOUNDRY_FUZZ_SEED=0x1234 forge test --no-match-contract Fork
FOUNDRY_PROFILE=deep forge test --match-contract "SealedVMDiffTest|NetlistScanTest"   # 20,000 netlists, 50,000 damaged ones
```

| Suite | Tests | What it shows |
|---|---|---|
| `SealedVM.diff.t.sol` | 3 fuzz | SealedVM against TapeOut's own `NetlistVM.run` (vendored, unmodified). 4,096 random well-formed flat netlists of 1 to 3,400 gates (0 to 300 LATCH records, leading or interleaved, forward references, constants and duplicate inputs), each with four (state, inputs) pairs of every length class and a second beat: raw return data identical. 512 v1 chips, eight beats each. 4,096 damaged netlists: SealedVM accepts exactly those TapeOut's tape-out check accepts. |
| `SealedVM.t.sol` | 29 | Hand-built circuits, every rejection with its exact error, lenient reads, exact output lengths, the TAP-20 vectors, 65,536 pins, a 9,000-gate netlist, a worst-case gas budget. |
| `NetlistScan.t.sol` | 19 | Every limit of section 2 at its boundary, every rejection, and 4,096 damaged chips against an independent reference checker and against TapeOut's own check. |
| `SSTORE2.t.sol` | 7 | Pointer format, round trips, failure. |
| `Fab.t.sol` | 42 | The Fab suite against TapeOut's vendored contracts deployed locally. |
| `fork/Fab.fork.t.sol` | 43 | The same suite against the deployed TapeOut contracts: the processor is created through the real factory with `createCPU`. |
| `fork/SealedVM.fork.t.sol` | 8 | Two large circuits other teams taped out on X Layer (4,863 and 3,035 gates), read from the chain: SealedVM matches `Circuits.step` on 56 vectors each. The gas report. |
| `fork/StepGas.fork.t.sol` | 3 | The least gas each evaluator must be given, by bisection, against the two amounts a kernel gives: the flagship chip (the fixed copy `test/fixtures/fg.hex`), the corners of section 2, and one test on the chip tools' current output (below). Takes about 40 s. |
| `fork/Deploy.fork.t.sol` | 3 | The deploy script, inside the fork. |

The Fab suite asserts, on every tape-out: the caller paid exactly `quote(netlist).cost`; TapeOut's ledgers
moved by exactly that amount; exactly `nNand` and `nLatch` transistors were minted to the Fab and burned from
it and none moved anywhere else; the Fab holds no OKB, no transistor and no NFT afterwards and TapeOut owes it
no refund; the NFT is the caller's; the snapshot bytes equal `Circuits.netlist(chipId)`; and
`SealedVM.step(snapshot, 96, 112, s, x)` returns the same bytes as `Circuits.step(chipId, s, x)` on random
`(s, x)`. One test replaces TapeOut's circuit implementation, as its owner could, and shows the sealed
evaluator still returns what TapeOut returned before. Others change what TapeOut charges and does the way an
upgrade could (each of the three prices lower and higher, a circuit NFT minted with `_safeMint`, LATCH
transistors left unburned, price views that say more than `mint` charges): the Fab follows the first two and
reverts on the last two.

**The flagship chip in these tests.** `chips/out/fg.hex` is rebuilt by the chip tools, so every test that
needs a fixed real chip reads the copy `test/fixtures/fg.hex` (1,889 NAND + 64 LATCH, 13,479 bytes, keccak256
`0x2fd0e007…b2591a89`). Exactly one test reads the live file:
`test_fork_liveChip_isAV1Chip_evaluatorsAgree_andFitsTheStepGas`. It asserts only what any build of the chip
must satisfy: the Fab accepts it as an interface-v1 chip, the deployed `Circuits.step` and SealedVM agree on
it, and each evaluator runs it inside the gas a kernel gives it. It skips if the file is absent.

## Gas and sizes

Measured on the X Layer fork against the deployed `Circuits.step`, v1 chips with 64 state bits, every account
cold, the kernel's 32-byte state and 12-byte inputs:

| Gates | `Circuits.step` | `SealedVM.step` | Ratio |
|---|---|---|---|
| 500 | 1,282,096 (2,564 per gate) | 100,560 (201 per gate) | 12.7 |
| 2,000 | 4,661,636 (2,330 per gate) | 336,059 (168 per gate) | 13.9 |
| 3,400 | 7,813,545 (2,298 per gate) | 555,946 (163 per gate) | 14.1 |
| one more gate | 2,252 | 157 | |

A budget for callers, checked by `testFuzz_gasBudget_onV1Chips` on worst-case chips: one `SealedVM.step` of a
v1 chip costs at most `20,000 + 160 * nNand + 280 * nLatch` gas from a cold start.

### What a kernel must give `step`

The figures above are gas used. A kernel needs something else: the least gas an evaluator must be *given*
for `step` to succeed. That is more, because TapeOut's processor is a beacon proxy and a proxy can pass on
only 63/64 of what it has. `test/fork/StepGas.fork.t.sol` finds it by bisection on the fork and compares it
with what a kernel gives (INTERFACE.md section 2; the kernel factory in `contracts/core` computes the same
two numbers from the chip's counts):

```
TapeOut's evaluator   200,000 + 2,600 * gateCount + 800 * nState
the sealed evaluator   40,000 +   200 * nNand     + 400 * nLatch
```

"In a settle" means after the four comparisons of INTERFACE.md section 12, which touch every account and slot
TapeOut's `step` reads; from a cold start it needs 15,635 more. SealedVM is measured cold, which is how a
settle reaches it. The kernel's 32-byte state and 12-byte inputs throughout.

The flagship chip, the fixed copy `test/fixtures/fg.hex` (1,889 NAND + 64 LATCH, 13,479 bytes), for which a
kernel gives 5,329,000 and 443,400:

| State | Inputs | `Circuits.step`, in a settle | `SealedVM.step` |
|---|---|---|---|
| zero | zero | 4,566,646 | 320,545 |
| zero | all ones | 4,589,133 | 321,637 |
| all ones | zero | 4,580,845 | 322,469 |
| all ones | all ones | 4,595,209 | 322,521 |

Eight random (state, inputs) pairs needed no more than the last row: 86% of what TapeOut's evaluator is given
and 73% of what the sealed one is given.

The corners of section 2, on chips built so that every cost that depends on the data is at its highest (every
LATCH takes a 1, all 112 outputs are 1), at the all-ones state with all-ones inputs:

| Chip | `Circuits.step`, in a settle | given | `SealedVM.step` | given |
|---|---|---|---|---|
| most LATCH, fewest gates: 256 LATCH, 0 NAND | 884,768 | 1,070,400 | 80,629 | 142,400 |
| largest, most LATCH: 256 LATCH, 3,144 NAND | 8,080,087 | 9,244,800 | 574,250 | 771,200 |
| largest, most bytes: 1 LATCH, 3,399 NAND | 7,898,923 | 9,040,800 | 543,925 | 720,200 |
| smallest: 1 LATCH, 111 NAND | 359,320 | 492,000 | 27,656 | 62,600 |

At the zero state with zero inputs the same four chips need 839,793, 8,069,895, 7,885,894 and 354,613 on
TapeOut, and the same as above on SealedVM.

No row needs more than 88% of what TapeOut's evaluator is given or 76% of what the sealed one is given;
the tests assert 10% and 20% of margin. TapeOut's four corner figures fit
`101,730 + 2,293 * nNand + 3,059 * nLatch` to within 0.2% and the flagship is 0.7% below that line, but the
line is a fit, not a bound: a chip of 112 LATCH records and no NAND, measured in `contracts/core`, needs
453,834, which is 2.1% above it (and 78% of what it is given). SealedVM stays inside its budget of
`20,000 + 160 * nNand + 280 * nLatch` on every chip measured.

`Fab.tapeoutChip`, execution plus intrinsic gas: 9,406,734 for a 2,000-gate chip (13,808 bytes), 15,839,561
for the largest chip section 2 allows (23,797 bytes). About 60% is the two code deposits (TapeOut's copy of
the netlist and the Fab's), about 30% TapeOut's own checks.

| Contract | Runtime | Initcode |
|---|---|---|
| `SealedVM` | 2,276 bytes | 2,304 bytes |
| `Fab` | 6,465 bytes | 7,341 bytes |

## Interface

```solidity
// SealedVM
function step(address snapshot, uint32 nIn, uint32 nOut, bytes calldata state, bytes calldata inputs)
    external view returns (bytes memory newState, bytes memory outputs);

// Fab
function tapeoutChip(bytes calldata netlist, bytes32 manifestHash) external payable returns (uint256 chipId);
function tapeoutChipTo(bytes calldata netlist, bytes32 manifestHash, address to) external payable returns (uint256 chipId);
function quote(bytes calldata netlist) external view returns (uint256 nNand, uint256 nLatch, uint256 cost);
function isChip(uint256 chipId) external view returns (bool);
function chipInfo(uint256 chipId) external view
    returns (address snapshot, bytes32 netlistHash, uint32 nState, uint32 gateCount, address author, bytes32 manifestHash);
function snapshot(uint256 chipId) external view returns (bytes memory);
// immutables and constants: CIRCUITS, TRANSISTORS, N_IN (96), N_OUT (112)

event ChipTaped(uint256 indexed chipId, address indexed author, bytes32 indexed manifestHash,
                bytes32 netlistHash, uint32 nState, uint32 gateCount);
```

`cost = mintPrice * (nNand + nLatch) + protocolFee * mintCalls + TAPEOUT_FEE`, where `mintCalls` is 2, or 1
for a chip with no NAND, and the three prices are read from the processor in the same call
(`Transistors.mintPrice()`, `Transistors.protocolFee()`, `Circuits.TAPEOUT_FEE()`). The Fab stores none of
them. A call must carry exactly that. For the Covenant processor (0.00002 OKB per transistor) and today's
TapeOut fees (0.00066 OKB per mint call, 0.0013 OKB per tape-out), a 112-record chip costs 0.00486 OKB and a
2,000-gate chip 0.04262 OKB.

Things an integrator should know:

- `chipInfo` and `snapshot` revert with `NotAChip(chipId)` for an id that was not taped out through this Fab.
  `isChip` never reverts. A circuit taped out directly on the processor is not a chip.
- `author` is the caller of the Fab. With a wrapper contract it is the wrapper.
- `manifestHash` is the caller's commitment to the chip's pin manifest (the SHA-256 of its
  `.well-known/tape-pins.json`). The Fab records it as given and does not check it. Anyone can use any value;
  a chip's identity is `(chipId, netlistHash)`.
- A record is written once and never changes. `chipInfo(chipId).snapshot` is an SSTORE2 pointer (runtime code
  `0x00`, then the netlist); pass it to `SealedVM.step` with `nIn = 96`, `nOut = 112`.
- `SealedVM.step` takes `nIn` and `nOut` from the caller. They must be the values the circuit was taped out with.
- Call `quote` and `tapeoutChip` in the same block, or send what `quote` returns from a contract: if TapeOut
  changes a price in between, the tape-out reverts with `WrongValue(sent, cost)` and nothing is paid.
- Every tape-out ends with a check that the Fab holds no transistor of either type and that
  `Transistors.owed(Fab)` is zero, and reverts with `LeftOver()` otherwise. With today's TapeOut it never
  fires. It is there for an upgraded TapeOut that burns less than it reports or charges less than its price
  views say: the Fab has no way to move transistors or to collect a refund, so it stops instead.
- The Fab answers `onERC721Received`, but only to the processor's circuit contract and only during its own
  tape-out, so that it keeps working if TapeOut ever mints the circuit NFT with `_safeMint`. Any other safe
  transfer of an NFT to the Fab reverts with `UnexpectedTokens()`.
- For named return values in JavaScript, use the ABI of `IFabV1` (`out/IFabV1.sol/IFabV1.json`): the Fab's own
  ABI names the first return of `chipInfo` `snapshot_`.

Errors. The first five are shared by both contracts (`src/lib/NetlistErrors.sol`):

| Error | Raised by | Meaning |
|---|---|---|
| `TruncatedRecord()` | both | the last record is cut short |
| `BadOpcode(uint256 offset, uint8 opcode)` | both | SealedVM: any opcode but NAND and LATCH. Fab: an opcode TAP-20 does not define |
| `FutureSignal(uint256 offset)` | both | a NAND reads a signal that is not earlier than its own |
| `LatchOutOfRange(uint256 d, uint256 nSignals)` | both | a LATCH takes its next value from a signal that does not exist |
| `TooFewSignals(uint256 records)` | both | fewer records than outputs |
| `BadPins()` | SealedVM | `nIn` above 65,536, or `nOut` zero or above 65,536 |
| `BadSnapshot()` | SealedVM | no code at the pointer, or code that does not start with `0x00` |
| `TooManySignals()` | SealedVM | more than 2^24 signals possible |
| `NetlistTooLong(uint256 length)` | Fab | more than 24,000 bytes |
| `RefNotAllowed(uint256 offset)` | Fab | a REF record |
| `LatchAfterNand(uint256 offset)` | Fab | a LATCH after a NAND |
| `StateCountOutOfRange(uint256 nLatch)` | Fab | not 1 to 256 LATCH records |
| `TooManyGates(uint256 gates)` | Fab | more than 3,400 records |
| `WrongValue(uint256 sent, uint256 cost)` | Fab | `msg.value` is not exactly the cost at TapeOut's prices of this moment |
| `LeftOver()` | Fab | at the end of a tape-out the Fab still held transistors, or TapeOut owed it a refund |
| `BadRecipient()` | Fab | `to` is zero or the Fab |
| `TapeoutMismatch()` | Fab | TapeOut did not record the circuit the Fab asked for |
| `ChipExists(uint256 chipId)` | Fab | TapeOut returned an id already recorded |
| `NotAChip(uint256 chipId)` | Fab | unknown chip |
| `UnexpectedTokens()` | Fab | a transistor transfer that is not the Fab's own mint, or an NFT handed to the Fab by anyone but the processor during a tape-out |
| `NotAProcessor()` | Fab constructor | the two addresses are not one processor |
| `WriteFailed()` | Fab | the snapshot contract could not be created |
| `ReentrancyGuardReentrantCall()` | Fab | OpenZeppelin's lock |

TapeOut's own reverts pass through unchanged, for example `supply cap` when the processor has too few
transistors left.

## Deploy

The processor must exist first (it is created by the Splitter's constructor, through `script/Ignite.s.sol` in
`contracts/issuance`). Take its two addresses from that broadcast record.

```
cd contracts/evaluator
export COVENANT_CIRCUITS=0x...       # the processor's circuit contract (ERC-721)
export COVENANT_TRANSISTORS=0x...    # the processor's transistor contract (ERC-1155)
```

**1. Simulate.** Sends nothing and needs no key. The script refuses any chain but 196, any address pair that is
not one processor of TapeOut's factory, and a Fab whose quote for the smallest chip is not what the
processor's prices of that moment imply.

```
forge script script/DeployEvaluator.s.sol --rpc-url https://rpc.xlayer.tech
```

**2. Broadcast.** Run by the wallet holder only. Two contract creations: 545,399 gas for `SealedVM` and
1,490,661 for the `Fab` when the script was rehearsed against a local fork of X Layer. (`forge script`
estimates 2.65M for the pair; its estimate carries a margin.)

```
forge script script/DeployEvaluator.s.sol --rpc-url https://rpc.xlayer.tech \
  --account <keystore-name> --sender <deployer-address> --broadcast --slow
```

The addresses are printed and saved in `broadcast/DeployEvaluator.s.sol/196/run-latest.json`.

**3. Verify on OKLink.** Done on 2026-10-07 for both contracts, on OKLink and on Sourcify (`docs/VERIFY.md`,
section 2; `deploy/verify-explorers.sh` prepares the exact commands). OKLink asks for a key and accepted the
placeholder `none`. The shape of the commands:

```
export OKLINK_API_KEY=...
export OKLINK_URL=https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER

forge verify-contract <SealedVM address> src/SealedVM.sol:SealedVM \
  --verifier oklink --verifier-url $OKLINK_URL --verifier-api-key $OKLINK_API_KEY \
  --compiler-version v0.8.28+commit.7893614a --num-of-optimizations 200 --evm-version cancun --watch

forge verify-contract <Fab address> src/Fab.sol:Fab \
  --verifier oklink --verifier-url $OKLINK_URL --verifier-api-key $OKLINK_API_KEY \
  --constructor-args $(cast abi-encode "constructor(address,address)" $COVENANT_CIRCUITS $COVENANT_TRANSISTORS) \
  --compiler-version v0.8.28+commit.7893614a --num-of-optimizations 200 --evm-version cancun --watch
```

If the plugin refuses, `forge verify-contract ... --show-standard-json-input > input.json` produces the file
OKLink's web form accepts.

**4. Check from a terminal.**

```
RPC=https://rpc.xlayer.tech
cast call <Fab> "CIRCUITS()(address)" --rpc-url $RPC          # the processor's circuit contract
cast call <Fab> "TRANSISTORS()(address)" --rpc-url $RPC       # and its transistor contract
cast code <SealedVM> --rpc-url $RPC | cast keccak             # equals: forge inspect SealedVM deployedBytecode | cast keccak
cast call <Fab> "quote(bytes)(uint256,uint256,uint256)" $(cat chip.hex) --rpc-url $RPC
```

After the first tape-out, with `ID` the chip and `PTR` the first value of `chipInfo(ID)`, these two calls
return the same bytes for any state `S` and inputs `X`:

```
cast call $COVENANT_CIRCUITS "step(uint256,bytes,bytes)(bytes,bytes)" $ID $S $X --rpc-url $RPC
cast call <SealedVM> "step(address,uint32,uint32,bytes,bytes)(bytes,bytes)" $PTR 96 112 $S $X --rpc-url $RPC
```
