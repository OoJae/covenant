# Covenant keeper

A small worker that keeps every Covenant kernel settled. For each kernel in `KERNELS`, once per poll:

1. read `epochNow()` and `lastEpoch()`;
2. if a new epoch is available, estimate and simulate the settle call, through `KeeperTank.settleAndRefund(kernel)`
   when `TANK` is set, else `kernel.settle()` directly;
3. send it only if the simulation succeeds, with gas limit `max(estimate * 1.25, minSettleGas() * 1.1)` and an
   EIP-1559 fee capped by `MAX_FEE_GWEI`;
4. log one JSON line with the kernel, epoch, transaction hash, gas used and the tank's refund.

Kernel v1 and kernel v2 (USD₮0 quote, `contracts/core-v2`) have the same settle surface, so `KERNELS` may list
both; `TANK` refunds each from its own chip's allowance (NOTES.md, "Kernel v2").

It is **liveness only**. `settle()` is permissionless: anyone can call it, and a kernel does the same thing whoever
calls. If this process stops, nothing is lost; the next caller settles with a larger "epochs elapsed" input.

The keeper wallet is a team wallet (`docs/WALLETS.md`; invited into the TeamRegistry, and it declares itself there
before its first settle) and this code can make it do exactly one thing: call settle. The
transaction is checked against that rule immediately before it is signed (`assertSettleOnly` in `src/tx.ts`);
anything else stops the process.

| Path | What |
|---|---|
| `src/keeper.ts` | The scheduling logic (rules listed at the top of the file) |
| `src/tx.ts` | Gas limit, fees, and the settle-only guard |
| `src/chain.ts`, `src/pool.ts` | JSON-RPC client; RPC switching and backoff |
| `src/config.ts`, `src/signer.ts` | Environment parsing; the only use of the private key |
| `src/state.ts` | The small file that remembers, across restarts, which epoch was already sent |
| `test/` | 109 tests: scheduling against a scripted chain, end-to-end runs against a local JSON-RPC server, the ABI against kernel v1's and kernel v2's sources |
| `Dockerfile`, `railway.json` | Worker image and Railway settings |
| `keeper-backup.yml.example` | GitHub Actions cron template for a backup keeper |

## Run it

Needs Node 24 or newer (the sources are TypeScript, run directly by Node's type stripping; there is no build step).

```sh
pnpm install                       # at the repository root
cd services/keeper
pnpm test                          # no network beyond 127.0.0.1, no key
pnpm typecheck

# What would it do right now? Never signs, never sends, needs no key.
KERNELS=0x... TANK=0x... KEEPER_ADDRESS=0x... node src/index.ts --once --dry-run

# One pass, for cron. Exit code 0 = nothing was left undone.
KERNELS=0x... TANK=0x... KEEPER_PRIVATE_KEY=... node src/index.ts --once

# Long-running.
KERNELS=0x... TANK=0x... KEEPER_PRIVATE_KEY=... node src/index.ts
```

Exit codes: `0` ok, `1` runtime failure (in `--once` mode: a settle was due and did not land), `2` configuration
error. A configuration error is never retried: bad or missing variables, an RPC that serves another chain, a
kernel address with no code or without `chipId()`, a tank address with no code, a key that does not belong to
`KEEPER_ADDRESS`.

## Environment

Names with empty values are in `.env.example`.

| Variable | Default | Meaning |
|---|---|---|
| `KERNELS` | required | Comma-separated kernel addresses |
| `KEEPER_PRIVATE_KEY` | required unless dry run | Secret. 64 hex characters. Deleted from the process environment after it is read; never logged |
| `TANK` | empty | KeeperTank address. Empty: call `kernel.settle()` directly, unrefunded |
| `KEEPER_ADDRESS` | empty | The declared wallet. If set, a key for any other address is refused |
| `RPC_URLS` | `https://rpc.xlayer.tech,https://xlayerrpc.okx.com` | Tried in order; on an error the next one is used |
| `CHAIN_ID` | `196` | Every reachable RPC must report it |
| `MAX_FEE_GWEI` | `0.1` | Hard cap on `maxFeePerGas`. If base fee + tip is above it, nothing is sent |
| `PRIORITY_FEE_GWEI` | `0.001` | Tip. Keep it at or below `0.001`: the tank refunds at most base fee + 0.001 gwei per gas |
| `MAX_GAS_LIMIT` | `30000000` | A larger gas limit is never signed |
| `POLL_INTERVAL_SECONDS` | `30` | Time between passes |
| `MIN_EPOCH_LAG` | `1` | Settle when `epochNow - lastEpoch` reaches this. `2` for a backup keeper. Maximum 14 |
| `DRY_RUN` / `--dry-run` | `0` | Simulate and print; never sign or send |
| `ONCE` / `--once` | `0` | One pass, then exit |
| `DIRECT_FALLBACK` | `1` | With `TANK` set: if only the tank path reverts, send `kernel.settle()` directly |
| `RECEIPT_TIMEOUT_SECONDS` | `60` | How long a pass waits for a receipt |
| `STUCK_TX_SECONDS` | `180` | An unmined transaction older than this is replaced at the same nonce by the next due settle |
| `RPC_TIMEOUT_SECONDS` | `20` | Per request |
| `MIN_BALANCE_OKB` | `0.02` | Below this the heartbeat adds a `low_balance` warning |
| `HEARTBEAT_SECONDS` | `600` | Liveness line with the wallet balance |
| `STATE_FILE` | a file in the system temp directory | Remembers the epoch and hash of each send across restarts. `none`: memory only |
| `LOG_LEVEL` | `info` | `debug` also shows idle polls |
| `TANK_REFUNDED_EVENT` | KeeperTank's `Refunded(...)` | Only for a tank that declares its refund event differently |

## What the log lines mean

One JSON object per line on stdout. Amounts are wei, as decimal strings.

| `event` | Meaning |
|---|---|
| `started`, `kernel_ok` | Configuration as understood; each kernel answered `chipId()` |
| `settle_sent` | A transaction was broadcast (`txHash`, `via`, `nonce`, `gasLimit`, fees) |
| `settled` | **The line per settle**: `kernel`, `epoch`, `txHash`, `block`, `gasUsed`, `gasCostWei`, `refundWei` (the tank's `Refunded.paid`; 0 once the chip's allowance is used up; null for a direct settle), `netCostWei`, `record`, `clampBits`, `flags`, `inflow` |
| `dry_run` | Dry-run mode: the transaction that would have been sent |
| `settle_simulation_failed` | The settle would revert right now. `reason` names the kernel's or the tank's error, for example `tank: StepFailed() \| direct: StepFailed()`. Logged once per epoch and reason; retried every poll |
| `settle_reverted` | The transaction was mined and reverted. Not retried in that epoch |
| `settle_pending`, `waiting_for_pending_tx` | A transaction is still in the pool; nothing else is sent meanwhile |
| `fee_above_cap`, `gas_above_cap`, `insufficient_balance` | Not sent, with the numbers that explain why |
| `rpc_error`, `rpc_backoff`, `rpc_unavailable` | An endpoint failed and the next one was tried; all failed and the keeper is waiting |
| `kernel_not_ready` | The kernel's views revert. Polled until they answer. (An unbound kernel answers `epochNow() = 0` and is simply idle) |
| `refund_event_not_found` | Settled through the tank, but no log matched `TANK_REFUNDED_EVENT` (the deployed tank declares the event differently) |
| `heartbeat`, `low_balance` | Every ten minutes: wallet balance, the last view of each kernel, and `tankRemainingWei`: what the tank can still refund for that chip |
| `settle_nonce_too_low`, `inflight_superseded` | The nonce was used by another transaction of the same wallet (another instance). The keeper looks for its own receipt and moves on |
| `settled_event_not_found` | The transaction succeeded but carried no `Settled` event the keeper can decode. Compare `lastEpoch()` on chain |
| `tick_failed` | A pass ended with an unexpected error. Logged; the keeper backs off and continues |
| `config_error`, `guard_violation`, `fatal` | The process is about to exit |

## Guarantees

- **At most one settle per kernel per epoch.** The epoch is recorded just before the broadcast, in memory and in
  `STATE_FILE`, so a lost response, a revert on chain, a dropped transaction or a restart of the process cannot
  lead to a second send in that epoch. A retry of the broadcast re-sends the *same signed bytes*, so it cannot
  create a second transaction. Where the file does not survive (a fresh container, a GitHub Actions run), the
  process starts without that memory; the rules below and the kernel itself (one settle per epoch, enforced on
  chain) still hold, and the worst case is one more transaction that reverts.
- **One transaction in flight per wallet.** While one is pending, later settles wait. If it is still pending after
  `STUCK_TX_SECONDS`, the next due settle reuses its nonce with fees raised by at least 12.5%, so only one of the
  two can be mined. The same applies to a pending transaction left by another instance using the same wallet.
- **Fee cap.** `maxFeePerGas = min(MAX_FEE_GWEI, 2 * baseFee + tip)`. Above the cap, nothing is sent.
- **Only settle.** Recipient must be a configured kernel (calldata exactly `settle()`) or the tank (calldata exactly
  `settleAndRefund(kernel)` for a configured kernel), value zero, chain id as configured.

What is not guaranteed: two *different* wallets racing in the same epoch both get mined, and the second one reverts
and pays for the revert. Use one wallet for the worker and the backup, or give the backup `MIN_EPOCH_LAG=2`.

## Runbook

Everything below is done by a person. Nothing here has been deployed yet (2026-10-06): the Railway service exists with no deployment, and the keeper wallet `0x7444…C4Ff` has been invited into the TeamRegistry, funded with 0.031 OKB, and has sent no transaction.

### 1. The wallet

1. Create a fresh wallet used for nothing else. Record its address in `docs/WALLETS.md`. Before it sends anything
   else, have a listed wallet call `TeamRegistry.invite(keeper)` and then call `declare("keeper")` from the keeper.
2. Fund it with OKB on X Layer. Start with **0.05 OKB** and watch the heartbeat; the plan budgets 0.15 OKB for
   keeper gas through judging with two kernels. The arithmetic (estimates until the first real settle is measured):
   - A settle of the Flow Governor is about 5.2M gas; at a 0.021 gwei effective price that is about 0.00011 OKB.
     With 900 s epochs that is 96 settles and about 0.0105 OKB a day per kernel **if nothing is refunded**:
     0.05 OKB then lasts about two days and a half for two kernels.
   - Through the tank the gas is refunded while the chip's allowance lasts, so the balance barely moves. The
     heartbeat shows what is left (`tankRemainingWei`); when it reaches zero the wallet pays in full.
     Refunds go to this wallet and never exceed the gas it paid.
   - The wallet must always hold more than `gasLimit * maxFeePerGas` for one settle (about 0.0006 OKB today).
     Below `MIN_BALANCE_OKB` (0.02) the heartbeat logs `low_balance`: about a day's notice for two kernels when
     nothing is refunded.
3. The wallet must never trade, never call IGNIX, and never send funds into a kernel. This code cannot do any of
   that; do not use the key anywhere else.

### 2. Dry run first

```sh
cd services/keeper
KERNELS=<kernel> TANK=<tank> KEEPER_ADDRESS=<wallet> node src/index.ts --once --dry-run
```

Expect `kernel_ok`, then either `idle` or a `dry_run` line with `wouldSend: true`. A `config_error` here means the
addresses are wrong. Against a fork: add `RPC_URLS=http://127.0.0.1:8545`.

### 3. Deploy the worker on Railway

Railway deprecated per-service config files (`railway.json`) on new services in 2026: a new service does not read
it. `railway.json` in this directory records the intended settings and is the input for `railway config migrate`
(which writes `.railway/railway.ts`). The steps below set the same things by hand and do not depend on either.

```sh
# from the repository root, once: railway login && railway link
railway add --service covenant-keeper
railway variable set --service covenant-keeper --skip-deploys \
  RAILWAY_DOCKERFILE_PATH=services/keeper/Dockerfile \
  KERNELS=<kernel-1>,<kernel-2> TANK=<tank> KEEPER_ADDRESS=<wallet>
railway variable set --service covenant-keeper --skip-deploys --stdin KEEPER_PRIVATE_KEY   # paste the key, then Ctrl-D
railway up --service covenant-keeper --detach        # or connect the GitHub repository instead
railway logs --service covenant-keeper
```

In the service settings:

- **Root directory**: leave empty. The Dockerfile needs the repository root as build context (the lockfile is there).
- **Replicas**: 1. Never more: two replicas would race for the same nonce.
- **Restart policy**: on failure, 10 retries. A configuration error then shows up as a crashed service instead of a loop.
- **No public domain, no healthcheck**: it is a worker and listens on nothing.
- Mark `KEEPER_PRIVATE_KEY` as sealed.

Check: `started` and `kernel_ok` in the logs, then one `settled` line per epoch per kernel, and on chain
`cast call <kernel> "lastEpoch()(uint32)" --rpc-url https://rpc.xlayer.tech`.

### 4. The backup cron (optional)

Copy `keeper-backup.yml.example` to `.github/workflows/keeper-backup.yml` and set the variables and the secret
listed at the top of that file. It runs every ten minutes with `MIN_EPOCH_LAG=2`, so it only acts after the worker
has missed a whole epoch. Trigger it by hand once with "dry run" ticked to see what it would do.

The page's "Settle now" button is the third path and needs no key of ours.

### 5. Stopping it

- Worker: `railway down --service covenant-keeper -y` (removes the running deployment), or delete the service.
  To pause without losing the logs, set `DRY_RUN=1` and redeploy.
- Backup: Actions tab, `keeper-backup`, "Disable workflow"; then delete the `KEEPER_PRIVATE_KEY` secret.
- Afterwards move the remaining OKB out of the keeper wallet by hand and stop using the key.

Stopping is safe at any moment. A transaction already broadcast still lands; one that was only signed is never sent.

### 6. When something is wrong

| Symptom | Likely cause | Action |
|---|---|---|
| Exit code 2, `config_error` | Bad variable, wrong chain, address without code | Read the message; fix the variable |
| `settle_simulation_failed` every epoch | The kernel reverts: `StepFailed()` (evaluator failure inside the grace period) | Nothing to do for the keeper. After `fallbackEpochs` the kernel applies its fallback split and settles again |
| `settle_sent` with `via: direct` and a `tankFailure` | The tank path reverts but the kernel alone would settle, for example `KernelDoesNotHoldChip()` or a wrong `TANK` | Settles continue unrefunded. Fix the cause, or clear `TANK` |
| `refundWei` is `0` | The chip's allowance in the tank is used up (`tankRemainingWei: 0` in the heartbeat) | Settles continue, paid by the wallet: keep it funded. Anyone may add to a chip's allowance with `KeeperTank.topUp(chipId)`; the keeper wallet itself never does |
| `refund_event_not_found` | The deployed tank's event differs from the one in `contracts/issuance` | Set `TANK_REFUNDED_EVENT` to its signature |
| `fee_above_cap` | Base fee rose above `MAX_FEE_GWEI` | Raise the cap if the cost is acceptable |
| `insufficient_balance`, `low_balance` | Wallet nearly empty | Fund it |
| `rpc_unavailable` repeatedly | Both public endpoints down or rate-limiting | Add another endpoint to `RPC_URLS` |
| `waiting_for_pending_tx` for minutes | A transaction is stuck | Nothing: after `STUCK_TX_SECONDS` it is replaced |

See `NOTES.md` for the decisions behind this, what was verified against the live chain, and what is still assumed.
