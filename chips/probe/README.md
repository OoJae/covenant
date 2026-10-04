# Probe circuit: the epoch meter

The first circuit to be taped out on the Covenant processor. Small, real and sequential: an 8-bit saturating
counter with a sticky "ever saturated" flag. It is taped directly with `tapeout()` (not through the Fab) and it
is not a vault chip: it does not follow the 96-in / 112-out kernel interface.

Status: built, proven and rehearsed on a local fork. **Not yet on mainnet.** Nothing in this directory sent a
transaction to a real chain.

## What it computes

One beat is `step(state, inputs) -> (newState, outputs)`. Bit 0 first, TAP-20 packing (bit `i` of a vector is
bit `i mod 8` of byte `i / 8`).

| Vector | Bits | Field | Meaning |
|---|---|---|---|
| inputs (2 bits, 1 byte) | 0 | `en` | count this beat |
| | 1 | `clr` | clear the count; wins over `en`; never clears the flag |
| state (9 bits, 2 bytes) | 0-7 | `count` | saturates at 255, never wraps |
| | 8 | `flag` | set in the beat the count reaches 255; nothing clears it |
| outputs (10 bits, 2 bytes) | 0-7 | `count` | the count **after** this beat |
| | 8 | `flag` | the flag after this beat |
| | 9 | `parity` | XOR of the eight output count bits |

```
count' = clr ? 0 : (en and count != 255) ? count + 1 : count
flag'  = flag or (count' == 255)
```

Example, from the all-zero state: 254 beats with `en` give count 254 and flag 0; the 255th gives outputs
`ff01` (count 255, flag 1, parity 0); further `en` beats change nothing; a `clr` beat gives `0001` (count 0,
flag still 1).

## The netlist

| | |
|---|---|
| Transistors | **109 NAND + 9 LATCH = 118 gates** |
| Size | **799 bytes** (7 x 109 + 4 x 9) |
| keccak256 of the bytes | `0xbe0a646df5b58df69e5dc50f492dcc5bdcffa440c3188b8b786ff506cb181325` |
| nIn / nOut / nState | 2 / 10 / 9 |
| Layout | records 0-8 are the LATCH records (state bit `i` is record `i`); records 9-107 are logic; the last 10 records are the outputs |
| Logic depth | 31 NANDs |
| Synthesis | `tapc synth`, recipe `rich-compress2` (the smallest of the 12 tried: 109 to 138 NAND) |
| Toolchain | Yosys 0.69 (git sha1 9f75ca1f9) from `yowasp-yosys==0.69.0.0.post1233`, tapc 0.1.0 |

The build is deterministic: `make -C chips probe` reproduces `probe.tap` byte for byte (checked by
`chips/tools/tests/test_probe.py::test_rebuild_reproduces_the_committed_bytes`).

## Files

| File | What it is |
|---|---|
| `probe_core.v` | the source: a pure combinational Verilog function `core(s, x) -> (ns, y)` |
| `probe.pins.json` | names of the input, output and state fields |
| `probe.tap` | the netlist, raw bytes: the `netlist` argument of `tapeout` |
| `probe.hex` | the same bytes as `0x...` |
| `probe.manifest.json` | counts, keccak, signal index of every pin and latch, build inputs |
| `probe.map.json` | one entry per record (level, cone, pin name) for a die-shot renderer |
| `model.py` | behavioural model in Python, written independently of the Verilog |
| `gen_vectors.py`, `probe.vectors.json` | test vectors from the model: a 285-beat walk and all 2,048 (state, input) pairs |
| `probe_props.v` | eight properties as a Verilog wrapper around the unpacked netlist |
| `probe_props.py` | four properties for z3, including the complete specification |
| `probe.proofs.json` | proof report (22 proofs, all `proved`) |
| `fork/rehearsal.json`, `fork/difftest.jsonl` | tape-out rehearsal and differential test on a **local anvil fork** |

## What has been checked

1. **Netlist equals the model on every state and every input**: all 512 states x 4 inputs, with `tapc.sim` and
   again with TAP-20's reference evaluator.
2. **Netlist equals the RTL for every (s, x)**, proven twice: Yosys miter + SAT, and z3 on a formula built
   straight from the bytes against the word-level RTL.
3. **Properties of the bytes, for every (s, x)**, each proven by Yosys SAT and by z3:
   the flag is sticky; a count of 255 after a beat implies the flag (with the zero state this makes it a state
   invariant); the outputs equal the new state; the parity bit is the parity; `clr` wins; nothing moves without
   `en` or `clr`; the count never decreases without `clr`; `en` adds exactly one below 255.
4. **The complete specification** (`prop_full_spec` in `probe_props.py`) is valid for the bytes.
5. **The deployed TapeOut contracts accept these bytes and compute the same thing** (fork, below).

## Rehearsal on a local fork (simulation, not mainnet)

Run on an anvil fork of X Layer at block 72,372,765 against the real TapeOut factory and circuit implementation
`0x977f217887e085d298cb3819cdad5a0ee35f29b2` (runtime code hash `0x7a15c353...1b30`), with a throwaway processor
created on the fork:

- `tapeout(probe.tap, 2, 10)` succeeded; `netlist(1)` returned exactly the 799 local bytes; `circuitInfo(1)` =
  (2, 10, 9, 118).
- Gas: `tapeout` 567,908; `mint` of 109 NAND 157,599; `mint` of 9 LATCH 86,434. One `step` is estimated at
  323,972 gas.
- `tapc difftest` against the fork: 2,333 of 2,333 vectors identical (every one of the 2,048 state/input pairs,
  plus the 285-beat walk). Evidence: `fork/difftest.jsonl`; its header says `LOCAL FORK`.

Fees read from the chain at that block: `TAPEOUT_FEE` = 0.0013 OKB; the factory's `protocolFee` = 0.00066 OKB,
charged once per `mint` call (so twice per chip: one call for NAND, one for LATCH); `deployFee` = 0.0066 OKB.

## Tape-out on mainnet (for whoever signs)

On the Covenant processor, at the planned price of 0.00002 OKB per transistor:

| Step | Call | Value |
|---|---|---|
| 1 | `Transistors.mint(0, 109)` | 109 x 0.00002 + 0.00066 = 0.00284 OKB |
| 2 | `Transistors.mint(1, 9)` | 9 x 0.00002 + 0.00066 = 0.00084 OKB |
| 3 | `Circuits.tapeout(<probe.hex>, 2, 10)` | exactly 0.0013 OKB |

Total 0.00498 OKB plus about 812,000 gas. `tapeout` burns 109 of token id 0 and 9 of token id 1 from the caller
and mints the circuit NFT to the caller. If it is the first tape-out on the processor the circuit id is 1.

Two things to check before signing:

- **The minting wallet must have no code.** `mint` uses the ERC-1155 acceptance check, so a contract, or an EOA
  carrying an EIP-7702 delegation, that does not implement `IERC1155Receiver` makes it revert with
  `ERC1155InvalidReceiver`. This happened in the first rehearsal: anvil's default account has a delegation on
  X Layer. Check with `cast code <wallet> --rpc-url https://rpc.xlayer.tech` (expect `0x`).
- **The bytes.** `cast keccak $(cat chips/probe/probe.hex)` must print the keccak above.

After the tape-out, compare the chain with the simulator and commit the evidence:

```
chips/tools/bin/tapc difftest --cpu <Covenant processor> --id <circuit id> --n 10000 --seed 1 \
    --tap chips/probe/probe.tap --vectors chips/probe/probe.vectors.json \
    --out chips/probe/difftest-mainnet.jsonl
```

It exits non-zero if the on-chain bytes differ from `probe.tap` or if any vector differs. About one minute on
the public RPC.

## Rebuild and re-check

```
make -C chips probe          # synthesise, prove (22 proofs), regenerate and check the vectors
make -C chips probe-check    # the tests in chips/tools/tests/test_probe.py
```

Free read of a taped circuit, no wallet (replace the address and id):

```
cast call <processor> "step(uint256,bytes,bytes)(bytes,bytes)" <id> 0xfe00 0x01 --rpc-url https://rpc.xlayer.tech
# -> (0xff01, 0xff01): count 255, flag set, parity 0
```
