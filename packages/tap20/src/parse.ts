// TAP-20 decoder and well-formedness check (TAP-20 sections 2 and 3).
//
// A netlist is a headerless concatenation of big-endian records:
//   0x00 NAND   a:u24 b:u24                                       7 bytes, 1 signal
//   0x01 LATCH  d:u24                                             4 bytes, 1 signal
//   0x02 REF    cpu:20 id:u64 nIns:u8 nOuts:u8 ins:u24 x nIns     31 + 3 nIns bytes, nOuts signals
// Signals: 0 = constant 0, 1 = constant 1, 2 .. 2 + nIn - 1 = inputs, then the signals each
// record produces, in record order. Outputs are the last nOut signals.

export const NAND = 0;
export const LATCH = 1;
export const REF = 2;

/** TAP-20 section 3, conditions 2, 6, 7 and 8. */
export const MAX_PINS = 1 << 16;
export const MAX_SIGNALS = 1 << 24;
export const MAX_STATE = 1 << 24;
export const MAX_GATES = 2 ** 32 - 1;

export type Tap20ErrorCode =
  | 'bad-opcode' // condition 1: an opcode other than 0x00, 0x01, 0x02
  | 'truncated' // condition 1: the last record is incomplete
  | 'pins' // condition 2: nIn or nOut out of range (includes nOut = 0)
  | 'too-few-signals' // condition 3: the elements produce fewer than nOut signals
  | 'future-signal' // condition 4: a NAND or REF input does not refer backwards
  | 'latch-range' // condition 5: a LATCH d is not a signal of this circuit
  | 'ref-unresolved' // condition 6: the REF target is not a circuit of a registered processor
  | 'ref-arity' // condition 6: the target's nIn / nOut differ from nIns / nOuts
  | 'ref-size' // condition 6: the target's state is larger than 2^24 bits
  | 'size-overflow' // condition 7: total state above 2^24 bits or total gates above 2^32 - 1
  | 'too-many-signals' // condition 8: more than 2^24 signals
  | 'limit'; // a caller-supplied bound on gates, REF depth or circuits fetched was exceeded

export class Tap20Error extends Error {
  readonly code: Tap20ErrorCode;
  /** Byte offset of the offending record, or -1 when the error is not tied to one. */
  readonly offset: number;

  constructor(code: Tap20ErrorCode, message: string, offset: number = -1) {
    super(message);
    this.name = 'Tap20Error';
    this.code = code;
    this.offset = offset;
  }
}

export interface RefRecord {
  /** Processor contract, lower-case hex with 0x. */
  cpu: string;
  /** Circuit id on that processor (u64). */
  id: bigint;
  nIns: number;
  nOuts: number;
  /** Signal indices fed to the sub-circuit's inputs. */
  ins: Uint32Array;
  /** Index of this REF's record in the parent netlist. */
  element: number;
  /** The referenced circuit, already parsed and checked. */
  sub: Netlist;
}

export interface Netlist {
  nIn: number;
  nOut: number;
  /** Number of records (elements). */
  n: number;
  /** Total number of signals S = 2 + nIn + signals produced by the elements. */
  nSignals: number;
  /** Total state bits, REF sub-circuits included. */
  nState: number;
  /** NAND + LATCH count, REF sub-circuits included (what `circuitInfo` reports). */
  gateCount: number;
  nNand: number;
  nLatch: number;
  nRef: number;
  /** REF nesting depth: 0 for a flat netlist. */
  depth: number;
  /** Length of the netlist in bytes. */
  byteLength: number;
  /** Opcode per element. */
  op: Uint8Array;
  /** NAND: input a. LATCH: d. REF: unused (0). */
  a: Uint32Array;
  /** NAND: input b. LATCH: unused (0). REF: index into `refs`. */
  b: Uint32Array;
  /** Index of the first signal each element produces. */
  out: Uint32Array;
  /** LATCH: its state bit. REF: first bit of its state block. NAND: unused. */
  stateBase: Uint32Array;
  /** Element indices of the LATCH records, in record order. */
  latches: Uint32Array;
  refs: RefRecord[];
}

/** Returns the referenced circuit, or nothing if (cpu, id) is not a circuit of a registered processor. */
export type Resolver = (cpu: string, id: bigint) => Netlist | null | undefined;

export interface RefHeader {
  cpu: string;
  id: bigint;
  nIns: number;
  nOuts: number;
}

/** Cache key for a circuit. */
export function refKey(cpu: string, id: bigint | number | string): string {
  return `${cpu.toLowerCase()}:${BigInt(id).toString()}`;
}

interface Scan {
  elements: number;
  produced: number;
  nand: number;
  latch: number;
  ref: number;
  refIns: number;
}

// Pass 1: check opcodes and record lengths before anything is allocated (TAP-20 section 7.2).
function scan(bytes: Uint8Array): Scan {
  const len = bytes.length;
  let p = 0;
  let nand = 0;
  let latch = 0;
  let ref = 0;
  let refIns = 0;
  let produced = 0;
  while (p < len) {
    const op = bytes[p];
    if (op === NAND) {
      if (p + 7 > len) throw truncated(p);
      p += 7;
      nand++;
      produced++;
    } else if (op === LATCH) {
      if (p + 4 > len) throw truncated(p);
      p += 4;
      latch++;
      produced++;
    } else if (op === REF) {
      if (p + 31 > len) throw truncated(p);
      const nIns = bytes[p + 29];
      if (p + 31 + 3 * nIns > len) throw truncated(p);
      produced += bytes[p + 30];
      p += 31 + 3 * nIns;
      ref++;
      refIns += nIns;
    } else {
      throw new Tap20Error('bad-opcode', `unknown opcode 0x${op.toString(16).padStart(2, '0')} at byte ${p}`, p);
    }
  }
  return { elements: nand + latch + ref, produced, nand, latch, ref, refIns };
}

function truncated(p: number): Tap20Error {
  return new Tap20Error('truncated', `truncated record at byte ${p}`, p);
}

function u24(bytes: Uint8Array, p: number): number {
  return (bytes[p] << 16) | (bytes[p + 1] << 8) | bytes[p + 2];
}

function readRefHeader(bytes: Uint8Array, p: number): RefHeader {
  let cpu = '0x';
  for (let i = 1; i <= 20; i++) cpu += bytes[p + i].toString(16).padStart(2, '0');
  let id = 0n;
  for (let i = 21; i < 29; i++) id = (id << 8n) | BigInt(bytes[p + i]);
  return { cpu, id, nIns: bytes[p + 29], nOuts: bytes[p + 30] };
}

/**
 * The REF records of a netlist, in record order, without resolving them. Only opcodes and
 * record lengths are checked. Used to fetch the REF closure before `parse`.
 */
export function listRefs(bytes: Uint8Array): RefHeader[] {
  if (scan(bytes).ref === 0) return [];
  const out: RefHeader[] = [];
  let p = 0;
  while (p < bytes.length) {
    const op = bytes[p];
    if (op === NAND) p += 7;
    else if (op === LATCH) p += 4;
    else {
      const h = readRefHeader(bytes, p);
      out.push(h);
      p += 31 + 3 * h.nIns;
    }
  }
  return out;
}

/**
 * Decode a netlist and check that it is well-formed (TAP-20 section 3). Throws `Tap20Error`
 * otherwise. `resolve` supplies REF targets; a netlist with a REF and no resolver is rejected.
 */
export function parse(bytes: Uint8Array, nIn: number, nOut: number, resolve?: Resolver): Netlist {
  // Condition 2.
  if (!Number.isInteger(nIn) || !Number.isInteger(nOut) || nIn < 0 || nOut < 0) {
    throw new Tap20Error('pins', 'nIn and nOut must be non-negative integers');
  }
  if (nOut === 0) throw new Tap20Error('pins', 'no outputs (nOut = 0)');
  if (nIn > MAX_PINS || nOut > MAX_PINS) throw new Tap20Error('pins', 'too many pins (nIn or nOut above 65,536)');

  // Condition 1.
  const sc = scan(bytes);

  // Conditions 8 and 3.
  const nSignals = 2 + nIn + sc.produced;
  if (nSignals > MAX_SIGNALS) throw new Tap20Error('too-many-signals', 'more than 2^24 signals');
  if (sc.produced < nOut) {
    throw new Tap20Error('too-few-signals', `too few signals for outputs: ${sc.produced} produced, nOut = ${nOut}`);
  }

  const n = sc.elements;
  const op = new Uint8Array(n);
  const a = new Uint32Array(n);
  const b = new Uint32Array(n);
  const out = new Uint32Array(n);
  const stateBase = new Uint32Array(n);
  const latches = new Uint32Array(sc.latch);
  const refIns = new Uint32Array(sc.refIns);
  const refs: RefRecord[] = [];

  let p = 0;
  let next = 2 + nIn; // index of the first signal the current element produces
  let nState = 0;
  let gateCount = sc.nand + sc.latch;
  let depth = 0;
  let li = 0;
  let ri = 0;

  for (let e = 0; e < n; e++) {
    const o = bytes[p];
    op[e] = o;
    out[e] = next;
    if (o === NAND) {
      const x = u24(bytes, p + 1);
      const y = u24(bytes, p + 4);
      // Condition 4: references go backwards only.
      if (x >= next || y >= next) {
        throw new Tap20Error('future-signal', `NAND at byte ${p} produces signal ${next} but reads signal ${x >= next ? x : y}`, p);
      }
      a[e] = x;
      b[e] = y;
      p += 7;
      next += 1;
    } else if (o === LATCH) {
      const d = u24(bytes, p + 1);
      // Condition 5: d may refer forward, but must be a signal of this circuit.
      if (d >= nSignals) {
        throw new Tap20Error('latch-range', `LATCH at byte ${p}: d = ${d} is out of range (S = ${nSignals})`, p);
      }
      a[e] = d;
      stateBase[e] = nState;
      latches[li++] = e;
      nState += 1;
      p += 4;
      next += 1;
    } else {
      const h = readRefHeader(bytes, p);
      const ins = refIns.subarray(ri, ri + h.nIns);
      for (let i = 0; i < h.nIns; i++) {
        const s = u24(bytes, p + 31 + 3 * i);
        if (s >= next) {
          throw new Tap20Error('future-signal', `REF at byte ${p} produces signal ${next} but reads signal ${s}`, p);
        }
        ins[i] = s;
      }
      ri += h.nIns;
      // Condition 6.
      const sub = resolve ? resolve(h.cpu, h.id) : undefined;
      if (!sub) {
        throw new Tap20Error(
          'ref-unresolved',
          `REF at byte ${p}: ${h.cpu} #${h.id} is not a circuit of a registered processor${resolve ? '' : ' (no resolver given)'}`,
          p,
        );
      }
      if (sub.nIn !== h.nIns || sub.nOut !== h.nOuts) {
        throw new Tap20Error(
          'ref-arity',
          `REF at byte ${p}: pin mismatch, record says ${h.nIns} in / ${h.nOuts} out, target has ${sub.nIn} in / ${sub.nOut} out`,
          p,
        );
      }
      if (sub.nState > MAX_STATE) throw new Tap20Error('ref-size', `REF at byte ${p}: target state above 2^24 bits`, p);
      b[e] = refs.length;
      stateBase[e] = nState;
      refs.push({ cpu: h.cpu, id: h.id, nIns: h.nIns, nOuts: h.nOuts, ins, element: e, sub });
      nState += sub.nState;
      gateCount += sub.gateCount;
      if (sub.depth + 1 > depth) depth = sub.depth + 1;
      p += 31 + 3 * h.nIns;
      next += h.nOuts;
    }
    // Condition 7, checked as the totals grow so they stay exact.
    if (nState > MAX_STATE || gateCount > MAX_GATES) throw new Tap20Error('size-overflow', 'size overflow', p);
  }

  return {
    nIn,
    nOut,
    n,
    nSignals,
    nState,
    gateCount,
    nNand: sc.nand,
    nLatch: sc.latch,
    nRef: sc.ref,
    depth,
    byteLength: bytes.length,
    op,
    a,
    b,
    out,
    stateBase,
    latches,
    refs,
  };
}

/** Re-encode a parsed netlist. `encode(parse(bytes, ...))` returns the same bytes. */
export function encode(nl: Netlist): Uint8Array {
  const bytes = new Uint8Array(nl.byteLength);
  let p = 0;
  const put24 = (v: number): void => {
    bytes[p++] = (v >>> 16) & 255;
    bytes[p++] = (v >>> 8) & 255;
    bytes[p++] = v & 255;
  };
  for (let e = 0; e < nl.n; e++) {
    const o = nl.op[e];
    bytes[p++] = o;
    if (o === NAND) {
      put24(nl.a[e]);
      put24(nl.b[e]);
    } else if (o === LATCH) {
      put24(nl.a[e]);
    } else {
      const r = nl.refs[nl.b[e]];
      for (let i = 0; i < 20; i++) bytes[p++] = parseInt(r.cpu.substr(2 + 2 * i, 2), 16);
      for (let i = 7; i >= 0; i--) bytes[p++] = Number((r.id >> BigInt(8 * i)) & 255n);
      bytes[p++] = r.nIns;
      bytes[p++] = r.nOuts;
      for (let i = 0; i < r.nIns; i++) put24(r.ins[i]);
    }
  }
  return bytes;
}
