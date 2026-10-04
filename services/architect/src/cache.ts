// A small in-memory cache of successful compiles, keyed by the request.
//
// A compile is a pure function of (preset, params) for a given toolchain build, and it can take the best
// part of a minute. Caching it keeps a repeated request (the builder page compiling for free, then the same
// chip being bought) well inside the lifetime of an x402 payment. The cache lives in this process and is
// emptied by every deploy, which is also when the toolchain can change.

import { createHash } from 'node:crypto';
import type { CompileResult } from './toolchain.ts';

/** JSON with object keys in sorted order, so that {"a":1,"b":2} and {"b":2,"a":1} are the same request. */
export function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  if (value !== null && typeof value === 'object') {
    const o = value as Record<string, unknown>;
    return `{${Object.keys(o)
      .sort()
      .map((k) => `${JSON.stringify(k)}:${canonicalJson(o[k])}`)
      .join(',')}}`;
  }
  return JSON.stringify(value);
}

export const requestKey = (preset: string, params: Record<string, unknown>): string =>
  createHash('sha256').update(`${preset}\n${canonicalJson(params)}`).digest('hex');

export class CompileCache {
  readonly maxEntries: number;
  readonly #entries = new Map<string, CompileResult>();
  /** Compiles under way, so that identical requests arriving together share one toolchain run. */
  readonly inflight = new Map<string, Promise<CompileResult>>();

  constructor(maxEntries: number) {
    this.maxEntries = maxEntries;
  }

  get size(): number {
    return this.#entries.size;
  }

  get(key: string): CompileResult | undefined {
    const hit = this.#entries.get(key);
    if (hit !== undefined) {
      // Re-insert so that the least recently used entry is the first one in iteration order.
      this.#entries.delete(key);
      this.#entries.set(key, hit);
    }
    return hit;
  }

  set(key: string, result: CompileResult): void {
    if (this.maxEntries <= 0) return;
    this.#entries.delete(key);
    this.#entries.set(key, result);
    while (this.#entries.size > this.maxEntries) {
      const oldest = this.#entries.keys().next();
      if (oldest.done) break;
      this.#entries.delete(oldest.value);
    }
  }
}
