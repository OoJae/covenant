---
tap: TBD
title: Stateful Circuit Consumers
description: How a contract that runs a sequential circuit keeps the circuit's latch state between beats, records every beat so that anyone can replay it, and notices when the evaluator behind it has changed.
author: <NAME> (@OoJae)
discussions-to: <ISSUE-URL>
status: Draft
type: Application
created: 2026-10-04
requires: TAP-02
license: CC0-1.0
---

# TAP-TBD: Stateful Circuit Consumers

## Summary

This TAP sets out how a smart contract that uses a TapeOut circuit with memory keeps that memory from one run to the next and publishes each run, so that anyone can run the circuit again and check that the contract stored exactly what the circuit computed.

## Abstract

A circuit with LATCH records has state, but a processor contract stores none: `step` is a view function that takes the state from its caller and returns the next one (TAP-02 §6). A contract that wants a circuit to remember anything must keep the state itself. This TAP calls such a contract a **consumer** and specifies: the byte string in which the state is kept and its one-word form for circuits of up to 256 latches; what a consumer passes to `step` and which results it may accept; the record it keeps of every beat (inputs, outputs, state after) and the **replay rule** by which anyone checks those records against the netlist; the values a consumer pins when it is bound to a circuit, so that it notices a change of the upgradeable circuit implementation; and a small read interface through which explorers and auditors can read any consumer the same way. The netlist format, the state layout, the beat and the bit packing are those of TAP-02 and are referenced, not restated.

## Motivation

On X Layer at block 72,371,934, 286 of the 2,820 taped-out circuits had state. None of that state lives in TapeOut's contracts. The processor contract offers `step(id, state, inputs)`, which computes one beat from a state the caller supplies. TAP-02 §6 (numbered TAP-20 until PR #45) also mentions a state-changing `beat(address cpu, uint256 id, bytes inputs)` (`0x1fc0021d`) "that keeps state on chain". That selector is not in the code of the circuit implementation on X Layer, Base or BNB Smart Chain (read on 2026-10-04, Deployments), and a call to it on a processor contract reverted on X Layer and on BNB Smart Chain. Whoever uses a sequential circuit on chain therefore writes a contract that stores the state, and today each such contract decides alone:

- how the state bits are laid out in storage, and what is passed to `step`;
- what to do when `step` returns a string of an unexpected length;
- what to keep of each beat, if anything;
- how to notice that the code behind `step` has changed. The processor factory is not sealed on any chain, and its owner can replace the implementation of every processor contract in one call.

These choices decide whether a third party can check a consumer. A consumer says that it does what its circuit computes. That is only checkable if the state it stored, the inputs it used and the outputs it acted on are public in a known form, and if the rule that connects them is written down. Without a shared form, every explorer and every auditor has to learn each consumer from its source, and a mistake in one consumer's byte handling (a state cut to 32 bytes, an integer read with the wrong byte order) silently changes what the circuit sees.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174 when, and only when, they appear in all capitals.

### 1. Terms

- **Circuit**, **processor contract**, **netlist**, **beat**: as defined in TAP-02 §1. `step`, `circuitInfo` and `netlist` are the functions of TAP-02 §6. `nIn`, `nOut` and `nState` are the values `circuitInfo` returns.
- **Consumer**: a contract that runs beats of one circuit and keeps the state between them.
- **Bound circuit**: the circuit a consumer is bound to (§2).
- **State string**: the packing of the state vector (TAP-02 §4) into bytes as in TAP-02 §5: exactly `L = ceil(nState / 8)` bytes, state bit `i` at bit `i mod 8` of byte `floor(i / 8)`, and every unused bit of the last byte zero. It is the form in which `step` returns `newState`. The **input string** (`ceil(nIn / 8)` bytes) and the **output string** (`ceil(nOut / 8)` bytes) are packed the same way.
- **State word**: a state string of at most 32 bytes, followed by zero bytes up to 32 bytes (§3.2).
- **Record**: what a consumer keeps of one beat (§5).
- **Evaluator**: the code that computes a beat. The **processor evaluator** is `step` of the bound processor contract. An **alternate evaluator** is any other code that computes one beat of TAP-02 §4 over a copy of the bound circuit's netlist (§6.3).
- **Pinned value**: a value that a consumer records when it is bound and compares on later reads. The word has nothing to do with the input and output pins of a circuit.
- **Latches-first**: a netlist is latches-first when it has no REF record and no LATCH record comes after a NAND record.
- **Reader**: software that reads a consumer's records and checks them.

### 2. Binding

1. A consumer is bound to exactly one circuit: a processor contract on the consumer's own chain and a circuit id. The binding MUST NOT change once the consumer has run a beat.
2. From the time it is bound, a consumer MUST hold the circuit's `nIn`, `nOut` and `nState`, with the values that `circuitInfo` returns. `nState` MUST be greater than 0.
3. When it is bound, the consumer SHOULD record the pinned values of §6.1.
4. The state before the first beat, the **initial state**, is the state string whose bytes are all zero, unless the consumer has another initial state, which it then MUST expose (§7).

### 3. State

#### 3.1 What is stored

A consumer's state is a state string (§1). A consumer MUST NOT hold a state with a bit set at position `nState` or above, and MUST NOT hold fewer than `L` bytes of it.

#### 3.2 Forms of storage

A consumer stores its state in one of these forms:

- **String form:** the state string itself, as `bytes`. Any `nState`.
- **Word form:** one `bytes32` holding the state word. Only for `nState ≤ 256`. Byte `j` of the state string is byte `j` of the word, counted from the most significant byte; bytes `L` to 31 are zero. Read as an unsigned 256-bit integer, the word has state bit `i` at bit `8·(31 − floor(i / 8)) + (i mod 8)`. It is **not** the integer whose bit `i` is state bit `i`.
- **Several words**, for `nState > 256`: word `j` holds bytes `32j` to `32j + 31` of the state string, and the last word is padded with zero bytes.

A consumer that uses the word form MUST refuse to be bound to a circuit whose `nState` exceeds 256.

#### 3.3 Latches-first circuits

A circuit made to be used by a consumer SHOULD be latches-first. Then state bit `i` is LATCH record `i`, it occupies netlist bytes `4i` to `4i + 3`, its output is signal `2 + nIn + i`, and `nState` is the number of leading LATCH records. For other netlists the state layout is that of TAP-02 §4: each LATCH and each REF takes the next state bits in record order, wherever it stands.

### 4. One beat

A consumer runs a beat in these steps:

1. **Inputs.** It assembles an input string of exactly `ceil(nIn / 8)` bytes whose unused bits are zero. Where the input bits come from is outside this TAP.
2. **Evaluator.** It decides which evaluator to use (§6.2).
3. **Call.** It calls the evaluator with the stored state and the input string. For the processor evaluator the call is `step(id, state, inputs)`. The `state` argument is the state string or, in the word form, the 32 bytes of the state word; the result is the same (TAP-02 §5).
4. **Result.** It accepts the result only if the call succeeded, `newState` is exactly `L` bytes and `outputs` is exactly `ceil(nOut / 8)` bytes. It SHOULD also require that no bit of `newState` is set at position `nState` or above; a conforming evaluator never sets one (TAP-02 §5). Anything else is a **failed beat**.
5. **Store.** After an accepted result it stores `newState` as its state, in its form of storage with all padding zero, and writes the record of §5, in the same transaction. In the word form, the bytes after the first `L` MUST be written as zero whatever lies in memory beyond the returned string.

Further rules:

- A consumer MUST NOT replace its state with anything but the `newState` of an accepted result of a beat whose `state` argument was the state it held. In particular it has no function that sets the state.
- After a failed beat the consumer MUST NOT change its state. It MAY revert, or go on without a beat (§5.2).
- A consumer that goes on without a beat when the evaluator call fails MUST make sure that its caller cannot cause that failure by supplying too little gas: before the call it compares `gasleft()` with a floor that covers the call, and reverts below the floor.
- A consumer SHOULD limit the gas it gives to the evaluator and the amount of return data it copies.

### 5. Records and the replay rule

#### 5.1 Records

A consumer numbers its records from 1, without gaps. The record of a beat holds:

| Member | Content |
|---|---|
| `source` | `1` when the processor evaluator computed the beat, `2` when an alternate evaluator did. `0` is used by §5.2; other values are reserved |
| `inputs` | The input string passed to the evaluator |
| `outputs` | The output string the evaluator returned |
| `stateAfter` | The state string the evaluator returned, which is the consumer's state after the beat |

The state before record `n` is the `stateAfter` of record `n − 1`, and the initial state for record 1.

A consumer MUST make every record available from chain data in at least one of two ways: through a view function, or in an event emitted by the transaction that ran the beat. It SHOULD offer the view function, because many public nodes restrict log queries, and SHOULD emit the event as well. §7 gives an interface for both.

#### 5.2 Records without a beat

A consumer MAY write a record for a transaction in which it acted without a beat, for example after a failed beat. Such a record has `source` `0`. Its `stateAfter` MUST equal the state before it. Its `inputs` and `outputs` are whatever the consumer acted on; they are not outputs of the circuit and the replay rule does not cover them.

#### 5.3 The replay rule

For every record with `source` `1` or `2`:

> One beat of TAP-02 §4 over the bound circuit's netlist, from the state before the record and with the record's `inputs`, yields exactly the record's `stateAfter` and `outputs`.

A consumer MUST satisfy this rule for every record it writes, and its current state MUST equal the `stateAfter` of its last record (or the initial state, if it has none).

A reader checks a consumer as follows:

1. It reads the bound circuit, `nIn`, `nOut`, `nState` and the pinned netlist hash from the consumer (§7).
2. It obtains netlist bytes whose `keccak256` equals the pinned netlist hash, from `netlist(id)` or from any copy.
3. It sets `state` to the initial state, and for each record in order:
   - it requires `stateAfter` to be exactly `L` bytes with no bit set at `nState` or above;
   - for `source` `0`, it requires `stateAfter` to equal `state`;
   - otherwise it requires `inputs` to be exactly `ceil(nIn / 8)` bytes with its unused bits zero, computes one beat with a conforming evaluator (TAP-02 §6) from `state` and `inputs`, and requires the result to equal `stateAfter` and `outputs`;
   - it sets `state` to `stateAfter`.
4. It requires the consumer's current state to equal `state`.

A reader MAY compute the beats with `eth_call` to `step` on the processor contract while the pinned values of §6.1 hold at the block it reads; otherwise it uses its own evaluator. For a circuit whose netlist has REF records, the reader also needs the netlists of the referenced circuits.

### 6. Pinned values and a changed evaluator

#### 6.1 What is pinned

Processor contracts are beacon proxies, and until the processor factory is sealed its owner can change the implementation behind the beacon (TAP-02 §3). When it is bound, a consumer SHOULD record:

| Pinned value | How it is read | What a difference means |
|---|---|---|
| `beacon` | The address in the processor contract's ERC-1967 beacon slot `0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50`. A contract cannot read another contract's storage, so whoever binds the consumer supplies the address | (Checked by readers, §7) |
| `implementation` | `beacon.implementation()` (`0x5c60da1b`) | The implementation was replaced |
| `implementationCodeHash` | `EXTCODEHASH` of `implementation` | The code at that address is not the code that was there |
| `netlistHash` | `keccak256(netlist(id))` | The stored netlist, or the way it is returned, has changed |
| `nIn`, `nOut`, `nState` | `circuitInfo(id)` | The stored pin counts have changed; `step` reads the netlist through them |

For a circuit whose netlist has REF records, a consumer SHOULD pin `netlistHash` and the pin counts of every circuit in the REF closure as well, or SHOULD be bound to circuits without REF records only.

#### 6.2 Comparing

Before every beat with the processor evaluator, in the same transaction, a consumer that has pinned values SHOULD read each of them again and compare. If any differs, the evaluator has **changed**, and the consumer MUST NOT accept a result from the processor evaluator in that transaction. It then either runs no beat (§4), or runs the beat with an alternate evaluator.

A consumer MAY use an alternate evaluator at any time; the record's `source` says which evaluator computed each beat.

#### 6.3 Alternate evaluators

An alternate evaluator used by a consumer:

- MUST compute one beat exactly as TAP-02 §4 and §5, over netlist bytes whose `keccak256` equals the pinned `netlistHash`, with the pinned `nIn` and `nOut`;
- MUST NOT have an upgrade path, and its copy of the netlist MUST NOT be changeable;
- for a netlist with REF records, MUST hold copies of every netlist in the REF closure under the same conditions.

The result checks of §4 apply to it unchanged.

### 7. Reader interface

A consumer SHOULD implement this interface. A consumer whose records use other types, or that was deployed before this TAP, MAY be served by a separate contract that implements the interface for it by reading the consumer.

```solidity
interface ICircuitConsumer {
    event Beat(uint256 indexed n, uint8 source, bytes inputs, bytes outputs, bytes stateAfter);

    function circuit() external view returns (address processor, uint256 id, uint32 nIn, uint32 nOut, uint32 nState);
    function circuitState() external view returns (bytes memory state);
    function beatCount() external view returns (uint256);
    function beatAt(uint256 n) external view returns (uint8 source, bytes memory inputs, bytes memory outputs, bytes memory stateAfter);
    function pinnedEvaluator() external view returns (address beacon, address implementation, bytes32 implementationCodeHash, bytes32 netlistHash);
}
```

| Function or event | Selector or topic0 | Rule |
|---|---|---|
| `circuit()` | `0x1dfe0324` | The bound circuit and the pin counts kept under §2. The values never change |
| `circuitState()` | `0xc8797bfb` | The current state as a state string of exactly `L` bytes, whatever the form of storage |
| `beatCount()` | `0x85380826` | The number of records |
| `beatAt(uint256)` | `0x305d873f` | Record `n` (§5.1), with `stateAfter` as a state string of exactly `L` bytes. Reverts for `n = 0` and for `n` above `beatCount()` |
| `pinnedEvaluator()` | `0x6dfce703` | The pinned values of §6.1. A value the consumer did not pin is returned as zero |
| `Beat` | `0x4fce71f9ea0f324d8e229659864540a93ca16a1e6925a6078fffcc00fec4b489` | Emitted once per record, in the transaction that wrote it, with the record's number and members |
| `initialState()` | `0x590fa6f8` | Returns `bytes`: the initial state as a state string. REQUIRED when the initial state is not all zero. A reader that gets a revert or empty return data takes the initial state to be all zero |

The ERC-165 interface ID of `ICircuitConsumer` is `0x0d1e10c5`, the XOR of its five selectors. A consumer MAY announce it through ERC-165.

A reader MUST compare the `beacon` that `pinnedEvaluator()` returns with the address in the processor contract's ERC-1967 beacon slot, read with `eth_getStorageAt`. If they differ, the consumer watches another beacon and its `implementation` and `implementationCodeHash` say nothing about the bound processor contract.

## Rationale

- **Why a convention at all.** TAP-02 makes the evaluator a pure function and leaves the state to the caller, which is what allows a REF'd circuit to run on a slice of its caller's state. The price is that each consumer is a small piece of the protocol's state handling. A convention lets a reader check any consumer with one procedure, and puts the places where consumers go wrong in writing.
- **The state string is what `step` returns.** Storing exactly the returned bytes means that a record can be compared with a replay byte for byte, with no conversion in between.
- **A word form.** One storage slot per state is the cheapest form, and 256 bits cover most circuits: on X Layer at block 72,371,934, 285 of the 286 circuits with state had at most 256 state bits and one had 288. Padding on the right is what Solidity does when it converts `bytes` of at most 32 bytes to `bytes32`, and it keeps byte `j` of the string at byte `j` of the word. §3.2 spells out the bit positions because the other natural reading, the integer whose bit `i` is state bit `i`, puts every bit somewhere else.
- **The word may be passed to `step`.** TAP-02 §5 says that callers should send exactly `ceil(n / 8)` bytes, and requires every conforming evaluator to ignore what lies beyond. Passing the 32-byte word saves a consumer the copy that trims it. This TAP allows it because the result is defined by TAP-02 to be the same, and requires in return that the bits beyond `nState` be zero, so that what is stored is one canonical string. On X Layer the equivalence was observed on four deployed circuits and on the example circuit (Test Cases).
- **Length checks are requirements.** `step` reads a short state as if the missing bits were zero. A consumer that stored 32 bytes of a longer state would therefore clear the higher latches at every beat without any error. A consumer that accepted a short `newState` would do the same once. Both are excluded by §3.2 and §4.
- **Records in storage, not only in events.** An event is enough to replay a beat, and costs less. But a reader with only public nodes often cannot get old events: the two public X Layer endpoints refused log queries over more than 100 blocks on 2026-10-04, and TAP-10 §11 notes that most public nodes do not serve `eth_getLogs`. A view function is read with `eth_call` at any block a node serves. The rule requires one of the two and recommends both.
- **Records without a beat.** A consumer that moves value has to do something when its evaluator fails; refusing to run would leave the value stuck. Giving such records a `source` of their own keeps the sequence complete and keeps the replay rule exact for the others.
- **Three pinned values.** The implementation address detects a replacement. The code hash costs one opcode and removes the question of whether code at an address can ever differ from what was there. The netlist hash and the pin counts detect a change of what is stored, which a replacement that is later undone could make without leaving a difference in the first two. Pinning is borrowed from TAP-10, which pins the implementations of the site contracts (§6.1) and, for the DeWEB hub, the beacon's implementation and the code hash of the processor proxy (§13.4); this TAP pins the implementation's own code hash and adds the netlist. The cost is small next to a beat: `eth_estimateGas` for a beat of a 3,035-gate circuit on X Layer returned 7,140,062 gas at block 72,375,573, about 2,350 gas per gate; TAP-02 measured about 2,317 on BNB Smart Chain.
- **A changed evaluator stops the processor path, and no more.** This TAP does not tell a consumer whether to halt or to continue on an alternate evaluator; that depends on what the consumer holds. It requires that the choice is visible in every record.
- **An interface that is recommended, not required.** The requirements of §2 to §6 are about bytes and can be met by a consumer with fixed-size types and its own function names. The interface exists so that a generic reader needs no per-consumer code; a consumer that cannot implement it can be given an adapter. `circuit()` returns the pin counts because `nIn` and `nOut` are not in the netlist bytes and a replay needs them.
- **Latches-first.** It is recommended because it makes the state layout readable from the first `4·nState` bytes of the netlist and lets a simple alternate evaluator find the latches without a scan. Of the 55 circuits with state and without REF on X Layer at block 72,371,934, 53 were latches-first.
- **Left out.** How inputs are assembled, who may trigger a beat and how often, and what a consumer does with outputs are the consumer's own design. Names for the bits of the three vectors are the subject of the Circuit Pin Manifest draft; a consumer can commit to a manifest in the way that draft describes. Connecting stateful circuits to each other (who owns which state, reset, feedback), which Idea #50 lists among its open questions, is also left out: this TAP is about one contract that keeps the state of one bound circuit.

## Backwards Compatibility

This TAP adds no contract and changes nothing in TAP-02. It restricts nothing that a caller of `step` may do; it describes a way of using `step` that a contract may claim to follow.

A consumer deployed before this TAP that stores its state as a right-padded `bytes32`, passes it to `step` and records inputs, outputs and the state after each beat already meets §3 to §5 if it also checks the returned lengths. If its functions have other names, an adapter (§7) makes it readable through the interface.

## Test Cases

The files are in `assets/tap-draft-stateful-consumers/`. `make_replay_vectors.py` regenerates `replay-vectors.json` byte for byte with `replay_reference.py` and the reference evaluator of TAP-02 (`assets/tap-02/reference.py`).

**The example circuit** `shift-toggle` has `nIn = 2` (`d`, `en`), `nOut = 2` (`oldest_n`, `phase_next`) and `nState = 9`: an 8-bit shift register in state bits 0 to 7 and a toggle in state bit 8. It is latches-first, 71 bytes:

```
010000020100000401000005010000060100000701000008010000090100000a01000011
0000000c0000030000000c00000d0000000300000d0000000b00000b0000000e00000f

keccak256(netlist) = 0x4d4d8bb44f524249174cb16ec625924cd96ba7c3f45c62be21901a440647fa00
```

`L = ceil(9 / 8) = 2`: a state string has two bytes, and bits 1 to 7 of its second byte are unused.

**`replay-vectors.json`** (format `tap-replay-vectors/1`) contains 12 beats from the all-zero state. The first three:

| n | State before | `inputs` | `outputs` | `stateAfter` | State word after |
|---|---|---|---|---|---|
| 1 | `0x0000` | `0x03` | `0x03` | `0x0101` | `0x0101` followed by 30 zero bytes |
| 2 | `0x0101` | `0x00` | `0x03` | `0x0201` | `0x0201` followed by 30 zero bytes |
| 3 | `0x0201` | `0x03` | `0x01` | `0x0500` | `0x0500` followed by 30 zero bytes |

In beat 3 the state before is `0x0201`: the shift register holds `0b00000010` and the toggle is 1. With `d = 1` and `en = 1` the register becomes `0b00000101` and the toggle 0, so `stateAfter` is `0x0500`; `outputs` is `0x01` because the oldest register bit was 0 (`oldest_n` = 1) and the toggle after the beat is 0.

The file also contains:

- beat 3 asked for with other `state` arguments. The state string `0x0201`, the state word, the state string followed by six other bytes, and a word with every bit from bit 9 upward set all give `(0x0500, 0x01)`. The first byte alone, `0x02`, gives `(0x0501, 0x03)`: the missing byte reads as zero, which is another state;
- state words for `nState` 1, 8, 9, 64, 255 and 256, and four byte strings that are not state strings (a bit set beyond `nState`, one byte too few, one byte too many, a word with a non-zero byte after the string);
- a valid sequence of seven records, with one record without a beat (`source` 0) in the middle and three beats with `source` 2 after it, and seven invalid sequences with the record at which the check of §5.3 fails: a flipped bit in `stateAfter`, wrong `outputs`, a record without a beat that changes the state, a `stateAfter` with a bit beyond `nState`, a `stateAfter` that is one byte short, `inputs` with a bit beyond `nIn`, and a missing record.

**Checked against the deployed implementation.** On 2026-10-04, on a local fork of X Layer at block 72,374,876 (no transaction was sent to the chain), the example circuit and a variant with the same function that is not latches-first were taped out on a new processor contract, which runs the deployed circuit implementation `0x977f217887E085D298Cb3819cDAD5A0ee35F29B2`. `step` returned the values of the file for all 41 calls made: the 12 beats on both netlists, the 12 beats with the state word as argument, and the five other `state` arguments. On X Layer itself, at block 72,373,447, `step` was called read-only on four existing circuits with 1, 9, 16 and 288 state bits. For each, the result equalled that of the TAP-02 reference evaluator; `newState` had `ceil(nState / 8)` bytes (1, 2, 2 and 36) with its unused bits zero; the state word, where one exists, gave the same result as the state string; bits and bytes beyond `nState` were ignored; and a state string one byte short was read with the missing bits as zero.

## Reference Implementation

- `assets/tap-draft-stateful-consumers/ReferenceConsumer.sol` (MIT, 181 lines, not audited): a consumer in the word form that checks its pinned values before every beat, performs no beat when one differs, stores one record per beat and implements `ICircuitConsumer`. Its caller supplies the input string, which a real consumer must not do. On a local fork of X Layer at block 72,376,024 it was bound to the example circuit: `beatAt` returned the 12 records of `replay-vectors.json`, an input string with a bit beyond `nIn` was refused, and after the factory owner's `upgradeCircuits` was simulated with a copy of the same code at another address, `beat` reverted until the original implementation was restored.
- `assets/tap-draft-stateful-consumers/replay_reference.py` (MIT, Python without dependencies): `replay` is the reader's check of §5.3; `state_word`, `state_string` and `is_canonical` are §3.
- The Covenant kernel, the contract this TAP was drawn from, keeps a chip's state in the word form, checks the returned lengths, pins the implementation, its code hash, the pin counts and the netlist hash, falls back to an alternate evaluator over its own copy of the netlist, and stores every record. It uses fixed-size types and its own function names and does not implement `ICircuitConsumer`. The source, at commit `fc90bbf`: [`contracts/core/src/Kernel.sol`](https://github.com/OoJae/covenant/blob/fc90bbf/contracts/core/src/Kernel.sol), its second version [`contracts/core-v2/src/KernelV2.sol`](https://github.com/OoJae/covenant/blob/fc90bbf/contracts/core-v2/src/KernelV2.sol), and the alternate evaluator [`contracts/evaluator/src/SealedVM.sol`](https://github.com/OoJae/covenant/blob/fc90bbf/contracts/evaluator/src/SealedVM.sol).

## Deployments

None. This TAP deploys no contract. A consumer reads the processor contract it is bound to and that contract's beacon. The values below were read on 2026-10-04 with `eth_call`, `eth_getStorageAt` and `eth_getCode`, each chain at one block (`assets/tap-draft-stateful-consumers/deployments-check.json`). They match TAP-10 Deployments, which does not list the implementation code hashes.

| | X Layer (196) | Base (8453) | BNB Smart Chain (56) |
|---|---|---|---|
| Block read | 72,376,227 | 52,177,964 | 125,739,381 |
| Processor factory (UUPS proxy) | `0x1f09DAeFA827f02CBb40967cc91b259763760761` | the same | `0x68224F668083c29e9800Be2a646d42d18cedF7e2` |
| Factory implementation (ERC-1967 slot) | `0x74956236Ab64eD143933040B4137E8A352e4d17b` | the same | `0xa68cCF4931d98ad0A4BE15eE40542eDc0DEc6422` |
| `isSealed()` | 0 | 0 | 0 |
| Factory `owner()` | `0xB3D85b42A045c1A88D800CAD0F55d2566a4D3138` | the same | the same |
| Circuit beacon | `0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C` | the same | `0xf8D6d8EB894d6971c8976Ad8b4971cbEFE028156` |
| Beacon `owner()` | the factory | the factory | the factory |
| Circuit implementation | `0x977f217887E085D298Cb3819cDAD5A0ee35F29B2` | the same address | `0x8E1D125Def6d3826C278299273a0760D47626068` |
| Implementation code hash | `0x7a15c353205e5245f40f5f5524542a982a4bb3b9a28476e4f10845163f941b30` | `0x0b1ba888fef12a1bdc448f206d429069b2edd1ad70a4fd334a8bd8082d23f1ab` | `0x2ea433839e23b3773b7880d6f1807affb0f648ae98760b9a3b6394879665c345` |
| Processor proxy code hash | `0x57aa306fd0be97087da3534e03398f5ff4efd533b5be4e45a405ce86fa6717d5` | the same | `0xd8c4b0216e0aadd615fbd134465b6af060a11769edc7c844d8f14d1b8a783992` |
| ERC-1967 beacon slot of processor 0 | the circuit beacon | the circuit beacon | the circuit beacon |
| Selector `0x1fc0021d` (`beat`) in the implementation | absent | absent | absent |

The circuit implementation has the same address on X Layer and Base and different code, so a code hash pinned on one chain does not hold on the other. On X Layer the factory owner is a contract that answers `getThreshold()` with 3 and `getOwners()` with five addresses.

The source of the X Layer implementation is verified; its `Circuits.sol` and `lib/NetlistVM.sol` contain what this TAP relies on: `step` is a view function over stored netlist chunks, a bit beyond the end of the `state` or `inputs` string reads as 0, and `newState` is allocated as `(nState + 7) / 8` bytes.

As long as the processor factory can be upgraded, this TAP cannot become Final (TAP-01 §5.1).

## Security Considerations

- **What replay proves.** That every stored state, and every output the consumer recorded, is what the pinned netlist computes from the recorded inputs. It does not prove that the inputs were true: a consumer that assembles a wrong input string runs the circuit faithfully on wrong data. Whether the inputs follow from chain state is checked against the consumer's own code or against a published description of its pins.
- **A changed evaluator.** Until the processor factory is sealed, its owner can replace the circuit implementation for every processor contract at once. A consumer that pins nothing follows the new code without noticing. The comparison of §6.2 runs in the same transaction as the beat, so a replacement that is in effect during that transaction is seen, also when it is undone later. A replacement that changes stored netlists and is then undone is seen through `netlistHash` and the pin counts. Whatever a consumer misses, a reader that replays with the pinned netlist finds the first record that the netlist does not produce.
- **What the pinned values do not cover.** The circuits behind REF records, unless the consumer pins them too (§6.1). A change of the chain's own rules. A `beacon` that was wrong from the start, which only a reader can see (§7). And `isSealed()`: a consumer cannot conclude from it alone that checks are no longer needed, because an unsealed factory can be upgraded to answer anything; TAP-10 §13.8 lists what a client reads to establish the seal.
- **State cut or padded wrongly.** The hazards that §3 and §4 exclude are silent ones. A state of more than 256 bits kept in one word loses its upper bits, and `step` reads them as zero from then on. A `newState` shorter than `L` that is padded and stored does the same. A word copied from memory beyond the returned length can carry bits that are not state; the evaluator ignores them, but the stored word then differs from the canonical one, and comparisons and hashes of states stop agreeing. A state word read as an integer puts bit 0 at position 248. A reader needs `nState` to know how many bytes of a word are state.
- **Forcing the failure path.** A consumer that acts differently when the evaluator fails gives its caller a lever: a call with just too little gas for the evaluator makes it fail. The gas floor of §4 removes the lever. The floor has to cover the evaluator's worst case, which grows with the number of gates.
- **Return data.** A consumer that copies all return data from an evaluator it has not verified can be made to run out of gas. Checking the pinned values first and bounding the copy both prevent it.
- **Incomplete records.** A consumer could leave out a beat. The reader's check of §5.3 fails at the next record, because that record does not follow from the one before it, or at step 4, because the current state is not the last `stateAfter`.
- **Alternate evaluators.** An alternate evaluator is new code that claims to be equivalent to the processor evaluator. A difference between the two shows up in replay, but only after the consumer has acted on it. It deserves differential testing against `step` on the consumer's own circuit before it is deployed, and it must itself be impossible to change.
- **Reorganizations.** A record in a block that is not final can disappear or change its number. A reader that needs finality uses the finality tag of its chain (TAP-10 §2.1).
- **Cost.** A record in storage costs three or more storage slots per beat. A consumer for which that is too much keeps events only and accepts that its history is harder to read.

### Open questions

1. TAP-02 §6 names a state-changing `beat(address cpu, uint256 id, bytes inputs)` (`0x1fc0021d`) that keeps state on chain. The selector is not in the circuit implementation on any of the three chains (Deployments). If such a function exists in another contract, or is planned, this TAP should refer to it and align its record with it.
2. Whether the interface should expose pinned values for the REF closure, or whether consumers should be told to use circuits without REF records.
3. Whether a consumer can be given a safe on-chain way to stop comparing once the factory is sealed.
4. Whether the `Beat` event should be required rather than recommended.
5. The names of the interface (`ICircuitConsumer`, `beatAt`, `pinnedEvaluator`) are proposals.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE).
