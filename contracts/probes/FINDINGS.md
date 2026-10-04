# Probe findings: how live IGNIX behaves towards a contract recipient

Ground truth for kernel v1, from fork tests against X Layer mainnet (chain 196).

| | |
|---|---|
| Pinned block | **72,369,000** (2026-10-04 18:20:36 UTC, timestamp 1791138036, hash `0xf92ac85ecc7a5f75189da1b84cfa220d1c75fee4f69a6a40719d891ac6dd15dd`) |
| Result | **112 tests, 0 failed** (`forge test`, 12 suites). Also passes with `--isolate`, `--evm-version prague` and the fallback RPC |
| Method check | Two real mainnet transactions re-executed on a fork give the real token amounts to the wei and the real `gasUsed` to the unit (`Q10_Replay`) |
| IgnixManager | proxy `0x96B51c57e5346D0C0198899243cf851D1E23C309`, implementation `0x126F5088cf077944933F5741fb71A6CC40F2942a` (verified source, vendored) |
| Unverified on OKLink | the launch token, the Directed vault, the Directed vault factory, the launch factory, the registry, both lockers. Their behaviour below is measured, and for the vault also read from bytecode |

How each statement is backed:

- **[test]** a passing fork test proves it; the test name is given.
- **[bytecode]** read from the disassembly in `vendor-cache/` and consistent with the tests.
- **[API]** from the IGNIX read-only API or from reading ignix.bot; not provable on-chain.
- **UNVERIFIED** could not be proven; the reason is given (section 12).

Two fixtures are used throughout:

- **Fork launch**: a complete `createToken` through the live Manager with the platform signer replaced in
  fork storage, recipient = a `RecipientProbe` contract, quote native OKB, tax 3% / 3% (as planned for the reference token),
  `firstBuy = 0`. The token's runtime code hash equals that of live tokens and the vault equals a live vault
  except for its two immutables (`test_Q0_fork_launched_token_and_vault_have_the_same_code_as_live_ones`).
- **Live OB**: a real pre-graduation token with the probe etched over its real (EOA) recipient.

---

## 0. What the kernel must do (summary)

1. **Wrap every `vault.claim` in try/catch.** It reverts `NothingToClaim()` when the balance is zero,
   `Paused()` under the DIVIDEND switch, and `claim(token)` always reverts before graduation. Only claim the
   project token once `pairOf(token) != 0`.
2. **Account by balance delta.** Anyone can push the tax out with `claimFor` at any time, so tax can already
   be in the kernel when `settle()` starts, and the kernel's own `claim` then reverts.
3. **`receive()` must not take the settle lock.** The vault pays native OKB with a call that runs the
   recipient's `receive()` inside `claim`, with `msg.sender == vault` and all remaining gas. A revert there
   reverts the claim (`TransferFailed`); the money stays in the vault.
4. **Use the struct form of `tokens()`** (`IIgnix.sol`). A typed call to the flat 16-value getter does not
   compile without `via_ir`. Use `IgnixRead.tryTokens` where a revert is not acceptable.
5. **Quote with `CurveQuote`, pass the quote as `minOut`, cap with `maxNonGraduatingBuy`.** Both are exact.
   When one wei of token is left the cap is 0 and a 1-wei buy graduates.
6. **Skip the buy while `snipeBpsNow(token) > 0`, while a founder round is open, and after graduation.**
   Each would revert or overpay; check before calling.
7. **The kernel's own curve buy pays `taxBuyBps` back to its own vault.** It returns as inflow next epoch.
8. **After graduation the curve is closed for good** (`Graduated_()`), new tax arrives only in the project
   token, and the vault's native balance is whatever accrued on the curve, including a lump from the
   graduating buy. **Native OKB therefore needs its own route after graduation** (section 6.6): interface v1
   gives it the router buy of section 7.
9. **Burn by transfer to `0x...dEaD`.** It is untaxed, there is no burn function, `totalSupply` does not move.
10. **No fallback function, and no `token0()` / `token1()` / `fee()`.** During the 100-day protection window
    the token staticcalls those on any contract that sends or receives it.
11. **Size gas guards from section 9**, with margin: the Manager is upgradeable.
12. **Launch with `firstBuy = 0`.** A non-zero first buy trades inside `createToken` and puts tax from the
    creator's own money into the vault.
13. **Nobody else moves native tax.** The platform's daily job pushes the project token only. Native OKB
    leaves the vault only through the kernel's claim or a volunteer's `claimFor`.

---

## 1. Live pre-graduation Directed tokens quoted in native OKB

Source: `GET https://api.ignix.bot/v1/launches?limit=200&page=1..39` on 2026-10-04 18:34 UTC, then every
candidate re-read on-chain at the pinned block (`vendor-cache/ignix-directed-launches.json`,
`vendor-cache/directed-native-onchain-72369000.json`).

| | |
|---|---|
| Launches on the platform | 7,695 |
| Directed (templateId 3) | 381 |
| Directed, native OKB quote | **83, all still on the curve** (74 have at least one trade) |
| Directed, graduated | 2, both with an ERC-20 quote; the one checked on-chain has recipient `0x...dEaD` |
| Recipients of the 83 | 46 distinct; none is a burn address; 82 are the creator itself; 11 are EIP-7702-delegated EOAs; **1 is a real contract** |
| Vaults holding unclaimed native tax | 32 of 83, 0.150 OKB in total |
| Furthest native Directed curve | OB, 0.177 OKB raised of 85 (0.2%) |
| Launches with a founder round | 0 of 7,695 |

**Fixture A, "OB" (OpenBook)**: live, pre-graduation, templateId 3, native OKB, 295 trades, recipient is a
normal address.

| | |
|---|---|
| Token | `0x995546dFdf93BEF59C35742aB5f4762fbcB8eEEe` |
| Vault | `0xeC7732C9dCF978C8a97E6c44499331757D240365` |
| Recipient | `0xC12fBf15Df59800f39F2Ebb34c9CBDce150Ae404` (EOA, also the creator) |
| Launch | 2026-09-22 23:25:56 UTC, tx `0x0ebe6f4bfb5bb1eadc2a4fd429eea32cc33ad9a30eead752cb2820aab6d454a1`, tax 1% / 1%, anti-snipe 50% over 30 min, `firstBuy` 0.4 OKB, `listingFee` 0, protection 8,640,000 s |
| At the pinned block | sold 6,632,272.89 tokens, collected 0.177271982484240993 OKB, vault holds 0.004006687747548187 OKB unclaimed |

**Fixture B, "TEST"**: live, pre-graduation, native OKB, 9 trades, recipient is a third-party **contract**.

| | |
|---|---|
| Token | `0xa0aBa560a1c48545e8EB5E9B938af097b007EEee` |
| Vault | `0x27558D2205B3553cAc5875Cef63624E3bE6672e4` (0.016933658097562826 OKB unclaimed) |
| Recipient | `0xb27fAEaB17A97bAAda0C571F3E679aABD952992f`, 9,442 bytes, verified on OKLink as `BurstBurnEngine` |

`BurstBurnEngine` is another project's tax recipient: an owned, pausable buy-and-burn engine whose
`receive()` emits an event, with a factory that creates the recipient before the token is launched. Its
balance and its `ignitionCount` are 0 at the pinned block: it has not received a claim yet. It is relevant
to `docs/PRIOR_ART.md`.

Tests: `test_Q1_OB_is_live_pregraduation_directed_native_with_trades`,
`test_Q1_second_fixture_recipient_is_a_live_contract`,
`test_Q1_no_native_directed_token_has_graduated_reference_is_erc20_quote`.

**Kernel:** no native-OKB Directed token has ever graduated, so everything after graduation can only be
shown on a fork (sections 6 and 7).

---

## 2. Claiming to a contract

### 2.1 Answers

| Question | Answer | Test |
|---|---|---|
| Does tax accrue in the vault? | Yes, in native OKB, inside the trade. Buy: `floor(gross * taxBuyBps / 1e4)`. 1 OKB at 3% puts exactly 0.03 OKB in the vault. Sells are taxed the same way on the gross proceeds | `test_Q2_tax_accrues_in_vault_as_native_on_curve_buy` |
| `vault.sync()` | Permissionless and a no-op for this template | `test_Q2_sync_then_claim_delivers_native_to_contract`, `test_Q8_sync_is_a_noop_for_the_directed_vault` |
| `claim(address(0))` from the recipient contract | Works. Pays the vault's whole native balance | `test_Q2_sync_then_claim_delivers_native_to_contract`, `test_Q2_claim_without_sync_works` |
| How much gas reaches the recipient? | **All of it (63/64 of what is left).** The vault uses a plain `call{value}` with no gas argument and no 2,300 stipend limit | `test_Q2_gas_forwarded_to_recipient_is_63_64ths` |
| Non-trivial `receive()` | Works. Tested with 4 storage writes and an event (about 90,600 gas of receiver work) | `test_Q2_nontrivial_receive_works` |
| `receive()` reverts | The claim reverts `TransferFailed()` `0x90b8ec18`, for `claim` and `claimFor` alike. Nothing is lost: the balance stays in the vault and the next claim pays it | `test_Q2_reverting_receive_makes_claim_revert_TransferFailed` |
| `receive()` runs out of gas | Same: `TransferFailed()`, nothing moves | `test_Q2_out_of_gas_in_receive_reverts_the_whole_claim` |
| Third party calls `claimFor(recipient, address(0))` | Pushes the whole balance to the recipient contract; the caller gets nothing | `test_Q2_claimFor_by_third_party_pushes_to_recipient` |
| `claimFor(other, ...)`, or `claim` by a non-recipient | `Unauthorized()` `0x82b42900` | `test_Q2_claimFor_cannot_redirect_and_claim_is_recipient_only` |
| `claimableNow` versus the real delta | **Equal.** return value = `claimableNow` = balance delta, for native and for the token | `test_Q2_sync_then_claim_delivers_native_to_contract`, `test_Q6_claim_token_delivers_project_tokens_to_the_contract_recipient` |
| Nothing to claim | `NothingToClaim()` `0x969bf728` (a revert, not a zero return) | `test_Q2_claim_reverts_NothingToClaim_when_vault_is_empty` |
| `claim(token)` before graduation | `NothingToClaim()`; `claimableNow(recipient, token)` is 0 while `token.pair() == 0` | `test_Q2_claim_of_project_token_before_graduation_reverts_NothingToClaim` |
| Any other asset (for example WOKB) | `UnknownAsset()` `0xc97d95cf`, also from `claimableNow` | `test_Q2_unknown_asset_reverts` |
| Is there a ledger? | No. Claimable is the vault's balance. A plain transfer of OKB to the vault is accepted and becomes claimable | `test_Q2_vault_has_no_ledger_donations_are_claimable` |
| Re-entering `claim` from `receive()` | Inner call reverts `ReentrancyGuardReentrantCall()` `0x3ee5aeb5`; the outer claim still pays once | `test_Q2_reentrant_claim_from_receive_is_blocked` |
| `receive()` that accepts only the vault and the Manager | Works; `msg.sender` in `receive()` is the vault | `test_Q2_receive_that_only_accepts_vault_and_manager_works` |
| Event | `Claimed(address indexed recipient, address indexed asset, uint256 amount)`, topic0 `0xf7a40077ff7a04c7e61f6f26fb13774259ddf1b6bce9ecf26a8276cdd3992683` | `test_Q2_claim_emits_Claimed_event` |
| Live OB vault, probe etched at its recipient | Claim delivers the 0.004006687747548187 OKB already there plus new tax | `test_Q2_live_OB_vault_claim_to_etched_contract_recipient` |
| Live third-party contract recipient, nothing etched | `claimFor` delivers 0.016933658097562826 OKB to `BurstBurnEngine` | `test_Q2_live_third_party_contract_recipient_receives_claimFor` |

### 2.2 Gas forwarded to `receive()`

Gas limit given to `claimFor`, and gas left at the first line of `receive()`:

| `claimFor` gas limit | gas at `receive()` entry |
|---|---|
| 150,000 | 122,201 |
| 300,000 | 269,858 |
| 1,000,000 | 958,920 |
| 5,000,000 | 4,896,420 |
| 30,000,000 | 29,505,795 |

About 25,900 gas is spent before the call; 63/64 of the rest is forwarded.

### 2.3 Gas used by claim

See section 9. In short: 30,225 gas for `claim(native)` as seen by the calling contract (with a receiver
that does almost nothing), 51,629 for a whole `claimFor` transaction from an EOA, 19,131 when it reverts
`NothingToClaim`.

### 2.4 What the kernel must do

- `try vault.claim(asset) {} catch {}` and then measure `balance - accounted`. Never use the return value
  as the only record: a `claimFor` by anyone moves the money without the kernel's `claim` succeeding.
- `receive()` runs during the kernel's own `settle()`. It must not be guarded by the same reentrancy lock,
  and it must accept `msg.sender == vault`.
- Keep `receive()` cheap. The work it does is paid by whoever calls `claimFor`, and a stranger who supplies
  too little gas only makes his own call revert.
- Do not call `sync()`. It does nothing.
- Do not call `claim(token)` before graduation: it always reverts and costs 22,377 gas.

---

## 3. `buyTo` from a contract

| Question | Answer | Test |
|---|---|---|
| Does `manager.buyTo{value: amt}(token, amt, minOut, address(this))` work from a contract? | Yes. 0.5 OKB on a fresh 3% curve delivered 17,769,551.133734382230654437 tokens, exactly the on-chain quote, to the calling contract | `test_Q3_buyTo_from_contract_delivers_exact_quoted_tokens_to_itself` |
| `Trade` event | `trader` (topic 2) is the **recipient** | same |
| Can the contract move the tokens before graduation? | **No.** Every transfer that does not have the Manager on one side reverts `CurveOnly()` `0x9dabc49b`: to `0x...dEaD`, to an EOA, to its own vault, to itself, to the future pair, a zero-value transfer, and `transferFrom` by an approved spender. `approve` works | `test_Q3_tokens_cannot_move_before_graduation_CurveOnly` |
| Back to the Manager? | Two ways, both need the contract to act. (a) A plain `transfer(manager, x)` succeeds: the tokens are gifted to the Manager and the curve does not account for them. (b) `approve(manager)` + `manager.sell` works from a contract and pays native OKB | `test_Q3_the_only_exits_before_graduation_are_the_manager` |
| Who is `taxExempt`? | Manager, the vault, the V2 LP locker, the liquidity helper: **true**. The vault's recipient (the kernel), `0x...dEaD`, the router, the creator: **false** | `test_Q3_tax_exempt_flags` |
| Does a buy by the vault's own recipient pay tax? | **Yes.** The curve charges `taxBuyBps` on every buy. A 1 OKB kernel buy at 3% puts 0.03 OKB into its own vault, claimable at once | `test_Q3_buy_by_the_vaults_own_recipient_pays_tax_back_to_its_vault` |
| Bad arguments | recipient zero, recipient = Manager, recipient = the future V2 pair, `msg.value != amountIn`: `BadValue()` `0x0bba69fb`. `minOut` one wei above the quote: `Slippage()` `0x7dd37f70`. `amountIn = 0`: `SoldOut()` `0x52df9fe5`. Unknown token: `NotFound()` `0xc5723b51` | `test_Q3_buyTo_rejects_bad_recipients_and_bad_value` |
| Other recipients | `buyTo(..., 0x...dEaD)` works on the curve (the Manager is the sender). Anyone can `buyTo(..., kernel)` and so push locked tokens into the kernel | `test_Q3_buyTo_recipient_can_be_dead_or_anyone_and_third_parties_can_gift` |
| Creator rebate on curve trades | None. `creatorAccrued` stays 0 | `test_Q0_no_creator_rebate_accrues_on_curve_trades` |

**What the kernel must do**

- The tokens are locked only because the kernel has no `approve`, `sell` or `transfer` path on the curve.
  Keep it that way: no generic call, no approval of the Manager.
- Count locked tokens from the balance delta around the kernel's own `buyTo`. The raw balance can be
  inflated by anyone.
- Subtract `buy * taxBuyBps / 1e4` from the next epoch's inflow if the chip must not see the kernel's own
  tax as outside inflow (the design already does this).
- "Net of any creator rebate" in the buy cap is zero today.

---

## 4. On-chain quote: `src/CurveQuote.sol`

`CurveQuote.quoteBuy(curve, snipeBps, quoteIn)` reads six fields of `tokens(token)` plus `snipeBpsNow(token)`
and mirrors `CurveTrading.buy`:

    feeBps = buyFeeBps + taxBuyBps + snipeBps
    net    = quoteIn - floor(quoteIn * feeBps / 10000)
    left   = sellable - sold
    out    = vToken - ceilDiv(vQuote * vToken, vQuote + net)
    if out >= left:                                   # the buy reaches the end of the curve
        out = left
        net = ceilDiv(vQuote * left, vToken - left)
        grossNeeded = ceilDiv(net * 10000, 10000 - feeBps)
        if grossNeeded < quoteIn: refund = quoteIn - grossNeeded; quoteIn = grossNeeded
    tax         = floor(quoteIn * taxBuyBps / 10000)  # to the vault
    platformFee = quoteIn - net - tax                 # curve fee + all anti-snipe + dust
    soldOut     = (sold + out == sellable)            # graduation runs in the same transaction

**It is exact.** Every assertion below is strict equality against the live Manager:

| Proven | Runs | Test |
|---|---|---|
| tokens out, tax to vault, platform fee, refund, new `vQuote` / `vToken` / `sold`, and graduated-or-not, on live OB state, 1 wei to 200 OKB (about half the cases cross the curve) | 64 | `testFuzz_Q4_quote_is_exact_on_live_OB_including_crossing_buys` |
| same on a fresh curve, amounts from 1 wei to 900 OKB on a log scale, `buy` and `buyTo` | 64 | `testFuzz_Q4_quote_is_exact_on_log_scale_amounts` |
| contract buyer via `buyTo` after a random prior trade | 48 | `testFuzz_Q4_quote_is_exact_for_contract_buyTo_after_a_random_prior_trade` |
| inside the anti-snipe window at a random time | 48 | `testFuzz_Q4_quote_is_exact_inside_the_anti_snipe_window` |
| pure properties for any reachable state: never reverts, `spent + refund = in`, `net + tax + fee = spent`, the max helper is exact | 2,000 | `testFuzz_Q4_pure_quote_never_reverts_and_conserves` |
| initial curve: `vQuote` = 28.333333333333333333 OKB, `vToken` = 1,066,666,666.666... tokens, 800M sellable | 1 | `test_Q4_fresh_curve_matches_CurveMath_params` |
| a real mainnet buy: the quote equals the real `Trade` event | 1 | `test_Q10_fork_reproduces_a_real_mainnet_buy_tokens_and_gas` |

**The buy that crosses the remaining supply**

| Question | Answer | Test |
|---|---|---|
| What happens? | It is **capped** at the remaining supply and the excess is **refunded**. On a fresh 3% curve the whole curve costs 88.541666666666666667 OKB gross; sending 10 OKB more returns exactly 10 OKB | `test_Q4_crossing_buy_is_capped_refunded_and_graduates_in_the_same_tx` |
| Graduation in the same transaction? | **Yes.** `pairOf` is set, the token is unlocked and `GraduatedV2` is emitted inside the buy. That buy cost 3,055,785 gas | same |
| Who gets the refund through `buyTo`? | **The recipient, not the payer**, by a native call from the Manager (`msg.sender == manager` in `receive()`) | `test_Q4_crossing_buyTo_refund_goes_to_recipient_not_to_payer` |
| Recipient refuses the refund | The whole buy reverts `TransferFailed()` `0x90b8ec18`. With the exact cost there is no refund and the buy graduates | `test_Q4_crossing_buyTo_reverts_if_recipient_refuses_the_refund` |

**Largest buy that does not graduate:** `CurveQuote.maxNonGraduatingBuy(curve, snipeBps)`

    left   = sellable - sold;  R = vToken - left
    netMax = ceilDiv(vQuote * vToken, R) - 1 - vQuote
    maxIn  = floor(netMax * 10000 / (10000 - feeBps))      # 0 when left == 0

| Proven | Test |
|---|---|
| Fresh 3% curve: max = 88.541666666666666665 OKB, leaves 1 wei of token; max + 1 wei graduates | `test_Q4_maxNonGraduatingBuy_is_exact_on_fresh_curve` |
| Live OB: max = 86.553804099505876758 OKB (cost to graduate 86.553804099505876760) | `test_Q4_maxNonGraduatingBuy_is_exact_on_live_OB` |
| After random trades, with 90% anti-snipe at random times | `testFuzz_Q4_maxNonGraduatingBuy_is_exact_after_random_trades` |
| One wei of token left: the helper returns 0, and a buy of **1 wei of OKB graduates the token** | `test_Q4_with_one_wei_left_the_helper_returns_zero_and_a_one_wei_buy_graduates` |

Also provided: `CurveQuote.costToGraduate`, and `V2TaxQuote.buyOut` for the Uniswap leg (section 7).

**What the kernel must do**

- `amount = min(wanted, maxNonGraduatingBuy)`; skip if `tokensOut(amount) == 0`; pass `tokensOut` as
  `minOut`. Computed in the same transaction it cannot fail on slippage.
- The helper is pure and cannot revert for any state the Manager can be in, so it needs no try/catch.
- Rejecting the Manager in `receive()` is not a substitute for the cap: a crossing buy with zero refund
  still graduates.

---

## 5. Decoding `tokens(token)`: `src/interfaces/IIgnix.sol`

`tokens(address)` (selector `0xe4860339`) returns **exactly 16 static words, 512 bytes**
(`test_Q5_tokens_returns_exactly_16_words_512_bytes`). The design doc's list is correct:

| Word | Field | Type | Live OB value at the pinned block |
|---|---|---|---|
| 0 | creator | address | `0xC12f...e404` |
| 1 | buyFeeBps | uint16 | 100 |
| 2 | sellFeeBps | uint16 | 100 |
| 3 | taxBuyBps | uint16 | 100 |
| 4 | taxSellBps | uint16 | 100 |
| 5 | quote | address | 0 (native OKB) |
| 6 | snipeStartBps | uint16 | 5000 |
| 7 | snipeMins | uint16 | 30 |
| 8 | createdAt | uint64 | 1790119556 |
| 9 | vQuote | uint128 | 28.510605315817574326 OKB (= E + collected) |
| 10 | vToken | uint128 | 1,060,034,393.778... tokens (= T - sold) |
| 11 | sold | uint128 | 6,632,272.887764698979702275 tokens |
| 12 | collected | uint128 | 0.177271982484240993 OKB |
| 13 | sellable | uint128 | 800,000,000 tokens |
| 14 | reserve | uint128 | 200,000,000 tokens |
| 15 | poolId | bytes32 | 0 |

Storage: 6 packed slots at `keccak256(abi.encode(token, 8))`, in the same order
(`test_Q5_storage_layout_of_tokens_mapping`).

**There is no graduation flag and no graduation target in the struct.** Graduated means
`pairOf(token) != 0` (every taxed token graduates to V2); `poolId` stays zero. After graduation
`sold == sellable` (`test_Q5_graduated_V2_token_reads`).

**Compiler trap.** An interface that declares `tokens()` with 16 separate return values is ABI-correct but
a call to it does not compile with solc 0.8.28 without `via_ir` ("Stack too deep ... Variable headStart is
2 slot(s) too deep"). `IIgnix.sol` therefore declares `tokens(address) returns (CurveToken memory)`, which
has the identical encoding and compiles (`test_Q5_typed_struct_and_reader_agree_with_raw_words`).

Other views, with live values:

| View | Selector | Notes | Test |
|---|---|---|---|
| `pairOf(token)` | `0xa7465bdb` | the graduated flag for V2. Mapping slot 15 | `test_Q5_vaultOf_pairOf_snipeBpsNow_pausedUntil_founderRound_live` |
| `vaultOf(token)` | `0x0709df45` | mapping slot 12 | same |
| `snipeBpsNow(token)` | `0xf91a40b4` | 0 when disabled or over | same, and section 8 |
| `pausedUntil(kind)` | `0x54bce65b` | all nine kinds are 0 at the pinned block. Mapping slot 21 | same |
| `founderRound(token)` | `0x47965b55` | `(root, endsAt, capTotal, spentTotal)`. **The founder-round flag is `endsAt`**: public buys revert `FounderOnly()` `0x2c353d89` while `block.timestamp < endsAt`. Mapping slot 10 | `test_Q5_founder_round_flag_and_FounderOnly` |
| `creatorOf(token)` | `0xdea5c2e0` | zero for a token the Manager did not launch | `test_Q5_unknown_token_reads_as_all_zero` |
| `signer()` | | storage slot 5 | `test_Q0_signer_lives_in_slot_5_and_the_override_is_fork_only` |

Every selector the kernel calls is asserted in `test_Q5_selectors_of_everything_the_kernel_calls`, and
every token view answers on the live token in `test_Q5_token_views_answer_on_the_live_token`.

`src/IgnixRead.sol` gives non-reverting readers. `tryTokens` accepts 512 bytes or more and returns
`ok = false` for a shorter answer, a revert or an address with no code; the typed interface call reverts in
those cases (`test_Q5_reader_tolerates_longer_returndata_and_rejects_shorter`).

**What the kernel must do**

- Copy `IIgnix.sol`. Read `tokens()` through the struct form or `IgnixRead.tryTokens`.
- Graduated = `pairOf(token) != address(0)`.
- Treat `founderRound(token).endsAt > block.timestamp` like an open anti-snipe window: skip the buy.

---

## 6. Forced graduation

Setup: fork launch (3% / 3%), the probe buys 1 OKB on the curve, another user buys 2 OKB, nobody claims,
then a whale buys the rest of the curve (85.541666666666666667 OKB gross).

### 6.1 The graduation

`test_Q6_whale_buyout_graduates_to_the_official_uniswap_v2_pair`

| | |
|---|---|
| Manager config (verified on-chain) | `V2_ROUTER02` = `0x182a927119D56008d921126764bF884221b10f59`, `WRAPPED_NATIVE` = `0xe538905cf8410324e03A5A23C1c177a474D59b2b`, `router.WETH()` = WOKB, `router.factory()` = `V2_FACTORY` = `0xDf38F24fE153761634Be942F9d859f3DBA857E95` |
| `pairOf(token)` | set; equals `factory.getPair(token, WOKB)` and the CREATE2 address from init code hash `0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f`, so it is predictable before graduation |
| Opening reserves | 200,000,000 tokens and 85 OKB of WOKB (= `collected`). On live OB the same test gave 85.000000000000000217 OKB |
| Token | `unlocked()` true, `pair()` set, `pools(pair)` true, `protectionActive()` true, `protectionEndsAt()` = graduation time + 8,640,000 s |
| LP | all but Uniswap's 1,000 minimum-liquidity units are in the V2 locker |
| Manager | holds no token any more; `sold == sellable`; `poolId == 0` |

### 6.2 The curve is closed

`manager.buy`, `manager.buyTo` and `manager.sell` revert **`Graduated_()` `0x735c0da7`**
(`test_Q6_curve_buy_buyTo_and_sell_revert_Graduated_`). A failed `buyTo` costs the caller 39,447 gas and
the `msg.value` comes back with the revert.

### 6.3 V2 trades and the token tax (also answers Q-A)

| Question | Answer | Test |
|---|---|---|
| Where does tax go on a V2 trade? | **Straight into the vault, in the project token, inside the same transfer.** `taxSink() == vault`. The token contract holds nothing in between. A buy loses `floor(gross * taxBuyBps / 1e4)`, a sell `floor(amount * taxSellBps / 1e4)` | `test_Q6_QA_v2_trades_put_project_token_tax_straight_into_the_vault` |
| Does the vault's native balance change after graduation? | No. New tax is token-only | same |
| `claim(token)` by the contract recipient | Works. return = `claimableNow` = balance delta = the vault's token balance (1,055,238.235179530961133837 tokens in the test). No tax is taken on the way: the vault is exempt | `test_Q6_claim_token_delivers_project_tokens_to_the_contract_recipient` |
| `claimFor(recipient, token)` by a third party | Works the same. It is a plain ERC-20 transfer: **no callback into the recipient** | `test_Q6_claimFor_token_by_a_third_party_pushes_to_the_recipient` |
| Is there an on-chain threshold? | **No.** A balance of 1 wei is claimable by the recipient; only zero reverts | `test_Q6_QA_there_is_no_onchain_threshold_one_wei_is_claimable` |
| `sync()` | Moves nothing | `test_Q6_QA_sync_moves_nothing` |
| The platform's daily push | Selector `0x67318ec1(uint256 minAmount)` on the vault, callable **only** by the address returned by `factory.0x2761dbab()` = `0xcc8D1916A96319A0Cdcde1897DAB61d34322FeFe` (an EOA). It pushes the whole token balance to the recipient if it is at least `minAmount`, otherwise returns 0. **The threshold is a calldata argument chosen by the off-chain job.** It cannot redirect and it does not convert | `test_Q6_QA_platform_push_is_operator_only_and_its_threshold_is_calldata` |
| A real push on mainnet | tx `0x4c1b8ddd4af56229dcb5b128e99dc9f34506a747d92cb95bd243090276a1eb34`, block 72,303,399, 2026-10-04 00:07:15 UTC, from that operator to the live graduated Directed vault, `minAmount` = 113.788698483739788718 tokens, pushed 86,793.012027758266434075 tokens, 66,828 gas. Re-executed on a fork: same amount, same gas | `test_Q10_fork_reproduces_the_real_platform_push_with_its_calldata_threshold` |
| Residual native tax | Still claimable. In the test 2.65625 OKB: the 0.09 OKB accrued earlier plus 3% of the whale's own graduating buy, paid into the vault inside the graduating transaction | `test_Q6_residual_native_tax_is_still_claimable_after_graduation` |
| Live graduated Directed vault (`0xa6A54EE383A75DA9A2f6e6a060A4c023C8DE8d64`, untouched) | `claimableNow` equals the balance for both assets (58,985.399581383102476555 tokens and 0.408163265306122444 of the quote), and `claimFor` delivers exactly that | `test_Q6_live_graduated_directed_vault_claimableNow_equals_balance_and_claimFor_delivers` |

A scan of the 100,000 blocks (27.8 hours) before the pinned block found exactly one event on that vault,
the push above, and none on the OB and TEST vaults (`vendor-cache/vault-logs-scan.json`). The push function
handles the project token only [bytecode], and the graduated vault still holds its quote-side balance: the
platform does not push the quote side.

### 6.4 Tokens bought before graduation (also answers Q-B)

| Question | Answer | Test |
|---|---|---|
| Can they be transferred now? | Yes | `test_Q6_QB_tokens_bought_on_the_curve_can_go_to_dead_untaxed_during_and_after_protection` |
| Is a transfer to `0x...dEaD` taxed or blocked? | **Neither.** The full amount arrives, the vault gets nothing, during the protection window and after it | same |
| `totalSupply` afterwards | Unchanged: 1,000,000,000 tokens | same |
| Burn function | **None.** `burn(uint256)` and `burnFrom` do not exist (empty revert). `transfer(address(0), x)` reverts `ERC20InvalidReceiver(address(0))` `0xec442f05` | `test_Q6_there_is_no_burn_function_and_zero_address_is_refused` |
| Other transfers | Contract to EOA and back: untaxed. A transfer **to the pair** is a sell: 3% goes to the vault | `test_Q6_wallet_transfers_are_untaxed_but_a_transfer_to_the_pair_is_taxed_as_a_sell` |

### 6.5 The same on live state

`test_Q6_live_OB_full_lifecycle_with_contract_recipient` runs the whole sequence on the real OB token with
the probe etched at its recipient: exact quote, `CurveOnly` lock, whale buyout for 85.553804099505876760
OKB, `Graduated_` on `buyTo`, V2 buy taxed 1%, `claim(token)` = `claimableNow`, 0.869544728742606954 OKB of
residual native tax pushed by a third party, untaxed transfer to `0x...dEaD`.

### 6.6 What the kernel must do

- Latch `graduated` from `pairOf(token) != 0`, then stop calling `buyTo` and start claiming the token.
- Keep claiming native OKB after graduation: the residual is there, and the graduating buy adds
  `taxBuyBps` of up to the whole remaining curve in one go (2.65625 OKB in total for a 3% token that
  graduates without sells).
- **Native OKB needs a route after graduation.** The curve buy reverts forever, so native OKB in the
  kernel (the residual tax, the graduation lump and any undrained reserve) cannot use it. Interface v1
  (`chips/INTERFACE.md` section 9) routes it through the router call of section 7 (one call, measured, no
  refund path). Without that leg "no balance is unreachable" would not hold for a token that graduates.
- Token pushes have no hook. Token tax can appear in the kernel at any time through `claimFor` or the
  platform's push, so token inflow is `balance - accounted` as well.
- Dashboards: circulating supply is `totalSupply - balanceOf(0x...dEaD)`; `totalSupply` never falls.

---

## 7. Post-graduation buy-and-burn through Uniswap V2 (also answers Q-C)

Call, from a contract holding native OKB:

    router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amountIn}(minOut, [WOKB, token], to, deadline)

| Question | Answer | Test |
|---|---|---|
| Works with `to = 0x...dEaD` during the protection window? | Yes. 0.5 OKB gave 1,131,119.259402211734708797 tokens to `0x...dEaD` and 34,983.069878418919630168 tokens of tax to the vault | `test_Q7_QC_router_buy_to_dead_works_during_protection_with_exact_minOut` |
| Works with `to = the contract`? | Yes | `test_Q7_router_buy_to_self_works_during_protection` |
| After the window? | Yes, both, taxed identically. The official pair stays taxed forever | `test_Q7_router_buys_work_and_are_taxed_the_same_after_protection` |
| How much tax, how much LP fee? | LP fee 0.3% (standard 997/1000). The pair pays `gross`; the token diverts `floor(gross * taxBuyBps / 1e4)` to the vault; the recipient gets the rest | `_swapAndCheck` in every test above |
| Can `minOut` be computed on-chain? | **Yes, exactly**, from `pair.getReserves()` and `taxBuyBps`: `V2TaxQuote.buyOut`. Passing the result as `minOut` succeeds; one wei more reverts `UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT`. Fuzzed over 1e9 wei to 200 OKB, both recipients, during and after protection | `testFuzz_Q7_v2_quote_from_reserves_and_taxBuyBps_is_exact` (64 runs), `test_Q7_minOut_one_wei_above_the_onchain_quote_reverts` |
| Does native OKB come back to the caller? | **No.** Exactly `amountIn` leaves and nothing returns. A caller whose `receive()` reverts for everyone, or accepts only the vault and the Manager, still completes the swap | `test_Q7_QC_no_native_ever_returns_to_the_caller_receive_may_refuse_the_router` |
| Which router function? | The `SupportingFeeOnTransferTokens` exact-in variant. Plain `swapExactETHForTokens` also succeeds but checks `minOut` against the amount **before** tax, so it cannot protect the buy. `swapETHForExactTokens` refunds dust to `msg.sender` and fails with `TransferHelper: ETH_TRANSFER_FAILED` if `receive()` refuses the router | `test_Q7_QC_plain_swapExactETHForTokens_succeeds_but_checks_minOut_before_tax`, `test_Q7_QC_exact_out_variant_refunds_native_and_needs_receive` |
| Direct `pair.swap` to `0x...dEaD` (no router) | Works: wrap, send WOKB to the pair, `pair.swap(gross, to)`. Same tax. One wei above the formula fails `UniswapV2: K` | `test_Q7_direct_pair_swap_to_dead_works_and_is_taxed_the_same` |
| Under `pauseAll()` | The router buy and plain transfers still work; they do not read the Manager's switches | `test_Q8_pauseAll_after_graduation_freezes_claims_but_not_v2_buys_or_transfers` |

`V2TaxQuote.buyOut(amountIn, reserveWOKB, reserveToken, taxBuyBps)`:

    gross = amountIn * 997 * reserveToken / (reserveWOKB * 1000 + amountIn * 997)
    tax   = floor(gross * taxBuyBps / 10000)
    net   = gross - tax          # what `to` receives; use as minOut

**What the protection window is.** `protectionEndsAt()` = graduation time + `protectionDuration()`
(8,640,000 s = 100 days on live launches; one live token used the 1-day minimum).

| Measured | Test |
|---|---|
| While it is open the token staticcalls `token0()` on a **contract** sender or receiver (then `token1()`, `fee()` and the official V2 / V3 factories, 10,000 gas each [bytecode]). An EOA such as `0x...dEaD` is not probed. After the window nothing is probed | `test_Q7_token_probes_a_contract_receiver_with_token0_during_protection`, `test_Q7_token_probes_a_contract_sender_with_token0_during_protection`, `test_Q7_token_does_not_probe_anyone_after_protection` |
| A **genuine** second Uniswap pool of the token is registered in `pools()` on first transfer and taxed like the official pair. A contract that only exposes `token0` / `token1` is not. After the window the second pool is untaxed | `test_Q7_protection_window_only_extends_the_tax_to_other_genuine_pools` |
| It does not restrict router buys, router sells or plain transfers by a contract | `test_Q7_protection_window_does_not_restrict_router_trades_or_plain_transfers` |

Gas: section 9. Worst case 210,269 for a router buy to `0x...dEaD`.

**What the kernel must do**

- Use `swapExactETHForTokensSupportingFeeOnTransferTokens` with `minOut = V2TaxQuote.buyOut(...).net`
  computed in the same transaction, in try/catch.
- `receive()` does not need to accept the router or WOKB.
- The kernel must not answer `token0()`, `token1()` or `fee()` and must have no fallback.
- The reserves can be moved by anyone in the same block; `minOut` from live reserves only guarantees the
  formula, not a fair price. The design's reference-price guard is still needed for that.

---

## 8. Timing and griefing

| Question | Answer | Test |
|---|---|---|
| Can anyone call `claimFor` for our recipient at any time? | **Yes.** No access control beyond `recipient == RECIPIENT`, no cooldown, several times per block. Effect: the tax arrives in the kernel outside `settle()`, and the kernel's own `claim` in the same block **reverts** `NothingToClaim()`. Nothing is lost | `test_Q8_anyone_can_claimFor_at_any_time_and_it_front_runs_the_recipients_own_claim` |
| Can that be prevented? | For native OKB, yes if wanted: a `receive()` that accepts the vault only while the kernel is inside its own claim makes a stranger's `claimFor` revert `TransferFailed()` and the tax waits in the vault. Token pushes cannot be gated | `test_Q8_receive_gated_to_own_claim_makes_third_party_native_pushes_revert` |
| What does `sync()` do? | Nothing for this template: it reads the quote balance, writes only the reentrancy guard slot (back to 1), emits nothing, moves nothing. **Not needed before claim** | `test_Q8_sync_is_a_noop_for_the_directed_vault` |
| Claim when the **buy** pause is set (`pausedUntil[1]`) | **Claim still works.** Buys revert `Paused()` `0x9e87fac8` (`buy` and `buyTo`; `msg.value` returns). Sells stay open. The BUY pause may be indefinite | `test_Q8_BUY_pause_blocks_buys_but_not_claims` |
| Which switch freezes claims? | **Kind 6, DIVIDEND.** `claim` and `claimFor` revert `Paused()`; `claimableNow` still reports the balance; tax keeps accruing and buys keep working. At most 72 hours per owner call (`FreezeTooLong()` `0x6955d88b` beyond), renewable; it reopens by itself at the deadline and nothing is lost | `test_Q8_DIVIDEND_pause_blocks_claim_and_claimFor_for_at_most_72h_per_call` |
| `pauseAll()` after graduation | Claims of both assets freeze for 72 h. Router buys and transfers to `0x...dEaD` keep working | `test_Q8_pauseAll_after_graduation_freezes_claims_but_not_v2_buys_or_transfers` |
| `snipeBpsNow` during the window | `snipeStartBps` at creation, then linear: 5000 bps over 30 min gives 4997 after 1 s, 2500 after 15 min, 2 in the last second, 0 from minute 30 on. The surcharge goes to the **platform**: a 1 OKB buy at 2500 bps paid 0.26 OKB to the platform, 0.03 OKB to the vault and 0.71 OKB into the curve | `test_Q8_snipeBpsNow_decays_linearly_and_the_surcharge_goes_to_the_platform` |
| Is anti-snipe optional? | **Yes**, `snipeStartBps = 0` is accepted. If set: 2000 to 9000 bps, `snipeMins > 0`, and `snipe + 100 + taxBuy <= 9500`, else `FeeTooHigh()` `0xcd4e6167` | `test_Q8_anti_snipe_is_optional_and_bounded_by_LaunchLogic` |
| With a founder round | The anti-snipe clock starts at the round's end; until then `snipeBpsNow` stays at the start value and public buys revert `FounderOnly()` | `test_Q5_founder_round_flag_and_FounderOnly` |
| Is `firstBuy` optional? | **Yes, 0 is accepted** with `msg.value = listingFee` (0 on the observed launch). Nothing is sold and the vault is empty | `test_Q8_firstBuy_is_optional_zero_is_accepted` |
| Non-zero `firstBuy` | Trades inside `createToken`, exempt from anti-snipe, and **pays tax into the vault from the creator's own money** (0.012 OKB for 0.4 OKB at 3%) | `test_Q8_nonzero_firstBuy_trades_in_the_creating_tx_and_pays_tax_into_the_vault` |
| Tax and protection bounds | Tax at most 1000 bps per side. A Directed (V2) launch needs `taxBuy + taxSell > 0`; on-chain one taxed side is enough. Protection at least 1 day | `test_Q8_tax_and_protection_bounds` |
| Signature | Binds `msg.sender`, the recipient (`vaultData`), `msg.value` and the deadline. Without the fork override the real signer is required | `test_Q8_launch_needs_the_signer_and_binds_sender_deadline_and_value`, `test_Q8_real_platform_signer_is_required_on_mainnet_state` |
| Recipient admitted by the Directed factory | Any non-zero address: a deployed contract, an address with no code yet, `0x...dEaD`. Zero is refused | `test_Q8_directed_factory_validate_accepts_any_nonzero_recipient` |

**What the kernel must do**

- Treat a failed claim as "zero inflow this epoch" and still advance state. A 72-hour DIVIDEND pause can be
  renewed indefinitely by the IGNIX owner; inflow simply waits in the vault.
- Do not assume tax arrives only through the kernel's own claim, and do not let the chip depend on the
  split between "claimed now" and "already here".
- Check `pausedUntil(1)`, `snipeBpsNow` and `founderRound.endsAt` before the buy, or let the try/catch absorb
  the revert (50,313 gas for a failed `buyTo`).
- Launch with `firstBuy = 0`, anti-snipe off, no founder round. `tools/launch-check` can read all of these
  from the `createToken` calldata (selector `0xef44bdf2`): `p.firstBuy`, `p.snipeStartBps`, `p.founderBps`,
  `templateId == 3`, `abi.decode(vaultData, (address))`, `p.quote == 0`, `venue == 1`.
- The launch wallet must be the one the signature was issued to, and the recipient must be final before
  asking for the signature.

---

## 9. Gas

All figures are gas **as seen by the calling contract** (`gasleft()` before and after the external call),
each leg starting with a cold access list, so they are per-leg worst cases. Test contract `Q9_Gas`.
"Minimum gas limit" is the smallest `gas:` value with which the sub-call succeeds, found by binary search;
below it the call reverts as a whole and nothing moves.

### Curve phase

| Leg | Gas | Minimum gas limit |
|---|---|---|
| `claim(native)`, receiver does almost nothing | 30,225 | 29,518 |
| `claim(native)`, receiver doing 4 storage writes + event | 120,857 (90,632 is the receiver) | 120,150 |
| `claim(native)` reverting `NothingToClaim` | 19,131 | |
| `claim(native)` reverting `Paused` | 18,793 | |
| `claim(token)` before graduation (reverts) | 22,377 | |
| `claimFor(native)` from an EOA, whole transaction | 51,629 | |
| `buyTo`, very first buy on a fresh curve | 135,037 | 131,696 |
| `buyTo`, first for this recipient, curve already traded | 117,937 | 114,325 |
| `buyTo`, later | 100,837 | |
| `buyTo` reverting `Slippage` | 50,313 | |
| `buyTo` reverting `Graduated_` | 39,447 | |
| `buyTo` that sells out the curve and graduates | 3,055,785 | |
| `tokens(token)` | 22,573 | 19,714 |
| `snipeBpsNow` / `pairOf` / `pausedUntil` / `founderRound` | 11,594 / 11,000 / 10,453 / 14,782 | |
| `vault.claimableNow` | 3,613 | |

### Graduated phase

| Leg | Gas | Minimum gas limit |
|---|---|---|
| `claim(token)`, during protection | 53,496 | 57,295 |
| `claim(token)`, after protection | 44,511 | |
| `claim(native)` residual | 30,225 | |
| transfer to `0x...dEaD`, first (balance 0 to x), during protection | 53,349 | 50,375 |
| transfer to `0x...dEaD`, later, during protection | 36,249 | |
| transfer to `0x...dEaD`, later, after protection | 25,507 | |
| router buy to `0x...dEaD`, **first swap ever on the pair**, in a later block | **210,269** | |
| router buy to `0x...dEaD`, first swap of a block, dead balance 0 to x | 158,969 | 155,840 |
| router buy to `0x...dEaD`, first swap of a block, later | 141,869 | |
| router buy to `0x...dEaD`, same block as another swap | 131,453 | |
| router buy to itself, first swap of a block, during protection | 139,960 | |
| router buy, first swap of a block, after protection | 131,871 | |
| router buy reverting `INSUFFICIENT_OUTPUT_AMOUNT` | 128,177 | |
| direct `WOKB.deposit` + `WOKB.transfer` + `pair.swap`, same block as graduation | 148,893 | |
| `pair.getReserves` / `pair.token0` / `token.taxBuyBps` / `token.balanceOf` | 5,398 / 5,263 / 5,422 / 5,658 | |

The first swap of each block costs more because the pair then writes its two cumulative-price slots; the
very first time they go from zero to non-zero.

### Whole epochs in one transaction (later legs reuse warm state)

| Sequence | Gas |
|---|---|
| Curve: `claim(native)` + `tokens` + `snipeBpsNow` + `pairOf` + first `buyTo` | 30,240 + 23,820 + 94,442 = **148,502** |
| Curve, next epoch | 30,240 + 23,820 + 77,342 = **131,402** |
| Graduated: `claim(token)` + `claim(native)` + first transfer to `0x...dEaD` | 53,514 + 16,737 + 32,064 = **102,315** |
| Graduated, next epoch (native claim reverts) | 53,514 + 5,507 + 14,964 = **73,985** |

### Real transactions

| Transaction | Real `gasUsed` | Fork |
|---|---|---|
| `buy` of 0.046809775 OKB, tx `0x521559763f9546f914e726146eaf9ee00db39754c8ff8fb4a625f794beca1cbe`, block 72,368,108 | 210,837 | 210,837 (213,637 before a 2,800 refund) |
| platform push, tx `0x4c1b8ddd4af56229dcb5b128e99dc9f34506a747d92cb95bd243090276a1eb34`, block 72,303,399 | 66,828 | 66,828 |

Receipts at the pinned block show `l1Fee = 0` (both L1 fee scalars are zero): a transaction costs
`gasUsed * effectiveGasPrice` only. User transactions near the pinned block paid 0.52 gwei.

Tests: `test_Q9_gas_claim_native`, `test_Q9_gas_claimFor_as_a_transaction`, `test_Q9_gas_buyTo`,
`test_Q9_gas_buyTo_that_graduates`, `test_Q9_gas_reads`, `test_Q9_gas_claim_token_after_graduation`,
`test_Q9_gas_transfer_to_dead`, `test_Q9_gas_v2_router_buy`, `test_Q9_gas_reads_after_graduation`,
`test_Q9_gas_curve_epoch_in_one_transaction`, `test_Q9_gas_graduated_epoch_in_one_transaction`,
`test_Q9_min_gas_limit_curve_legs`, `test_Q9_min_gas_limit_graduated_legs`,
`test_Q10_fork_reproduces_a_real_mainnet_buy_tokens_and_gas`.

**What the kernel must do**

- Guard each leg on the per-leg worst case times 64/63, plus the kernel's own `receive()` cost for the
  native claim, plus margin. Suggested starting points: native claim 60,000; token claim 90,000; `buyTo`
  220,000; transfer to `0x...dEaD` 90,000; router buy 330,000.
- The external legs are small next to the chip step (about 5.2M gas): about 150,000 on the curve and about
  100,000 after graduation.
- The Manager is upgradeable and the token's cost depends on the protection window, so these numbers can
  change. A guard that is too low only turns a leg into a caught failure; it cannot lose funds.

---

## 10. Further questions

**Q-A. Where does project-token tax sit after a taxed V2 trade, what moves it, is there a threshold, does a
small claim work?**

- It sits in the **vault** as a plain token balance from the moment of the trade. `taxSink() == vault`; the
  token contract holds nothing.
- Three calls move it, all to `RECIPIENT` only: `claim(token)` by the recipient, `claimFor(recipient, token)`
  by anyone, and the operator-only `0x67318ec1(uint256 minAmount)` by `0xcc8D1916A96319A0Cdcde1897DAB61d34322FeFe`.
  `sync()` does not.
- **The threshold exists only in the platform's off-chain job**: it is the `minAmount` argument of the
  operator call. On-chain the only floor is "not zero". The real push found on mainnet passed 113.79 tokens
  and moved 86,793 tokens.
- A claim by the recipient contract succeeds for 1 wei.
- Nothing converts the token: there is no swap path in the vault [bytecode], which matches the docs'
  "MEME is never converted".

Tests: section 6.3.

**Q-B. Is a plain transfer of the graduated token from a contract to `0x...dEaD` taxed or blocked? Any
difference during protection?**

Neither taxed nor blocked, during the window and after it. The only difference is gas: 36,249 during the
window against 25,507 after it for a repeat transfer, because the token probes the sending contract.
Test: `test_Q6_QB_tokens_bought_on_the_curve_can_go_to_dead_untaxed_during_and_after_protection`.

**Q-C. Router buy with `0x...dEaD` as recipient from a contract: does it work, which function, what tax and
fee, any refund?**

It works during and after the window with `swapExactETHForTokensSupportingFeeOnTransferTokens`. LP fee
0.3%, then `taxBuyBps` of the gross output goes to the vault in tokens. No native OKB returns to the
caller, so `receive()` does not need to accept the router. Tests: section 7.

**Create-form defaults read on ignix.bot on 2026-10-04 [API], against what the chain enforces [test]**

| Form default | On-chain rule |
|---|---|
| Directed vault tax 1% / 1%, minimum 1% per side | at most 10% per side; at least one side non-zero. The 1% per-side minimum is a signer policy. All 83 live native Directed tokens have at least 1% on both sides (maximum seen 6% / 9%) |
| Graduation protection 100 days, minimum 1 day | minimum 1 day enforced. OB signed 8,640,000 s; one live graduated token used 86,400 s |
| Anti-snipe off | optional; 8 of the 83 live tokens enabled it |
| Priority buy 0 | `firstBuy = 0` accepted |
| Graduation at 85 OKB | `graduation = 85e18` on the launches read; the initial curve follows from it. The threshold is not range-checked on-chain |
| 1,000,000,000 supply, 80% on the curve | `sellable` = 800,000,000 and `reserve` = 200,000,000 on all 83 |
| Curve fee | 1% buy and 1% sell, forced on-chain |

---

## 11. Corrections to our earlier design notes

| Earlier statement | Finding |
|---|---|
| "The token figure exceeded the vault's token balance, so the kernel must measure balance deltas" | At one block `claimableNow` **equals** the balance on that same vault. The earlier difference came from reading at two blocks. Measuring deltas is still right, for the reason in section 8 |
| "IGNIX's daily push uses `claimFor` with no recipient callback" | The push is the operator-only `0x67318ec1(minAmount)`, token only. No callback is correct for tokens. Native claims do call `receive()` |
| "The unknown vault selector `0x67318ec1` is not needed" | Identified (above). Not needed by the kernel |
| "Before graduation ... cannot move them" | Confirmed for every non-Manager destination. A transfer to the Manager and a curve sell remain possible if the holder performs them |
| "After graduation a transfer to `0x...dEaD` is untaxed" | Confirmed |
| "A direct `pair.swap` with `0x...dEaD` as recipient works ... tax deducted from the recipient's amount" | Confirmed on a native-OKB pair, inside the protection window |
| "The Manager storage slot of `signer` can be located" | Slot 5 |
| Error selectors `FounderOnly 0x2c353d89`, `Paused 0x9e87fac8`, `Slippage 0x7dd37f70`, `CurveOnly 0x9dabc49b`, `TransferFailed 0x90b8ec18`; "`claimFor` costs about 52k" | All confirmed (51,629) |
| `tokens()` struct of 16 words | Confirmed. Add: a flat 16-value interface does not compile without `via_ir` |
| Claims pausable in 72-hour windows | Confirmed. The switch is kind 6 (DIVIDEND); the BUY switch (kind 1) does not affect claims |

---

## 12. UNVERIFIED

| Item | Reason |
|---|---|
| Behaviour of a native-OKB Directed token after a **real** graduation | None has graduated on mainnet (0 of 83). Shown only on a fork, on a fork launch and on live OB |
| A native claim to a contract recipient **on mainnet** | Has not happened yet: the one live contract recipient has balance 0. Shown on the fork with that unmodified contract, and the fork is shown faithful by `Q10_Replay` |
| How the platform's push job picks its threshold and schedule | Off-chain. One push was seen in 27.8 hours, with a threshold of 113.79 tokens |
| Names of `0x67318ec1` (vault), `0x2761dbab` and `0xf7fd7b0f` (Directed factory) | Sources are not verified and no signature database knows them. Behaviour of the first two is tested; `0xf7fd7b0f(address)` is presumably the owner's setter for the push operator and was not called |
| Full semantics of the token outside the paths tested | Token source is not verified. Tested: curve lock, tax on the official pair, plain transfers, a second genuine V2 pool, the `token0()` probe. Not tested: V3 pools, the V4 swap gate (`openSwapGate` / `closeSwapGate`), `addDetectedPools`, `setTaxExempt` |
| That the platform signer will sign a launch whose recipient is a contract with `firstBuy = 0` and anti-snipe off | The signature is issued off-chain. On-chain the launch is valid, and a live token with a contract recipient exists (fixture B) |
| The listing fee for a new launch | A signed parameter. It was 0 on the OB launch; the current value is the signing service's choice |
| Whether the token address must end in `eeee` | Every live token does; the fork launch with an arbitrary salt did not need it, so the suffix is mined off-chain rather than enforced |
| Future behaviour | The Manager is a UUPS proxy under a 1-of-2 Safe, and the registry, launch factory and Directed factory pointers can be rotated for future launches. Everything here is the behaviour at block 72,369,000 |

---

## 13. Reference tables

### Errors (selectors asserted in tests)

| Selector | Error | Raised by | When |
|---|---|---|---|
| `0x969bf728` | `NothingToClaim()` | vault | claim with a zero balance; `claim(token)` before graduation |
| `0x82b42900` | `Unauthorized()` | vault | `claim` by a non-recipient; `claimFor` for another address; the push by a non-operator |
| `0xc97d95cf` | `UnknownAsset()` | vault | asset is neither QUOTE nor TOKEN |
| `0x9e87fac8` | `Paused()` | vault, Manager | DIVIDEND switch for claims, BUY switch for buys |
| `0x90b8ec18` | `TransferFailed()` | vault, Manager | native payment to a recipient that reverts or runs out of gas |
| `0x3ee5aeb5` | `ReentrancyGuardReentrantCall()` | vault | re-entrant claim |
| `0x9dabc49b` | `CurveOnly()` | token | any non-Manager transfer before graduation |
| `0xec442f05` | `ERC20InvalidReceiver(address)` | token | transfer to `address(0)` |
| `0x735c0da7` | `Graduated_()` | Manager | `buy` / `buyTo` / `sell` after graduation |
| `0x7dd37f70` | `Slippage()` | Manager | output below `minTokensOut` |
| `0x52df9fe5` | `SoldOut()` | Manager | output is zero (`amountIn = 0`) |
| `0x0bba69fb` | `BadValue()` | Manager | `msg.value != amountIn`; bad `buyTo` recipient; launch rule |
| `0x2c353d89` | `FounderOnly()` | Manager | public buy during a founder round |
| `0xc5723b51` | `NotFound()` | Manager | token not launched by this Manager |
| `0xcd4e6167` | `FeeTooHigh()` | Manager | launch fee, tax or anti-snipe out of range |
| `0x6955d88b` | `FreezeTooLong()` | Manager | pause of kind 4 or 6 beyond 72 h |
| `0x5cd5d233` / `0x0819bdcd` | `BadSignature()` / `SignatureExpired()` | Manager | launch admission |
| `Error(string)` | `UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT`, `UniswapV2: K`, `TransferHelper: ETH_TRANSFER_FAILED` | Uniswap V2 | the revert data has dirty padding; decode the string, do not compare raw bytes |

### Addresses (chain 196, block 72,369,000)

| | |
|---|---|
| IgnixManager (proxy) | `0x96B51c57e5346D0C0198899243cf851D1E23C309` |
| Manager owner (Safe) | `0x9147C109F903eeA66DD0b512531ae9cE0377E76a` |
| Platform signer | `0x6EFa1Fad18900B929Fe6782fd3eaBeac2563416A` (also owns the Directed factory) |
| Vault registry | `0xCE65471A6c6950e17f4B527b20b0aF8a8f905311` |
| Directed vault factory (template 3) | `0x48509800895d5735fDC93367aE925579eeFF24aE` |
| Push operator | `0xcc8D1916A96319A0Cdcde1897DAB61d34322FeFe` (EOA) |
| Launch factory | `0x5Fe101CaED11883eE133eb3Ffd013F0CD27Bb9D3` |
| Uniswap V2 router / factory | `0x182a927119D56008d921126764bF884221b10f59` / `0xDf38F24fE153761634Be942F9d859f3DBA857E95` |
| WOKB | `0xe538905cf8410324e03A5A23C1c177a474D59b2b` |
| V2 LP locker / liquidity helper | `0xeD707fc375C6A27e4330d3d38a939ba55bB2b99A` / `0x8916FDAB92f3F5B3e8FB0d22f99c88a28e751ba6` |
| Token runtime code hash (all tokens checked) | `0xe4a9dfa056a271c2bab97dd1b2968f0f7364b654f79ebc4d11b50f96ebe75dec` (9,419 bytes) |
| Directed vault runtime | 3,019 bytes; immutables RECIPIENT, TOKEN, MANAGER, FACTORY, QUOTE |
