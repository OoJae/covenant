// Several RPC endpoints behind one call(). On an RPC error: switch to the next endpoint at once.
// When a whole round of endpoints has failed: back off (exponentially, with jitter) before the next round.

import type { ChainClient } from './chain.ts';
import { RpcError, RpcUnavailableError } from './errors.ts';
import type { Logger } from './log.ts';

export interface PoolOptions {
  log: Logger;
  sleep: (ms: number) => Promise<void>;
  /** Delay after the first failed round. Doubles each round. */
  baseDelayMs?: number;
  maxDelayMs?: number;
  /** Rounds over all endpoints before a call gives up with RpcUnavailableError. */
  maxRounds?: number;
  random?: () => number;
}

export interface Pool {
  readonly clients: readonly ChainClient[];
  readonly current: ChainClient;
  call<T>(label: string, fn: (client: ChainClient) => Promise<T>): Promise<T>;
}

export class RpcPool implements Pool {
  readonly clients: readonly ChainClient[];
  readonly #log: Logger;
  readonly #sleep: (ms: number) => Promise<void>;
  readonly #baseDelayMs: number;
  readonly #maxDelayMs: number;
  readonly #maxRounds: number;
  readonly #random: () => number;
  #index = 0;

  constructor(clients: readonly ChainClient[], options: PoolOptions) {
    if (clients.length === 0) throw new Error('RpcPool needs at least one client');
    this.clients = clients;
    this.#log = options.log;
    this.#sleep = options.sleep;
    this.#baseDelayMs = options.baseDelayMs ?? 1000;
    this.#maxDelayMs = options.maxDelayMs ?? 30_000;
    this.#maxRounds = options.maxRounds ?? 3;
    this.#random = options.random ?? Math.random;
  }

  get current(): ChainClient {
    return this.clients[this.#index] as ChainClient;
  }

  /** Delay before round `round` (1-based count of failed rounds so far): base * 2^(round-1), capped, +0..25% jitter. */
  backoffMs(round: number): number {
    const exp = Math.min(this.#maxDelayMs, this.#baseDelayMs * 2 ** Math.max(0, round - 1));
    return Math.round(exp * (1 + 0.25 * this.#random()));
  }

  async call<T>(label: string, fn: (client: ChainClient) => Promise<T>): Promise<T> {
    let failedInRound = 0;
    let rounds = 0;
    let last: RpcError | null = null;
    for (;;) {
      const client = this.current;
      try {
        return await fn(client);
      } catch (err) {
        // Anything that is not an RPC fault (a revert, a rejected transaction) is the caller's business.
        if (!(err instanceof RpcError)) throw err;
        last = err;
        failedInRound++;
        this.#index = (this.#index + 1) % this.clients.length;
        this.#log.warn('rpc_error', { call: label, rpc: client.label, error: err.message, next: this.current.label });
        if (failedInRound < this.clients.length) continue;
        failedInRound = 0;
        rounds++;
        if (rounds >= this.#maxRounds) {
          throw new RpcUnavailableError(
            `${label}: all ${this.clients.length} RPC endpoint(s) failed ${rounds} time(s); last error: ${last.message}`,
          );
        }
        const delay = this.backoffMs(rounds);
        this.#log.warn('rpc_backoff', { call: label, delayMs: delay, round: rounds });
        await this.#sleep(delay);
      }
    }
  }
}
