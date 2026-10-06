// The TypeScript port of the kernel's arithmetic against chips/golden/vectors.json, the vectors the Solidity
// kernel and the Python reference model also pass. No network.

import { readFileSync } from 'node:fs';
import { describe, expect, test } from 'vitest';
import {
  bytesOf,
  exp8,
  fallbackWord,
  INPUT_FIELDS,
  lg8,
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
