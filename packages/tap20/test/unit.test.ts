// Unit tests beyond the published vectors: bit helpers, each well-formedness condition,
// REF closure loading and the evaluation bounds.

import { describe, expect, test } from 'vitest';
import {
  byteLength,
  bytesToHex,
  canonical,
  getBit,
  hexToBytes,
  listRefs,
  load,
  packBits,
  parse,
  setBit,
  step,
  stepBits,
  Tap20Error,
  unpackBits,
  type CircuitSource,
  type Tap20ErrorCode,
} from '../src/index.ts';

const u24 = (v: number): number[] => [(v >> 16) & 255, (v >> 8) & 255, v & 255];
const nand = (a: number, b: number): number[] => [0, ...u24(a), ...u24(b)];
const latch = (d: number): number[] => [1, ...u24(d)];
const ref = (cpu: number, id: number, nOuts: number, ins: number[]): number[] => [
  2,
  ...new Array<number>(19).fill(0),
  cpu,
  0, 0, 0, 0, 0, 0, 0, id,
  ins.length,
  nOuts,
  ...ins.flatMap(u24),
];
const bytes = (...records: number[][]): Uint8Array => Uint8Array.from(records.flat());

function codeOf(fn: () => unknown): Tap20ErrorCode | undefined {
  try {
    fn();
  } catch (e) {
    if (e instanceof Tap20Error) return e.code;
    throw e;
  }
  return undefined;
}

describe('bit packing', () => {
  test('LSB first: bit i is bit (i mod 8) of byte floor(i / 8)', () => {
    expect(Array.from(packBits([1, 0, 0, 0, 0, 0, 0, 0, 1]))).toEqual([0x01, 0x01]);
    expect(Array.from(packBits([0, 1, 1]))).toEqual([0x06]);
    expect(Array.from(unpackBits([0x06], 3))).toEqual([0, 1, 1]);
    expect(Array.from(unpackBits([0x80, 0x01], 9))).toEqual([0, 0, 0, 0, 0, 0, 0, 1, 1]);
  });

  test('unpack is lenient: missing bytes are 0, extra bytes and bits are ignored', () => {
    expect(Array.from(unpackBits([], 3))).toEqual([0, 0, 0]);
    expect(Array.from(unpackBits([0xff, 0xff, 0xff], 3))).toEqual([1, 1, 1]);
    expect(Array.from(unpackBits([0xff], 12))).toEqual([1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0]);
  });

  test('pack gives exactly ceil(n / 8) bytes and zero padding', () => {
    expect(packBits([]).length).toBe(0);
    expect(packBits(new Array(8).fill(1)).length).toBe(1);
    expect(packBits(new Array(9).fill(1)).length).toBe(2);
    expect(Array.from(packBits(new Array(9).fill(1)))).toEqual([0xff, 0x01]);
    expect(Array.from(packBits([1, 1, 1, 1], 2))).toEqual([0x03]);
    expect(byteLength(0)).toBe(0);
    expect(byteLength(243)).toBe(31);
    expect(byteLength(288)).toBe(36);
  });

  test('round trip for every length 0..40', () => {
    let seed = 12345;
    for (let n = 0; n <= 40; n++) {
      const bits = new Uint8Array(n);
      for (let i = 0; i < n; i++) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        bits[i] = (seed >> 16) & 1;
      }
      expect(Array.from(unpackBits(packBits(bits), n))).toEqual(Array.from(bits));
    }
  });

  test('canonical normalises what the contracts read leniently', () => {
    expect(bytesToHex(canonical(hexToBytes('ff'), 2))).toBe('0x03');
    expect(bytesToHex(canonical(hexToBytes('03aa'), 2))).toBe('0x03');
    expect(bytesToHex(canonical(hexToBytes(''), 2))).toBe('0x00');
    expect(bytesToHex(canonical(hexToBytes('ffff'), 16))).toBe('0xffff');
    expect(bytesToHex(canonical(hexToBytes('ff'), 0))).toBe('0x');
  });

  test('getBit and setBit', () => {
    const b = new Uint8Array(2);
    setBit(b, 0, 1);
    setBit(b, 9, true);
    expect(Array.from(b)).toEqual([1, 2]);
    expect(getBit(b, 0)).toBe(1);
    expect(getBit(b, 1)).toBe(0);
    expect(getBit(b, 9)).toBe(1);
    expect(getBit(b, 99)).toBe(0);
    setBit(b, 0, 0);
    expect(Array.from(b)).toEqual([0, 2]);
    expect(() => setBit(b, 16, 1)).toThrow(RangeError);
  });

  test('hex helpers', () => {
    expect(bytesToHex(hexToBytes('0x00ffA1'))).toBe('0x00ffa1');
    expect(bytesToHex(hexToBytes('00ffa1'), false)).toBe('00ffa1');
    expect(hexToBytes('0x').length).toBe(0);
    expect(() => hexToBytes('0x123')).toThrow(SyntaxError);
    expect(() => hexToBytes('zz')).toThrow(SyntaxError);
  });
});

describe('well-formedness, one condition at a time', () => {
  test('1: bad opcode and truncated records', () => {
    expect(codeOf(() => parse(Uint8Array.of(3), 2, 1))).toBe('bad-opcode');
    expect(codeOf(() => parse(Uint8Array.of(0xff, 0, 0, 2, 0, 0, 3), 2, 1))).toBe('bad-opcode');
    for (let cut = 1; cut < 7; cut++) expect(codeOf(() => parse(bytes(nand(2, 3)).subarray(0, cut), 2, 1))).toBe('truncated');
    for (let cut = 1; cut < 4; cut++) expect(codeOf(() => parse(bytes(latch(2)).subarray(0, cut), 1, 1))).toBe('truncated');
    const r = bytes(ref(0xaa, 1, 1, [2, 3]));
    for (let cut = 1; cut < r.length; cut++) expect(codeOf(() => parse(r.subarray(0, cut), 2, 1, () => undefined))).toBe('truncated');
  });

  test('2: pin counts', () => {
    const one = bytes(nand(0, 1));
    expect(codeOf(() => parse(one, 0, 0))).toBe('pins');
    expect(codeOf(() => parse(one, 65537, 1))).toBe('pins');
    expect(codeOf(() => parse(one, 0, 65537))).toBe('pins');
    expect(codeOf(() => parse(one, -1, 1))).toBe('pins');
    expect(codeOf(() => parse(one, 1.5, 1))).toBe('pins');
    expect(parse(one, 65536, 1).nSignals).toBe(2 + 65536 + 1);
    expect(parse(one, 0, 1).nIn).toBe(0);
  });

  test('3: outputs must be produced by elements', () => {
    expect(codeOf(() => parse(new Uint8Array(0), 4, 1))).toBe('too-few-signals');
    expect(codeOf(() => parse(bytes(nand(2, 3)), 2, 2))).toBe('too-few-signals');
    expect(parse(bytes(nand(2, 3), nand(2, 4)), 2, 2).nOut).toBe(2);
  });

  test('4: NAND and REF inputs refer backwards only', () => {
    // nIn = 2: the first NAND produces signal 4, so it may read 0..3 only.
    expect(parse(bytes(nand(3, 3)), 2, 1).n).toBe(1);
    expect(codeOf(() => parse(bytes(nand(4, 2)), 2, 1))).toBe('future-signal'); // its own output
    expect(codeOf(() => parse(bytes(nand(2, 5), nand(2, 3)), 2, 1))).toBe('future-signal');
    const inv = parse(bytes(nand(2, 2)), 1, 1);
    expect(codeOf(() => parse(bytes(ref(0xaa, 1, 1, [3])), 1, 1, () => inv))).toBe('future-signal');
  });

  test('5: a LATCH d may refer forward but must be below S', () => {
    // signals: 0, 1, in0 = 2, latch = 3, nand = 4; S = 5
    expect(parse(bytes(latch(4), nand(2, 3)), 1, 1).nState).toBe(1);
    expect(codeOf(() => parse(bytes(latch(5), nand(2, 3)), 1, 1))).toBe('latch-range');
    expect(parse(bytes(latch(3)), 1, 1).nState).toBe(1); // a latch fed by itself holds its value
  });

  test('6: REF needs a registered target with matching pins', () => {
    const inv = parse(bytes(nand(2, 2)), 1, 1);
    const top = bytes(ref(0xaa, 7, 1, [2]));
    expect(codeOf(() => parse(top, 1, 1))).toBe('ref-unresolved');
    expect(codeOf(() => parse(top, 1, 1, () => undefined))).toBe('ref-unresolved');
    expect(codeOf(() => parse(top, 1, 1, () => null))).toBe('ref-unresolved');
    expect(codeOf(() => parse(bytes(ref(0xaa, 7, 1, [2, 2])), 1, 1, () => inv))).toBe('ref-arity');
    expect(codeOf(() => parse(bytes(ref(0xaa, 7, 2, [2])), 1, 2, () => inv))).toBe('ref-arity');
    const ok = parse(top, 1, 1, (cpu, id) => {
      expect(cpu).toBe('0x00000000000000000000000000000000000000aa');
      expect(id).toBe(7n);
      return inv;
    });
    expect(ok.gateCount).toBe(1);
    expect(ok.depth).toBe(1);
  });

  test('6 and 7: state and gate totals', () => {
    const inv = parse(bytes(nand(2, 2)), 1, 1);
    const big = { ...inv, nState: (1 << 24) + 1 };
    expect(codeOf(() => parse(bytes(ref(0xaa, 1, 1, [2])), 1, 1, () => big))).toBe('ref-size');
    const heavy = { ...inv, gateCount: 2 ** 31 };
    const two = bytes(ref(0xaa, 1, 1, [2]), ref(0xaa, 1, 1, [2]));
    expect(codeOf(() => parse(two, 1, 1, () => heavy))).toBe('size-overflow');
    const stateful = { ...inv, nState: 1 << 23 };
    const three = bytes(ref(0xaa, 1, 1, [2]), ref(0xaa, 1, 1, [2]), ref(0xaa, 1, 1, [2]));
    expect(codeOf(() => parse(three, 1, 1, () => stateful))).toBe('size-overflow');
  });

  test('a REF id uses all 64 bits', () => {
    const rec = ref(0xaa, 0, 1, [2]);
    for (let i = 21; i < 29; i++) rec[i] = 0xff;
    const [h] = listRefs(Uint8Array.from(rec));
    expect(h.id).toBe(2n ** 64n - 1n);
    expect(h.nIns).toBe(1);
    expect(h.nOuts).toBe(1);
  });
});

describe('evaluation', () => {
  test('every signal value is reported, indexed by signal number', () => {
    // in0 = 2, in1 = 3, g4 = NAND(2, 3), g5 = NAND(4, 4) = AND
    const nl = parse(bytes(nand(2, 3), nand(4, 4)), 2, 1);
    const r = stepBits(nl, [], [1, 1]);
    expect(Array.from(r.signals)).toEqual([0, 1, 1, 1, 0, 1]);
    expect(Array.from(r.outputs)).toEqual([1]);
    expect(Array.from(stepBits(nl, [], [1, 0]).signals)).toEqual([0, 1, 1, 0, 1, 0]);
  });

  test('a LATCH outputs the stored bit and stores s[d] of this beat', () => {
    // signals: in0 = 2, q = 3 (LATCH d = 2): a one-beat delay of the input
    const nl = parse(bytes(latch(2)), 1, 1);
    let state: Uint8Array = new Uint8Array(1);
    const seen: number[] = [];
    for (const x of [1, 0, 1, 1, 0]) {
      const r = step(nl, state, [x]);
      seen.push(r.outputs[0]);
      state = r.newState;
    }
    expect(seen).toEqual([0, 1, 0, 1, 1]);
  });

  test('outputs never depend on the inputs of the same beat when they are LATCH outputs', () => {
    const nl = parse(bytes(latch(2)), 1, 1);
    expect(step(nl, [1], [0]).outputs[0]).toBe(1);
    expect(step(nl, [1], [1]).outputs[0]).toBe(1);
    expect(step(nl, [0], [1]).outputs[0]).toBe(0);
  });

  test('a 4-bit counter built from latches counts', () => {
    // latches q0..q3 = signals 2..5 (nIn = 0). XOR via 4 NANDs, AND via 2.
    // d0 = NOT q0; d1 = q1 XOR q0; d2 = q2 XOR (q0 AND q1); d3 = q3 XOR (q0 AND q1 AND q2)
    const recs: number[][] = [];
    let next = 2;
    const emit = (r: number[]): number => {
      recs.push(r);
      return next++;
    };
    const lat = [0, 0, 0, 0].map(() => emit(latch(0)));
    const xor = (a: number, b: number): number => {
      const t = emit(nand(a, b));
      return emit(nand(emit(nand(a, t)), emit(nand(b, t))));
    };
    const and = (a: number, b: number): number => {
      const t = emit(nand(a, b));
      return emit(nand(t, t));
    };
    const d0 = emit(nand(lat[0], lat[0]));
    const d1 = xor(lat[1], lat[0]);
    const c1 = and(lat[0], lat[1]);
    const d2 = xor(lat[2], c1);
    const c2 = and(c1, lat[2]);
    const d3 = xor(lat[3], c2);
    [d0, d1, d2, d3].forEach((d, i) => {
      recs[i] = latch(d);
    });
    const nl = parse(bytes(...recs), 0, 1);
    expect(nl.nState).toBe(4);
    let state: Uint8Array = new Uint8Array(1);
    for (let i = 0; i < 40; i++) {
      expect(state[0]).toBe(i % 16);
      state = step(nl, state, []).newState;
    }
  });

  test('bounds on gates and REF depth are enforced before evaluating', () => {
    const inv = parse(bytes(nand(2, 2)), 1, 1);
    const l1 = parse(bytes(ref(0xaa, 1, 1, [2])), 1, 1, () => inv);
    const l2 = parse(bytes(ref(0xaa, 2, 1, [2])), 1, 1, () => l1);
    expect(l2.depth).toBe(2);
    expect(step(l2, [], [1]).outputs[0]).toBe(0);
    expect(codeOf(() => step(l2, [], [1], { maxDepth: 1 }))).toBe('limit');
    expect(codeOf(() => step(l2, [], [1], { maxGates: 0 }))).toBe('limit');
  });
});

describe('load: fetching the REF closure', () => {
  const sources = new Map<string, CircuitSource>([
    ['0x00000000000000000000000000000000000000aa:1', { netlist: bytes(nand(2, 2)), nIn: 1, nOut: 1 }],
    ['0x00000000000000000000000000000000000000aa:2', { netlist: bytes(ref(0xaa, 1, 1, [2]), ref(0xaa, 1, 1, [3])), nIn: 1, nOut: 1 }],
  ]);
  const fetcher = (log: string[]) => async (cpu: string, id: bigint) => {
    log.push(`${cpu}:${id}`);
    return sources.get(`${cpu}:${id}`);
  };

  test('a flat netlist needs no fetcher', async () => {
    const nl = await load(bytes(nand(2, 3)), 2, 1);
    expect(nl.nNand).toBe(1);
  });

  test('nested targets are fetched once each and evaluated by recursion', async () => {
    const log: string[] = [];
    // top = double inverter (circuit 2) applied twice more through circuit 1: NOT(NOT(NOT(x)))
    const top = bytes(ref(0xaa, 2, 1, [2]), ref(0xaa, 1, 1, [3]));
    const nl = await load(top, 1, 1, fetcher(log));
    expect(log.sort()).toEqual(['0x00000000000000000000000000000000000000aa:1', '0x00000000000000000000000000000000000000aa:2']);
    expect(nl.depth).toBe(2);
    expect(nl.gateCount).toBe(3);
    expect(step(nl, [], [0]).outputs[0]).toBe(1);
    expect(step(nl, [], [1]).outputs[0]).toBe(0);
  });

  test('a missing target is ill-formed, and limits are enforced', async () => {
    const missing = bytes(ref(0xaa, 9, 1, [2]));
    await expect(load(missing, 1, 1, fetcher([]))).rejects.toMatchObject({ code: 'ref-unresolved' });
    await expect(load(missing, 1, 1)).rejects.toMatchObject({ code: 'ref-unresolved' });
    const top = bytes(ref(0xaa, 2, 1, [2]));
    await expect(load(top, 1, 1, fetcher([]), { maxDepth: 1 })).rejects.toMatchObject({ code: 'limit' });
    await expect(load(top, 1, 1, fetcher([]), { maxCircuits: 1 })).rejects.toMatchObject({ code: 'limit' });
    await expect(load(top, 1, 1, fetcher([]), { maxGates: 1 })).rejects.toMatchObject({ code: 'limit' });
  });

  test('a source that refers to itself cannot recurse forever', async () => {
    const self = bytes(ref(0xaa, 5, 1, [2]));
    const loop = async () => ({ netlist: self, nIn: 1, nOut: 1 });
    await expect(load(self, 1, 1, loop)).rejects.toMatchObject({ code: 'ref-unresolved' });
  });
});
