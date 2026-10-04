// Environment parsing for the Architect service.
//
// Two kinds of problem are kept apart on purpose:
//   - a malformed general setting (PORT, limits) is a ConfigError: the process exits with code 2;
//   - anything that makes the PAID route unable to sell (missing OKX credentials, missing PAY_TO, no real
//     toolchain) is collected in paid.reasons: the paid route answers 503 and everything else keeps working.

import { getAddress, isAddress, parseUnits, zeroAddress } from 'viem';
import type { Address } from 'viem';
import { isLevel } from './log.ts';
import type { Level } from './log.ts';

export class ConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ConfigError';
  }
}

export type Env = Record<string, string | undefined>;

/** X Layer mainnet, CAIP-2. */
export const NETWORK = 'eip155:196' as const;

/**
 * USDT0 on X Layer. Emitted in lowercase: that is byte for byte what OKX's seller SDK and OKX's A2MCP guide
 * put in the challenge. The checksummed form is 0x779Ded0c9e1022225f8E0630b35a9b54bE713736.
 */
export const USDT0 = {
  address: '0x779ded0c9e1022225f8e0630b35a9b54be713736',
  /** EIP-712 domain of the token, needed by the buyer to sign transferWithAuthorization. "USD₮0". */
  name: 'USD₮0',
  version: '1',
  decimals: 6,
} as const;

/** Payee used in mock mode when PAY_TO is unset. Nothing is ever paid in mock mode. */
export const MOCK_PAY_TO: Address = '0x000000000000000000000000000000000000dEaD';

export const DEFAULT_RPC_URLS = ['https://rpc.xlayer.tech', 'https://xlayerrpc.okx.com'];

export interface OkxCredentials {
  apiKey: string;
  secretKey: string;
  passphrase: string;
  baseUrl?: string;
}

export interface PaidConfig {
  mode: 'live' | 'mock';
  network: typeof NETWORK;
  asset: typeof USDT0;
  /** As configured, for display: "0.50". */
  priceUsd: string;
  /** In the token's smallest unit: "500000". */
  amount: string;
  payTo: Address | null;
  maxTimeoutSeconds: number;
  /** Ask the facilitator to wait for on-chain confirmation before the result is released. */
  syncSettle: boolean;
  /** After a "timeout" answer: how long the SDK polls the facilitator's settle status before the chain is asked. */
  settlePollMs: number;
  /** Present only in live mode with all three variables set. Never logged. */
  okx: OkxCredentials | null;
  /** Used to confirm a settlement on chain when the facilitator reports a timeout. */
  rpcUrls: string[];
  /** Why the paid route cannot sell. Empty means ready (subject to the facilitator answering). */
  reasons: string[];
}

export interface ToolchainConfig {
  /** argv of the toolchain command, or null for the stub. */
  command: string[] | null;
  timeoutMs: number;
  cwd: string | null;
  /** Unit price of a transistor in wei; only the stub uses it (a real toolchain reports its own cost). */
  transistorPriceWei: bigint;
}

export interface Config {
  port: number;
  host: string;
  /** https://host without a trailing slash, or null when unknown. */
  publicBaseUrl: string | null;
  bodyLimitBytes: number;
  freeRatePerMinute: number;
  paidRatePerMinute: number;
  /** Take the client address from the proxy's X-Real-IP header instead of the socket. */
  trustProxy: boolean;
  maxConcurrentCompiles: number;
  /** Successful compiles kept in memory, keyed by (preset, params). 0 turns the cache off. */
  compileCacheEntries: number;
  defaultPreset: string;
  /** '*' or an explicit list of allowed origins. */
  corsOrigins: '*' | string[];
  logLevel: Level;
  toolchain: ToolchainConfig;
  paid: PaidConfig;
}

const TRUE = new Set(['1', 'true', 'yes', 'on']);
const FALSE = new Set(['0', 'false', 'no', 'off']);

const get = (env: Env, name: string): string | undefined => {
  const v = env[name];
  if (v === undefined) return undefined;
  const t = v.trim();
  return t === '' ? undefined : t;
};

function integer(env: Env, name: string, fallback: number, min: number, max: number): number {
  const v = get(env, name);
  if (v === undefined) return fallback;
  if (!/^\d+$/.test(v)) throw new ConfigError(`${name}: "${v}" is not a whole number`);
  const n = Number(v);
  if (!Number.isSafeInteger(n) || n < min || n > max) throw new ConfigError(`${name}: ${v} is outside ${min}..${max}`);
  return n;
}

function bool(env: Env, name: string, fallback: boolean): boolean {
  const v = get(env, name)?.toLowerCase();
  if (v === undefined) return fallback;
  if (TRUE.has(v)) return true;
  if (FALSE.has(v)) return false;
  throw new ConfigError(`${name}: "${v}" is not a boolean (use 1 or 0)`);
}

export const PRESET_RE = /^[a-z0-9][a-z0-9_-]{0,63}$/;

/**
 * Split a command line into argv without a shell: whitespace separates, single and double quotes group,
 * backslash escapes the next character outside single quotes. No expansion of any kind.
 */
export function splitCommand(line: string): string[] {
  const out: string[] = [];
  let cur = '';
  let has = false;
  let quote: '"' | "'" | null = null;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i] as string;
    if (quote) {
      if (ch === quote) quote = null;
      else if (ch === '\\' && quote === '"' && i + 1 < line.length) cur += line[++i];
      else cur += ch;
    } else if (ch === '"' || ch === "'") {
      quote = ch;
      has = true;
    } else if (ch === '\\' && i + 1 < line.length) {
      cur += line[++i];
      has = true;
    } else if (/\s/.test(ch)) {
      if (has || cur) out.push(cur);
      cur = '';
      has = false;
    } else {
      cur += ch;
    }
  }
  if (quote) throw new ConfigError('TAPC_CMD: unterminated quote');
  if (has || cur) out.push(cur);
  return out;
}

function publicBaseUrl(env: Env): string | null {
  const explicit = get(env, 'PUBLIC_BASE_URL');
  const railway = get(env, 'RAILWAY_PUBLIC_DOMAIN');
  const raw = explicit ?? (railway ? `https://${railway}` : undefined);
  if (raw === undefined) return null;
  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    throw new ConfigError(`PUBLIC_BASE_URL: "${raw}" is not a URL`);
  }
  if (u.protocol !== 'https:' && u.protocol !== 'http:') throw new ConfigError('PUBLIC_BASE_URL must be http(s)');
  if (u.search || u.hash) throw new ConfigError('PUBLIC_BASE_URL must not carry a query string or a fragment');
  return `${u.origin}${u.pathname.replace(/\/+$/, '')}`;
}

function rpcUrls(env: Env): string[] {
  const raw = get(env, 'RPC_URLS');
  const list = (raw === undefined ? DEFAULT_RPC_URLS : raw.split(',')).map((s) => s.trim()).filter(Boolean);
  for (const u of list) {
    try {
      const p = new URL(u);
      if (p.protocol !== 'https:' && p.protocol !== 'http:') throw new Error('protocol');
    } catch {
      throw new ConfigError('RPC_URLS: every entry must be an http(s) URL');
    }
  }
  return list;
}

function paidConfig(env: Env, toolchainIsStub: boolean): PaidConfig {
  const reasons: string[] = [];

  const modeRaw = (get(env, 'X402_MODE') ?? 'live').toLowerCase();
  let mode: 'live' | 'mock' = 'live';
  if (modeRaw === 'mock') mode = 'mock';
  else if (modeRaw !== 'live') reasons.push(`X402_MODE is "${modeRaw}"; it must be "live" or "mock"`);

  const priceUsd = get(env, 'PRICE_USD') ?? '0.50';
  let amount = '0';
  if (!/^\d{1,6}(\.\d{1,6})?$/.test(priceUsd)) {
    reasons.push('PRICE_USD must be a plain decimal number with at most 6 decimals, for example 0.50');
  } else {
    amount = parseUnits(priceUsd, USDT0.decimals).toString();
    if (amount === '0') reasons.push('PRICE_USD must be greater than zero');
  }

  let payTo: Address | null = null;
  const payToRaw = get(env, 'PAY_TO');
  if (payToRaw === undefined) {
    if (mode === 'mock') payTo = MOCK_PAY_TO;
    else reasons.push('PAY_TO is not set');
  } else if (!/^0x[0-9a-fA-F]{40}$/.test(payToRaw)) {
    reasons.push('PAY_TO is not a 20-byte hex address');
  } else if (!isAddress(payToRaw)) {
    reasons.push('PAY_TO fails the EIP-55 checksum (paste the checksummed address, or the all-lowercase form)');
  } else if (getAddress(payToRaw) === zeroAddress) {
    reasons.push('PAY_TO is the zero address');
  } else {
    payTo = getAddress(payToRaw);
  }

  let okx: OkxCredentials | null = null;
  if (mode === 'live') {
    const apiKey = get(env, 'OKX_API_KEY');
    const secretKey = get(env, 'OKX_SECRET_KEY');
    const passphrase = get(env, 'OKX_PASSPHRASE');
    const missing = [
      apiKey === undefined ? 'OKX_API_KEY' : null,
      secretKey === undefined ? 'OKX_SECRET_KEY' : null,
      passphrase === undefined ? 'OKX_PASSPHRASE' : null,
    ].filter((x): x is string => x !== null);
    if (missing.length > 0) {
      reasons.push(`${missing.join(', ')} ${missing.length === 1 ? 'is' : 'are'} not set`);
    } else if (apiKey !== undefined && secretKey !== undefined && passphrase !== undefined) {
      okx = { apiKey, secretKey, passphrase };
      const baseUrl = get(env, 'OKX_BASE_URL');
      if (baseUrl !== undefined) {
        if (!/^https:\/\/[^\s/]+$/.test(baseUrl)) reasons.push('OKX_BASE_URL must look like https://host with no path');
        else okx.baseUrl = baseUrl;
      }
    }
    // Selling a fixed demo payload would be dishonest. In live mode the paid route needs the real toolchain.
    if (toolchainIsStub) reasons.push('TAPC_CMD is not set: the toolchain is a stub, and the paid route does not sell stub output');
  }

  return {
    mode,
    network: NETWORK,
    asset: USDT0,
    priceUsd,
    amount,
    payTo,
    maxTimeoutSeconds: integer(env, 'X402_MAX_TIMEOUT_SECONDS', 300, 30, 3600),
    syncSettle: bool(env, 'X402_SYNC_SETTLE', true),
    settlePollMs: integer(env, 'X402_SETTLE_POLL_MS', 5000, 0, 60_000),
    okx,
    rpcUrls: rpcUrls(env),
    reasons,
  };
}

/** The toolchain part of the environment. TAPC_CMD unset means stub mode. */
export function toolchainConfig(env: Env): ToolchainConfig {
  const tapc = get(env, 'TAPC_CMD');
  const command = tapc === undefined ? null : splitCommand(tapc);
  if (command !== null && command.length === 0) throw new ConfigError('TAPC_CMD is set but empty');

  const priceWei = get(env, 'TRANSISTOR_PRICE_WEI') ?? '20000000000000';
  if (!/^\d{1,30}$/.test(priceWei)) throw new ConfigError('TRANSISTOR_PRICE_WEI must be a whole number of wei');

  return {
    command,
    // Below the 300 s validity of an x402 payment and below Railway's 5-minute idle limit on a request.
    timeoutMs: integer(env, 'TAPC_TIMEOUT_MS', 120_000, 1000, 280_000),
    cwd: get(env, 'TAPC_CWD') ?? null,
    transistorPriceWei: BigInt(priceWei),
  };
}

export function loadConfig(env: Env): Config {
  const logLevel = get(env, 'LOG_LEVEL') ?? 'info';
  if (!isLevel(logLevel)) throw new ConfigError(`LOG_LEVEL: "${logLevel}" is not one of debug, info, warn, error`);

  const toolchain = toolchainConfig(env);

  const defaultPreset = get(env, 'DEFAULT_PRESET') ?? 'flow-governor';
  if (!PRESET_RE.test(defaultPreset)) throw new ConfigError('DEFAULT_PRESET must match [a-z0-9][a-z0-9_-]{0,63}');

  const cors = get(env, 'CORS_ORIGINS') ?? '*';
  const corsOrigins = cors === '*' ? '*' : cors.split(',').map((s) => s.trim()).filter(Boolean);

  // Railway terminates TLS at its edge and sets X-Real-IP; anywhere else the socket address is the truth.
  const onRailway = get(env, 'RAILWAY_ENVIRONMENT_NAME') !== undefined || get(env, 'RAILWAY_PROJECT_ID') !== undefined;

  return {
    port: integer(env, 'PORT', 8787, 1, 65535),
    host: get(env, 'HOST') ?? '0.0.0.0',
    publicBaseUrl: publicBaseUrl(env),
    bodyLimitBytes: integer(env, 'BODY_LIMIT_BYTES', 16_384, 256, 1_048_576),
    freeRatePerMinute: integer(env, 'RATE_LIMIT_PER_MIN', 10, 1, 100_000),
    paidRatePerMinute: integer(env, 'PAID_RATE_LIMIT_PER_MIN', 120, 1, 100_000),
    trustProxy: bool(env, 'TRUST_PROXY', onRailway),
    maxConcurrentCompiles: integer(env, 'MAX_CONCURRENT_COMPILES', 2, 1, 64),
    compileCacheEntries: integer(env, 'COMPILE_CACHE_ENTRIES', 64, 0, 10_000),
    defaultPreset,
    corsOrigins,
    logLevel,
    toolchain,
    paid: paidConfig(env, toolchain.command === null),
  };
}

/** The values that must never be printed. Passed to the logger so it can scrub them. */
export function secretsOf(config: Config): string[] {
  const o = config.paid.okx;
  return o ? [o.apiKey, o.secretKey, o.passphrase] : [];
}

/** A summary that is safe to log and to serve from /healthz. */
export function describe(config: Config): Record<string, unknown> {
  return {
    publicBaseUrl: config.publicBaseUrl,
    toolchain: config.toolchain.command === null ? 'stub' : 'cli',
    paid: {
      mode: config.paid.mode,
      configured: config.paid.reasons.length === 0,
      reasons: config.paid.reasons,
      network: config.paid.network,
      asset: config.paid.asset.address,
      priceUsd: config.paid.priceUsd,
      amount: config.paid.amount,
      payTo: config.paid.payTo,
      syncSettle: config.paid.syncSettle,
    },
    limits: {
      bodyBytes: config.bodyLimitBytes,
      freePerMinute: config.freeRatePerMinute,
      paidPerMinute: config.paidRatePerMinute,
      concurrentCompiles: config.maxConcurrentCompiles,
      compileCacheEntries: config.compileCacheEntries,
    },
  };
}
