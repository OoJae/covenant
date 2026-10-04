# Probes: how to run

Fork tests against the live IGNIX contracts on X Layer (chain 196). Nothing here sends a transaction to a real
network, and no key or secret is used. Each test name states the fact it proves. The written findings
(answers, numbers, what the kernel must do) are in `FINDINGS.md`.

## Run

```bash
cd contracts/probes

# once: forge-std is not committed (the repo .gitignore excludes lib/)
forge install foundry-rs/forge-std --no-git --root "$PWD"

# everything (112 tests in 12 suites, about 20 s with a warm RPC cache, about 1 min cold)
forge test

# with the numbers (gas, amounts) printed
forge test -vv

# one question at a time
forge test --match-contract Q2_Claim -vv
forge test --match-contract Q9_Gas -vv
```

The tests create their own fork with `vm.createSelectFork(url, 72369000)`, so no flag is needed. These
equivalent forms also pass:

```bash
forge test --fork-url https://rpc.xlayer.tech --fork-block-number 72369000
XLAYER_RPC_URL=https://xlayerrpc.okx.com forge test      # fallback RPC
forge test --isolate                                      # every top-level call as its own transaction
forge test --evm-version prague                           # same results and same gas as cancun
```

Run the commands from `contracts/probes`, and keep the absolute `--root "$PWD"` on the install: without a
root forge can fall back to the git root and create `lib/` there, and a relative `--root .` fails with
"prefix not found".

## Pinned state

| | |
|---|---|
| Chain | X Layer mainnet, chain id 196 |
| Block | **72,369,000** (hash `0xf92ac85e...6dd15dd`, 2026-10-04 18:20:36 UTC, timestamp 1791138036) |
| RPC | `https://rpc.xlayer.tech` (default), `https://xlayerrpc.okx.com` (fallback). Both serve archive state at the pinned block |
| Override | `XLAYER_RPC_URL` environment variable |

Changing the block is a one-line edit (`PINNED_BLOCK` in `test/ProbeBase.sol`), but the tests assert live
balances of the fixture tokens at that block, so a few constants in `Q1`, `Q2`, `Q5` and `Q6_LiveOB` must
be updated with it.

## Toolchain and dependencies

| | |
|---|---|
| forge / cast | 1.8.3 (Homebrew) |
| solc | 0.8.28, `evm_version = "cancun"`, optimizer 200 runs, `via_ir = false` |
| forge-std | installed into `contracts/probes/lib/forge-std` with `forge install foundry-rs/forge-std --no-git` on 2026-10-04 (default branch at that date; it provides `vm.lastFrameGas`). The only dependency |
| Other | none. No npm packages, no global installs |

`foundry.toml` turns `lint_on_build` off (forge's linter flags the intentional masking casts in
`IgnixRead.sol`).

## Layout

```
src/interfaces/IIgnix.sol          IgnixManager as the kernel sees it: CurveToken struct, views, buyTo, errors
src/interfaces/IDirectedVault.sol  Directed vault (template 3), recovered from bytecode
src/interfaces/IIgnixToken.sol     launch token (fee-on-transfer after graduation), recovered from bytecode
src/interfaces/IUniswapV2.sol      minimal router / pair / factory / WOKB
src/CurveQuote.sol                 CurveQuote (exact curve buy quote, largest non-graduating buy)
                                   V2TaxQuote (router buy output net of the token tax)
src/IgnixRead.sol                  non-reverting readers of tokens(), pairOf(), snipeBpsNow(), ...
src/probes/RecipientProbe.sol      stand-in kernel used by the tests (never deployed anywhere)

test/ProbeBase.sol                 fixture: pinned fork, signer override, full launch, graduation helper
test/Q0_ForkLaunch.t.sol           the launch method itself
test/Q1_Fixtures.t.sol             live fixtures
test/Q2_Claim.t.sol                claim / claimFor to a contract
test/Q3_BuyTo.t.sol                buyTo from a contract, transfer lock, tax exemptions
test/Q4_CurveQuote.t.sol           quote exactness (fuzz), curve-crossing buy, max non-graduating buy
test/Q5_Decode.t.sol               tokens() layout, other views, founder round, selectors
test/Q6_Graduation.t.sol           forced graduation and everything after it (also Q-A, Q-B)
test/Q6_LiveOB.t.sol               the same lifecycle on the live OB token; live graduated vault
test/Q7_V2BuyBurn.t.sol            Uniswap V2 buy-and-burn leg (also Q-C), protection window
test/Q8_Timing.t.sol               claimFor griefing, sync, pause switches, anti-snipe, launch bounds
test/Q9_Gas.t.sol                  gas per leg, minimum gas limits, whole epochs
test/Q10_Replay.t.sol              two REAL mainnet transactions re-executed on a fork: same tokens, same gas

vendor-cache/                      everything fetched from outside the chain (see below)
```

## How the fork launch works

`ProbeBase._launch` performs a complete `IgnixManager.createToken` on the fork:

1. `stdstore` locates the storage slot behind `signer()` on the Manager proxy (slot 5; asserted).
2. `vm.store` replaces the platform signer with an address from `makeAddrAndKey("covenant-probes fork-only
   signer")`. The key is derived from that label inside the test VM; it is not a real key.
3. The test rebuilds the exact digest of `createToken` (chain id, Manager, sender, params, templateId 3,
   `abi.encode(recipient)`, deadline, factory, venue 1, protection seconds, pool fee, launch factory), signs
   it with `vm.sign`, and calls `createToken` with `firstBuy = 0` and `listingFee = 0`.

Everything after that is unmodified mainnet code: launch factory, token, Directed vault factory, vault. The
resulting token has the same runtime code hash as live tokens and the vault equals a live vault except for
its two immutables (`Q0_ForkLaunch`).

Forced graduation is a plain `buy` by a funded address (`vm.deal`) for the exact remaining cost plus a
surplus, so the cap, the refund and the in-transaction graduation all run.

## Gas numbers

`Q9_Gas` measures each leg as a sub-call from a contract (`gasleft()` before and after, inside
`RecipientProbe`). With this forge version the access list is reset between the top-level calls a test
makes, so each measured leg starts cold: the numbers are per-leg worst cases, and identical with and
without `--isolate`. Inside one transaction later legs are cheaper (see the "whole epoch" tests).

`Q10_Replay` checks the method itself: a real mainnet `buy` and the platform's real token push, re-executed
on forks of the blocks before them, give the token amounts of the real logs to the wei and the `gasUsed` of
the real receipts to the unit (210,837 and 66,828).

Receipts at the pinned block show `l1Fee = 0` (both L1 fee scalars are zero), so a transaction's cost is
`gasUsed * effectiveGasPrice` only. User transactions around the pinned block paid 0.52 gwei.

Forge runs these forks with Cancun rules (`evm_version = "cancun"`), while X Layer has EIP-7702 active:
11 of the 83 live native Directed recipients are delegated EOAs (23 bytes of code, `0xef0100...`). Under
Cancun rules a call to such an address fails instead of following the delegation, so the fixtures use
recipients without code, or a real contract. Running with `--evm-version prague` gives identical results
for every test here.

## vendor-cache

| File | What |
|---|---|
| `ignix-directed-launches.json` | every Directed (templateId 3) launch from `GET https://api.ignix.bot/v1/launches` (39 pages, 7,695 launches, fetched 2026-10-04 18:34 UTC), key fields only, plus counts per template |
| `directed-native-onchain-72369000.json` | for the 83 native-OKB Directed tokens: vault, recipient, recipient code size, vault balance and `tokens()` fields read by `eth_call` at the pinned block |
| `tx-create-OB.json` | the real `createToken` transaction of the OB fixture (templateId 3, `vaultData = abi.encode(recipient)`, venue 1, protection 8,640,000 s, listing fee 0) |
| `code-*.hex`, `disasm-*.txt` | runtime bytecode and `cast disassemble` output of the unverified token, vault and factories |
| `oklink-*.json` | Not committed (third-party source text). OKLink verified-source API responses. `{"data":[]}` means "not verified": token, vault, Directed factory, launch factory, registry, lockers. Verified: Manager implementation, Uniswap V2 router, WOKB |
| `vault-logs-scan.json` | `eth_getLogs` scan of three vaults (live graduated Directed vault, OB vault, TEST vault) over the 100,000 blocks (27.8 h) before the pinned block: one platform push, no other claim |
| `tx-platform-push-example.json` | that push: transaction and receipt of `0x4c1b8ddd...eb34` (operator `0xcc8D...FeFe`, selector `0x67318ec1`, threshold in calldata) |

The RPC allows `eth_getLogs` over at most 100 blocks and rate-limits bursts ("over rate limit" from about the
sixth log query in one batch); the scan used batches of four with a pause.

The OKLink endpoint is
`https://www.oklink.com/api/v5/explorer/contract/verify-contract-info?chainShortName=XLAYER&contractAddress=<addr>`.
It returns HTTP 429 after a few requests; wait about 12 s and retry.
