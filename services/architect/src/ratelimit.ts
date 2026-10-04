// In-memory, per-client fixed-window rate limiter, and the client address it is keyed on.
// State lives in this process: with more than one replica each replica counts separately.

import type { Context } from 'hono';

export interface RateDecision {
  allowed: boolean;
  limit: number;
  remaining: number;
  /** Seconds until the window resets. */
  resetSeconds: number;
}

export class RateLimiter {
  readonly limit: number;
  readonly windowMs: number;
  readonly #now: () => number;
  readonly #maxKeys: number;
  readonly #windows = new Map<string, { start: number; count: number }>();

  constructor(limit: number, windowMs = 60_000, now: () => number = Date.now, maxKeys = 20_000) {
    this.limit = limit;
    this.windowMs = windowMs;
    this.#now = now;
    this.#maxKeys = maxKeys;
  }

  get size(): number {
    return this.#windows.size;
  }

  take(key: string): RateDecision {
    const now = this.#now();
    let w = this.#windows.get(key);
    if (!w || now - w.start >= this.windowMs) {
      if (!w && this.#windows.size >= this.#maxKeys) this.#prune(now);
      w = { start: now, count: 0 };
      this.#windows.set(key, w);
    }
    const resetSeconds = Math.max(1, Math.ceil((w.start + this.windowMs - now) / 1000));
    if (w.count >= this.limit) return { allowed: false, limit: this.limit, remaining: 0, resetSeconds };
    w.count += 1;
    return { allowed: true, limit: this.limit, remaining: this.limit - w.count, resetSeconds };
  }

  /** Drop expired windows; if the table is still full, drop the oldest so memory stays bounded. */
  #prune(now: number): void {
    for (const [key, w] of this.#windows) {
      if (now - w.start >= this.windowMs) this.#windows.delete(key);
    }
    while (this.#windows.size >= this.#maxKeys) {
      const oldest = this.#windows.keys().next();
      if (oldest.done) break;
      this.#windows.delete(oldest.value);
    }
  }
}

const IP_RE = /^[0-9a-fA-F:.]{2,45}$/;

/**
 * The client's address.
 * Behind Railway's edge (trustProxy) the edge sets X-Real-IP; a client cannot forge it there.
 * Without a trusted proxy the forwarding headers are ignored, because any client can send them.
 */
export function clientAddress(c: Context, trustProxy: boolean, socketAddress: (c: Context) => string | undefined): string {
  if (trustProxy) {
    const real = c.req.header('x-real-ip')?.trim();
    if (real && IP_RE.test(real)) return real;
    const forwarded = c.req.header('x-forwarded-for');
    if (forwarded) {
      // The right-most entry is the one appended by the proxy closest to us.
      const last = forwarded.split(',').at(-1)?.trim();
      if (last && IP_RE.test(last)) return last;
    }
  }
  return socketAddress(c) ?? 'unknown';
}
