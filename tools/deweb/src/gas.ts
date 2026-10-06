// Gas estimates for the publication's transactions, without running an EVM.
//
// The estimate is the protocol's own arithmetic (intrinsic gas, calldata bytes, the CREATE of each chunk
// contract, 200 gas per byte of deployed code, memory expansion, the storage slots of long strings) plus one
// constant per kind of call for everything else the contracts do (permission checks, bookkeeping, events).
// Those constants were fitted to the gas measured by the fork tests in sim/ (X Layer block 72,376,000) and
// test/plan-vs-fork.test.ts fails if an estimate drifts from a measurement:
//   - a file written for the first time, appendChunk, open, setFallback and a first bind: within 0.5%
//   - replacing a file that already exists, removeFile, and a renewing bind: rough (within 25%); these
//     depend on how many storage slots are cleared and on the refund cap, and are marked `rough`
// The forge script estimates each transaction itself when it broadcasts; nothing depends on these numbers
// except the printed plan.

import { strip } from '../../../packages/chain/src/index.ts';
import type { FileInfo } from './abi.ts';

export interface GasContext {
  /** The container's path list when the step runs, in the registry's order. Updated as the plan goes. */
  paths: string[];
  /** `fileInfo` of the paths that exist on chain before the plan runs. */
  existing: Map<string, FileInfo>;
}

export interface GasInput {
  kind: 'open' | 'putFile' | 'appendChunk' | 'setFallback' | 'removeFile' | 'bind';
  /** Calldata, 0x-prefixed. */
  data: string;
  /** Path the call is about (putFile, appendChunk, setFallback, removeFile). */
  path?: string;
  /** Content type declared (putFile) or already stored (appendChunk). */
  contentType?: string;
  /** Bytes of file data in this call (putFile, appendChunk). */
  chunkBytes?: number;
  /** True when the name was paid for before (bind). */
  renewal?: boolean;
}

const TX = 21_000;
const SSTORE_NEW = 22_100; // a cold storage slot going from zero to non-zero
const SSTORE_LENGTH_DELTA = 17_100; // first element of an array: its length slot goes 0 -> 1 instead of n -> n+1

// Fitted constants (gas): what is left of each measured transaction after the arithmetic below.
// Across the 21 transactions measured by the fork tests the left-over varies by at most 25 gas per kind.
const BASE = {
  open: 145_662,
  putFresh: 233_248,
  appendChunk: 108_957,
  setFallback: 91_992,
  bind: 170_022,
  /** Replacing a one-chunk file instead of creating it saves this much. */
  replaceSaving: 140_697,
  removeFile: 93_900,
  /** Clearing one more chunk slot: 5,000 gas, of which the capped refund gives back about a fifth. */
  removePerExtraChunk: 4_030,
  /** A string longer than 31 bytes costs this much besides its extra storage slots. */
  longStringOverhead: 193,
} as const;

/** Intrinsic gas of the calldata: 4 per zero byte, 16 per non-zero byte. */
export function calldataGas(data: string): number {
  const h = strip(data);
  let zero = 0;
  for (let i = 0; i < h.length; i += 2) if (h.charCodeAt(i) === 48 && h.charCodeAt(i + 1) === 48) zero++;
  return zero * 4 + (h.length / 2 - zero) * 16;
}

const words = (bytes: number): number => Math.ceil(bytes / 32);
const memory = (w: number): number => 3 * w + Math.floor((w * w) / 512);
const pad32 = (bytes: number): number => words(bytes) * 32;

/** Extra storage of a string longer than 31 bytes: one slot per 32 bytes besides the length slot. */
const longString = (bytes: number): number => (bytes <= 31 ? 0 : SSTORE_NEW * words(bytes) + BASE.longStringOverhead);

/**
 * The SiteRegistry and the DomainBinding are ERC-1967 proxies: the proxy copies the whole calldata into its
 * own memory before it delegates the call. 3 gas per word copied, plus the memory itself.
 */
export const proxyCopyGas = (calldataBytes: number): number => 3 * words(calldataBytes) + memory(words(calldataBytes));

/**
 * Creating one chunk contract of `n` data bytes (its code is one zero byte followed by the data):
 * CREATE, the initcode word charge, copying the data into memory in the registry, copying the code out in
 * the constructor, and the code deposit.
 */
export function chunkDeployGas(n: number): number {
  const freePointer = 0x80;
  return (
    32_000 +
    200 * (n + 1) +
    2 * words(n + 12) +
    3 * words(n) +
    (memory(words(freePointer + 12 + n)) - memory(words(freePointer))) +
    3 * words(n + 1) +
    memory(words(n + 1))
  );
}

export function estimateGas(s: GasInput, ctx: GasContext): { gas: number; rough: boolean } {
  const calldataBytes = strip(s.data).length / 2;
  const intrinsic = TX + calldataGas(s.data);
  const viaProxy = intrinsic + proxyCopyGas(calldataBytes);
  const path = s.path ?? '';
  const typeBytes = s.contentType?.length ?? 0;
  // the FileSet event carries the path and the content type: 8 gas per byte of log data
  const eventData = 8 * (pad32(path.length) + pad32(typeBytes));

  switch (s.kind) {
    case 'open':
      return { gas: intrinsic + BASE.open, rough: false };

    case 'putFile': {
      const fresh = viaProxy + BASE.putFresh + chunkDeployGas(s.chunkBytes ?? 0) + eventData + longString(typeBytes);
      const old = ctx.existing.get(path);
      if (old && ctx.paths.includes(path)) {
        // the path keeps its entry in the list; old chunk slots are cleared (about 200 gas each after refunds)
        return { gas: fresh - BASE.replaceSaving + 200 * (old.chunkCount - 1), rough: true };
      }
      const first = ctx.paths.length === 0 ? SSTORE_LENGTH_DELTA : 0;
      ctx.paths.push(path);
      return { gas: fresh + longString(path.length) + first, rough: false };
    }

    case 'appendChunk':
      return { gas: viaProxy + BASE.appendChunk + chunkDeployGas(s.chunkBytes ?? 0) + eventData, rough: false };

    case 'setFallback':
      return { gas: viaProxy + BASE.setFallback + longString(path.length) + 8 * pad32(path.length), rough: false };

    case 'removeFile': {
      // the registry moves the last path of the list into the freed position; a long one costs new slots there
      const at = ctx.paths.indexOf(path);
      const last = ctx.paths[ctx.paths.length - 1] ?? '';
      const move = at >= 0 && at !== ctx.paths.length - 1 ? longString(last.length) : 0;
      if (at >= 0) {
        ctx.paths[at] = last;
        ctx.paths.pop();
      }
      const chunks = ctx.existing.get(path)?.chunkCount ?? 1;
      return { gas: viaProxy + BASE.removeFile + BASE.removePerExtraChunk * (chunks - 1) + move, rough: true };
    }

    case 'bind':
      // a renewal rewrites storage slots instead of creating them and costs less: the estimate is an upper bound
      return { gas: viaProxy + BASE.bind, rough: s.renewal === true };
  }
}
