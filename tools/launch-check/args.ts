// Command-line parsing shared by launch-check.ts and simulate.ts, and the expected-values file.

import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { DEFAULT_EXPECTED, FIXED, type Expected, type TxInput } from './checks.ts';
import { MANAGER } from './decode.ts';
import { DeploymentError, loadDeployment, type Deployment } from './deployment.ts';
import { isHex, parseAddress, parseValue, sameAddress, strip0x } from './hex.ts';

/** A mistake in how the tool was called. It is reported and the tool exits non-zero; it is never a PASS. */
export class UsageError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'UsageError';
  }
}

/**
 * `--name value` pairs and bare `--flags`. A flag given twice, or one not in `known`, is an error.
 * A `list` option may be repeated; its values are joined with commas.
 */
export function parseFlags(argv: readonly string[], known: Readonly<Record<string, 'value' | 'flag' | 'list'>>): Map<string, string> {
  const out = new Map<string, string>();
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) throw new UsageError(`unexpected argument "${a}"`);
    const eq = a.indexOf('=');
    const name = eq > 0 ? a.slice(2, eq) : a.slice(2);
    const kind = known[name];
    if (!kind) throw new UsageError(`unknown option --${name}`);
    if (out.has(name) && kind !== 'list') throw new UsageError(`--${name} was given twice`);
    if (kind === 'flag') {
      if (eq > 0) throw new UsageError(`--${name} takes no value`);
      out.set(name, 'true');
      continue;
    }
    let v: string | undefined;
    if (eq > 0) v = a.slice(eq + 1);
    else v = argv[++i];
    if (v === undefined) throw new UsageError(`--${name} needs a value`);
    out.set(name, kind === 'list' && out.has(name) ? out.get(name) + ',' + v : v);
  }
  return out;
}

/** Calldata given inline, or as `@file`. Whitespace and line breaks from a copy-paste are removed. */
export function readData(arg: string, cwd: string = process.cwd()): string {
  let raw = arg;
  if (arg.startsWith('@')) {
    const path = resolve(cwd, arg.slice(1));
    try {
      raw = readFileSync(path, 'utf8');
    } catch (e) {
      throw new UsageError(`--data: cannot read ${path}: ${(e as Error).message}`);
    }
  }
  const compact = raw.replace(/\s+/g, '');
  if (!compact) throw new UsageError('--data is empty');
  if (!isHex(compact)) throw new UsageError('--data is not hex. Copy the raw hex data from the wallet (it starts with 0xef44bdf2), not the decoded view.');
  return '0x' + strip0x(compact).toLowerCase();
}

const need = (flags: Map<string, string>, name: string): string => {
  const v = flags.get(name);
  if (v === undefined) throw new UsageError(`--${name} is required${['from', 'to', 'value', 'data'].includes(name) ? ' (or give the whole transaction with --tx)' : ''}`);
  return v;
};

/**
 * The parameters of an `eth_sendTransaction` request, as a page hook captures them before the wallet opens:
 * `{"from","to","value","data"}` (other keys such as gas are ignored; `input` is accepted for `data`). The file may
 * also hold the params array or the whole request `{"method":"eth_sendTransaction","params":[{...}]}`.
 * `value` is hex wei ("0x0"), decimal wei, or absent (then 0, as eth_sendTransaction defines it).
 */
export function parseTxJson(text: string, where: string = '--tx'): { from: string; to: string; value: bigint; data: string } {
  let o: unknown;
  try {
    o = JSON.parse(text);
  } catch (e) {
    throw new UsageError(`${where}: not valid JSON (${(e as Error).message})`);
  }
  const isObj = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === 'object' && !Array.isArray(v);
  if (isObj(o) && o.method !== undefined) {
    if (o.method !== 'eth_sendTransaction') throw new UsageError(`${where}: the request is ${JSON.stringify(o.method)}, not eth_sendTransaction`);
    o = o.params;
  }
  if (Array.isArray(o)) {
    if (o.length < 1) throw new UsageError(`${where}: the params array is empty`);
    o = o[0];
  }
  if (!isObj(o)) throw new UsageError(`${where}: expected an object with from, to, value and data`);
  if (o.chainId !== undefined && !(o.chainId === 196 || o.chainId === '196' || (typeof o.chainId === 'string' && /^0x0*c4$/i.test(o.chainId)))) {
    throw new UsageError(`${where}: chainId is ${JSON.stringify(o.chainId)}, not X Layer (196)`);
  }
  const str = (key: string): string => {
    const v = o[key as keyof typeof o];
    if (typeof v !== 'string') throw new UsageError(`${where}: "${key}" is missing or not a string`);
    return v;
  };
  if (o.data !== undefined && o.input !== undefined && o.data !== o.input) throw new UsageError(`${where}: "data" and "input" differ`);
  const data = o.data !== undefined ? str('data') : str('input');
  let value = 0n;
  const v = o.value;
  if (v !== undefined && v !== null) {
    if (typeof v === 'number') {
      if (!Number.isSafeInteger(v) || v < 0) throw new UsageError(`${where}: value ${v} is not an exact whole number of wei; give it as a string`);
      value = BigInt(v);
    } else if (typeof v === 'string' && (/^0x[0-9a-fA-F]+$/.test(v) || /^[0-9]+$/.test(v))) value = BigInt(v);
    else throw new UsageError(`${where}: value ${JSON.stringify(v)} is not wei (hex "0x..." or decimal)`);
  }
  try {
    return { from: parseAddress(str('from'), `${where} from`), to: parseAddress(str('to'), `${where} to`), value, data: readData(data) };
  } catch (e) {
    if (e instanceof UsageError) throw new UsageError(`${where}: ${e.message}`);
    throw new UsageError(`${where}: ${(e as Error).message}`);
  }
}

/**
 * The transaction as the wallet will send it, from --tx <json | @file> or from --from --to --value --data, and
 * the kernel it must pay: --kernel, or the kernel of the deployment file (`fallbackKernel`) when --kernel is not
 * given.
 */
export function readTx(flags: Map<string, string>, fallbackKernel: string | null = null): TxInput {
  try {
    const k = flags.get('kernel');
    if (k === undefined && fallbackKernel === null) throw new UsageError('--kernel is required (or --deployment with a file that names the kernel)');
    const kernel = k !== undefined ? parseAddress(k, '--kernel') : (fallbackKernel as string);
    const txArg = flags.get('tx');
    if (txArg !== undefined) {
      const clash = ['from', 'to', 'value', 'data'].filter((f) => flags.has(f));
      if (clash.length) throw new UsageError(`--tx already gives from, to, value and data; do not also pass ${clash.map((f) => '--' + f).join(' ')}`);
      let text = txArg;
      if (txArg.startsWith('@')) {
        const path = resolve(process.cwd(), txArg.slice(1));
        try {
          text = readFileSync(path, 'utf8');
        } catch (e) {
          throw new UsageError(`--tx: cannot read ${path}: ${(e as Error).message}`);
        }
      }
      return { ...parseTxJson(text, '--tx'), kernel };
    }
    return {
      from: parseAddress(need(flags, 'from'), '--from'),
      to: parseAddress(need(flags, 'to'), '--to'),
      value: parseValue(need(flags, 'value')),
      data: readData(need(flags, 'data')),
      kernel,
    };
  } catch (e) {
    if (e instanceof UsageError) throw e;
    throw new UsageError((e as Error).message);
  }
}

const ALLOWED_KEYS = new Set([
  'description',
  'chainId',
  'manager',
  'templateId',
  'quote',
  'venue',
  'taxBuyBps',
  'taxSellBps',
  'protectionSecs',
  'firstBuy',
  'snipeStartBps',
  'founderBps',
  'name',
  'symbol',
  'kernel',
  'processor',
]);

const addressOrNull = (v: unknown, what: string): string | null => {
  if (v === null || v === undefined) return null;
  if (typeof v !== 'string') throw new UsageError(`expected-values file: ${what} must be an address string or null`);
  try {
    return parseAddress(v, what);
  } catch (e) {
    throw new UsageError(`expected-values file: ${(e as Error).message}`);
  }
};

const intField = (o: Record<string, unknown>, key: string, fallback: number, max: number): number => {
  const v = o[key];
  if (v === undefined) return fallback;
  if (typeof v !== 'number' || !Number.isInteger(v) || v < 0 || v > max) throw new UsageError(`expected-values file: ${key} must be an integer from 0 to ${max}`);
  return v;
};

/**
 * Reads an expected-values file. The rules a launch must satisfy (Directed template, native quote, venue 1,
 * first buy 0, anti-snipe off, no founder round) are fixed in the tool: a file that states anything else is
 * refused rather than obeyed.
 */
export function parseExpected(jsonText: string, where: string = 'expected-values file'): Expected {
  let o: Record<string, unknown>;
  try {
    o = JSON.parse(jsonText) as Record<string, unknown>;
  } catch (e) {
    throw new UsageError(`${where}: not valid JSON (${(e as Error).message})`);
  }
  if (o === null || typeof o !== 'object' || Array.isArray(o)) throw new UsageError(`${where}: must be a JSON object`);
  for (const key of Object.keys(o)) {
    if (!ALLOWED_KEYS.has(key)) throw new UsageError(`${where}: unknown key "${key}" (a misspelt key would silently drop an expectation)`);
  }
  const fixed = (key: string, want: unknown, show: string): void => {
    if (o[key] !== undefined && o[key] !== want) {
      throw new UsageError(`${where}: ${key} is ${JSON.stringify(o[key])}, but this tool only approves ${show}`);
    }
  };
  fixed('chainId', 196, 'launches on X Layer (chain id 196)');
  fixed('templateId', FIXED.templateId, 'the Directed vault template (3)');
  fixed('venue', FIXED.venue, 'venue 1 (Uniswap V2)');
  fixed('snipeStartBps', 0, 'launches with anti-snipe off (0)');
  fixed('founderBps', 0, 'launches without a founder round (0)');
  if (o.firstBuy !== undefined && o.firstBuy !== 0 && o.firstBuy !== '0') throw new UsageError(`${where}: firstBuy must be 0; a first buy is a team buy`);
  if (o.quote !== undefined && !(typeof o.quote === 'string' && sameAddress(o.quote, FIXED.quote))) {
    throw new UsageError(`${where}: quote must be the zero address (native OKB); kernel v1 binds nothing else`);
  }
  if (o.manager !== undefined && !(typeof o.manager === 'string' && sameAddress(o.manager, MANAGER))) {
    throw new UsageError(`${where}: manager must be the IgnixManager proxy ${MANAGER}`);
  }
  const strOrNull = (key: string): string | null => {
    const v = o[key];
    if (v === undefined || v === null) return null;
    if (typeof v !== 'string') throw new UsageError(`${where}: ${key} must be a string or null`);
    return v;
  };
  const proc = o.processor;
  if (proc !== undefined && proc !== null && (typeof proc !== 'object' || Array.isArray(proc))) throw new UsageError(`${where}: processor must be an object`);
  const p = (proc ?? {}) as Record<string, unknown>;
  for (const key of Object.keys(p)) {
    if (key !== 'circuits' && key !== 'transistors') throw new UsageError(`${where}: unknown key "processor.${key}"`);
  }
  return {
    taxBuyBps: intField(o, 'taxBuyBps', DEFAULT_EXPECTED.taxBuyBps, 1000),
    taxSellBps: intField(o, 'taxSellBps', DEFAULT_EXPECTED.taxSellBps, 1000),
    protectionSecs: intField(o, 'protectionSecs', DEFAULT_EXPECTED.protectionSecs, Number.MAX_SAFE_INTEGER),
    name: strOrNull('name'),
    symbol: strOrNull('symbol'),
    kernel: addressOrNull(o.kernel, 'kernel'),
    circuits: addressOrNull(p.circuits, 'processor.circuits'),
    transistors: addressOrNull(p.transistors, 'processor.transistors'),
    kernelFactory: null,
    fab: null,
    sealedVM: null,
    chipId: null,
  };
}

/**
 * Adds a deployment file's addresses to the expected values. An address the expected-values file also names
 * must be the same one; a disagreement is a usage error, never a silent choice.
 */
export function withDeployment(expected: Expected, d: Deployment): Expected {
  const merge = (what: string, mine: string | null, theirs: string | null): string | null => {
    if (mine !== null && theirs !== null && !sameAddress(mine, theirs)) {
      throw new UsageError(`the expected-values file says ${what} is ${mine}, the deployment file ${d.source} says ${theirs}`);
    }
    return mine ?? theirs;
  };
  return {
    ...expected,
    kernel: merge('the kernel', expected.kernel, d.kernel),
    circuits: merge('processor.circuits', expected.circuits, d.circuits),
    transistors: merge('processor.transistors', expected.transistors, d.transistors),
    kernelFactory: merge('the KernelFactory', expected.kernelFactory, d.kernelFactory),
    fab: merge('the Fab', expected.fab, d.fab),
    sealedVM: merge('the SealedVM', expected.sealedVM, d.sealedVM),
    chipId: expected.chipId ?? d.chipId,
  };
}

/** `--deployment <file>`, or null when the flag is absent. A file that cannot be read is a usage error. */
export function readDeploymentFlag(flags: Map<string, string>): Deployment | null {
  const path = flags.get('deployment');
  if (path === undefined) return null;
  try {
    return loadDeployment(path);
  } catch (e) {
    if (e instanceof DeploymentError) throw new UsageError(`--deployment: ${e.message}`);
    throw e;
  }
}

export function loadExpected(path: string | undefined): Expected {
  if (path === undefined) return { ...DEFAULT_EXPECTED };
  const abs = resolve(process.cwd(), path);
  let text: string;
  try {
    text = readFileSync(abs, 'utf8');
  } catch (e) {
    throw new UsageError(`--expected: cannot read ${abs}: ${(e as Error).message}`);
  }
  return parseExpected(text, abs);
}
