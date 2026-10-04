# Notes on the TAP drafts in this directory

Written on 2026-10-04. Nothing here has been submitted: no issue, pull request or comment was opened anywhere, and no transaction was sent to any chain. These are drafts for the team to review.

## 1. What is here

| File | What it is |
|---|---|
| `tap-draft-circuit-pin-manifest.md` | Draft TAP 1: the pin manifest (format, binding, publication, commitment, profiles) |
| `tap-draft-stateful-consumers.md` | Draft TAP 2: how a consumer contract keeps latch state, records beats and pins the evaluator |
| `assets/pin-manifest.schema.json` | JSON Schema (draft 2020-12) of the manifest |
| `assets/covenant-v1.pins.json` | Covenant interface v1 as a profile. Generated; do not edit by hand |
| `assets/covenant-v1.vectors.json` | Worked conversions with that profile. Generated |
| `assets/gen_covenant_manifest.py` | Generator of the two files above. Imports `chips/golden/kernel_model.py`, parses `chips/INTERFACE.md` section 2 |
| `assets/pins_reference.py` | Reference implementation (MIT): strict file reader, validator, binding and profile checks, field codec, state word helpers, replay check, keccak256 |
| `assets/make_vectors.py` | Generator of the three files below, using TAP-20's `reference.py` from `chips/vendor/tap-20/` |
| `assets/shift-toggle.pins.json` | Circuit manifest of the example circuit (9 latches, 5 NAND, 71 bytes) |
| `assets/manifest-vectors.json` | Test vectors of draft 1 |
| `assets/replay-vectors.json` | Test vectors of draft 2 |
| `assets/ReferenceConsumer.sol` | Reference consumer of draft 2 (MIT, not audited) |
| `assets/deployments-check.json` | Raw reads behind the Deployments table of draft 2 |
| `assets/check_assets.py` | Runs the schema and the reference validator over every manifest |
| `.venv/` | Local virtual environment with `jsonschema` 4.26.0. Ignored by git (`.gitignore` line 4) |

To regenerate and check everything (all three commands are deterministic and write only inside `docs/taps/assets/`):

```
~/.local/bin/python3.12 -B docs/taps/assets/gen_covenant_manifest.py
~/.local/bin/python3.12 -B docs/taps/assets/make_vectors.py
docs/taps/.venv/bin/python -B docs/taps/assets/check_assets.py
```

Last run: `covenant-v1.pins.json` is 7,285 bytes, SHA-256 `0x77a721cda1c499ae4ffcad1a02a9bbb75bfce2a5773e587adbc77bd660756eb5`; `shift-toggle.pins.json` is 1,323 bytes, SHA-256 `0x990990d0522a05d95881ae22eab2798d5dcb9f8e49236e97968bca6b26a0237a`. **Both passed the JSON Schema (jsonschema 4.26.0, `Draft202012Validator`) and the reference validator.** The 4 valid manifests of the vector file pass both; the 24 invalid ones are all refused by the reference validator, 15 of them by the schema alone (the other 9 break rules a schema cannot express: overlap, order, range against `nIn`, unique names, and so on); the 11 malformed files are refused by the strict reader. Both generators reproduce their files byte for byte when run again.

The generator of the Covenant profile types no layout number. Offsets and widths come from `INPUT_FIELDS` and `OUTPUT_FIELDS`; `nIn`, `nOut` and the largest code from `IN_BITS`, `OUT_BITS` and `LG8_MAX`; the unit share (256) and the progress and lock scales (255) are recovered by calling `route_tax`, `prog_code` and `lock_code` and asserted; the shape numbers (1 to 256 latches, 3,400 gates, 24,000 bytes) are parsed from `chips/INTERFACE.md` section 2. The script also checks that the bit ranges printed in INTERFACE.md sections 5 and 6 equal the model's layouts (they do), and that the generic codec reproduces `chips/golden/vectors.json`: 64 input words, 60 output words, 3,623 `lg8` points, 1,024 `exp8` points and 6 state words.

## 2. Why two drafts and not one

The brief allowed one file or two. The TAPs process asks for one topic per TAP in three places: TAP-01 section 4 ("Editors judge whether a TAP is complete, coherent and on one topic"), the editors' checklist in CONTRIBUTING section 4 ("It covers one topic; the Summary is one sentence") and the pull request template. The two concerns are separable: a combinational circuit benefits from a manifest and has no state; a consumer can follow the state convention without publishing a manifest. They also have different neighbours in the repository: the manifest overlaps an open Idea (#44, see section 5), the consumer convention overlaps nothing. Two drafts let the second go forward while the first is discussed. So `tap-draft-pin-manifest-and-stateful-consumers.md` was not written; the two files above replace it.

Both are type **Application** (TAP-01 section 3: "Conventions that applications may adopt on top of Standards TAPs: ... metadata formats"). Neither changes TAP-10 or TAP-20.

## 3. The TAPs repository today

Read with `gh api` at commit `27b7a5fb6ffb0d1360dc2083ff1a34bb57db1239` (2026-10-04T15:56:06Z), the same commit as `chips/vendor/tap-20/`.

| TAP | Title | Type | Status | Notes |
|---|---|---|---|---|
| TAP-01 | TAP Purpose and Process | Process | Draft | Follows EIP-1; adds the status Candidate |
| TAP-10 | DeWEB Access and Messaging Layers | Standards | Draft, v1.1 | Containers, names, site store, payment contract, hub; Deployments for three chains |
| TAP-11 | TapeAPI Service Manifest and Holder Delegation | Application | Draft | A JSON manifest at `/.well-known/tapeapi.json` in a container; canonical JSON (section 6) |
| TAP-12 | Sealed Commitments and Verdicts over TapeSend | Application | Draft | Merged 2026-10-04 |
| TAP-13 | Signed Responses for Container Services | Application | Draft | Merged 2026-10-04 |
| TAP-20 | Circuit Netlist Format and Evaluation Semantics | Standards | Draft | The netlist format; verified against BNB Smart Chain only |

The README index lists TAP-01, 10, 11 and 20; PR #43 adds 12 and 13. Licence: text CC0 1.0, code under `assets/` MIT (`LICENSE`, CONTRIBUTING section 7).

Open draft pull requests: #12 Private Channels (Standards), #14 Encrypted Private Files (Application), #16 MCP Tools as Container Service Methods (Application), #18 Attested Reads (Application), #20 Private Groups (Standards), #23 TapeUP Native Assets (the editors asked for it to be closed and reworked), #26 AI Usage Receipts (Application), #28 Proof-Verified Reads (Standards), #47 Container Agent Mandates, Phase 0 (Application). Other open pull requests: #35 and #36 (TAP-11 follow-ups), #43 (README), #45 (renumber TAP-20 to TAP-02), #46 (TAP-13 wording).

Open Ideas: #5, #7, #9, #11, #13, #15, #17, #19, #21, #22, #25, #27, #29, #30, #33, #34, #38, #40, #41, #42, #44. Issue #31 is the editors' queue and explains how drafts are handled.

## 4. The submission process the repository expects

From README, CONTRIBUTING, TAP-01 and issue #31:

1. Search the TAPs and the open issues (done, section 5).
2. Open an issue with the **Idea** template: title `Idea: <short title>`, label `idea`, four parts (Problem, Proposal, Type, Builds on). One Idea per TAP. Wait for feedback before the pull request.
3. Copy `TAP-template.md` to `TAPs/TAP-draft-<short-title>.md`. Preamble: `tap: TBD`, `title`, `description` (one sentence), `author` (`Name (@handle)`), `discussions-to` (the Idea issue), `status: Draft`, `type`, `created`, `requires`, `license: CC0-1.0`. Heading `# TAP-TBD: <Title>`.
4. Sections in this order: Summary (one sentence, no key words), Abstract, Motivation, Specification, Rationale, Backwards Compatibility, Test Cases, Reference Implementation, Deployments, Security Considerations, Copyright. Key words in capitals, only in the Specification.
5. Vector files go in `assets/tap-draft-<short-title>/` while the pull request is open.
6. Open a pull request that adds only the TAP file and its assets, with the pull request template filled in (what it does, the Idea issue, six author checks).
7. Editors check the format, not the merit. They assign the number (the lowest above 10 that is neither reserved nor used; multiples of ten are reserved; today that would be 14), rename the file to `TAPs/TAP-<nn>.md` and the assets to `assets/tap-<nn>/`, and merge as Draft. Merging as Draft is not acceptance.
8. Before Review: test vectors that a reference implementation reproduces, the reference implementation linked at a fixed commit, deployed addresses verified read-only, Security Considerations. Review lasts at least 14 days. A TAP that depends on an upgradeable contract can reach Candidate and becomes Final only once that contract is sealed.

How our files map to the repository:

| Here | In TapeOutProtocol/TAPs |
|---|---|
| `tap-draft-circuit-pin-manifest.md` | `TAPs/TAP-draft-circuit-pin-manifest.md` |
| `assets/pin-manifest.schema.json`, `pins_reference.py`, `make_vectors.py`, `check_assets.py`, `shift-toggle.pins.json`, `manifest-vectors.json`, `covenant-v1.pins.json`, `covenant-v1.vectors.json` | `assets/tap-draft-circuit-pin-manifest/` |
| `tap-draft-stateful-consumers.md` | `TAPs/TAP-draft-stateful-consumers.md` |
| `assets/replay-vectors.json`, `ReferenceConsumer.sol`, `deployments-check.json` | `assets/tap-draft-stateful-consumers/` |
| `assets/gen_covenant_manifest.py` | Stays in this repository: it imports the Covenant model. The TAPs repository gets the generated JSON |

The drafts already refer to their assets by the repository paths. `make_vectors.py` writes all three vector files next to itself and looks for TAP-20's `reference.py` in `../tap-20`, which is where it is in the TAPs repository; for the second pull request either copy `make_vectors.py` and `pins_reference.py` into its asset directory too or split the script.

## 5. Overlaps found

**Idea #44, "Semantic Port Mapping for TAP-20 Circuit Interfaces"** (opened 2026-10-04 15:55 UTC by `259906573-ship-it`, another entrant of the hackathon; no comments, no draft file). It describes the same gap as draft 1 for stateless circuits: a mapping between named, typed values and TAP-20 bit ranges. It shows an experimental JSON shape and says "This is not a final schema". Its open questions 5 to 7 are the ones draft 1 answers (signedness, scale and unit; how a mapping is bound to a circuit; where it lives and how its provenance is established). It says that stateful interfaces are outside its evidence.

What this means for us:

- Draft 1 must not be submitted as a competing Idea. The honest route is a comment on #44 that offers the draft as input, and an agreement with its author and the editors on one text and its authorship. Draft 1 says so in its Motivation, Rationale and Open questions.
- No text or schema was taken from #44. Our field members (`name`, `offset`, `width`) come from the tuples of `kernel_model.py`; #44 uses `bitOffset`, `bitWidth`, `port` and `type`, and binds by `chainId`, processor and circuit id where draft 1 binds by the netlist hash.
- If the two become one TAP, the member names are a detail to settle there.

**Nothing overlaps draft 2.** No TAP, draft or Idea mentions latch state, `step` consumers or replay (`grep` for `netlist`, `circuitInfo` and `latch` over the nine open draft files returns nothing).

Related, not overlapping: TAP-11 (the precedent for a manifest as a site file; draft 1 follows its reading procedure and file rules); PR #16 (pins tool definitions by a SHA-256 in a manifest); Idea #30 (release manifests; the editors' comments there on discovery paths and on what `requires` must list were followed); PR #28 (proofs of reads; could prove `netlist` and `fileInfo` reads); PR #45 (if TAP-20 becomes TAP-02, `requires` and every reference change).

`.well-known/` keys already used by TAPs and drafts: `tapeapi.json`, `tape-channel.json`, `tapeapi-mandates.json`, `tape-20.json`. `tape-pins.json` is free.

## 6. What was verified, and how

All reads are `eth_call`, `eth_getStorageAt`, `eth_getCode`, `eth_estimateGas` or `eth_getLogs` against public nodes. `F` is the factory `0x1f09daefa827f02cbb40967cc91b259763760761`, `RPC` is `https://rpc.xlayer.tech`.

### 6.1 Processor contracts and the factory

| Claim | Result | How |
|---|---|---|
| The factory is not sealed and is owned by a 3-of-5 Safe | `isSealed()` false on X Layer, Base and BNB Smart Chain; owner `0xB3D85b42A045c1A88D800CAD0F55d2566a4D3138`; on X Layer `getThreshold()` = 3, `getOwners()` = 5 addresses | `cast call $F 'isSealed()(bool)'`, `cast call $F 'owner()(address)'`, `cast call <owner> 'getThreshold()(uint256)'` |
| Beacon, implementation, code hashes | `assets/deployments-check.json`: X Layer block 72,376,227, Base 52,177,964, BNB Smart Chain 125,739,381. All match TAP-10 Deployments. The implementation address is the same on X Layer and Base, the code hash is not | `cast call $F 'circuitBeacon()(address)'`, `cast call <beacon> 'implementation()(address)'`, `cast keccak $(cast code <impl>)` |
| A processor is a beacon proxy whose beacon is fixed | 295 bytes of code, code hash `0x57aa306f...17d5` as in TAP-10; ERC-1967 beacon slot holds `0xf70d1ed4...991C`; the beacon address is in the code | `cast storage <processor> 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50` |
| `step` is a view and the contract keeps no state | Vendored source: `step` and `eval` are `view`; `Circ` has no state field | `contracts/vendor/tapeout-xlayer/src/Circuits.sol` |
| No `beat` function | Selector `0x1fc0021d` is absent from the implementation code on all three chains; `cast call <processor> 'beat(address,uint256,bytes)' ...` reverts with empty data on X Layer and BNB Smart Chain | `cast code <impl> | grep -c 1fc0021d` |
| `nextId()` is the last id, not the next | X Layer processor 0: `nextId()` = 103, `circuitInfo(103)` answers, `circuitInfo(104)` reverts `no circuit`. BNB Smart Chain processor 0: 11640, same behaviour. Source: `circuitId = ++nextId` | `cast call <processor> 'nextId()(uint256)'` |
| No per-circuit metadata | `tokenURI(1)` returns `""` | `cast call <processor> 'tokenURI(uint256)(string)' 1` |
| `step` reads strings leniently and returns exact lengths | X Layer block 72,373,447, circuit 1 of processors 273, 261, 172 and 252 (9, 16, 288 and 1 state bits): result equals TAP-20's `reference.py`; `newState` is `ceil(nState/8)` bytes with unused bits zero; the 32-byte word gives the same result; bits and bytes beyond `nState` are ignored; a short string reads the missing bits as zero | Example: `cast call 0xA30706F2BD6EEF04d07a4359CEc270697fE3947c 'step(uint256,bytes,bytes)(bytes,bytes)' 1 0x0102 0x05` returns `0x0204 0xf6`, and so does the same call with `0x0102` followed by 30 bytes of `00` or of `ff` |
| Gas of a beat | `eth_estimateGas` of `step` at block 72,375,573: 7,140,062 for 3,035 gates, 8,343,781 for 3,562, 11,439,245 for 4,863: about 2,340 gas per gate | `cast estimate <processor> 'step(uint256,bytes,bytes)' <id> <state> <inputs>` |
| Log queries are limited | `eth_getLogs` over 1,000 blocks is refused by `rpc.xlayer.tech` and `xlayerrpc.okx.com` with `block range greater than 100 max` | `curl` with `eth_getLogs` |
| Counts used in the Motivation sections | X Layer block 72,371,934: 275 processors, 2,820 circuits (`nextId` summed), 286 with `nState > 0`, of which 231 are copies of one 31-byte REF netlist and 55 are flat; 53 of the 55 are latches-first; `nState` up to 288; 493 circuits with `nIn + nOut > 16`; largest `nIn` 161, `nOut` 199 | A scan with batched `eth_call` (batches of 10: the node refuses larger ones) of `cpuAt`, `nextId`, `circuitInfo` for every circuit and `netlist` for the 286 |

### 6.2 Containers and the site store

Sources read: the verified source of the site store implementation `0xa85c4143d1D4A77f54b8e4ecC9E6D1418Afea45f`, of the container opener `0x536adD8F30f03b69f6fbF29d425A816A0dC50106` and of the payments table, from `https://www.oklink.com/api/v5/explorer/contract/verify-contract-info?chainShortName=XLAYER&contractAddress=<address>` (the endpoint the vendored README names; it is rate limited).

| Claim | Result |
|---|---|
| Who can write a site | `SiteRegistry.onlyEditor`: the container's valid signer (the holder of the circuit NFT, container opened, not listed on the market) or an operator whose setter is still the holder; operators last at most 30 days |
| `putFile` replaces a file and records a declared hash | Source: `delete f.chunks`, `f.sha256Hash = sha256Hash`; the comment says the hash is declared by the uploader and not checked on chain |
| The opener | Not upgradeable, no owner; `FEE` = 0.08 OKB (a constant); anyone can open any circuit's container |
| Live values, X Layer block 72,375,522 | Site store implementation slot `0xa85c4143...a45f`, payment contract implementation slot `0x5ebf29b8...47df` (both as TAP-10 lists), both owned by `0xE4fc10592FA8ad7c408B81e99CfC54Ef4B14283d`; `monthlyFee()` = 0.026 OKB; `fileInfo(container, ".well-known/tape-pins.json")` on an opened container returns zeros with `chunkCount` 0 |

On a **local anvil fork** of X Layer at block 72,374,876 (nothing sent to the chain; a throwaway key funded with `anvil_setBalance`):

1. `createCPU`, `mint`, `tapeout` of the two example netlists: accepted; `circuitInfo` = (2, 2, 9, 14) and (2, 2, 9, 15); `keccak256(netlist(1))` = `0x4d4d8bb4...fa00`, the hash in the vectors.
2. `step` on the fork returned the vector values for 41 of 41 calls. `eval` on the same circuit reverts `has latch: use step`.
3. `putFile` before opening reverts `NotOwner`. `open` with 0.08 OKB succeeds, also from an address that is not the holder, which gains no write access. The holder's `putFile(container, ".well-known/tape-pins.json", "application/json", sha256, bytes)` succeeds (593,377 gas for 1,323 bytes); `fileInfo` returns the size, the declared hash and `chunkCount` 1; `read` returns the bytes.
4. A second `putFile` replaces the file and changes `sha256Hash` and `updatedAt`.
5. After `transferFrom` of the circuit NFT to a contract, `canEdit` is false for the previous holder and for the operator it had set, `operatorOf` returns zero, and `putFile` from the previous holder reverts `NotOwner`. The file stays as it was.

On a second fork at block 72,376,024, `ReferenceConsumer.sol` (compiled with solc 0.8.28) was bound to the example circuit: `pinnedEvaluator()` returned the beacon, the implementation, its code hash and the netlist hash; 12 calls of `beat` produced the 12 records of `replay-vectors.json` (`beatAt`), about 180,000 gas each; input strings `0x07`, `0x` and `0x0300` were refused; after `upgradeCircuits(<copy of the same code at another address>)` sent as the impersonated factory owner, `evaluatorUnchanged()` was false and `beat` reverted `EvaluatorChanged`, although `step` still answered; after the owner restored the implementation the consumer ran again. This also confirms that the owner's one call changes every processor, and that a restored implementation leaves no difference in the pinned address and code hash.

### 6.3 Not verified

- Base and BNB Smart Chain site contracts were not read again; draft 1 says so.
- The alternate-evaluator path of draft 2 has no generic reference contract. Covenant's `SealedVM` is one, in another track's directory.
- The examples were not put on a real chain. That would cost tape-out and container fees and needs the user's decision.
- `ReferenceConsumer.sol` has no test suite beyond the fork run above.
- The full reader procedure of draft 1, section 2.1 (node agreement, pinned block, site status) has no reference code: `pins_reference.py` works on bytes that are already read.

Provenance of code in `assets/`: everything was written for these drafts. `keccak256` in `pins_reference.py` follows the structure of the Keccak team's public-domain `CompactFIPS202.py` and was checked against `cast keccak` and against `tapc`'s own implementation. `make_vectors.py` imports TAP-20's `reference.py` (MIT) from `chips/vendor/tap-20/` and does not copy it. If the team records provenance in `docs/THIRD_PARTY.md`, these two lines belong there; that file is outside this track's directory.

## 7. Design decisions in brief

- **Where the manifest lives:** the file `.well-known/tape-pins.json` in the circuit's own container, in the site store. It can be found from the circuit alone, needs no new contract, and is verified as every TAP-10 file is. It is not under `/.tape/`, which gateways reserve.
- **How it is bound:** the manifest states `keccak256` of the netlist and the pin counts; a reader checks them against `netlist(id)` and `circuitInfo(id)`. It does not name a processor or an id, so it can be written before tape-out and one manifest serves every copy of a netlist. A netlist with REF records also needs `chainId`.
- **How a swap is noticed:** site files can be replaced by the holder, so a contract commits to the SHA-256 of the manifest file through `pinManifestOf(address,uint256)` (`0x67b68875`). The SHA-256 of the file bytes is the hash the site store already records. Candidates rejected and why (draft 1, Rationale): a hash kept only by the taping-out contract (not every circuit has one, and the processor contract does not expose the tape-out caller to `eth_call`; the general form covers it), an event (contracts and `eth_call` cannot read it, public nodes cap log queries), bits in the netlist (no free bytes; dead gates cost transistors), a registry contract (a new contract with an owner question).
- **Activation:** unlike TAP-11, a manifest in an `unpaid` site is still read and the status is shown, because a circuit held by a contract can never be activated. This is the point most likely to be contested; it is listed as an open question.
- **State layout:** the state string is exactly what `step` returns: TAP-20 packing, `ceil(nState/8)` bytes. Up to 256 latches it may be kept as one `bytes32`, string first, zero bytes after. That word may be passed to `step`. Latches-first netlists are recommended.
- **Replay:** every record holds source, inputs, outputs and state after; one TAP-20 beat from the previous state and the inputs must give the recorded state and outputs. Records without a beat have source 0 and leave the state unchanged.
- **Pinned values:** the beacon's implementation, the implementation's code hash, the netlist hash and the pin counts, compared before every beat in the same transaction.

## 8. How Covenant stands against the drafts

Read from `chips/INTERFACE.md` and from `contracts/core/src/Kernel.sol`, `KernelFactory.sol` and `contracts/evaluator/src/Fab.sol` as they were on 2026-10-04 evening. Other tracks own those files; nothing was changed.

**Draft 2 (consumers).** The kernel meets the requirements of sections 2 to 6: word form; the 32-byte word is passed to `step`; the returned lengths are checked and the bytes after the returned string are cleared; a failed step changes no state and is either a revert or a flagged record; a gas floor is checked before the call; records are readable with `records(n)` and emitted in `Settled`; it pins the implementation, its code hash, the pin counts and the netlist hash, and switches to `SealedVM` on a difference. Record flags map to `source`: `FALLBACK` is 0, `SEALED` is 2, otherwise 1. What the kernel does not do:

- It does not implement `ICircuitConsumer` (section 7, a SHOULD). An adapter in `Lens.sol`, which is not frozen, could expose `beatAt`, `circuitState` and `pinnedEvaluator` from `records`, `state` and `globals`.
- `_step` does not check that the unused bits of the last state byte are zero (section 4 step 4, a SHOULD). It matters only for chips whose `nState` is not a multiple of 8.
- The `beacon` is a constructor argument of `KernelFactory`. A deployment script should assert that it equals the processor's ERC-1967 beacon slot; a reader of draft 2 makes that comparison.

**Draft 1 (manifest).** `covenant-v1.pins.json` is the profile. Each chip still needs its own circuit manifest: the profile's fields, plus `circuit.netlistHash`, `nState`, the chip's `state` fields and the `profile` claim. `tapc` already has that information in its `tapc-pins/1` files (`name`, `lsb`, `width`; `lsb` is the draft's `offset`) and in `<chip>.manifest.json`; a converter is small and was not written because the toolchain belongs to another track. Two things need a decision:

- **Publication.** A manifest can be written to a chip's container only while a wallet holds the chip. Once the chip is in a kernel nobody can write that site (verified, 6.2 step 5). So the order would be: tape out, open the container (0.08 OKB), `putFile`, then hand the chip to the kernel. The fee is the same opening fee the plan already budgets once for the site container; it would be paid per chip.
- **Commitment.** Neither the kernel nor the Fab has `pinManifestOf`. The frozen Fab ABI has one free 32-byte value per chip, `templateId` ("the caller's tag, recorded as given"). If it is not needed for anything else, passing the manifest's SHA-256 as `templateId` fixes the manifest at tape-out with no ABI change, and a view in `Lens.sol` can return it as `pinManifestOf`. Whether `templateId` is used this way is still open.

## 9. `chips/INTERFACE.md` against the TAPs and the deployed contracts

No hard conflict was found. Four points worth knowing:

1. **Line 36**, "It passes all 32 bytes to `step` and stores `bytes32(newState)`." TAP-20 section 5 says: "Callers SHOULD send exactly `ceil(n / 8)` bytes with zero padding; a conforming evaluator MUST read other byte strings the same way as the contracts." The kernel departs from a SHOULD, not from a MUST, and the result is the same: verified in the source (`_getBit` returns 0 beyond the string and never reads beyond `nState`) and on X Layer (section 6.1). Draft 2 allows the word form for this reason.
2. **Lines 34 and 36** use two meanings of a 32-byte value. Line 34: "A word is the little-endian integer of those bytes." Line 36: the state is "one `bytes32` holding the TAP-20 byte string right-padded with zeros". A reader that takes the `bytes32` state as an integer and applies `(word >> o)` gets wrong fields: state bit 0 is at bit 248 of that integer. The golden vectors keep the two apart (`bits` and `bytes32`); the text does not warn. Both drafts state the rule.
3. **Line 223** lists three pinned values ("`beacon.implementation()`, the implementation's code hash, or `keccak256(Circuits.netlist(chipId))`"). `Kernel._sealedMode` also compares `circuitInfo` (`nIn`, `nOut`, `nState`, `gateCount`) and the netlist length. The code does more than the document says.
4. **Line 239**, "a 3-of-5 Safe can upgrade processor logic": confirmed (section 6.1). **Line 51**, "X Layer has no Osaka": an `eth_call` of code using the `CLZ` opcode returns `EVM error: NotActivated` on X Layer and 255 on Base. **Line 201**, "public RPCs cap log queries at 100 blocks": confirmed.

The layouts of sections 5 and 6 of INTERFACE.md equal `kernel_model.py` (checked by the generator on every run).

## 10. Two observations about TAP-20 itself

For its author, when the drafts are discussed:

- Section 6 lists `nextId()` as "the id the next taped-out circuit will get". On X Layer and on BNB Smart Chain it returns the id of the last circuit (section 6.1). `web/NOTES.md` in this repository found the same.
- Section 6 says a processor contract "also exposes a state-changing `beat(address cpu, uint256 id, bytes inputs)` (`0x1fc0021d`) that keeps state on chain". The selector is not in the implementation on any of the three chains.

## 11. Open questions for the maintainers

1. Should draft 1 and Idea #44 become one TAP? Who authors it?
2. May a manifest in a site whose name is not activated be used, with its status shown? TAP-11 applies activation to service resolution; draft 1 argues that a pin manifest is different.
3. Are the key `.well-known/tape-pins.json` and the member name `tapepins` acceptable?
4. Where is the `beat` function that TAP-20 section 6 mentions, and how does it keep state? Draft 2 should align with it if it exists.
5. Where is the "component interface TAP draft" that TAP-20's Rationale mentions? Does it define port metadata?
6. Would the owners add a view that returns the tape-out caller of a circuit? Today it is only in logs.
7. For consumers of circuits with REF records: should the reader interface expose pinned values for the REF closure?
8. Is there a safe on-chain way for a consumer to stop comparing pinned values once the factory is sealed?
9. If PR #45 renumbers TAP-20 to TAP-02, both drafts change `requires` and their references.

## 12. Before anything is submitted

- Fill in `author` (the GitHub handle `@OoJae` is in the files; the name is a placeholder) and `discussions-to` in both drafts.
- Publish the repository and replace the two "link at a fixed commit will be added" sentences.
- Draft 1: comment on Idea #44 first. Draft 2: open its own Idea issue.
- Run the three commands of section 1 again, and `deployments-check` on the day; update block numbers and digests in the texts if anything changed.
- The Copyright line links to `../LICENSE`, which resolves in the TAPs repository, not here.

## 13. Draft texts for the Idea stage

The process starts with an Idea issue (section 4). These are drafts for the team to edit. They have not been posted.

**A comment on Idea #44 (draft 1).**

> We met the same gap from the other side: a contract that writes 96 input bits and reads 112 output bits of a sequential circuit every epoch, and a front end that has to show what each recorded beat meant. We wrote a full draft before we saw this Idea and would rather contribute it here than open a competing one.
>
> It gives one possible answer to three of your open questions. Question 5 (types): eight encodings (`uint`, `int`, `bool`, `enum`, `flags`, a logarithmic amount code, `zero`, `bits`), with `min`, `max`, `scale` and `unit`, and rules for values an encoder must refuse. Question 6 (binding): the manifest states `keccak256` of the netlist and the pin counts instead of a chain, processor and circuit id, so it can be written before tape-out and cannot be attached to another netlist. Question 7 (where it lives): `.well-known/tape-pins.json` in the circuit's container, read the way TAP-11 reads its manifest, with an optional one-function commitment so that a contract can fix the SHA-256 of the manifest it was built against. It also names the bits of the state vector, which your evidence leaves out.
>
> Draft, JSON Schema, a dependency-free reference implementation and test vectors: `<link at a fixed commit>`. Would you prefer one TAP with joint authorship, or two TAPs with a clear line between them? We are fine with either, and with your member names if the editors prefer them.

**An Idea issue for draft 2.** Title: `Idea: Stateful circuit consumers: keeping latch state and replayable beats (Application, builds on TAP-20)`

> **Problem.** A circuit with LATCH records has state, but a processor contract stores none: `step` takes the state from its caller. Every contract that uses a sequential circuit therefore decides alone how to store the state, what to pass to `step`, what to do with a result of the wrong length, what to record, and how to notice that the upgradeable circuit implementation has changed. On X Layer 286 of 2,820 circuits have state (block 72,371,934). Without a shared form, a third party cannot check that a contract stored what its circuit computed, and small byte-handling mistakes (a state cut to 32 bytes, a `bytes32` read as an integer) change what the circuit sees without any error.
>
> **Proposal.** A convention for such contracts: the state is kept as the TAP-20 packed byte string that `step` returns, or as one `bytes32` with zero padding for up to 256 latches; returned lengths are checked; every beat leaves a record (inputs, outputs, state after), and one TAP-20 beat from the previous state must reproduce it; records without a beat are marked; the contract pins the beacon's implementation, its code hash, the netlist hash and the pin counts and compares them before each beat. A small read interface lets explorers read any such contract. Draft, vectors and a reference contract: `<link at a fixed commit>`.
>
> **Type.** Application.
>
> **Builds on.** TAP-20. One question for the editors: TAP-20 section 6 mentions a state-changing `beat(address cpu, uint256 id, bytes inputs)` (`0x1fc0021d`); we could not find that selector in the circuit implementation on X Layer, Base or BNB Smart Chain. If it exists elsewhere, the draft should align with it.
