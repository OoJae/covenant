# Texts for the TAPs repository, for approval

Prepared on 2026-10-07. **Nothing here has been posted.** Each text goes out only after you approve it, through `gh` as `@OoJae`, in this order:

1. (a) the comment on Idea #44, which offers draft 1;
2. (b) the Idea issue for draft 2;
3. creating the fork `OoJae/TAPs`, which is public too and needs its own OK;
4. after feedback on (b): the pull request for draft 2, with body (c);
5. a pull request for draft 1 only if #44's author or an editor agrees;
6. nothing goes to the editors' queue (#31).

**Before posting, fill in:**

| Placeholder | What goes there |
|---|---|
| `<COMMIT>` | The commit of this repository that contains the drafts as they are now, once it is pushed. `fc90bbf` holds the older text, which still cites TAP-20, so the links in these posts cannot use it |
| `<IDEA-ISSUE-URL>` | The URL of issue (b), once it exists |
| `<NAME>` in both drafts | Your name, as you want it in `author`. `export_upstream.py --author-name` fills it in the exported copy only |
| `<ISSUE-URL>` in both drafts | Draft 1: #44's URL (or the issue the editors name). Draft 2: `<IDEA-ISSUE-URL>`. `export_upstream.py --discussions-to` fills it per draft |

The texts say "we" for the Covenant project. Change it to "I" if you prefer to speak for yourself.

On the day, re-read the open issues and pull requests (#44, #50, #31 and any new Idea about circuit pins or state) in case something has changed since 2026-10-07.

---

## (a) Comment on Idea #44 (draft 1)

Where: https://github.com/TapeOutProtocol/TAPs/issues/44

> We ran into the same gap from the other side: a contract that writes 96 input bits and reads 112 output bits of a sequential circuit every epoch, and a front end that has to show what each recorded beat meant. We wrote a full draft before we saw this Idea, and we would rather contribute it here than open a competing one.
>
> On your three placements, the draft takes the second: a companion Application TAP next to TAP-02 that changes nothing in TAP-02. It describes the pins of one circuit and says nothing about connections, so it sits on the "what a component exposes" side of the boundary you proposed on #50. Like you, we could not find the component-interface draft that TAP-02's Rationale mentions; if the editors point to it, we are happy to move the text there.
>
> It gives one possible answer to three of your open questions:
>
> - **Q5, types.** Eight encodings (`uint`, `int`, `bool`, `enum`, `flags`, a logarithmic amount code, `zero`, `bits`), with `min`, `max`, `scale` and `unit`, integer-only arithmetic, and a list of values an encoder must refuse instead of clipping.
> - **Q6, binding.** The manifest states `keccak256` of the netlist and the pin counts instead of a chain, processor and circuit id. It can be written before tape-out, one manifest serves every copy of a netlist, and it cannot be attached to another netlist. A netlist with REF records also names its chain.
> - **Q7, where it lives and its provenance.** `.well-known/tape-pins.json` in the circuit's own container, read the way TAP-11 reads its manifest, plus an optional one-function commitment (`pinManifestOf`) so that a contract can fix the SHA-256 of the manifest it was built against. A replaced file then no longer matches.
>
> It also names the bits of the state vector, which your evidence leaves out. It is in use: our Fab contract on X Layer recorded the SHA-256 of a circuit manifest in this format when it taped out chips 2 and 5.
>
> The draft, a JSON Schema, a dependency-free reference implementation and test vectors generated with TAP-02's reference evaluator: https://github.com/OoJae/covenant/blob/<COMMIT>/docs/taps/tap-draft-circuit-pin-manifest.md (assets: https://github.com/OoJae/covenant/tree/<COMMIT>/docs/taps/assets).
>
> Would you, and the editors, prefer one TAP with joint authorship, or two TAPs with a clear line between them? We are fine with either, and with your member names (`bitOffset`, `bitWidth`, `type`) if people prefer them.

Facts behind it: 96 and 112 bits are `nIn` and `nOut` of the Covenant profile. The Fab at `0xdCAc8c47aF534dC0cDE30f60056bCe7D63a79aFE` returns `manifestHash` `0xfe8b7a49…e209` from `chipInfo(2)` and `chipInfo(5)` (read on 2026-10-07); that is the SHA-256 of `chips/out/fg.pins.json`, which claims the `covenant-v1` profile by its digest `0x77a721cd…6eb5`.

---

## (b) Idea issue for draft 2

Where: https://github.com/TapeOutProtocol/TAPs/issues/new?template=idea.md (the web form adds the label `idea`; through the API a label from someone without triage rights is dropped, so if it is posted with `gh issue create`, check afterwards whether the label is there and, if not, ask in the issue).

**Title:** `Idea: Stateful circuit consumers: keeping latch state and replayable beats (Application, builds on TAP-02)`

**Body:**

> **Problem.** A circuit with LATCH records has state, but a processor contract stores none: `step` is a view function that takes the state from its caller and returns the next one (TAP-02 §6). Every contract that runs a sequential circuit therefore decides alone how to store the state, what to pass to `step`, what to do with a result of the wrong length, what to record of each beat, and how to notice that the circuit implementation behind the beacon has changed (the processor factory is not sealed, and its owner can replace that implementation for every processor contract in one call). On X Layer, 286 of 2,820 circuits had state at block 72,371,934. Without a shared form, nobody outside a contract can check that it stored what its circuit computed, and small byte-handling mistakes (a state cut to 32 bytes, a `bytes32` read as an integer, which puts state bit 0 at bit 248) change what the circuit sees without any error.
>
> **Proposal.** A convention for such contracts ("consumers"):
>
> - the state is kept as the TAP-02 packed byte string that `step` returns, or, for up to 256 latches, as one `bytes32` with zero padding, which may be passed to `step` directly;
> - the returned lengths are checked, and a failed beat changes no state;
> - every beat leaves a record (inputs, outputs, state after), and one TAP-02 beat from the previous state must reproduce it, so anyone can replay the history from the netlist; records without a beat are marked;
> - when it is bound, the consumer pins the beacon's implementation, its code hash, the netlist hash and the pin counts, and compares them before each beat;
> - a small read interface (`ICircuitConsumer`) lets explorers and auditors read any consumer the same way.
>
> A full draft with test vectors (generated with TAP-02's reference evaluator), a reference consumer contract checked on an X Layer fork, and a deployed consumer it was drawn from: https://github.com/OoJae/covenant/blob/<COMMIT>/docs/taps/tap-draft-stateful-consumers.md. I would open the pull request after feedback here.
>
> **Type.** Application.
>
> **Builds on.** TAP-02 (§4 state and beat, §5 packing, §6 `step`, `circuitInfo`, `netlist`). Two questions for the editors and for TAP-02's author:
>
> 1. TAP-02 §6 mentions a state-changing `beat(address cpu, uint256 id, bytes inputs)` (`0x1fc0021d`) that keeps state on chain. The selector is not in the circuit implementation on X Layer, Base or BNB Smart Chain (read on 2026-10-04; on X Layer again on 2026-10-07 at block 72,589,084). If that function exists elsewhere or is planned, the draft should align its records with it.
> 2. Idea #50 lists state ownership, reset and feedback among its open questions for connecting circuits. This proposal is narrower: one contract keeping the state of one bound circuit. It does not try to answer #50's questions, but a composition format may want to reuse its state form.

---

## (c) Pull request body for draft 2

Where: a pull request from a branch of the fork `OoJae/TAPs` to `TapeOutProtocol/TAPs:main`, made with `docs/taps/export_upstream.py <fork clone> --draft stateful-consumers --author-name "<NAME>" --discussions-to <IDEA-ISSUE-URL> --posting`, which also regenerates the vectors in the clone and lints the text.

**Title:** `TAP-draft: Stateful Circuit Consumers`

**Body:**

```markdown
<!-- For a new TAP, the pull request adds TAPs/TAP-draft-<short-title>.md (and assets, if any). See CONTRIBUTING.md. -->

**What this pull request does:** new TAP draft (Application), `TAPs/TAP-draft-stateful-consumers.md`, with its assets in `assets/tap-draft-stateful-consumers/`: `replay-vectors.json`, the generator `make_replay_vectors.py`, the reader's check `replay_reference.py`, a reference consumer `ReferenceConsumer.sol` and the raw reads behind its Deployments table, `deployments-check.json`. It specifies how a contract that runs a circuit with LATCH records keeps the circuit's state between beats, records every beat so that anyone can replay it, and notices when the evaluator behind `step` has changed. It changes nothing in TAP-02.

**Idea issue or discussion:** <IDEA-ISSUE-URL>

Checklist for authors (editors check the same list, CONTRIBUTING.md §4):

- [x] The preamble is complete (TAP-01 §7.1); `tap: TBD` for a new draft
- [x] One topic; the Summary is one sentence
- [x] Motivation and Specification are present
- [x] RFC 2119 key words are capitalised and used only for real requirements
- [x] Nothing normative depends on an external link, except references at a fixed commit or version
- [ ] I can dedicate this text to the public domain under CC0 1.0

## What the draft specifies

- **State** (§3): the TAP-02 packed byte string that `step` returns, `ceil(nState / 8)` bytes with unused bits zero; or, for up to 256 latches, one `bytes32` holding that string followed by zero bytes. §3.2 gives the bit positions of the word form, because reading it as an integer puts state bit 0 at bit 248.
- **One beat** (§4): what is passed to `step` (the word form may be passed as it is, since TAP-02 §5 defines the result to be the same), which results may be accepted (exact lengths, no bit beyond `nState`), and that a failed beat changes no state. A consumer that goes on without a beat when the call fails needs a gas floor, so that a caller cannot force the failure.
- **Records and the replay rule** (§5): every record holds `source`, `inputs`, `outputs` and `stateAfter`; one TAP-02 beat from the previous state must reproduce it. `source` 0 marks a record without a beat, which must leave the state unchanged.
- **Pinned values** (§6): the beacon's implementation, its code hash, the netlist hash and the pin counts, compared before every beat in the same transaction; a difference stops the processor path. An alternate evaluator must have no upgrade path.
- **Reader interface** (§7, recommended): `ICircuitConsumer` with `circuit()`, `circuitState()`, `beatCount()`, `beatAt(n)`, `pinnedEvaluator()`, the `Beat` event and an optional `initialState()`; ERC-165 ID `0x0d1e10c5`. A consumer that cannot implement it can be served by an adapter.

## Test vectors and reference implementation

- `replay-vectors.json` (format `tap-replay-vectors/1`): 12 beats of a 71-byte example circuit with 9 latches; one beat asked for with five different `state` arguments; word forms for six values of `nState` from 1 to 256, and four strings that are not state strings; one valid record sequence (with a record without a beat and three beats from an alternate evaluator) and seven invalid ones, each with the record at which replay fails.
- `python3 assets/tap-draft-stateful-consumers/make_replay_vectors.py` regenerates the file byte for byte. It finds TAP-02's `assets/tap-02/reference.py` through `../tap-02` and uses nothing else outside its directory.
- `ReferenceConsumer.sol` (MIT, not audited) was bound to the example circuit on a local fork of X Layer: `beatAt` returned the 12 records of the vector file, and after a simulated `upgradeCircuits` it refused to beat until the original implementation was restored.
- The deployed consumer the draft was drawn from, at a fixed commit: https://github.com/OoJae/covenant/blob/fc90bbf/contracts/core/src/Kernel.sol (second version `contracts/core-v2/src/KernelV2.sol`, alternate evaluator `contracts/evaluator/src/SealedVM.sol`). It does not implement `ICircuitConsumer`.

## Deployments

None: the draft deploys no contract. The values it reads (factory, beacon, circuit implementation and its code hash on X Layer, Base and BNB Smart Chain) were read on 2026-10-04 and are in `deployments-check.json`. On X Layer the beacon, the circuit implementation, its code hash and `isSealed()` were the same on 2026-10-07 at block 72,589,084.

## Questions for the editors

1. TAP-02 §6 mentions a state-changing `beat(address cpu, uint256 id, bytes inputs)` (`0x1fc0021d`). We could not find it on any of the three chains. If it exists or is planned, the draft should align with it (draft, Open questions 1).
2. Circuits with REF records: should the interface expose pinned values for the whole REF closure, or should consumers be told to use flat circuits (Open questions 2)?
3. Should the `Beat` event be required rather than recommended (Open questions 4)?
```

Notes on (c):

- Tick the CC0 box yourself before posting; it is left empty on purpose.
- The checklist boxes that are ticked are the ones `lint_tap.py` checks or that hold by construction; read the text once more before posting.
- Re-run `deployments-check` on the posting day if more than a few days have passed, and update the date and block numbers in the draft and here.
