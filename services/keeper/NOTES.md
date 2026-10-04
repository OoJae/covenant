# Keeper: notes

Decisions, what was checked against the live chain, and what is still assumed. Written 2026-10-04.

## How to run

```sh
pnpm install                 # repository root
cd services/keeper
pnpm test                    # 105 tests, about 4 s
pnpm typecheck
KERNELS=0x... TANK=0x... KEEPER_ADDRESS=0x... node src/index.ts --once --dry-run
docker build -f services/keeper/Dockerfile -t covenant-keeper .   # from the repository root
```

## Decisions

- **Runtime.** TypeScript run directly by Node (type stripping, Node 24+; the machine and the image have Node 26).
  No build step, no bundler. `tsc --noEmit` is the type check. Tests use `node:test`.
- **Dependencies.** One: `viem` 2.57.2, used for ABI encoding, event decoding, transaction serialisation, the
  keccak hash and the account. The RPC transport is 150 lines of `fetch` in `src/chain.ts`, not viem's: retries,
  endpoint switching and backoff are then decided in exactly one place (`src/pool.ts`), and each node error is
  classified by us (revert, rejected transaction, endpoint fault).
- **One settle per kernel per epoch.** `sentEpoch` is written before the broadcast, in memory and in `STATE_FILE`
  (epoch and transaction hash only). After that point every path (lost response, nonce too low, revert on chain,
  dropped from the pool, process restart) leads to "already sent this epoch". The cost of this strictness: a
  transaction that is dropped costs that epoch; the next epoch is settled with DT = 2. A dry run neither reads
  nor writes the file.
- **Idempotent broadcast.** The transaction is signed once; a retry on another endpoint sends the same bytes. The
  hash is computed locally, so the receipt can be looked up even if no endpoint ever answered the broadcast.
- **One transaction in flight per wallet.** Kernels are processed one after the other and each waits for its
  receipt (60 s). A transaction still pending after `STUCK_TX_SECONDS` is replaced at the same nonce (fees +12.5%)
  by whichever settle is due next. A pending transaction the process does not know (`pending` nonce above `latest`:
  another instance, or a previous run) is waited for and then replaced the same way.
- **Simulation.** `eth_estimateGas`, then `eth_call` with the exact gas limit. The fee fields are included when the
  wallet covers `MAX_GAS_LIMIT * maxFeePerGas`, so that the tank's refund branch (which reads `tx.gasprice`) is
  exercised too. With a smaller balance the node would cap the estimate by what the balance can buy and answer
  "gas required exceeds allowance", so the fee fields are left out and the log says `feesSimulated: false`.
- **Fees.** `maxFeePerGas = min(MAX_FEE_GWEI, 2 * baseFee + tip)`; default tip 0.001 gwei, default cap 0.1 gwei.
  The tank refunds `gasUsed * min(tx.gasprice, basefee + 0.01 gwei)`, so any tip up to 0.01 gwei is fully refunded.
- **Direct fallback.** With `TANK` set, if the tank path reverts and `kernel.settle()` alone would succeed, the
  direct call is sent (unrefunded) and the log carries the tank's revert reason. Liveness is the keeper's only job;
  a tank problem should not stop settles. `DIRECT_FALLBACK=0` turns it off.
- **Backup policy.** `MIN_EPOCH_LAG=2` instead of a timer: stateless, works in a one-shot cron, and stays well under
  the chip's saturation point (the DT input saturates at 15; the variable is limited to 14).
- **The key.** Read once, removed from `process.env`, handed to viem's account, never stored in the config object.
  Every log line passes a redaction filter for the key (with and without `0x`, any letter case) and for RPC URLs
  (replaced by their host, since URLs can carry API keys). Error text from `fetch` is reduced to an error code.
  Tests never contain or generate a key: signing is replaced by serialisation with a constant dummy signature, and
  the key-format tests use values outside the valid scalar range (zero, 2^256-1).
- **Exit codes.** 2 for configuration (never retried), 1 for runtime, 0 otherwise. On Railway use "restart on
  failure, 10 retries" so a configuration error ends as a crashed service.

## Verified on 2026-10-04 (read-only JSON-RPC against rpc.xlayer.tech and xlayerrpc.okx.com)

- Both report chain id 196.
- `baseFeePerGas` is 20,000,000 wei (0.02 gwei), constant over the sampled blocks; `eth_gasPrice` 20,000,001;
  `eth_maxPriorityFeePerGas` 1 wei. Type-2 transactions are in every sampled block; tips of 0 and 1 wei are mined.
- One block per second; block gas limit 210,000,000; blocks are almost empty (gas used ratio under 1%).
- X Layer is OP-stack: each block starts with a type `0x7e` deposit, and receipts carry `l1Fee` (0 today,
  `l1BaseFeeScalar` 0). The keeper adds `l1Fee` to the reported cost.
- A reverting `eth_call` or `eth_estimateGas` answers `{"code":3,"message":"execution reverted[: reason]","data":...}`.
- `eth_call` to an address without code returns `0x` (the keeper reads an empty answer as "the address does not
  implement this function", and at start-up as a configuration error).
- `eth_estimateGas` with fee fields from an address without balance answers "gas required exceeds allowance (0)";
  `eth_call` with fee fields answers `-32003 insufficient funds for gas * price + value`.
- An unknown transaction hash gives a `null` receipt.
- End to end with the real endpoints: a contract that is not a kernel is refused with exit code 2; an address
  without code likewise; `CHAIN_ID=1` is refused; an unreachable first endpoint is skipped.

## Verified locally

- 105 tests pass (`pnpm test`), `tsc --noEmit` is clean.
- The Docker image builds from the repository root (Docker 29, linux/arm64; context under 1 kB thanks to
  `Dockerfile.dockerignore`; 503 MB). The container runs as the unprivileged `node` user, exits 2 without
  `KERNELS`, and in dry-run mode reaches the live RPC from inside the container.
- Not verified: a real signed transaction. No key was available here, by design. Signing is viem's
  `privateKeyToAccount`; everything around it (the transaction fields, the guard, the broadcast, the receipt) is
  tested with a signer that serialises with a dummy signature.

## Checked against the contract sources in this repository (2026-10-04, evening)

`contracts/issuance/src/KeeperTank.sol`, `contracts/issuance/src/interfaces/IKernelMin.sol` and
`contracts/core/src/Kernel.sol` appeared while this was being written. The keeper was aligned with them:

- `settleAndRefund(address kernel)` returns nothing, bubbles up a revert of `kernel.settle()` unchanged, and always
  emits `Refunded(uint256 indexed chipId, address indexed kernel, address indexed caller, uint256 gasUsed, uint256 paid)`.
  That signature is the default of `TANK_REFUNDED_EVENT`; `paid` is what the log line reports as `refundWei`.
  `paid` is zero when the chip's allowance or the tank is empty: the settle still happens.
- The refund is `gas * min(tx.gasprice, block.basefee + 0.01 gwei)`. The default tip of 0.001 gwei is fully covered.
- Anyone may call the tank. The keeper wallet (a declared team wallet) is refunded like any other caller, never
  more than the gas it paid.
- `remainingOf(uint256 chipId)` is read for the heartbeat (`tankRemainingWei`).
- `chipId()` is `0x0351e494` and `settle()` is `0x11da60b4`, the two selectors the tank is frozen to (a test pins them).
- `settle()` reverts with `NotBound()`, `EpochNotElapsed()`, `InsufficientGas()` or `StepFailed()`. These and the
  tank's errors are logged by name. `epochNow()` returns 0 for an unbound kernel, so such a kernel is idle.
- `minSettleGas()` already includes the 63/64 margins for the clone and for a calling contract and the transaction
  base cost; `* 1.1` on top is plain headroom.
- The first `settleAndRefund` for a chip also scans its netlist in the tank (more gas, once). The estimate covers it.

## Open assumptions

1. **Deployed bytecode equals these sources.** If the deployed tank or kernel differs, settles still work as long as
   `settle()` and `settleAndRefund(address)` exist; the event decoding degrades to `refundWei: null` /
   `record: null` with a warning, and `TANK_REFUNDED_EVENT` can be set.
2. **`pending` nonce.** Whether the public endpoints see the sequencer's pool is unknown (an idle address showed
   `pending == latest`). If they do not, the "another instance has a transaction in flight" check never triggers;
   the same-nonce rule still prevents two settles from one wallet in one block.
3. **Gas.** `minSettleGas()` is expected around 12M for a 3,400-gate chip. `MAX_GAS_LIMIT` defaults to 30M.
4. **Fees stay near today's.** Base fee 0.02 gwei; the cap defaults to 0.1 gwei.

## Not done

- The state file lives in the container's temporary directory by default. Where that does not survive (a new
  deployment, a GitHub Actions run), a process starts without the memory. Then, inside an epoch in which a
  transaction was already broadcast, that transaction is either mined and settled (nothing to do), mined and
  reverted (the new process may try once more), visible as pending (the keeper waits), or invisible (the new
  transaction carries the same nonce, so at most one of the two is mined). Two settles can never both succeed:
  the kernel reverts the second. Mount a volume and point `STATE_FILE` at it to close the remaining gap.
- No metrics endpoint. The log lines are the interface.
- Multicall batching of the reads: two `eth_call`s per kernel per poll is far below any rate limit.
- `railway.json` is Railway's deprecated per-service config format. New services do not read it (Railway docs,
  2026-10-04); it documents the intended settings and feeds `railway config migrate`. The runbook sets them by hand.
