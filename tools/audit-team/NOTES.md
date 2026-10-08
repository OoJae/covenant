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
- the deployer (`covenant.deployer` of `addresses.json`, `0x84cE7bAe1b788C7aD985D57721cA428b401aE34D`), the
  keeper (`keeper` of `deployments/xlayer.json`) and the Covenant Architect's OKX.AI agent wallet
  (`architect.agentWallet`), always;
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
| `kernel-value` | native value sent to a kernel (listed, or `KernelFactory.isKernel` / `KernelFactoryV2.isKernel`) or to a kernel's vault |
| `kernel-usdt0` | USD₮0 sent from the wallet to a kernel (v1 or v2) or to a kernel's vault: a USD₮0 `Transfer` from the wallet to one in the receipt of any of its transactions or user operations, a USD₮0 `transfer` / `transferFrom` / `transferWithAuthorization` call naming one (also when it reverted), or a USD₮0 `Transfer` out of the wallet in a transaction it did not send (its EIP-3009 authorisation, such as an x402 payment, or an allowance, executed by anyone; see "USD₮0 and kernel v2") |
| `transistor-transfer` | `safeTransferFrom` / `safeBatchTransferFrom` on the Covenant Transistors, or a `TransferSingle` / `TransferBatch` of them to or from the wallet inside any transaction (mints and burns are not transfers) |
| `delegation` | the wallet has code other than an EIP-7702 designator to a known smart-wallet implementation (a contract, or a delegation to an implementation not listed in `smartWalletImplementations`), or one of its nonces was used by an authorisation to such an implementation |
| `unexplained-nonce` | a nonce that neither a transaction nor an authorisation of the wallet explains |

A target that is not in the known list is a `WARN` (listed, not a flag). A rule that cannot be decided because an
address is not configured (for example value sent to an unknown contract while no kernel and no KernelFactory is
known) says `NOT CHECKED` and makes the verdict INCOMPLETE, never CLEAN. A reverted transaction is still listed and
flagged, marked as having had no effect.

`addresses.json` names the fixed IGNIX and DEX contracts and the deployer. The Covenant contracts (Splitter,
KeeperTank, TeamRegistry, Transistors, Circuits, SealedVM, Fab, KernelFactory, Lens, kernels) and the keeper stay
null there: `deployments/xlayer.json`, written from the chain by the signing sessions, is the one record, and
`--deployment deployments/xlayer.json` fills them in (an address named in both places must be the same). Known
Covenant contracts are named in the report, so calls to them are not unknown targets. `other` names the further
contracts the team calls: the OKX.AI agent registry, and TapeOut's three DeWEB contracts (container opener,
SiteRegistry, DomainBinding), to which the deployer publishes the site. Every transaction `deployments/xlayer.json`
lists under `site.txs` goes to one of those three (125 on 2026-10-08: 1 `open`, 73 `putFile`, 26 `appendChunk`,
24 `removeFile`, 1 `bind`). Until they were listed, each of them was a `WARN`.

## USD₮0 and kernel v2

A v2 kernel (`contracts/core-v2`) routes every USD₮0 it receives as tax: x402 revenue paid to it funds buys of the
team's token. So no team wallet may ever pay one (self-payment is forbidden), and the audit treats a v2 kernel like a
v1 kernel and adds the rule `kernel-usdt0`. `--deployment` brings the v2 kernel (`flagshipV2.kernel`) and the
KernelFactoryV2 (`coreV2.kernelFactory`, asked `isKernel` for every unknown target and every USD₮0 recipient) and the
LensV2; `addresses.json` names USD₮0 (`usdt0`).

An x402 payment needs no transaction of the payer: the payer signs an EIP-3009 authorisation and the facilitator
submits it. Such a payment uses no nonce and no user operation, so the nonce walk cannot see it. When a KernelFactoryV2
is configured, the audit therefore scans every USD₮0 `Transfer` log whose `from` is one of the team wallets (one
`eth_getLogs` filter for all of them, 100-block chunks, the part below the safe head cached), from the block at which
the KernelFactoryV2 got its code (found by a search over `eth_getCode` at historical blocks; no v2 kernel can exist
before it) to the audit block. Each transfer in a transaction the wallet did not send is listed as a row of its own
(function "(USD₮0 transfer, sent by another account)"); into a kernel or a kernel's vault it is a FLAG, to anything
else it is listed only. The verdict shows a `COVERED` line with the blocks scanned, or `NOT COVERED` with the reason
(then the audit is INCOMPLETE).

## Smart wallets (EIP-7702 + ERC-4337)

A wallet whose code is exactly `0xef0100` followed by an address listed in `smartWalletImplementations` of
`addresses.json` is a smart wallet: listed as such, not flagged. Today the list holds one implementation,
`0xe40ccb2d94975c51bff0c004efdfd9b3a5796fa4`, OKX's SmartWalletEntry (verified contract on OKLink), the delegate of
OKX Agentic Wallets. Any other code, or an authorisation to an address not in the list, is still a FLAG.

Such a wallet also acts without signing transactions: a bundler sends `handleOps` to an ERC-4337 EntryPoint and the
EntryPoint calls the wallet. For every wallet that has or had code, the audit therefore scans the
`UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)` logs with the wallet as `sender` on each
EntryPoint of `addresses.json` that has code (v0.7 `0x0000000071727De22E5E9d8BAf0edAc6f37da032` and v0.6
`0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789`, both live on X Layer), from the block of the wallet's first activity
(its first nonce, found by the nonce walk; a delegation always uses a nonce) to the audit block, in 100-block
`eth_getLogs` chunks (the public endpoint refuses 101), ten per HTTP request at the same pace as every other request.
The part below the safe head is cached in `cache/chain-196.json`, so a rerun asks only for the new blocks.

Each operation is listed like a transaction (`op <sequence>`, the bundle's hash, value "not visible") and audited
from the bundle's receipt, restricted to its own logs: those between the previous `BeforeExecution` /
`UserOperationEvent` of the same EntryPoint and its own `UserOperationEvent`. The rules that name the wallet (an IGNIX
trade by it, an IGNIX token moved to or from it or approved by it, transistors moved to or from it) are also applied
to the bundle's validation phase, which cannot be attributed to one operation. In the execution: any other IGNIX
trade or token movement is `ignix-activity` (a kernel's own curve buy inside a settle is expected), any other
IgnixManager event is `ignix-call`, `TokenCreated` with a trade is `first-buy`, a WOKB event or a Uniswap V2 `Swap`
is `dex-call`; events of kernels and their vaults are named. The verdict shows a `COVERED` line per smart wallet
(operations found, EntryPoints, blocks), or `NOT COVERED` with the reason (then the audit is INCOMPLETE).

## What it cannot see

- Calls made on a wallet's behalf other than its user operations through the listed EntryPoints: a relayer, a
  contract the wallet controls, an EntryPoint not listed, or the wallet's delegate code called directly by another
  account (not through an EntryPoint: no `UserOperationEvent`). Inside a wallet's own transactions and user
  operations, internal calls are seen only through the events they emit (IGNIX `Trade`, token Transfer / Approval,
  ERC-1155 transfers); a call or a value transfer that emits nothing (for example OKB sent to a kernel's vault by a
  user operation) is not seen: `debug_traceTransaction` is not available on the public RPC.
- Wallets that were never declared, in the table or in the registry. The registry proves nothing about a wallet
  that is not listed.
- Anything off-chain (a centralised exchange).
- Tokens moved out of a wallet by other accounts, except USD₮0 from the KernelFactoryV2's creation on (above).
- A wallet whose nonce was already non-zero at block 0 (reported as incomplete).

## Verified facts

| Fact | Verified by |
|---|---|
| **Live audit, 2026-10-06, block 72,526,734: VERDICT CLEAN** (15 transactions and 1 user operation of 3 wallets). The deployer: 15 transactions, all found (the keeper's funding, Ignite, the probe's two mints and tape-out, the SealedVM, Fab, KernelFactory and Lens, the flagship's `tapeoutChip`, `KernelFactory.create` and chip handover, two more `tapeoutChip` (the demo chips 3 and 4), and `TeamRegistry.invite`). The keeper: none. The Architect's agent wallet `0xbe50...6da0`: a smart wallet (designator to OKX SmartWalletEntry); its one nonce is the 7702 authorisation, and its one user operation, the OKX.AI registration (bundle `0x61d9d945...`, block 72,525,583, EntryPoint v0.7, bundler `0xaf3d...e052`), emitted 4 events of the OKX.AI agent registry (the mint of agent 14683 to the wallet); nothing flagged. WARN: the keeper and the agent wallet are declared in `docs/WALLETS.md` but not yet in the TeamRegistry (entry 0 only; the deployer has sent one `invite`). | `node tools/audit-team/audit-team.ts --deployment deployments/xlayer.json` (output in `out/`) |
| `eth_getLogs` on https://rpc.xlayer.tech accepts 100 blocks per query and refuses 101 (`block range greater than 100 max`); `debug_traceTransaction` is not whitelisted. Both EntryPoints (v0.7, v0.6) have code on X Layer. | `curl` of `eth_getLogs` / `debug_traceTransaction`, `cast code`, 2026-10-06 |
| The deployer `0x84cE...E34D` had sent no transaction at block 72,378,000; on 2026-10-06 it had sent one: nonce 0, block 72,516,171, a plain transfer of 0.031 OKB to `0x7444eC2a06d3c1070203b76c2c3EeE998317C4Ff` (an address without code). Verdict CLEAN (one WARN: unknown target). | `node tools/audit-team/audit-team.ts --wallet 0x84cE7bAe1b788C7aD985D57721cA428b401aE34D --no-cache --out <dir>` (2026-10-06, block 72,516,637) and `test/live.test.ts` (pinned block) |
| The creator of IGNIX's OB token has 11 transactions at block 72,378,480, all found; its first buy of 0.4 OKB, an `approve` on OB and a sale through an aggregator are flagged. | `test/live.test.ts`, `out/audit.md` |
| A real wallet that signed an EIP-7702 authorisation has the nonce it used explained. | `test/live.test.ts` |
| The selectors and event topics the rules use are computed from their signatures and equal the values measured on the chain (`createToken` 0xef44bdf2, `buyTo` 0x9415aa2a, `claim` 0x1e83409a, `creatorOf` 0xdea5c2e0, `TransferSingle`, ...). | `test/known.test.ts` |
| The TeamRegistry is read with `count()` and `at(i)` (`(address wallet, string role, uint256 timestamp)`, contracts/issuance/src/TeamRegistry.sol); on the rehearsal fork, entry 0 is the deployer. | `test/audit.test.ts` (offline), `REHEARSE=1 node --test tools/launch-check/test/rehearsal.test.ts` (on the fork) |
| The nonce walk locates every nonce exactly for random histories, with any number of probes per round, and refuses a node whose counts go backwards. | `test/walk.test.ts` |
| USD₮0 into a kernel is flagged: by a transfer of the wallet (also reverted, also into the kernel's vault, also through another contract), by its user operation, and by its EIP-3009 authorisation executed by a facilitator (no nonce used); a payment to anyone else is listed and not flagged; the scan starts at the KernelFactoryV2's creation; a KernelFactoryV2 without `usdt0` makes the audit INCOMPLETE. The wallets are synthetic table addresses: no real wallet pays anything in any test. | `OFFLINE=1 node --test tools/audit-team/test/usdt0.test.ts` (10 tests) |
| On a fork with the real kernel v2 (deployed by `deploy/rehearse-v2.sh`), launched, bound, traded by unrelated addresses and paid 0.5 USD₮0 by an unrelated payer, the audit with the completed deployment file flags nothing and scans USD₮0 from the KernelFactoryV2's creation. | `REHEARSE=1 node --test tools/launch-check/test/rehearsal-v2.test.ts` |

Tests: `OFFLINE=1 node --test tools/audit-team/test/*.test.ts` (offline, a chain made of tables) and
`node --test tools/audit-team/test/live.test.ts` (read-only, X Layer at a pinned block).
