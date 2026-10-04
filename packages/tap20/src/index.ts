// @covenant/tap20: TAP-20 netlist format and one-beat evaluation, in TypeScript.
//
// Implements TAP-20 "Circuit Netlist Format and Evaluation Semantics" (CC0,
// https://github.com/TapeOutProtocol/TAPs/blob/main/TAPs/TAP-20.md). The structure follows the
// TAP's MIT reference implementation (assets/tap-20/reference.py); this is an independent port.

export {
  NAND,
  LATCH,
  REF,
  MAX_PINS,
  MAX_SIGNALS,
  MAX_STATE,
  MAX_GATES,
  Tap20Error,
  parse,
  encode,
  listRefs,
  refKey,
} from './parse.ts';
export type { Netlist, RefRecord, RefHeader, Resolver, Tap20ErrorCode } from './parse.ts';

export { step, stepBits, evaluate, DEFAULT_MAX_GATES, DEFAULT_MAX_DEPTH } from './sim.ts';
export type { Beat, Limits } from './sim.ts';

export { load } from './load.ts';
export type { CircuitSource, Fetcher, LoadOptions } from './load.ts';

export { packBits, unpackBits, getBit, setBit, canonical, byteLength, bytesToHex, hexToBytes } from './bits.ts';
