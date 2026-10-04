---
tap: 20
title: Circuit Netlist Format and Evaluation Semantics
description: The byte format of a TapeOut circuit netlist, when a netlist is well-formed, and exactly what one beat of evaluation computes.
author: Yintong Wang (@ronesync)
discussions-to: https://github.com/TapeOutProtocol/TAPs/issues/22
status: Draft
type: Standards
created: 2026-09-28
updated: 2026-09-30
requires: TAP-01
license: CC0-1.0
---

# TAP-20: Circuit Netlist Format and Evaluation Semantics

## Summary

This TAP writes down, byte for byte, how a TapeOut circuit is stored on chain and what it computes, so that anyone can build compilers, simulators and verifiers that agree with the chain.

## Abstract

Every circuit taped out on TapeOut is a netlist: a sequence of NAND, LATCH and REF records stored by a processor contract. This TAP specifies the record encoding, the numbering of signals, the conditions under which a netlist is well-formed, the bit packing of inputs, outputs and state, and the result of one beat of evaluation, including LATCH feedback and REF sub-circuits. It also lists the read-only contract functions through which netlists and evaluation results can be obtained, with test vectors, a reference implementation, and a comparison against 24 circuits on BNB Smart Chain mainnet.

## Motivation

The netlist format is the core of the protocol: the canvas, the evaluator, Proof-of-Design review, third-party tools and V2 components all depend on it. Today it is defined only by the code of the official front end and contracts. Independent tools have had to reconstruct it from that code, and nothing tells an implementer which of its details are guaranteed and which are accidents of one implementation.

Without a written standard:

- Compilers (Verilog to TapeOut, for example) cannot know which netlists the chain accepts;
- Verifiers cannot state what they prove, because "equivalent" depends on the evaluation semantics, in particular LATCH timing and REF state;
- Other TAPs, such as a component interface or data-format TAPs, have no normative definition of bit order and signal numbering to refer to.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174 when, and only when, they appear in all capitals.

The encoding (§2), state layout and beat semantics (§4), bit packing (§5) and the read-only functions in §6 were confirmed against BNB Smart Chain mainnet on 2026-09-29 (Test Cases). The well-formedness rules (§3), the handling of padding and byte lengths (§5) and the `tapeout` checks (§6) follow the verified source of the circuit implementation `0x8E1D125Def6d3826C278299273a0760D47626068` (`Circuits.sol` and `lib/NetlistVM.sol`, MIT, verified on BscScan), read on 2026-09-30. The one item marked **[Open]** is listed under *Open questions* at the end of Security Considerations.

### 1. Terms

| Term | Meaning |
|---|---|
| Processor contract | An ERC-721 contract created by the processor factory. It stores circuits and evaluates them. Called "cpu" in contract interfaces |
| Circuit | A pair (processor contract, circuit id). Circuit ids start at 1 within each processor contract |
| Netlist | The byte string of records that defines a circuit, together with `nIn` and `nOut` |
| Signal | A single bit value, identified by its index |
| Element | One decoded record |
| Beat | One evaluation step: from (state, inputs) to (new state, outputs) |

### 2. Signals and records

A circuit has `nIn` inputs and `nOut` outputs, `0 ≤ nIn ≤ 65,536` and `1 ≤ nOut ≤ 65,536`. `nIn` MAY be 0 (a circuit driven only by its state). Signals are numbered:

| Index | Signal |
|---|---|
| 0 | constant 0 |
| 1 | constant 1 |
| 2 … 2 + nIn − 1 | the inputs, input `i` at index `2 + i` |
| 2 + nIn onward | the outputs of the elements, in record order; each element appends the signals it produces |

A netlist is a concatenation of records with no header, no padding and no terminator. `nIn` and `nOut` are not part of the netlist bytes; they are stored alongside it (§6). All multi-byte integers are big-endian. `u24` is a 3-byte unsigned integer, used for signal indices.

| Opcode | Name | Record after the opcode byte | Record length | Signals produced |
|---|---|---|---|---|
| `0x00` | NAND | `a:u24 b:u24` | 7 bytes | 1: `NOT (a AND b)` |
| `0x01` | LATCH | `d:u24` | 4 bytes | 1: the stored state bit (§4) |
| `0x02` | REF | `cpu:20 bytes, id:u64, nIns:u8, nOuts:u8, ins:u24 × nIns` | 31 + 3·nIns bytes | nOuts: the outputs of circuit (`cpu`, `id`) |

### 3. Well-formedness

A netlist with parameters `nIn`, `nOut` is well-formed if and only if all of the following hold. Let `S` be the total number of signals: `2 + nIn` plus the number of signals produced by all elements.

1. Every opcode is `0x00`, `0x01` or `0x02`, and the last record is complete;
2. `nIn ≤ 65,536` and `1 ≤ nOut ≤ 65,536`;
3. The elements produce at least `nOut` signals, that is `2 + nIn + nOut ≤ S`. The outputs are therefore always signals produced by elements, never inputs or constants;
4. Each input `a`, `b` of a NAND, and each entry of `ins` of a REF, is an index **smaller than** the index of the first signal that element produces (references go backwards only);
5. The `d` of a LATCH is any index smaller than `S` (it MAY refer forward; this is how feedback is built);
6. For a REF: `cpu` is a processor contract registered with the processor factory (`isCPU(cpu)` is true); circuit (`cpu`, `id`) exists; its `nIn` equals `nIns` and its `nOut` equals `nOuts` (so only circuits with at most 255 inputs and 255 outputs can be referenced); and its `nState` is at most 2^24;
7. The total state, including REF sub-circuits, is at most 2^24 bits, and the total gate count, including REF sub-circuits, is at most 2^32 − 1;
8. `S ≤ 2^24`. `tapeout` does not check this directly, but a netlist that large could not fit in one transaction; tools MUST still reject it.

Tools MUST reject netlists that are not well-formed, and MUST NOT produce them. `tapeout` enforces conditions 1–7 (`Circuits.tapeout` and `NetlistVM.analyze`); records are checked in order and the first failure reverts. The revert reasons are:

| Condition | Revert reason |
|---|---|
| 1 | `bad opcode`; a truncated record reverts with a Solidity panic `0x32` (array index out of bounds), with no reason string |
| 2 | `no outputs` (nOut = 0); `too many pins` (nIn or nOut above 65,536) |
| 3 | `too few signals for outputs` |
| 4 | `NAND: future signal`; `REF: future signal` |
| 5 | `LATCH d out of range` |
| 6 | `REF: target not a registered CPU`; `no circuit` (propagated from the target's `circuitInfo`); `REF: pin mismatch`; `REF size` |
| 7 | `size overflow` |
 `tapeout` imposes no REF nesting limit and no netlist size limit other than the transaction's gas. (The 16-level REF limit in `NetlistVM` applies only to the critical-path depth used by Proof-of-Design mining, not to tape-out.)

Because a REF can only name a circuit that already exists when the referencing circuit is taped out, and a stored circuit has no setter, the REF graph is acyclic. Processor contracts are beacon proxies (Deployments), so this holds only while the circuit implementation behind the beacon does not change **[Open: until the factory is sealed]**.

### 4. State and one beat

**State layout.** A circuit's state is a bit vector of length `nState`. Walking the elements in record order, each LATCH is given the next single state bit and each REF is given the next block of `nState(sub)` bits, where `sub` is the referenced circuit. `nState` is the total. A circuit with no LATCH, directly or through REF, has `nState = 0` and is combinational.

**One beat** takes `state` (length `nState`) and `inputs` (length `nIn`) and produces `newState` and `outputs`:

1. Set signal 0 to 0, signal 1 to 1, and signal `2 + i` to `inputs[i]`;
2. For each element, in record order:
   - NAND: its output is `1 − (s[a] AND s[b])`;
   - LATCH: its output is its state bit **from `state`** (the value stored at the previous beat);
   - REF: run one beat of the referenced circuit with its block of `state` and inputs `s[ins[0]] … s[ins[nIns − 1]]`; its outputs are that beat's outputs, and that beat's new state is the REF's block of `newState`;
3. After all elements are evaluated, each LATCH's bit in `newState` is `s[d]`, the value of `d` in this beat;
4. `outputs` are the last `nOut` signals, `s[S − nOut] … s[S − 1]`, in index order.

A LATCH's output in a beat therefore never depends on that beat's inputs; a LATCH is a one-beat delay.

### 5. Bit packing

Inputs, outputs and state are passed to and from contracts as byte strings. Bit `i` of a vector is bit `i mod 8` (value `2^(i mod 8)`) of byte `floor(i / 8)`: least significant bit first.

- **Outputs and new state** are exactly `ceil(n / 8)` bytes, with the unused high bits of the last byte zero.
- **Inputs and state given to `eval` and `step`** are read leniently: bit `i` is read as 0 when byte `floor(i / 8)` is beyond the end of the byte string; bits and bytes beyond `n` are ignored. The contracts never reject an input or state because of its length or padding. Callers SHOULD send exactly `ceil(n / 8)` bytes with zero padding; a conforming evaluator MUST read other byte strings the same way as the contracts.

### 6. Contract interface (read-only part)

A processor contract exposes at least:

| Function | Selector | Returns |
|---|---|---|
| `nextId()` | `0x61b8ce8c` | the id the next taped-out circuit will get |
| `circuitInfo(uint256 id)` | `0x084d60f1` | `(uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount)`. `gateCount` counts every NAND and LATCH, including those reached through REF; for a circuit without REF it equals its own NAND + LATCH records. Reverts `no circuit` for an id that does not exist |
| `netlist(uint256 id)` | `0x3fc4be56` | `bytes`: the netlist exactly as specified in §2 |
| `eval(uint256 id, bytes inputs)` | `0x934d06ea` | `bytes`: the packed outputs of one beat. For a circuit with `nState > 0` it reverts with the reason `has latch: use step` |
| `step(uint256 id, bytes state, bytes inputs)` | `0xe8281a1a` | `(bytes newState, bytes outputs)`: one beat with caller-supplied state, all three vectors packed as in §5 |

It also exposes a state-changing `beat(address cpu, uint256 id, bytes inputs)` (`0x1fc0021d`) that keeps state on chain.

Tape-out is `tapeout(bytes netlist, uint32 nIn, uint32 nOut) payable returns (uint256 id)` (`0x7bd3ac1d`). In order, it requires `msg.value` to equal exactly the constant `TAPEOUT_FEE` (0.0002 BNB), checks §3 conditions 1–7, burns the caller's top-level NAND and LATCH count in transistor tokens (REF'd gates are not burned again), stores the netlist in 24,000-byte SSTORE2 chunks, and mints the circuit NFT to the caller with the next id. The fee check comes first (revert `tapeout fee`), then the §3 checks, then the burn. A simulated `tapeout` (`eth_call`) therefore reaches the §3 checks only when it carries `value` = 0.0002 BNB from an address whose balance covers it (a real balance, or a balance set with an `eth_call` state override); it then reverts with the §3 reason for an ill-formed netlist, and at the burn (insufficient transistor balance) for a well-formed one when the caller holds no tokens. This TAP does not specify the fee, which is part of the implementation.

The processor factory lists every processor contract: `cpuCount()` (`0xa94da8a7`) and `cpuAt(uint256 i)` (`0x4bc7cbbd`), in creation order from 0, append-only (TAP-10, appendix).

The selectors above are `keccak256` of the signatures shown, truncated to 4 bytes. `circuitInfo`, `netlist`, `eval`, `step`, `cpuCount` and `cpuAt` were called successfully on the deployed contracts; `beat` and `tapeout` change state and were not called. The signatures and return types above match the verified source.

An implementation of this TAP is **conforming** if it rejects every netlist that §3 rejects and, for every well-formed netlist and any state and inputs, either returns the outputs and new state of §4 or fails for lack of resources (gas, memory or call depth). It MUST NOT return a result that differs from §4. The deployed contracts are conforming in this sense: they impose no REF nesting limit, so a deep enough REF chain runs out of gas or call depth rather than returning a wrong result.

### 7. Requirements for tools and verifiers

1. Tools that evaluate untrusted netlists MUST bound the total number of gates and the REF depth before evaluating, and MUST NOT assume that a short netlist is cheap to evaluate.
2. Decoders MUST check record lengths before reading (§3, condition 1) and MUST NOT allocate memory in proportion to a count field before validating it.
3. Verifiers SHOULD record, for every circuit they read, the block number, the circuit's REF closure, and the circuit implementation behind the beacon at that block.
4. Tools that prove properties of circuits (equivalence for Proof-of-Design review, component certification, compilers) SHOULD state the version of this TAP they implement.

## Rationale

- **Documenting, not redesigning.** This TAP describes the format already on chain, so that the existing circuits (1,169 processor contracts at block 124,675,668) stay valid. Where the deployed behaviour is not yet confirmed, the text says so with **[Open]** instead of guessing.
- **Backward references only, except LATCH.** Evaluating elements once in record order is then always correct, and a single pass has a predictable cost. Feedback exists only through LATCH, whose value is fixed at the start of the beat, so there are no combinational loops.
- **Why REF state is a contiguous block.** It lets a REF'd sub-circuit be evaluated with a slice of the caller's state, with no per-circuit storage; it also makes state layout a pure function of the netlist.
- **Why LSB-first packing.** It is what the deployed contracts use. The component interface TAP draft uses the same packing for component ports, so circuit outputs feed component inputs with no conversion.

## Backwards Compatibility

None: this TAP records existing behaviour. If a confirmed difference between this text and the deployed contracts is found, this TAP changes to match the contracts.

## Test Cases

### Vectors

`assets/tap-20/vectors.json` (format `tap-netlist-vectors/1`) contains:

- **Valid netlists** with either a full truth table (combinational) or a sequence of beats from all-zero state (sequential), all bit vectors packed as in §5:
  - `nand`, `constants`: one gate; use of signals 0 and 1;
  - `popcount8_3151`: the on-chain bytes of circuit #3151 of processor `0xb1024b89886B9a34Aa4ff5F31C411D708b20a14C` (385 bytes, 55 NAND), `nIn = 8`, `nOut = 4`, all 256 inputs; the outputs are the population count of the inputs, least significant bit first;
  - `toggle`: a LATCH whose `d` refers forward (`q' = q XOR en`), 8 beats;
  - `ref_with_state`: a LATCH, then a REF to `toggle`, then a NAND; pins the state layout of §4 and REF semantics, 8 beats. It uses the placeholder processor address `0x00000000000000000000000000000000000000aa`, resolved from the vector's `refs` list.
- **Ill-formed netlists** that every implementation must reject: unknown opcode, truncated record, NAND forward reference, `nOut = 0`, an output that would be an input (no elements), more outputs than elements produce, REF arity mismatch, REF to a circuit that is not on a registered processor.
- **Packing edge cases** (§5) on the `nand` circuit: padding bits set, one extra byte, an empty byte string and a byte string where only padding differs, each with the output the contracts return.

`vectors.json` is generated by `make_vectors.py` from the reference implementation and is reproducible byte for byte (SHA-256 `1a02f5cf991c130a22dc6cc6ee93d0f8fe0720afed081665fa8b8018aefd203b`). Its `chainVerified` flag stays `false`: these vectors are constructed, and were not themselves sent to `eval`/`step`. The format they encode was verified on chain as below.

### Comparison with BNB Smart Chain mainnet

**Measured** on 2026-09-29, read-only (`eth_call` only, no transaction), at block 124,675,668 (re-pinned to 124,675,796 after the node pruned that block's state), node `bsc-dataseed.bnbchain.org`:

- All 1,169 processor contracts were listed from the factory with `cpuCount` / `cpuAt`. 24 circuits were sampled across 6 processor contracts: 4 with LATCH, 4 with REF, 5 with `nIn = 0`, from 1 to 1,204 gates.
- For every circuit: the netlist decodes and re-encodes to the same bytes (24/24); `nState` and `gateCount` from `circuitInfo` match the decoded netlist (24/24).
- 16 random (state, input) pairs per circuit through `step` and through a §4 simulator: **384/384 identical** (new state and outputs, bit for bit).
- `eval` on the 18 circuits with `nState = 0`: **288/288 identical**. On the 6 circuits with state it reverts with `has latch: use step`.

The comparison, with every circuit listed and the raw results, is `assets/tap-20/chain-verification.{json,md}`. This meets the condition this draft set for Review: at least 20 mainnet circuits, including at least 3 with LATCH and 3 with REF.

## Reference Implementation

- `assets/tap-20/reference.py` (MIT): decoder, encoder, well-formedness check, one-beat evaluator and bit packing in about 140 lines of dependency-free Python. This is the reference implementation of this TAP.
- The deployed contracts themselves: `Circuits.sol` and `lib/NetlistVM.sol` of the circuit implementation `0x8E1D125Def6d3826C278299273a0760D47626068` (MIT, [source verified on BscScan](https://bscscan.com/address/0x8E1D125Def6d3826C278299273a0760D47626068#code); the deployed bytecode fixes the version). Their comments state that the evaluator matches the tapeout.net JavaScript simulator bit for bit.

## Deployments

**BNB Smart Chain (56).** **Measured** read-only on 2026-09-29 at block 124,767,866, identical on `bsc-dataseed.bnbchain.org`, `bsc-dataseed1.defibit.io` and `bsc-dataseed1.ninicoin.io` (raw reads: `assets/tap-20/deployments-check.json`).

| Contract | Address | How to verify read-only | Value read | Sealed? |
|---|---|---|---|---|
| Processor factory (UUPS proxy) | `0x68224F668083c29e9800Be2a646d42d18cedF7e2` | `isSealed()` (`0x631f9852`); ERC-1967 implementation slot `0x3608…2bbc`; `owner()`; `cpuCount()`, `cpuAt(i)` | not sealed (`isSealed()` = 0); owner `0xB3D85b42A045c1A88D800CAD0F55d2566a4D3138` | **No** |
| Factory implementation | `0xa68cCF4931d98ad0A4BE15eE40542eDc0DEc6422` | must equal the factory's ERC-1967 slot | matches | — |
| Circuit beacon | `0xf8D6d8EB894d6971c8976Ad8b4971cbEFE028156` | `implementation()` must equal the circuit implementation; `owner()` must equal the factory | implementation matches; owner is the factory | Follows the factory |
| Circuit implementation | `0x8E1D125Def6d3826C278299273a0760D47626068` | code behind every processor contract; source verified on BscScan | — | — |
| Processor contracts | one beacon proxy per processor, listed by the factory | `netlist(id)`, `circuitInfo(id)`, `eval`, `step` via `eth_call` | 1,169 at block 124,675,668 | Follows the factory |

**Base (8453) and X Layer (196).** TAP-10 lists different contracts on these chains: processor factory `0x1f09DAeFA827f02CBb40967cc91b259763760761`, factory implementation `0x74956236Ab64eD143933040B4137E8A352e4d17b`, circuit beacon `0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C`, circuit implementation `0x977f217887E085D298Cb3819cDAD5A0ee35F29B2`. This TAP has not compared them with the text, and has not read their source. Until that is done, the Test Cases and the verified-source statements of this TAP apply to BNB Smart Chain only.

## Security Considerations

- **Evaluation cost is not bounded by the netlist size.** A REF costs 31 bytes but may expand to a circuit of any size, recursively (§7, requirement 1). Measured on mainnet (2026-09-29, `bsc-dataseed1.defibit.io`, block 124,676,926), `eval` on a 1,204-gate circuit used 2,789,919 execution gas, about 2,317 gas per gate. At that rate a BNB Smart Chain transaction (16,777,216 gas) evaluates about 7,000 gates. The measured `eth_call` caps are 550,000,000 gas on the bsc-dataseed nodes and 50,000,000 on publicnode, about 239,000 and 21,700 gates (*estimated*).
- **Decoders parse untrusted bytes** (§7, requirement 2).
- **REF targets are trusted code paths.** The meaning of a circuit that uses REF depends on the referenced circuits. Processor contracts are beacon proxies and the factory is not sealed, so stored netlists and their evaluation could change after tape-out (§7, requirement 3). Public nodes keep recent state only (about 128 blocks on bsc-dataseed, measured), so a verifier reading at a pinned block has to finish within that window or re-pin.
- **Equivalence is only as good as the semantics.** Proofs that two circuits are equivalent are only meaningful relative to §4 (§7, requirement 4).

### Open questions

1. When the processor factory will be sealed, after which stored netlists and their evaluation become immutable.

Resolved on 2026-09-30 from the verified source: which conditions `tapeout` enforces (§3), whether outputs may be inputs or constants (they may not, §3 condition 3), the types returned by `circuitInfo` (§6), and how padding and wrong-length byte strings are handled (§5).

## Copyright

Copyright and related rights waived via [CC0](../LICENSE).
