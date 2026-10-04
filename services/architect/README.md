# Covenant Architect

The "compile a vault chip" service: a preset name and its parameters go in, a TAP-20 netlist with its pin
manifest, proof results and cost comes out. It is the product listed on OKX.AI, paid per call with x402.

| Endpoint | Price | What it does |
|---|---|---|
| `GET /healthz` | free | Liveness, and what is configured (never a secret) |
| `POST /v1/architect/compile` | free | Compile. Rate-limited per client address, small body. Used by the builder page |
| `POST /v1/architect/chip` | 0.50 USDT0 | The same compile behind an x402 paywall (OKX seller SDK, USDT0 on X Layer) |

It is thin on purpose. The HTTP layer, the paywall and the limits are finished and tested; the chip toolchain is
reached through one adapter function, `compilePreset(preset, params)` in `src/toolchain.ts`.

**State today.** The toolchain entry point this service needs does not exist yet, so `TAPC_CMD` is unset and the
service runs in **stub mode**: the free route returns a fixed demo payload marked `stub: true`, and the paid route is
closed (503), because selling a fixed payload would be dishonest. Nothing has been deployed and no OKX.AI agent has
been registered. What a person has to do is in the runbook below.

| Path | What |
|---|---|
| `src/app.ts` | Routes and their order (limits, validation, paywall, handler) |
| `src/paywall.ts` | x402 wiring on OKX's SDK; fail-closed guard; settlement-timeout check on chain |
| `src/mock-facilitator.ts` | `X402_MODE=mock`: an in-process facilitator, for tests and local runs |
| `src/toolchain.ts` | **The adapter and the CLI contract** for the chip toolchain |
| `src/stub.ts` | The fixed demo payload (a real, tiny TAP-20 netlist) |
| `src/config.ts`, `src/request.ts`, `src/ratelimit.ts`, `src/cache.ts` | Environment, request validation, limiter, compile cache |
| `scripts/selfcheck.ts` | Prints (and can run) the curl self-check of OKX's A2MCP guide |
| `scripts/okx-listing.ts` | Prints the `onchainos agent ...` registration commands with the service JSON filled in |
| `test/` | 86 tests. Nothing in them contacts OKX or X Layer |

## Run it

Needs Node 24 or newer (TypeScript sources run directly; there is no build step).

```sh
pnpm install                         # at the repository root
cd services/architect
pnpm test && pnpm typecheck

X402_MODE=mock node src/index.ts     # http://localhost:8787, stub toolchain, mock payments
node scripts/selfcheck.ts http://localhost:8787 --run --mock-pay
```

```sh
curl -s localhost:8787/healthz
curl -s -X POST localhost:8787/v1/architect/compile -H 'Content-Type: application/json' \
  -d '{"preset":"flow-governor","params":{}}'
curl -i -X POST localhost:8787/v1/architect/chip          # 402 + PAYMENT-REQUIRED
```

## The request and the answers

Both compile routes take the same JSON body. Both fields are optional:

```json
{ "preset": "flow-governor", "params": { } }
```

- `preset`: lowercase name, `[a-z0-9][a-z0-9_-]{0,63}`. Default: `DEFAULT_PRESET` (`flow-governor`).
- `params`: a JSON object, or JSON text of one (some clients can only send strings). Default `{}`. At most 500
  values, 8 levels deep. The toolchain validates the fields of each preset.
- Any other field is a 400.

An empty body is a valid request for the default preset. That is deliberate: OKX's marketplace self-check is a bare
`curl -i -X POST <endpoint>` and must receive the 402 challenge.

| Status | When | Charged on the paid route |
|---|---|---|
| 200 | `{netlistHex, manifest, proofs, cost}` (plus `stub: true` in stub mode) | **yes**, after this answer exists |
| 400 | Body is not JSON, not an object, has an unknown field, a bad `preset` or bad `params` | no (refused before the challenge) |
| 402 | Paid route: no payment, payment refused, or settlement failed after a successful compile | no |
| 405 | Not a POST. Carries `Allow: POST` | no |
| 413 | Body larger than `BODY_LIMIT_BYTES` | no |
| 422 | The toolchain rejected the request, or a proof failed. Body: `error.code`, `stage`, `diagnostics`, `proofs` | no |
| 429 | Rate limit. Carries `Retry-After` | no |
| 502 / 504 | The toolchain crashed, printed garbage, or timed out | no |
| 503 | Compiler busy; or the paid route is not configured; or the facilitator is unreachable | no |

Response headers: `X-Covenant-Toolchain: stub|cli`, `X-Covenant-Cache: hit|miss`, `RateLimit-*`, and on the paid
route `X-Covenant-X402-Mode: live|mock`, `PAYMENT-REQUIRED` (402) and `PAYMENT-RESPONSE` (after settlement).

Successful compiles are cached in memory by `(preset, params)`, and identical requests that arrive together share
one toolchain run. A paid request served from the cache is settled like any other.

## The paywall

Built on OKX's seller SDK: `@okxweb3/x402-hono` 0.1.1, `@okxweb3/x402-evm` 0.2.1 (exact scheme),
`@okxweb3/x402-core` 0.1.0 (`OKXFacilitatorClient`). Network `eip155:196`, asset USDT0
`0x779ded0c9e1022225f8e0630b35a9b54be713736` (emitted in lowercase, as OKX's SDK and guide do), price from
`PRICE_USD`, payee from `PAY_TO`.

What happens to a request to `POST /v1/architect/chip`:

1. **Can the route sell?** It needs `OKX_API_KEY`, `OKX_SECRET_KEY`, `OKX_PASSPHRASE`, `PAY_TO` and a real toolchain
   (`TAPC_CMD`), and OKX's facilitator must have answered. Otherwise: **503** with the reasons (variable names only).
   No challenge is issued by a server that could not settle.
2. Rate limit, body limit, body validation (400 before any payment is asked for).
3. **No `PAYMENT-SIGNATURE` header: 402.** The challenge is base64 JSON in the `PAYMENT-REQUIRED` header; the body
   is `{}`. Decoded:
   ```json
   { "x402Version": 2, "error": "Payment required",
     "resource": { "url": "https://<host>/v1/architect/chip", "description": "...", "mimeType": "application/json" },
     "accepts": [ { "scheme": "exact", "network": "eip155:196", "amount": "500000",
                    "asset": "0x779ded0c9e1022225f8e0630b35a9b54be713736", "payTo": "<PAY_TO>",
                    "maxTimeoutSeconds": 300, "extra": { "name": "USD₮0", "version": "1" } } ] }
   ```
4. Header present: OKX verifies the payment; then the compile runs.
5. **The compile failed (any status of 400 or more): nothing is settled.** The buyer's authorisation is simply never used.
6. The compile succeeded: OKX settles (`syncSettle`: it waits for the transfer to be mined). On success the answer
   carries `PAYMENT-RESPONSE`. If settlement fails the result is withheld and the answer is 402.
7. If OKX answers "timeout", the service looks for the USDT0 transfer to `PAY_TO` in the transaction's receipt on
   X Layer before refusing the buyer.

**Mock mode** (`X402_MODE=mock`) replaces only the facilitator: OKX's SDK still builds the challenge and runs the same
flow, but verification and settlement happen in this process and nothing touches OKX or the chain. It accepts only
the payment that `mockPaymentHeader()` builds and refuses real signed payments, so a mock server can never look paid.
Every answer of the paid route carries `X-Covenant-X402-Mode`. Never list a deployment that says `mock`.

## The toolchain contract

For the chips team. The full text is at the top of `src/toolchain.ts`; in short:

- `TAPC_CMD` is the complete command, for example `python -m tapc architect`. It is run once per request, without a
  shell and without extra arguments.
- **stdin**: `{"protocol":"covenant-architect/1","op":"compile","preset":"...","params":{...}}`
- **stdout**: exactly one JSON object.
  - success: `{"ok":true,"netlistHex":"0x...","manifest":{...},"proofs":[{"id","status","detail"}],"cost":{...}}`
  - rejection: `{"ok":false,"error":{"code","message","stage","diagnostics":[{"code","path","message","hint"}]}}`
- `ok:true` means compiled **and** every required proof holds. A proof with `status: "failed"` turns the answer into
  a rejection whatever `ok` says.
- Logs go to **stderr**. Exit 0 on success. Anything unparseable or a crash is a toolchain fault (502).
- The netlist may be at most 24,000 bytes; the run is killed after `TAPC_TIMEOUT_MS` (120 s by default, 280 s at most).
- The command sees `PATH`, `HOME`, `LANG`, `LC_ALL`, `TZ`, `TMPDIR`, `VIRTUAL_ENV`, `PYTHONPATH`, `PYTHONUNBUFFERED`,
  `YOWASP_CACHE_DIR`, `YOWASP_MOUNT` and `TAPC_*`. No credential of the service reaches it.

`tapc` today has `synth`, `pack`, `prove`, `sim`, `info`, `difftest` and `fork-tapeout`, but no entry point that
takes a preset and parameters and prints this JSON. That entry point (`tapc architect`, or a wrapper script) is the
one missing piece. `test/fixtures/fake-tapc.mjs` is a 60-line example of a program that satisfies the contract.

## Environment

Names with empty values are in `.env.example`.

| Variable | Default | Meaning |
|---|---|---|
| `OKX_API_KEY`, `OKX_SECRET_KEY`, `OKX_PASSPHRASE` | none | Secrets. Sign the calls to OKX's x402 facilitator. Required for the paid route |
| `PAY_TO` | none | X Layer address that receives the USDT0. Required for the paid route |
| `PUBLIC_BASE_URL` | `https://$RAILWAY_PUBLIC_DOMAIN` | Public https origin. The challenge's `resource.url` is built from it |
| `TAPC_CMD` | unset (stub) | The toolchain command. Required for the paid route |
| `PRICE_USD` | `0.50` | Price per call, at most 6 decimals. Must equal the OKX.AI listing fee |
| `X402_MODE` | `live` | `mock` for local tests |
| `X402_SYNC_SETTLE` | `1` | Wait for the transfer to be mined before releasing the result |
| `X402_MAX_TIMEOUT_SECONDS` | `300` | Validity of a payment authorisation |
| `X402_SETTLE_POLL_MS` | `5000` | After a facilitator "timeout": how long its status is polled before the chain is asked |
| `OKX_BASE_URL` | SDK default `https://web3.okx.com` | Facilitator host |
| `RPC_URLS` | the two public X Layer endpoints | Only for the settlement-timeout check |
| `PORT`, `HOST` | `8787` (`8080` in the image), `0.0.0.0` | Listener |
| `RATE_LIMIT_PER_MIN` | `10` | Free route, per client address |
| `PAID_RATE_LIMIT_PER_MIN` | `120` | Paid route, per client address |
| `BODY_LIMIT_BYTES` | `16384` | Largest request body |
| `MAX_CONCURRENT_COMPILES` | `2` | Toolchain runs at once; beyond that, 503 `busy` |
| `COMPILE_CACHE_ENTRIES` | `64` | Compiles kept in memory. `0` turns the cache off |
| `TRUST_PROXY` | `1` on Railway, else `0` | Take the client address from `X-Real-IP` |
| `DEFAULT_PRESET` | `flow-governor` | Preset used when the request names none |
| `CORS_ORIGINS` | `*` | Allowed browser origins |
| `TAPC_TIMEOUT_MS`, `TAPC_CWD` | `120000`, the service's directory | Toolchain time limit and working directory |
| `YOWASP_CACHE_DIR` | `/var/cache/yowasp` in the image | Where yowasp-yosys keeps its compiled WebAssembly |
| `TRANSISTOR_PRICE_WEI` | `20000000000000` | Only for the stub's cost figure |
| `LOG_LEVEL` | `info` | |

A malformed general setting (`PORT`, a limit) stops the process with exit code 2. A problem with the paid
configuration never does: the paid route answers 503 and names it, and `/healthz` shows it under `paid.reasons`.

## Runbook

Everything below is done by a person. Nothing here has been deployed, no secret has been entered, and no
`onchainos` command that logs in, creates, signs or pays has been run.

### 1. Deploy on Railway

Railway deprecated per-service config files (`railway.json`) for new services in 2026: a new service does not read
it. The file in this directory records the intended settings and is the input for `railway config migrate`. The
commands below set the same things by hand.

```sh
# from the repository root, once: railway login && railway link
railway add --service covenant-architect
railway variable set --service covenant-architect --skip-deploys \
  RAILWAY_DOCKERFILE_PATH=services/architect/Dockerfile PORT=8080
railway domain --service covenant-architect --port 8080      # prints https://<name>.up.railway.app
railway up --service covenant-architect --detach              # or connect the GitHub repository instead
railway logs --service covenant-architect
```

In the service settings:

- **Root directory**: leave empty. The Dockerfile needs the repository root as build context (lockfile and `chips/`).
- **Healthcheck path** `/healthz`, **restart policy** on failure.
- **Replicas**: 1. The rate limiter and the compile cache live in the process.
- **Region**: one that can reach `web3.okx.com`. Singapore or a US region; this is checked in step 3.

The image installs Python 3.12 and the toolchain's pinned requirements (`chips/tools/requirements.txt`), and compiles
yowasp-yosys' WebAssembly once at build time into `YOWASP_CACHE_DIR=/var/cache/yowasp`, so no request pays for that.
If the first compile after every deploy is about a minute slower than the ones after it, the machine could not load
the code compiled at build time and yowasp recompiled it; attach a volume at `/var/cache/yowasp` so the recompiled
cache survives deploys (`railway volume add --service covenant-architect --mount-path /var/cache/yowasp`). A Railway
volume is owned by root while the image runs as an unprivileged user, so also set `RAILWAY_RUN_UID=0` in that case.

At this point: `curl https://<host>/healthz` shows `toolchain.mode: "stub"` and `paid.ready: false` with the reasons,
the free route answers with the stub, and the paid route answers 503.

### 2. Wire the toolchain

When the chips team ships the entry point (see "The toolchain contract"):

```sh
railway variable set --service covenant-architect TAPC_CMD='python -m tapc architect'
```

(`PYTHONPATH=/app/chips/tools` and the virtualenv are already set in the image.) Check `toolchain.mode: "cli"` in
`/healthz` and time one compile of the largest preset. It has to finish well inside `TAPC_TIMEOUT_MS`; a payment is
valid for 300 s and Railway closes a request that sends nothing for 5 minutes.

### 3. Set the secrets and the payee

```sh
railway variable set --service covenant-architect --skip-deploys --stdin OKX_API_KEY      # paste, Ctrl-D
railway variable set --service covenant-architect --skip-deploys --stdin OKX_SECRET_KEY
railway variable set --service covenant-architect --skip-deploys --stdin OKX_PASSPHRASE
railway variable set --service covenant-architect PAY_TO=<address> PRICE_USD=0.50
```

Mark the three OKX variables as sealed. `PAY_TO`:

- For self-tests use a **throwaway address labelled TEST**; those payments are never counted as revenue.
- For the listing, the plan's default is the OKX.AI agent wallet (`onchainos wallet addresses`, X Layer). Whether a
  contract (the Revenue Covenant inbox) is accepted as payee is an open question: test it with a 0.01 price first.

`/healthz` must now show `paid.mode: "live"`, `paid.ready: true`, `paid.facilitator: "ok"`. If it shows
`"unavailable"`, the log line `paywall_facilitator_unavailable` has OKX's answer (wrong key, wrong passphrase, or the
region cannot reach OKX).

### 4. Check the 402

```sh
node scripts/selfcheck.ts https://<host>                # prints the curl commands
PAY_TO=<address> PRICE_USD=0.50 node scripts/selfcheck.ts https://<host> --run
```

The first line of OKX's guide is the one that matters:

```sh
curl -i -X POST https://<host>/v1/architect/chip
# expected: HTTP 402 and a "payment-required: <base64>" header
```

`--run` also decodes the challenge and compares scheme, network, asset, amount, payee, token domain and
`resource.url`. All lines must say PASS before the listing is submitted.

### 5. One real paid call (optional, costs the price)

With `PAY_TO` set to the TEST address, from a terminal with a funded Agentic Wallet. These spend real USDT0:

```sh
onchainos payment quote https://<host>/v1/architect/chip --method POST --param preset=flow-governor
onchainos payment pay --payment-id <id from the quote> --yes
```

Expect `status: success` and a transaction hash; find the USDT0 transfer to `PAY_TO` on OKLink. Then call it once
with a preset that fails and confirm that the buyer's balance did not change.

### 6. Register the OKX.AI agent service

Print the commands with the service JSON for the real endpoint, then run them yourself:

```sh
node scripts/okx-listing.ts https://<host> --avatar ./avatar.png
```

It prints the following, with `<host>` replaced by the real host. These are the commands from the local okx-ai skill
(`references/identity/register.md`, `validate.md`, `listing.md`). **A person runs them; nothing here was run for you.**

```sh
# OKX.AI registration for https://<host>/v1/architect/chip
# Run these yourself, in order, from a terminal where `onchainos wallet status` shows the wallet that should
# own the agent. Nothing below has been run for you.

# 0. The endpoint must already answer 402 (see: node scripts/selfcheck.ts https://<host> --run)

# 1. Pre-check. Read canCreate. If "consent" comes back, read the terms and re-run with the key it gives you.
onchainos agent pre-check --role asp
# onchainos agent pre-check --role asp --consent-key <consentKey from the first call>

# 2. Upload the avatar (PNG, JPEG or WebP, at most 1 MB). Keep the "url" it returns.
onchainos agent upload --file './avatar.png'

# 3. Validate the listing locally (no network). Expect {"pass": true, "findings": []}.
onchainos agent validate-listing --role asp \
  --name 'Covenant Architect' \
  --description 'Covenant Architect compiles vault chips for IGNIX tokens on X Layer: tax-routing circuits anyone can read and nobody can change, delivered as TapeOut netlists with a pin manifest, proofs and a cost quote.' \
  --service '[{"serviceName":"Vault Chip Compiler","serviceDescription":"1. [Service Description] Compiles a Covenant vault chip preset for an IGNIX token into a TapeOut TAP-20 netlist and returns JSON with netlistHex, the pin manifest, proof results and the tape-out cost.\n2. [Parameter Spec] preset(string, optional): vault chip preset name, default flow-governor; params(object, optional): preset parameters as a JSON object, default {}\n3. [Request Method] POST\n4. [Request Example] curl -X POST https://<host>/v1/architect/chip -H \"Content-Type: application/json\" -d '\''{\"preset\":\"flow-governor\",\"params\":{}}'\''","serviceType":"A2MCP","fee":"0.5","endpoint":"https://<host>/v1/architect/chip"}]'

# 4. Create the agent. Replace <avatar url> with the url from step 2. Keep the newAgentId it returns.
onchainos agent create --role asp \
  --name 'Covenant Architect' \
  --description 'Covenant Architect compiles vault chips for IGNIX tokens on X Layer: tax-routing circuits anyone can read and nobody can change, delivered as TapeOut netlists with a pin manifest, proofs and a cost quote.' \
  --picture '<avatar url>' \
  --service '[{"serviceName":"Vault Chip Compiler","serviceDescription":"1. [Service Description] Compiles a Covenant vault chip preset for an IGNIX token into a TapeOut TAP-20 netlist and returns JSON with netlistHex, the pin manifest, proof results and the tape-out cost.\n2. [Parameter Spec] preset(string, optional): vault chip preset name, default flow-governor; params(object, optional): preset parameters as a JSON object, default {}\n3. [Request Method] POST\n4. [Request Example] curl -X POST https://<host>/v1/architect/chip -H \"Content-Type: application/json\" -d '\''{\"preset\":\"flow-governor\",\"params\":{}}'\''","serviceType":"A2MCP","fee":"0.5","endpoint":"https://<host>/v1/architect/chip"}]'

# 5. Submit for listing review (usually within 48 hours; watch the linked email). Keep the endpoint up meanwhile.
onchainos agent activate --agent-id <newAgentId> --preferred-language en-US
```

Proposed values (all of them are suggestions; change them in `src/listing.ts`):

| Field | Value |
|---|---|
| name | `Covenant Architect` |
| description | Covenant Architect compiles vault chips for IGNIX tokens on X Layer: tax-routing circuits anyone can read and nobody can change, delivered as TapeOut netlists with a pin manifest, proofs and a cost quote. |
| picture | an avatar you supply (PNG, JPEG or WebP, at most 1 MB), uploaded with `agent upload` |
| serviceType | `A2MCP` |
| serviceName | `Vault Chip Compiler` |
| fee | `0.5` (must equal `PRICE_USD`) |
| endpoint | `https://<host>/v1/architect/chip` |
| serviceDescription | four numbered lines, below |

```text
1. [Service Description] Compiles a Covenant vault chip preset for an IGNIX token into a TapeOut TAP-20 netlist and returns JSON with netlistHex, the pin manifest, proof results and the tape-out cost.
2. [Parameter Spec] preset(string, optional): vault chip preset name, default flow-governor; params(object, optional): preset parameters as a JSON object, default {}
3. [Request Method] POST
4. [Request Example] curl -X POST https://<host>/v1/architect/chip -H "Content-Type: application/json" -d '{"preset":"flow-governor","params":{}}'
```

Notes:

- `pre-check` decides whether the wallet may create the agent (`canCreate`). The skill document says an address may
  hold several ASP identities, so the existing agent should not block this one; `pre-check` is the authority.
- `validate-listing` is local and was run on these exact values with a Railway-shaped host: `pass: true`, no findings.
  The server-side review can still reject.
- Review usually takes up to 48 hours. The endpoint must stay up, in live mode, with a real toolchain, the whole time.
- After registration the skill sets up the A2A communication runtime (`okx-a2a doctor --fix`).
- If the endpoint URL or the price changes later: `onchainos agent update --agent-id <id> --service '[{"operation":"update","id":"<service id>", ...}]'`.

### 7. Stopping

`railway down --service covenant-architect -y` removes the running deployment. To close only the paid route, unset
`PAY_TO` and redeploy: it answers 503 at once. To take the listing down: `onchainos agent deactivate --agent-id <id>`.

### When something is wrong

| Symptom | Cause | Action |
|---|---|---|
| Paid route 503 `paid_endpoint_unavailable` | A variable is missing or malformed | The answer and `/healthz` list the reasons |
| Paid route 503 `facilitator_unavailable` | OKX refused the credentials or is unreachable | Log line `paywall_facilitator_unavailable`; retried every 5 s on demand |
| 402 but `resource.url` starts with `http://` | `PUBLIC_BASE_URL` is unset outside Railway | Set it to the public https origin |
| 502 `toolchain_spawn` | `TAPC_CMD` does not start | Check the command inside the container |
| 502 `toolchain_bad_output` | The toolchain printed something else on stdout | Logs belong on stderr; see the contract |
| 504 `toolchain_timeout` | Compile slower than `TAPC_TIMEOUT_MS` | Raise it (at most 280000), or precompute |
| 503 `busy` | `MAX_CONCURRENT_COMPILES` runs in progress | Retry; raise the limit if the machine has the cores |
| Buyer was refused with 402 after paying | Settlement failed or timed out | Log lines `payment_settle_failed`, `payment_settlement_timeout` carry the transaction |

See `NOTES.md` for the decisions, the SDK details that differ from the design document, and the open questions.
