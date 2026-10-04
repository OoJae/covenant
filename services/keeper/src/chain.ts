// The chain as the scheduler sees it, and the JSON-RPC implementation of it.
// Plain fetch on purpose: retries, RPC switching and backoff are decided in one place (pool.ts), not in a transport.

import { decodeAbiParameters } from 'viem';
import type { Address, Hex } from 'viem';
import { CALLDATA, knownErrorName, remainingOfCalldata } from './abi.ts';
import type { LogLite } from './abi.ts';
import {
  InsufficientFundsError,
  NonceTooLowError,
  RevertError,
  RpcError,
  TxRejectedError,
  UnderpricedError,
} from './errors.ts';

export interface KernelView {
  epochNow: number;
  lastEpoch: number;
}

export interface CallRequest {
  from: Address;
  to: Address;
  data: Hex;
  gas?: bigint;
  maxFeePerGas?: bigint;
  maxPriorityFeePerGas?: bigint;
}

export interface Receipt {
  transactionHash: Hex;
  status: 'success' | 'reverted';
  blockNumber: bigint;
  gasUsed: bigint;
  effectiveGasPrice: bigint;
  /** OP-stack data fee. X Layer reports it; it is 0 at the time of writing. */
  l1Fee: bigint;
  logs: LogLite[];
}

export interface ChainClient {
  /** Host name only: safe to log. */
  readonly label: string;
  chainId(): Promise<number>;
  hasCode(address: Address): Promise<boolean>;
  chipId(kernel: Address): Promise<bigint>;
  epochs(kernel: Address): Promise<KernelView>;
  minSettleGas(kernel: Address): Promise<bigint>;
  /** KeeperTank.remainingOf(chipId): wei still available to refund settles of this chip. */
  tankRemaining(tank: Address, chipId: bigint): Promise<bigint>;
  baseFee(): Promise<bigint>;
  balance(address: Address): Promise<bigint>;
  nonces(address: Address): Promise<{ latest: number; pending: number }>;
  estimateGas(call: CallRequest): Promise<bigint>;
  /** eth_call at the latest block. Resolves when the call succeeds; throws RevertError when it would revert. */
  simulate(call: CallRequest): Promise<Hex>;
  /** Broadcast signed bytes. Resolves when the node accepted them or already had them. */
  sendRaw(raw: Hex): Promise<void>;
  receipt(hash: Hex): Promise<Receipt | null>;
}

type FetchFn = (
  input: string,
  init: { method: string; headers: Record<string, string>; body: string; signal: AbortSignal },
) => Promise<{ ok: boolean; status: number; json(): Promise<unknown> }>;

const hex = (n: bigint | number): Hex => `0x${BigInt(n).toString(16)}`;

/** Turn revert data into something a person can read. */
export function decodeRevert(data: string | undefined | null, message: string): string {
  if (data && data.startsWith('0x08c379a0') && data.length >= 138) {
    try {
      const [reason] = decodeAbiParameters([{ type: 'string' }], `0x${data.slice(10)}`);
      if (reason) return reason;
    } catch {
      // fall through
    }
  }
  if (data && data.startsWith('0x4e487b71') && data.length >= 74) {
    return `panic 0x${BigInt(`0x${data.slice(10, 74)}`).toString(16)}`;
  }
  if (data && data.length >= 10) {
    // A custom error of the kernel or the tank, by name when it is one we know.
    const known = knownErrorName(data);
    if (known) return known;
  }
  const m = /execution reverted:?\s*(.*)$/i.exec(message);
  if (m && m[1]) return m[1];
  if (data && data.length >= 10) return `custom error ${data.slice(0, 10)}`;
  return message && !/^execution reverted$/i.test(message) ? message : 'no reason given';
}

const REVERT_RE =
  /execution reverted|out of gas|gas required exceeds|invalid opcode|invalid jump|stack underflow|stack overflow|always failing transaction|contract creation code storage out of gas/i;
const FUNDS_RE = /insufficient funds|insufficient balance|exceeds transaction sender account balance/i;

class AlreadyKnown extends Error {}

/** Map a JSON-RPC error object to the keeper's error classes. Exported for tests. */
export function classifyNodeError(host: string, method: string, code: number, message: string, data?: string): Error {
  if (method === 'eth_sendRawTransaction') {
    if (/already known|already imported|already exists|known transaction/i.test(message)) return new AlreadyKnown();
    if (/nonce too low|nonce is too low|old nonce/i.test(message)) return new NonceTooLowError(message);
    if (/underpriced/i.test(message)) return new UnderpricedError(message);
    if (FUNDS_RE.test(message)) return new InsufficientFundsError(message);
    // A malformed or rejected transaction is not something another RPC would accept.
    if (
      code === -32602 ||
      /invalid sender|invalid signature|rlp:|tx type not supported|exceeds block gas limit|max fee per gas less than block base fee|intrinsic gas too low|invalid chain id/i.test(
        message,
      )
    ) {
      return new TxRejectedError(message.slice(0, 160));
    }
  }
  if (method === 'eth_call' || method === 'eth_estimateGas') {
    if (FUNDS_RE.test(message)) return new InsufficientFundsError(message);
    if (code === 3 || REVERT_RE.test(message)) return new RevertError(decodeRevert(data, message), data ?? null);
  }
  return new RpcError(host, method, `node error ${code}: ${message.slice(0, 160)}`);
}

/**
 * A short label for a failed fetch: an error code such as ECONNREFUSED, or "timeout".
 * Never the raw error text: it can contain the URL, and the URL can contain an API key.
 */
export function networkErrorKind(err: unknown): string {
  const e = err as { name?: unknown; code?: unknown; cause?: { code?: unknown; errors?: Array<{ code?: unknown }> } };
  if (e?.name === 'TimeoutError' || e?.name === 'AbortError') return 'timeout';
  const candidates = [e?.cause?.code, e?.cause?.errors?.[0]?.code, e?.code];
  for (const c of candidates) {
    if (typeof c === 'string' && /^[A-Z][A-Z0-9_]{2,40}$/.test(c)) return c;
  }
  return 'network error';
}

export interface JsonRpcOptions {
  timeoutMs?: number;
  fetch?: FetchFn;
}

export class JsonRpcChainClient implements ChainClient {
  readonly label: string;
  readonly #url: string;
  readonly #timeoutMs: number;
  readonly #fetch: FetchFn;
  #id = 0;

  constructor(url: string, options: JsonRpcOptions = {}) {
    this.#url = url;
    this.#timeoutMs = options.timeoutMs ?? 20_000;
    this.#fetch = options.fetch ?? ((input, init) => fetch(input, init));
    let host = 'rpc';
    try {
      host = new URL(url).host;
    } catch {
      // config.ts has already validated the URL; keep the generic label
    }
    this.label = host;
  }

  async #request(method: string, params: unknown[]): Promise<unknown> {
    let res: { ok: boolean; status: number; json(): Promise<unknown> };
    try {
      res = await this.#fetch(this.#url, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: ++this.#id, method, params }),
        signal: AbortSignal.timeout(this.#timeoutMs),
      });
    } catch (err) {
      throw new RpcError(this.label, method, networkErrorKind(err));
    }
    if (!res.ok) throw new RpcError(this.label, method, `http ${res.status}`);
    let body: unknown;
    try {
      body = await res.json();
    } catch {
      throw new RpcError(this.label, method, 'response is not JSON');
    }
    if (!body || typeof body !== 'object') throw new RpcError(this.label, method, 'response is not an object');
    const b = body as { result?: unknown; error?: { code?: unknown; message?: unknown; data?: unknown } };
    if (b.error) {
      const code = typeof b.error.code === 'number' ? b.error.code : 0;
      const message = typeof b.error.message === 'string' ? b.error.message : 'unknown error';
      const data = typeof b.error.data === 'string' ? b.error.data : undefined;
      throw classifyNodeError(this.label, method, code, message, data);
    }
    if (!('result' in b)) throw new RpcError(this.label, method, 'response has neither result nor error');
    return b.result;
  }

  async #quantity(method: string, params: unknown[]): Promise<bigint> {
    const r = await this.#request(method, params);
    if (typeof r !== 'string' || !/^0x[0-9a-fA-F]+$/.test(r)) throw new RpcError(this.label, method, 'result is not a quantity');
    return BigInt(r);
  }

  /** A view that returns one 32-byte word. Empty return data means the address has no such function (or no code). */
  async #word(to: Address, data: Hex, what: string): Promise<bigint> {
    const r = await this.#request('eth_call', [{ to, data }, 'latest']);
    if (typeof r !== 'string' || !/^0x[0-9a-fA-F]*$/.test(r)) throw new RpcError(this.label, 'eth_call', 'result is not hex');
    if (r.length < 66) throw new RevertError(`${what}() returned no data: the address does not implement it`);
    return BigInt(r.slice(0, 66));
  }

  async chainId(): Promise<number> {
    return Number(await this.#quantity('eth_chainId', []));
  }

  async hasCode(address: Address): Promise<boolean> {
    const r = await this.#request('eth_getCode', [address, 'latest']);
    if (typeof r !== 'string') throw new RpcError(this.label, 'eth_getCode', 'result is not hex');
    return r.length > 2;
  }

  chipId(kernel: Address): Promise<bigint> {
    return this.#word(kernel, CALLDATA.chipId, 'chipId');
  }

  async epochs(kernel: Address): Promise<KernelView> {
    const [now, last] = await Promise.all([
      this.#word(kernel, CALLDATA.epochNow, 'epochNow'),
      this.#word(kernel, CALLDATA.lastEpoch, 'lastEpoch'),
    ]);
    return { epochNow: Number(now), lastEpoch: Number(last) };
  }

  minSettleGas(kernel: Address): Promise<bigint> {
    return this.#word(kernel, CALLDATA.minSettleGas, 'minSettleGas');
  }

  tankRemaining(tank: Address, chipId: bigint): Promise<bigint> {
    return this.#word(tank, remainingOfCalldata(chipId), 'remainingOf');
  }

  async baseFee(): Promise<bigint> {
    const block = (await this.#request('eth_getBlockByNumber', ['latest', false])) as { baseFeePerGas?: unknown } | null;
    const v = block?.baseFeePerGas;
    if (typeof v !== 'string' || !/^0x[0-9a-fA-F]+$/.test(v)) {
      throw new RpcError(this.label, 'eth_getBlockByNumber', 'latest block has no baseFeePerGas');
    }
    return BigInt(v);
  }

  balance(address: Address): Promise<bigint> {
    return this.#quantity('eth_getBalance', [address, 'latest']);
  }

  async nonces(address: Address): Promise<{ latest: number; pending: number }> {
    const [latest, pending] = await Promise.all([
      this.#quantity('eth_getTransactionCount', [address, 'latest']),
      this.#quantity('eth_getTransactionCount', [address, 'pending']),
    ]);
    return { latest: Number(latest), pending: Number(pending) };
  }

  #callObject(call: CallRequest): Record<string, string> {
    const o: Record<string, string> = { from: call.from, to: call.to, data: call.data, value: '0x0' };
    if (call.gas !== undefined) o['gas'] = hex(call.gas);
    if (call.maxFeePerGas !== undefined) o['maxFeePerGas'] = hex(call.maxFeePerGas);
    if (call.maxPriorityFeePerGas !== undefined) o['maxPriorityFeePerGas'] = hex(call.maxPriorityFeePerGas);
    return o;
  }

  estimateGas(call: CallRequest): Promise<bigint> {
    return this.#quantity('eth_estimateGas', [this.#callObject(call)]);
  }

  async simulate(call: CallRequest): Promise<Hex> {
    const r = await this.#request('eth_call', [this.#callObject(call), 'latest']);
    if (typeof r !== 'string' || !r.startsWith('0x')) throw new RpcError(this.label, 'eth_call', 'result is not hex');
    return r as Hex;
  }

  async sendRaw(raw: Hex): Promise<void> {
    try {
      await this.#request('eth_sendRawTransaction', [raw]);
    } catch (err) {
      if (err instanceof AlreadyKnown) return;
      throw err;
    }
  }

  async receipt(hash: Hex): Promise<Receipt | null> {
    const r = (await this.#request('eth_getTransactionReceipt', [hash])) as Record<string, unknown> | null;
    if (r === null || r === undefined) return null;
    const isQuantity = (v: unknown): v is string => typeof v === 'string' && /^0x[0-9a-fA-F]+$/.test(v);
    const q = (v: unknown): bigint => (isQuantity(v) ? BigInt(v) : 0n);
    if (typeof r !== 'object' || !isQuantity(r['status']) || !isQuantity(r['blockNumber'])) {
      throw new RpcError(this.label, 'eth_getTransactionReceipt', 'receipt is missing status or blockNumber');
    }
    const logs: LogLite[] = [];
    if (Array.isArray(r['logs'])) {
      for (const l of r['logs'] as Array<Record<string, unknown>>) {
        if (typeof l?.['address'] === 'string' && Array.isArray(l['topics']) && typeof l['data'] === 'string') {
          logs.push({ address: l['address'], topics: (l['topics'] as unknown[]).map(String), data: l['data'] });
        }
      }
    }
    return {
      transactionHash: hash,
      status: BigInt(r['status']) === 1n ? 'success' : 'reverted',
      blockNumber: q(r['blockNumber']),
      gasUsed: q(r['gasUsed']),
      effectiveGasPrice: q(r['effectiveGasPrice']),
      l1Fee: q(r['l1Fee']),
      logs,
    };
  }
}
