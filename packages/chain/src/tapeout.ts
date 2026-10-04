// The TapeOut read-only surface used by Covenant, as typed call descriptors.
// Selectors are written out next to their signatures; src/signatures.ts lists them all and
// test/abi.test.ts recomputes every one.

import {
  addressWord,
  bytesTail,
  decAddress,
  decAggregate3,
  decBool,
  decBytes,
  decCircuitInfo,
  decStep,
  decString,
  decUint,
  encAggregate3,
  revertReason,
  word,
  type CircuitInfo,
  type StepResult,
} from './abi.ts';
import { RpcError, type Rpc } from './rpc.ts';

/** Multicall3, same address on every chain; deployed on X Layer. */
export const MULTICALL3 = '0xcA11bde05977b3631167028862bE2a173976CA11';

/** A read-only call: where, what, and how to decode the answer. */
export interface Call<T> {
  to: string;
  data: string;
  decode: (ret: string) => T;
}

const mk = <T>(to: string, selector: string, args: string, decode: (ret: string) => T): Call<T> => ({
  to,
  data: '0x' + selector + args,
  decode,
});

type Id = number | bigint;

/** The processor factory. */
export const factory = (at: string) => ({
  /** cpuCount() */
  cpuCount: (): Call<bigint> => mk(at, 'a94da8a7', '', decUint),
  /** cpuAt(uint256) */
  cpuAt: (i: Id): Call<string> => mk(at, '4bc7cbbd', word(i), decAddress),
  /** isCPU(address) */
  isCPU: (cpu: string): Call<boolean> => mk(at, '5f5a364f', addressWord(cpu), decBool),
});

/** A processor: the ERC-721 "Circuits" contract that stores and evaluates netlists. */
export const processor = (at: string) => ({
  /** name() */
  name: (): Call<string> => mk(at, '06fdde03', '', decString),
  /** symbol() */
  symbol: (): Call<string> => mk(at, '95d89b41', '', decString),
  /**
   * nextId(). Circuit ids start at 1. Measured on X Layer (2026-10-04): this returns the number
   * of circuits taped out, i.e. the highest existing id (`circuitInfo(nextId)` answers and
   * `circuitInfo(nextId + 1)` reverts `no circuit`), although TAP-20 section 6 describes it as
   * "the id the next taped-out circuit will get". Treat ids 1..nextId as candidates and let a
   * `no circuit` revert on the last one decide.
   */
  nextId: (): Call<bigint> => mk(at, '61b8ce8c', '', decUint),
  /** ownerOf(uint256) */
  ownerOf: (id: Id): Call<string> => mk(at, '6352211e', word(id), decAddress),
  /** circuitInfo(uint256) returns (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount) */
  circuitInfo: (id: Id): Call<CircuitInfo> => mk(at, '084d60f1', word(id), decCircuitInfo),
  /** netlist(uint256) returns (bytes) */
  netlist: (id: Id): Call<string> => mk(at, '3fc4be56', word(id), decBytes),
  /** eval(uint256,bytes): one beat of a circuit without state; reverts `has latch: use step` otherwise */
  eval: (id: Id, inputs: string): Call<string> => mk(at, '934d06ea', word(id) + word(64) + bytesTail(inputs), decBytes),
  /** step(uint256,bytes,bytes) returns (bytes newState, bytes outputs): one beat with caller-supplied state */
  step: (id: Id, state: string, inputs: string): Call<StepResult> => {
    const st = bytesTail(state);
    return mk(at, 'e8281a1a', word(id) + word(96) + word(96 + st.length / 2) + st + bytesTail(inputs), decStep);
  },
  /** transistors(): the processor's ERC-1155 contract */
  transistors: (): Call<string> => mk(at, '6fbd1719', '', decAddress),
});

/** A processor's ERC-1155 transistor contract. */
export const transistors = (at: string) => ({
  /** supplyCap() */
  supplyCap: (): Call<bigint> => mk(at, '8f770ad0', '', decUint),
  /** mintPrice(), in wei of OKB */
  mintPrice: (): Call<bigint> => mk(at, '6817c76c', '', decUint),
  /** minted() */
  minted: (): Call<bigint> => mk(at, '4f02c420', '', decUint),
  /** story() */
  story: (): Call<string> => mk(at, '46c922d1', '', decString),
  /** cpuName() */
  cpuName: (): Call<string> => mk(at, '700ed104', '', decString),
  /** cpuSymbol() */
  cpuSymbol: (): Call<string> => mk(at, '91254d67', '', decString),
  /** creator() */
  creator: (): Call<string> => mk(at, '02d05d3f', '', decAddress),
});

/**
 * Multicall3 `getBlockNumber()`. Put it in the same `readAll` as other calls to learn the block
 * they were all evaluated at (one `aggregate3` runs in one block).
 */
export const blockNumber = (multicall: string = MULTICALL3): Call<bigint> => mk(multicall, '42cbb15c', '', decUint);

/** A call that reverted, or whose return data did not decode. */
export class CallError extends Error {
  readonly data: string | undefined;

  constructor(message: string, data?: string) {
    super(message);
    this.name = 'CallError';
    this.data = data;
  }
}

/** One direct `eth_call`. A revert is thrown as `CallError` carrying the decoded reason. */
export async function read<T>(rpc: Rpc, c: Call<T>): Promise<T> {
  let ret: string;
  try {
    ret = await rpc.call(c.to, c.data);
  } catch (e) {
    if (e instanceof RpcError && e.data !== undefined) throw new CallError(revertReason(e.data), e.data);
    throw e;
  }
  return c.decode(ret);
}

type Results<T extends readonly Call<unknown>[]> = { -readonly [K in keyof T]: T[K] extends Call<infer R> ? R | Error : never };

export interface ReadAllOptions {
  /** Multicall3 address. */
  multicall?: string;
  /** Sub-calls per `aggregate3` call. Default 100. */
  chunk?: number;
}

/**
 * Many calls through Multicall3 `aggregate3` with `allowFailure`, so one failing call does not
 * hide the others. Each entry of the result is the decoded value or an `Error`.
 * The `aggregate3` calls themselves go out in JSON-RPC batches of at most 10.
 */
export async function readAll<const T extends readonly Call<unknown>[]>(
  rpc: Rpc,
  calls: T,
  opts: ReadAllOptions = {},
): Promise<Results<T>> {
  const to = opts.multicall ?? MULTICALL3;
  const chunk = opts.chunk ?? 100;
  const reqs: [string, unknown[]][] = [];
  for (let o = 0; o < calls.length; o += chunk) {
    reqs.push(['eth_call', [{ to, data: encAggregate3(calls.slice(o, o + chunk)) }, 'latest']]);
  }
  // One entry per aggregate3 call: its decoded sub-results, or the error that replaced them.
  const groups = (await rpc.batch(reqs)).map((reply) => {
    try {
      return reply instanceof Error ? reply : decAggregate3(reply as string);
    } catch (e) {
      return e as Error;
    }
  });
  const out = calls.map((c, i) => {
    const group = groups[Math.floor(i / chunk)];
    if (group instanceof Error) return group;
    const sub = group[i % chunk];
    if (!sub) return new CallError('missing from the aggregate3 result');
    if (!sub.success) return new CallError(revertReason(sub.data), sub.data);
    try {
      return c.decode(sub.data);
    } catch (e) {
      return new CallError((e as Error).message, sub.data);
    }
  });
  return out as Results<T>;
}
