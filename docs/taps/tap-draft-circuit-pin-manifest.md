---
tap: TBD
title: Circuit Pin Manifest
description: A JSON file that names the bit fields of a circuit's input, output and state vectors, the rule that ties it to one netlist, the place where it is published, and the way a contract commits to it.
author: <NAME> (@OoJae)
discussions-to: <ISSUE-URL>
status: Draft
type: Application
created: 2026-10-04
requires: TAP-02, TAP-10
license: CC0-1.0
---

# TAP-TBD: Circuit Pin Manifest

## Summary

This TAP lets whoever makes or holds a TapeOut circuit publish a small file saying what each input, output and memory bit of the circuit means, so that explorers, tools and contracts can show names instead of numbered wires and can tell when that file has been replaced.

## Abstract

A taped-out circuit is a netlist with `nIn` inputs and `nOut` outputs; nothing on chain says what any of those bits mean. This TAP defines a **pin manifest**: a JSON file that divides a circuit's input vector, output vector and state vector into named fields, each with an offset, a width and an encoding (unsigned or signed integer, boolean, enumeration, flags, a logarithmic amount code, always-zero, or uninterpreted bits). A manifest is bound to a circuit by the keccak256 of the circuit's netlist and by its pin counts, so it can be written before tape-out and cannot be attached to another circuit. It is published as the file `.well-known/tape-pins.json` in the circuit's container and read with the verification rules of TAP-10. Because whoever can write that site can replace the file, a contract that depends on the meaning of the pins can commit to the SHA-256 of a manifest through one view function, and a reader can then tell a committed manifest from one that is only published. A manifest without a circuit binding is a **profile**: a pin layout that many circuits can implement and that a circuit manifest claims by digest. Evaluation semantics, signal numbering and bit packing are those of TAP-02 and are referenced, not restated.

## Motivation

TAP-02 (numbered TAP-20 until PR #45) defines what a circuit computes on bit vectors. It does not say what the bits stand for, and the chain holds nothing that does: a processor contract stores the netlist bytes, `nIn`, `nOut`, `nState` and `gateCount`, and its `tokenURI` returns an empty string (X Layer, 2026-10-04). On X Layer at block 72,371,934 there were 2,820 circuits on 275 processor contracts. 493 of them have more than 16 input and output pins, the widest have 161 inputs and 199 outputs, and 286 keep state, up to 288 bits. For each of them the meaning of the pins exists only in its author's source files.

Three kinds of software need that meaning and cannot get it:

- **Explorers and die-shot viewers** can draw gates and wires but cannot label a pin or a latch.
- **Contracts that consume a circuit, and their front ends**, pack application values into input bits and unpack output bits with hand-written code. Anyone who wants to show what a recorded beat meant has to copy that code.
- **SDKs and agents** that call `eval` or `step` need a mapping from named, typed values to bit ranges. Idea #44 (semantic port mapping) describes this gap for stateless circuits, and the errors it caused in one implementation.

TAP-11 describes the methods of a service; its `params` and `returns` are informative type names, not bit ranges. No existing TAP maps names to bits.

Where such a mapping belongs is still open. #44 asks whether it should be (1) an optional section or profile around TAP-02, (2) "a companion application profile", or (3) part of the component-interface work that the Rationale of TAP-02 mentions, which has not been published in the TAPs repository. This TAP takes the second placement: a separate Application TAP next to TAP-02, which leaves the netlist format, the evaluation and the bit packing unchanged. (In this TAP the word *profile* has the narrower meaning of §6.) On Idea #50 its author proposes a boundary between what a component exposes (#44), how compatible components are connected (#50) and how the resulting netlist is represented (TAP-02). This TAP is on the first side of that boundary: it describes the pins of one circuit and says nothing about connections between circuits.

A file format alone would not be enough. If the labels are a file that the circuit's holder can rewrite, a reader cannot know whether the labels it sees today are the ones a contract was built against. This TAP therefore also says how a manifest is tied to one netlist and how a contract commits to one manifest. It uses only what TapeOut already provides: the netlist bytes, the container's site store, and one view function on whichever contract wants to commit.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174 when, and only when, they appear in all capitals.

### 1. Terms and notation

- **Circuit**, **processor contract**, **#ID**, **netlist**, **signal**, **beat**: as defined in TAP-02 §1. **Container**, **holder**, **opened**, **site store**, **pinned block**, **default agreement**: as defined in TAP-10 §1.
- **Vector**: one of the three bit vectors of a circuit. The **input vector** has `nIn` bits; its bit `i` is signal `2 + i`. The **output vector** has `nOut` bits; its bit `i` is signal `S − nOut + i`, where `S` is the number of signals. The **state vector** has `nState` bits, laid out as TAP-02 §4 says. Vectors are packed into bytes as in TAP-02 §5.
- **Field**: a run of consecutive bits of one vector, with a name and an encoding (§3.3, §5).
- **Manifest**: the file of §3. A **circuit manifest** has a `circuit` member and describes the circuits that have one given netlist (§4). A **profile** has no `circuit` member and describes a pin layout (§6).
- **Manifest digest**: the SHA-256 of the bytes of a manifest file.
- **Netlist hash**: `keccak256` of the netlist bytes of TAP-02 §2, which are the bytes that `netlist(id)` returns.
- **Latches-first**: a netlist is latches-first when it has no REF record and no LATCH record comes after a NAND record. In such a netlist, state bit `i` is record `i`, occupies netlist bytes `4i` to `4i + 3`, and its output is signal `2 + nIn + i`.
- **Publisher**: whoever writes a manifest. **Reader**: software that obtains a manifest and uses it to name or convert bits.
- Hashes and digests are written as `0x` followed by 64 lowercase hex digits. `keccak256` is the Keccak-256 hash used by Ethereum (original Keccak padding, not NIST SHA3-256). Other notation is that of TAP-10 §1.

### 2. Obtaining a manifest

#### 2.1 From the circuit's container

The manifest of a circuit is the file with the site store key `.well-known/tape-pins.json` in that circuit's own container: the URL path `/.well-known/tape-pins.json` with its leading `/` removed, as TAP-10 §7.2 step 3 does.

To read it, a reader makes all reads at one pinned block of the circuit's chain, chosen and checked for freshness as in TAP-10 §5.3 and adopted under at least default agreement (TAP-10 §5.2). It assigns the first outcome that applies:

1. **Identity.** Resolve the circuit as in TAP-10 §4.1–§4.3. The result is the chain, the processor contract, the #ID, the container, the holder and whether the container is opened. An identity outcome other than a resolved circuit (TAP-10 §4.4) ends resolution.
2. **Site status.** Compute the site status as in TAP-10 §6.2, including the implementation checks of TAP-10 §6.1. A reader that keeps a blocklist (TAP-10 §10) MUST consult it here. `store-changed`, `not-opened` and `blocked` end resolution with that status. `unpaid` does not: the reader continues and keeps the status for §8.
3. **Circuit.** Read `circuitInfo(#ID)` and `netlist(#ID)` from the processor contract (TAP-02 §6) and compute the netlist hash.
4. **File.** Read `fileInfo(container, ".well-known/tape-pins.json")` from the site store that TAP-10 §6.1 selects. Only this exact key is read; the landing rules of TAP-10 §7.2 step 4 (index files, fallback path) MUST NOT be applied. Then:
   - `chunkCount` 0 means `no-manifest`;
   - a declared `size` above 65,536 bytes means `manifest-invalid`, and the file MUST NOT be read;
   - otherwise the file is read and verified exactly as TAP-10 §7.1 steps 3–5. A file outcome other than `ok` (`incomplete`, `no-hash`) ends resolution with that outcome, and the bytes MUST NOT be used.
5. **Validity.** Parse and validate the bytes under §3. Any failure is `manifest-invalid`. A file that is a profile is also `manifest-invalid` here.
6. **Binding.** Check §4 against the values read in step 3. A failure is `manifest-mismatch`.
7. **Resolved.** The result is the manifest, its digest (the SHA-256 verified in step 4), the file's `updatedAt`, the site status (`ok` or `unpaid`), the holder and the pinned block.

A reader MUST NOT use a value stated in a manifest in place of a value it read from the chain.

#### 2.2 From any other source

A reader MAY take the bytes of a manifest from any other source: a file that a user supplies, a repository, the site of another container. Such bytes MUST pass §3. A circuit manifest obtained this way MUST also pass §4 against a circuit that the reader has read as in §2.1 steps 1 and 3. The source gives the manifest no authority: it is **unattributed** unless a commitment under §7 matches its digest.

#### 2.3 Standing and outcomes

A reader knows one or more of these about a manifest that passed §3 and §4:

| Standing | Meaning |
|---|---|
| **published** | Resolved under §2.1. It is what the writers of the circuit's site published as of the pinned block: the holder, or an operator the holder set (TAP-10 Appendix A). They can replace it at any time |
| **committed by `C`** | Its digest equals the value that contract `C` returns under §7 |
| **unattributed** | Obtained under §2.2, and no commitment matches |

| Outcome of §2.1 | Meaning |
|---|---|
| resolved | Every step passed; the manifest is published |
| Input error, `stale-block`, `unavailable`, `wrong-chain`, `ambiguous`, TAP-10 identity outcomes | Step 1, or the chain and node rules of TAP-10 §4.1 and §5 |
| `store-changed`, `not-opened`, `blocked` | Step 2 (TAP-10 §6.4) |
| `no-manifest` | The container's site has no file at `.well-known/tape-pins.json` |
| `incomplete`, `no-hash` | The file failed TAP-10 §7.1 |
| `manifest-invalid` | The file is too large, is not a valid manifest (§3), or is a profile |
| `manifest-mismatch` | The manifest does not describe this circuit (§4) |

Outcome names are only ever added.

### 3. Manifest file

#### 3.1 File

- A manifest is JSON text (RFC 8259) encoded in UTF-8, whose top-level value is an object. A file that is not valid UTF-8, or that begins with a byte order mark, is invalid.
- It MUST NOT exceed 65,536 bytes.
- A file is invalid when any object in it repeats a member name (compared after escape sequences are decoded); when any member anywhere is named `__proto__`, `constructor` or `prototype`; when any number is written with a fraction or an exponent, is `-0`, or has an absolute value above 2^53 − 1; or when any string or member name contains an unpaired UTF-16 surrogate.
- Readers MUST ignore members they do not know, at every level, and MUST NOT reject a manifest because of them. Later TAPs MAY define further members.
- Publishers SHOULD store the file with content type `application/json`; readers do not rely on the content type.

#### 3.2 Members

| Member | Type | Required | Rule |
|---|---|---|---|
| `tapepins` | string | yes | Matches `^0\.[1-9][0-9]*$`. This TAP defines `"0.1"`. A reader MUST accept any value of that form and MUST reject any other; a later minor version only adds optional members, encodings (§5.2) and `shape` members (§6.2) |
| `name` | string | no | At most 64 Unicode code points. Display only; it carries no identity |
| `description` | string | no | At most 2,048 code points |
| `circuit` | object | circuit manifest: yes; profile: absent | The binding (§4) |
| `profile` | object | no | `{ "name": string, "sha256": string }`: the profile this manifest claims (§6.3). `name` has at most 64 code points; `sha256` is the manifest digest of the profile file |
| `nIn` | number | yes | 0 to 65,536 |
| `nOut` | number | yes | 1 to 65,536 |
| `nState` | number | circuit manifest: yes; profile: no | 0 to 16,777,216 |
| `shape` | object | no | Profiles only (§6.2). A circuit manifest with a `shape` member is invalid |
| `inputs` | array of fields | yes | Fields of the input vector; may be empty |
| `outputs` | array of fields | yes | Fields of the output vector; may be empty |
| `state` | array of fields | circuit manifest: yes; profile: no | Fields of the state vector; may be empty. A profile that has `state` MUST have `nState` |

#### 3.3 Fields

| Member | Type | Required | Rule |
|---|---|---|---|
| `name` | string | yes | Matches `^[A-Za-z_][A-Za-z0-9_]{0,63}$` and is not `__proto__`, `constructor` or `prototype`. Unique within its array; names are case-sensitive |
| `offset` | number | yes | The index, in the vector, of the field's least significant bit; at least 0 |
| `width` | number | yes | The number of bits; at least 1 |
| `encoding` | string | yes | §5.2 |
| `description` | string | no | At most 512 code points |
| `unit` | string | no | At most 32 code points. Informative |
| `min`, `max`, `scale`, `values`, `bits`, `mantissaBits` | | per encoding | §5.2. A member that §5.2 does not list for the field's encoding MUST NOT be present |

Within each of `inputs`, `outputs` and `state`:

- fields MUST be listed in increasing `offset`, and MUST NOT overlap: each `offset` is at least the previous field's `offset + width`;
- `offset + width` MUST NOT exceed `nIn`, `nOut` or `nState` respectively;
- bits that no field covers are **unnamed**. The manifest says nothing about them.

### 4. Binding to a circuit

The `circuit` object has these members:

| Member | Type | Required | Rule |
|---|---|---|---|
| `netlistHash` | string | yes | The netlist hash (§1) |
| `chainId` | number | when the netlist has a REF record | The chain ID of the chain on which the netlist was taped out; a positive integer |

A circuit manifest **describes** a circuit, read on the chain with chain ID `c`, whose netlist bytes are `N` and for which `circuitInfo` returns `(nIn, nOut, nState, gateCount)`, when all of these hold:

1. `keccak256(N)` equals `circuit.netlistHash`;
2. the manifest's `nIn`, `nOut` and `nState` equal the circuit's;
3. if `N` contains a REF record (opcode `0x02`), `circuit.chainId` is present;
4. if `circuit.chainId` is present, it equals `c`.

A reader MUST check all four against values it read from the chain at the pinned block, never against values supplied with the manifest.

`nIn` and `nOut` are compared because they are not part of the netlist bytes (TAP-02 §2): the same bytes taped out with another `nIn` are another circuit. A manifest does not name a processor contract or an #ID. It describes every circuit that has this netlist and these pin counts, and it can be written, and its digest computed, before the circuit is taped out.

### 5. Encodings

#### 5.1 Raw value

For a field with offset `o` and width `w`, the **raw value** is

```
r = b[o]·2^0 + b[o + 1]·2^1 + … + b[o + w − 1]·2^(w − 1)
```

where `b[i]` is bit `i` of the vector, which in the packed byte string is bit `i mod 8` of byte `floor(i / 8)` (TAP-02 §5). A field may be wider than 64 or 256 bits; raw values are non-negative integers of any size. Where this TAP writes a raw value in JSON (the keys of `values`), it is a decimal string without leading zeros.

A reader MUST take each bit from the packed byte string in this way. It MUST NOT read a byte string as one big-endian integer and apply offsets to that integer. A vector held in a fixed-size word, such as a state kept in a `bytes32`, is the packed byte string followed by zero bytes: bit `i` is still bit `i mod 8` of byte `floor(i / 8)` of the word.

#### 5.2 The encodings

| `encoding` | Meaning of the raw value `r` | Members |
|---|---|---|
| `uint` | The integer `r` | Optional `min`, `max`, `scale`, `values` |
| `int` | Two's complement: `r` if `r < 2^(w − 1)`, otherwise `r − 2^w` | Optional `min`, `max`, `scale` |
| `bool` | `w` MUST be 1. 0 is false, 1 is true | None |
| `enum` | One of the listed values. A raw value that is not listed is **undefined** | REQUIRED `values`, not empty |
| `flags` | `w` independent booleans | REQUIRED `bits` |
| `log` | The code of a non-negative amount (§5.3) | REQUIRED `mantissaBits`; optional `scale`, `values` |
| `zero` | Always 0. Whoever writes the vector MUST write 0 to every bit of the field; whoever reads it MUST ignore the field | None |
| `bits` | No interpretation: the bits themselves | None |

- `min` and `max` are integers: inclusive bounds on the decoded integer, each a value the field can hold, with `min` not above `max`. A decoded value outside them is **out of range**.
- `scale` is an array `[n, d]` of two integers, each at least 1. The quantity that the field stands for is the decoded integer (for `log`, the amount) times `n / d`, in the field's `unit`. It is an aid for display.
- `values` is an object whose keys are raw values (decimal strings, each a value the field can hold) and whose values are labels of 1 to 64 code points. For `enum` it lists every defined value. For `uint` and `log` it labels particular raw values, such as a value that means "none".
- `bits` is an array of exactly `w` entries. Entry `k` is the label of vector bit `o + k`, a string of 1 to 64 code points, or `null` for a bit without a label.
- `mantissaBits` is an integer from 0 to 16.

A reader MUST treat an `encoding` that this TAP does not define as `bits`, MUST ignore the encoding members of such a field, and MUST NOT reject the manifest because of it.

#### 5.3 The `log` encoding

Let `k` be `mantissaBits` and `w` the field's width. The code of an amount `x` is

```
code(0) = 0
code(x) = min(2^w − 1, 2^k·e + m + 1)        for x ≥ 1, with e = floor(log2 x) and
                                             m = floor(x / 2^(e − k)) mod 2^k     if e ≥ k
                                             m = (x · 2^(k − e)) mod 2^k          if e < k
```

and the floor amount of a code `c` is

```
floor(0) = 0
floor(c) = floor((2^k + ((c − 1) mod 2^k)) · 2^E / 2^k)      for c ≥ 1, with E = floor((c − 1) / 2^k)
```

`code` never decreases as `x` grows, and `floor(code(x)) ≤ x` for every `x`. One step of the code is 1/2^k of an octave. The largest code, `2^w − 1`, also stands for every larger amount.

#### 5.4 Converting values

An **encoder** turns named values into a packed vector. It MUST produce exactly `ceil(n / 8)` bytes for a vector of `n` bits, with every unnamed bit, every field that was not given and every unused bit of the last byte set to 0. It MUST refuse, and MUST NOT clip: a value that the field cannot hold; a `uint` or `int` value that is out of range; an `enum` label that `values` does not have; a `flags` label that `bits` does not have; a non-zero value for a `zero` field; a negative amount for a `log` field. An amount too large for a `log` field is not refused: its code is `2^w − 1` (§5.3).

A **decoder** turns a packed vector into named values. It MUST report, and MUST NOT hide: an undefined `enum` value, an out-of-range value, and a `zero` field that is not 0. It SHOULD report unnamed bits that are set. For a `log` field it gives the code and MAY give `floor(code)`; it MUST NOT present `floor(code)` as the exact amount.

Encoders and decoders MUST use integer arithmetic for §5.1 to §5.3.

### 6. Profiles

#### 6.1 Profile

A profile is a manifest without a `circuit` member. It describes a pin layout that many circuits can implement: `nIn`, `nOut`, `inputs` and `outputs`, and optionally `nState` and `state` (a profile that fixes the state fields fixes `nState` too).

A profile is identified by its manifest digest. Its `name` is a label: two profile files with the same name and different digests are different profiles. This TAP defines no registry of profiles and no place where a profile file must be published; the digest lets a reader check a profile file from any source.

#### 6.2 Shape

A profile MAY carry a `shape` object with constraints on the netlist of a circuit that implements it:

| Member | Type | Constraint |
|---|---|---|
| `nStateMin`, `nStateMax` | number | `nState` is at least `nStateMin` and at most `nStateMax`. Each is 0 to 16,777,216, with `nStateMin` not above `nStateMax`. Neither is used in a profile that has `nState` |
| `flat` | boolean | `true`: the netlist has no REF record |
| `latchesFirst` | boolean | `true`: the netlist is latches-first (§1) |
| `maxGates` | number | The circuit's `gateCount`, as `circuitInfo` returns it, is at most this |
| `maxNetlistBytes` | number | The netlist is at most this many bytes long |

A constraint that is absent, or `false`, does not constrain.

#### 6.3 Claiming a profile

A manifest claims a profile with its `profile` member. A manifest `M` **implements** a profile `P` when:

1. `M.nIn` equals `P.nIn` and `M.nOut` equals `P.nOut`;
2. if `P` has `nState`, `M.nState` equals it; and `M.nState` is within `P.shape.nStateMin` and `P.shape.nStateMax` where those are present;
3. for each of `inputs` and `outputs`, and for `state` if `P` has it: every field of `P` appears in the same array of `M` with the same `name`, `offset` and `width`, and with the same `encoding`, `min`, `max`, `scale`, `values`, `bits` and `mantissaBits` (each absent in both or equal in both). The encoding members are not compared for a field whose encoding in `P` is `bits` or is not defined by this TAP: `M` may give such a field any encoding. `description` and `unit` are not compared;
4. the netlist of the circuit that `M` describes satisfies every constraint of `P.shape`.

`M` MAY name bits that `P` leaves unnamed. A profile claims nothing about a circuit's behaviour; it fixes where the bits are.

A reader that has the profile file MUST check that its manifest digest equals `M.profile.sha256` before it relies on the claim, and SHOULD check conditions 1 to 4. A reader that does not have the profile file MUST present the claim as unchecked.

### 7. Commitments

A contract **commits** to a manifest for a circuit by returning the manifest digest from this function:

```solidity
/// selector 0x67b68875
function pinManifestOf(address processor, uint256 id) external view returns (bytes32 digest);
```

- `digest` is the manifest digest as a `bytes32`, or zero when the contract commits to no manifest for that circuit.
- Once the function has returned a non-zero value for a circuit, it MUST return the same value for that circuit in every later block.
- A contract that calls `tapeout` and commits to a manifest for the new circuit SHOULD set the commitment in the same transaction.
- A contract MAY announce the function through ERC-165; the interface ID is `0x67b68875`.

A reader checks a commitment by calling `pinManifestOf(processor contract, #ID)` on a contract `C` at the pinned block, under at least default agreement. A revert, return data that is not exactly 32 bytes, or zero means that `C` commits to nothing. Otherwise:

- if the value equals the digest of a manifest that passed §3 and §4 for that circuit, the manifest is **committed by `C`**;
- if it differs, the reader MUST NOT present that manifest as the one `C` uses.

A reader asks a contract `C` only when it has a reason to care what `C` commits to: it came to the circuit through `C` (for example it is displaying how `C` uses the circuit), its user named `C`, or `C` is the contract that called `tapeout` for the circuit.

A commitment says which manifest a contract was deployed with. It does not say that the manifest is true (Security Considerations).

### 8. Use and display

- A reader that shows names or converted values from a manifest MUST make available to its user the manifest's standing (§2.3), the committing contract if there is one, and the manifest digest; and for a published manifest its `updatedAt` and its site status.
- A reader that kept the digest of the manifest it last used for a circuit, and now resolves another one, SHOULD say that the manifest has changed.
- `name`, `description`, `unit` and every label come from the publisher. A reader MUST render them as plain text, never as HTML or other markup, and MUST make visible or remove the control and bidirectional characters that TAP-10 §16 lists for message text.
- This TAP changes nothing in TAP-10 §6.3: a shell displays a site, and this file as part of a site, only in state `ok`.

## Rationale

- **Bound to the netlist, not to a token.** TAP-11 binds its manifest to a processor contract, an #ID and a container, because there the subject is an identity. Here the subject is what a circuit computes, and that is fixed by the netlist bytes and the pin counts. Binding to them removes a circular dependency: an #ID exists only after tape-out, while a contract that tapes out and commits in one transaction needs the digest before. It also means one manifest serves every copy of a netlist: on X Layer at block 72,371,934, 231 of the 286 circuits with state were byte-identical copies of one 31-byte netlist, on five processor contracts. A netlist with a REF record names a processor address, and the same address can hold different circuits on different chains (TAP-10 §4.1 notes that Base and X Layer share processor addresses), so such a manifest names its chain.
- **A site file for discovery.** A manifest in the circuit's own container can be found from the circuit alone, costs no new contract, and inherits TAP-10's checks: a derived container, a length and a SHA-256, node agreement and pinned implementations. TAP-11 made the same choice for the service manifest. The key is outside `/.tape/`, which TAP-10 §8.8 reserves for gateways.
- **A commitment for stability.** `putFile` replaces an existing file (TAP-10 Appendix A), so a published manifest is what the site's writers say today. The alternatives considered for making one manifest stick:
  - *A hash recorded by the contract that tapes out.* This works, and §7 covers it, but only for circuits taped out through a contract, and a processor contract keeps no record of the tape-out caller that `eth_call` can read: the caller appears only in the `TapedOut` and `Transfer` logs. §7 therefore lets any contract commit, and a taping-out contract is one case.
  - *An event.* A contract cannot read an event, and neither can `eth_call`. Public nodes restrict log queries: the two public X Layer endpoints refused ranges above 100 blocks on 2026-10-04, and TAP-10 §11 notes that most public nodes do not serve `eth_getLogs`. An event can accompany a commitment; it cannot be one.
  - *The netlist itself.* A netlist has no header and no free bytes, and `tapeout` rejects every opcode but three (TAP-02 §2, §3). The only carrier would be gates that drive nothing, which cost transistors and change `gateCount`.
  - *A registry contract.* It would be a new contract on every chain with its own owner or its own immutability question, to hold one word per circuit that the interested contract can hold itself.
  - *A holder signature over the manifest*, as TAP-11 §5 has. It proves that one holder approved the content at some time, not that the content has stayed. It can be added later without changing this TAP.
- **SHA-256 of the file bytes.** It is the hash the site store records for every file and the one a TAP-10 client already verifies, so a published manifest needs no second hash, and a contract can compute it with the SHA-256 precompile. The digest lives outside the file, so no canonical form of JSON is needed. TAP-11 §6 needs one because its signature is a member of the file it signs.
- **`unpaid` does not stop a read.** TAP-11 applies activation to service resolution so that a name is relied on by every client or by none. A pin manifest is different in two ways. It describes a circuit that does not change, so there is nothing to keep current by paying. And only the container's effective holder can activate a name (TAP-10 Appendix A): a circuit held by a contract that has no call for it cannot be activated, and a name that an earlier holder paid for cannot be renewed when it runs out. Under TAP-11's rule the manifest of such a circuit could not be read. TAP-10 itself applies activation to shells that display sites (§6.3) and not to messaging (§12.2). This TAP keeps the status visible (§8) and leaves the rule for shells untouched. The choice is listed under Open questions.
- **Self-contained circuit manifests.** A circuit manifest repeats the fields of the profile it claims instead of inheriting them. A reader then needs one file to decode a vector, and no rule is needed for what happens when a profile and a manifest disagree: they are compared (§6.3).
- **Profiles by digest.** A name registry would need an owner. A digest needs none, and a profile can live in a TAP's assets, a repository or a site.
- **A short list of encodings, and `bits` for the rest.** Each encoding is something every reader has to implement, so the list is short. An unknown encoding falls back to `bits`, so a later version can add one without breaking a reader. `log` is on the list because amounts on chain have up to 256 bits and circuits have few pins; a floor-logarithm code with a few mantissa bits is the usual way through, and stating it once lets a generic reader show an amount where it would otherwise show a code.
- **Offsets index the TAP-02 vector.** The least significant bit of a field is the bit at `offset`, in the bit order TAP-02 §5 already fixes, so there is no separate byte-order question. §5.1 states this for a `bytes32` because that is where it has gone wrong: the same bytes read as a big-endian integer put bit 0 at position 248.
- **Offset order and no overlap.** One order makes two manifests with the same fields comparable, and a bit with two names would have two meanings.
- **A companion TAP, not a part of TAP-02.** TAP-01 §3 lists metadata formats among the conventions of Application TAPs, and a circuit is evaluated the same way with or without names. Of the three placements #44 lists (Motivation), a section of TAP-02 would tie a convention that tools may adopt to the Standards TAP that every evaluator follows, and the component-interface draft has not been published, so there is nothing yet to add to. A companion TAP keeps TAP-02 as it is and can change without it.
- **Relation to Ideas #44 and #50.** #44 asks for the mapping between named values and bit ranges, and asks how a mapping should be bound to a circuit and where it should live (its questions 5 to 7). This draft is offered as a text for that discussion. Under the boundary proposed on #50, connections between circuits, the check that one circuit's outputs fit another's inputs, and the generation of REF netlists from such connections belong to #50; a connection format can refer to fields by the names and offsets defined here. This TAP does not derive TAP-11 method descriptors or tool schemas from a manifest either; that can be built on top.
- **Left out.** Names for signals inside the netlist (a map from records to source blocks, for die shots) are larger, tool-specific and not needed to convert a vector. A manifest stored in contract storage would need its own reading rules. Connections between circuits are the subject of Idea #50.

## Backwards Compatibility

This TAP adds no contract and changes nothing in TAP-10 or TAP-02. A TAP-10 client that does not implement it sees the manifest as an ordinary site file. A circuit without a manifest is unaffected.

Tools that already keep pin names in their own files can convert them. The Covenant chip toolchain, for example, uses a file with `name`, `lsb` and `width` per field; `lsb` is this TAP's `offset`.

## Test Cases

The files are in `assets/tap-draft-circuit-pin-manifest/`. `make_manifest_vectors.py` regenerates `shift-toggle.pins.json` and `manifest-vectors.json` byte for byte from the reference implementation of this TAP and the reference evaluator of TAP-02 (`assets/tap-02/reference.py`). `pin-manifest.schema.json` is a JSON Schema (draft 2020-12) for §3 to §6; its description lists the rules that a schema cannot express.

**`shift-toggle.pins.json`** is a circuit manifest of 1,323 bytes with the digest `0x990990d0522a05d95881ae22eab2798d5dcb9f8e49236e97968bca6b26a0237a`. Its circuit is an example made for this TAP: `nIn = 2`, `nOut = 2`, `nState = 9`, nine LATCH records and five NAND records, latches-first, 71 bytes:

```
01000002  01000004  01000005  01000006  01000007  01000008  01000009  0100000a  01000011
0000000c000003  0000000c00000d  0000000300000d  0000000b00000b  0000000e00000f

netlistHash = keccak256(netlist) = 0x4d4d8bb44f524249174cb16ec625924cd96ba7c3f45c62be21901a440647fa00
```

| Vector | Field | Offset | Width | Encoding |
|---|---|---|---|---|
| inputs | `d` | 0 | 1 | `bool` |
| inputs | `en` | 1 | 1 | `bool` |
| outputs | `oldest_n` | 0 | 1 | `bool` |
| outputs | `phase_next` | 1 | 1 | `bool` |
| state | `hist` | 0 | 8 | `bits` |
| state | `phase` | 8 | 1 | `bool` |

Example: the state string `0xcd01` decodes to `hist` = raw value 205 and `phase` = true; the output string `0x01` decodes to `oldest_n` = true and `phase_next` = false.

**`covenant-v1.pins.json`** is a profile of 7,285 bytes with the digest `0x77a721cda1c499ae4ffcad1a02a9bbb75bfce2a5773e587adbc77bd660756eb5`: the pins of a Covenant vault chip, a circuit that decides once per epoch how a token's trading tax is routed. It has 96 input bits in 11 fields and 112 output bits in 14 fields, and the shape `nStateMin` 1, `nStateMax` 256, `flat`, `latchesFirst`, `maxGates` 3,400, `maxNetlistBytes` 24,000. It uses `log` with `mantissaBits` 3, `uint` with `max` and `scale`, `bool`, `zero` and `bits`. `covenant-v1.vectors.json` gives worked conversions. One of them, an output string of 14 bytes:

```
0x800080000300000080021e0b0000

T_BUY 128   T_HOLD 0   T_ALLOW 32   T_RES 96        (of 256: four shares of the fresh tax)
V_BUY 0     V_HOLD 0   V_ALLOW 0    V_RES 256
REL 2       CEIL 399 (floor amount 985162418487296)  MODE 1   TIER 0   FLAGS 0   AUX 0
```

Both files were generated from the Covenant reference model, which also checked the codec of this TAP against that project's own vectors: 64 input strings, 60 output strings and 3,623 amounts with their codes.

**`manifest-vectors.json`** (format `tap-pin-manifest-vectors/1`) contains:

- 11 files that are not manifests under §3.1: a byte order mark, invalid UTF-8, a top-level array, a repeated member name (also written once with an escape), a member named `constructor`, numbers with a fraction, with an exponent and above 2^53 − 1, an unpaired surrogate, and a file of more than 65,536 bytes;
- 24 manifests that break one rule of §3 to §6 each, among them: a field beyond its vector, two overlapping fields, fields out of offset order, a repeated field name, a `bool` field of 4 bits, an `enum` without `values`, a `values` key the field cannot hold, a `flags` field whose `bits` has the wrong length, a `log` field without `mantissaBits`, `max` beyond the field, `min` above `max`, `mantissaBits` on a `uint` field, a circuit manifest with a `shape`, and a profile with `state` and no `nState`;
- 4 manifests that are valid: with an unknown member, with an unknown encoding, with unnamed bits, and a profile that fixes its state fields;
- 7 binding cases (§4): the example circuit; the same netlist read on another chain; another netlist with the same function; the same bytes with `nIn = 3`; and a netlist with a REF record, without `chainId`, with the right one and with the wrong one;
- 6 profile cases (§6.3) against a small profile given in the file: a manifest that implements it, a wrong profile digest, a field at another offset, a field with another encoding, an `nState` outside the range, and a netlist with the same pins, state and function that is not latches-first;
- conversions (§5) on one 48-bit layout that uses every encoding: 4 sets of values with their bytes and the decoded result; 3 byte strings to decode (one with an unnamed bit set; one with an undefined `enum` value, a `zero` field that is not 0 and an out-of-range value; one shorter than the vector); and 8 values that an encoder must refuse;
- 30 points of the `log` code for `mantissaBits` 0, 3 and 4.

## Reference Implementation

`assets/tap-draft-circuit-pin-manifest/pins_reference.py` (MIT): about 600 lines of Python without dependencies. `parse` is §3.1; `validate` is §3 to §6; `check_binding` is §4; `decode_vector`, `encode_vector`, `log_code` and `log_floor` are §5; `conforms` and `check_shape` are §6.3. `check_assets.py` checks the digests of the two example manifests, runs the JSON Schema and `validate` over every manifest in the vector files, and reports how many invalid manifests the schema alone refuses (15 of 24).

No reference contract is given for §7: the commitment is one view function that returns one stored word.

The Covenant project generates `covenant-v1.pins.json` from its reference model, [`chips/golden/kernel_model.py`](https://github.com/OoJae/covenant/blob/fc90bbf/chips/golden/kernel_model.py), with [`docs/taps/assets/gen_covenant_manifest.py`](https://github.com/OoJae/covenant/blob/fc90bbf/docs/taps/assets/gen_covenant_manifest.py) (commit `fc90bbf`). Its Fab contract, [`contracts/evaluator/src/Fab.sol`](https://github.com/OoJae/covenant/blob/fc90bbf/contracts/evaluator/src/Fab.sol), records for every chip it tapes out a manifest digest that the caller supplies, and returns it from `chipInfo`. It does not check the digest and does not implement `pinManifestOf` (§7).

## Deployments

None. This TAP deploys no contract. It reads the contracts below at the addresses of TAP-10 Deployments, and accepts only the implementations that TAP-10 lists. The X Layer values were read again on 2026-10-04 from `rpc.xlayer.tech` with `eth_call` and `eth_getStorageAt` (ERC-1967 slot `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`): the factory and the circuit implementation at block 72,376,227, the opener, the site store and the payment contract at block 72,375,522. They match TAP-10. The site contracts of the other chains were not read again for this draft.

| Contract | X Layer (196) | What this TAP uses | Upgradeable? |
|---|---|---|---|
| Processor factory (UUPS proxy) | `0x1f09DAeFA827f02CBb40967cc91b259763760761`; implementation `0x74956236Ab64eD143933040B4137E8A352e4d17b`; `isSealed()` false | `cpuCount`, `cpuAt`, `isCPU` (TAP-10 §4) | Yes, until sealed |
| Processor contracts | One beacon proxy per processor; circuit implementation `0x977f217887E085D298Cb3819cDAD5A0ee35F29B2` | `circuitInfo` `0x084d60f1`, `netlist` `0x3fc4be56`, `ownerOf` `0x6352211e` | Follow the factory |
| Container opener | `0x536adD8F30f03b69f6fbF29d425A816A0dC50106` | `accountOf` `0x0c1905e5`, `isOpened` `0x8b508494` | No |
| Site store `SiteRegistry` (UUPS proxy) | `0xd6EFb7adCc9c83dC4924Ad56f6a8E4e969b9ADB6`; implementation `0xa85c4143d1D4A77f54b8e4ecC9E6D1418Afea45f` | Implementation slot, `fileInfo` `0x6c609107`, `read` `0xccaa7afb`, `readRange` `0x15a4cae2` | Yes |
| Payment contract `DomainBinding` (UUPS proxy) | `0x68809Fd2fb343aA57D0aeB7f33Defe477c9666f9`; implementation `0x5eBF29b80789e548907C707530C3C7607C4347Df` | Implementation slot, `isLive` `0xd6b062cd`, `isContainerLive` `0xdcca979e`, for the site status only | Yes |

Publishing, and the reads of §2.1 steps 3 and 4, were exercised on a local fork of X Layer at block 72,374,876, with no transaction sent to the chain: the two example netlists were taped out, a container was opened, `shift-toggle.pins.json` was written with `putFile` under the key `.well-known/tape-pins.json`, and `fileInfo` and `read` returned its size, its digest and its bytes. On the same fork, `putFile` reverted before the container was opened, and after the circuit NFT was moved to another address the previous holder and the operator it had set could no longer write.

As long as the factory, the site store and the payment contract can be upgraded, this TAP cannot become Final (TAP-01 §5.1).

## Security Considerations

- **A manifest is a claim.** Nothing checks that a field means what its name says. A manifest that calls bit 0 `approved` does not make the circuit compute an approval, and two labels can be exchanged without breaking any rule of this TAP. What a reader verifies is narrower: that the manifest is well-formed, that it describes this netlist, and who published or committed it. What a circuit computes is established from its netlist, by evaluation or by proof, and what a contract does with a circuit's outputs is established from the contract's code. A manifest should be generated from the same source as that code and its tests, as the example profile is.
- **A replaced manifest.** Whoever can write the container's site can replace the file at any time and can put back an older one: the holder, an operator the holder set, or the owner of the site store through an upgrade. A reader of a published manifest sees only the current file. Three things limit this. The file's `updatedAt` and the `FileSet` log show that a write happened. A reader can remember the digest it used (§8). And a commitment (§7) fixes one digest, so a replaced file no longer matches. Without a commitment or a remembered digest, a first-time reader cannot tell an original manifest from a replacement.
- **Change of holder.** A buyer of the circuit inherits the site and its manifest and can replace it. An operator stops being valid when the holder that set it stops being the holder. If the holder is a contract with no call into the site store, nobody can write the site any more: a wrong manifest then stays wrong, and a right one cannot be replaced. Anyone can open another holder's container, but opening it gives no right to write to it.
- **Declared hashes.** The site store records the SHA-256 that the uploader declares and does not check it. A reader verifies the bytes it read (TAP-10 §7.1). A contract that compares a commitment with `fileInfo` on chain compares two declarations, not bytes.
- **Commitments are as fixed as the committing contract.** §7 requires the value never to change, but a reader cannot check that from outside. A contract behind a proxy, or with a setter, can break the requirement. A reader that needs certainty reads the contract's code.
- **The wrong circuit.** §4 keeps a manifest from being presented for a circuit with another netlist or other pin counts, whoever publishes it. It does not keep it from being presented for another circuit with the same netlist and pin counts, which is intended. For netlists with REF records, `chainId` separates chains; the meaning of the referenced circuits is still only as fixed as their own netlists (TAP-02 Security Considerations).
- **Upgradeable contracts.** Until the processor factory is sealed, the circuit implementation behind the beacon can change. If `netlist(id)` then returns other bytes, §4 fails and the manifest is no longer accepted. If the bytes stay the same but the new implementation evaluates them differently, the manifest still passes and its field positions may no longer mean what they did; a reader that cares records the circuit implementation at the pinned block, as TAP-02 §7 recommends. Pinned implementations make a lasting change of the site store fail closed, but cannot reveal an upgrade that restores an accepted implementation within one transaction (TAP-10 §13.8).
- **State held in a word.** A contract that keeps a circuit's state in a `bytes32` keeps the packed byte string followed by zero bytes. Reading that word as an integer and applying field offsets gives wrong values without any error (§5.1). A decoder also needs `nState` from the manifest: the word does not say how many of its bits are state, and bits above `nState` must be 0.
- **Saturation and labels.** The largest `log` code stands for every larger amount. If a field also gives that code a label in `values`, an encoder turns a very large amount into the labelled value. A publisher who needs both meanings uses a wider field.
- **Parsing and display.** A manifest is attacker-controlled input. The size bound, the refusal of repeated and prototype member names and the plain-text rule of §8 limit parser differences, prototype pollution and markup injection. Field names are restricted to ASCII letters, digits and `_`, so two names that look alike are spelled alike; descriptions and labels are free text and can still mislead.
- **Activation.** A reader under this TAP reads the manifest of a site whose name is not activated, and reports the status. As TAP-10 §6.3 says, the fee is enforced by shells that display only activated sites; this TAP does not turn a reader of pin names into a shell, and it does not let a shell display the file outside state `ok`.
- **Privacy.** Resolution reads only public chain state.

### Open questions

1. Whether this text and Idea #44 should become one TAP with joint authorship, or two TAPs with a stated boundary between them.
2. Whether a manifest in a site whose status is `unpaid` may be used (this draft: yes, with the status shown), or whether TAP-11's rule should apply (Rationale).
3. The key `.well-known/tape-pins.json` and the version member name `tapepins`: both are proposals.
4. Whether a processor contract should expose the tape-out caller of a circuit in a view function. Today it can be found only in logs, which makes a commitment by the taping-out contract hard to discover with `eth_call`.
5. How this TAP relates to the "component interface" draft that the Rationale of TAP-02 mentions. That draft was not found in the TAPs repository; #44 and #50 ask the same question.
6. Whether `log` belongs in the list of encodings or should be left to profiles.
7. The member names. This draft uses `name`, `offset`, `width` and `encoding`; the experiment in #44 uses `name`, `port`, `bitOffset`, `bitWidth` and `type`. If the two texts become one, the names are a detail to settle there.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE).
