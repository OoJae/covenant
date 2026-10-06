// The TypeScript port of the kernel's arithmetic against chips/golden/vectors.json, the vectors the Solidity
// kernel and the Python reference model also pass. No network.

import { readFileSync } from 'node:fs';
import { describe, expect, test } from 'vitest';
import {
  bytesOf,
  exp8,
  exp8s,
  fallbackWord,
  INPUT_FIELDS,
  lg8,
  lg8s,
  minAmountForCode,
  OUTPUT_FIELDS,
  pack,
  route,
  stateBytes,
  stateWord32,
  unpack,
  wordOf,
  type RouteEnv,
} from '../src/kernel/model.ts';

const V = JSON.parse(readFileSync(new URL('../../chips/golden/vectors.json', import.meta.url), 'utf8'));

interface RoutingVector {
  envelope: RouteEnv;
  word: string;
  bytes: string;
  inflow: string;
  reserve0: string;
  cumInflow: string;
  allowPaidCum: string;
  graduated?: boolean;
  expect: { allow: string; buyDecided: string; buyShare: string; clamp: number; rel: number; release: string; reserveAfter: string; shares: number[]; toReserve: string };
}

function check(v: RoutingVector): void {
  expect(bytesOf(BigInt(v.word), 14)).toBe(v.bytes);
  expect(wordOf(v.bytes)).toBe(BigInt(v.word));
  const r = route(v.envelope, BigInt(v.word), BigInt(v.inflow), BigInt(v.reserve0), BigInt(v.cumInflow), BigInt(v.allowPaidCum), v.graduated ?? false);
  expect({
    allow: r.allow.toString(),
    buyDecided: r.buyDecided.toString(),
    buyShare: r.buyShare.toString(),
    clamp: r.clamp,
    rel: r.rel,
    release: r.release.toString(),
    reserveAfter: r.reserveAfter.toString(),
    shares: r.shares,
    toReserve: r.toReserve.toString(),
  }).toEqual(v.expect);
}

describe('golden vectors (chips/golden/vectors.json)', () => {
  test('format', () => {
    expect(V.format).toBe('covenant-golden/2');
  });

  test(`lg8: ${V.lg8.length} + ${V.revision2.edges.lg8.length} vectors`, () => {
    for (const v of [...V.lg8, ...V.revision2.edges.lg8]) expect(lg8(BigInt(v.x)), v.x).toBe(v.code);
  });

  test(`exp8: ${V.exp8.length} vectors, and exp8(lg8(x)) <= x`, () => {
    for (const v of V.exp8) expect(exp8(v.code).toString(), String(v.code)).toBe(v.x);
    for (let x = 1n; x < 5000n; x++) expect(exp8(lg8(x)) <= x).toBe(true);
    expect([lg8(1n), lg8(10n ** 6n), lg8(10n ** 15n), lg8(10n ** 16n), lg8(10n ** 18n), lg8(10n ** 27n)]).toEqual([1, 160, 399, 425, 478, 717]);
  });

  test('word layouts are the ones the vectors were made with', () => {
    expect(V.layout.input.map((f: { name: string; offset: number; width: number }) => [f.name, f.offset, f.width])).toEqual(INPUT_FIELDS);
    expect(V.layout.output.map((f: { name: string; offset: number; width: number }) => [f.name, f.offset, f.width])).toEqual(OUTPUT_FIELDS);
    expect(V.layout.inBits).toBe(96);
  });

  test(`input words: ${V.inputs.length} vectors`, () => {
    for (const v of V.inputs) {
      expect(bytesOf(BigInt(v.word), 12)).toBe(v.bytes);
      expect(unpack(INPUT_FIELDS, wordOf(v.bytes))).toEqual(v.fields);
      expect(pack(INPUT_FIELDS, v.fields)).toBe(BigInt(v.word));
    }
  });

  test(`output words: ${V.outputs.length} vectors`, () => {
    for (const v of V.outputs) {
      expect(bytesOf(BigInt(v.word), 14)).toBe(v.bytes);
      expect(unpack(OUTPUT_FIELDS, wordOf(v.bytes))).toEqual(v.fields);
      expect(pack(OUTPUT_FIELDS, v.fields)).toBe(BigInt(v.word));
    }
  });

  test(`routing (clamps K1T..K5): ${V.routing.length} vectors`, () => {
    for (const v of V.routing) check(v);
  });

  test(`routing at the boundaries: ${V.revision2.routingBoundary.length} vectors`, () => {
    for (const v of V.revision2.routingBoundary) check(v);
  });

  test(`routing after graduation: ${V.revision2.routingGraduated.length} vectors`, () => {
    for (const v of V.revision2.routingGraduated) check(v);
  });

  test('fallback words, and the fallback word routed after graduation', () => {
    for (const v of V.fallback) {
      const w = fallbackWord(v.fbAllow, v.envelope.relMax);
      expect(w.toString()).toBe(v.word);
      expect(bytesOf(w, 14)).toBe(v.bytes);
    }
    for (const v of V.revision2.edges.fallbackGraduated) {
      expect(fallbackWord(v.fbAllow, v.envelope.relMax).toString()).toBe(v.word);
      // gen_vectors.py routes it with inflow 1e24, reserve 1e23, cumulative inflow 1e25, nothing paid, graduated
      const r = route(v.envelope, BigInt(v.word), 10n ** 24n, 10n ** 23n, 10n ** 25n, 0n, true);
      expect(r.buyDecided.toString()).toBe(v.expect.buyDecided);
      expect(r.reserveAfter.toString()).toBe(v.expect.reserveAfter);
      expect(r.shares).toEqual(v.expect.shares);
      expect(r.clamp).toBe(v.expect.clamp);
    }
  });

  test('state: the kernel stores the TAP-20 byte string first in a bytes32', () => {
    for (const v of V.state) {
      const n = Math.ceil(v.nState / 8);
      const s = stateBytes(v.bytes32, v.nState);
      expect(s.length).toBe(2 + 2 * n);
      expect(wordOf(s)).toBe(BigInt(v.bits));
      expect(stateWord32(s)).toBe(v.bytes32);
    }
  });
});

// Kernel v2 (USD₮0 quote): chips/golden/vectors_v2.json and its companion vectors_v2_settles.jsonl, written by
// gen_vectors_v2.py from kernel_model_v2.py. The Solidity KernelV2 passes the same files (GoldenV2.t.sol,
// DiffSettlesV2.t.sol).
const V2 = JSON.parse(readFileSync(new URL('../../chips/golden/vectors_v2.json', import.meta.url), 'utf8'));

interface RoutingVectorV2 extends Omit<RoutingVector, 'bytes'> {
  shift: number;
}

function checkV2(v: RoutingVectorV2): void {
  const r = route(v.envelope, BigInt(v.word), BigInt(v.inflow), BigInt(v.reserve0), BigInt(v.cumInflow), BigInt(v.allowPaidCum), v.graduated ?? false, v.shift);
  expect({
    allow: r.allow.toString(),
    buyDecided: r.buyDecided.toString(),
    buyShare: r.buyShare.toString(),
    clamp: r.clamp,
    rel: r.rel,
    release: r.release.toString(),
    reserveAfter: r.reserveAfter.toString(),
    shares: r.shares,
    toReserve: r.toReserve.toString(),
  }).toEqual(v.expect);
}

describe('kernel v2 golden vectors (chips/golden/vectors_v2.json)', () => {
  test('format and the shift: 33 bits, 264 codes, from 135.895901 USD₮0 per OKB', () => {
    expect(V2.format).toBe('covenant-golden-v2/1');
    expect(V2.shift).toEqual({ codeShift: 264, maxShift: 40, quoteDecimals: 6, quoteShift: 33, referenceRateMicro: '135895901' });
    // kernel_model_v2._check_reference_points
    expect([lg8s(10n ** 6n, 33), lg8s(500_000n, 33), lg8s(8_000n * 10n ** 6n, 33)]).toEqual([424, 416, 527]);
    expect([exp8s(425, 33), exp8s(440, 33), exp8s(452, 33), exp8s(479, 33)]).toEqual([1n << 20n, 15n << 18n, 11n << 20n, 14n << 23n]);
    expect((10n ** 18n) >> 33n).toBe(116_415_321n); // 1 OKB of the chip's calibration, in USD₮0 base units
  });

  test(`lg8s: ${V2.lg8s.length} vectors, and lg8s(x, s) = min(1023, lg8(x) + 8s)`, () => {
    for (const v of V2.lg8s) expect(lg8s(BigInt(v.x), v.s), `${v.x} << ${v.s}`).toBe(v.code);
    for (let s = 0; s <= 40; s++) {
      expect(lg8s(0n, s)).toBe(0);
      for (const x of [1n, 2n, 7n, 8n, 9n, 1000n, 500_000n, 10n ** 6n, 2n ** 100n]) expect(lg8s(x, s)).toBe(Math.min(1023, lg8(x) + 8 * s));
    }
  });

  test(`exp8s: ${V2.exp8s.length} vectors, and exp8(c + 8s) >> s = exp8(c)`, () => {
    for (const v of V2.exp8s) expect(exp8s(v.code, v.s).toString(), `${v.code} >> ${v.s}`).toBe(v.x);
    for (const s of [1, 20, 33, 40]) for (let c = 1; c + 8 * s <= 1023; c++) expect(exp8s(c + 8 * s, s)).toBe(exp8(c));
  });

  test(`routing with the shift: ${V2.routing.length} vectors`, () => {
    for (const v of V2.routing) checkV2(v);
  });

  test(`routing at the boundaries: ${V2.routingBoundary.length} vectors`, () => {
    for (const v of V2.routingBoundary) checkV2(v);
  });

  test('the floor threshold: the smallest reserve whose shifted code reaches floorMin', () => {
    for (const s of [0, 33]) {
      for (const code of [1, 2, 9, 100, 264, 265, 266, 300, 400, 425, 440, 600, 1023]) {
        const m = minAmountForCode(code, s);
        if (m > 0n && m <= (1n << 128n) - 1n) {
          expect(lg8s(m, s) >= code, `${code} ${s}`).toBe(true);
          expect(lg8s(m - 1n, s) < code, `${code} ${s}`).toBe(true);
        }
      }
    }
    expect(minAmountForCode(1, 33)).toBe(1n); // the reference envelope's floorMin: any non-zero reserve
    expect(minAmountForCode(425, 33)).toBe(1n << 20n); // 1.048576 USD₮0, the factory's floorMin bound
    expect(minAmountForCode(425, 0)).toBe(exp8(425));
  });
});

// One settle's expectation in vectors_v2_settles.jsonl (gen_vectors_v2.py EXPECT_WIDTH = 29): n, epoch, time,
// clampBits, flags, inputs, outputs, stateAfter (big-endian integers of the bytes), inflow, reserveBefore, allow,
// buyDecided, buyExecuted, tokensOut, quoteIn, cumInflow, allowPaidCum, then books and balances.
describe('kernel v2: every settle of vectors_v2_settles.jsonl through the clip port', () => {
  test('stored input codes are the shifted codes; stored amounts are the shifted routing of the stored outputs', () => {
    const lines = readFileSync(new URL('../../chips/golden/vectors_v2_settles.jsonl', import.meta.url), 'utf8').split('\n').filter(Boolean);
    expect(lines.length).toBe(V2.settleSequences);
    const W = V2.expectWidth;
    expect(W).toBe(29);
    const be = (x: string, n: number): string => '0x' + BigInt(x).toString(16).padStart(2 * n, '0');
    let settles = 0;
    let graduated = 0;
    let fallbacks = 0;
    for (const line of lines) {
      const q = JSON.parse(line) as { head: string[]; settled: number; expects: string[] };
      const shift = Number(q.head[1]);
      const env = V2.envPresets[Number(q.head[4])] as RouteEnv & { fbAllow: number };
      expect(q.expects.length).toBe(q.settled * W);
      for (let j = 0; j < q.settled; j++) {
        const e = q.expects.slice(j * W, (j + 1) * W);
        const [clampBits, flags] = [Number(e[3]), Number(e[4])];
        const [inflow, reserveBefore, allow, buyDecided, buyExecuted] = [8, 9, 10, 11, 12].map((i) => BigInt(e[i]));
        const [cumInflow, allowPaidCum] = [BigInt(e[15]), BigInt(e[16])];
        const grad = (flags & 64) !== 0;
        const s = grad ? 0 : shift;
        const inputs = be(e[5], 12);
        const outputs = be(e[6], 14);
        const x = unpack(INPUT_FIELDS, wordOf(inputs));
        const at = `sequence head ${q.head.slice(0, 5).join(',')}, settle ${e[0]}`;
        expect([x.TAX, x.TAXCUM, x.RES, x.GRAD, x.REV, x.REVCUM, x.ESC, x.ZERO], at).toEqual([lg8s(inflow, s), lg8s(cumInflow, s), lg8s(reserveBefore, s), grad ? 1 : 0, 0, 0, 0, 0]);
        const r = route(env, wordOf(outputs), inflow, reserveBefore, cumInflow, allowPaidCum - allow, grad, s);
        expect([r.clamp, r.allow, r.buyDecided], at).toEqual([clampBits, allow, buyDecided]);
        expect(buyExecuted <= buyDecided, at).toBe(true);
        if (flags & 1) {
          fallbacks++;
          expect(outputs, at).toBe(bytesOf(fallbackWord(env.fbAllow, env.relMax), 14));
        }
        if (grad) graduated++;
        settles++;
      }
    }
    expect(settles).toBe(V2.settleCount);
    expect(graduated).toBeGreaterThan(0);
    expect(fallbacks).toBeGreaterThan(0);
  });
});
