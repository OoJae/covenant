// The nonce walk on synthetic histories: every nonce is located, several nonces in one block are handled,
// and an inconsistent node is reported instead of believed. Offline.

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { walkNonces, type CountProbe } from '../walk.ts';

/** A history: the blocks in which the address sent a transaction (a block may repeat). */
function history(blocks: readonly number[]): { probe: CountProbe; calls: number[][] } {
  const sorted = [...blocks].sort((a, b) => a - b);
  const calls: number[][] = [];
  const probe: CountProbe = async (asked) => {
    calls.push([...asked]);
    return asked.map((b) => sorted.filter((x) => x <= b).length);
  };
  return { probe, calls };
}

/** A small deterministic generator, so the "random" cases are the same on every run. */
function rng(seed: number): () => number {
  let s = seed >>> 0;
  return () => {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    return s / 2 ** 32;
  };
}

test('an address that never sent a transaction: two counts and nothing to find', async () => {
  const h = history([]);
  const w = await walkNonces(h.probe, 72_378_000);
  assert.deepEqual(w.blocks, []);
  assert.equal(w.total, 0);
  assert.equal(w.rounds, 1);
  assert.deepEqual(h.calls, [[0, 72_378_000]]);
});

test('one transaction is found in about eight rounds of ten probes, not twenty-seven', async () => {
  const h = history([71_350_520]);
  const w = await walkNonces(h.probe, 72_378_000);
  assert.deepEqual(w.blocks, [{ block: 71_350_520, firstNonce: 0, lastNonce: 0 }]);
  assert.ok(w.rounds <= 9, `${w.rounds} rounds`);
  for (const c of h.calls) assert.ok(c.length <= 10, 'never more than one batch per round while one range is open');
});

test('several nonces in one block are one entry covering all of them', async () => {
  const h = history([100, 500, 500, 500, 501, 9_000, 9_000]);
  const w = await walkNonces(h.probe, 10_000);
  assert.deepEqual(w.blocks, [
    { block: 100, firstNonce: 0, lastNonce: 0 },
    { block: 500, firstNonce: 1, lastNonce: 3 },
    { block: 501, firstNonce: 4, lastNonce: 4 },
    { block: 9_000, firstNonce: 5, lastNonce: 6 },
  ]);
  assert.equal(w.total, 7);
});

test('transactions in the first block, in the head block and in adjacent blocks', async () => {
  const h = history([1, 2, 3, 9_999, 10_000]);
  const w = await walkNonces(h.probe, 10_000);
  assert.deepEqual(w.blocks.map((b) => b.block), [1, 2, 3, 9_999, 10_000]);
  assert.deepEqual(w.blocks.map((b) => [b.firstNonce, b.lastNonce]), [[0, 0], [1, 1], [2, 2], [3, 3], [4, 4]]);
});

test('a head of one or two blocks', async () => {
  assert.deepEqual((await walkNonces(history([1]).probe, 1)).blocks, [{ block: 1, firstNonce: 0, lastNonce: 0 }]);
  assert.deepEqual((await walkNonces(history([1, 2]).probe, 2)).blocks.map((b) => b.block), [1, 2]);
  assert.deepEqual((await walkNonces(history([]).probe, 0)).blocks, []);
});

test('random histories: every nonce is located exactly, with any number of probes per round', async () => {
  const next = rng(20261004);
  for (let round = 0; round < 60; round++) {
    const head = 1 + Math.floor(next() * 5_000_000);
    const n = Math.floor(next() * 80);
    const blocks: number[] = [];
    for (let i = 0; i < n; i++) {
      // clustered and repeated blocks, like a wallet that acts in bursts
      const base = 1 + Math.floor(next() * head);
      const burst = 1 + Math.floor(next() * 3);
      for (let j = 0; j < burst && blocks.length < n; j++) blocks.push(Math.min(head, base + (next() < 0.5 ? 0 : j)));
    }
    const perRound = [1, 3, 10, 25][round % 4];
    const h = history(blocks);
    const w = await walkNonces(h.probe, head, { probesPerRound: perRound });
    const expected = new Map<number, number>();
    for (const b of blocks) expected.set(b, (expected.get(b) ?? 0) + 1);
    const want = [...expected.entries()].sort((a, b) => a[0] - b[0]);
    assert.deepEqual(w.blocks.map((b) => [b.block, b.lastNonce - b.firstNonce + 1]), want);
    assert.equal(w.total, blocks.length);
    // a bisection: never more than about log2(head) + 2 rounds
    assert.ok(w.rounds <= Math.ceil(Math.log2(head + 1)) + 3, `${w.rounds} rounds for head ${head}`);
  }
});

test('a floor: only the nonces used after it are located', async () => {
  const h = history([10, 20, 3_000, 4_000]);
  const w = await walkNonces(h.probe, 5_000, { floor: 1_000 });
  assert.equal(w.atFloor, 2);
  assert.equal(w.total, 4);
  assert.deepEqual(w.blocks, [
    { block: 3_000, firstNonce: 2, lastNonce: 2 },
    { block: 4_000, firstNonce: 3, lastNonce: 3 },
  ]);
  const same = await walkNonces(h.probe, 5_000, { floor: 5_000 });
  assert.deepEqual(same.blocks, []);
});

test('a cap on the counts locates only the first nonces', async () => {
  const h = history([10, 20, 30, 40, 50, 60]);
  const capped: CountProbe = async (b) => (await h.probe(b)).map((c) => Math.min(c, 4));
  const w = await walkNonces(capped, 1_000);
  assert.equal(w.total, 4);
  assert.deepEqual(w.blocks.map((b) => b.block), [10, 20, 30, 40]);
});

test('a node whose counts go backwards is reported, not believed', async () => {
  const lying: CountProbe = async (asked) => asked.map((b) => (b === 0 ? 0 : b === 1_000 ? 3 : b > 400 && b < 600 ? 5 : 1));
  await assert.rejects(walkNonces(lying, 1_000), /outside .*consistent archive state/);
  const shrinking: CountProbe = async (asked) => asked.map((b) => (b === 0 ? 2 : 1));
  await assert.rejects(walkNonces(shrinking, 1_000), /the count fell/);
  const short: CountProbe = async (asked) => (asked.length === 2 && asked[0] === 0 ? [0, 1] : []);
  await assert.rejects(walkNonces(short, 1_000), /different number of counts/);
});
