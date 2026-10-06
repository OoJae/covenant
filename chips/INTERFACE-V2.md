# Covenant interface: what differs for kernel v2

> **Naming.** The "Kernel v2" column of `INTERFACE.md` revision 2 (section 1) describes a later *revenue* kernel
> (an ERC-20 quote plus a `RevenueInbox` feeding `REV`, `V_*` routing, staking after graduation, a token allowance
> after graduation, REF gates). That kernel is roadmap. The kernel v2 of this file is a smaller step: **kernel v2
> (USD₮0 quote)** takes only that column's first row, the ERC-20 quote, and none of the others.

Kernel v2 is the RECIPIENT of an IGNIX Directed vault whose quote is an ERC-20: USD₮0 on X Layer
(`0x779Ded0c9e1022225f8E0630b35a9b54bE713736`, 6 decimals). This file lists every way a v2 kernel differs from
`chips/INTERFACE.md` revision 2, section by section. Anything not listed here is revision 2, unchanged, and that
document wins for it. Revision 2 itself is not changed by kernel v2.

- **Reference model:** `chips/golden/kernel_model_v2.py` (the shift and the routing) and `chips/golden/world_v2.py`
  (a whole settle). Both import `kernel_model.py` and change none of it.
- **Golden vectors:** `chips/golden/vectors_v2.json` and its companion `vectors_v2_settles.jsonl`, written by
  `gen_vectors_v2.py`. `vectors.json` is unchanged.
- **Code:** `contracts/core-v2` (`KernelV2`, `KernelFactoryV2`, `LensV2`, `KernelMathV2`). Status: built and tested on
  mocks and on an X Layer fork; deployed on X Layer on 2026-10-06 (`KernelFactoryV2` `0x231c…82c1`, `LensV2`
  `0x3ebe…b049`, one kernel `0xd50A…dD75` holding chip 5, unbound; `deployments/xlayer.json`, `coreV2` and
  `flagshipV2`).

## 1. Scope

| | Kernel v1 | Kernel v2 (this file) |
|---|---|---|
| Quote asset | native OKB | an ERC-20, USD₮0 (`vault.QUOTE()` and the curve's quote word must both equal it) |
| Revenue | none | USD₮0 sent to the kernel by anyone (for example x402 with `payTo` = the kernel). **On the curve** it is inflow, routed by the chip **as tax**. **After graduation** the chip does not see it: a fixed rule buys the token with it and sends the tokens to 0xdEaD (9.3) |
| `REV`, `REVCUM`, `ESC` | 0 | 0 |
| `V_*` group, `K1V`, `K2V` | ignored, never set | ignored, never set |
| Allowance | OKB, on the curve only | USD₮0, on the curve only |
| Chips | flat | flat; a chip compiled for kernel v1 (the Flow Governor) runs unchanged through the code shift of section 4.1 |

The revenue half of the interface (a `RevenueInbox`, `route_rev`, the `V_*` routing, the Revenue Covenant chip) is
**not** part of kernel v2. It is roadmap. A v2 kernel cannot tell revenue from tax: both are USD₮0 it holds beyond
its books.

## 4.1 The code shift (new)

Every v2 kernel carries a code shift `s` in bits, fixed at creation (a pin of `KernelFactoryV2`, copied into the
clone; 33 for USD₮0). On the curve the chip sees amounts as if each USD₮0 base unit were `2^s` wei:

```
lg8s(x, s)  = lg8(min(x, 2^128 - 1) << s)      = 0 for x = 0,  min(1023, lg8(x) + 8 s) otherwise
exp8s(c, s) = exp8(c) >> s                       exp8(c + 8 s) >> s = exp8(c) for 1 <= c <= 1023 - 8 s
```

Both identities hold exactly (`kernel_model_v2.py` checks 2,740,850 cases; `KernelMathV2.t.sol` fuzzes them). A
chip's code-level behaviour and proofs therefore carry over: a v2 kernel showing USD₮0 amount `x` presents exactly the
input word a v1 kernel would present for `x * 2^s` wei.

- With `s = 33`, 1 OKB of a chip's calibration reads as `10^18 / 2^33` = 116.415321 USD₮0. That is the stated
  reference: it is the nearest whole-bit shift for any OKB price between 82.3 and 164.6 USD₮0; at the reference
  block (72,530,000) the price was 135.9 (`contracts/core-v2/NOTES.md` section 3).
- Reference points with `s = 33`: 1 USD₮0 = code 424; $0.50 = 416; 8,000 USD₮0 = 527; code 425 = 1.048576 USD₮0;
  code 440 = 3.932160 USD₮0; code 479 = 117.440512 USD₮0.
- After graduation the regime asset is the project token (18 decimals, as in v1) and `s = 0`.

## 5. Input word

| Field | Kernel v2 |
|---|---|
| `TAX` | `lg8s(inflow, s)`; inflow includes revenue paid to the kernel |
| `TAXCUM` | `lg8s(cumInflow, s)` |
| `RES` | `lg8s(reserve0, s)` |
| `REV`, `REVCUM`, `ESC` | 0 |
| others | unchanged |

`s` is the kernel's shift on the curve and 0 after graduation. **Regime asset:** USD₮0 on the curve; the project token
after graduation.

What a caller can influence, in addition to revision 2's list: **`TAX` and `TAXCUM` by paying USD₮0 to the kernel.**
Anyone can; the payment is routed like tax and the payer does not get it back.

## 7. Envelope

The struct, every factory check and every bound are revision 2's, number for number. Two readings change:

- `ceilMax` and `floorMin` are codes in the **chip's code space**, the space the shifted amounts are shown in. The
  per-settle ceiling is `exp8s(ceilMax, s)` base units of USD₮0 on the curve; the floor applies while
  `lg8s(reserve0, s) >= floorMin`. An envelope therefore means the same to a chip on either kernel.
- The guarantees, restated for USD₮0:
  1. At most `allowCumBps / 10000`, and never more than half, of the USD₮0 that arrives at the kernel on the curve
     (tax, revenue and the echo of its own buys) can become allowance, paid in USD₮0. Nothing after graduation.
  2. Everything else can only be bought and locked, burned, or wait in the reserve.
  3. A reserve at or above `exp8s(floorMin, s)`, rounded up to a base unit (at most 1.048576 USD₮0 for
     `floorMin <= 425`), is offered to the buy leg at `floorRel / 256` per settle or faster.
  4. Unchanged.

The reference envelope (`LaunchChipV2.referenceEnvelope`) is the Flow Governor's: `capT` 48, `allowCumBps` 1875,
`ceilMax` 440 (3.932160 USD₮0 per settle), `relMax` 128, `floorRel` 2, `floorMin` 1 (any non-zero reserve),
`fallbackEpochs` 16, `fbAllow` 8, epoch 900 s.

## 8. Routing

### 8.1 Books

`A` is USD₮0 on the curve. `balanceOf(kernel, A)` is a gas-capped static call; when it cannot be read, `free` is
taken as exactly what the books say (nothing new, nothing lost), as revision 2 already does for the token.

### 8.2 Clamps

`route_tax_v2` (`kernel_model_v2.py`) is `route_tax` with three substitutions and nothing else:

```
chip ceiling   allow = min(allow, exp8(CEIL) >> s)              (not a clamp)
K2C            if ceilMax != 1023 and allow > exp8(ceilMax) >> s:  allow = exp8(ceilMax) >> s
K5             if lg8(reserve0 << s) >= floorMin and REL < floorRel:  REL = floorRel
```

With `s = 0` it is `route_tax` bit for bit (every routing vector of `vectors.json` is reproduced). `K1V` and `K2V` are
never set.

### 8.5 Gas

The rule is unchanged. The fixed amounts are (each more than three times the cold worst case measured on the fork,
checked against the kernel's own constants by the fork tests): view 100,000; netlist 500,000; claim 350,000; approve
200,000; buy 700,000 (3.58 times the measured `buyTo`); transfer 200,000; swap 700,000. The
longest path has 17 view-sized calls; `minSettleGas` counts 18, both claims, both evaluators, and the larger of the
curve leg (approve, buy, reset) and the graduated legs (burn, approve, swap, reset).

## 9. Routes by regime

### 9.1 On the curve

| | Kernel v2 |
|---|---|
| Fresh inflow | USD₮0: the kernel's `vault.claim(USD₮0)` (a plain transfer, no callback), anyone's `claimFor`, and any USD₮0 sent to the kernel |
| Buy-and-lock | `approve(Manager, amount)`, then `buyTo(token, amount, exactQuote, kernel)` with `msg.value = 0`, then the allowance back to zero (read; `approve(0)` unless it reads zero), after a failed buy too. What left is measured by the kernel's USD₮0 balance. Sizing is revision 2's, in USD₮0 (`Q = vQuote`) |
| Allowance | pull credit in USD₮0 to `allowancePayee` |
| Reserve | USD₮0 held by the kernel |

### 9.2 Graduation

Unchanged, with "native OKB" read as USD₮0: the USD₮0 the kernel still holds beyond its credits becomes the **quote
pot**. The pair is token/USD₮0.

### 9.3 After graduation

| | Kernel v2 |
|---|---|
| Fresh inflow | project token, as in v1 |
| Quote pot | residual USD₮0 tax (still claimed every settle), the USD₮0 reserve left at graduation, and any USD₮0 that arrives later (revenue). Every settle spends it through `swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, minOut, [USD₮0, token], 0xdEaD, now)` after `approve(router, amount)`, resetting the allowance to zero afterwards; `amount = min(pot, impactCap)` with `Q` the pair's USD₮0 reserve and `F = 25`, minimum output 99% of the exact quote. No allowance is taken from it |
| `Record.quoteIn` | USD₮0 the router buy spent (v1: `nativeIn`, OKB) |

On the curve, revenue is routed by the chip as tax. After graduation the chip does not see revenue: the input word
carries only token flows, and a fixed rule (above) buys the token with it and sends the tokens to 0xdEaD, whatever the
chip outputs. The allowance payee gets nothing from it.

### 9.4 Requirements

- **What can enter.** There is no `receive()` and no payable function: a plain OKB transfer to a v2 kernel reverts.
  USD₮0 and, after graduation, project tokens can be sent by anyone and are routed (USD₮0 after graduation by the
  fixed rule of 9.3). No team wallet may send either (`contracts/core-v2/NOTES.md` section 1).
- **What has no exit** (stated exceptions to "every asset has an exit"; an ERC-20 transfer cannot be refused):
  - OKB forced in by `SELFDESTRUCT`: never counted, routed or sent;
  - any ERC-20 other than USD₮0 and the bound token, sent to any kernel;
  - USD₮0 sent to a kernel that is **never bound** (`settle` reverts `NotBound`, no credit exists). USD₮0 sent before
    `bind` is routed by the first settle once `bind` succeeds; if it never does (for example the token was launched
    with the wrong quote or recipient, or not at all), that USD₮0 stays there. Hence: never point `payTo` at a kernel
    before its `bind` has succeeded.
- **Approvals.** The only allowances a v2 kernel ever gives are to the IgnixManager and the router, each for exactly
  one buy, cleared in the same settle.
- **Credits.** `withdrawCredit` pays only if the transfer succeeds, returns nothing or `true`, and the kernel's balance
  falls by exactly the credit; otherwise it reverts and the credit stays. There are no native credits.

## 10. Kernel ABI v2

`IKernelMin` (`chipId()`, `settle()`) is unchanged, so the KeeperTank serves v2 kernels as they are (fork-tested). The
rest of `IKernelV1` is kept with these differences:

```solidity
struct RecordV2 { /* RecordV1's 14 fields, same order and types */ uint128 quoteIn; /* in place of nativeIn */ }
function records(uint32 n) external view returns (RecordV2 memory);
function globals() external view returns (GlobalsV2 memory);   // GlobalsV2: `quote` in place of `wokb`, plus `quoteShift`
function quote() external view returns (address);
function quoteShift() external view returns (uint256);
event QuoteSwept(uint32 indexed n, uint256 quoteIn, uint256 tokensBurned);      // v1: NativeSwept
event GraduationSeen(address indexed pair, uint256 quoteReserveReleased);
```

`Settled` is unchanged. **`bind`**: check 4 is "`vault.QUOTE()` and the curve's quote word equal the kernel's quote".

**Reading graduated records.** After graduation two legs share the flags `BUY_FAILED`, `BUY_SKIPPED` and
`BUY_SHRUNK`: the burn leg (project tokens to 0xdEaD) and the quote leg (the USD₮0 pot bought on the pair). The record
does not say which leg set a flag; readers (web, audit-team, keeper) tell them apart from the amounts and the event:

- the burn leg is `buyDecided` / `buyExecuted` (tokens) and sets only `BUY_FAILED`, when `buyExecuted < buyDecided`;
- the quote leg is `quoteIn` (USD₮0 spent) and the `QuoteSwept(n, quoteIn, tokensBurned)` event, emitted only when
  the swap went through. It sets `BUY_SKIPPED` (pair reserves unreadable, or a pot too small to buy one token unit),
  `BUY_SHRUNK` (the impact cap cut it) and `BUY_FAILED` (approve or swap failed: no `QuoteSwept`; or the swap spent
  less than sized: `QuoteSwept` with `quoteIn` below the sized amount). No pot means no flag and no event;
- so in a graduated record `BUY_SKIPPED` and `BUY_SHRUNK` are always the quote leg's, and `BUY_FAILED` is the burn
  leg's when `buyExecuted < buyDecided` and the quote leg's otherwise (both can fail in one settle: then a missing
  `QuoteSwept` while the kernel still holds USD₮0 beyond its credits shows the quote leg's part). `tokensOut` is both
  legs' tokens that reached 0xdEaD together.

**Factory:** `KernelFactoryV2(manager, v2Router, quote, quoteShift, circuits, fab, sealedVM, beacon, impl0,
impl0Hash)`. `quote` must answer `decimals() == 6` and `quoteShift <= 40`. `create`, `predict`, `isKernel`,
`kernelOf`, `pinsLive` as v1; `codeShift()` is `8 * quoteShift`.

## 13. Trust statement additions

- **Tether's owner** (one owner address, `0x4DFF…0bf8`, controls both blocking and upgrades of USD₮0) can block a kernel's address. A
  blocked kernel still receives claims and payments and keeps settling, but cannot be pulled from or send: its buys
  and its credit withdrawals fail until it is unblocked. Tether's owner can also destroy a blocked kernel's USD₮0;
  the kernel then routes what is left and never reverts. **Credits come first:** after a destruction, USD₮0 that
  arrives later (tax or revenue) first refills the credits the destroyed balance covered, and the chip sees none of
  it (`TAX` = 0) until they are covered; credits already made are repaid from it. Over the kernel's life the payee
  still receives at most `allowCumBps` of all that arrived (destroyed USD₮0 counts as having arrived), but of the
  money arriving right after a destruction up to all of it can go to the allowance payee.
- **USD₮0 is an upgradeable proxy.** Every amount is measured by balance, so a fee on transfer would make claims
  arrive short and buys fail (the Manager's exact quote no longer fills) without breaking the books.
- **Revenue is routed only if it is paid to the kernel.** `payTo` is a seller setting that the operator can change at
  any time without a trace on chain. Whether revenue reaches the kernel is the operator's choice, and IGNIX's agent
  revenue badge does not see payments to it. On the curve the chip routes revenue as tax; after graduation the chip
  does not see it and a fixed rule buys and burns (9.3).
- **No team self-payment.** No team wallet may pay revenue into a kernel that buys the team's token, or trade the
  token (`contracts/core-v2/NOTES.md` section 1).
