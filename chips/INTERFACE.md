# Covenant interface v1

This is the contract between the kernel (Solidity), the chips (netlists), the tools and the website.
If code and this document disagree, fix the code or change this document first.

- **Reference model:** `chips/golden/kernel_model.py`. All arithmetic below is defined by it.
- **Golden vectors:** `chips/golden/vectors.json` (regenerate with `gen_vectors.py`). Solidity, Python and TypeScript implementations must pass them bit for bit.
- **Precedence:** this file over any other description in the repository.

## 1. Scope

| | Kernel v1 | Kernel v2 (second implementation, second factory) |
|---|---|---|
| Quote asset | Native OKB only (`vault.QUOTE() == address(0)`) | Adds ERC-20 quote (USDT0) |
| Revenue | None. `REV`, `REVCUM` are 0; the `V_*` group is ignored | `RevenueInbox` feeds `REV`; `V_*` routes it |
| Holder share | Folded into the reserve | Staking after graduation |
| Chips | Flat (NAND and LATCH only) | May add REF |

The chip interface is identical for v1 and v2, so a chip taped out for v1 runs unchanged on v2.

## 2. Chip shape (enforced by the Fab)

- `nIn = 96`, `nOut = 112`.
- `1 <= nState <= 256`. Records `0 .. nState-1` are LATCH records and no LATCH follows them. State bit `i` is LATCH record `i`.
- Opcodes NAND (`0x00`) and LATCH (`0x01`) only. No REF.
- `nNand + nLatch <= 3400` and `7*nNand + 4*nLatch <= 24000` bytes (one SSTORE2 chunk).
- Format and evaluation semantics: TAP-20. Outputs are the last 112 signals.

A chip core is written as a pure function `core(s, x) -> (ns, y)`; the packer adds the LATCH records.

## 3. Bits and bytes

- TAP-20 packing: bit `i` of a vector is bit `i mod 8` of byte `i / 8`.
- A word is the little-endian integer of those bytes. Field `F` at offset `o`, width `w`: `(word >> o) & (2^w - 1)`.
- Input word: 96 bits, 12 bytes. Output word: 112 bits, 14 bytes.
- State: the kernel stores one `bytes32` holding the TAP-20 byte string right-padded with zeros. It passes all 32 bytes to `step` and stores `bytes32(newState)`.

## 4. The log code

```
lg8(0) = 0
lg8(x) = min(1023, 8*e + m + 1)      e = floor(log2 x)
                                     m = (x >> (e-3)) & 7   if e >= 3
                                         (x << (3-e)) & 7   otherwise
exp8(0) = 0
exp8(c) = ((8 + ((c-1) & 7)) << ((c-1) >> 3)) >> 3
```

- One code is 1/8 of an octave (about 9%). `lg8` is monotone and `exp8(lg8(x)) <= x`.
- Reference points: 1 wei = 1; 1e6 = 160; 0.001 OKB = 399; 0.01 OKB = 425; 1 OKB (1e18) = 478; 1e27 = 717.
- Solidity must not use the `CLZ` opcode (X Layer has no Osaka). Compile with `evm_version = "cancun"`.
- Amounts reach the chip only as codes. Shares come back as 1/256ths and are applied to exact amounts.

## 5. Input word (96 bits)

| Bits | Field | Meaning |
|---|---|---|
| 0-9 | `TAX` | `lg8` of the fresh inflow of the regime asset recognised by this settle |
| 10-19 | `TAXCUM` | `lg8` of cumulative inflow in the current regime, this settle included |
| 20-29 | `REV` | `lg8` of revenue since the last step. Kernel v1: 0 |
| 30-39 | `REVCUM` | `lg8` of cumulative revenue. Kernel v1: 0 |
| 40-49 | `RES` | `lg8` of the reserve of the regime asset before this settle's routing |
| 50-59 | `ESC` | `lg8` of the holder escrow. Kernel v1: 0 |
| 60-67 | `PROG` | Curve progress: `min(254, sold*255/sellable)`; 255 once graduated |
| 68-75 | `LOCK` | `255 * (tokens locked or burned by the kernel) / totalSupply` |
| 76-79 | `DT` | Epochs since the last persisted step; at least 1; saturates at 15 |
| 80 | `GRAD` | 1 once graduated |
| 81-95 | | Always 0. Chips must ignore these bits |

**Regime asset:** native OKB while the token is on the curve; the project token after graduation. `TAXCUM` restarts at graduation.

Every bit is assembled by the kernel from chain state. No caller supplies an input.

## 6. Output word (112 bits)

| Bits | Field | Meaning |
|---|---|---|
| 0-8 | `T_BUY` | Share of fresh tax to buy-and-lock, 0..256 |
| 9-17 | `T_HOLD` | Holder share. Kernel v1 adds it to the reserve |
| 18-26 | `T_ALLOW` | Allowance share |
| 27-35 | `T_RES` | Reserve share |
| 36-71 | `V_BUY`, `V_HOLD`, `V_ALLOW`, `V_RES` | Same four shares for fresh revenue. Kernel v1 ignores them |
| 72-80 | `REL` | Share (0..256) of the pre-settle reserve released into buy-and-lock |
| 81-90 | `CEIL` | `lg8` ceiling on this settle's allowance amount; 1023 means none |
| 91-93 | `MODE` | Telemetry |
| 94-95 | `TIER` | Telemetry |
| 96-103 | `FLAGS` | Telemetry |
| 104-111 | `AUX` | Telemetry |

A well-formed chip keeps each share group summing to exactly 256.

## 7. Envelope (immutable per kernel)

| Field | Meaning | Factory check |
|---|---|---|
| `launcher` | The wallet that will create the token; `bind` requires `tokens(token).creator == launcher` | non-zero |
| `epochLen` | Seconds per epoch | `>= 300` |
| `allowancePayee` | Receives the allowance as a pull credit | non-zero |
| `capT` | Maximum `T_ALLOW` | `<= 256` |
| `capV` | Maximum `V_ALLOW` (v2) | `<= 255` |
| `allowCumBps` | Lifetime allowance is at most this share of cumulative inflow | `<= 9999` |
| `ceilMax` | `lg8` code: maximum allowance per settle; 1023 means none | `<= 1023` |
| `relMax` | Maximum `REL` | `1..256` |
| `floorRel` | Minimum `REL` while `lg8(reserve) >= floorMin` | `1..relMax` |
| `floorMin` | `lg8` code at or above which the floor applies | `<= 425` |
| `fallbackEpochs` | Epochs without a persisted step after which the fallback split applies | `>= 2` |
| `fbAllow` | Allowance share used by the fallback | `<= capT` |
| `buyEnabled` | If false, decided buy amounts are credited to `sink` instead | |
| `sink` | Pull-credit payee used only when `buyEnabled` is false | non-zero if used |

## 8. Routing (never reverts on chip output)

For the regime asset, with `inflow` measured as a balance delta and `reserve0` the reserve before routing:

```
K1T  if any T_* > 256 or the four do not sum to 256:  (T_BUY, T_HOLD, T_ALLOW, T_RES) = (0, 0, 0, 256)
K2   if T_ALLOW > capT:  T_ALLOW = capT              (the excess stays in the reserve)
     allow = inflow * T_ALLOW / 256
     if CEIL != 1023:  allow = min(allow, exp8(CEIL))                 (the chip's own ceiling; not a clamp)
K2C  if ceilMax != 1023 and allow > exp8(ceilMax):  allow = exp8(ceilMax)
K2L  room = cumInflow * allowCumBps / 10000 - allowPaidCum;  if allow > room:  allow = room
     buyShare  = inflow * T_BUY / 256
     toReserve = inflow - allow - buyShare            (holder share, reserve share, clipped excess, rounding dust)
K3   if REL > relMax:  REL = relMax
K5   if lg8(reserve0) >= floorMin and REL < floorRel:  REL = floorRel
     release    = reserve0 * REL / 256
     buyDecided = buyShare + release
     reserve    = reserve0 - release + toReserve + (buyDecided - buyExecuted)
```

- Each `K*` sets a bit in the record's `clampBits` (values in `vectors.json`). A proven chip never sets one, so `clampBits == 0` on every epoch is the checkable meaning of "the chip decides".
- The floor (`K5`) bounds hoarding: while the reserve is above the threshold, at least `floorRel/256` of it leaves every settle. Chips are compiled with their kernel's `floorRel` and `floorMin` and must satisfy them.
- A buy leg that fails or is shrunk leaves the unexecuted part in the reserve. Nothing is lost and nothing is re-routed.
- **Evaluator failure:** the kernel checks `gasleft()` against a per-kernel floor before calling `step`, so a caller cannot force a failure by under-funding. If `step` still fails (revert, out of gas, wrong lengths), `settle()` reverts while fewer than `fallbackEpochs` epochs have passed since the last persisted step. After that, the same `settle()` applies the fallback word `T_BUY = 256 - fbAllow, T_ALLOW = fbAllow, REL = relMax, CEIL = 1023`, leaves the state unchanged and flags the record. There is no separate fallback entry point to race.

## 9. Routes by regime (kernel v1)

| | On the curve | After graduation |
|---|---|---|
| Fresh inflow | Native OKB claimed from the vault | Project token claimed from the vault |
| Buy-and-lock | One `IgnixManager.buyTo` to the kernel in try/catch. Tokens cannot move before graduation. Size is capped so a sandwich loses money (cap net of the allowance rebate), shrunk so it never graduates the curve, skipped while `snipeBpsNow > 0` or a founder round is open | Token amount sent to `0xdEaD` in try/catch |
| Allowance | Pull credit in OKB | Pull credit in the project token |
| Reserve | OKB held by the kernel | Tokens held by the kernel |
| Native OKB that arrives after graduation, and the OKB reserve left at graduation | n/a | Capped Uniswap V2 buy with `0xdEaD` as recipient, in try/catch; no allowance is taken from it. If the fork probes show this leg is unsafe, it is replaced before deployment, never left without an exit |

Requirements:
- Every asset the kernel can hold has an exit in every regime.
- Team funds must not be able to reach a buy: native `receive()` accepts value only from the vault, the manager and the V2 pair/router refund paths.
- At most one settle per epoch. `epoch = (block.timestamp - bindTime) / epochLen`.

## 10. Kernel ABI v1

`chipId()` and `settle()` are frozen forever: the immutable `KeeperTank` calls them.

```solidity
interface IKernelMin {                       // frozen by KeeperTank
    function chipId() external view returns (uint256);
    function settle() external returns (uint32 n);
}

struct Record {
    uint32  epoch;
    uint40  time;
    uint16  clampBits;
    uint8   flags;          // see below
    bytes12 inputs;         // exactly the bytes passed to step
    bytes14 outputs;        // exactly the bytes returned by step (or the fallback word)
    bytes32 stateAfter;     // stateBefore is the previous record's stateAfter (zero for n = 1)
    uint128 inflow;
    uint128 reserveBefore;
    uint128 allow;
    uint128 buyDecided;
    uint128 buyExecuted;
    uint128 tokensOut;      // tokens received on the curve, or burned after graduation
}

interface IKernelV1 is IKernelMin {
    function bind(address token) external;
    function withdrawCredit(address payee, address asset) external returns (uint256 paid);   // anyone may call; pays only payee
    function token() external view returns (address);
    function vault() external view returns (address);
    function count() external view returns (uint32);             // number of records; records are 1-indexed
    function records(uint32 n) external view returns (Record memory);
    function state() external view returns (bytes32);
    function epochNow() external view returns (uint32);
    function lastEpoch() external view returns (uint32);
    function reserve() external view returns (uint256);          // regime asset
    function creditOf(address payee, address asset) external view returns (uint256);
    function lockedTokens() external view returns (uint256);
    function graduated() external view returns (bool);
    function envelope() external view returns (Envelope memory);
    function evaluator() external view returns (address vm, bool sealedMode);
    function minSettleGas() external view returns (uint256);
}
```

Record flags: `1` fallback split applied; `2` sealed evaluator used; `4` vault claim failed; `8` curve read failed; `16` buy skipped by a guard; `32` buy call failed; `64` graduated; `128` buy shrunk by a cap.

Event: `Settled(uint32 indexed n, uint32 epoch, bytes12 inputs, bytes14 outputs, uint16 clampBits, uint8 flags, bytes32 stateAfter, uint128 inflow, uint128 allow, uint128 buyDecided, uint128 buyExecuted, uint128 tokensOut)`.

History is read with `eth_call` on `records(n)`; public RPCs cap log queries at 100 blocks.

`bind(token)` succeeds once, and only if: `vaultOf(token).RECIPIENT() == address(this)`, `vault.TOKEN() == token`, `vault.QUOTE() == address(0)`, `tokens(token).creator == launcher`, and the kernel holds the chip NFT.

## 11. Fab ABI v1

```solidity
interface IFabV1 {
    function tapeoutChip(bytes calldata netlist, bytes32 templateId) external payable returns (uint256 chipId);
    function quote(bytes calldata netlist) external view returns (uint256 nNand, uint256 nLatch, uint256 cost);
    function isChip(uint256 chipId) external view returns (bool);
    function chipInfo(uint256 chipId) external view
        returns (address snapshot, bytes32 netlistHash, uint32 nState, uint32 gateCount, address author, bytes32 templateId);
    function snapshot(uint256 chipId) external view returns (bytes memory);
}
```

`tapeoutChip` checks section 2, mints exactly the transistors needed, calls `tapeout`, stores the exact netlist bytes (SSTORE2) and their keccak, and forwards the circuit NFT to the caller. A kernel factory binds only chips for which `isChip` is true.

## 12. Evaluators

- **TapeOut:** `Circuits.step(chipId, state, inputs)`.
- **Sealed:** a Solidity port of the same one-beat semantics over the Fab snapshot. The kernel uses it whenever `beacon.implementation()`, the implementation's code hash, or `keccak256(Circuits.netlist(chipId))` differs from the values pinned at kernel creation. The check runs on every settle; there is no switch.

```solidity
interface ISealedVM {
    /// One TAP-20 beat over a flat netlist (NAND and LATCH records only) stored at an SSTORE2 pointer.
    /// Must return exactly what Circuits.step returns for the same netlist, state and inputs.
    function step(address snapshot, uint32 nIn, uint32 nOut, bytes calldata state, bytes calldata inputs)
        external view returns (bytes memory newState, bytes memory outputs);
}
```

The snapshot pointer is a contract whose runtime code is `0x00` followed by the raw netlist bytes (the SSTORE2 convention used by TapeOut's own `lib/SSTORE2.sol`).

## 13. Trust statement that code must not contradict

- Nothing on the tax path has an owner, an upgrade path or a pause.
- TapeOut's factory is unsealed (a 3-of-5 Safe can upgrade processor logic); IgnixManager is upgradeable by its owner. The keeper is liveness only.
- Unaudited.
