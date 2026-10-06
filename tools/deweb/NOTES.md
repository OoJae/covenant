# deweb: notes

Publishes Covenant's site (web/, built to web/dist) into the DeWEB container of a TapeOut circuit on X Layer, so
that the official gateway serves it from the chain, and checks the result. Read-only tools plus one forge script;
the transactions are sent only by `deploy/publish-site.sh --broadcast`, signed by the deployer's keystore.

| File | Role |
|---|---|
| `plan.ts` | The ordered transactions, their calldata, gas and OKB, against the live chain (eth_call only) |
| `verify.ts` | Reads the site back from the chain and compares it with a build, with a second node operator, and with what the official gateway serves in a headless browser |
| `src/` | Codec (`abi.ts`), chain reads and the container address (`chain.ts`), the site directory (`site.ts`), the plan (`plan.ts`), gas estimates (`gas.ts`), the checks (`verify.ts`), a DevTools driver (`browser.ts`) |
| `sim/` | Foundry: `src/SitePublisher.sol` (the same plan in Solidity, and the read-back), `script/Publish.s.sol` (what forge broadcasts), `test/Publish.fork.t.sol` (the real DeWEB contracts on a fork) |
| `../../deploy/publish-site.sh` | The signing wrapper: build, rehearse on a fork, send, record, verify |

## Where the site goes

- **Circuit**: the probe circuit, `deployments/xlayer.json .probe.circuitId` = 1, on Covenant's processor
  `0xaC90A95bd11eb67A2dD83Ab7ecc0Ea9B521dEF0b` (processor number **283** in the TapeOut factory), held by the deployer.
- **Container**: `0x911350102b2D81a1E8A816638D429a16b80B8Ee2` (the ERC-6551 account of circuit 1; not opened yet).
- **Name**: `1.2.283.tape` (`<id>.<area code 2 = X Layer>.<processor number>.tape`, TAP-10 section 3.1).
- **Gateway URL**: **https://1-2-283.tapekit.org/** (status page: https://1-2-283.tapekit.org/.tape/status).

There is no short or vanity name such as "covenant" to register. A DeWEB name is derived from the processor
number and the circuit id; gateways resolve a name to the container *derived* from it and ignore any other container
(TAP-10 sections 4.2 and 6.3). `DomainBinding.bind(name, container, months)` accepts any well-formed domain for any
opened container (verified source: `_validDomain`: lower case, at least one dot), and keys the payment by
(name, container), so binding "covenant.tape" would buy nothing a gateway shows. A real DNS domain can be pointed at
a container only through HashPort's hosted console (TapeKit README, "Commercial service"), outside this project.
Read on 2026-10-06: `isPaid` is false for `covenant.tape`, `covenant.xlayer.tape`, `covenant.xyz`, `cvnt.tape` and
`1.2.283.tape`.

## What is sent, and what it costs

Planned against the live chain on 2026-10-06 (block 72,532,550) for the current build (11 files, 210,335 bytes,
15 chunks of at most 24,000 bytes):

| # | Call | Value |
|---|---|---|
| 1 | `opener.open(processor, 1)` | 0.08 OKB (`FEE()`, once) |
| 2-16 | `SiteRegistry.putFile` per file and `appendChunk` per further 24,000 bytes (scripts and stylesheet first, `index.html` last) | 0 |
| 17 | `DomainBinding.bind("1.2.283.tape", container, MONTHS)` | MONTHS x 0.026 OKB (`monthlyFee()`) |

17 transactions, about 49.9 million gas: about **0.001 OKB** of gas at X Layer's 0.02 gwei. **Total for one month:
about 0.107 OKB** (0.08 + 0.026 + 0.001); each further month 0.026 OKB. The fees are read from the chain at the time
of the plan and of the send. Rerunning after a site change sends only the files that changed (no opening, no name
fee while the name is active).

## The site under the gateway

The official gateway (tapekit.org, Service Worker version 0.3.0) serves `/` as `index.html`, an exact path as itself
with the declared content type (`; charset=utf-8` added to text types), a missing path with an extension as 404, and
a missing path without one as the site's fallback if one is set (TAP-10 section 7.2). Every file it serves is checked
against its declared SHA-256 and carries a Content-Security-Policy that allows same-origin scripts and
`connect-src https:`.

The site needs no change for this, and none was made: `web/vite.config.ts` already builds with `base: './'` (relative
URLs, no module-preload helper), the router uses the URL hash only (`#/...`, so every page is `index.html` and no
fallback path is needed), every script and the stylesheet are same-origin files, and the RPC calls go to
rpc.xlayer.tech / xlayerrpc.okx.com over https, which the policy allows. `web/scripts/check-budget.mjs` (part of the
build) refuses absolute paths and any other origin.

**The site bundles `deployments/xlayer.json`** (`web/src/config.ts` imports the whole file). Two consequences:
1. at HEAD on 2026-10-06 the build fails its own budget, because the file now carries the Architect's endpoint URLs
   (`https://architect-production-ffbe.up.railway.app`), a host `check-budget.mjs` does not allow. The site cannot
   be published until web/ imports only the sections it uses or the budget allows that host;
2. the publication record must not feed the build it records: `deploy/publish-site.sh` builds the site of HEAD
   with HEAD's `deployments/xlayer.json` minus `.site`. Otherwise every publication would change the next build.

## deploy/publish-site.sh

```
deploy/publish-site.sh                 rehearsal only: build, plan, rehearse on a fork, read back. Nothing is sent
deploy/publish-site.sh --broadcast     the same, then send (keystore covenant-deployer, one password)
MONTHS=3 deploy/publish-site.sh ...    months of name activation (default 1)
```

In order: the tree (web/, packages/, the chip files the site embeds, the lockfile, tools/deweb, deploy/) is HEAD and
HEAD is on origin/main; no .env, FOUNDRY_*, DAPP_* or COVENANT_FORK; the processor and circuit of
`deployments/xlayer.json`, held by the deployer; earlier broadcast records checked against the chain (below); HEAD's
site exported with `git archive` and built in a scratch directory with web/package.json's build command (pnpm's own
dependency check is skipped there: in a scratch directory it tries to reinstall); the snapshot copied to
`tools/deweb/sim/site/` (git-ignored); `plan.ts` against the chain; the rehearsal: a scratch copy of
`tools/deweb/sim` on a free-port anvil fork of the chain, the deployer impersonated, the whole forge script broadcast
there, the number of transactions compared with plan.ts's, and the site read back from the fork byte for byte with
`verify.ts`. Nothing of the rehearsal is written in the repository. With `--broadcast`: the deployer's nonce must be
the one the rehearsal started from and the snapshot unchanged; forge then sends from `tools/deweb/sim` with
`--account covenant-deployer --sender <deployer> --broadcast --slow`; afterwards the site is read back from the chain
(and through a second node operator), recorded in `deployments/xlayer.json` under `.site` (commit, processor,
processor number, circuit, container, name, gateway, paidUntil, build digest, files with SHA-256, every transaction),
and checked through the live gateway in a headless browser (`#app *` must render).

**A rehearsal that fails sends nothing.** A fork reads the chain lazily through the public node, which answers
about seven requests per second; the rehearsal's anvil therefore retries (`--retries 20 --fork-retry-backoff 1000`)
and its read-back waits up to 180 s per request. If it still fails (an empty `EvmError: Revert` in forge's
simulation, or a timeout), run the command again; do not run other forks against the same node at the same time.

**Recovery.** forge writes its record (`tools/deweb/sim/broadcast/Publish.s.sol/196/`, git-ignored) before it asks for
the password. Each run first asks the chain about every transaction in every record there: a record with nothing
signed (stopped at the password prompt) is removed with its timestamped copies; a record whose signed transactions are
all on chain and succeeded is kept (its hashes go into `.site.txs`); a signed transaction without a receipt (pending,
or a record that is not from mainnet) or one that reverted stops everything. What reached the chain is never sent
again because the plan is recomputed from the chain: an opened container is not opened again, an active name is not
paid again, a file already on chain byte for byte is not written again, and a file cut off half way is rewritten from
its first chunk (`putFile` replaces the whole file).

## What it cannot see

- **The gateway's future.** tapekit.org is run by the TapeOut / HashPort team. It refuses every X Layer site if the
  SiteRegistry or DomainBinding proxy is upgraded to an implementation it does not list ("store-changed"), and shows
  nothing while either of its two node operators (OKX, dRPC) is down. `verify.ts` reports both.
- **The name after it expires.** The gateway answers 402 when the name is not paid; the files stay on chain and
  readable by anyone (TAP-10 section 6.3: the fee is enforced by gateways, not by the chain).
- **What the browser does with the site.** verify.ts renders the landing page (`#app *`); it does not click through
  every route.

## Verified facts

| Fact | Verified by |
|---|---|
| Circuit 1 of processor `0xaC90…EF0b` is processor number 283, held by the deployer; its container `0x9113…8Ee2` is not opened and its name `1.2.283.tape` was never paid; `FEE()` = 0.08 OKB, `monthlyFee()` = 0.026 OKB; both proxies point at the implementations the gateway accepts. | `node tools/deweb/plan.ts --processor 0xaC90A95bd11eb67A2dD83Ab7ecc0Ea9B521dEF0b --circuit 1 --from 0x84cE7bAe1b788C7aD985D57721cA428b401aE34D` (2026-10-06, block 72,532,550) |
| X Layer's gas price is 0.02 gwei (20,000,001 wei); the deployer holds 0.478 OKB at nonce 15. | `cast gas-price`, `cast balance`, `cast nonce` on https://rpc.xlayer.tech, 2026-10-06 |
| The gateway serves a live X Layer site byte for byte with the declared types, `/` as index.html, 404 for a missing file, the fallback for an unknown route, `x-tape-verified: 1` on every file, Service Worker version 0.3.0, and the policy above. | `node tools/deweb/verify.ts --site 12-2-231 --no-local --no-covenant-needs` (2026-10-06): MATCH in every check |
| plan.ts produces byte-identical calldata to the Solidity planner executed on a fork (the fixture sites, an update with pruning, and the current web/dist), with gas estimates within 0.5% of the gas measured on the fork (rough steps within 25%). | `node --test tools/deweb/test/plan.test.ts` after `forge test --root tools/deweb/sim` |
| The codec equals Foundry's `cast` for every call and return value used. | `node --test tools/deweb/test/abi.test.ts` |
| On a fork of the real DeWEB contracts: anyone may pay the opening fee but only the holder writes; writes need an opened container; ownership is checked on every write; an operator can write files but not bind; the declared SHA-256 is not checked on chain; bind takes the exact fee, holder only, and activates the container; a second publication sends nothing and an update only the difference. | `forge test --root tools/deweb/sim` (14 tests, block 72,376,000) |
| `deploy/publish-site.sh` end to end on a fork, in a scratch clone pushed to a scratch origin (forge `--unlocked` there only): the rehearsal plans and sends 17 transactions on its own fork and reads the site back; after an earlier run that only opened the container, `--broadcast` sends the other 16 and records `.site` with all 17 hashes, the container, `1.2.283.tape`, the gateway URL and paid-until; a second `--broadcast` sends nothing; an unsigned leftover record (and its timestamped copy) is removed and nothing is sent; a record naming a transaction that is not on chain is refused; an uncommitted change in web/ is refused. | `PUBLISH_E2E=1 node --test tools/deweb/test/publish-site.e2e.test.ts` (2026-10-06, 1 test, 6 scenarios, 367 s) |
| The site of HEAD (built as the wrapper builds it, without the Architect URLs that fail its budget today), published on a fork exactly as the wrapper would, and opened through a local copy of the official gateway (TapeKit sw-gateway: `sw.js` byte-identical to tapekit.org's 0.3.0, kernel identical except that its X Layer node list is the fork): all 11 files served byte for byte with the declared types and `x-tape-verified: 1`, `/` is index.html, the policy allows the module script, the on-demand chunks, the stylesheet, the data: icon and both RPC hosts, and the page renders `#app *`: the site's script runs under the gateway. | a one-off script against `tools/deweb/research/local-gateway` (git-ignored), 2026-10-06; `verify.ts --gateway 'http://{label}.localhost:8096' --expect-selector '#app *'` reported MATCH in every check |
| The gateway reads X Layer at the head minus 2 (`pin: 'latest'`). On a fork, which mines only when a transaction arrives, blocks must be mined after a publication before the gateway sees its last two transactions; on mainnet a block arrives every second or so. | the render check above answered 402 (unpaid) until `anvil_mine` |

## Tests

```
node --test tools/deweb/test/*.test.ts                                  offline: codec, plan vs fork, verify checks
forge test --root tools/deweb/sim                                       the real contracts on a fork (rewrites sim/measured)
PUBLISH_E2E=1 node --test tools/deweb/test/publish-site.e2e.test.ts     the wrapper end to end on a fork (scratch clone)
```
