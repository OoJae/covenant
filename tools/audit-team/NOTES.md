# audit-team: notes

`audit-team.ts` lists every transaction each team wallet has ever sent and checks it against the rule of
`docs/WALLETS.md`: no team wallet ever buys, sells or swaps any IGNIX token, sends funds into a kernel, or trades
transistors. It uses only a public archive JSON-RPC endpoint (no explorer API, no key, read calls only).

```
node tools/audit-team/audit-team.ts --deployment deployments/xlayer.json [--quiet]
node tools/audit-team/audit-team.ts --wallet 0x...            # only this wallet (repeatable)
```

It writes `out/audit.md` (a table per wallet, the verdict, what the method cannot see) and `out/audit.json`.
Exit code 0: clean. 1: a rule was broken. 2: nothing flagged, but the audit could not be completed (never clean).

## Which wallets

Without `--wallet`: the union of
- the table of `docs/WALLETS.md` (every row whose Address cell holds an address; rows without one are reported as
  roles still to be added);
- the deployer (`covenant.deployer` of `addresses.json`, `0x84cE7bAe1b788C7aD985D57721cA428b401aE34D`) and the
  keeper (`keeper` of `deployments/xlayer.json`), always;
- every wallet the on-chain `TeamRegistry` lists, read with `count()` and `at(i)` at the audit block, when
  its address is known (`issuance.teamRegistry` of `deployments/xlayer.json`, given with `--deployment`).

`--deployment` reads `deployments/xlayer.json` (nested) or the flat `deploy/rehearsal.json`; the parts of signing
session 2 (evaluator, core, flagship) may be absent: the audit needs only the wallets, the registry and, when
present, the kernels.

A wallet listed on-chain but missing from `docs/WALLETS.md`, or the other way round, is audited anyway and
reported on a `WARN` line. If entry 0 of the registry is not the deployer, the configured address is not the
Covenant registry and the audit is incomplete (exit code 2). With `--wallet`, only the given wallets are audited
and neither the table nor the registry is read.

## What it checks

For each wallet, `eth_getTransactionCount` at the audit block gives the number of nonces used; a bisection over
`eth_getTransactionCount` at historical blocks finds the block of every nonce (`walk.ts`); each of those blocks is
fetched and the wallet's transactions are taken from it, with their receipts. Every nonce must be explained by a
transaction or by an EIP-7702 authorisation the wallet signed. Then each transaction is classified (`classify.ts`):

| Rule (FLAG, expected 0) | Raised by |
|---|---|
| `ignix-call` | any call to IgnixManager other than `createToken` (buy, buyTo, sell, claims, plain OKB...) |
| `first-buy` | a `createToken` whose decoded `firstBuy` is not 0, or whose calldata does not decode |
| `dex-call` | any call to the Uniswap V2 router or to WOKB |
| `ignix-token-call` | any transaction to a token launched through IgnixManager (`creatorOf(token) != 0`) or to a kernel's token |
| `ignix-activity` | an IGNIX `Trade` event, or a Transfer / Approval of an IGNIX token to or from the wallet, inside a transaction to any other contract (for example a sale through an aggregator) |
| `kernel-value` | native value sent to a kernel (listed, or `KernelFactory.isKernel`) or to a kernel's vault |
| `transistor-transfer` | `safeTransferFrom` / `safeBatchTransferFrom` on the Covenant Transistors, or a `TransferSingle` / `TransferBatch` of them to or from the wallet inside any transaction (mints and burns are not transfers) |
| `delegation` | the wallet has code (a contract, or an EIP-7702 delegation), or one of its nonces was used by an authorisation |
| `unexplained-nonce` | a nonce that neither a transaction nor an authorisation of the wallet explains |

A target that is not in the known list is a `WARN` (listed, not a flag). A rule that cannot be decided because an
address is not configured (for example value sent to an unknown contract while no kernel and no KernelFactory is
known) says `NOT CHECKED` and makes the verdict INCOMPLETE, never CLEAN. A reverted transaction is still listed and
flagged, marked as having had no effect.

`addresses.json` names the fixed IGNIX and DEX contracts and the deployer. The Covenant contracts (Splitter,
KeeperTank, TeamRegistry, Transistors, Circuits, SealedVM, Fab, KernelFactory, Lens, kernels) and the keeper stay
null there: `deployments/xlayer.json`, written from the chain by the signing sessions, is the one record, and
`--deployment deployments/xlayer.json` fills them in (an address named in both places must be the same). Known
Covenant contracts are named in the report, so calls to them are not unknown targets.

## What it cannot see

- Calls made by contracts on a wallet's behalf: a relayer, an ERC-4337 bundler, a contract the wallet controls, or
  an EIP-7702 delegate can act in transactions other accounts send. Inside a wallet's own transactions, internal
  calls are seen only through the events they emit (IGNIX `Trade`, token Transfer / Approval, ERC-1155 transfers).
- Wallets that were never declared, in the table or in the registry. The registry proves nothing about a wallet
  that is not listed.
- Anything off-chain (a centralised exchange).
- A wallet whose nonce was already non-zero at block 0 (reported as incomplete).

## Verified facts

| Fact | Verified by |
|---|---|
| **Live audit, 2026-10-06, block 72,521,612: VERDICT CLEAN.** The deployer has 9 transactions, all found: nonce 0 funds the keeper with 0.031 OKB (block 72,516,171); nonce 1 deploys the Splitter (Ignite, 0.0066 OKB, block 72,519,781); nonces 2 and 3 are `Transistors.mint` (0.00284 and 0.00084 OKB) and nonce 4 `Circuits.tapeout` of the probe (0.0013 OKB); nonces 5 to 8 deploy the SealedVM, the Fab, the KernelFactory and the Lens (signing session 2, blocks 72,521,302 to 72,521,377). The keeper `0x7444...C4Ff` has sent nothing. Nothing is flagged, no unknown target. One WARN: the keeper is declared in `docs/WALLETS.md` but not (yet) in the TeamRegistry, which lists only entry 0, the deployer (declared 2026-10-06 12:13:37 UTC). Output: `out/audit.md`, `out/audit.json`. | `node tools/audit-team/audit-team.ts --deployment deployments/xlayer.json` |
| The deployer `0x84cE...E34D` had sent no transaction at block 72,378,000; on 2026-10-06 it had sent one: nonce 0, block 72,516,171, a plain transfer of 0.031 OKB to `0x7444eC2a06d3c1070203b76c2c3EeE998317C4Ff` (an address without code). Verdict CLEAN (one WARN: unknown target). | `node tools/audit-team/audit-team.ts --wallet 0x84cE7bAe1b788C7aD985D57721cA428b401aE34D --no-cache --out <dir>` (2026-10-06, block 72,516,637) and `test/live.test.ts` (pinned block) |
| The creator of IGNIX's OB token has 11 transactions at block 72,378,480, all found; its first buy of 0.4 OKB, an `approve` on OB and a sale through an aggregator are flagged. | `test/live.test.ts`, `out/audit.md` |
| A real wallet that signed an EIP-7702 authorisation has the nonce it used explained. | `test/live.test.ts` |
| The selectors and event topics the rules use are computed from their signatures and equal the values measured on the chain (`createToken` 0xef44bdf2, `buyTo` 0x9415aa2a, `claim` 0x1e83409a, `creatorOf` 0xdea5c2e0, `TransferSingle`, ...). | `test/known.test.ts` |
| The TeamRegistry is read with `count()` and `at(i)` (`(address wallet, string role, uint256 timestamp)`, contracts/issuance/src/TeamRegistry.sol); on the rehearsal fork, entry 0 is the deployer. | `test/audit.test.ts` (offline), `REHEARSE=1 node --test tools/launch-check/test/rehearsal.test.ts` (on the fork) |
| The nonce walk locates every nonce exactly for random histories, with any number of probes per round, and refuses a node whose counts go backwards. | `test/walk.test.ts` |

Tests: `OFFLINE=1 node --test tools/audit-team/test/*.test.ts` (offline, a chain made of tables) and
`node --test tools/audit-team/test/live.test.ts` (read-only, X Layer at a pinned block).
