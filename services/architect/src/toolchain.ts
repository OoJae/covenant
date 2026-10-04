// The one adapter between this service and the chip toolchain.
//
//   compilePreset(preset, params)  ->  { netlistHex, manifest, proofs, cost }
//
// STUB MODE. When TAPC_CMD is unset, compilePreset returns the fixed demo payload from stub.ts, marked
// `stub: true`. The paid route refuses to sell it (see config.ts).
//
// CLI CONTRACT ("covenant-architect/1"). When TAPC_CMD is set, it is the complete command line of the
// toolchain entry point, for example
//
//     TAPC_CMD="/app/chips/.venv/bin/python -m tapc architect"
//
// It is split into argv without a shell and run once per request, with no extra arguments.
//
//   stdin   One JSON object, then EOF:
//             {"protocol":"covenant-architect/1","op":"compile","preset":"flow-governor","params":{...}}
//           `preset` matches [a-z0-9][a-z0-9_-]{0,63}. `params` is a JSON object; the service checks only
//           its size and depth, so the toolchain validates the fields for each preset. Values that came
//           through OKX's CLI may be strings ("900" for 900): accept numeric strings.
//
//   stdout  Exactly one JSON object and nothing else (logs go to stderr).
//           Success:
//             {"ok":true,
//              "netlistHex":"0x...",     TAP-20 bytes, ready for Fab.tapeoutChip; at most 24,000 bytes
//              "manifest":{...},         the "tapc-manifest/1" object (pins, counts, keccak256, ...)
//              "proofs":[{"id":"shares-sum-256","status":"proved"|"failed"|"skipped","detail":"..."}],
//              "cost":{...}}             at least {"transistors":n}; any further fields are passed through
//           `ok:true` means: compiled AND every required proof holds. A result that contains a proof
//           with status "failed" is treated as a rejection whatever `ok` says.
//           Rejection (bad preset, bad params, a proof fails, the design does not fit):
//             {"ok":false,"error":{"code":"unknown_preset","message":"...","stage":"validate",
//                                  "diagnostics":[{"code":"...","path":"params.epochLen","message":"...","hint":"..."}]}}
//
//   exit    0 with ok:true, or any code with a parseable ok:false object  -> the answer above.
//           Anything else (non-zero without such an object, unparseable stdout, a signal) -> toolchain fault.
//
//   limits  Killed after TAPC_TIMEOUT_MS (default 120 s). stdout above 8 MiB is a fault.
//   env     PATH, HOME, LANG, LC_ALL, TZ, TMPDIR, VIRTUAL_ENV, PYTHONPATH, PYTHONUNBUFFERED,
//           YOWASP_CACHE_DIR, YOWASP_MOUNT and every TAPC_* variable. Nothing else: no credentials.
//   cwd     TAPC_CWD when set, else the service's working directory.
//
// HTTP mapping (app.ts): success 200; rejection 422; timeout 504; any other toolchain fault 502.
// None of the non-200 outcomes is charged.

import { spawn } from 'node:child_process';
import { toolchainConfig } from './config.ts';
import type { ToolchainConfig } from './config.ts';
import { stubResult } from './stub.ts';

export const PROTOCOL = 'covenant-architect/1';
export const MAX_NETLIST_BYTES = 24_000;
const MAX_STDOUT_BYTES = 8 * 1024 * 1024;
const MAX_STDERR_BYTES = 64 * 1024;

export interface CompileResult {
  netlistHex: string;
  manifest: Record<string, unknown>;
  proofs: unknown[];
  cost: Record<string, unknown>;
  /** Present and true only for the fixed demo payload. */
  stub?: true;
}

export interface Diagnostic {
  code?: string;
  path?: string;
  message?: string;
  hint?: string;
}

/** The toolchain understood the request and said no. HTTP 422. Not charged. */
export class CompileRejected extends Error {
  readonly code: string;
  readonly stage: string | null;
  readonly diagnostics: Diagnostic[];
  readonly proofs: unknown[] | null;
  constructor(code: string, message: string, stage: string | null = null, diagnostics: Diagnostic[] = [], proofs: unknown[] | null = null) {
    super(message);
    this.name = 'CompileRejected';
    this.code = code;
    this.stage = stage;
    this.diagnostics = diagnostics;
    this.proofs = proofs;
  }
}

export type FaultKind = 'spawn' | 'timeout' | 'crash' | 'bad_output';

/** The toolchain itself failed. HTTP 502 (504 for a timeout). Not charged. */
export class ToolchainError extends Error {
  readonly kind: FaultKind;
  /** Tail of stderr, for the server log only. Never sent to a client. */
  readonly stderrTail: string;
  constructor(kind: FaultKind, message: string, stderrTail = '') {
    super(message);
    this.name = 'ToolchainError';
    this.kind = kind;
    this.stderrTail = stderrTail;
  }
}

export type ToolchainMode = 'stub' | 'cli';

export const toolchainMode = (config: ToolchainConfig): ToolchainMode => (config.command === null ? 'stub' : 'cli');

const PASS_THROUGH = [
  'PATH',
  'HOME',
  'LANG',
  'LC_ALL',
  'TZ',
  'TMPDIR',
  'VIRTUAL_ENV',
  'PYTHONPATH',
  'PYTHONUNBUFFERED',
  'YOWASP_CACHE_DIR',
  'YOWASP_MOUNT',
];

/** The environment handed to the toolchain: an allow-list, so no credential of the service can reach it. */
export function childEnv(env: Record<string, string | undefined>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const key of PASS_THROUGH) {
    const v = env[key];
    if (v !== undefined) out[key] = v;
  }
  for (const [key, v] of Object.entries(env)) {
    if (key.startsWith('TAPC_') && v !== undefined) out[key] = v;
  }
  return out;
}

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);

/** Check the toolchain's answer. Throws CompileRejected or ToolchainError('bad_output'). */
export function parseToolchainOutput(stdout: string, exitCode: number | null, stderrTail = ''): CompileResult {
  let doc: unknown;
  try {
    doc = JSON.parse(stdout);
  } catch {
    if (exitCode !== 0) throw new ToolchainError('crash', `toolchain exited with code ${exitCode}`, stderrTail);
    throw new ToolchainError('bad_output', 'toolchain printed something that is not JSON', stderrTail);
  }
  if (!isObject(doc)) throw new ToolchainError('bad_output', 'toolchain output is not a JSON object', stderrTail);

  if (doc['ok'] === false) {
    const e = isObject(doc['error']) ? doc['error'] : {};
    const diagnostics = Array.isArray(e['diagnostics']) ? (e['diagnostics'].filter(isObject) as Diagnostic[]) : [];
    throw new CompileRejected(
      typeof e['code'] === 'string' ? e['code'] : 'rejected',
      typeof e['message'] === 'string' ? e['message'] : 'the toolchain rejected the request',
      typeof e['stage'] === 'string' ? e['stage'] : null,
      diagnostics,
      Array.isArray(doc['proofs']) ? doc['proofs'] : null,
    );
  }
  if (exitCode !== 0) throw new ToolchainError('crash', `toolchain exited with code ${exitCode}`, stderrTail);
  if (doc['ok'] !== true) throw new ToolchainError('bad_output', 'toolchain output has no boolean "ok"', stderrTail);

  const { netlistHex, manifest, proofs, cost } = doc;
  if (typeof netlistHex !== 'string' || !/^0x(?:[0-9a-fA-F]{2})+$/.test(netlistHex)) {
    throw new ToolchainError('bad_output', 'netlistHex is not non-empty 0x-prefixed hex', stderrTail);
  }
  if ((netlistHex.length - 2) / 2 > MAX_NETLIST_BYTES) {
    throw new ToolchainError('bad_output', `netlist is larger than ${MAX_NETLIST_BYTES} bytes`, stderrTail);
  }
  if (!isObject(manifest)) throw new ToolchainError('bad_output', 'manifest is not an object', stderrTail);
  if (!Array.isArray(proofs)) throw new ToolchainError('bad_output', 'proofs is not an array', stderrTail);
  if (!isObject(cost)) throw new ToolchainError('bad_output', 'cost is not an object', stderrTail);

  // Safety net for the paid route: a result with a failed proof is never returned as a success.
  const failed = proofs.filter((p) => isObject(p) && p['status'] === 'failed');
  if (failed.length > 0) {
    throw new CompileRejected('proof_failed', `${failed.length} proof(s) failed`, 'prove', [], proofs);
  }
  return { netlistHex, manifest, proofs, cost };
}

function runCommand(command: string[], input: string, config: ToolchainConfig, env: Record<string, string | undefined>): Promise<{ stdout: string; code: number | null; stderrTail: string }> {
  return new Promise((resolve, reject) => {
    const [file, ...args] = command;
    if (file === undefined) return reject(new ToolchainError('spawn', 'TAPC_CMD is empty'));

    let child;
    try {
      // detached: the toolchain gets its own process group, so a timeout kills its children too.
      child = spawn(file, args, {
        cwd: config.cwd ?? undefined,
        env: childEnv(env),
        stdio: ['pipe', 'pipe', 'pipe'],
        shell: false,
        detached: true,
      });
    } catch {
      return reject(new ToolchainError('spawn', 'could not start the toolchain command'));
    }

    const out: Buffer[] = [];
    let outBytes = 0;
    let err = Buffer.alloc(0);
    let settled = false;
    let fault: ToolchainError | null = null;

    const killGroup = (): void => {
      try {
        if (child.pid !== undefined) process.kill(-child.pid, 'SIGKILL');
      } catch {
        child.kill('SIGKILL');
      }
    };
    const stderrTail = (): string => err.toString('utf8').slice(-4000);

    const timer = setTimeout(() => {
      fault = new ToolchainError('timeout', `toolchain did not finish within ${config.timeoutMs} ms`, stderrTail());
      killGroup();
    }, config.timeoutMs);

    child.stdout.on('data', (chunk: Buffer) => {
      outBytes += chunk.length;
      if (outBytes > MAX_STDOUT_BYTES) {
        fault ??= new ToolchainError('bad_output', 'toolchain output is larger than 8 MiB', stderrTail());
        killGroup();
        return;
      }
      out.push(chunk);
    });
    child.stderr.on('data', (chunk: Buffer) => {
      err = Buffer.concat([err, chunk]).subarray(-MAX_STDERR_BYTES);
    });
    child.on('error', () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(new ToolchainError('spawn', 'could not start the toolchain command (is TAPC_CMD correct?)'));
    });
    child.on('close', (code) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (fault) return reject(fault);
      resolve({ stdout: Buffer.concat(out).toString('utf8'), code, stderrTail: stderrTail() });
    });

    // A toolchain that exits without reading stdin must not take the service down with EPIPE.
    child.stdin.on('error', () => {});
    child.stdin.end(input);
  });
}

/**
 * Compile a preset: compilePreset(preset, params). Stub mode when TAPC_CMD is not configured.
 * The last two arguments default to the process environment; the service passes its parsed configuration.
 * Throws CompileRejected (the request is at fault) or ToolchainError (the toolchain is at fault).
 */
export async function compilePreset(
  preset: string,
  params: Record<string, unknown>,
  config: ToolchainConfig = toolchainConfig(process.env),
  env: Record<string, string | undefined> = process.env,
): Promise<CompileResult> {
  if (config.command === null) return stubResult(preset, params, config.transistorPriceWei);

  const request = JSON.stringify({ protocol: PROTOCOL, op: 'compile', preset, params });
  const { stdout, code, stderrTail } = await runCommand(config.command, request, config, env);
  return parseToolchainOutput(stdout, code, stderrTail);
}
