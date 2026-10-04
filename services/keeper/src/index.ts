// Entry point.  node src/index.ts [--once] [--dry-run]
// Exit codes: 0 ok, 1 runtime failure (one-shot mode: a settle was due and did not land), 2 configuration error.

import type { Address } from 'viem';
import { makeRefundDecoder } from './abi.ts';
import { JsonRpcChainClient } from './chain.ts';
import { loadConfig, takePrivateKey } from './config.ts';
import type { Config } from './config.ts';
import { ConfigError, GuardError, RpcUnavailableError } from './errors.ts';
import { FAILED_KINDS, Keeper } from './keeper.ts';
import type { Signer } from './keeper.ts';
import { createLogger, keyRedactions, urlRedactions } from './log.ts';
import type { Logger } from './log.ts';
import { RpcPool } from './pool.ts';
import { signerFromKey } from './signer.ts';
import { fileStore, memoryStore } from './state.ts';

const USAGE = `Covenant keeper: calls settle() once per epoch for each kernel in KERNELS.

  node src/index.ts              run forever, polling every POLL_INTERVAL_SECONDS
  node src/index.ts --once       one pass over all kernels, then exit (for cron)
  node src/index.ts --dry-run    simulate and print what would be sent; never signs or sends

Environment: see .env.example. Exit codes: 0 ok, 1 runtime failure, 2 configuration error.
`;

const ZERO: Address = '0x0000000000000000000000000000000000000000';

/** Sleep that ends early when the signal aborts. */
function sleeper(signal: AbortSignal): (ms: number) => Promise<void> {
  return (ms) =>
    new Promise<void>((resolve) => {
      if (signal.aborted) return resolve();
      const timer = setTimeout(() => {
        signal.removeEventListener('abort', onAbort);
        resolve();
      }, ms);
      const onAbort = (): void => {
        clearTimeout(timer);
        resolve();
      };
      signal.addEventListener('abort', onAbort, { once: true });
    });
}

function describe(cfg: Config, from: Address, hasSigner: boolean): Record<string, unknown> {
  return {
    mode: cfg.once ? 'once' : 'loop',
    dryRun: cfg.dryRun,
    wallet: from,
    signer: hasSigner,
    chainId: cfg.chainId,
    kernels: cfg.kernels,
    tank: cfg.tank,
    via: cfg.tank ? 'tank' : 'direct',
    directFallback: cfg.tank ? cfg.directFallback : null,
    rpc: cfg.rpcUrls.map((u) => new URL(u).host),
    maxFeePerGasCapWei: cfg.maxFeePerGasCap,
    priorityFeePerGasWei: cfg.priorityFeePerGas,
    maxGasLimit: cfg.maxGasLimit,
    pollIntervalMs: cfg.pollIntervalMs,
    minEpochLag: cfg.minEpochLag,
    stuckTxMs: cfg.stuckTxMs,
    stateFile: cfg.stateFile,
  };
}

// Module-level so that the last-resort handler at the bottom writes through the same redactions.
let log: Logger = createLogger();

async function main(argv: readonly string[]): Promise<number> {
  if (argv.includes('--help') || argv.includes('-h')) {
    process.stdout.write(USAGE);
    return 0;
  }

  let cfg: Config;
  let signer: Signer | null = null;
  try {
    const key = takePrivateKey(process.env);
    cfg = loadConfig(process.env, argv);
    log = createLogger({ level: cfg.logLevel, redactions: [...keyRedactions(key), ...urlRedactions(cfg.rpcUrls)] });
    if (key) signer = signerFromKey(key);
    if (!signer && !cfg.dryRun) {
      throw new ConfigError('KEEPER_PRIVATE_KEY is required (or set DRY_RUN=1 to simulate without sending)');
    }
    if (signer && cfg.keeperAddress && signer.address.toLowerCase() !== cfg.keeperAddress.toLowerCase()) {
      throw new ConfigError(
        `KEEPER_PRIVATE_KEY belongs to ${signer.address}, but KEEPER_ADDRESS declares ${cfg.keeperAddress}`,
      );
    }
  } catch (err) {
    if (err instanceof ConfigError) {
      log.error('config_error', { error: err.message });
      return 2;
    }
    throw err;
  }

  const from: Address = signer?.address ?? cfg.keeperAddress ?? ZERO;
  if (!signer && !cfg.keeperAddress) {
    log.warn('dry_run_without_wallet', {
      hint: 'simulating from the zero address; set KEEPER_ADDRESS to simulate from the real keeper wallet',
    });
  }

  const controller = new AbortController();
  const sleep = sleeper(controller.signal);
  const stop = (signal: string): void => {
    log.info('stopping', { signal });
    controller.abort();
  };
  process.once('SIGTERM', () => stop('SIGTERM'));
  process.once('SIGINT', () => stop('SIGINT'));

  let keeper: Keeper;
  try {
    const pool = new RpcPool(
      cfg.rpcUrls.map((url) => new JsonRpcChainClient(url, { timeoutMs: cfg.rpcTimeoutMs })),
      { log, sleep },
    );
    keeper = new Keeper(
      {
        kernels: cfg.kernels,
        tank: cfg.tank,
        chainId: cfg.chainId,
        maxFeePerGasCap: cfg.maxFeePerGasCap,
        priorityFeePerGas: cfg.priorityFeePerGas,
        maxGasLimit: cfg.maxGasLimit,
        minEpochLag: cfg.minEpochLag,
        directFallback: cfg.directFallback,
        dryRun: cfg.dryRun,
        verboseIdle: cfg.once,
        receiptTimeoutMs: cfg.receiptTimeoutMs,
        receiptPollMs: cfg.receiptPollMs,
        stuckTxMs: cfg.stuckTxMs,
        minBalanceWei: cfg.minBalanceWei,
        heartbeatMs: cfg.heartbeatMs,
      },
      {
        pool,
        signer,
        from,
        log,
        now: Date.now,
        sleep,
        decodeRefund: makeRefundDecoder(cfg.refundedEvent),
        // A dry run sends nothing, so it has nothing to remember and must not be held back by an earlier run.
        store: cfg.stateFile && signer && !cfg.dryRun ? fileStore(cfg.stateFile, cfg.chainId, from) : memoryStore(),
      },
    );
  } catch (err) {
    if (err instanceof ConfigError) {
      log.error('config_error', { error: err.message });
      return 2;
    }
    throw err;
  }

  log.info('started', describe(cfg, from, signer !== null));

  // Chain-dependent configuration checks. An unreachable chain is not a configuration error: the
  // long-running mode keeps trying, the one-shot mode gives up with code 1.
  for (let attempt = 0; ; attempt++) {
    try {
      await keeper.preflight();
      break;
    } catch (err) {
      if (err instanceof ConfigError) {
        log.error('config_error', { error: err.message });
        return 2;
      }
      if (!(err instanceof RpcUnavailableError)) throw err;
      log.error('rpc_unavailable', { stage: 'preflight', error: err.message });
      if (cfg.once) return 1;
      await sleep(Math.min(300_000, cfg.pollIntervalMs * 2 ** Math.min(attempt, 4)));
      if (controller.signal.aborted) return 0;
    }
  }

  if (cfg.once) {
    const outcomes = await keeper.tick();
    await keeper.heartbeat(true);
    const failed = outcomes.filter((o) => FAILED_KINDS.has(o.kind));
    log.info('done', { outcomes: outcomes.map((o) => ({ kernel: o.kernel, kind: o.kind })), failed: failed.length });
    return failed.length > 0 ? 1 : 0;
  }

  let failures = 0;
  while (!controller.signal.aborted) {
    let failed: boolean;
    try {
      const outcomes = await keeper.tick();
      failed = outcomes.some((o) => o.kind === 'rpc_unavailable');
    } catch (err) {
      // A guard violation or a configuration error must stop the process. Anything else (an RPC answering
      // with something unexpected, say) is logged, and the keeper tries again: staying alive is its job.
      if (err instanceof GuardError || err instanceof ConfigError) throw err;
      const e = err instanceof Error ? err : new Error(String(err));
      log.error('tick_failed', { error: `${e.name}: ${e.message}` });
      failed = true;
    }
    failures = failed ? failures + 1 : 0;
    if (!failed) await keeper.heartbeat();
    // Back off between passes while something is wrong: 2x, 4x ... the poll interval, capped at five minutes.
    const delay = failed ? Math.min(300_000, cfg.pollIntervalMs * 2 ** Math.min(failures, 5)) : cfg.pollIntervalMs;
    await sleep(delay);
  }
  log.info('stopped', {});
  return 0;
}

/** Let stdout drain, then make sure nothing (an idle socket, a stray timer) keeps the process alive. */
function finish(code: number): void {
  process.exitCode = code;
  setTimeout(() => process.exit(code), 2000).unref();
}

main(process.argv.slice(2)).then(finish, (err: unknown) => {
  // Last resort. Name and message only; GuardError and anything unexpected end the process.
  const e = err instanceof Error ? err : new Error(String(err));
  log.error(e instanceof GuardError ? 'guard_violation' : 'fatal', { error: `${e.name}: ${e.message}` });
  finish(1);
});
