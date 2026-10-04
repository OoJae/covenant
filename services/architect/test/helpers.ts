// Builds the app the way src/index.ts does, from an explicit environment, without opening a port.

import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { FacilitatorClient } from '@okxweb3/x402-core/server';
import { createApp } from '../src/app.ts';
import { loadConfig, secretsOf } from '../src/config.ts';
import type { Config, Env } from '../src/config.ts';
import { createLogger } from '../src/log.ts';
import type { Logger } from '../src/log.ts';
import { decodePaymentRequired, mockPaymentHeader } from '../src/mock-facilitator.ts';
import { createPaywall } from '../src/paywall.ts';
import type { Paywall } from '../src/paywall.ts';
import { compilePreset, toolchainMode } from '../src/toolchain.ts';
import type { CompileResult } from '../src/toolchain.ts';

export const HERE = dirname(fileURLToPath(import.meta.url));
export const ROOT = join(HERE, '..');

/** TAPC_CMD that runs the fake toolchain in test/fixtures. */
export const FAKE_TAPC = `${JSON.stringify(process.execPath)} ${JSON.stringify(join(HERE, 'fixtures', 'fake-tapc.mjs'))}`;

/** A made-up payee. Not a wallet anyone here controls; nothing is ever paid in the tests. */
export const PAY_TO = '0x1111111111111111111111111111111111111111';
export const PUBLIC = 'https://architect.example';

/** Placeholders, obviously not credentials. They exist to exercise the "credentials present" branches. */
export const FAKE_OKX: Env = {
  OKX_API_KEY: 'placeholder-api-key',
  OKX_SECRET_KEY: 'placeholder-secret-key',
  OKX_PASSPHRASE: 'placeholder-passphrase',
};

export interface Harness {
  app: ReturnType<typeof createApp>;
  config: Config;
  paywall: Paywall;
  lines: Array<Record<string, unknown>>;
  log: Logger;
  compiles: Array<{ preset: string; params: Record<string, unknown> }>;
  clock: { now: () => number; advance: (ms: number) => void };
  /** POST JSON (or nothing) to a path. */
  post(path: string, body?: unknown, headers?: Record<string, string>): Promise<Response>;
  /** Unpaid request, then the same request with a mock payment built from the challenge. */
  payMock(body?: unknown, headers?: Record<string, string>): Promise<Response>;
}

export interface HarnessOptions {
  compile?: (preset: string, params: Record<string, unknown>) => Promise<CompileResult>;
  facilitator?: FacilitatorClient;
  retryAfterMs?: number;
  fetch?: typeof fetch;
}

export function harness(env: Env = {}, options: HarnessOptions = {}): Harness {
  const config = loadConfig(env);
  const lines: Array<Record<string, unknown>> = [];
  const log = createLogger({ level: 'debug', secrets: secretsOf(config), write: (l) => void lines.push(JSON.parse(l)) });
  let t = 1_800_000_000_000;
  const clock = { now: () => t, advance: (ms: number) => void (t += ms) };

  const paywall = createPaywall(config.paid, {
    log,
    publicBaseUrl: config.publicBaseUrl,
    facilitator: options.facilitator,
    retryAfterMs: options.retryAfterMs,
    fetch: options.fetch,
    now: clock.now,
    sleep: async () => {},
  });

  const compiles: Harness['compiles'] = [];
  const inner = options.compile ?? ((preset, params) => compilePreset(preset, params, config.toolchain, {}));
  const app = createApp({
    config,
    log,
    compile: (preset, params) => {
      compiles.push({ preset, params });
      return inner(preset, params);
    },
    toolchainMode: toolchainMode(config.toolchain),
    paywall,
    now: clock.now,
  });

  const post: Harness['post'] = async (path, body, headers = {}) => {
    const init: RequestInit = { method: 'POST', headers: { ...headers } };
    if (body !== undefined) {
      init.body = typeof body === 'string' ? body : JSON.stringify(body);
      (init.headers as Record<string, string>)['content-type'] ??= 'application/json';
    }
    return app.request(path, init);
  };

  const payMock: Harness['payMock'] = async (body, headers = {}) => {
    const unpaid = await post('/v1/architect/chip', body, headers);
    const challenge = unpaid.headers.get('PAYMENT-REQUIRED');
    if (unpaid.status !== 402 || !challenge) throw new Error(`expected a 402 challenge, got ${unpaid.status}`);
    return post('/v1/architect/chip', body, { ...headers, 'PAYMENT-SIGNATURE': mockPaymentHeader(challenge) });
  };

  return { app, config, paywall, lines, log, compiles, clock, post, payMock };
}

export const challengeOf = (res: Response): ReturnType<typeof decodePaymentRequired> => {
  const header = res.headers.get('PAYMENT-REQUIRED');
  if (!header) throw new Error('no PAYMENT-REQUIRED header');
  return decodePaymentRequired(header);
};

export const decodeHeader = (value: string | null): Record<string, unknown> => {
  if (!value) throw new Error('header is missing');
  return JSON.parse(Buffer.from(value, 'base64').toString('utf8')) as Record<string, unknown>;
};
