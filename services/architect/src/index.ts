// Entry point.  node src/index.ts
// Exit codes: 0 stopped, 1 runtime failure, 2 configuration error.

import { serve } from '@hono/node-server';
import { getConnInfo } from '@hono/node-server/conninfo';
import { createApp, VERSION } from './app.ts';
import { ConfigError, describe, loadConfig, secretsOf } from './config.ts';
import type { Config } from './config.ts';
import { createLogger } from './log.ts';
import type { Logger } from './log.ts';
import { createPaywall } from './paywall.ts';
import { compilePreset, toolchainMode } from './toolchain.ts';

let log: Logger = createLogger();

function main(): void {
  let config: Config;
  try {
    config = loadConfig(process.env);
  } catch (err) {
    if (err instanceof ConfigError) {
      log.error('config_error', { error: err.message });
      process.exitCode = 2;
      return;
    }
    throw err;
  }
  log = createLogger({ level: config.logLevel, secrets: secretsOf(config) });

  const paywall = createPaywall(config.paid, { log, publicBaseUrl: config.publicBaseUrl });
  const app = createApp({
    config,
    log,
    compile: (preset, params) => compilePreset(preset, params, config.toolchain),
    toolchainMode: toolchainMode(config.toolchain),
    paywall,
    socketAddress: (c) => {
      try {
        return getConnInfo(c).remote.address;
      } catch {
        return undefined;
      }
    },
  });

  const server = serve({ fetch: app.fetch, port: config.port, hostname: config.host }, (info) => {
    log.info('listening', { version: VERSION, port: info.port, host: config.host, ...describe(config) });
    if (config.paid.mode === 'mock') {
      log.warn('x402_mock_mode', { hint: 'X402_MODE=mock: the paid route takes no real payment. Never list this deployment.' });
    }
    if (config.paid.reasons.length > 0) {
      log.warn('paid_endpoint_disabled', { reasons: config.paid.reasons, hint: 'POST /v1/architect/chip answers 503 until these are fixed' });
    } else if (config.paid.mode === 'live' && !config.publicBaseUrl?.startsWith('https://')) {
      log.warn('public_base_url_missing', {
        hint: 'Set PUBLIC_BASE_URL to the public https origin: the 402 challenge must name the real endpoint URL.',
      });
    }
    if (toolchainMode(config.toolchain) === 'stub') {
      log.warn('toolchain_stub', { hint: 'TAPC_CMD is unset: /v1/architect/compile returns the fixed demo payload.' });
    }
    // Contact the facilitator now, so that /healthz and the first paid request already know the answer.
    paywall.warmUp();
  });

  server.on('error', (err: Error) => {
    log.error('listen_failed', { error: err.message });
    process.exit(1);
  });

  // One request going wrong in an unforeseen way must not take the other requests down with it.
  process.on('unhandledRejection', (reason) => {
    const e = reason instanceof Error ? reason : new Error(String(reason));
    log.error('unhandled_rejection', { error: `${e.name}: ${e.message}` });
  });

  const stop = (signal: string): void => {
    log.info('stopping', { signal });
    server.close(() => process.exit(0));
    // In-flight compiles get a moment; then leave regardless.
    setTimeout(() => process.exit(0), 10_000).unref();
  };
  process.once('SIGTERM', () => stop('SIGTERM'));
  process.once('SIGINT', () => stop('SIGINT'));
}

try {
  main();
} catch (err) {
  const e = err instanceof Error ? err : new Error(String(err));
  log.error('fatal', { error: `${e.name}: ${e.message}` });
  process.exitCode = 1;
}
