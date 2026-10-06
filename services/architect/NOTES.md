# Architect: notes

Decisions, what was verified, where OKX's SDK differs from the design document, and what is still open.
Written 2026-10-04; the real toolchain was wired in on 2026-10-06 (section "The real toolchain").

## How to run

```sh
pnpm install                              # repository root
cd services/architect
pnpm test                                 # 89 tests (3 skipped: the opt-in real-toolchain ones), about 3 s
pnpm typecheck
X402_MODE=mock node src/index.ts          # local server with mock payments and the stub toolchain
node scripts/selfcheck.ts http://localhost:8787 --run --mock-pay
node scripts/okx-listing.ts https://<public-host>
docker build -f services/architect/Dockerfile -t covenant-architect .    # from the repository root
docker run --rm -p 8080:8080 -e X402_MODE=mock covenant-architect       # real toolchain, mock payments

# the adapter and the HTTP app against the real toolchain (about 35 s)
TAPC_E2E_CMD="$PWD/../../chips/.venv/bin/python -m tapc.architect" TAPC_E2E_CWD="$PWD/../../chips/tools" \
  node --test test/toolchain-real.test.ts
# the toolchain's own tests, this one included (about 2.5 minutes)
cd ../../chips/tools && ../.venv/bin/python -m pytest tests/test_architect.py
```

## Versions used

| Package | Version | Role |
|---|---|---|
| `@okxweb3/x402-hono` | 0.1.1 | `paymentMiddlewareFromHTTPServer`, `x402ResourceServer`, `x402HTTPResourceServer` |
| `@okxweb3/x402-evm` | 0.2.1 | `ExactEvmScheme` from `@okxweb3/x402-evm/exact/server` |
| `@okxweb3/x402-core` | 0.1.0 | `OKXFacilitatorClient` (main entry), types from `/server` and `/types` |
| `hono` | 4.13.13 | HTTP framework, `hono/body-limit`, `hono/cors` |
| `@hono/node-server` | 2.1.3 | `serve`, `getConnInfo` |
| `viem` | 2.57.2 | address checksum, `parseUnits`, keccak256 of the stub netlist |
| `typescript` (dev) | 7.0.2 | `tsc --noEmit` only |
| Node | 26 (24+ required) | runs the `.ts` sources directly |

The three OKX packages are pinned to exact versions: they are 0.x and they move money.

## What the SDK really does (read from its published source, not from its README)

Differences from our earlier design notes are marked **differs**.

1. **differs: `syncSettle` is not a route option.** The design wrote the route as
   `{accepts: {...}}` "with `syncSettle: true`". In the SDK it is a field of `OKXConfig`:
   `new OKXFacilitatorClient({apiKey, secretKey, passphrase, baseUrl?, syncSettle?})`, and it is sent in the body
   of the settle request. Unset means OKX answers `status: "pending"` at once and the SDK delivers the resource
   on trust. This service sets it to `true` (`X402_SYNC_SETTLE`).
2. **differs: the README of x402-hono shows `new OKXFacilitatorClient()` without arguments.** The type requires the
   three credentials. The core README says the default host is `https://www.okx.com`; the code uses
   `https://web3.okx.com`. Paths: `/api/v6/pay/x402/{supported,verify,settle,settle/status}`. Requests are signed
   with HMAC-SHA256 into `OK-ACCESS-KEY / -SIGN / -TIMESTAMP / -PASSPHRASE`. No project id header.
3. **differs: the middleware starts the facilitator handshake eagerly.** `paymentMiddleware(routes, server)` calls
   `httpServer.initialize()` when it is created and keeps the promise. If OKX is unreachable at boot, that promise
   rejects before anything awaits it, which Node treats as an unhandled rejection. This service therefore uses
   `paymentMiddlewareFromHTTPServer(httpServer, undefined, undefined, false)` and does the handshake itself, with
   a 5 s pause between attempts and a 503 while it has not succeeded.
4. Confirmed: **settlement happens only after a successful handler.** After `next()`, a response status of 400 or
   more returns without settling. So a 422, 502, 503, 504 or 500 from the compile is never charged.
5. Confirmed, and worth knowing: **if settlement fails after a successful handler, the SDK replaces the response
   with a 402** (and the `PAYMENT-RESPONSE` header carries the facilitator's answer). The result is not delivered.
6. The unpaid answer is **402 with the challenge only in the `PAYMENT-REQUIRED` header**; the body is `{}`.
   A request that looks like a browser (`Accept: text/html` and a `Mozilla` user agent) gets an HTML paywall
   **without** the header. The marketplace check and every API client are not browsers, so this is left alone.
7. The payment is read from `PAYMENT-SIGNATURE`. The Hono adapter also looks at `X-PAYMENT`, but the core decodes
   only `payment-signature`, so x402 v1 clients are not served.
8. `payTo` and `price` may each be a string or a per-request function (as the design said). `price` may be
   `"$0.50"` or `{amount, asset, extra}`. This service passes the explicit form; a test pins that it equals what
   the SDK derives from `"$0.50"` on `eip155:196`: amount `500000`, asset `0x779ded0c...3736` in lowercase,
   `extra {name: "USD₮0", version: "1"}`.
9. `maxTimeoutSeconds` defaults to 300 in the core.
10. On `status: "timeout"` the SDK polls `settle/status` for 5 s and then calls the `onSettlementTimeout` hook.
    This service registers the hook: it looks in the transaction's receipt for a USDT0 `Transfer` to `PAY_TO` of
    at least the price.
11. The SDK logs with `console.warn` / `console.error`, so a few lines in the service log are not JSON.

## Decisions

- **Fail closed.** The paid route needs credentials, a payee and a real toolchain. Any of them missing: 503 with
  the reasons, no challenge. A malformed `PAY_TO` (bad checksum) is a reason too, not a crash, so the free route
  and `/healthz` stay up and say what is wrong.
- **No stub for money.** In live mode an unset `TAPC_CMD` closes the paid route. Mock mode may serve the stub.
- **An empty body is a valid request.** OKX's self-check is `curl -i -X POST <endpoint>` with no body and must get
  402, and OKX's client treats a 402 as "the endpoint accepted these parameters". So both fields default
  (`DEFAULT_PRESET`, `{}`), and only a non-empty malformed body is refused, with a 400 that describes the inputs.
- **GET is 405 with `Allow: POST`.** OKX's client probes with GET and switches to POST on a 405.
- **The 402 body is left as the SDK makes it (`{}`).** OKX's tooling is built against that; a helpful body is not
  worth the risk of being misread.
- **Lowercase asset address in the challenge**, as OKX's SDK and guide emit it.
- **Mock mode replaces only the facilitator.** The challenge is produced by the same SDK code as in production.
  It accepts one marker payload and refuses anything shaped like a real payment; its "transaction" is
  `MOCK-NOT-A-TRANSACTION-n`; every answer carries `X-Covenant-X402-Mode: mock`.
- **Toolchain isolation.** No shell; the command gets an allow-listed environment, so OKX credentials cannot reach
  it; its own process group, killed as a whole on timeout; stdout capped at 8 MiB; stderr kept for the server log
  only. A result with a failed proof is turned into a rejection even if the toolchain says `ok: true`.
- **Compile cache.** In-memory, 64 entries, keyed by sha256 of the preset and canonical-JSON params; identical
  concurrent requests share a run. Reason: a compile may take most of a minute, and a payment lives 300 s.
- **Rate limit** is a fixed one-minute window per client address, in memory. The address comes from `X-Real-IP`
  only when a proxy is trusted (default on Railway); elsewhere forwarding headers are ignored.
- **The stub is a real netlist.** 788 bytes: one latch that holds itself and 112 constant outputs (half of fresh
  tax to buy-and-lock, half to reserve, REL 2). Checked on 2026-10-04 against `chips/vendor/tap-20/reference.py`
  (loads, constant outputs, state holds), `chips/tools/tapc/netlist.py` (`check`, keccak256
  `0x69cfc16a...79d0ae`) and `chips/golden/kernel_model.py` (decodes as intended, no clamp bit under the default
  envelope). It follows the manifest shape `tapc-manifest/1`, so the web builder can be developed against it.

## Verified on 2026-10-04

- All three OKX packages exist on npm at the versions above; their `dist/` was read for every statement in the
  section "What the SDK really does".
- OKX's A2MCP guide (`web3.okx.com/onchainos/dev-docs/okxai/howtomcp`): the self-check is
  `curl -i -X POST https://your-domain/your-path`, expecting `HTTP 402 + PAYMENT-REQUIRED`; the example challenge
  uses the lowercase USDT0 address, `maxTimeoutSeconds: 300`, `extra {name: "USD₮0", version: "1"}`, and calls
  `payTo` "your real X Layer wallet".
- The proposed listing passes `onchainos agent validate-listing` (documented by the CLI as pure-local, no network):
  `{"pass": true, "findings": []}`, both when the command printed by `scripts/okx-listing.ts` is pasted into a
  shell as is and when the values are passed directly. The
  same validator rejects a service name equal to the agent name, an http or localhost endpoint, a URL in the agent
  description and a test marker in the agent name. It does **not** reject a three-line description: the server-side
  review does that.
- Locally in mock mode: `curl -i -X POST /v1/architect/chip` returns `402`, `payment-required: <base64>` and `{}`;
  a GET returns `405` with `allow: POST`.
- Railway (docs and CLI 5.54.1): `X-Real-IP` carries the client address; `RAILWAY_PUBLIC_DOMAIN` and `PORT` are
  provided; `RAILWAY_DOCKERFILE_PATH` selects a Dockerfile; config-as-code (`railway.json`) is deprecated, new
  services cannot opt in, existing ones stop being read on 2026-12-01; requests are closed after 5 minutes without
  data.
- The Docker image, built locally (Docker 29, linux/arm64) from the repository root:
  - the build context is 0.3 MB thanks to `Dockerfile.dockerignore` (58 MB without the `chips/**/build` exclusion);
  - Debian 12 does not work on arm64: the pinned `z3-solver==5.1.0.0` has an arm64 wheel only for glibc 2.38+, so
    pip tried to build z3 from source and failed. Debian 13 (`python:3.12-slim-trixie`, `node:26-trixie-slim`)
    fixes it. The x86-64 wheel (glibc 2.27+) works on either;
  - the Node binary copied into the Python image needs `libatomic1` on arm64; the Dockerfile installs it and runs
    `node --version` during the build so a broken copy fails the build, not the container;
  - `yowasp-yosys -V` takes 10 to 17 s during the build (it compiles the WebAssembly) and 0 s in the running
    container as the unprivileged user, so the baked cache is used; the cache file is 173 MB; the image is 1.04 GB;
  - `python -m tapc --version` prints `tapc 0.1.0` and `import z3` works inside the image;
  - the container, started with `X402_MODE=mock`, passes all 16 checks of `scripts/selfcheck.ts --run --mock-pay`
    from the host, a mock-paid call included; started with no variables at all, its paid route answers 503 with
    the three reasons.
- The real server over real HTTP (not only `app.request`): rate limit by socket address (ten 200s, then 429),
  413 on an oversized body, graceful stop on SIGTERM.

## The real toolchain (2026-10-06)

`chips/tools/tapc/architect.py` speaks the contract of `src/toolchain.ts`; README.md, "The real toolchain", says what
it takes and returns. The image sets `TAPC_CMD="/opt/venv/bin/python -m tapc.architect"`. Nothing in `src/` changed:
the contract did not need to.

Decisions:

- **`-m tapc.architect`, not `tapc architect`.** The subcommand needs a registration in `chips/tools/tapc/cli.py`,
  outside this work's files. The program is the same; the README says so.
- **One fixed synthesis recipe** (`rich-dc2-compress`, recorded in `chips/out/fg.manifest.json`): 1.5 s instead of
  the 5 to 7 s of the twelve-recipe portfolio, and the stock request reproduces the committed bytes. The same recipe
  reproduces `glutton.tap` too.
- **Parameters are checked twice**: restated with a path and a hint for every relation of
  `chips/rtl/gen_params.py`, then `gen_params.py`'s own `check_constraints`, `check_envelope`, `check_reference` and
  `render` run on the merged document. A test drives 3,000 random parameter sets and asserts that the second pass
  never finds anything the first missed. Constants that `gen_params.py` pins (among them `SURGE_TH`, `DD_TH`,
  `DRYN`, `CDN`, `TR_MIN`, `TR_MAX`) and those wired into the RTL's structure (`TRN`, `LEAK`) are refused with code
  `fixed` unless sent at their current value: changing them needs a change of the RTL, of `gen_params.py` or of
  the inductive invariant P4, not a parameter.
- **Proofs**: the property wrappers of `chips/props/fg_props.v` are read with the request's `fg_params.vh`, so P2
  is proven against the requested envelope; the byte-level z3 predicates (`chips/props/fg_props.py`) and the pin
  manifest generator (`chips/synth/gen_pins.py`) read the constants from the model's dictionaries, which a worker
  process updates in place for its one request. P7 (witness) is reported as `skipped`.
- **Workers are processes, one per job, each leading its own process group**, so a job past the budget is stopped
  together with its Yosys. Each worker watches its parent and stops itself if the parent disappears: the service
  kills only the toolchain's own process group after `TAPC_TIMEOUT_MS`. The image runs `tini` as PID 1, which reaps
  whatever is left.
- **A toolchain fault exits 70 with nothing on stdout** (502, not charged) instead of a rejection: a crashed solver
  or a broken installation is not the buyer's fault.

Measured on this machine (macOS 27, arm64, 10 cores; load average 3 to 5 from other work), the stock Flow Governor
request, whole command (`--budget 100`):

| Where | Workers | Wall time (runs) | P1 to P4 all proved after | EQ Yosys | EQ z3 |
|---|---|---|---|---|---|
| host | 4 | 31.1, 29.6, 29.7 s | 6.2 to 6.3 s | 3.3 to 3.7 s | 27.3 to 28.5 s |
| host | 8 | 29.9, 37.1, 30.4 s | 6.3 to 9.7 s | 3.8 to 6.5 s | 28.2 to 35.5 s |
| host, custom params (13 overrides) | 4 / 8 | 30.3, 29.9, 30.5 / 31.1, 31.8, 30.4 s | 7.2 to 8.4 s | 3.7 to 4.6 s | 27.5 to 30.1 s |
| container `--cpus 4` | 4 / 8 | 30.3, 36.3 / 30.5, 29.9 s | 5.0 to 6.5 s | 3.2 to 4.3 s | 28.5 to 34.1 s |
| container `--cpus 2` | 2 / 4 | 32.7 / 34.6 s | 4.8 / 9.5 s | 3.1 / 6.9 s | 27.8 / 31.9 s |
| container `--cpus 4`, through HTTP (`/v1/architect/compile`) | 4 | 30.8 s (a repeat is a cache hit, 5 ms) | | | |

Synthesis takes 1.5 to 1.6 s, the pin manifest 0.6 s, P5, P6 and the extras about 6 s. EQ by z3 is the critical
path; 8 workers do not beat 4, because the six other jobs are done within 10 s. Eleven extreme but valid parameter
sets (no allowance at all, the largest allowance, no ceiling, the lowest ceiling, `RC` 0 and 208, the extreme
floors and milestones, `floorRel` 1 with the longest epoch) all proved 57 of 57, except `RC` 0, where z3's EQ had no
verdict in 115 s (reported as `timeout`; EQ by Yosys proved it in seconds). Glutton: 1.8 s, 10 of 10 proved.

The image: `docker image ls` 1.04 GB (226 MB compressed), arm64, build 3.5 minutes; the build context gained
`docs/taps/assets` (the pin-manifest draft's reference implementation, which `gen_pins.py` needs). A container
uses 60 MiB idle and peaked at about 550 MiB during a compile with 4 workers (sampled every second). In the
container the stock compile gives byte for byte the committed `fg.tap`, `fg.manifest.json` and `fg.pins.json`:
Linux and macOS agree. `node scripts/selfcheck.ts http://localhost:18080 --run --mock-pay` against the container
(`X402_MODE=mock`, `--cpus 4`, nothing else set): 16 of 16 checks passed, the mock-paid call included a real
compile (31.5 s for the whole self-check).

## Not verified (needs credentials or money, so a person)

- A real settlement through OKX's facilitator. Everything from "OKX verifies" on is tested against a scripted
  facilitator only.
- That `web3.okx.com/api/v6/pay/x402/*` accepts the developer key that will be issued, and from which Railway region.
- The image on x86-64, which is what Railway builds. Only arm64 was built here. Whether the netlist bytes are the
  same on x86-64 is likely (Yosys and ABC run as one WebAssembly module) but not established.
- Compile time on Railway's vCPUs. Here: 30 to 35 s with 2 or 4 CPUs.
- That the SDK's behaviour "status 400 or more is not settled" also holds for OKX's own accounting (it must:
  no settle request is sent at all).

## Open questions for a person

1. **May `PAY_TO` be a contract?** OKX's guide says "your real X Layer wallet". USDT0's `transferWithAuthorization`
   can pay any address, but whether the facilitator and its screening accept a contract payee is unknown. Test with
   `PRICE_USD=0.01` and the contract as `PAY_TO` before relying on it. Default: the agent wallet.
2. **Must the payee be the agent's own wallet for the listing and for IGNIX's revenue ledger?** Unknown. IGNIX
   counts USDT0 sent by the OKX facilitator into the OKX.AI agent wallet (product.md, F4).
3. **Does the account's existing agent block a second ASP?** The local skill says an address may hold several ASP
   identities (only User and Evaluator are limited to one). `onchainos agent pre-check --role asp` decides.
4. **Do OKX's reviewers make a real paid call?** If so the endpoint must be live with a real toolchain throughout
   the review (up to 48 hours).
5. **How long does a real compile with proofs take on Railway?** Here 30 to 35 s on 2 or 4 CPUs, inside the 100 s
   proof budget and the 120 s `TAPC_TIMEOUT_MS`. To be measured on the deployed machine (runbook step 2).
6. **Should the listing describe the parameters?** Presets are `flow-governor` (parameters in README.md, "The real
   toolchain") and `glutton`. The listing text names `flow-governor` as the default and says `params` is an object;
   it does not list the parameter names.
7. The avatar image for the agent.

## Depends on other teams

- **Chips:** the entry point exists (`chips/tools/tapc/architect.py`). Registering it as `tapc architect` in
  `chips/tools/tapc/cli.py` is theirs. The Dockerfile copies `chips/` and `docs/taps/assets` and installs
  `chips/tools/requirements.txt`; if those move, the Dockerfile must follow. A change of the synthesis recipes,
  the RTL, `fg_params.json` or the property files changes what the service sells: rerun
  `chips/tools/tests/test_architect.py`.
- **Coordinator:** `railway.json` cannot be used by a new Railway service. Either set the service settings by hand
  (runbook) or run `railway config migrate` to produce `.railway/railway.ts`, which lives outside this directory.

## Not done

- No LLM drafting (`/v1/architect/draft`), no DSL: the plan's later stage.
- No job queue: a compile is one synchronous request.
- No persistence: the rate limiter and the cache are per process; with two replicas each counts separately.
- A buyer whose settlement succeeded but whose connection dropped gets nothing back from this service; the
  payment is on chain. There is no receipt store to replay the answer from.
