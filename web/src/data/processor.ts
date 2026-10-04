// What the processor page reads from X Layer. Everything is eth_call through Multicall3;
// nothing here can send a transaction. Kept apart from the circuit loader so the landing and
// processor pages do not pull in the simulator.

import { blockNumber, CallError, factory, processor, readAll, transistors, type CircuitInfo, type Rpc } from '@covenant/chain';
import { checksumAddress } from '@covenant/chain/keccak';

const ok = <T>(v: T | Error): T | null => (v instanceof Error ? null : v);

/** The chain answered, and the answer is that the thing asked for is not there. */
export class Missing extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'Missing';
  }
}

export interface ProcessorData {
  /** EIP-55 form. */
  address: string;
  /** `factory.isCPU(address)`; null if the factory could not be asked. */
  registered: boolean | null;
  name: string;
  symbol: string;
  /** `nextId()`: on X Layer, the number of circuits taped out (ids 1..circuits). */
  circuits: number;
  transistors: string | null;
  supplyCap: bigint | null;
  mintPrice: bigint | null;
  minted: bigint | null;
  story: string | null;
  cpuName: string | null;
  cpuSymbol: string | null;
  creator: string | null;
  block: bigint | null;
}

/** A processor and its transistor contract: two Multicall3 requests. */
export async function loadProcessor(rpc: Rpc, factoryAddress: string, address: string): Promise<ProcessorData> {
  const p = processor(address);
  const [name, symbol, next, tr, registered, block] = await readAll(rpc, [
    p.name(),
    p.symbol(),
    p.nextId(),
    p.transistors(),
    factory(factoryAddress).isCPU(address),
    blockNumber(),
  ] as const);
  if (next instanceof Error || tr instanceof Error) {
    // Distinguish "the node did not answer" from "this address is not a processor".
    const failed = next instanceof Error ? next : (tr as Error);
    if (!(failed instanceof CallError)) throw failed;
    throw new Missing(`${address} does not answer like a TapeOut processor (${next instanceof Error ? 'nextId' : 'transistors'}: ${failed.message})`);
  }
  const t = transistors(tr);
  const [supplyCap, mintPrice, minted, story, cpuName, cpuSymbol, creator] = await readAll(rpc, [
    t.supplyCap(),
    t.mintPrice(),
    t.minted(),
    t.story(),
    t.cpuName(),
    t.cpuSymbol(),
    t.creator(),
  ] as const);
  const creatorAddress = ok(creator);
  return {
    address: checksumAddress(address),
    registered: ok(registered),
    name: ok(name) ?? '',
    symbol: ok(symbol) ?? '',
    circuits: Number(next),
    transistors: checksumAddress(tr),
    supplyCap: ok(supplyCap),
    mintPrice: ok(mintPrice),
    minted: ok(minted),
    story: ok(story),
    cpuName: ok(cpuName),
    cpuSymbol: ok(cpuSymbol),
    creator: creatorAddress === null ? null : checksumAddress(creatorAddress),
    block: ok(block),
  };
}

export interface CircuitRow {
  id: number;
  info: CircuitInfo | null;
  owner: string | null;
}

/**
 * `circuitInfo` and `ownerOf` for ids `from..to` inclusive, through Multicall3 (no logs: the
 * public nodes cap eth_getLogs at 100 blocks). Ids that do not exist are left out.
 */
export async function loadCircuits(rpc: Rpc, address: string, from: number, to: number): Promise<CircuitRow[]> {
  const p = processor(address);
  const calls = [];
  for (let id = from; id <= to; id++) calls.push(p.circuitInfo(id), p.ownerOf(id));
  const out = await readAll(rpc, calls);
  const rows: CircuitRow[] = [];
  for (let id = from; id <= to; id++) {
    const info = out[2 * (id - from)];
    const owner = out[2 * (id - from) + 1];
    if (info instanceof CallError && owner instanceof CallError) continue; // no such circuit
    if (info instanceof Error && !(info instanceof CallError)) throw info; // the node failed
    rows.push({
      id,
      info: info instanceof Error ? null : (info as CircuitInfo),
      owner: owner instanceof Error ? null : checksumAddress(owner as string),
    });
  }
  return rows;
}
