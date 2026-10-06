# Covenant kernel v2: notes

Kernel v2 is the option "(c′)" of `docs/design/kernel-v2.md` as revised by its review: a kernel for IGNIX Directed
tokens **quoted in USD₮0**, with x402 revenue paid straight to the kernel (`payTo` = the kernel) and routed **as tax**,
the Flow Governor reused unchanged through a fixed code shift, and everything about kernel v1 that is not about the
quote asset kept as it is. The interface delta is `chips/INTERFACE-V2.md`.

**Status (2026-10-06):** built, tested on mocks, against an independent Python model (bit for bit) and on an X Layer
fork, and rehearsed on a local anvil fork. Two independent reviews found no defect in the kernel's code; their
findings on tests, wording, the deploy script's rehearsal switch and the Architect's timeout check are fixed (section
10). Not audited. **Deployed on X Layer on 2026-10-06** (steps 1 and 2 of section 9, built from commit `a9c3c22`;
`deployments/xlayer.json`, `coreV2` and `flagshipV2`): KernelFactoryV2 `0x231c0174ebb69789813f6EcB625b4626E69A82C1`
(USD₮0, shift 33 read from the pool at deployment), KernelV2 implementation `0x0d75d4c11e4770257b2bbf2d1E0Cb78f5B50CAd5`,
LensV2 `0x3EBE9e9cbc67D6A008c55d20294357521D28b049`, and the Flow Governor taped out again as chip 5 and held by the v2
kernel `0xd50A7cb21f4ef91f795730Fe8c45EaA5E500dD75` under the reference envelope, with the Architect agent wallet
`0xBE5088307e15AAF8cF0c53bfCc4C612c9EaD6DA0` as allowance payee. `LensV2.preflight` on chain gives the figures of
section 4 exactly (TapeOut 4,496,309 of 5,326,400; SealedVM 326,054 of 443,200; `minSettleGas` 11,814,581), and the
runtime sizes equal the EIP-170 table. Steps 3 to 6 are not done: no token is launched or bound, and `PAY_TO` is the
agent wallet. A separate RevenueInbox, `routeRev` and a Revenue
Covenant chip are **roadmap**, not part of this package. ("Kernel v2" here means **kernel v2 (USD₮0 quote)**; the
"Kernel v2" column of `chips/INTERFACE.md` revision 2 is that later revenue kernel.)

## 1. Rules this package keeps

- **No team self-payment.** No team wallet may ever pay revenue into a kernel that buys the team's token, or trade
  the token. Revenue that a team wallet pays itself is not tax. Every test here pays the kernel from an address that
  has nothing to do with the launcher or the allowance payee (`payer`, `x402 buyer (unrelated to the team)`), and the
  fork tests' traders are unrelated addresses too. A live x402 test with a contract `payTo` must use a throwaway
  contract that cannot reach any kernel, never a kernel (review finding 3).
- **Revenue buys need the organisers' written approval first.** The organisers' answer of 2026-10-05 allows contract
  buys "funded by transaction taxes". Contract buys funded by x402 revenue paid to the kernel are not covered by it,
  and team trading voids eligibility. So `PAY_TO` stays on the agent wallet until IGNIX confirms in writing, in the
  Developer Support topic, that contract buys funded by third-party x402 revenue paid to the kernel are allowed, and
  until OKX.AI agent 14683 has finished its review (section 9, step 6). Until then a v2 kernel may be deployed,
  launched and bound, and routes token tax only, which is approved.
- **What is and is not promised.** Revenue is routed only if it is paid to the kernel. `payTo` is a seller setting
  that the operator can change at any time, leaving no trace on chain. Tether can freeze or burn USD₮0 held by a
  kernel (section 7). The kernel cannot tell revenue from tax. **On the curve, revenue is routed by the chip as tax.
  After graduation the chip does not see revenue; a fixed rule buys the token with it and sends the tokens to
  0xdEaD**, and the allowance payee gets nothing from it.
- **Security bar of kernel v1:** no owner, no upgrade path, no pause, no setter on the tax path; every external call
  gas-capped and measured by balance; reentrancy guarded; nothing a chip outputs can make `settle` revert.

## 2. Files, and how to run everything

| Path | What |
|---|---|
| `src/KernelV2.sol` | the kernel (clone implementation) |
| `src/KernelFactoryV2.sol` | deterministic clones; pins IGNIX, USD₮0, the shift, the processor, Fab, SealedVM, TapeOut |
| `src/LensV2.sol` | replay, counterfactual, shadow runs, stateMatters, preflight for v2 kernels |
| `src/KernelMathV2.sol` | kernel v1's routing with the code shift |
| `src/interfaces/IKernelV2.sol`, `IQuote.sol` | `GlobalsV2`, `RecordV2`, `IKernelV2`; the ERC-20 and router surface |
| `script/DeployCoreV2.s.sol`, `LaunchChipV2.s.sol` | deployment and launch scripts (chain-guarded, REHEARSAL override) |
| `test/` | unit, fuzz, golden, differential, invariant and fork tests (section 8) |
| `../../chips/golden/kernel_model_v2.py` | the reference model: the shift, `route_tax_v2`, the input word |
| `../../chips/golden/world_v2.py` | a whole settle on the test world, step for step |
| `../../chips/golden/gen_vectors_v2.py` | writes `vectors_v2.json` and `vectors_v2_settles.jsonl` |
| `../../chips/INTERFACE-V2.md` | what differs from interface revision 2 |

Kernel v1's sources are not copied: `KernelMath`, `TradeMath`, `SafeCall` and the v1 interfaces are compiled from
`contracts/core/src` through the remapping `core/`, and v1's test doubles that do not depend on the quote asset
(TapeOut, the Fab, the sealed evaluator, the project token, the V2 pair) through `core-test/`. Libraries come from
`contracts/core/lib` (run `forge install` there first if it is missing). Nothing under `contracts/core` was changed.

```sh
cd contracts/core-v2
forge build --sizes
forge test                                     # unit, fuzz, golden, differential, invariant (fork tests skip)
XLAYER_FORK=1 forge test --match-path 'test/fork/*'     # fork tests (read-only RPC; XLAYER_RPC_URL overrides)
FOUNDRY_PROFILE=deep forge test --match-contract 'InvariantsV2Test|KernelMathV2FuzzTest'
cd ../../chips/golden
python3 kernel_model_v2.py                     # self-checks: identities, and kernel v1 reproduced with shift 0
python3 gen_vectors_v2.py                      # deterministic: same files, same hashes
```

A fresh differential on another seed runs from a scratch copy of the repository (the differential reads the shipped
files by fixed path): `V2_SEED=<n> python3 chips/golden/gen_vectors_v2.py` there, then
`forge test --match-contract DiffSettlesV2Test` in its `contracts/core-v2`. Foundry's dynamic test linking is off in
`foundry.toml` (review B-F1); `BindFactoryV2Test.test_canary_an_expected_revert_of_new_does_not_end_the_test` fails
if it is switched back on.

## 3. The code shift

**Derivation.** The Flow Governor reads amounts as lg8 codes of wei of OKB (18 decimals). USD₮0 has 6 decimals. One
USD₮0 base unit is worth `10^12 / P` wei at a price of `P` USD₮0 per OKB. A code shift is exact only by whole bits,
because `lg8(x << s) = lg8(x) + 8s` holds exactly and no other multiplier commutes with lg8 (the review's finding 4;
`kernel_model_v2.py` checks both identities for every x below 2^16, every power of two to 2^128 and its
neighbours, and every s up to 40: 2,740,850 cases). So the shift is the whole number of bits nearest to
`log2(10^12 / P)`.

- **Stated reference rate:** 135.895901 USD₮0 per OKB, the spot price of the canonical Uniswap V3 USD₮0/WOKB 0.05% pool
  `0xe3BE6A0137f1b0602Fc1a4841686f43B340a5082` at X Layer block 72,530,000 (2026-10-06 15:03:56 UTC).
  `log2(10^12 / 135.895901) = 32.78`, so **s = 33 bits, a shift of 264 codes**.
- **What the chip then assumes:** 1 OKB of its calibration is `10^18 / 2^33` = **116.415321 USD₮0**. At the reference
  rate the chip reads USD₮0 flows 1.17 times larger (1.8 codes) than their OKB value.
- **The band:** 33 is the nearest whole shift for any price from **82.3 to 164.6 USD₮0 per OKB**
  (`shift_for_rate` decides it in integers; `DeployCoreV2.shiftFromPool` reads the pool and refuses to deploy outside
  the band). The shift is immutable per kernel (a factory pin copied into each clone); the price is read once, at
  deployment, and never by a kernel.

**What the Flow Governor's thresholds mean in USD₮0** (`exp8(code) >> 33`):

| Constant | Code | Kernel v1 (OKB) | Kernel v2 (USD₮0) |
|---|---|---|---|
| `FLOOR_Q` (reading floor per epoch) | 346 | 9.9e12 wei | 0.0012 USD₮0 (1,152 base units) |
| `RESMIN_Q` (smallest reserve for DEFEND) | 389 | 4.2e14 wei | 0.049 USD₮0 |
| `M1`, `M2`, `M3` (allowance milestones) | 425, 452, 479 | 0.0090, 0.0991, 1.0088 OKB | 1.048576, 11.534336, 117.440512 USD₮0 |
| `CEIL0` (allowance ceiling per settle, tier 0) | 440 | 0.0338 OKB | 3.932160 USD₮0 |
| envelope `floorMin` bound | 425 | 0.009 OKB | 1.048576 USD₮0 |

One x402 call at $0.50 reads as code 416 (152 + 264), 70 codes above the reading floor: it registers as live flow.

**Envelope codes are in the chip's code space.** `ceilMax` and `floorMin` are compared with shifted codes, so the
Flow Governor's proof that no clamp fires on its reference envelope carries over unchanged: on the fork, 20 curve
epochs with traders and x402 revenue gave `clampBits == 0` on every record. The reference envelope in USD₮0 terms:
at most 18.75% of a settle's inflow and of all curve inflow becomes allowance, at most 3.932160 USD₮0 per settle, the
floor applies to any non-zero reserve.

**After graduation** the regime asset is the project token, 18 decimals as in kernel v1, and the shift is 0. One
calibration difference remains and is stated, not fixed: the Flow Governor's token thresholds are its OKB thresholds
moved by `TOKEN_SHIFT` = 169 codes, the token units per wei at the opening of an 85 OKB pair. An 8,000 USD₮0 curve
opens its pair at 200,000,000 tokens against 7,999.999999 USD₮0, which through the shift is 171.8 codes. The token
regime therefore reads flows about 2.5 codes (1.24 times) higher than the curve regime does at the same value.

## 4. Gas and size

**Fixed gas per external call** (`KernelV2` constants), each more than three times the worst case measured on the
fork at block 72,530,000 with cold accounts and zero-to-non-zero writes (`test_fork_v2_measure_live_call_gas`,
`test_fork_v2_measure_router_buy_gas`, which compare with the kernel's own constants through
`test/utils/GasPinsV2.sol`, so changing a constant trips them). The fork measurement raised three of them during
this work: the first values (claim 200,000, approve 100,000, buy 500,000) were below three times the cold costs. The
review then raised the buy from 600,000 (3.07 times the measured `buyTo`, too thin a margin for an IgnixManager
upgrade) to 700,000 (3.58 times); `minSettleGas` did not change, because the graduated legs are the larger pair.

| Call | Allowance | Measured (cold) |
|---|---|---|
| USD₮0 `balanceOf` / `allowance` (and other views) | 100,000 | 14,747 / 10,585 |
| `Circuits.netlist` | 500,000 | kernel v1: 140,355 for 23,032 bytes |
| `vault.claim(USD₮0)` / `claim(token)` | 350,000 | 88,674 / 101,586 |
| USD₮0 `approve` / `approve(0)` | 200,000 | 53,929 / 36,792 |
| `IgnixManager.buyTo` (USD₮0) | 700,000 | 195,364 |
| token transfer to 0xdEaD | 200,000 | 56,893 |
| router buy USD₮0 to token, to 0xdEaD | 700,000 | 181,968 |

`minSettleGas` = 11,814,581 for the Flow Governor (1,888 NAND + 64 LATCH; rehearsal and fork); 12,542,576 for the
2,200-gate test chip. On the fork a settle never needs it all: a curve settle with a buy used 5,077,003 gas, the
first graduated settle (two claims, burn, approve, router buy, reset) 5,130,740, the largest of 20 curve epochs
5,192,864, a settle on the live SealedVM 805,583. Preflight: TapeOut's step used 4,496,309 of its 5,326,400, the
SealedVM 326,054 of its 443,200. A gas sweep around `minSettleGas` on the fork (step 30,000) gave a full settle or a
whole revert at every point, never a different record; the smallest limit that settled was 11,574,581.

**EIP-170** (`forge build --sizes`, runtime bytes; limit 24,576):

| Contract | Runtime | Headroom |
|---|---|---|
| KernelV2 | 20,900 | 3,676 |
| LensV2 | 15,590 | 8,986 |
| KernelFactoryV2 | 6,560 | 18,016 |

(Kernel v1's implementation is 20,413.) The headroom was kept by reusing v1's libraries and dropping the native path.

## 5. Decisions

1. **Native OKB is refused, not routed.** No `receive()`, no fallback, no payable function: a plain OKB transfer
   reverts. OKB forced in by `SELFDESTRUCT` (or a block reward) cannot be refused; no code path reads the kernel's OKB
   balance, so it is never counted, routed or sent and stays there for ever, by choice: an exit would need an
   OKB-to-USD₮0 venue pinned in an immutable contract. Tested by unit, invariant and fork tests (`forced OKB never
   moves`). It is not the only asset without an exit: so is any ERC-20 other than USD₮0 and the bound token sent to
   any kernel, and USD₮0 sent to a kernel that is never bound (section 7; `StatedLimitsV2`).
2. **Revenue is inflow by balance.** Whatever USD₮0 the kernel holds beyond its credits and reserve is fresh inflow:
   the kernel's own claim, a third party's `claimFor` (which works for an ERC-20 quote, unlike v1's native claim),
   and payments to the kernel. `REV`, `REVCUM`, `ESC` stay 0; the `V_*` group is ignored; `K1V`/`K2V` are never set.
3. **Exact approvals.** Each buy approves exactly its amount to the IgnixManager (or, after graduation, the router),
   calls it, then reads the allowance and approves zero unless it reads zero, after a failed buy too. The
   approve's return value is not trusted: what moved is measured by balance. Tested: no allowance is ever left (unit,
   invariant, differential and fork), and a Manager that pulls one unit more than approved gets nothing.
4. **The quote pot after graduation.** Residual USD₮0 tax (claimed every settle), the USD₮0 reserve left at
   graduation and any later USD₮0 are bought on the token/USD₮0 V2 pair (the pair IGNIX graduates into, probe Q11 U6)
   with 0xdEaD as recipient, capped by kernel v1's impact cap with `Q` = the pair's USD₮0 reserve. No allowance after
   graduation, as in v1.
5. **Allowance in USD₮0, to a payee that can move it.** `LaunchChipV2` refuses the KeeperTank as payee: the tank has no
   ERC-20 exit. The KeeperTank still serves v2 kernels for keepers (it only calls `chipId()` and `settle()` and pays
   refunds in OKB from its own balance): fork-tested with `settleAndRefund`.
6. **Credits are paid by balance delta.** `withdrawCredit` reverts unless the transfer succeeded and the kernel's
   balance fell by exactly the credit (tested with a token that lies about its transfers).
7. **One factory pin set per deployment.** The quote must answer `decimals() == 6`; the shift is at most 40. The
   envelope checks are kernel v1's, unchanged. (An extra check that the allowance payee is not the kernel itself
   was written and then removed: the kernel's address commits to the envelope, so it is unreachable.)
8. **Same record layout as v1.** `RecordV2` has v1's 14 fields with `quoteIn` (USD₮0) in place of `nativeIn`, so
   readers of v1 records read v2 records with one name changed. `Settled` is unchanged.

## 6. Verified facts (with the command that checks each)

| Fact | Check |
|---|---|
| A Directed launch quoted in USD₮0 with a v2 kernel as recipient is accepted by the live Manager (signer replaced in the fork); `vault.QUOTE()` is USD₮0; the token's code is every live IGNIX token's | `XLAYER_FORK=1 forge test --match-test test_fork_v2_pins_bind_facts_and_preflight` |
| The Flow Governor (chips/out/fg.hex, keccak `0xe548…43b4`) tapes out through the live Fab as chip 5 for 0.04166 OKB, and live TapeOut and the live SealedVM agree on it | same, and `test_fork_launch_script_end_to_end` |
| 20 epochs of unrelated trading and x402 payments (EIP-3009 `transferWithAuthorization` to the kernel): every input code is the shifted one, no clamp fires, books equal balances, no allowance left, every record replays on both live evaluators | `test_fork_v2_twenty_epochs_traders_and_x402_revenue_on_the_flow_governor` |
| The kernel's curve buy fills at the exact quote on the live Manager, and USD₮0 moves only by the claim and the buy | `test_fork_v2_curve_buy_is_exact_and_leaves_no_allowance` |
| Graduation to the live token/USD₮0 pair (opening reserves 200,000,000 tokens and 7,999.999999 USD₮0), the quote pot bought to 0xdEaD, `burnLocked`, the pot drained, no allowance after graduation | `test_fork_v2_graduation_quote_pot_buy_to_dead_and_burnLocked` |
| A sandwich of the quote leg on the live pair loses money | `test_fork_v2_sandwich_of_the_quote_leg_loses_money` |
| Both evaluators dead: 15 settles revert `StepFailed`, the 16th applies the fallback word, the chip decides again after | `test_fork_v2_fallback_after_the_grace_period` |
| A settle from inside the live Manager's lock (zero-token sell of the native-quoted OB) or a flash swap on the live USD₮0 pair reverts `LockHeld` and keeps the epoch | `test_fork_v2_settle_inside_the_managers_lock_reverts_and_keeps_the_epoch`, `..._flash_swap_on_the_usdt0_pair_reverts` |
| IGNIX's DIVIDEND pause fails the claim only; revenue paid to the kernel still routes | `test_fork_v2_ignix_dividend_pause_fails_the_claim_and_revenue_still_routes` |
| Tether blocking the kernel: claims and payments still arrive, buys and withdrawals fail, settles continue; a blocked holder's `approve` succeeds | `test_fork_v2_tether_block_never_stops_settles_and_the_credit_waits`, `test_fork_v2_usdt0_approve_from_a_blocked_address` |
| The live KeeperTank settles a v2 kernel and refunds its keeper | `test_fork_v2_the_live_keeper_tank_settles_a_v2_kernel_unchanged` |
| The deploy script reads 135.895901 USD₮0/OKB from the pool and accepts shift 33; it refuses 32, an 18-decimal quote, a mismatched router, a wrong code hash, a Fab for another processor, another chain | `ScriptsV2ForkTest` |
| `REHEARSAL=true` switches nothing off on chain 196 (the band check still refuses 32 and 40); it lets a rehearsal through only on another chain id | `test_fork_scripts_chain_guard_and_what_rehearsal_may_switch_off` |
| Chain facts at block 72,530,000: `pinsLive()` of the live v1 factory is true; USD₮0 `decimals()` = 6; IgnixManager `signer()` = `0x6EFa…416A` at slot 5; OB still on its curve; no BUY or DIVIDEND pause | `cast call` against `https://rpc.xlayer.tech -b 72530000` (read only) |

## 7. Open assumptions and limits

- **The facilitator.** Whether OKX's hosted x402 facilitator settles to a contract `payTo` is unknown; only a $0.01
  live test to a throwaway contract settles it (review findings 2, 11). If it refuses, no option routes revenue
  through a chip.
- **IGNIX's signer.** No Directed token quoted in USD₮0 exists on chain, and none with a contract recipient. The fork
  replaces the platform signer; whether IGNIX's signer signs such a launch is unknown (review finding 7).
- **Tether.** One owner address (`0x4DFF…0bf8`) can block the kernel, destroy its USD₮0 and upgrade USD₮0. A
  destroyed balance is lost; the kernel keeps settling on what is left. **Credits come first:** after Tether destroys
  a kernel's USD₮0, later inflow first refills the credits it covered before the chip sees any (the chip reads
  `TAX` = 0 until then, and the allowance payee can be repaid out of that new money). The lifetime bound still holds,
  since destroyed USD₮0 counts as having arrived. A fee added to USD₮0 would stop the kernel's buys (the Manager's
  exact quote no longer fills) without breaking its books.
- **Assets without an exit.** Forced OKB (section 5); any ERC-20 other than USD₮0 and the bound token, sent to any
  kernel; USD₮0 sent to a kernel that is never bound. USD₮0 sent before `bind` is routed by the first settle after a
  successful `bind`; if `bind` never succeeds (the token launched with the wrong quote or recipient, or not at all),
  it stays. Hence the rule of section 9: `PAY_TO` points at a kernel only after its `bind` succeeded.
- **The price band.** If OKB leaves 82.3 to 164.6 USD₮0 before deployment, 33 is no longer the nearest shift and
  `DeployCoreV2` refuses; a kernel already created keeps 33 for ever and its chip reads flows up to 1.4 times off.
- **Calibration after graduation** differs by about 2.5 codes from the curve's (section 3).
- **Forced OKB and USD₮0 dust** (a pot too small to buy one token unit, at most 1,000 base units in the invariant
  drain) stay in the kernel.
- **`tools/launch-check`** has a USD₮0 mode: a launch quoted in USD₮0 passes only against the v2 kernel the deployment
  file names (`tools/launch-check/NOTES.md`, "Kernel v2"), and `payto-check.ts` refuses a `PAY_TO` that is not that
  kernel, bound. The keeper settles v2 kernels unchanged, and `tools/audit-team` flags USD₮0 sent from a team wallet
  to any kernel, by its own transactions or by authorisations others execute.
- **Fork tests in parallel.** One fork test (`..._graduation_quote_pot_buy_to_dead_and_burnLocked`) failed in 3 of 32
  runs only while other forge processes used the same RPC cache at the same time, and passed alone every time. Run
  the fork suite in one process; count a fork failure only if it reproduces in one process (or with
  `--no-storage-caching`).
- Everything else kernel v1's NOTES list (IGNIX's upgrade powers, the lock rule, the sandwich bound over several
  epochs) applies unchanged.

## 8. Tests and results (2026-10-06)

| Suite | Tests | What |
|---|---|---|
| `unit/SettleCurveV2` | 39 | books in USD₮0, revenue, shifted codes, approvals, native OKB, clamps through the shift, buy sizing, guards, locks, Tether |
| `unit/GraduatedV2` | 21 | latch, quote pot, router approvals, swap failures, locks, burn leg, `burnLocked`, sandwich fuzz |
| `unit/FailureMatrixV2` | 11 | 160 + 160 fault combinations per regime (USD₮0's faults included), any word with any fault (fuzz); an unreadable regime balance loses no reserve, on the curve and after graduation |
| `unit/GasV2` | 12 | sweeps across every guard, `minSettleGas` in the costliest settles, through a calling contract; the restated constants are the kernel's |
| `unit/BindFactoryV2` | 15 | pins (every constructor check reached, each through its own call), envelope checks, determinism, bind checks (quote mismatch included); the dynamic-linking canary |
| `unit/CreditsV2` | 9 | balance-delta payouts, lying tokens, fees, failures |
| `unit/EvaluatorV2` | 21 | TapeOut, sealed, fallback, malformed answers; kernel v1's pin, gas, return-bomb and 256-latch tests ported; state bytes masked from either evaluator; a fallback is not a step |
| `unit/StatedLimitsV2` | 4 | the stated limits: revenue after graduation not seen by the chip, assets without an exit, USD₮0 paid before bind, credits first after Tether destroys a balance |
| `unit/LensV2` | 11 | replay (both evaluators, both regimes), counterfactual, shadows, stateMatters, preflight |
| `fuzz/KernelMathV2` | 6 | shift identities; s = 0 is kernel v1; any word, any shift: no revert, every guarantee (1,000 runs; 20,000 in the deep profile) |
| `golden/GoldenV2` | 6 | 1,950 lg8s, 3,072 exp8s, 3,000 + 153 routing vectors; 187 of v1's vectors through v2 with s = 0 |
| `golden/DiffSettlesV2` | 10 | 520 sequences, 35,903 events: **8,808 settles compared bit for bit** (2,752 graduated; 40 sequences run the real Flow Governor on the real SealedVM against its Python model) and 1,335 expected reverts. After the review fixes also on a fresh seed (`V2_SEED=99173`, scratch copy): 35,988 events, 8,940 settles (3,182 graduated) and 1,287 expected reverts, all equal |
| `invariant/InvariantsV2` | 1 | 64 runs x 100 calls, and 256 x 300 = 76,800 calls in the deep profile, 0 handler reverts: books cover credits, value leaves only by clipped routes, one settle per epoch, a funded settle succeeds or the fallback becomes callable, a fallback is no step and carries no flag 2, a settle with the regime balance unreadable keeps the books whole, withdrawals move exactly the credit, no allowance left, forced OKB never moves, every record replays, and a drain at the end shows no balance unreachable and the token reserve leaving at the floor rate |
| `fork/KernelV2Fork`, `fork/ScriptsV2` | 19 + 4 | section 6 |

Counts and gas in the final report of 2026-10-06 come from these commands; rerun them to reproduce.

## 9. The mainnet steps the user would sign (only after the hold on launches is lifted)

Steps 1 and 2 were sent on 2026-10-06 (header above). Steps 3 to 6 have not been taken.

Before any of them: (i) the $0.01 x402 test to a **throwaway** contract `payTo` (never a kernel); (ii) a check,
without signing, that ignix.bot offers and signs a Directed launch quoted in USD₮0 with a contract recipient.

**Never point `PAY_TO` at a kernel before `bind()` has succeeded; USD₮0 sent to an unbound kernel, and any other
ERC-20 sent to any kernel, stays there for ever.** Run the scripts with `REHEARSAL` unset; it only counts off chain
196 anyway (a REHEARSAL left set cannot skip the price-band check of a mainnet deployment).

Steps 1 and 2 are one signing session: `ALLOWANCE_PAYEE=<a wallet that can move USD₮0> deploy/launch-kernel-v2.sh`
rehearses both on a fork from the chain's current state; with `--broadcast` it then sends each step from the nonce
the rehearsal used, signed by keystore `covenant-deployer` (the deployer is also the launcher), checks every created
address on chain and records it in `deployments/xlayer.json` as `coreV2` and `flagshipV2`. It refuses the
KeeperTank (or any contract, or an address USD₮0 has blocked) as payee, any script input left in the shell, and a tree
that is not the pushed commit; after an interruption the same command records what reached the chain and never
resends it. Tested end to end on a fork from a scratch copy, as `deploy/launch-kernel.sh` was.

1. **Deploy** (2 transactions: KernelFactoryV2, LensV2): `DeployCoreV2`, with the processor, Fab and SealedVM of
   `deployments/xlayer.json`.
2. **Tape out and create** (3 transactions: `Fab.tapeoutChip` about 0.0417 OKB, `KernelFactoryV2.create`, the chip NFT
   to the kernel): `LaunchChipV2`, which then runs `LensV2.preflight`.
3. **Prepay keepers** (optional, anyone): `KeeperTank.topUp(chipId)` with OKB.
4. **Launch the token** at ignix.bot from the launcher wallet: Directed, quote USD₮0, recipient = the kernel, first buy
   0, anti-snipe off, after `tools/launch-check/launch-check.ts` and `simulate.ts` pass on the exact transaction.
5. **Bind** (anyone): `kernel.bind(token)`. The deployer sends it with `ARCH_TOKEN=<token> deploy/post-launch.sh
   --broadcast` (signing session 4, `tools/README.md` "Launch day" step 6), which checks bind's preconditions on chain,
   rehearses on a fork and records `architectToken` in `deployments/xlayer.json`.
6. **Point `PAY_TO` at the kernel** in the Architect service, only when **all** of these hold:
   - (a) IGNIX has confirmed **in writing, in the Developer Support topic**, that contract buys funded by third-party
     x402 revenue paid to the kernel are allowed (the 2026-10-05 answer covers buys funded by transaction taxes
     only);
   - (b) OKX.AI agent 14683 has **finished its review** (`docs/design/kernel-v2-live-checks.md`: do not change
     `PAY_TO` on the listed service while it is in review);
   - (c) step 5 succeeded (`kernel.token()` is the token);
   - (d) the Architect running in production includes the settlement-timeout fix of review A-F6 (a transfer to
     `PAY_TO` counts only if an EIP-3009 authorization executed it: a kernel also receives vault claims).
   Until (a) and (b) hold, keep `PAY_TO` on the agent wallet: the kernel then routes token tax only, which is
   approved. `node tools/launch-check/payto-check.ts --deployment deployments/xlayer.json --pay-to <kernel>` checks
   (c) and the rest of the chain side read-only, and prints (a), (b) and (d), which no chain read can show. `PAY_TO` is a seller setting the operator can change; say so publicly. From then on no team wallet may
   pay the kernel, call the paid endpoint or trade the token: self-payment is forbidden.

## 10. Review fixes (two independent reviews, 2026-10-06)

Both reviews found no defect in `src/*.sol` against `chips/INTERFACE.md` revision 2 and `chips/INTERFACE-V2.md`.
Their findings were about the launch procedure, wording, tests, a deploy-script switch and the Architect service.
Each was reproduced first (a failing test, or a mutant of the kernel that the old suite let through) and then fixed.

| Finding | Action | Covered by |
|---|---|---|
| A-F1 (high): revenue-funded buys are outside the organisers' written approval | Gate on `PAY_TO` (sections 1 and 9, step 6): IGNIX's written confirmation in the Developer Support topic, and agent 14683's review finished. Until then `PAY_TO` stays on the agent wallet and the kernel routes token tax only. No code change | procedure; no test can cover it |
| A-F2: after graduation the chip does not see revenue | Wording: KernelV2 header, section 1, INTERFACE-V2 sections 1, 9.3 and 13, README | `StatedLimitsV2.test_after_graduation_revenue_is_not_seen_by_the_chip_and_a_fixed_rule_buys_and_burns_it` |
| A-F3, B-F6: forced OKB is not the only asset without an exit | Wording (sections 5, 7, 9; INTERFACE-V2 9.4) and the rule "`PAY_TO` only after `bind` succeeded" | `StatedLimitsV2.test_usdt0_sent_before_bind_and_foreign_tokens_have_no_exit`, `..._is_routed_once_bound` |
| A-F4, B-F7: credits come first after Tether destroys a balance | Wording (section 7, INTERFACE-V2 13) | `StatedLimitsV2.test_after_tether_destroys_the_balance_later_inflow_refills_the_credits_first` |
| A-F5: `REHEARSAL=true` switched the price-band check off on chain 196 | `rehearsalAllowed()` = REHEARSAL and chain id not 196, in both scripts | `test_fork_scripts_chain_guard_and_what_rehearsal_may_switch_off` (failed on the old script: shift 32 deployed on chain 196) |
| A-F6: the Architect's timeout check accepted any USD₮0 transfer to `PAY_TO` | `services/architect/src/paywall.ts`: only a transfer an EIP-3009 authorization executed (AuthorizationUsed by its sender; this payment's payer and nonce when known). Deployed on Railway with commit `8678740` on 2026-10-06 | `services/architect/test/live.test.ts`, two new tests (the first failed on the old code) |
| A-F7: graduated records share the buy flags between two legs | How to tell them apart, INTERFACE-V2 section 10 | wording |
| B-F1 (medium): the factory constructor test checked only its first line | Every check through an external call (17 counted), shift 40 and 0 accepted, a canary test, `dynamic_test_linking = false` | `BindFactoryV2.test_constructor_rejects_bad_pins` (kills M15 decimals, M16 shift bound), `test_canary_an_expected_revert_of_new_does_not_end_the_test` (failed with dynamic linking on) |
| B-F2 (medium): the unreadable-USD₮0 branch was untested | Two unit tests; the handler checks every settle with the regime balance unreadable and has an action that makes one | `FailureMatrixV2.test_unreadable_usdt0_balance_on_the_curve_loses_no_reserve`, `..._token_balance_after_graduation_...`, `HandlerV2.settleUnreadable` (all kill M6) |
| B-F3: kernel v1's evaluator tests not ported | 12 tests ported or added, the state mask included | `EvaluatorV2` (kills M19 code hash, M20 gate count, M20b nIn, M22 state mask, M35, M36) |
| B-F4: the founder-round test did not check its name | `expectCall` count 0 for `buyTo` and `approve` | `SettleCurveV2.test_buy_skipped_during_founder_round_without_calling_the_manager` (kills M25) |
| B-F5: invariants only partly ported | Drain step 4 (floor rate in the token regime), fallback checks, withdrawal balance deltas | `InvariantsV2` (kills M33 no K5, M35 flag 2 on fallback, M36 fallback persisted, M6) |
| B-F8: thin gas margin on the buy; fork measurements against literals | `G_BUY` 600,000 to 700,000 (3.58 times the measured `buyTo`; `minSettleGas` unchanged); fork measurements read the kernel's constants (`test/utils/GasPinsV2.sol`) | `GasV2.test_restated_constants_are_the_kernels`, `test_fork_v2_measure_live_call_gas`, `..._router_buy_gas` (M4, M18 now also fail a second test) |
| B-F9: two different "kernel v2"s | Naming note at the top of INTERFACE-V2, in this file and the README | wording |
| B-F10: one fork test failed under concurrent forge processes | Not a code defect; not reproduced in one process (passed in every single-process run). Section 7 says how to run the fork suite | `XLAYER_FORK=1 forge test` in one process |

Mutants (scratch copy, `src` mutated one at a time): before the fixes M6, M15, M16, M19, M20, M20b, M22 and M25
passed the whole suite and M4, M18 failed only the formula test; after them every one of these, and M33, M35, M36,
fails at least one test.

