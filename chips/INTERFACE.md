# Covenant interface v1

This is the contract between the kernel (Solidity), the chips (netlists), the tools and the website.
If code and this document disagree, fix the code or change this document first.

- **Reference model:** `chips/golden/kernel_model.py`. All arithmetic below is defined by it.
- **Golden vectors:** `chips/golden/vectors.json` (regenerate with `gen_vectors.py`). Solidity, Python and TypeScript implementations must pass them bit for bit.
- **Precedence:** this file over any other description in the repository.
- **Revision 2** (2026-10-05). The bit layout of the input and output words is unchanged since revision 1. What changed is listed in section 14.

## 1. Scope

| | Kernel v1 | Kernel v2 (second implementation, second factory) |
|---|---|---|
| Quote asset | Native OKB only (`vault.QUOTE() == address(0)`) | Adds ERC-20 quote (USDT0) |
| Revenue | None. `REV`, `REVCUM` are 0; the `V_*` group is ignored | `RevenueInbox` feeds `REV`; `V_*` routes it |
| Holder share | Folded into the reserve | Staking after graduation |
| Allowance | Paid in OKB while the token is on the curve. None after graduation | Adds a token allowance after graduation |
| Chips | Flat (NAND and LATCH only) | May add REF |

The chip interface is identical for v1 and v2, so a chip taped out for v1 runs unchanged on v2.
That says nothing about safety on v2: kernel v1 ignores the `V_*` group, so a chip must be proven for the `V_*` group as well before it routes revenue.

## 2. Chip shape (enforced by the Fab)

- `nIn = 96`, `nOut = 112`.
- `1 <= nState <= 256`. Records `0 .. nState-1` are LATCH records and no LATCH follows them. State bit `i` is LATCH record `i`.
- Opcodes NAND (`0x00`) and LATCH (`0x01`) only. No REF.
- `112 <= nNand + nLatch <= 3400` and `7*nNand + 4*nLatch <= 24000` bytes (one SSTORE2 chunk).
- Format and evaluation semantics: TAP-20. Outputs are the last 112 signals. An output may be a LATCH output, and a chip may have no NAND at all.

A chip core is written as a pure function `core(s, x) -> (ns, y)`; the packer adds the LATCH records.

**Gas.** The kernel gives each evaluator a fixed amount of gas for one beat, computed by the kernel factory from the chip's gate and latch counts: `200,000 + 2,600 * gateCount + 800 * nState` for TapeOut's and `40,000 + 200 * nNand + 400 * nLatch` for the sealed one. Measured on a fork at the all-ones state and all-ones inputs over the corners of every shape this section allows, TapeOut's `step` needs at most 87.4% of its amount and the sealed evaluator at most 75.5% of its own (table in `contracts/core/NOTES.md`), so a chip cannot be made to fail by its own state or inputs.

## 3. Bits and bytes

- TAP-20 packing: bit `i` of a vector is bit `i mod 8` of byte `i / 8`.
- A word is the little-endian integer of those bytes. Field `F` at offset `o`, width `w`: `(word >> o) & (2^w - 1)`.
- Input word: 96 bits, 12 bytes. Output word: 112 bits, 14 bytes.
- **State is a byte string, not an integer.** It is exactly what `step` returns: `ceil(nState / 8)` bytes in TAP-20 packing. The kernel stores it in one `bytes32` with the string first and zero bytes after it (so byte 0 of the string is the most significant byte of the `bytes32` value). Do not apply the word formula above to that `bytes32`.
- The kernel passes all 32 bytes to `step` (TAP-20 ignores the extra bytes) and requires the answer to be exactly `ceil(nState / 8)` state bytes and 14 output bytes. Any other answer is an evaluator failure (section 8.4).

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
- **Width.** The kernel keeps every amount in 128 bits. A balance above `2^128 - 1` is treated as `2^128 - 1`; nothing reverts.
- **Units.** A code is a number of base units of the regime asset (section 5): wei of OKB on the curve, base units of the project token after graduation. The same code therefore means unrelated amounts in the two regimes. Chips must switch thresholds on `GRAD`.

## 5. Input word (96 bits)

| Bits | Field | Meaning |
|---|---|---|
| 0-9 | `TAX` | `lg8(inflow)`: the regime asset that arrived since the previous settle (section 8.1) |
| 10-19 | `TAXCUM` | `lg8` of cumulative inflow in the current regime, this settle included |
| 20-29 | `REV` | `lg8` of revenue since the last step. Kernel v1: 0 |
| 30-39 | `REVCUM` | `lg8` of cumulative revenue. Kernel v1: 0 |
| 40-49 | `RES` | `lg8(reserve0)`: the reserve of the regime asset before this settle's routing |
| 50-59 | `ESC` | `lg8` of the holder escrow. Kernel v1: 0 |
| 60-67 | `PROG` | Curve progress: `min(254, sold*255/sellable)`; 255 once graduated; 0 if `sellable` is 0 or the curve cannot be read before graduation |
| 68-75 | `LOCK` | `min(255, 255 * (lockedTokens + burnedTokens) / totalSupply)`: the tokens this kernel bought on the curve and still holds, plus every token it sent or bought to `0xdEaD`, over the supply read once at bind. 0 if that supply is 0 or could not be read |
| 76-79 | `DT` | Epochs since the last persisted step (since bind if there has been none); at least 1; saturates at 15 |
| 80 | `GRAD` | 1 once the kernel has latched graduation (section 9.2) |
| 81-95 | | Always 0. Chips must ignore these bits |

**Regime asset:** native OKB while the token is on the curve; the project token after graduation. `TAXCUM` and the reserve restart at graduation (section 9.2).

**Persisted step:** a settle in which the evaluator answered and the kernel stored the new state. A settle that applied the fallback word (section 8.4) is not one. After an outage `DT` therefore spans the whole outage while `TAX` covers only the inflow since the previous settle.

Every bit is assembled by the kernel from chain state. No caller supplies an input. What a caller can still influence:

- **When** within an epoch the settle happens, and whether epochs are skipped. `TAX` then covers a longer window and `DT` says how many epochs it covers. `DT = 15` means 15 or more: after a longer gap a chip that divides `TAX` by `DT` overstates the rate.
- **`PROG`** and **`LOCK`** are spot readings. One buy, settle and sell-back shows any `PROG` to one settle, so they must not drive a one-way ratchet.
- **`TAX`** and **`TAXCUM`**, by sending value to the vault or (after graduation) tokens to the kernel. It is routed like tax and the sender does not get it back, but `TAXCUM` is therefore not a measure of trading alone.
- **`RES`** includes decided buys that did not execute.

A chip should not treat one reading as proof of anything. The Flow Governor needs two surge epochs or a 16x reading to bank, eight quiet epochs for a drought and about six epochs of decline for a drawdown.

## 6. Output word (112 bits)

| Bits | Field | Meaning |
|---|---|---|
| 0-8 | `T_BUY` | Share of fresh tax to buy-and-lock, 0..256 |
| 9-17 | `T_HOLD` | Holder share. Kernel v1 adds it to the reserve |
| 18-26 | `T_ALLOW` | Allowance share. After graduation kernel v1 adds it to the reserve |
| 27-35 | `T_RES` | Reserve share |
| 36-71 | `V_BUY`, `V_HOLD`, `V_ALLOW`, `V_RES` | Same four shares for fresh revenue. Kernel v1 ignores them |
| 72-80 | `REL` | Share (0..256) of the pre-settle reserve released into buy-and-lock |
| 81-90 | `CEIL` | `lg8` ceiling on this settle's allowance amount; 1023 means none |
| 91-93 | `MODE` | Telemetry |
| 94-95 | `TIER` | Telemetry |
| 96-103 | `FLAGS` | Telemetry |
| 104-111 | `AUX` | Telemetry |

A well-formed chip keeps each share group summing to exactly 256.

The kernel never reads the telemetry fields. They are recorded as the chip gave them, and they mean something only for a chip whose published proofs tie them to its routing. A reader must not trust them on an unproven chip.

## 7. Envelope (immutable per kernel)

```solidity
struct Envelope {
    address launcher;        // the wallet that creates the token
    uint32  epochLen;        // seconds per epoch
    address allowancePayee;  // receives the allowance as a pull credit
    uint16  capT;            // maximum T_ALLOW
    uint16  capV;            // maximum V_ALLOW (kernel v2; unused by v1)
    uint16  allowCumBps;     // lifetime allowance, as a share of cumulative inflow
    uint16  ceilMax;         // lg8 code: maximum allowance per settle; 1023 means none
    uint16  relMax;          // maximum REL
    uint16  floorRel;        // minimum REL while lg8(reserve) >= floorMin
    uint16  floorMin;        // lg8 code at or above which the floor applies
    uint16  fallbackEpochs;  // epochs without a persisted step after which the fallback word applies
    uint16  fbAllow;         // allowance share used by the fallback word
    bool    buyEnabled;      // if false, decided buy amounts are credited to `sink` instead
    address sink;            // pull-credit payee used only when buyEnabled is false
}
```

| Field | Factory check |
|---|---|
| `launcher` | non-zero. Only a token it created, or one it binds itself, can be bound (section 10) |
| `epochLen` | `300 .. 86400` |
| `allowancePayee` | non-zero |
| `capT` | `<= 128` |
| `capV` | `<= 255` |
| `allowCumBps` | `<= 5000` |
| `ceilMax` | `<= 1023` |
| `relMax` | `1 .. 256` |
| `floorRel` | `1 .. relMax`, and `epochLen * 178 <= 2592000 * floorRel` |
| `floorMin` | `1 .. 425` |
| `fallbackEpochs` | `>= 2`, and `epochLen * fallbackEpochs <= 30 days` |
| `fbAllow` | `<= capT` |
| `sink` | non-zero if `buyEnabled` is false |

**What these checks guarantee for any chip, however hostile, on any kernel the factory creates:**

1. At most `allowCumBps / 10000`, and never more than half, of the OKB that ever arrives at the kernel can become allowance. The allowance payee receives nothing else, and nothing after graduation. (What arrives includes the tax on the kernel's own buys, so measured against the tax that traders paid the share is slightly higher: 19.2% rather than 18.75% for the reference envelope.)
2. Everything else can only be bought and locked, burned, or wait in the reserve. (With `buyEnabled` false it is credited to `sink` instead; that address is part of the envelope and public.)
3. A reserve at or above `exp8(floorMin)` (at most 0.009 OKB) is offered to the buy leg at `floorRel / 256` per settle or faster: with a settle every epoch it halves within 30 days and one epoch. Below that threshold the amount is dust.
4. If the evaluator stops answering, the fallback word applies within 30 days.

Everything tighter than that is the launcher's choice of envelope. The envelope, not the chip, is what a holder has to read.

## 8. Routing

### 8.1 Books

For the regime asset `A`:

```
free     = min(2^128 - 1, balanceOf(kernel, A) - credits(A) - (lockedTokens if graduated else 0))
reserve0 = min(reserve, free)                 never route more than is there
inflow   = free - reserve0
cum      = min(2^128 - 1, cumInflow + inflow)
```

- `credits(A)` is the total of unwithdrawn pull credits in `A`. `reserve` is the kernel's stored reserve of `A`.
- Inflow is what the kernel holds beyond its books. The amount a claim call reports is never used. Value that arrived between settles (a third party's `claimFor`, the platform's daily token push, a forced transfer) is counted exactly like the kernel's own claim.
- The tax paid by the kernel's own buys comes back through the vault and is inflow like any other.

### 8.2 Clamps (never revert on chip output)

```
K1T  if any T_* > 256 or the four do not sum to 256:  (T_BUY, T_HOLD, T_ALLOW, T_RES) = (0, 0, 0, 256)
     if graduated:  allow = 0  and skip to buyShare    (kernel v1 pays no allowance after graduation; no clamp bit)
K2   if T_ALLOW > capT:  T_ALLOW = capT              (the excess stays in the reserve)
     allow = inflow * T_ALLOW / 256
     if CEIL != 1023:  allow = min(allow, exp8(CEIL))                 (the chip's own ceiling; not a clamp)
K2C  if ceilMax != 1023 and allow > exp8(ceilMax):  allow = exp8(ceilMax)
K2L  room = max(0, cum * allowCumBps / 10000 - allowPaidCum);  if allow > room:  allow = room
     buyShare  = inflow * T_BUY / 256
     toReserve = inflow - allow - buyShare            (holder share, reserve share, clipped excess, rounding dust)
K3   if REL > relMax:  REL = relMax
K5   if lg8(reserve0) >= floorMin and REL < floorRel:  REL = floorRel
     release    = reserve0 * REL / 256
     buyDecided = buyShare + release
     reserve    = reserve0 + inflow - allow - buyExecuted
```

- Each `K*` sets a bit in the record's `clampBits`: `K1T` 1, `K2` 4, `K2C` 8, `K2L` 16, `K3` 32, `K5` 64. (`K1V` 2 and `K2V` 128 belong to the revenue group of kernel v2.)
- When `K2` clips, the excess is added to the reserve share, so the four effective shares still sum to 256.
- `clampBits == 0` means the envelope did not have to correct the chip in that settle. It does not mean the chip behaved well: a chip that asks for exactly the envelope's maximum every time also shows 0. A fallback record is marked by flag 1, whatever its clamp bits are (the fallback word passes through the same clamps and can set `K2C` or `K2L`). A chip with published proofs that no clamp can ever fire, such as the Flow Governor, is the case where `clampBits == 0` on every epoch means "the chip decided".
- `K5` offers the release to the buy leg. Whether it executes is section 9.
- If `allowCumBps * 256 >= capT * 10000`, `K2L` can never fire. A chip cannot see `allowPaidCum`, so this is the only way to rule `K2L` out by proof. A chip is compiled against its kernel's `capT`, `ceilMax`, `relMax`, `floorRel`, `floorMin` and `allowCumBps`.
- A buy leg that fails or is shrunk leaves the unexecuted part in the reserve. Nothing is lost and nothing is re-routed.

### 8.3 One settle per epoch

`epoch = (block.timestamp - bindTime) / epochLen`. A settle requires `epoch > lastEpoch`, and `lastEpoch` is 0 at bind, so epoch 0 is never settled: the first settle is possible once one full epoch has passed since bind. `settle()` reverts when it does no work: not bound, epoch not elapsed, too little gas, an evaluator failure inside the grace period, or a buy refused because the caller holds the callee's lock (8.6).

### 8.4 Evaluator failure and the fallback word

A beat fails only if neither evaluator answers (section 12): the TapeOut evaluator reverted, ran out of its gas or gave an answer of the wrong size or shape, and so did the sealed one. Then:

- while `epoch - lastStepEpoch < fallbackEpochs`, `settle()` reverts. Nothing moves; the tax waits in the vault. (`lastStepEpoch` is the epoch of the last persisted step, 0 before the first.)
- afterwards the same `settle()` applies the fallback word `T_BUY = 256 - fbAllow, T_ALLOW = fbAllow, REL = relMax, CEIL = 1023`, leaves the state and `lastStepEpoch` unchanged, and sets flag 1. There is no separate fallback entry point to race.
- if the evaluator answers again later, the next settle is a normal one. If it never does, every settle uses the fallback word. That is the intended end state for a dead evaluator: the tax keeps being bought and locked.

### 8.5 Gas

Every external call the kernel makes gets a fixed amount of gas, the same for every caller. Before each call the kernel checks that the 63/64 rule leaves the callee that amount, and reverts the whole settle if not. A settle therefore either reverts as a whole or writes the same record whatever gas limit the caller chose: a caller cannot starve a callee into a caught failure. `minSettleGas()` is a gas limit with which a settle never reverts for lack of gas, whether sent directly or through one calling contract.

### 8.6 A caught failure must be one every caller would see

A failure of the claim, of the curve read or of a buy becomes a flag, not a revert, so that nothing IGNIX or Uniswap does can stop a settle. The exception: if the buy fails because the callee's reentrancy lock is held, `settle()` reverts. The kernel recognises this by IgnixManager's `ReentrancyGuardReentrantCall()` on the curve; after graduation by the pair's `UniswapV2: LOCKED`, or, when the router fails before it reaches the pair, by a static `pair.sync()` that reverts because the pair is locked. That state exists only inside a call stack the caller built, so only the caller's own transaction is affected and the epoch is not consumed. (The kernel cannot tell a held lock from an upgraded IgnixManager that always answers with that error. Such an upgrade would stop settles altogether and the tax would wait in the vault; it is one of the IGNIX owner's powers named in section 13.)

## 9. Routes by regime (kernel v1)

### 9.1 On the curve

| | |
|---|---|
| Fresh inflow | Native OKB. The kernel calls `vault.claim(address(0))` in try/catch; the vault reverts on an empty balance and under IGNIX's DIVIDEND pause, and the tax then waits in the vault |
| Buy-and-lock | One `IgnixManager.buyTo` with the kernel as recipient. `amount = min(buyDecided, impactCap, maxNonGraduatingBuy)`; `minTokensOut` is the exact quote computed from the same state, so the call cannot fill at any other price. The tokens cannot move before graduation (the token reverts `CurveOnly`) and the kernel has no `approve`, `sell` or `transfer` path for them |
| Buy skipped (flag 16) | While `snipeBpsNow(token) > 0`; when the Manager reverts `FounderOnly` or `Paused`; when the curve cannot be read; when the capped amount buys zero tokens |
| Allowance | Pull credit in OKB to `allowancePayee` |
| Reserve | OKB held by the kernel |

```
impactCap(Q, F, taxBuy, taxSell, capT) = Q * (F*256 + (taxBuy + taxSell) * (256 - capT)) / (256 * 4 * 10000)
```

with `Q` the pool's quote-side reserve (`vQuote` on the curve), `F` the round-trip trading fee in bps that no trader can recover (200 on the curve) and the taxes in bps. The tax is weighted by `(256 - capT) / 256` because up to `capT / 256` of it can come back to the allowance payee.

**What the cap does and does not do.** A trader who buys before a kernel buy and sells after it loses money when the two trades surround one settle, or two adjacent ones. Two settles can be one block apart (the last block of one epoch and the first of the next); that is why the divisor is 4, not 2. A release spread over three or more epochs is not covered: a chip's outputs follow from public inputs and public state, so its schedule is predictable, and a position held across several capped buys can profit once the amounts are large relative to the pool. Chips should keep each epoch's release small relative to `Q`. For the reference deployment the cap is about 0.49 OKB per settle and the flows are far below it.

`maxNonGraduatingBuy` is the largest buy that leaves at least one base unit of token on the curve. The kernel never graduates the curve itself. If the curve is one unit from the end, the kernel's buys are zero until someone else's buy graduates it.

### 9.2 Graduation

The kernel latches `graduated` in the first settle in which the token itself reports a pair: `IgnixToken.pair() != address(0)`. The token is not upgradeable, and IGNIX's vault uses the same test to decide which asset is claimable. The latch is never cleared; a failed read neither sets nor clears it. In that settle:

- the project token becomes the regime asset; `reserve`, `cumInflow` and `allowPaidCum` restart at zero;
- the OKB the kernel still holds beyond its credits becomes the **native pot** (section 9.3);
- OKB allowance credits already made stay withdrawable.

`GRAD`, flag 64, `graduated()` and the unit of `reserve()` follow the latch. In the first graduated settle `TAX` equals `TAXCUM` and `RES` is 0.

### 9.3 After graduation

| | |
|---|---|
| Fresh inflow | Project token. It arrives by the kernel's `vault.claim(token)` (try/catch), by anyone's `claimFor`, or by the platform's push; all are counted by balance |
| Buy-and-lock | `buyDecided` tokens are sent to `0xdEaD` (the token has no burn function; the transfer is untaxed) |
| Allowance | None in kernel v1. The `T_ALLOW` share stays in the reserve |
| Reserve | Tokens held by the kernel; `REL` releases them to `0xdEaD` |
| Native pot | Residual OKB tax still claimable from the vault (including the tax of the graduating buy) and the OKB reserve left at graduation. Every settle spends it through `swapExactETHForTokensSupportingFeeOnTransferTokens` on the token's Uniswap V2 pair with `0xdEaD` as recipient, `amount = min(pot, impactCap)` with `Q` the pair's WOKB reserve and `F = 25`, and a minimum output of 99% of the exact quote. No allowance is taken from it |
| Tokens bought on the curve | `lockedTokens` is the sum of the kernel's balance changes around its own `buyTo` calls. `burnLocked()`, callable by anyone, sends them to `0xdEaD`. They are never counted as inflow or reserve |
| Tokens that reached the kernel on the curve any other way | Someone else's `buyTo` with the kernel as recipient. They are not locked tokens: they count as inflow in the first settle after graduation |

The native pot is the kernel's OKB balance minus `totalCredits(address(0))`. The router buy pays the token's buy tax like any other buy; that tax reaches the kernel as tokens and is inflow, visible to the chip in `TAX`.

With `buyEnabled` false, every amount the tables above send to a buy or a burn is credited to `sink` instead, in the asset it is in. The record then shows `buyExecuted = buyDecided`, `tokensOut = 0` and no buy flag; after graduation the native pot is credited to `sink` in OKB and no router buy is made.

### 9.4 Requirements

- **Every asset the kernel can hold has an exit in every regime**: OKB on the curve (buy, allowance credit), OKB after graduation (router buy), tokens before graduation (none can leave; they are locked, which is the intent), tokens after graduation (burn leg, `burnLocked`), credits (withdrawable at any time).
- **What can enter.** A plain OKB transfer to a kernel reverts. `receive()` accepts OKB from the vault only while the kernel is inside its own claim, and from the Manager only while the kernel is inside its own buy. A third party's `claimFor` therefore reverts before graduation and the tax waits in the vault. Three paths cannot be refused: OKB sent to the vault itself (it becomes claimable tax), OKB forced into the kernel by `SELFDESTRUCT`, and tokens sent to the kernel after graduation. All three are routed like tax and can never be taken back. That no team wallet uses them is a rule the team keeps and anyone can check from the chain; code cannot enforce it.
- **No pool-like surface.** The kernel has no fallback function and does not answer `token0()`, `token1()` or `fee()`. During the token's protection window the token probes any contract that sends or receives it and taxes those that look like pools.
- **One dependency on an outsider.** If the kernel's own buys bring the curve to one base unit from the end, they are zero from then on, and the OKB reserve waits until someone else's buy graduates the token. No team wallet may send that buy.
- **IGNIX's switches.** IGNIX's owner can pause buys (the amounts wait in the reserve) and can pause claims for 72 hours at a time, renewably (the tax waits in the vault). Neither can redirect anything.

## 10. Kernel ABI v1

`chipId()` and `settle()` are frozen forever: the immutable `KeeperTank` calls them.

```solidity
interface IKernelMin {                       // frozen by KeeperTank
    function chipId() external view returns (uint256);
    function settle() external returns (uint32 n);   // reverts when it does no work
}

struct Record {
    uint32  epoch;
    uint40  time;
    uint16  clampBits;
    uint8   flags;          // see below
    bytes12 inputs;         // exactly the bytes passed to step
    bytes14 outputs;        // exactly the bytes returned by step (or the fallback word)
    bytes32 stateAfter;     // stateBefore is the previous record's stateAfter (zero for n = 1)
    uint128 inflow;         // regime asset
    uint128 reserveBefore;  // regime asset: reserve0 of section 8.1
    uint128 allow;          // OKB credited to the allowance payee (0 after graduation)
    uint128 buyDecided;     // regime asset
    uint128 buyExecuted;    // regime asset: OKB spent on the curve, or tokens that left for 0xdEaD
    uint128 tokensOut;      // tokens received on the curve, or tokens that reached 0xdEaD (both legs) after graduation
    uint128 nativeIn;       // OKB spent by the post-graduation router buy (0 on the curve)
}

interface IKernelV1 is IKernelMin {
    function bind(address token) external;
    function withdrawCredit(address payee, address asset) external returns (uint256 paid);   // anyone may call; pays only payee
    function burnLocked() external returns (uint256 burned);    // after graduation; anyone may call
    function token() external view returns (address);
    function vault() external view returns (address);
    function count() external view returns (uint32);             // number of records; records are 1-indexed
    function records(uint32 n) external view returns (Record memory);     // all zero for n = 0 or n > count
    function cums(uint32 n) external view returns (uint128 cumInflow, uint128 allowPaidCum);   // regime totals after settle n
    function state() external view returns (bytes32);
    function epochNow() external view returns (uint32);
    function lastEpoch() external view returns (uint32);         // epoch of the last settle
    function lastStepEpoch() external view returns (uint32);     // epoch of the last persisted step
    function bindTime() external view returns (uint40);
    function reserve() external view returns (uint256);          // regime asset, as of the last settle
    function creditOf(address payee, address asset) external view returns (uint256);
    function totalCredits(address asset) external view returns (uint256);
    function lockedTokens() external view returns (uint256);
    function burnedTokens() external view returns (uint128);
    function graduated() external view returns (bool);           // as of the last settle
    function pair() external view returns (address);
    function envelope() external view returns (Envelope memory);
    function evaluator() external view returns (address vm, bool sealedMode);   // what the next settle would ask first
    function minSettleGas() external view returns (uint256);
}
```

A record together with `cums(n)`, `cums(n-1)` and the previous record's `stateAfter` is everything needed to recompute settle `n`: step the chip with `(stateBefore, inputs)`, then apply section 8.2 with the envelope.

`withdrawCredit` is non-reentrant. It returns 0 for an empty credit; it pays native credits with all remaining gas and token credits with `transfer`; if the payee refuses, it reverts and the credit stays. `epochNow()` is 0 before bind.

**Record flags**

| Bit | Set when |
|---|---|
| 1 | The fallback word was applied (section 8.4) |
| 2 | The sealed evaluator's answer was used (section 12) |
| 4 | The vault held something and a claim failed |
| 8 | The curve words of `IgnixManager.tokens(token)` could not be read or were out of range |
| 16 | A buy was skipped by a guard, or the capped amount was zero (sections 9.1, 9.3) |
| 32 | A buy, burn or swap call failed, or moved less than it was sent (a cap shrinking the amount is flag 128, not 32) |
| 64 | The record was written in the graduated regime |
| 128 | A buy was shrunk by a cap |

After graduation flags 16, 32 and 128 cover both legs (the burn and the router buy).

**Event:** `Settled(uint32 indexed n, uint32 epoch, bytes12 inputs, bytes14 outputs, uint16 clampBits, uint8 flags, bytes32 stateAfter, uint128 inflow, uint128 allow, uint128 buyDecided, uint128 buyExecuted, uint128 tokensOut)`. The router leg also emits `NativeSwept(uint32 indexed n, uint256 nativeIn, uint256 tokensBurned)`.

History is read with `eth_call` on `records(n)`; public RPCs cap log queries at 100 blocks.

**`bind(token)`** succeeds once, and only if all of these hold: `vaultOf(token).RECIPIENT() == address(this)`; `vault.TOKEN() == token`; `vault.QUOTE() == address(0)`; the token has a non-zero tax on at least one side; the kernel holds the chip NFT; and either `tokens(token).creator == launcher` (then anyone may call) or the caller is `launcher` (so a token launched from the wrong wallet can still be bound by the launcher). A token launched with any other recipient can never be bound, and its tax stays in its vault. `tools/launch-check` exists to refuse such a launch before it is signed.

**Kernel factory**

```solidity
interface IKernelFactoryV1 {
    function create(Envelope calldata env, uint256 chipId, bytes32 salt) external returns (address kernel);
    function predict(Envelope calldata env, uint256 chipId, bytes32 salt) external view returns (address);
    function isKernel(address kernel) external view returns (bool);
    function kernelOf(address token) external view returns (address);     // set when a kernel binds
    function pinsLive() external view returns (bool);
}
```

A kernel is a deterministic clone whose envelope, chip and every address it talks to are its own bytecode. Its address depends only on `(factory, env, chipId, salt)`, so it is known before the token exists. Anyone may call `create`.

**What `KeeperTank` needs from a kernel** (it is immutable and will serve kernels written later): `chipId()` never reverts and costs under 50,000 gas; `settle()` reverts whenever it writes no record, because the tank refunds every `settle()` that returns; the kernel holds its chip NFT; a kernel that pays the tank by plain transfer forwards at least 200,000 gas.

## 11. Fab ABI v1

```solidity
interface IFabV1 {
    function tapeoutChip(bytes calldata netlist, bytes32 manifestHash) external payable returns (uint256 chipId);
    function tapeoutChipTo(bytes calldata netlist, bytes32 manifestHash, address to) external payable returns (uint256 chipId);
    function quote(bytes calldata netlist) external view returns (uint256 nNand, uint256 nLatch, uint256 cost);
    function isChip(uint256 chipId) external view returns (bool);
    function chipInfo(uint256 chipId) external view
        returns (address snapshot, bytes32 netlistHash, uint32 nState, uint32 gateCount, address author, bytes32 manifestHash);
    function snapshot(uint256 chipId) external view returns (bytes memory);
}
```

`tapeoutChip` checks section 2, mints exactly the transistors needed, calls `tapeout`, stores the exact netlist bytes (SSTORE2) and their keccak, and forwards the circuit NFT to the caller. `msg.value` must equal `quote(netlist).cost`: the mint price per gate, TapeOut's fee per mint call and the tape-out fee, all read from TapeOut at the time of the call. `chipInfo` and `snapshot` revert for an id the Fab did not tape out. A kernel factory accepts only chips for which `isChip` is true.

`manifestHash` is the caller's commitment to the chip's pin manifest: the SHA-256 of the file `.well-known/tape-pins.json` that names the chip's input, output and state fields (see `docs/taps/`). The Fab records it as given and does not check it.

## 12. Evaluators

- **TapeOut:** `Circuits.step(chipId, state, inputs)`.
- **Sealed:** a Solidity port of the same one-beat semantics over the Fab snapshot.

```solidity
interface ISealedVM {
    /// One TAP-20 beat over a flat netlist (NAND and LATCH records only) stored at an SSTORE2 pointer.
    /// Must return exactly what Circuits.step returns for the same netlist, state and inputs.
    function step(address snapshot, uint32 nIn, uint32 nOut, bytes calldata state, bytes calldata inputs)
        external view returns (bytes memory newState, bytes memory outputs);
}
```

The snapshot pointer is a contract whose runtime code is `0x00` followed by the raw netlist bytes (the SSTORE2 convention used by TapeOut's own `lib/SSTORE2.sol`).

**When the sealed evaluator is used.** In two cases. First, if TapeOut's `step` is asked and fails for any reason, the kernel asks the sealed evaluator before it treats the beat as failed. Second, on every settle the kernel compares what TapeOut would run with what was pinned, and goes straight to the sealed evaluator if any comparison fails or cannot be made:

1. `beacon.implementation()` equals the pinned implementation address;
2. that address's code hash equals the pinned hash;
3. `Circuits.circuitInfo(chipId)` returns exactly `(96, 112, nState, gateCount)`;
4. `Circuits.netlist(chipId)` has the pinned length and `keccak256` of it equals the pinned hash.

Every one of these reads is a gas-capped static call that copies a bounded amount of return data; a read that fails, runs out of gas or returns an unexpected size selects the sealed evaluator and can never make `settle()` revert. The beacon and `Circuits` addresses are fixed in the kernel. The implementation address and code hash are constants of the kernel factory: they name the TapeOut implementation the differential tests ran against, not whatever is live when a kernel is created. If TapeOut has been upgraded since, every kernel simply runs on the sealed evaluator from its first settle. There is no switch, and going back and forth cannot change a result: both evaluators compute the same function of the same bytes.

## 13. Trust statement that code must not contradict

- No Covenant contract on the tax path has an owner, an upgrade path or a pause.
- TapeOut's factory is unsealed: a 3-of-5 Safe can upgrade processor logic. The kernel then uses the sealed evaluator.
- IgnixManager is upgradeable by its owner, a 1-of-2 Safe, which can also pause buys and, 72 hours at a time, claims. An upgrade could stop the buy leg or the claim (the kernel then keeps settling and the affected amounts wait), or make every settle revert (section 8.6; the tax then waits in the vault).
- The keeper is liveness only: anyone can call `settle()`.
- Unaudited.

## 14. Changes since revision 1

No bit of the input or output word moved. Revision 2 defines what revision 1 left open and tightens what the factory accepts.

- **Inflow** is defined by balance (8.1); `PROG`, `LOCK`, `DT` and `GRAD` are defined on failure paths (5).
- **No allowance after graduation** in kernel v1 (8.2, 9.3). One amount code cannot bound an allowance in two units, and a contract payee may be unable to move tokens.
- **Envelope limits** tightened: `epochLen <= 86400`, `capT <= 128`, `allowCumBps <= 5000`, `floorMin >= 1`, and a bound on how slowly the reserve may drain (7).
- **A buy that fails because the caller holds the callee's reentrancy lock reverts the settle** (8.6).
- **`receive()`** accepts the vault only during the kernel's own claim and the Manager only during its own buy (9.4).
- **State** is defined as a byte string (3); a wrong-sized evaluator answer is a failure (3, 8.4).
- **Buy sizing** is written down, with its limits (9.1).
- **Graduation** is defined step by step, including locked tokens and the native pot (9.2, 9.3).
- **ABI**: `Record.nativeIn`, `cums`, `lastStepEpoch`, `bindTime`, `burnLocked`, `burnedTokens`, `totalCredits`, `pair`; the `Envelope` struct and the factory interface are declared; record flags have defining conditions (10).
- **Fab**: the free `bytes32` is named `manifestHash`; prices are read at call time (11).
- **Sealed evaluator**: the four comparisons are listed, and the sealed evaluator is also asked whenever TapeOut's `step` fails, before the beat counts as failed (8.4, 12).
- **Gas**: the rule that makes a caught failure genuine is stated (8.5); the step gas covers every chip shape (2).
