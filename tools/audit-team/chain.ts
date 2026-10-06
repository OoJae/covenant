// Chain access for the audit: read-only JSON-RPC, at most ten calls per HTTP request, a pause between
// requests so the public endpoint's rate limit (about 7 per second) is never reached, retries, and a
// cache on disk for answers that can never change (counts, blocks and receipts well below the head).

import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { isRevert, RpcError, type Rpc } from '../../packages/chain/src/index.ts';
import { connect } from '../launch-check/chain.ts';
import { authorizationHash, type RpcAuthorization } from '../launch-check/rlp.ts';
import { recoverAddress } from '../launch-check/secp256k1.ts';

export const DEFAULT_RPCS = ['https://rpc.xlayer.tech', 'https://xlayerrpc.okx.com'] as const;

export interface RpcLog {
  address: string;
  topics: string[];
  data: string;
}

/** A transaction as the audit keeps it. */
export interface Tx {
  hash: string;
  from: string;
  to: string | null;
  nonce: number;
  value: string; // hex wei
  input: string;
  type: string;
  blockNumber: number;
  timestamp: number;
  transactionIndex: number;
}

export interface Receipt {
  status: string; // "0x1" success, "0x0" reverted
  gasUsed: string;
  contractAddress: string | null;
  logs: RpcLog[];
}

/** A nonce of the wallet that was used by an EIP-7702 authorisation instead of a transaction. */
export interface AuthorizationUse {
  nonce: number;
  /** The contract the wallet's code was delegated to (the zero address clears a delegation). */
  delegate: string;
  /** The transaction that carried the authorisation, and who sent it. */
  carrier: string;
  carrierFrom: string;
}

export interface WalletBlock {
  timestamp: number;
  txs: Tx[];
  authorizations: AuthorizationUse[];
}

/** A log found by `scanLogs`, with where it is. */
export interface ScanLog {
  blockNumber: number;
  transactionHash: string;
  logIndex: number;
  address: string;
  topics: string[];
  data: string;
}

/** A log scan remembered by the cache: every matching log in blocks `from .. to`. */
export interface StoredScan {
  from: number;
  to: number;
  logs: ScanLog[];
}

/** eth_getLogs accepts at most this many blocks per query on the public X Layer endpoint (measured: 100 works, 101 is refused). */
export const LOG_CHUNK = 100;

/** What an earlier run learned about a wallet, up to a block that can no longer change. */
export interface StoredWalk {
  /** The block the walk covers up to. */
  head: number;
  /** eth_getTransactionCount at block 0 and at `head`. */
  atFloor: number;
  total: number;
  /** Blocks in which the wallet used nonces: [block, firstNonce, lastNonce]. */
  blocks: [number, number, number][];
}

interface CacheFile {
  version: 1;
  chainId: number;
  counts: Record<string, Record<string, number>>;
  blocks: Record<string, Record<string, WalletBlock>>;
  receipts: Record<string, Receipt>;
  walks: Record<string, StoredWalk>;
  /** `${address}:${topics}` -> the part of a log scan that can no longer change. */
  scans: Record<string, StoredScan>;
}

export interface ChainOptions {
  urls?: readonly string[];
  /** Cache file, or null for no cache. */
  cachePath?: string | null;
  /** Minimum milliseconds between HTTP requests. Default 220 (about 4.5 requests per second). */
  minIntervalMs?: number;
  /** Blocks this close to the head are not written to the cache. Default 64. */
  confirmations?: number;
  /** For tests: an RPC client to use instead of creating one. */
  rpc?: Rpc;
  /** Audit at this block instead of the latest one. */
  block?: number;
}

export interface Stats {
  httpRequests: number;
  calls: number;
  cacheHits: number;
  retries: number;
}

type Req = readonly [string, readonly unknown[]];
const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
const hexBlock = (n: number): string => '0x' + n.toString(16);

export class Chain {
  readonly rpc: Rpc;
  readonly stats: Stats = { httpRequests: 0, calls: 0, cacheHits: 0, retries: 0 };
  chainId = 0;
  head = 0;
  headTimestamp = 0;
  private readonly minIntervalMs: number;
  private readonly confirmations: number;
  private readonly cachePath: string | null;
  private readonly pinned: number | undefined;
  private cache: CacheFile = { version: 1, chainId: 0, counts: {}, blocks: {}, receipts: {}, walks: {}, scans: {} };
  private readonly times = new Map<number, number>();
  private dirty = false;
  private last = 0;

  constructor(opts: ChainOptions = {}) {
    this.rpc = opts.rpc ?? connect(opts.urls ?? DEFAULT_RPCS, { timeout: 30000, retries: 1 });
    this.minIntervalMs = opts.minIntervalMs ?? 220;
    this.confirmations = opts.confirmations ?? 64;
    this.cachePath = opts.cachePath ?? null;
    this.pinned = opts.block;
  }

  /** Reads the chain id and fixes the block every later answer refers to. */
  async open(): Promise<void> {
    const [id, latest] = await this.batch([
      ['eth_chainId', []],
      ['eth_getBlockByNumber', [this.pinned === undefined ? 'latest' : hexBlock(this.pinned), false]],
    ]);
    this.chainId = Number(BigInt(id as string));
    const b = latest as { number?: string; timestamp?: string } | null;
    if (!b?.number || !b.timestamp) throw new Error(this.pinned === undefined ? 'the node returned no latest block' : `the node has no block ${this.pinned}`);
    this.head = Number(BigInt(b.number));
    this.headTimestamp = Number(BigInt(b.timestamp));
    if (this.cachePath && existsSync(this.cachePath)) {
      try {
        const c = JSON.parse(readFileSync(this.cachePath, 'utf8')) as CacheFile;
        if (c.version === 1 && c.chainId === this.chainId) this.cache = { ...c, walks: c.walks ?? {}, scans: c.scans ?? {} };
      } catch {
        // an unreadable cache is ignored and rewritten
      }
    }
    this.cache.chainId = this.chainId;
  }

  /** Writes the cache if anything was added. */
  save(): void {
    if (!this.cachePath || !this.dirty) return;
    mkdirSync(dirname(this.cachePath), { recursive: true });
    const tmp = this.cachePath + '.tmp';
    writeFileSync(tmp, JSON.stringify(this.cache));
    renameSync(tmp, this.cachePath);
    this.dirty = false;
  }

  private final(block: number): boolean {
    return block <= this.head - this.confirmations;
  }

  /** The highest block whose contents are treated as final (and may be cached). */
  safeHead(): number {
    return Math.max(0, this.head - this.confirmations);
  }

  /** The stored walk of a wallet, if the cache has one that ends at or below the safe head. */
  storedWalk(address: string): StoredWalk | null {
    const w = this.cache.walks[address.toLowerCase()];
    return w && w.head <= this.safeHead() ? w : null;
  }

  storeWalk(address: string, walk: StoredWalk): void {
    if (!this.cachePath || walk.head > this.safeHead()) return;
    this.cache.walks[address.toLowerCase()] = walk;
    this.dirty = true;
  }

  /**
   * Sends calls in HTTP requests of at most ten, spaced out, and retries the ones the node failed.
   * A call that reverted comes back as its RpcError; anything else that still fails after the retries throws.
   */
  async batch(reqs: readonly Req[], retryNull: boolean = false): Promise<unknown[]> {
    const out: unknown[] = new Array(reqs.length);
    for (let o = 0; o < reqs.length; o += 10) {
      let todo = reqs.slice(o, o + 10).map((_, j) => o + j);
      for (let attempt = 0; todo.length; attempt++) {
        if (attempt > 4) {
          const e = out[todo[0]];
          if (e === null) break; // still null after the retries: the caller reports what is missing
          throw new Error(`the node kept failing ${reqs[todo[0]][0]}: ${e instanceof Error ? e.message : 'no answer'}`);
        }
        if (attempt) {
          this.stats.retries++;
          await sleep(400 * 2 ** (attempt - 1));
        }
        const wait = this.last + this.minIntervalMs - Date.now();
        if (wait > 0) await sleep(wait);
        this.last = Date.now();
        this.stats.httpRequests++;
        this.stats.calls += todo.length;
        let replies: unknown[];
        try {
          replies = await this.rpc.batch(todo.map((k) => reqs[k]));
        } catch (e) {
          replies = todo.map(() => (e instanceof Error ? e : new Error(String(e))));
        }
        todo = todo.filter((k, j) => {
          out[k] = replies[j];
          const r = replies[j];
          // with retryNull, a null block or receipt (a node that is behind) is asked for again
          return (r instanceof Error && !isRevert(r)) || r === undefined || (retryNull && r === null);
        });
      }
    }
    return out;
  }

  /** eth_getTransactionCount at each block. */
  async counts(address: string, blocks: readonly number[]): Promise<number[]> {
    const a = address.toLowerCase();
    const known = (this.cache.counts[a] ??= {});
    const out: number[] = new Array(blocks.length);
    const ask: number[] = [];
    blocks.forEach((b, i) => {
      const hit = known[String(b)];
      if (hit !== undefined && b !== this.head) {
        out[i] = hit;
        this.stats.cacheHits++;
      } else ask.push(i);
    });
    if (ask.length) {
      const replies = await this.batch(ask.map((i) => ['eth_getTransactionCount', [a, hexBlock(blocks[i])]] as const));
      ask.forEach((i, j) => {
        const r = replies[j];
        if (r instanceof Error) throw new Error(`eth_getTransactionCount(${a}, ${blocks[i]}) failed: ${r.message}`);
        out[i] = Number(BigInt(r as string));
        if (this.final(blocks[i])) {
          known[String(blocks[i])] = out[i];
          this.dirty = true;
        }
      });
    }
    return out;
  }

  /** The transactions `address` sent in each block, and the EIP-7702 authorisations it signed that were used there. */
  async walletBlocks(address: string, blocks: readonly number[]): Promise<WalletBlock[]> {
    const a = address.toLowerCase();
    const known = (this.cache.blocks[a] ??= {});
    const out: WalletBlock[] = new Array(blocks.length);
    const ask: number[] = [];
    blocks.forEach((b, i) => {
      const hit = known[String(b)];
      if (hit) {
        out[i] = hit;
        this.stats.cacheHits++;
      } else ask.push(i);
    });
    // one block per call: full blocks can be large
    for (let o = 0; o < ask.length; o += 5) {
      const part = ask.slice(o, o + 5);
      const replies = await this.batch(part.map((i) => ['eth_getBlockByNumber', [hexBlock(blocks[i]), true]] as const), true);
      part.forEach((i, j) => {
        const r = replies[j];
        if (r instanceof Error || !r) throw new Error(`eth_getBlockByNumber(${blocks[i]}) failed: ${r instanceof Error ? r.message : 'no such block'}`);
        const wb = reduceBlock(r as RawBlock, a);
        out[i] = wb;
        if (this.final(blocks[i])) {
          known[String(blocks[i])] = wb;
          this.dirty = true;
        }
      });
    }
    return out;
  }

  async receipts(hashes: readonly string[]): Promise<Receipt[]> {
    const out: Receipt[] = new Array(hashes.length);
    const ask: number[] = [];
    hashes.forEach((h, i) => {
      const hit = this.cache.receipts[h];
      if (hit) {
        out[i] = hit;
        this.stats.cacheHits++;
      } else ask.push(i);
    });
    if (ask.length) {
      const replies = await this.batch(ask.map((i) => ['eth_getTransactionReceipt', [hashes[i]]] as const), true);
      ask.forEach((i, j) => {
        const r = replies[j] as (Receipt & { blockNumber: string }) | Error | null;
        if (r instanceof Error || !r) throw new Error(`eth_getTransactionReceipt(${hashes[i]}) failed: ${r instanceof Error ? r.message : 'no receipt'}`);
        const rec: Receipt = {
          status: r.status,
          gasUsed: r.gasUsed,
          contractAddress: r.contractAddress ?? null,
          logs: r.logs.map((l) => ({ address: l.address.toLowerCase(), topics: l.topics, data: l.data })),
        };
        out[i] = rec;
        if (this.final(Number(BigInt(r.blockNumber)))) {
          this.cache.receipts[hashes[i]] = rec;
          this.dirty = true;
        }
      });
    }
    return out;
  }

  /**
   * Every log of `address` matching `topics` in blocks `from .. head`, by eth_getLogs in chunks of LOG_CHUNK blocks
   * (ten queries per HTTP request, spaced like every other request). The part below the safe head is remembered,
   * so that a later run with the same `from` only asks for the blocks after it.
   */
  async scanLogs(address: string, topics: readonly (string | null)[], from: number, onProgress?: (done: number, total: number) => void): Promise<ScanLog[]> {
    const key = `${address.toLowerCase()}:${topics.map((t) => t ?? '*').join(',')}`;
    const stored = this.cache.scans[key];
    const base = stored && stored.from === from && stored.to <= this.safeHead() ? stored : null;
    if (base) this.stats.cacheHits++;
    const start = base ? base.to + 1 : from;
    const chunks: [number, number][] = [];
    for (let b = start; b <= this.head; b += LOG_CHUNK) chunks.push([b, Math.min(b + LOG_CHUNK - 1, this.head)]);
    const found: ScanLog[] = base ? [...base.logs] : [];
    for (let o = 0; o < chunks.length; o += 50) {
      const part = chunks.slice(o, o + 50);
      const replies = await this.batch(part.map(([a, b]) => ['eth_getLogs', [{ address, topics, fromBlock: hexBlock(a), toBlock: hexBlock(b) }]] as const));
      part.forEach(([a, b], j) => {
        const r = replies[j];
        if (r instanceof Error || !Array.isArray(r)) throw new Error(`eth_getLogs(${address}, blocks ${a}..${b}) failed: ${r instanceof Error ? r.message : 'no answer'}`);
        for (const l of r as { blockNumber: string; transactionHash: string; logIndex: string; address: string; topics: string[]; data: string; removed?: boolean }[]) {
          if (l.removed) continue;
          found.push({ blockNumber: Number(BigInt(l.blockNumber)), transactionHash: l.transactionHash, logIndex: Number(BigInt(l.logIndex)), address: l.address.toLowerCase(), topics: l.topics, data: l.data });
        }
      });
      onProgress?.(Math.min(o + 50, chunks.length), chunks.length);
    }
    found.sort((x, y) => x.blockNumber - y.blockNumber || x.logIndex - y.logIndex);
    if (this.cachePath) {
      const safe = this.safeHead();
      if (safe >= from) {
        this.cache.scans[key] = { from, to: safe, logs: found.filter((l) => l.blockNumber <= safe) };
        this.dirty = true;
      }
    }
    return found;
  }

  /** Block timestamps (unix seconds). */
  async blockTimes(blocks: readonly number[]): Promise<number[]> {
    const ask = [...new Set(blocks.filter((b) => !this.times.has(b)))];
    if (ask.length) {
      const replies = await this.batch(ask.map((b) => ['eth_getBlockByNumber', [hexBlock(b), false]] as const), true);
      ask.forEach((b, i) => {
        const r = replies[i] as { timestamp?: string } | Error | null;
        if (r instanceof Error || !r || !r.timestamp) throw new Error(`eth_getBlockByNumber(${b}) failed`);
        this.times.set(b, Number(BigInt(r.timestamp)));
      });
    }
    return blocks.map((b) => this.times.get(b) as number);
  }

  /** eth_call at the audit block. A revert is returned as the RpcError; a node failure throws. */
  async calls(reqs: readonly { to: string; data: string }[]): Promise<(string | RpcError)[]> {
    if (!reqs.length) return [];
    const replies = await this.batch(reqs.map((r) => ['eth_call', [{ to: r.to, data: r.data }, hexBlock(this.head)]] as const));
    return replies.map((r, i) => {
      if (r instanceof RpcError) return r;
      if (r instanceof Error) throw new Error(`eth_call to ${reqs[i].to} failed: ${r.message}`);
      return r as string;
    });
  }

  /** Runtime code at the audit block ("0x" for an address without code). */
  async codes(addresses: readonly string[]): Promise<string[]> {
    if (!addresses.length) return [];
    const replies = await this.batch(addresses.map((a) => ['eth_getCode', [a, hexBlock(this.head)]] as const));
    return replies.map((r, i) => {
      if (r instanceof Error) throw new Error(`eth_getCode(${addresses[i]}) failed: ${r.message}`);
      return r as string;
    });
  }
}

interface RawTx {
  hash: string;
  from: string;
  to: string | null;
  nonce: string;
  value: string;
  input: string;
  type?: string;
  transactionIndex: string;
  authorizationList?: RpcAuthorization[];
}

interface RawBlock {
  number: string;
  timestamp: string;
  transactions: RawTx[];
}

/** Keeps what concerns `address` (lower case) from a full block. */
export function reduceBlock(block: RawBlock, address: string): WalletBlock {
  const blockNumber = Number(BigInt(block.number));
  const timestamp = Number(BigInt(block.timestamp));
  const txs: Tx[] = [];
  const authorizations: AuthorizationUse[] = [];
  for (const t of block.transactions) {
    if (t.from.toLowerCase() === address) {
      txs.push({
        hash: t.hash,
        from: address,
        to: t.to ? t.to.toLowerCase() : null,
        nonce: Number(BigInt(t.nonce)),
        value: t.value,
        input: t.input,
        type: t.type ?? '0x0',
        blockNumber,
        timestamp,
        transactionIndex: Number(BigInt(t.transactionIndex)),
      });
    }
    for (const auth of t.authorizationList ?? []) {
      let authority: string | null = null;
      try {
        authority = recoverAddress(authorizationHash(auth), BigInt(auth.r), BigInt(auth.s), Number(BigInt(auth.yParity ?? auth.v ?? '0x0')));
      } catch {
        authority = null;
      }
      if (authority === address) {
        authorizations.push({ nonce: Number(BigInt(auth.nonce)), delegate: auth.address.toLowerCase(), carrier: t.hash, carrierFrom: t.from.toLowerCase() });
      }
    }
  }
  txs.sort((x, y) => x.nonce - y.nonce);
  return { timestamp, txs, authorizations };
}
