// What the circuit page reads from X Layer and how a beat is checked against the chain.
// Free of any DOM, so the same code runs in scripts/verify-live.ts and in the tests.
// Everything is eth_call; nothing here can send a transaction.

import { blockNumber, CallError, factory, processor, read, readAll, toBytes, toHex, type CircuitInfo, type Rpc } from '@covenant/chain';
import { checksumAddress, keccak256Hex } from '@covenant/chain/keccak';
import { canonical, load, step, type Fetcher, type Netlist } from '@covenant/tap20';
import { Missing } from './processor.ts';

const ok = <T>(v: T | Error): T | null => (v instanceof Error ? null : v);

export interface RefTarget {
  cpu: string;
  id: bigint;
  info: CircuitInfo;
}

export interface CircuitData {
  processor: string;
  id: bigint;
  /** `circuitInfo(id)` as the chain reports it. */
  info: CircuitInfo;
  owner: string | null;
  processorName: string | null;
  /** `factory.isCPU(processor)`. */
  registered: boolean | null;
  /** Block at which the netlist was read. */
  block: bigint | null;
  /** The netlist exactly as stored. */
  bytes: Uint8Array;
  /** keccak256 of those bytes. */
  keccak: string;
  /** Decoded and checked by this site's own TAP-20 implementation. */
  netlist: Netlist;
  /** Circuits reached through REF records, fetched and checked the same way. */
  refs: RefTarget[];
  /** Whether the state bits and gate count we decode equal what `circuitInfo` reports. */
  consistent: boolean;
}

/**
 * A fetcher for REF targets (TAP-20 section 3, condition 6): the target must be a circuit that
 * exists on a processor registered with the factory.
 */
export function refFetcher(rpc: Rpc, factoryAddress: string, seen?: RefTarget[]): Fetcher {
  return async (cpu, id) => {
    const p = processor(cpu);
    const [registered, info, hex] = await readAll(rpc, [factory(factoryAddress).isCPU(cpu), p.circuitInfo(id), p.netlist(id)] as const);
    for (const v of [registered, info, hex]) if (v instanceof Error && !(v instanceof CallError)) throw v;
    if (registered !== true || info instanceof Error || hex instanceof Error) return undefined;
    seen?.push({ cpu: checksumAddress(cpu), id, info });
    return { netlist: toBytes(hex), nIn: info.nIn, nOut: info.nOut };
  };
}

/** One circuit: its facts and its netlist in one Multicall3 request, plus one per REF target. */
export async function loadCircuit(rpc: Rpc, factoryAddress: string, address: string, id: bigint): Promise<CircuitData> {
  const p = processor(address);
  const [info, hex, owner, name, registered, block] = await readAll(rpc, [
    p.circuitInfo(id),
    p.netlist(id),
    p.ownerOf(id),
    p.name(),
    factory(factoryAddress).isCPU(address),
    blockNumber(),
  ] as const);
  if (info instanceof Error || hex instanceof Error) {
    const e = info instanceof Error ? info : (hex as Error);
    if (!(e instanceof CallError)) throw e;
    throw new Missing(`circuit ${id} of ${address} could not be read: ${e.message}`);
  }
  const bytes = toBytes(hex);
  const refs: RefTarget[] = [];
  const netlist = await load(bytes, info.nIn, info.nOut, refFetcher(rpc, factoryAddress, refs));
  const ownerAddress = ok(owner);
  return {
    processor: checksumAddress(address),
    id,
    info,
    owner: ownerAddress === null ? null : checksumAddress(ownerAddress),
    processorName: ok(name),
    registered: ok(registered),
    block: ok(block),
    bytes,
    keccak: keccak256Hex(bytes),
    netlist,
    refs,
    consistent: netlist.nState === info.nState && netlist.gateCount === info.gateCount,
  };
}

export interface BeatResult {
  /** Packed, canonical, as hex with 0x. */
  newState: string;
  outputs: string;
}

/** One beat computed here, by this site's simulator. Also returns every signal for the drawing. */
export function localBeat(nl: Netlist, state: Uint8Array, inputs: Uint8Array): BeatResult & { signals: Uint8Array; newStateBytes: Uint8Array } {
  const r = step(nl, state, inputs);
  return { newState: toHex(r.newState), outputs: toHex(r.outputs), signals: r.signals, newStateBytes: r.newState };
}

/** Which contract function checks a beat: `eval` for a circuit without state, `step` otherwise. */
export const beatMethod = (nState: number): 'eval' | 'step' => (nState === 0 ? 'eval' : 'step');

/**
 * The same beat computed by the chain: one free, direct eth_call to the processor
 * (`eval(id, inputs)` or `step(id, state, inputs)`), exactly what the printed `cast call` runs.
 */
export async function chainBeat(rpc: Rpc, address: string, id: bigint, nState: number, state: Uint8Array, inputs: Uint8Array): Promise<BeatResult> {
  const p = processor(address);
  if (nState === 0) return { newState: '0x', outputs: await read(rpc, p.eval(id, toHex(inputs))) };
  return read(rpc, p.step(id, toHex(state), toHex(inputs)));
}

export const sameBeat = (a: BeatResult, b: BeatResult): boolean => a.newState === b.newState && a.outputs === b.outputs;

/** The terminal command that reproduces `chainBeat`. */
export function castLine(address: string, id: bigint, nState: number, state: Uint8Array, inputs: Uint8Array, rpcUrl: string): string {
  return nState === 0
    ? `cast call ${address} "eval(uint256,bytes)(bytes)" ${id} ${toHex(inputs)} --rpc-url ${rpcUrl}`
    : `cast call ${address} "step(uint256,bytes,bytes)(bytes,bytes)" ${id} ${toHex(state)} ${toHex(inputs)} --rpc-url ${rpcUrl}`;
}

/** Terminal commands that reproduce the facts shown for a circuit. */
export function castFacts(address: string, id: bigint, rpcUrl: string): { label: string; line: string }[] {
  return [
    { label: 'pins, state bits, gates', line: `cast call ${address} "circuitInfo(uint256)(uint32,uint32,uint32,uint32)" ${id} --rpc-url ${rpcUrl}` },
    { label: 'keccak256 of the netlist', line: `cast call ${address} "netlist(uint256)(bytes)" ${id} --rpc-url ${rpcUrl} | cast keccak` },
    { label: 'owner', line: `cast call ${address} "ownerOf(uint256)(address)" ${id} --rpc-url ${rpcUrl}` },
  ];
}

/** Packed bytes of exactly ceil(n / 8) bytes from whatever the user typed (hex, already validated). */
export const packedFromHex = (hex: string, n: number): Uint8Array => canonical(toBytes(hex), n);
