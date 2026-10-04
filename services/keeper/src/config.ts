// Environment and flag parsing. Anything wrong here is a ConfigError, and the process exits with code 2.

import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { getAddress, isAddress, parseEther, parseGwei, zeroAddress } from 'viem';
import type { Address, Hex } from 'viem';
import { ConfigError } from './errors.ts';
import { isLevel } from './log.ts';
import type { Level } from './log.ts';

export const DEFAULT_RPC_URLS = ['https://rpc.xlayer.tech', 'https://xlayerrpc.okx.com'];

/**
 * The event KeeperTank emits on every settleAndRefund (contracts/issuance/src/KeeperTank.sol). `paid` is the
 * refund in wei; it is zero once the chip's allowance or the tank is empty.
 * TANK_REFUNDED_EVENT overrides it for a tank that declares the event differently; the refund is then read
 * from the argument named `paid` (or `amount`, `refund`, `refunded`, `value`), else from the last uint argument.
 */
export const DEFAULT_REFUNDED_EVENT =
  'event Refunded(uint256 indexed chipId, address indexed kernel, address indexed caller, uint256 gasUsed, uint256 paid)';

export interface Config {
  kernels: Address[];
  tank: Address | null;
  rpcUrls: string[];
  chainId: number;
  /** Upper bound on maxFeePerGas, in wei. */
  maxFeePerGasCap: bigint;
  /** Tip, in wei. Keep it at or below 0.01 gwei: the tank refunds at most basefee + 0.01 gwei per gas. */
  priorityFeePerGas: bigint;
  /** Never sign a transaction with a gas limit above this. */
  maxGasLimit: bigint;
  pollIntervalMs: number;
  /** Settle only when epochNow - lastEpoch is at least this. 1 for the primary keeper, 2 for a backup. */
  minEpochLag: number;
  /** How long one pass waits for a receipt before moving on. */
  receiptTimeoutMs: number;
  receiptPollMs: number;
  /** An unmined transaction older than this is replaced at the same nonce (never within the same epoch). */
  stuckTxMs: number;
  rpcTimeoutMs: number;
  heartbeatMs: number;
  /** With TANK set: if the tank path reverts but a direct settle() would succeed, send the direct call. */
  directFallback: boolean;
  dryRun: boolean;
  once: boolean;
  /** Log a warning when the wallet holds less than this, in wei. */
  minBalanceWei: bigint;
  logLevel: Level;
  /** The declared keeper wallet. If set together with the key, they must match. */
  keeperAddress: Address | null;
  refundedEvent: string;
  /** File that remembers the send of each epoch across restarts, or null for memory only. */
  stateFile: string | null;
}

export type Env = Record<string, string | undefined>;

const TRUE = new Set(['1', 'true', 'yes', 'on']);
const FALSE = new Set(['0', 'false', 'no', 'off', '']);

const get = (env: Env, name: string): string | undefined => {
  const v = env[name];
  if (v === undefined) return undefined;
  const t = v.trim();
  return t === '' ? undefined : t;
};

export function parseAddress(name: string, value: string): Address {
  if (!/^0x[0-9a-fA-F]{40}$/.test(value)) {
    throw new ConfigError(`${name}: "${value}" is not a 20-byte hex address`);
  }
  if (!isAddress(value)) {
    throw new ConfigError(
      `${name}: "${value}" fails the EIP-55 checksum. Paste the checksummed address, or the all-lowercase form.`,
    );
  }
  const address = getAddress(value);
  if (address === zeroAddress) throw new ConfigError(`${name}: the zero address is not allowed`);
  return address;
}

function parseBool(name: string, value: string | undefined, fallback: boolean): boolean {
  if (value === undefined) return fallback;
  const v = value.toLowerCase();
  if (TRUE.has(v)) return true;
  if (FALSE.has(v)) return false;
  throw new ConfigError(`${name}: "${value}" is not a boolean (use 1 or 0)`);
}

function parseInteger(name: string, value: string | undefined, fallback: number, min: number, max: number): number {
  if (value === undefined) return fallback;
  if (!/^\d+$/.test(value)) throw new ConfigError(`${name}: "${value}" is not a whole number`);
  const n = Number(value);
  if (!Number.isSafeInteger(n) || n < min || n > max) {
    throw new ConfigError(`${name}: ${value} is outside ${min}..${max}`);
  }
  return n;
}

function parseGweiValue(name: string, value: string | undefined, fallback: string, allowZero: boolean): bigint {
  const v = value ?? fallback;
  if (!/^\d+(\.\d{1,9})?$/.test(v)) {
    throw new ConfigError(`${name}: "${v}" is not a gwei amount (digits, at most 9 decimals)`);
  }
  const wei = parseGwei(v);
  if (wei === 0n && !allowZero) throw new ConfigError(`${name}: must be greater than zero`);
  return wei;
}

function parseOkbValue(name: string, value: string | undefined, fallback: string): bigint {
  const v = value ?? fallback;
  if (!/^\d+(\.\d{1,18})?$/.test(v)) {
    throw new ConfigError(`${name}: "${v}" is not an OKB amount (digits, at most 18 decimals)`);
  }
  return parseEther(v);
}

function parseRpcUrls(value: string | undefined): string[] {
  const list = (value === undefined ? DEFAULT_RPC_URLS : value.split(',')).map((s) => s.trim()).filter(Boolean);
  if (list.length === 0) throw new ConfigError('RPC_URLS: no URL given');
  const seen = new Set<string>();
  for (const u of list) {
    let parsed: URL;
    try {
      parsed = new URL(u);
    } catch {
      throw new ConfigError(`RPC_URLS: an entry is not a valid URL (host shown only if parseable)`);
    }
    if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') {
      throw new ConfigError(`RPC_URLS: ${parsed.host} must use http or https`);
    }
    if (seen.has(u)) throw new ConfigError(`RPC_URLS: ${parsed.host} is listed twice`);
    seen.add(u);
  }
  return list;
}

const FLAGS = new Set(['--once', '--dry-run', '--help', '-h']);

export function loadConfig(env: Env, argv: readonly string[]): Config {
  for (const arg of argv) {
    if (!FLAGS.has(arg)) throw new ConfigError(`unknown argument "${arg}" (known: --once, --dry-run, --help)`);
  }

  const kernelsRaw = get(env, 'KERNELS');
  if (kernelsRaw === undefined) {
    throw new ConfigError('KERNELS is required: a comma-separated list of kernel addresses');
  }
  const kernels: Address[] = [];
  for (const [i, part] of kernelsRaw.split(',').entries()) {
    const p = part.trim();
    if (p === '') continue;
    const a = parseAddress(`KERNELS[${i}]`, p);
    if (kernels.includes(a)) throw new ConfigError(`KERNELS: ${a} is listed twice`);
    kernels.push(a);
  }
  if (kernels.length === 0) throw new ConfigError('KERNELS is required: no address found in it');

  const tankRaw = get(env, 'TANK');
  const tank = tankRaw === undefined ? null : parseAddress('TANK', tankRaw);
  if (tank && kernels.includes(tank)) throw new ConfigError('TANK must not also be listed in KERNELS');

  const keeperRaw = get(env, 'KEEPER_ADDRESS');
  const keeperAddress = keeperRaw === undefined ? null : parseAddress('KEEPER_ADDRESS', keeperRaw);

  const maxFeePerGasCap = parseGweiValue('MAX_FEE_GWEI', get(env, 'MAX_FEE_GWEI'), '0.1', false);
  const priorityFeePerGas = parseGweiValue('PRIORITY_FEE_GWEI', get(env, 'PRIORITY_FEE_GWEI'), '0.001', true);
  if (priorityFeePerGas > maxFeePerGasCap) {
    throw new ConfigError('PRIORITY_FEE_GWEI must not exceed MAX_FEE_GWEI');
  }

  const logLevel = get(env, 'LOG_LEVEL') ?? 'info';
  if (!isLevel(logLevel)) throw new ConfigError(`LOG_LEVEL: "${logLevel}" is not one of debug, info, warn, error`);

  const refundedEvent = get(env, 'TANK_REFUNDED_EVENT') ?? DEFAULT_REFUNDED_EVENT;

  const receiptTimeoutMs = parseInteger('RECEIPT_TIMEOUT_SECONDS', get(env, 'RECEIPT_TIMEOUT_SECONDS'), 60, 5, 600) * 1000;
  const stuckTxMs = parseInteger('STUCK_TX_SECONDS', get(env, 'STUCK_TX_SECONDS'), 180, 30, 86_400) * 1000;
  if (stuckTxMs < receiptTimeoutMs) {
    throw new ConfigError('STUCK_TX_SECONDS must be at least RECEIPT_TIMEOUT_SECONDS');
  }

  return {
    kernels,
    tank,
    rpcUrls: parseRpcUrls(get(env, 'RPC_URLS')),
    chainId: parseInteger('CHAIN_ID', get(env, 'CHAIN_ID'), 196, 1, 2 ** 31 - 1),
    maxFeePerGasCap,
    priorityFeePerGas,
    maxGasLimit: BigInt(parseInteger('MAX_GAS_LIMIT', get(env, 'MAX_GAS_LIMIT'), 30_000_000, 100_000, 200_000_000)),
    pollIntervalMs: parseInteger('POLL_INTERVAL_SECONDS', get(env, 'POLL_INTERVAL_SECONDS'), 30, 2, 3600) * 1000,
    // The chip's "epochs elapsed" input saturates at 15, so a lag policy above 14 would hide information from it.
    minEpochLag: parseInteger('MIN_EPOCH_LAG', get(env, 'MIN_EPOCH_LAG'), 1, 1, 14),
    receiptTimeoutMs,
    receiptPollMs: parseInteger('RECEIPT_POLL_MS', get(env, 'RECEIPT_POLL_MS'), 1000, 100, 60_000),
    stuckTxMs,
    rpcTimeoutMs: parseInteger('RPC_TIMEOUT_SECONDS', get(env, 'RPC_TIMEOUT_SECONDS'), 20, 1, 120) * 1000,
    heartbeatMs: parseInteger('HEARTBEAT_SECONDS', get(env, 'HEARTBEAT_SECONDS'), 600, 10, 86_400) * 1000,
    directFallback: parseBool('DIRECT_FALLBACK', get(env, 'DIRECT_FALLBACK'), true),
    dryRun: argv.includes('--dry-run') || parseBool('DRY_RUN', get(env, 'DRY_RUN'), false),
    once: argv.includes('--once') || parseBool('ONCE', get(env, 'ONCE'), false),
    // About a day of unrefunded settles for two kernels at 900 s epochs (see README, "The wallet").
    minBalanceWei: parseOkbValue('MIN_BALANCE_OKB', get(env, 'MIN_BALANCE_OKB'), '0.02'),
    logLevel,
    keeperAddress,
    refundedEvent,
    stateFile: stateFile(env),
  };
}

/** STATE_FILE: a path, or "none" for memory only. Default: a file in the system's temporary directory. */
function stateFile(env: Env): string | null {
  const v = get(env, 'STATE_FILE');
  if (v === undefined) return join(tmpdir(), 'covenant-keeper-state.json');
  if (v.toLowerCase() === 'none') return null;
  return v;
}

/**
 * Remove KEEPER_PRIVATE_KEY from the environment and return it normalised, or null when unset.
 * The value never appears in an error message.
 */
export function takePrivateKey(env: Env): Hex | null {
  const raw = env['KEEPER_PRIVATE_KEY'];
  delete env['KEEPER_PRIVATE_KEY'];
  if (raw === undefined) return null;
  const v = raw.trim();
  if (v === '') return null;
  const bare = v.startsWith('0x') || v.startsWith('0X') ? v.slice(2) : v;
  if (!/^[0-9a-fA-F]{64}$/.test(bare)) {
    throw new ConfigError(
      'KEEPER_PRIVATE_KEY is set but is not 32 bytes of hex (64 hex characters, with or without 0x)',
    );
  }
  return `0x${bare.toLowerCase()}`;
}
