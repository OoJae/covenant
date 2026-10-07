# Notes on the TAP drafts in this directory

Written on 2026-10-04, updated on 2026-10-07. **Nothing has been submitted:** no issue, pull request or comment was opened anywhere, and no transaction was sent to any chain. The 2026-10-07 update made read-only calls only (`gh api` on the TAPs repository, `eth_call` on X Layer). The texts to post are in `POSTS.md`, waiting for approval.

The circuit netlist standard was numbered TAP-20 until PR #45 (merged 2026-10-04, after TAP-01 §6.1 was changed by PR #48 to reserve 2 to 9 for foundational standards). It is TAP-02 now, and these notes use that name except where they quote older text. Its section numbers did not change.

## 0. Status on 2026-10-07

| Draft | State | Next step (each needs your OK) |
|---|---|---|
| 1, Circuit Pin Manifest | Ready to offer to #44 | Comment (a) of `POSTS.md` on #44; a pull request only if #44's author or an editor agrees |
| 2, Stateful Circuit Consumers | Ready for the Idea stage | Idea issue (b), then the fork, then the pull request with body (c) after feedback |

### 0.1 What changed in this revision

1. **Numbering.** TAP-20 became TAP-02 in both drafts, the generators, the vector notes and the comments of `pins_reference.py`. Each draft keeps one historical note, "numbered TAP-20 until PR #45", in its Motivation. `requires` is `TAP-02, TAP-10` for draft 1 and `TAP-02` for draft 2. The text of `TAPs/TAP-02.md` at upstream commit `075dd834` equals the vendored `chips/vendor/tap-20/TAP-20.md` except for the number, the author's display name, `updated` and four asset paths, so every `§` reference still holds. `assets/tap-02/reference.py` upstream is byte-identical to the vendored one (SHA-256 `0e851594…9fa9`).
2. **Front matter.** `author: <NAME> (@OoJae)` (you give the name at posting time) and `discussions-to: <ISSUE-URL>` in both drafts.
3. **Fixed-commit links**, at `https://github.com/OoJae/covenant/blob/fc90bbf/...` (the repository is public; `fc90bbf` is `fc90bbf69f7686368c34b8c8d789aa8a3b3ee16c`). Draft 1, Reference Implementation: `chips/golden/kernel_model.py`, `docs/taps/assets/gen_covenant_manifest.py` and `contracts/evaluator/src/Fab.sol`, with one new sentence: the Fab records a caller-supplied manifest digest per chip and returns it from `chipInfo`, without checking it and without `pinManifestOf`. Draft 2, Reference Implementation: `contracts/core/src/Kernel.sol`, `contracts/core-v2/src/KernelV2.sol` and `contracts/evaluator/src/SealedVM.sol` (both kernels were checked for the behaviour the draft describes: word form, length checks, pinned values, sealed fallback, stored records).
4. **Draft 1 and #44/#50.** The Motivation now cites #44's three placements (its author's comment of 2026-10-05: an optional section or profile around TAP-02, a companion application profile, or the component-interface work) and says that draft 1 takes the second. It cites the boundary that #50's author proposed on 2026-10-06 (what a component exposes / how components are connected / how the netlist is represented) and puts draft 1 on the first side: one circuit's pins, nothing about connections. The Rationale gains "A companion TAP, not a part of TAP-02" and a rewritten "Relation to Ideas #44 and #50"; "Left out" names connections; open question 1 now asks "one TAP with joint authorship or two TAPs", question 5 notes that #44 and #50 ask the same, and question 7 (member names) is new.
5. **Draft 2.** The Specification no longer cites TAP-10 (the term "Pinned value" compared itself to TAP-10 §6.1); the comparison moved to the Rationale, so `requires: TAP-02` covers every TAP its Specification cites. "Left out" says that connecting stateful circuits, which #50 lists as open, is not covered.
6. **Generators split.** `make_vectors.py` is gone. `make_manifest_vectors.py` (draft 1) writes `shift-toggle.pins.json` and `manifest-vectors.json`; `make_replay_vectors.py` (draft 2) writes `replay-vectors.json` with the new `replay_reference.py` (state helpers, `replay`, `keccak256`, `scan`), so each asset directory stands alone. The nine functions it shares with `pins_reference.py` are the same code (compared by syntax tree, docstrings aside). Both generators look for TAP-02's `reference.py` in `$TAP02_REFERENCE_DIR` (which must hold it if set), then `../tap-02`, then `chips/vendor/tap-20`, and print the file and SHA-256 they used.
7. **Outputs.** `covenant-v1.pins.json`, `covenant-v1.vectors.json`, `shift-toggle.pins.json` and `pin-manifest.schema.json` are byte-identical. `manifest-vectors.json` differs only in two strings that name the generator (`note`, `conformance.profileFile`); `replay-vectors.json` differs only in `note`. Both were compared member by member against the previous files, and both generators reproduce their files when run again, with the vendored reference and with the upstream one.
8. **`check_assets.py`** first checks the SHA-256 of `covenant-v1.pins.json` (must be `0x77a721cd…6eb5`), `shift-toggle.pins.json` and `pin-manifest.schema.json`, with the standard library only, then runs the schema checks as before. A copy with one byte of `covenant-v1.pins.json` changed fails (tried).
9. **`gen_covenant_manifest.py`** had stopped at an assertion: commit `32779cc` (2026-10-05) reworded `chips/INTERFACE.md` section 2 to `112 <= nNand + nLatch <= 3400`. Its pattern now accepts the lower bound (the profile has none), and it again writes both files byte for byte. The copy at `fc90bbf`, which draft 1 links, still has the old pattern.
10. **New:** `assets/lint_tap.py`, `export_upstream.py`, `POSTS.md`.

### 0.2 Results

| File | Bytes | SHA-256 |
|---|---|---|
| `covenant-v1.pins.json` | 7,285 | `0x77a721cda1c499ae4ffcad1a02a9bbb75bfce2a5773e587adbc77bd660756eb5` (unchanged) |
| `pin-manifest.schema.json` | 6,756 | `0xeb5c7df2482277369b4c99f86385d57547b3c0adc001031ffe13fb2bb0442033` (unchanged) |
| `shift-toggle.pins.json` | 1,323 | `0x990990d0522a05d95881ae22eab2798d5dcb9f8e49236e97968bca6b26a0237a` (unchanged) |
| `covenant-v1.vectors.json` | 8,479 | `0xffbef49915363dbfb8ab731c86c534534eb594b453a7f502d21e2a6dc7e42656` (unchanged) |
| `manifest-vectors.json` | 74,381 | `0x22c0a62d21617ae131def26d7a198a836b82e9f4bcfd8b8d49be2ae4e69bfb88` (was `0x70b900d1…`) |
| `replay-vectors.json` | 23,862 | `0x5e8fa76cb806141e33afeeb0d7e2e942ade60d6659678c9bf4bf8da83ef02a75` (was `0xa55bf2dc…`) |

- `lint_tap.py` against the upstream `TAP-template.md`: both drafts 0 errors, 2 warnings each (the placeholders `<NAME>` and `<ISSUE-URL>`). With `--posting` those two are errors, as intended. As a check of the lint itself: upstream TAP-12 and TAP-13 pass; TAP-02 gets one error (its Specification cites TAP-10, which its `requires` omits) and TAP-11 one (it mentions "TAP-20" as TapeAPI's old self-assigned name, which the renumbering rule flags).
- `check_assets.py`: all checks pass (4 valid manifests pass the schema and the validator; 24 invalid ones are refused by the validator, 15 by the schema alone; 11 malformed files are refused by the strict reader).
- `export_upstream.py` into a copy of the upstream tree at `075dd834`: both drafts laid out, both generators found `assets/tap-02/reference.py` through `../tap-02` and reproduced their files byte for byte, `check_assets.py` and the lint passed. With `--author-name`, `--discussions-to` and `--posting` on draft 2: 0 errors, 0 warnings.
- X Layer, read on 2026-10-07 at block 72,589,084: `isSealed()` false; beacon `0xf70d1ed4…991C`; implementation `0x977f2178…29B2` with code hash `0x7a15c353…1b30`, as on 2026-10-04; selector `0x1fc0021d` still absent. The Fab's `chipInfo(2)` and `chipInfo(5)` return `manifestHash` `0xfe8b7a49a7d0f9a75d0684b88587648284fc586f936035f8831cb6d34060e209`, the SHA-256 of `chips/out/fg.pins.json`, which claims `covenant-v1` by `0x77a721cd…6eb5`. This is why that file must not change.

### 0.3 Open questions for you

1. The name for `author` (both drafts).
2. `discussions-to` of draft 1: #44's URL is the natural value while the draft is offered there.
3. The links in `POSTS.md` to the drafts themselves need the commit that contains this revision (`<COMMIT>`): commit and push first. `fc90bbf` has the older text.
4. Short or full commit hashes in the drafts' links. The drafts use `fc90bbf` as asked; #49 upstream used a full hash. The full one is above.
5. The link to `gen_covenant_manifest.py` at `fc90bbf` shows the version that stops at the INTERFACE.md assertion (0.1, item 9). Once this revision is pushed, that one link could point at the new commit instead.
6. One historical note per draft was kept, because each draft is read on its own. If one note in total is wanted, the one in draft 2's Motivation can go.
7. Outside this directory, and not changed: `chips/INTERFACE.md`, `docs/BUILD_YOUR_CHIP.md` and other files still say "TAP-20"; `chips/vendor/tap-20/` keeps its name (it is the copy made at upstream commit `27b7a5fb`, and both generators fall back to it).
8. "We" or "I" in the posts.

## 1. What is here

| File | What it is |
|---|---|
| `tap-draft-circuit-pin-manifest.md` | Draft TAP 1: the pin manifest (format, binding, publication, commitment, profiles) |
| `tap-draft-stateful-consumers.md` | Draft TAP 2: how a consumer contract keeps latch state, records beats and pins the evaluator |
| `POSTS.md` | The three texts to post (comment on #44, Idea issue, pull request body), for approval |
| `export_upstream.py` | Lays the drafts and their assets out in a clone of the TAPs repository and checks them there (section 4) |
| `assets/pin-manifest.schema.json` | JSON Schema (draft 2020-12) of the manifest. Also used by `chips/kit/kit.py` and `chips/synth/gen_pins.py` |
| `assets/covenant-v1.pins.json` | Covenant interface v1 as a profile. Generated; never edit: its digest is claimed by deployed manifests |
| `assets/covenant-v1.vectors.json` | Worked conversions with that profile. Generated |
| `assets/gen_covenant_manifest.py` | Generator of the two files above. Imports `chips/golden/kernel_model.py`, parses `chips/INTERFACE.md` section 2 |
| `assets/pins_reference.py` | Reference implementation of draft 1 (MIT): strict reader, validator, binding and profile checks, field codec; also the state helpers and replay check. Imported by `chips/` tools and copied into the Architect image, so its functions stay as they are |
| `assets/make_manifest_vectors.py` | Generator of `shift-toggle.pins.json` and `manifest-vectors.json`, with TAP-02's `reference.py` |
| `assets/check_assets.py` | Pinned digests, then the schema and the reference validator over every manifest |
| `assets/shift-toggle.pins.json` | Circuit manifest of the example circuit (9 latches, 5 NAND, 71 bytes) |
| `assets/manifest-vectors.json` | Test vectors of draft 1 |
| `assets/replay_reference.py` | Reference implementation of draft 2 (MIT): state string and word form, replay check, keccak256 |
| `assets/make_replay_vectors.py` | Generator of `replay-vectors.json`, with TAP-02's `reference.py` |
| `assets/replay-vectors.json` | Test vectors of draft 2 |
| `assets/ReferenceConsumer.sol` | Reference consumer of draft 2 (MIT, not audited) |
| `assets/deployments-check.json` | Raw reads behind the Deployments table of draft 2 |
| `assets/lint_tap.py` | Format check of a TAP text against TAP-01 §7 and the template (section 4). Not exported |
| `.venv/` | Local virtual environment with `jsonschema` 4.26.0. Ignored by git (`.gitignore` line 4) |

To regenerate and check everything (deterministic; writes only inside `docs/taps/assets/`):

```
~/.local/bin/python3.12 -B docs/taps/assets/gen_covenant_manifest.py
~/.local/bin/python3.12 -B docs/taps/assets/make_manifest_vectors.py
~/.local/bin/python3.12 -B docs/taps/assets/make_replay_vectors.py
docs/taps/.venv/bin/python -B docs/taps/assets/check_assets.py
~/.local/bin/python3.12 -B docs/taps/assets/lint_tap.py docs/taps/tap-draft-*.md
```

The generator of the Covenant profile types no layout number. Offsets and widths come from `INPUT_FIELDS` and `OUTPUT_FIELDS`; `nIn`, `nOut` and the largest code from `IN_BITS`, `OUT_BITS` and `LG8_MAX`; the unit share (256) and the progress and lock scales (255) are recovered by calling `route_tax`, `prog_code` and `lock_code` and asserted; the shape numbers (1 to 256 latches, 3,400 gates, 24,000 bytes) are parsed from `chips/INTERFACE.md` section 2. The script also checks that the bit ranges printed in INTERFACE.md sections 5 and 6 equal the model's layouts (they do), and that the generic codec reproduces `chips/golden/vectors.json`: 64 input words, 60 output words, 3,623 `lg8` points, 1,024 `exp8` points and 6 state words.

## 2. Why two drafts and not one

The brief allowed one file or two. The TAPs process asks for one topic per TAP in three places: TAP-01 section 4 ("Editors judge whether a TAP is complete, coherent and on one topic"), the editors' checklist in CONTRIBUTING section 4 ("It covers one topic; the Summary is one sentence") and the pull request template. The two concerns are separable: a combinational circuit benefits from a manifest and has no state; a consumer can follow the state convention without publishing a manifest. They also have different neighbours in the repository: the manifest overlaps an open Idea (#44, see section 5), the consumer convention overlaps nothing. Two drafts let the second go forward while the first is discussed.

Both are type **Application** (TAP-01 section 3: "Conventions that applications may adopt on top of Standards TAPs: ... metadata formats"). Neither changes TAP-02 or TAP-10.

## 3. The TAPs repository today

Read with `gh api` on 2026-10-07 at commit `075dd834a72c4c5b251d97f183cac9d42d8ccd66` (2026-10-05T05:44:22Z, the merge of #46). The first reading, on 2026-10-04, was at `27b7a5fb`, the commit of `chips/vendor/tap-20/`.

| TAP | Title | Type | Status | Notes |
|---|---|---|---|---|
| TAP-01 | TAP Purpose and Process | Process | Draft | Follows EIP-1. §6.1 since #48: 2 to 9 are reserved for foundational standards, and editors may renumber a Draft |
| TAP-02 | Circuit Netlist Format and Evaluation Semantics | Standards | Draft | Was TAP-20 (#45). `requires: TAP-01`. Assets in `assets/tap-02/` |
| TAP-10 | DeWEB Access and Messaging Layers | Standards | Draft, v1.1 | Containers, names, site store, payment contract, hub; Deployments for three chains |
| TAP-11 | TapeAPI Service Manifest and Holder Delegation | Application | Draft | A JSON manifest at `/.well-known/tapeapi.json` in a container; canonical JSON (section 6) |
| TAP-12 | Sealed Commitments and Verdicts over TapeSend | Application | Draft | |
| TAP-13 | Signed Responses for Container Services | Application | Draft | |

The README index lists all six. Licence: text CC0 1.0, code under `assets/` MIT (`LICENSE`, CONTRIBUTING section 7). The next number an editor would assign to an ordinary draft is 14 (the lowest above 10 that is neither reserved nor used).

Open draft pull requests: #12 Private Channels, #14 Encrypted Private Files, #16 MCP Tools as Container Service Methods, #18 Attested Reads, #20 Private Groups, #26 AI Usage Receipts, #28 Proof-Verified Reads, #47 Container Agent Mandates (Phase 0), #49 Agent Member of the Service Manifest. Merged since the first reading: #35 and #36 (TAP-11 follow-ups), #43 (README), #45 (renumbering), #46 (TAP-13 wording), #48 (TAP-01 §6.1). Closed without merge: #23, #39.

Open Ideas: #11, #13, #15, #17, #19, #21, #25, #27, #29, #30, #33, #34, #38, #40, #41, #42, #44, #50. Issue #31 is the editors' queue and explains how drafts are handled.

## 4. The submission process the repository expects

From README, CONTRIBUTING, TAP-01 and issue #31:

1. Search the TAPs and the open issues (done, section 5).
2. Open an issue with the **Idea** template: title `Idea: <short title>`, label `idea`, four parts (Problem, Proposal, Type, Builds on). One Idea per TAP. Wait for feedback before the pull request.
3. Copy `TAP-template.md` to `TAPs/TAP-draft-<short-title>.md`. Preamble in this order: `tap: TBD`, `title`, `description` (one sentence), `author` (`Name (@handle)`), `discussions-to` (the Idea issue), `status: Draft`, `type`, `created`, `requires`, `license: CC0-1.0`. Heading `# TAP-TBD: <Title>`.
4. Sections in this order: Summary (one sentence, no key words), Abstract, Motivation, Specification, Rationale, Backwards Compatibility, Test Cases, Reference Implementation, Deployments, Security Considerations, Copyright. Key words in capitals, only in the Specification. TAP-02 keeps its open questions as a `###` subsection at the end of Security Considerations; both drafts do the same.
5. Vector files go in `assets/tap-draft-<short-title>/` while the pull request is open.
6. Open a pull request that adds only the TAP file and its assets, with the pull request template filled in (what it does, the Idea issue, six author checks). Recent drafts title it `TAP-draft: <Title>`.
7. Editors check the format, not the merit. They assign the number, rename the file to `TAPs/TAP-<nn>.md` and the assets to `assets/tap-<nn>/`, and merge as Draft. Merging as Draft is not acceptance. Editors on #30: a TAP whose text refers to another TAP's sections for something normative lists it in `requires`.
8. Before Review: test vectors that a reference implementation reproduces, the reference implementation linked at a fixed commit, deployed addresses verified read-only, Security Considerations. Review lasts at least 14 days. A TAP that depends on an upgradeable contract can reach Candidate and becomes Final only once that contract is sealed.

`lint_tap.py` checks points 3 and 4 and the `requires` rule of point 7: the front matter keys, their order and values; the heading; the sections and their order; a one-sentence Summary and description; key words only in the Specification, which must carry the template's sentence; every TAP the Specification cites in `requires`; no "TAP-20" outside the historical note; no template comment; the Copyright line. Placeholders are warnings, or errors with `--posting`.

How our files map to the repository (`export_upstream.py` does this, then regenerates and checks in the clone):

| Here | In TapeOutProtocol/TAPs |
|---|---|
| `tap-draft-circuit-pin-manifest.md` | `TAPs/TAP-draft-circuit-pin-manifest.md` |
| `assets/pin-manifest.schema.json`, `pins_reference.py`, `make_manifest_vectors.py`, `check_assets.py`, `shift-toggle.pins.json`, `manifest-vectors.json`, `covenant-v1.pins.json`, `covenant-v1.vectors.json` | `assets/tap-draft-circuit-pin-manifest/` |
| `tap-draft-stateful-consumers.md` | `TAPs/TAP-draft-stateful-consumers.md` |
| `assets/replay_reference.py`, `make_replay_vectors.py`, `replay-vectors.json`, `ReferenceConsumer.sol`, `deployments-check.json` | `assets/tap-draft-stateful-consumers/` |
| `assets/gen_covenant_manifest.py`, `lint_tap.py` | Stay here. The first imports the Covenant model (the TAPs repository gets the generated JSON); the second is our own tool |

Usage, at posting time, in a clone of the fork: `python3 docs/taps/export_upstream.py <clone> --draft stateful-consumers --author-name "<NAME>" --discussions-to <IDEA-ISSUE-URL> --posting`. It writes only the listed files and runs no git command.

## 5. Overlaps found

**Idea #44, "Semantic Port Mapping for TAP-20 Circuit Interfaces"** (opened 2026-10-04 15:55 UTC by `259906573-ship-it`, another entrant of the hackathon; no draft file). It describes the same gap as draft 1 for stateless circuits: a mapping between named, typed values and the bit ranges of the netlist standard. It shows an experimental JSON shape and says "This is not a final schema". Its open questions 5 to 7 are the ones draft 1 answers (signedness, scale and unit; how a mapping is bound to a circuit; where it lives and how its provenance is established). It says that stateful interfaces are outside its evidence. Comments: an editor (`TheCYPER`, 2026-10-04) noted the renumbering to TAP-02; the author (2026-10-05) asked the editors to choose between three placements: (1) an optional section or profile around TAP-02, (2) a companion application profile, (3) the component-interface work referenced in TAP-02's Rationale. No editor has answered that yet.

**Idea #50, "Composable Circuit Interface"** (opened 2026-10-05 by the same author). Interfaces, circuit references and connections between circuits. Its author's comment of 2026-10-06 narrows it: "#44 / component-interface: what a component exposes. #50: how compatible components are connected deterministically. TAP-02: how the resulting executable netlist is represented." It lists timing, reset, state ownership and feedback of stateful modules as open and outside its proof of concept.

What this means for us:

- Draft 1 must not be submitted as a competing Idea. The route is comment (a) on #44, which offers the draft, says it takes option 2, places it on the "what a component exposes" side of #50's boundary, and asks whether #44's author and the editors prefer one TAP with joint authorship or two. Draft 1 says the same in its Motivation, Rationale and Open questions.
- No text or schema was taken from #44 or #50. Our field members (`name`, `offset`, `width`) come from the tuples of `kernel_model.py`; #44 and #50 use `bitOffset`, `bitWidth`, `port` and `type`, and bind by `chainId`, processor and circuit id where draft 1 binds by the netlist hash. If the texts become one, the member names are a detail to settle there (draft 1, open question 7).
- Draft 2 overlaps neither. It touches #50 only at "state ownership": #50 asks it for composed circuits, draft 2 answers it for one contract and one circuit. The Idea text (b) says so.

Related, not overlapping: TAP-11 (the precedent for a manifest as a site file; draft 1 follows its reading procedure and file rules); PR #16 (pins tool definitions by a SHA-256 in a manifest); Idea #30 (release manifests; the editors' comments there on discovery paths and on what `requires` must list were followed); PR #28 (proofs of reads; could prove `netlist` and `fileInfo` reads); PR #49 (an optional member of the TAP-11 manifest; the same pattern of a later TAP adding members).

`.well-known/` keys already used by TAPs and drafts: `tapeapi.json`, `tape-channel.json`, `tapeapi-mandates.json`, `tape-20.json`. `tape-pins.json` is free.

## 6. What was verified, and how

All reads are `eth_call`, `eth_getStorageAt`, `eth_getCode`, `eth_estimateGas` or `eth_getLogs` against public nodes. `F` is the factory `0x1f09daefa827f02cbb40967cc91b259763760761`, `RPC` is `https://rpc.xlayer.tech`. Unless a date is given, the reads are of 2026-10-04; section 0.2 lists what was read again on 2026-10-07.

### 6.1 Processor contracts and the factory

| Claim | Result | How |
|---|---|---|
| The factory is not sealed and is owned by a 3-of-5 Safe | `isSealed()` false on X Layer, Base and BNB Smart Chain; owner `0xB3D85b42A045c1A88D800CAD0F55d2566a4D3138`; on X Layer `getThreshold()` = 3, `getOwners()` = 5 addresses | `cast call $F 'isSealed()(bool)'`, `cast call $F 'owner()(address)'`, `cast call <owner> 'getThreshold()(uint256)'` |
| Beacon, implementation, code hashes | `assets/deployments-check.json`: X Layer block 72,376,227, Base 52,177,964, BNB Smart Chain 125,739,381. All match TAP-10 Deployments. The implementation address is the same on X Layer and Base, the code hash is not | `cast call $F 'circuitBeacon()(address)'`, `cast call <beacon> 'implementation()(address)'`, `cast keccak $(cast code <impl>)` |
| A processor is a beacon proxy whose beacon is fixed | 295 bytes of code, code hash `0x57aa306f...17d5` as in TAP-10; ERC-1967 beacon slot holds `0xf70d1ed4...991C`; the beacon address is in the code | `cast storage <processor> 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50` |
| `step` is a view and the contract keeps no state | Vendored source: `step` and `eval` are `view`; `Circ` has no state field | `contracts/vendor/tapeout-xlayer/src/Circuits.sol` |
| No `beat` function | Selector `0x1fc0021d` is absent from the implementation code on all three chains; `cast call <processor> 'beat(address,uint256,bytes)' ...` reverts with empty data on X Layer and BNB Smart Chain. X Layer again on 2026-10-07: absent | `cast code <impl> | grep -c 1fc0021d` |
| `nextId()` is the last id, not the next | X Layer processor 0: `nextId()` = 103, `circuitInfo(103)` answers, `circuitInfo(104)` reverts `no circuit`. BNB Smart Chain processor 0: 11640, same behaviour. Source: `circuitId = ++nextId` | `cast call <processor> 'nextId()(uint256)'` |
| No per-circuit metadata | `tokenURI(1)` returns `""` | `cast call <processor> 'tokenURI(uint256)(string)' 1` |
| `step` reads strings leniently and returns exact lengths | X Layer block 72,373,447, circuit 1 of processors 273, 261, 172 and 252 (9, 16, 288 and 1 state bits): result equals TAP-02's `reference.py`; `newState` is `ceil(nState/8)` bytes with unused bits zero; the 32-byte word gives the same result; bits and bytes beyond `nState` are ignored; a short string reads the missing bits as zero | Example: `cast call 0xA30706F2BD6EEF04d07a4359CEc270697fE3947c 'step(uint256,bytes,bytes)(bytes,bytes)' 1 0x0102 0x05` returns `0x0204 0xf6`, and so does the same call with `0x0102` followed by 30 bytes of `00` or of `ff` |
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
- The alternate-evaluator path of draft 2 has no generic reference contract. Covenant's `SealedVM` is one, in another track's directory; draft 2 now links it at `fc90bbf`.
- The examples were not put on a real chain. That would cost tape-out and container fees and needs the user's decision.
- `ReferenceConsumer.sol` has no test suite beyond the fork run above.
- The full reader procedure of draft 1, section 2.1 (node agreement, pinned block, site status) has no reference code: `pins_reference.py` works on bytes that are already read.
- Whether the Covenant chips' manifests were written to their containers as `.well-known/tape-pins.json` is not recorded here.

Provenance of code in `assets/`: everything was written for these drafts. `keccak256` in `pins_reference.py` and `replay_reference.py` follows the structure of the Keccak team's public-domain `CompactFIPS202.py` and was checked against `cast keccak` and against `tapc`'s own implementation. The generators import TAP-02's `reference.py` (MIT) and do not copy it. If the team records provenance in `docs/THIRD_PARTY.md`, these lines belong there; that file is outside this track's directory.

## 7. Design decisions in brief

- **Where the manifest lives:** the file `.well-known/tape-pins.json` in the circuit's own container, in the site store. It can be found from the circuit alone, needs no new contract, and is verified as every TAP-10 file is. It is not under `/.tape/`, which gateways reserve.
- **How it is bound:** the manifest states `keccak256` of the netlist and the pin counts; a reader checks them against `netlist(id)` and `circuitInfo(id)`. It does not name a processor or an id, so it can be written before tape-out and one manifest serves every copy of a netlist. A netlist with REF records also needs `chainId`.
- **How a swap is noticed:** site files can be replaced by the holder, so a contract commits to the SHA-256 of the manifest file through `pinManifestOf(address,uint256)` (`0x67b68875`). The SHA-256 of the file bytes is the hash the site store already records. Candidates rejected and why (draft 1, Rationale): a hash kept only by the taping-out contract (not every circuit has one, and the processor contract does not expose the tape-out caller to `eth_call`; the general form covers it), an event (contracts and `eth_call` cannot read it, public nodes cap log queries), bits in the netlist (no free bytes; dead gates cost transistors), a registry contract (a new contract with an owner question).
- **Where it sits next to #44 and #50:** a companion Application TAP next to TAP-02 (#44's option 2); one circuit's pins; nothing about connections.
- **Activation:** unlike TAP-11, a manifest in an `unpaid` site is still read and the status is shown, because a circuit held by a contract can never be activated. This is the point most likely to be contested; it is listed as an open question.
- **State layout:** the state string is exactly what `step` returns: TAP-02 packing, `ceil(nState/8)` bytes. Up to 256 latches it may be kept as one `bytes32`, string first, zero bytes after. That word may be passed to `step`. Latches-first netlists are recommended.
- **Replay:** every record holds source, inputs, outputs and state after; one TAP-02 beat from the previous state and the inputs must give the recorded state and outputs. Records without a beat have source 0 and leave the state unchanged.
- **Pinned values:** the beacon's implementation, the implementation's code hash, the netlist hash and the pin counts, compared before every beat in the same transaction.

## 8. How Covenant stands against the drafts

First read on 2026-10-04 from `chips/INTERFACE.md`, `contracts/core/src/Kernel.sol`, `KernelFactory.sol` and `contracts/evaluator/src/Fab.sol`; updated on 2026-10-07 from the same files and `contracts/core-v2/src/KernelV2.sol` at `fc90bbf`. Other tracks own those files; nothing was changed.

**Draft 2 (consumers).** Both kernels meet the requirements of sections 2 to 6: word form; the 32-byte word is passed to `step`; the returned lengths are checked and the bytes after the returned string are cleared; a failed step changes no state and is either a revert or a flagged record; a gas floor is checked before the call; records are readable with `records(n)` and emitted in `Settled`; they pin the implementation, its code hash, the pin counts and the netlist hash, and switch to `SealedVM` on a difference. Record flags map to `source`: `FALLBACK` is 0, `SEALED` is 2, otherwise 1. What the kernels do not do:

- They do not implement `ICircuitConsumer` (section 7, a SHOULD). An adapter in a Lens could expose `beatAt`, `circuitState` and `pinnedEvaluator` from `records`, `state` and `globals`.
- `_step` does not check that the unused bits of the last state byte are zero (section 4 step 4, a SHOULD). It matters only for chips whose `nState` is not a multiple of 8.
- The `beacon` is a constructor argument of the kernel factory. A deployment script should assert that it equals the processor's ERC-1967 beacon slot; a reader of draft 2 makes that comparison.

**Draft 1 (manifest).** `covenant-v1.pins.json` is the profile. The chip toolchain now writes a circuit manifest per chip in this format: `chips/synth/gen_pins.py` (`chips/out/fg.pins.json`, the Flow Governor) and `chips/kit/kit.py` (`<chip>.tape-pins.json`), both checked with `pins_reference.py` and the schema of this directory. The 2026-10-04 notes said such a converter had not been written; that is no longer so.

- **Commitment.** Interface revision 2 replaced the Fab's `templateId` with `manifestHash`: `tapeoutChip(netlist, manifestHash)` records the caller's value and `chipInfo` returns it (`chips/INTERFACE.md` section 11). Chips 2 and 5 carry `0xfe8b7a49…e209`, the SHA-256 of `chips/out/fg.pins.json` (read on 2026-10-07). This is a commitment by the taping-out contract, the case draft 1's Rationale names first; it is not the `pinManifestOf` view of section 7. A view in a Lens could expose it under that name.
- **Publication.** A manifest can be written to a chip's container only while a wallet holds the chip. Once the chip is in a kernel nobody can write that site (verified, 6.2 step 5). So the order would be: tape out, open the container (0.08 OKB), `putFile`, then hand the chip to the kernel. The fee is paid per chip.

## 9. `chips/INTERFACE.md` against the TAPs and the deployed contracts

No hard conflict was found. Four points worth knowing (line numbers of 2026-10-04):

1. **Line 36**, "It passes all 32 bytes to `step` and stores `bytes32(newState)`." TAP-02 section 5 says: "Callers SHOULD send exactly `ceil(n / 8)` bytes with zero padding; a conforming evaluator MUST read other byte strings the same way as the contracts." The kernel departs from a SHOULD, not from a MUST, and the result is the same: verified in the source (`_getBit` returns 0 beyond the string and never reads beyond `nState`) and on X Layer (section 6.1). Draft 2 allows the word form for this reason.
2. **Lines 34 and 36** use two meanings of a 32-byte value. Line 34: "A word is the little-endian integer of those bytes." Line 36: the state is "one `bytes32` holding the TAP-20 byte string right-padded with zeros". A reader that takes the `bytes32` state as an integer and applies `(word >> o)` gets wrong fields: state bit 0 is at bit 248 of that integer. The golden vectors keep the two apart (`bits` and `bytes32`); the text does not warn. Both drafts state the rule.
3. **Line 223** lists three pinned values ("`beacon.implementation()`, the implementation's code hash, or `keccak256(Circuits.netlist(chipId))`"). `Kernel._sealedMode` also compares `circuitInfo` (`nIn`, `nOut`, `nState`, `gateCount`) and the netlist length. The code does more than the document says.
4. **Line 239**, "a 3-of-5 Safe can upgrade processor logic": confirmed (section 6.1). **Line 51**, "X Layer has no Osaka": an `eth_call` of code using the `CLZ` opcode returns `EVM error: NotActivated` on X Layer and 255 on Base. **Line 201**, "public RPCs cap log queries at 100 blocks": confirmed.

The layouts of sections 5 and 6 of INTERFACE.md equal `kernel_model.py` (checked by the generator on every run). INTERFACE.md still says "TAP-20" (section 0.3, item 7).

## 10. Two observations about TAP-02 itself

For its author, when the drafts are discussed (both are unchanged by the renumbering):

- Section 6 lists `nextId()` as "the id the next taped-out circuit will get". On X Layer and on BNB Smart Chain it returns the id of the last circuit (section 6.1). `web/NOTES.md` in this repository found the same.
- Section 6 says a processor contract "also exposes a state-changing `beat(address cpu, uint256 id, bytes inputs)` (`0x1fc0021d`) that keeps state on chain". The selector is not in the implementation on any of the three chains (X Layer read again on 2026-10-07).

## 11. Open questions for the maintainers

1. Should draft 1 and Idea #44 become one TAP with joint authorship, or two TAPs with a stated boundary? (Asked in comment (a).)
2. May a manifest in a site whose name is not activated be used, with its status shown? TAP-11 applies activation to service resolution; draft 1 argues that a pin manifest is different.
3. Are the key `.well-known/tape-pins.json` and the member name `tapepins` acceptable?
4. Where is the `beat` function that TAP-02 section 6 mentions, and how does it keep state? Draft 2 should align with it if it exists. (Asked in the Idea text (b) and the pull request body (c).)
5. Where is the "component interface TAP draft" that TAP-02's Rationale mentions? #44 and #50 ask the same.
6. Would the owners add a view that returns the tape-out caller of a circuit? Today it is only in logs.
7. For consumers of circuits with REF records: should the reader interface expose pinned values for the REF closure?
8. Is there a safe on-chain way for a consumer to stop comparing pinned values once the factory is sealed?

(The 2026-10-04 question 9, on the renumbering, is settled: both drafts now require TAP-02.)

## 12. Before anything is submitted

- Your OK on each text of `POSTS.md`, one at a time, in the order given there.
- Fill in `author` and `discussions-to` (section 0.3), at export time with `export_upstream.py --author-name/--discussions-to`, or in the drafts here.
- Commit and push this revision, then put that commit in place of `<COMMIT>` in `POSTS.md`.
- Run the commands of section 1 again, and `lint_tap.py --posting` on the exported text; re-read the TAPs repository (#44, #50, #31, new Ideas) and, if more than a few days have passed, the deployments, and update dates and block numbers in the texts if anything changed.
- The Copyright line links to `../LICENSE`, which resolves in the TAPs repository, not here.

## 13. Draft texts for the Idea stage

Moved to `POSTS.md` and revised for TAP-02, #44's three placements and #50's boundary: (a) the comment on #44, (b) the Idea issue for draft 2, (c) the pull request body for draft 2.
