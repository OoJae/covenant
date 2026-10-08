# Notes: contracts/evaluator

Working notes for `SealedVM` and `Fab`. How to run everything is in `README.md`.

Last full run: 2026-10-06, `forge test`, 157 tests passed (100 hermetic, 57 on the X Layer fork at block
72,370,000), 0 failed, 0 skipped. On 2026-10-05 the whole suite also passed with
`--fork-url https://rpc.xlayer.tech --fork-block-number 72370000` on the command line, the hermetic suites
passed with `FOUNDRY_FUZZ_SEED=0x20261005`, and
`FOUNDRY_PROFILE=deep forge test --match-contract "SealedVMDiffTest|NetlistScanTest"` passed: 20,000 random
flat netlists and 2,000 v1 chips against TapeOut's evaluator, 50,000 damaged netlists against TapeOut's
tape-out check and 20,000 damaged chips against the section-2 reference.

`SealedVM`, `NetlistScan` and the SSTORE2 library have not changed since 2026-10-04. On that day their fuzz
suites were also run with seeds `0x1`, `0xdeadbeef`, `0x7a11e0` and `0xdee9`, and twice under
`FOUNDRY_PROFILE=deep` (seeds `0x5ea1ed` and `0xabcdef01`), each time 20,000 random flat netlists and 2,000 v1
chips against TapeOut's evaluator, 50,000 damaged netlists against TapeOut's tape-out check and 20,000 damaged
chips against the section-2 reference. No difference found in any run.

## 1. Decisions

### SealedVM

1. **Strict.** It evaluates only well-formed flat netlists and reverts on everything TAP-20 section 3 calls
   ill-formed: an opcode other than NAND or LATCH (so every REF), a cut record, a NAND reading a signal that is
   not earlier than its own, a LATCH `d` that is not a signal, fewer records than outputs, `nOut = 0`, pins above
   65,536. TapeOut's `NetlistVM.run` is looser in two places (a forward NAND reference reads 0, and it never
   checks the output count), but such netlists cannot be taped out, so `Circuits.step` never sees them. Strict
   is also what keeps every memory read inside the signal buffer. The differential test
   `testFuzz_acceptsExactlyWhatTapeOutAccepts` pins the equivalence: SealedVM succeeds exactly when
   `NetlistVM.analyze` (the check `Circuits.tapeout` runs) accepts.
2. **One byte per signal, one pass.** The netlist is copied from the pointer with one `extcodecopy`; 32 bytes
   of `0xff` are written after it. A record is decoded from one `mload`. The top four bytes of that word are
   the opcode and `a`; read as one number they are below the index being produced only if the opcode is `0x00`
   and `a` is an earlier signal, so the opcode check and one bounds check are the same comparison. The loop has
   no end-of-netlist test: the `0xff` byte is no opcode, so it ends the loop, and the position where the loop
   stopped must be exactly the end. A cut record always fails that test.
3. **Leading LATCH records are placed in bulk.** A v1 chip has all its LATCH records first, so their outputs
   (the state bits) are a contiguous run of signals after the inputs. Inputs and that run are written eight
   bits at a time with one multiplication (`_spread`); outputs are packed the same way (`_pack`). A LATCH that
   appears later is handled in the main loop, one at a time, so any flat netlist is evaluated correctly. This
   cut the fixed cost of a 64-latch chip from about 61,000 gas to about 26,000.
4. **Not done, on purpose.** Unrolling the loop four records per `mload` would save an estimated 20% and
   putting the signal buffer at memory address 0 an estimated 8% more. Both make the code harder to check,
   and the cost per gate is already 157 gas against TapeOut's 2,252. The loop is one record per iteration
   and the contract follows Solidity's memory conventions (every assembly block is `memory-safe`).
5. **`nIn` and `nOut` are parameters**, as section 12 of the interface says. For Fab chips the kernel passes
   96 and 112. Passing other values than the circuit was taped out with gives another circuit's answer or a
   revert, never an out-of-bounds read.
6. **The pointer must start with `0x00`.** TapeOut's reader does not check; it only skips the byte. The check
   costs about 20 gas and refuses an address that is not a data contract.

### Fab

1. **Prices are read on every call.** `quote` and both tape-out functions read `Transistors.mintPrice()`,
   `Transistors.protocolFee()` and `Circuits.TAPEOUT_FEE()` and compute the cost from them. The Fab stores
   none of them. TapeOut's processor logic is upgradeable and its factory is not sealed, so a Fab that fixed
   the prices at construction would stop for good at the first change. The cost of a chip can therefore
   change between a `quote` and the tape-out; the tape-out then reverts with `WrongValue` and nothing is paid
   (`test_prices_areReadOnEveryCall`). What a price view that overstates the charge could strand is stopped
   by the check of item 5.
2. **Exact value by construction.** `msg.value` must equal `cost`; the three payments (NAND mint, LATCH mint,
   tape-out fee) add up to `cost`. The Fab has no `receive`, no `fallback` and no other statement that sends
   value, so a call leaves its balance where it was. OKB forced in from outside stays forever: it does not
   subsidise a tape-out (`test_forcedBalance_isNeitherSpentNorReleased`) and nobody can take it out.
3. **The receiver hook accepts only the Fab's own mint**: caller is the processor's `Transistors`, operator is
   the Fab, `from` is zero. Everything else reverts, so nobody can park transistors in the Fab. Batches are
   always refused. `Transistors.mint` mints to its caller only, so no one else can cause an accepted mint.
4. **Records are write-once.** `ChipExists` if TapeOut ever returns an id the Fab has already recorded (only an
   upgraded TapeOut could). The record is written after TapeOut's call because the id does not exist before.
5. **Self-check after `tapeout`, and a check of the Fab's own holdings at the end.** `circuitInfo` must
   report 96, 112, `nLatch`, `nNand + nLatch` and `keccak256(Circuits.netlist(id))` must equal the hash of the
   bytes the Fab stores. That checks what TapeOut reports. The last statement of every tape-out checks what
   TapeOut did: the Fab must hold no transistor of either type and `Transistors.owed(Fab)` must be zero, or
   the call reverts with `LeftOver` and the caller keeps the money. Logic that burned fewer transistors than
   it reports would leave them in the Fab, and logic that charged less than its price views say would keep
   the difference as a refund owed to the Fab; the Fab can neither move a transistor nor collect a refund.
   With prices read on every call this check is the only thing between a lying price view and a stranded
   overpayment. Today's TapeOut never triggers it (every tape-out test, local and on the fork, ends with it);
   `test_revert_leftOver_*` trigger each of its three conditions on their own.
6. **Its own SSTORE2 copy**, one chunk, written from calldata. It costs 200 gas per byte a second time. Using
   TapeOut's chunk instead would need its address, which depends on the processor's account nonce and cannot
   be read on-chain.
7. **`chipInfo` and `snapshot` revert with `NotAChip`** for an unknown id, as section 11 of the interface
   says and like TapeOut's own `circuitInfo`.
8. **`author` is `msg.sender`**, also in `tapeoutChipTo`. An author passed as a parameter could be forged.
9. **`tapeoutChipTo` refuses `to == address(0)` and `to == address(this)`** (the NFT would be stuck). It
   exists so that a contract can tape out and hand the circuit NFT on in one transaction.
10. **A chip may have no NAND.** Section 2 allows it and so does TapeOut: 112 or more LATCH
    records make a valid chip whose outputs are LATCH outputs. The Fab then makes one mint call and charges one
    protocol fee. Tested on the fork (`test_tapeoutChip_withoutNand_mintsOnce`).
11. **OpenZeppelin v5.7.0**, the version `contracts/core` uses, for `ReentrancyGuardTransient` and the three
    interfaces (`IERC1155Receiver`, `IERC721Receiver`, `IERC165`).
12. **The ERC-721 hook accepts the processor during a tape-out and nothing else.** `onERC721Received` answers
    only if the caller is the processor's circuit contract and the Fab is inside its own tape-out (its
    transient reentrancy lock is set); otherwise it reverts with `UnexpectedTokens`. Today TapeOut mints the
    circuit NFT with `_mint`, which calls no hook. The hook is there so that a change to `_safeMint` would not
    stop the Fab (`test_safeMint_theFabKeepsWorking`, with a variant of TapeOut's circuit logic behind the
    processor's beacon). `supportsInterface` still names the ERC-1155 receiver and ERC-165 only: a safe mint
    does not ask it. The operator and the previous owner are not examined. So the hook would also accept
    another circuit that the processor's own code handed to the Fab during a tape-out; that circuit would
    stay in the Fab for good, exactly like one sent with a plain `transferFrom` at any time, which no
    contract can refuse (`test_erc721Hook_refusesEverythingOutsideATapeout` shows the plain transfer and
    that the Fab is unaffected). Code that TapeOut merely pays during a tape-out is refused
    (`test_erc721Hook_duringATapeout_acceptsOnlyTheProcessor`).

### NetlistScan

Section 2, in this order: length; leading LATCH records; then only NAND records with earlier inputs; then
the counts. Error precedence when several rules are broken: `NetlistTooLong`, then the first bad record
(`LatchAfterNand`, `RefNotAllowed`, `BadOpcode`, `TruncatedRecord`, `FutureSignal`), then
`StateCountOutOfRange`, `TooManyGates`, `TooFewSignals`, `LatchOutOfRange`. `testFuzz_agreesWithTheReference`
compares accept or reject with a second, plainly written implementation (`test/utils/V1Reference.sol`), and
checks that whatever the scan accepts, TapeOut's `analyze` accepts with the same counts.

### Tests

- **Two compiler profiles.** TapeOut's `NetlistVM.run` fails with "stack too deep" on solc's legacy pipeline,
  so `NetlistVMHarness.sol`, `LocalTapeOut.sol` and `TestCircuits.sol` are compiled with via-IR
  (`compilation_restrictions` in `foundry.toml`), everything under `src/` is pinned to the legacy pipeline,
  and tests reach the harnesses with `deployCode` and interfaces. Importing a harness into a test would pull
  the contracts under test into the via-IR build.
- **An upgraded TapeOut is played, not imagined.** `test/utils/TestCircuits.sol` is TapeOut's `Circuits` with
  the same storage layout and three switches (the tape-out fee, `_safeMint` instead of `_mint`, LATCH
  transistors left unburned). The suite puts it behind the processor's beacon, locally and on the fork (as
  the factory's owner), and changes the mint price and the protocol fee where they live, in the transistor
  contract's storage.
- **The Fab suite is written once** (`test/utils/FabSuite.sol`) and run against a local deployment of the
  vendored TapeOut sources and against the fork. The local run needs no network.
- **Census tests** count what the random damage produces, so a fuzz test that only ever sees one kind of
  rejection would fail the build.
- **Gas figures are cold-start figures.** Foundry 1.8 runs every top-level call of a test as its own
  transaction (`isolate` resolves to true by default), so a `gasleft()` difference around a call sees every
  account cold. Where warmth matters (the step gas a kernel must give), the test does the kernel's four
  comparisons and the evaluation inside one call (`SettleProbe` in `test/fork/StepGas.fork.t.sol`).

## 2. Verified facts

Commands were run on 2026-10-04 unless a row says otherwise. `RPC=https://rpc.xlayer.tech`; the second
endpoint is `https://xlayerrpc.okx.com`.

| Fact | How |
|---|---|
| Chain id 196 | `cast chain-id --rpc-url $RPC` |
| Both endpoints serve state one million blocks back; the fork block stays readable | `cast call 0x1f09daefa827f02cbb40967cc91b259763760761 'cpuCount()(uint256)' --block 71370884 --rpc-url $RPC` returned 211 on both |
| X Layer executes TSTORE, TLOAD and MCOPY | `cast rpc eth_call '{"data":"0x602a60005d60005c6000526020600060205e60206020f3"}' latest --rpc-url $RPC` returned `0x…2a` on both |
| X Layer rejects CLZ (Osaka) | `cast rpc eth_call '{"data":"0x60011e60005260206000f3"}' latest --rpc-url $RPC`: `NotActivated` / `invalid opcode: CLZ` |
| Factory: deploy fee 0.0066 OKB, protocol fee 0.00066 OKB per mint call, not sealed, 275 processors | `cast call 0x1f09…0761 'deployFee()(uint256)'`, `'protocolFee()(uint256)'`, `'isSealed()(bool)'`, `'cpuCount()(uint256)'` |
| The factory's owner `0xB3D85b42A045c1A88D800CAD0F55d2566a4D3138` is a Safe with threshold 3 and 5 owners; both beacons are owned by the factory. So three signatures can replace the logic of every processor | `cast call <owner> 'getThreshold()(uint256)'` (3), `'getOwners()(address[])'` (5 addresses); `cast call <beacon> 'owner()(address)'`, at block 72,370,000 |
| Circuit beacon `0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C`, implementation `0x977f217887E085D298Cb3819cDAD5A0ee35F29B2`, code hash `0x7a15c353…3f941b30`, 12,562 bytes: the implementation the vendored source was read from | `cast call <beacon> 'implementation()(address)'`, `cast keccak $(cast code <impl>)`; asserted in `test_fork_pinnedFacts` |
| Transistor beacon `0x1059Ad62cAbB6a6925bb65aA617300556c60A51B`, implementation `0x265bf10faB9ddEC0eE0A649C6B9DB845f1b9a06b`, code hash `0x7fa76245…658e17e9`, 9,265 bytes | same |
| The deployed implementations expose exactly the function selectors of the vendored sources: 26 for `Circuits`, 25 for `Transistors`, none missing, none extra. (The vendored bundle was fetched for the circuit implementation; this is the check that the transistor implementation is the same vintage.) | `cast selectors $(cast code <impl> --block 72370000)` against `methodIdentifiers` of the locally compiled vendored source |
| `TAPEOUT_FEE` is 0.0013 OKB; the treasury `0xEBeceDeA36e598b64E17f8d519EB77441C539F76` has no code | `cast call <any processor> 'TAPEOUT_FEE()(uint256)'`; `test_fork_pinnedFacts` |
| `Transistors.mint` to a contract runs the ERC-1155 acceptance check: without the hook it reverts `ERC1155InvalidReceiver` | `test_mintToAContract_runsTheAcceptanceCheck`, on the fork |
| `Circuits.tapeout` mints the NFT with `_mint`: no ERC-721 hook is called on the Fab; the burn's operator is `Circuits` and `from` is the Fab | the vendored source; every tape-out test on the fork; `_transistorFlows` reads the `TransferSingle` logs |
| The deployed transistor contract answers `balanceOf(address,uint256)` and `owed(address)`, the two reads of the Fab's final check | every tape-out test on the fork ends with that check (2026-10-05) |
| The two live circuits are flat and LATCH-first: `0xAa13…AF21` circuit 3 is 4,620 NAND + 243 LATCH in 33,312 bytes; `0x933F…Db5a` circuit 1 is 2,747 NAND + 288 LATCH in 20,381 bytes | `cast call <processor> 'netlist(uint256)(bytes)' <id>` and a record walk; asserted in `fork/SealedVM.fork.t.sol` |
| TAP-20 vectors are the published file | `shasum -a 256 test/fixtures/tap20-vectors.json` gives `1a02f5cf…aefd203b`, the hash TAP-20 states; from TapeOutProtocol/TAPs commit `cca62773` |
| OKLink's Foundry endpoint for X Layer exists | `curl "https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER?module=contract&action=checkverifystatus&guid=0"` answers `{"status":"1","message":"NOTOK","result":"Fail - Unable to verify"}`; an unknown chain name answers "This chain does not currently support" |
| The deploy script runs against the live chain without sending anything | `COVENANT_CIRCUITS=0x933FC3AA0c387CB8B6B1D22a2Ec3E2B5eeCfDb5a COVENANT_TRANSISTORS=0x0F243eD0f164C9693fe95ba7e678A7b2c799bF4B forge script script/DeployEvaluator.s.sol --rpc-url $RPC` (another team's processor, as a stand-in), 2026-10-05: "SIMULATION COMPLETE", 2,646,877 gas estimated |
| The deploy script broadcasts and its checks pass on a fork | The same command with `--broadcast --unlocked` against a local `anvil --fork-url $RPC`, for a processor created there through TapeOut's factory, 2026-10-05: `SealedVM` 545,399 gas, `Fab` 1,490,661 gas. Nothing was sent to X Layer; the local records were deleted |

### The production bytecode on the real node (no transaction)

Foundry's EVM is not X Layer's client, so both contracts were also executed by the live node with `eth_call`
and state overrides (`cast call --override-code`, `--override-balance`, `--override-nonce`). Nothing was sent.

- **SealedVM against TapeOut's own stored netlist** (2026-10-04; SealedVM has not changed since). TapeOut
  keeps circuit 1 of processor `0x933FC3AA…Db5a` in a data contract at
  `0x6794653479E38C30663f7565e85fa46c66972B99` (`cast compute-address <processor> --nonce 1`);
  its code is `0x00` followed by `netlist(1)`, byte for byte, which is the pointer format SealedVM reads. With
  SealedVM's runtime code overridden onto a scratch address,
  `step(0x6794…2B99, 161, 1, S, X)` returned the same bytes as the processor's own `step(1, S, X)` for 8 pairs
  (random, an empty state, a one-byte input) at block 72,375,281.
- **Fab against a live processor** (2026-10-05, block 72,394,782). The constructor was run with `eth_call`
  (no `to`) for processor `0x2503025c…c8bd` and returned the 6,465-byte runtime. With that code overridden
  onto a scratch address: `CIRCUITS()` and `TRANSISTORS()` returned the processor's two addresses;
  `quote(test/fixtures/fg.hex)` returned `(1889, 64, 1.2916 OKB)`, which is that processor's 0.00066 OKB per
  transistor times 1,953, two protocol fees of 0.00066 OKB and the tape-out fee of 0.0013 OKB, all read by the
  Fab in the call; `tapeoutChip` with that value returned `5`, the processor's `nextId + 1` (both mints with
  the receiver hook, TapeOut's burn, the self-checks, the snapshot creation, the record, the NFT transfer and
  the final check of the Fab's balances and of `owed` all ran on the node), and so did `tapeoutChipTo` to
  another address; with 1 wei it reverted `WrongValue(1, 1291600000000000000)` and with one wei too many
  `WrongValue(1291600000000000001, 1291600000000000000)`; `tapeoutChipTo(…, address(0))` reverted
  `BadRecipient`; a netlist with a REF reverted `RefNotAllowed(4)`; `onERC721Received` called by a stranger
  reverted `UnexpectedTokens`.

Bytecode of this revision (changes with any edit to the sources, comments included):
`forge inspect SealedVM deployedBytecode | cast keccak` and `forge inspect Fab bytecode | cast keccak`.

## 3. Open assumptions and things not verified

1. **An upgraded TapeOut can still stop this Fab, by lying to it.** A changed price no longer does. But
   logic that burns fewer transistors than it reports, or charges less than its price views say, makes
   every tape-out revert with `LeftOver` for as long as it stays in place. Recorded chips, their snapshots
   and kernels are unaffected; new chips would need a new Fab. A processor that lies in every view cannot
   be defeated by any check (section 6, finding 4).
2. **OKLink verification was not run from this package.** The command in the README follows Foundry's
   `--verifier oklink`. Both contracts were deployed on 2026-10-06, and their sources were verified on OKLink and
   on Sourcify on 2026-10-07 (`docs/VERIFY.md`, section 2).
3. **TapeOut's deployed build used via-IR.** Inferred: its source does not compile otherwise. OKLink's record
   does not show the flag. It does not matter for these contracts.
4. **Gas is measured in Foundry's EVM with Cancun rules.** X Layer runs a later fork and looks like an
   OP-Stack chain (sequencer fee vault as block producer), so a transaction also pays an L1 data fee that
   grows with calldata. A tape-out carries 14 to 24 KB of calldata. Not measured.
5. **The largest chip's tape-out costs 15.84M gas.** Fine today (blocks have a 210M gas limit, read from a
   block header on 2026-10-05). If X Layer adopted Ethereum's 16,777,216 per-transaction cap, there would be
   0.94M of room, and none if TapeOut's own tape-out got dearer. A 2,000-gate chip, a little larger than the
   flagship (1,953 gates), needs 9.4M.
6. **Fork tests depend on public endpoints keeping old state.** Both did on 2026-10-04. Until 2026-10-06 the
   first was named in `foundry.toml` with a `${XLAYER_RPC_URL:-...}` default, which Foundry does not
   expand, so the fork runs of 2026-10-04 and 2026-10-05 were served by the OKX endpoint. On 2026-10-06 that
   endpoint did not resolve; `test/utils/XLayerFork.sol` now reads `XLAYER_RPC_URL` itself, and the suite
   passed against `https://rpc.xlayer.tech`. Foundry also caches the fork under
   `~/.foundry/cache/rpc/xlayer/72370000`.
7. **`TooManySignals` is not exercised.** It needs a pointer with about 67 MB of code.
8. **The fuzz seed is fixed** in `foundry.toml`. Different seeds were run by hand (see the top of this file).
9. **The revision-2 changes to the Fab were not reviewed by a second agent.** They were tested by mutation
   instead (section 6).

## 4. The interface document

The code conforms to revision 2 of `chips/INTERFACE.md` (2026-10-05). Where the two meet:

| Revision 2 says | This code |
|---|---|
| Section 2: `112 <= nNand + nLatch <= 3400`; an output may be a LATCH output; a chip may have no NAND | The same. `TooFewSignals` below 112 records; a chip without NAND makes one mint call |
| Section 11: `tapeoutChip`, `tapeoutChipTo`, `quote`, `isChip`, `chipInfo`, `snapshot` | `src/interfaces/IFabV1.sol` is that text; the Fab implements it. The selectors are those of revision 1 (`test_abi_selectorsAndTopic_areUnchangedByTheRename`) |
| Section 11: the free `bytes32` is `manifestHash`, the SHA-256 of the chip's pin manifest | The same name in the functions, the `Chip` struct, `chipInfo` and the event. Recorded as given, never checked |
| Section 11: `msg.value` must equal `quote(netlist).cost`, with the prices read from TapeOut at the time of the call | The same: `WrongValue` otherwise, in both directions |
| Section 11: `chipInfo` and `snapshot` revert for an id the Fab did not tape out | The same: `NotAChip(uint256)` |
| Section 12: `ISealedVM.step` | The same signature, selector `0x2b797dfc` |
| Section 2, gas: what a kernel gives each evaluator, and that it covers every shape at the all-ones state | The two amounts are computed in `contracts/core`. Measured here in `test/fork/StepGas.fork.t.sol`; numbers in README.md, "What a kernel must give `step`" |

One sentence of section 2 is not exact: "TapeOut's `step` needs at most `101,730 + 2,293 * nNand + 3,059 *
nLatch` ... over every shape this section allows". The line is a fit to the corners measured here. A chip of
112 LATCH records and no NAND needs 453,834, which is 2.1% more than the line gives (measured in
`contracts/core`). What a kernel gives covers every shape measured with 12% or more to spare, so nothing
depends on the sentence.

The interface does not mention, and this code has:

- **Section 11**: `author` is `msg.sender` (a wrapper is the author of what it tapes out); the event
  `ChipTaped(uint256 indexed chipId, address indexed author, bytes32 indexed manifestHash, bytes32 netlistHash, uint32 nState, uint32 gateCount)`;
  the cost formula "one protocol fee per mint call, two calls unless the chip has no NAND"; the `LeftOver`
  check at the end of a tape-out; the ERC-721 receiver hook.
- **Section 12**: SealedVM reverts on an ill-formed netlist and on a pointer whose code does not start with
  `0x00`; `nIn` and `nOut` must be the values the circuit was taped out with.

## 5. Attribution

- `src/lib/SSTORE2.sol` is adapted from TapeOut's `lib/SSTORE2.sol` (MIT), itself after solmate's. Same
  creation code, same pointer format. The header says what changed.
- `SealedVM` is a new implementation of TAP-20's one-beat semantics, written against TapeOut's verified
  `NetlistVM.sol` (MIT), which the tests use unmodified as the oracle.
- `test/fixtures/tap20-vectors.json` is from TapeOutProtocol/TAPs (CC0), unmodified.
- `test/utils/TestCircuits.sol` is TapeOut's `Circuits.sol` (MIT) with three switches added for the tests;
  its header lists them. It is never deployed.
- No code from any other hackathon entry was read or used.

## 6. Independent review of revision 1, and what was done about it

A second agent reviewed `SealedVM`, `Fab` and the libraries adversarially on a private copy, without my
reasoning (2026-10-04, the revision-1 code). It could not break the equivalence with TapeOut's evaluator, the
memory bounds, the bit arithmetic, the value accounting, the registry or the pointer format against that
day's TapeOut. It added its own checks: the same source with memory beyond the free pointer pre-filled with
four patterns (same answers on about 13,000 cases), 1,500 damaged netlists with 254 to 65,536 inputs, 4,000
netlists of raw random bytes, and the real flagship netlist on 1,500 vectors and 300 chained beats.

What it found, in its order, and what became of each:

1. **The kernel's step gas (in `contracts/core`, not here) was too small for small or LATCH-heavy chips.**
   `60,000 + 2,600 * gateCount` was below what TapeOut's evaluator needs for, among others, the smallest chip
   (1 LATCH + 111 NAND) and any chip with many LATCH records and few NAND: a LATCH costs TapeOut about 3,060
   gas, a NAND about 2,290, and the fixed part is about 100,000. **Changed in `contracts/core`**: a kernel now
   gives TapeOut's evaluator `200,000 + 2,600 * gateCount + 800 * nState` and the sealed one
   `40,000 + 200 * nNand + 400 * nLatch`, and asks the sealed evaluator whenever TapeOut's step fails.
   `test/fork/StepGas.fork.t.sol` measures both evaluators against both amounts.
2. **Low, and only after a TapeOut upgrade: the Fab did not check that it ends a call holding nothing.**
   It trusted `circuitInfo` for the burn and the price views for the charge. The reviewer reproduced two
   upgraded-logic cases on its copy: logic that stops burning LATCH transistors leaves them in the Fab for
   good; a `mint` that charges less than the price views say leaves a refund owed to the Fab that nobody can
   collect. **Changed**: the `LeftOver` check is the last statement of every tape-out (section 1, Fab,
   item 5). Both cases are in the suite and revert.
3. **Low: two harmless TapeOut changes would have stopped the Fab.** A changed price, and a `tapeout` that
   mints with `_safeMint`. **Changed**: prices are read on every call (item 1), and the Fab has an ERC-721
   receiver hook (item 12). The reviewer suggested a hook that also requires the operator to be the Fab and
   the previous owner to be zero; the hook as built requires the caller to be the processor's circuit
   contract and the Fab to be inside its own tape-out, and item 12 says what that leaves open.
4. **Information: malicious circuit logic can add a record, never change one.** `ChipExists` held. Logic
   that returns someone else's existing circuit id and lies in `circuitInfo`, `netlist` and `transferFrom`
   makes `isChip` true for that id with the caller's netlist. The record still holds a netlist that passed
   section 2 and its own snapshot, and no value moves. Nothing a contract can check defeats a processor that
   lies in every view. Unchanged.
5. **Information: the only third-party grief found is buying the supply.** All but 111 transistors cost
   about 1,342 OKB, paid to the processor's creator. Unchanged.

**The revision-2 changes** (live prices, `LeftOver`, the ERC-721 hook, the rename) were made on 2026-10-05
and have not been reviewed by a second agent. They were tested by mutation: 28 small changes to
`Fab.sol` (each price fixed at its value of today, the value check loosened or deleted, each of the three
conditions of the final check removed or confused with another, each condition of the hook removed, swapped
or inverted, the hash dropped from the record or the event, and others), each run against the local Fab
suite. All 28 made at least one test fail. The selectors of the six `IFabV1` functions and the topic of
`ChipTaped` are asserted to be those of revision 1.
