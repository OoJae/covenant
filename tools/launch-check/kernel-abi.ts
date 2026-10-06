// Every read these tools make of a Covenant kernel (and of its factory) goes through this ONE module.
//
// WHERE EACH PART COMES FROM
//
//   chips/INTERFACE.md, revision 2 (2026-10-05):
//       section 7   struct Envelope (declared there since revision 2)
//       section 10  kernel ABI v1: token() vault() chipId() count() records(uint32) envelope() ...,
//                   struct Record (with `nativeIn` since revision 2), and IKernelFactoryV1.isKernel / kernelOf
//   contracts/core, not frozen by the document:
//       struct Globals and globals()        contracts/core/src/interfaces/IKernelExt.sol
//                                            (`sealedFloor` was added as its last field in revision 2)
//   kernel v2 (USD₮0 quote, chips/INTERFACE-V2.md):
//       struct GlobalsV2, globals(), quote(), quoteShift()   contracts/core-v2/src/interfaces/IKernelV2.sol
//       (kernel v1's ABI otherwise: token() vault() chipId() count() envelope() ... and isKernel / kernelOf on the
//        KernelFactoryV2; RecordV2 has Record's 14-word layout with `quoteIn` in place of `nativeIn`)
//
// test/kernel-abi.test.ts parses those Solidity sources (and the Solidity blocks of INTERFACE.md, and the
// copies in sim/src/Interfaces.sol) and fails when any struct below, or any function signature used below,
// no longer matches them. A drift therefore fails `node --test`; it is never skipped.
//
// The decoders are strict on purpose: a return of any other length, or a word that does not fit its type,
// is an error ("the kernel does not have the ABI this tool was written for"), never a guess.

import { keccak256 } from '../../packages/chain/src/keccak.ts';
import { addressWord, bytesToHex, strip0x, word } from './hex.ts';

/** The sources this module was last compared with (informational; the layout tests decide). */
export const KERNEL_ABI_SNAPSHOT = {
  readAtUtc: '2026-10-06T12:00:00Z', // IKernelV2.sol: 2026-10-06T21:00:00Z
  interfaceRevision: 2,
  sources: [
    { file: 'chips/INTERFACE.md', sha256: '6d35f54e424f1656760d72af55506ffb33bf5b31def9f5cedcf1b7ff63532b29', gives: 'struct Envelope (section 7), struct Record and the kernel ABI (section 10)' },
    { file: 'contracts/core/src/interfaces/IKernelV1.sol', sha256: 'c273bc7e1cb514cca3a23ae9d573570e55566fdbe08d27ec947db251b8c4349a', gives: 'struct Envelope, struct Record, IKernelV1' },
    { file: 'contracts/core/src/interfaces/IKernelExt.sol', sha256: '5cd4406f60120fccd665928505b380baaec8c6b628a66bae9db538cbf5fe2c7a', gives: 'struct Globals and globals()' },
    { file: 'contracts/core/src/KernelFactory.sol', sha256: 'ddb7a9ef6bc6fc03e2623ba10d4e3a8bb3db11ac80a388e268e6ff1186605106', gives: 'isKernel(address), kernelOf(address), step gas constants' },
    { file: 'contracts/core-v2/src/interfaces/IKernelV2.sol', sha256: '06258b45f6d0d2c0ec07ee25bde9a201c922c7435ac158e1a1a85df89384d953', gives: 'struct GlobalsV2, struct RecordV2, IKernelV2 (kernel v2, USD₮0 quote)' },
  ],
} as const;

export type FieldType = 'address' | 'bool' | 'bytes12' | 'bytes14' | 'bytes32' | 'uint8' | 'uint16' | 'uint32' | 'uint40' | 'uint128' | 'uint256';
export type Field = readonly [name: string, type: FieldType];

/** `struct Envelope`, in declaration order (INTERFACE.md section 7). */
export const ENVELOPE_FIELDS = [
  ['launcher', 'address'],
  ['epochLen', 'uint32'],
  ['allowancePayee', 'address'],
  ['capT', 'uint16'],
  ['capV', 'uint16'],
  ['allowCumBps', 'uint16'],
  ['ceilMax', 'uint16'],
  ['relMax', 'uint16'],
  ['floorRel', 'uint16'],
  ['floorMin', 'uint16'],
  ['fallbackEpochs', 'uint16'],
  ['fbAllow', 'uint16'],
  ['buyEnabled', 'bool'],
  ['sink', 'address'],
] as const satisfies readonly Field[];

/** `struct Globals`, in declaration order (contracts/core IKernelExt.sol; not frozen by INTERFACE.md). */
export const GLOBALS_FIELDS = [
  ['manager', 'address'],
  ['v2Router', 'address'],
  ['wokb', 'address'],
  ['factory', 'address'],
  ['circuits', 'address'],
  ['fab', 'address'],
  ['sealedVM', 'address'],
  ['beacon', 'address'],
  ['impl0', 'address'],
  ['impl0Hash', 'bytes32'],
  ['snapshot', 'address'],
  ['netlistHash', 'bytes32'],
  ['chipId', 'uint256'],
  ['nState', 'uint32'],
  ['gateCount', 'uint32'],
  ['netlistLen', 'uint32'],
  ['stepFloor', 'uint256'],
  ['sealedFloor', 'uint256'],
] as const satisfies readonly Field[];

/**
 * `struct GlobalsV2` of kernel v2 (contracts/core-v2/src/interfaces/IKernelV2.sol): kernel v1's Globals with the
 * quote asset in place of `wokb`, and the code shift in bits as the last field.
 */
export const GLOBALS_V2_FIELDS = [
  ['manager', 'address'],
  ['v2Router', 'address'],
  ['quote', 'address'],
  ['factory', 'address'],
  ['circuits', 'address'],
  ['fab', 'address'],
  ['sealedVM', 'address'],
  ['beacon', 'address'],
  ['impl0', 'address'],
  ['impl0Hash', 'bytes32'],
  ['snapshot', 'address'],
  ['netlistHash', 'bytes32'],
  ['chipId', 'uint256'],
  ['nState', 'uint32'],
  ['gateCount', 'uint32'],
  ['netlistLen', 'uint32'],
  ['stepFloor', 'uint256'],
  ['sealedFloor', 'uint256'],
  ['quoteShift', 'uint256'],
] as const satisfies readonly Field[];

/** `struct Record`, in declaration order (INTERFACE.md section 10). */
export const RECORD_FIELDS = [
  ['epoch', 'uint32'],
  ['time', 'uint40'],
  ['clampBits', 'uint16'],
  ['flags', 'uint8'],
  ['inputs', 'bytes12'],
  ['outputs', 'bytes14'],
  ['stateAfter', 'bytes32'],
  ['inflow', 'uint128'],
  ['reserveBefore', 'uint128'],
  ['allow', 'uint128'],
  ['buyDecided', 'uint128'],
  ['buyExecuted', 'uint128'],
  ['tokensOut', 'uint128'],
  ['nativeIn', 'uint128'],
] as const satisfies readonly Field[];

/**
 * Step gas the KernelFactory writes into a kernel (contracts/core/src/KernelFactory.sol `_args`):
 * TapeOut's evaluator gets 200,000 + 2,600 per gate + 800 per latch, the sealed evaluator
 * 40,000 + 200 per NAND + 400 per latch. Exported for the tests and for anyone reading a kernel's globals.
 */
export const STEP_GAS = { base: 200_000n, perGate: 2_600n, perLatch: 800n } as const;
export const SEALED_GAS = { base: 40_000n, perNand: 200n, perLatch: 400n } as const;
export const stepFloorOf = (gateCount: bigint, nState: bigint): bigint => STEP_GAS.base + STEP_GAS.perGate * gateCount + STEP_GAS.perLatch * nState;
export const sealedFloorOf = (gateCount: bigint, nState: bigint): bigint => SEALED_GAS.base + SEALED_GAS.perNand * (gateCount - nState) + SEALED_GAS.perLatch * nState;

export interface Envelope {
  launcher: string;
  epochLen: bigint;
  allowancePayee: string;
  capT: bigint;
  capV: bigint;
  allowCumBps: bigint;
  ceilMax: bigint;
  relMax: bigint;
  floorRel: bigint;
  floorMin: bigint;
  fallbackEpochs: bigint;
  fbAllow: bigint;
  buyEnabled: boolean;
  sink: string;
}

export interface Globals {
  manager: string;
  v2Router: string;
  wokb: string;
  factory: string;
  circuits: string;
  fab: string;
  sealedVM: string;
  beacon: string;
  impl0: string;
  impl0Hash: string;
  snapshot: string;
  netlistHash: string;
  chipId: bigint;
  nState: bigint;
  gateCount: bigint;
  netlistLen: bigint;
  stepFloor: bigint;
  sealedFloor: bigint;
}

/** Kernel v2's globals (GlobalsV2). The fields both generations share have the same names and types. */
export interface GlobalsV2 {
  manager: string;
  v2Router: string;
  quote: string;
  factory: string;
  circuits: string;
  fab: string;
  sealedVM: string;
  beacon: string;
  impl0: string;
  impl0Hash: string;
  snapshot: string;
  netlistHash: string;
  chipId: bigint;
  nState: bigint;
  gateCount: bigint;
  netlistLen: bigint;
  stepFloor: bigint;
  sealedFloor: bigint;
  quoteShift: bigint;
}

/** The globals of either generation: what a check may read without knowing which one it has. */
export type AnyGlobals = Globals | GlobalsV2;
export const isGlobalsV2 = (g: AnyGlobals): g is GlobalsV2 => 'quoteShift' in g;

export interface KernelRecord {
  epoch: bigint;
  time: bigint;
  clampBits: bigint;
  flags: bigint;
  inputs: string;
  outputs: string;
  stateAfter: string;
  inflow: bigint;
  reserveBefore: bigint;
  allow: bigint;
  buyDecided: bigint;
  buyExecuted: bigint;
  tokensOut: bigint;
  nativeIn: bigint;
}

export class KernelAbiError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'KernelAbiError';
  }
}

/** A read-only call: where, what, and how to decode the answer (the shape used by packages/chain). */
export interface Call<T> {
  to: string;
  data: string;
  decode: (ret: string) => T;
  /** The Solidity signature with its return types, for error messages and for the drift test. */
  signature: string;
}

const utf8 = new TextEncoder();
export const selector = (signature: string): string => bytesToHex(keccak256(utf8.encode(signature)).slice(0, 4));

function words(ret: string, count: number, what: string): bigint[] {
  const h = strip0x(ret);
  if (h.length !== count * 64) {
    throw new KernelAbiError(
      `${what} returned ${h.length / 2} bytes; ${count * 32} expected` +
        (h.length === 0 ? ' (no contract at this address, or it has no such function)' : ' (the ABI differs from tools/launch-check/kernel-abi.ts)'),
    );
  }
  const out: bigint[] = [];
  for (let i = 0; i < count; i++) out.push(BigInt('0x' + h.slice(64 * i, 64 * i + 64)));
  return out;
}

function value(w: bigint, type: FieldType, what: string): string | bigint | boolean {
  const fits = (bits: number): bigint => {
    if (w >> BigInt(bits) !== 0n) throw new KernelAbiError(`${what} does not fit ${type} (the ABI differs from tools/launch-check/kernel-abi.ts)`);
    return w;
  };
  // bytesN is left-aligned: the low 256 - 8N bits must be zero
  const leftBytes = (n: number): string => {
    const low = 256 - 8 * n;
    if (w & ((1n << BigInt(low)) - 1n)) throw new KernelAbiError(`${what} does not fit ${type} (the ABI differs from tools/launch-check/kernel-abi.ts)`);
    return '0x' + w.toString(16).padStart(64, '0').slice(0, 2 * n);
  };
  switch (type) {
    case 'address':
      return '0x' + fits(160).toString(16).padStart(40, '0');
    case 'bool':
      return fits(1) === 1n;
    case 'bytes12':
      return leftBytes(12);
    case 'bytes14':
      return leftBytes(14);
    case 'bytes32':
      return '0x' + w.toString(16).padStart(64, '0');
    case 'uint8':
      return fits(8);
    case 'uint16':
      return fits(16);
    case 'uint32':
      return fits(32);
    case 'uint40':
      return fits(40);
    case 'uint128':
      return fits(128);
    case 'uint256':
      return w;
  }
}

export function decodeStruct<T>(fields: readonly Field[], ret: string, what: string): T {
  const ws = words(ret, fields.length, what);
  const out: Record<string, string | bigint | boolean> = {};
  fields.forEach(([name, type], i) => {
    out[name] = value(ws[i], type, `${what}.${name}`);
  });
  return out as T;
}

const one = <T>(type: FieldType, what: string) => (ret: string): T => value(words(ret, 1, what)[0], type, what) as T;

const mk = <T>(to: string, signature: string, args: string, decode: (ret: string) => T): Call<T> => ({
  to,
  data: selector(signature.replace(/ returns.*$/, '')) + args,
  decode,
  signature,
});

/** The reads of one kernel. Every signature here is checked against IKernelV1.sol / IKernelExt.sol by the tests. */
export const kernel = (at: string) => ({
  /** The bound token, or the zero address before `bind`. */
  token: (): Call<string> => mk(at, 'token() returns (address)', '', one<string>('address', 'kernel.token()')),
  /** The token's Directed vault, or the zero address before `bind`. */
  vault: (): Call<string> => mk(at, 'vault() returns (address)', '', one<string>('address', 'kernel.vault()')),
  /** Frozen forever (the KeeperTank calls it): the chip this kernel is bound to. */
  chipId: (): Call<bigint> => mk(at, 'chipId() returns (uint256)', '', one<bigint>('uint256', 'kernel.chipId()')),
  /** Number of settlement records (records are 1-indexed). */
  count: (): Call<bigint> => mk(at, 'count() returns (uint32)', '', one<bigint>('uint32', 'kernel.count()')),
  /** One record; all zero for n = 0 or n > count. */
  records: (n: number | bigint): Call<KernelRecord> => mk(at, 'records(uint32) returns (Record)', word(n), (ret) => decodeStruct<KernelRecord>(RECORD_FIELDS, ret, `kernel.records(${n})`)),
  /** The immutable envelope (INTERFACE.md section 7). */
  envelope: (): Call<Envelope> => mk(at, 'envelope() returns (Envelope)', '', (ret) => decodeStruct<Envelope>(ENVELOPE_FIELDS, ret, 'kernel.envelope()')),
  /** Not part of the frozen ABI (IKernelExt.sol). */
  globals: (): Call<Globals> => mk(at, 'globals() returns (Globals)', '', (ret) => decodeStruct<Globals>(GLOBALS_FIELDS, ret, 'kernel.globals()')),
  /** Kernel v2 only (IKernelV2.sol): same selector as globals(), a 19-word GlobalsV2. A v1 kernel answers 18 words, an error here. */
  globalsV2: (): Call<GlobalsV2> => mk(at, 'globals() returns (GlobalsV2)', '', (ret) => decodeStruct<GlobalsV2>(GLOBALS_V2_FIELDS, ret, 'kernel.globals() (v2)')),
  /** Kernel v2 only: the ERC-20 quote asset (USD₮0) the kernel routes on the curve. */
  quote: (): Call<string> => mk(at, 'quote() returns (address)', '', one<string>('address', 'kernel.quote()')),
  /** Kernel v2 only: the code shift in bits applied to quote amounts before the chip sees them. */
  quoteShift: (): Call<bigint> => mk(at, 'quoteShift() returns (uint256)', '', one<bigint>('uint256', 'kernel.quoteShift()')),
});

/** The reads of the KernelFactory (INTERFACE.md section 10, IKernelFactoryV1). */
export const kernelFactory = (at: string) => ({
  isKernel: (k: string): Call<boolean> => mk(at, 'isKernel(address) returns (bool)', addressWord(k), one<boolean>('bool', 'KernelFactory.isKernel()')),
  kernelOf: (token: string): Call<string> => mk(at, 'kernelOf(address) returns (address)', addressWord(token), one<string>('address', 'KernelFactory.kernelOf()')),
});

/** ABI encoding of a struct value, for tests: the inverse of `decodeStruct`. */
export function encodeStruct(fields: readonly Field[], v: Record<string, string | bigint | boolean>): string {
  let out = '0x';
  for (const [name, type] of fields) {
    const x = v[name];
    if (type === 'address') out += addressWord(x as string);
    else if (type === 'bool') out += word(x ? 1 : 0);
    else if (type === 'bytes32') out += strip0x(x as string).padStart(64, '0');
    else if (type === 'bytes12' || type === 'bytes14') out += strip0x(x as string).padEnd(64, '0');
    else out += word(x as bigint);
  }
  return out;
}
